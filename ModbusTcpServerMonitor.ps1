param(
    [ValidateRange(1,65535)][int]$Port = 502,
    [ValidateRange(1,200)][int]$MaxClients = 50,
    [ValidateRange(100,65536)][int]$AddressSpaceSize = 10000,
    [string]$BindAddress = "0.0.0.0",
    [ValidateRange(0,86400)][int]$IdleTimeoutSeconds = 60
)

# Modbus TCP Server Monitor for Windows PowerShell 5.1+
# Supported FCs: 01, 02, 03, 04, 05, 06, 15, 16
# Address display is one-based by default: protocol address 0 is shown as 1.
# Version 1.1.0

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$source = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Concurrent;
using System.Collections.Generic;

public sealed class MbEvent {
    public DateTime Time = DateTime.Now;
    public string Type = "";
    public string Client = "";
    public string Message = "";
}

public sealed class MbClientInfo {
    public string Endpoint;
    public DateTime Connected;
    public DateTime LastSeen;
    public long RxFrames;
    public long TxFrames;
    public long RxBytes;
    public long TxBytes;
    public long Reads;
    public long Writes;
    public string LastOperation = "-";
}

public sealed class ModbusEngine : IDisposable {
    readonly ConcurrentQueue<MbEvent> events = new ConcurrentQueue<MbEvent>();
    public readonly ConcurrentDictionary<string,MbClientInfo> Clients = new ConcurrentDictionary<string,MbClientInfo>();
    readonly ConcurrentDictionary<string,TcpClient> sockets = new ConcurrentDictionary<string,TcpClient>();
    readonly List<Task> clientTasks = new List<Task>();
    // One lock guards the four data tables so multi-register writes are atomic with respect to reads.
    readonly object sync = new object();
    readonly ushort[] holding, input;
    readonly bool[] coils, discrete;

    public long TotalConnections, TotalRxFrames, TotalTxFrames, TotalRxBytes, TotalTxBytes, TotalReads, TotalWrites, TotalExceptions, TotalErrors, DroppedEvents;
    public int Port, MaxClients, Size;
    public int IdleTimeoutMs = 60000;
    public int MaxQueuedEvents = 50000;
    public DateTime Started;
    int queued;
    TcpListener listener;
    CancellationTokenSource cancel;
    Task acceptTask;

    public bool IsRunning { get { return listener != null; } }
    public int QueuedEvents { get { return queued; } }

    public ModbusEngine(int port, int maxClients, int size) {
        Port=port; MaxClients=maxClients; Size=size;
        holding=new ushort[size]; input=new ushort[size]; coils=new bool[size]; discrete=new bool[size];
    }

    void Emit(string type,string client,string message) {
        // Bounded queue: if the GUI falls behind, high-volume frame/read events are dropped (and counted)
        // instead of growing memory without limit. Control events are always kept.
        if (queued >= MaxQueuedEvents && (type=="RX" || type=="TX" || type=="READ")) { Interlocked.Increment(ref DroppedEvents); return; }
        Interlocked.Increment(ref queued);
        events.Enqueue(new MbEvent { Time=DateTime.Now, Type=type, Client=client, Message=message });
    }
    public void Note(string type,string message) { Emit(type,"-",message); }
    public bool TryDequeueEvent(out MbEvent e) {
        if (events.TryDequeue(out e)) { Interlocked.Decrement(ref queued); return true; }
        return false;
    }

    public void Start(string bindAddress) {
        if (listener != null) return;
        IPAddress ip;
        if (!IPAddress.TryParse(bindAddress, out ip)) throw new ArgumentException("Invalid bind address.");
        // The listener is published only after it is really listening, so a failed Start can be retried.
        TcpListener l = new TcpListener(ip,Port);
        l.Start();
        listener = l;
        cancel = new CancellationTokenSource();
        Started = DateTime.Now;
        Emit("SERVER","-","Started on "+bindAddress+":"+Port+" (max clients "+MaxClients+", address space "+Size+", idle timeout "+(IdleTimeoutMs>0 ? (IdleTimeoutMs/1000)+" s" : "off")+")");
        CancellationToken token = cancel.Token;
        SemaphoreSlim slots = new SemaphoreSlim(MaxClients,MaxClients);
        acceptTask = Task.Run(()=>AcceptLoop(l,slots,token));
    }

    static string SafeEndpoint(TcpClient tcp) { try { return tcp.Client.RemoteEndPoint.ToString(); } catch { return "?"; } }

    async Task AcceptLoop(TcpListener l, SemaphoreSlim slots, CancellationToken token) {
        while (!token.IsCancellationRequested) {
            TcpClient tcp=null;
            try {
                tcp=await l.AcceptTcpClientAsync().ConfigureAwait(false);
                if (!slots.Wait(0)) { Emit("WARN",SafeEndpoint(tcp),"Rejected: maximum clients reached ("+MaxClients+")"); tcp.Close(); continue; }
                tcp.NoDelay=true;
                TcpClient c = tcp;
                // The semaphore is captured per client so a late-exiting client never releases a semaphore of a later Start.
                Task t = Task.Run(async ()=> { try { await ClientLoop(c,token).ConfigureAwait(false); } finally { slots.Release(); } });
                lock (clientTasks) { clientTasks.RemoveAll(x => x.IsCompleted); clientTasks.Add(t); }
            } catch (ObjectDisposedException) { break; }
            catch (Exception ex) { if(!token.IsCancellationRequested){Interlocked.Increment(ref TotalErrors);Emit("ERROR","-","Accept: "+ex.Message);} if(tcp!=null)tcp.Close(); }
        }
    }

    async Task<bool> ReadExact(NetworkStream s,byte[] b,int count,CancellationToken token) {
        int offset=0;
        while(offset<count) {
            Task<int> read = s.ReadAsync(b,offset,count-offset,token);
            if (IdleTimeoutMs > 0) {
                // NetworkStream.ReadAsync ignores Socket.ReceiveTimeout, so the idle timeout is enforced with a race against a delay.
                using (CancellationTokenSource delayCts = CancellationTokenSource.CreateLinkedTokenSource(token)) {
                    Task delay = Task.Delay(IdleTimeoutMs, delayCts.Token);
                    Task done = await Task.WhenAny(read, delay).ConfigureAwait(false);
                    delayCts.Cancel();
                    if (done != read) {
                        token.ThrowIfCancellationRequested();
                        // Observe the fault of the abandoned read (the socket is closed right after) so it is not reported as unobserved.
                        Task observe = read.ContinueWith(t => { var ignored = t.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
                        throw new TimeoutException("No data received for "+(IdleTimeoutMs/1000)+" s; closing idle connection");
                    }
                }
            }
            int n=await read.ConfigureAwait(false);
            if(n==0)return false;
            offset+=n;
        }
        return true;
    }
    static ushort U16(byte[] b,int p){return (ushort)((b[p]<<8)|b[p+1]);}
    bool RangeOk(int start,int qty){return start>=0 && qty>0 && start+qty<=Size;}
    static string Hex(byte[] b){return BitConverter.ToString(b).Replace("-"," ");}
    static string ExName(byte c){
        switch(c){ case 1: return "Illegal function"; case 2: return "Illegal data address"; case 3: return "Illegal data value"; case 4: return "Server device failure"; default: return "Unknown"; }
    }

    async Task ClientLoop(TcpClient tcp,CancellationToken token) {
        string ep=SafeEndpoint(tcp);
        var info=new MbClientInfo {Endpoint=ep,Connected=DateTime.Now,LastSeen=DateTime.Now};
        Clients[ep]=info; sockets[ep]=tcp; Interlocked.Increment(ref TotalConnections); Emit("CONNECT",ep,"Connected");
        string reason="Disconnected";
        try {
            using(tcp) using(NetworkStream stream=tcp.GetStream()) {
                byte[] head=new byte[7];
                while(!token.IsCancellationRequested) {
                    if(!await ReadExact(stream,head,7,token).ConfigureAwait(false)) { reason="Disconnected by client"; break; }
                    ushort len=U16(head,4);
                    if(U16(head,2)!=0 || len<2 || len>254) { Emit("WARN",ep,"Invalid MBAP header (protocol="+U16(head,2)+", length="+len+"); closing connection"); reason="Closed: invalid MBAP header"; break; }
                    byte[] pdu=new byte[len-1];
                    if(!await ReadExact(stream,pdu,pdu.Length,token).ConfigureAwait(false)) { reason="Disconnected by client"; break; }
                    byte[] request=new byte[7+pdu.Length];Buffer.BlockCopy(head,0,request,0,7);Buffer.BlockCopy(pdu,0,request,7,pdu.Length);
                    info.LastSeen=DateTime.Now;Interlocked.Increment(ref info.RxFrames);Interlocked.Add(ref info.RxBytes,request.Length);Interlocked.Increment(ref TotalRxFrames);Interlocked.Add(ref TotalRxBytes,request.Length);
                    Emit("RX",ep,Hex(request));
                    bool write=false,read=false,changed=false;string op="";
                    byte[] responsePdu=Process(pdu,ref write,ref read,ref changed,ref op);
                    int responseLen=1+responsePdu.Length;
                    byte[] response=new byte[7+responsePdu.Length];
                    response[0]=head[0];response[1]=head[1];response[2]=0;response[3]=0;response[4]=(byte)(responseLen>>8);response[5]=(byte)responseLen;response[6]=head[6];Buffer.BlockCopy(responsePdu,0,response,7,responsePdu.Length);
                    await stream.WriteAsync(response,0,response.Length,token).ConfigureAwait(false);
                    info.LastOperation=op;info.LastSeen=DateTime.Now;Interlocked.Increment(ref info.TxFrames);Interlocked.Add(ref info.TxBytes,response.Length);Interlocked.Increment(ref TotalTxFrames);Interlocked.Add(ref TotalTxBytes,response.Length);
                    Emit("TX",ep,Hex(response));
                    if((responsePdu[0]&0x80)!=0){Interlocked.Increment(ref TotalExceptions);Emit("EXCEPTION",ep,op+" -> exception "+responsePdu[1]+" ("+ExName(responsePdu[1])+")");}
                    else if(read){Interlocked.Increment(ref info.Reads);Interlocked.Increment(ref TotalReads);Emit("READ",ep,op);}
                    else if(write){Interlocked.Increment(ref info.Writes);Interlocked.Increment(ref TotalWrites);Emit(changed?"CHANGE":"WRITE",ep,op);}
                }
            }
        } catch(OperationCanceledException) { reason="Closed: server stopped"; }
        catch(TimeoutException ex) { reason="Closed: idle timeout"; Emit("WARN",ep,ex.Message); }
        catch(Exception ex) {
            if(token.IsCancellationRequested) reason="Closed: server stopped";
            else { Interlocked.Increment(ref TotalErrors); Emit("ERROR",ep,ex.Message); reason="Closed: error"; }
        }
        finally { MbClientInfo gone;Clients.TryRemove(ep,out gone); TcpClient s;sockets.TryRemove(ep,out s); Emit("DISCONNECT",ep,reason); }
    }

    byte[] Ex(byte fc,byte code){return new byte[]{(byte)(fc|0x80),code};}

    // Exception codes follow the Modbus Application Protocol spec: 03 for a bad quantity/value/length, 02 for an address range outside the table.
    byte[] Process(byte[] p,ref bool write,ref bool read,ref bool changed,ref string op) {
        if(p.Length<1){op="Empty PDU";return new byte[]{0x80,3};}
        byte fc=p[0];
        try {
            lock(sync) {
                if(fc==1 || fc==2) {
                    op=(fc==1?"Read Coils":"Read Discrete Inputs");
                    if(p.Length!=5)return Ex(fc,3);
                    int start=U16(p,1),qty=U16(p,3); op+=" start="+(start+1)+" qty="+qty;
                    if(qty<1||qty>2000)return Ex(fc,3);
                    if(!RangeOk(start,qty))return Ex(fc,2);
                    bool[] src=fc==1?coils:discrete;
                    int bytes=(qty+7)/8;byte[] r=new byte[2+bytes];r[0]=fc;r[1]=(byte)bytes;
                    for(int i=0;i<qty;i++)if(src[start+i])r[2+i/8]|=(byte)(1<<(i%8));
                    read=true;return r;
                }
                if(fc==3 || fc==4) {
                    op=(fc==3?"Read Holding Registers":"Read Input Registers");
                    if(p.Length!=5)return Ex(fc,3);
                    int start=U16(p,1),qty=U16(p,3); op+=" start="+(start+1)+" qty="+qty;
                    if(qty<1||qty>125)return Ex(fc,3);
                    if(!RangeOk(start,qty))return Ex(fc,2);
                    ushort[] src=fc==3?holding:input;
                    byte[] r=new byte[2+qty*2];r[0]=fc;r[1]=(byte)(qty*2);
                    for(int i=0;i<qty;i++){r[2+i*2]=(byte)(src[start+i]>>8);r[3+i*2]=(byte)src[start+i];}
                    read=true;return r;
                }
                if(fc==5) {
                    op="Write Single Coil";
                    if(p.Length!=5)return Ex(fc,3);
                    int a=U16(p,1),raw=U16(p,3); op+=" address="+(a+1);
                    if(raw!=0 && raw!=0xFF00)return Ex(fc,3);
                    if(a>=Size)return Ex(fc,2);
                    bool v=raw==0xFF00; changed=coils[a]!=v; coils[a]=v; write=true;
                    op="Coil "+(a+1)+" = "+(v?1:0)+(changed?"":" (unchanged)"); return p;
                }
                if(fc==6) {
                    op="Write Single Register";
                    if(p.Length!=5)return Ex(fc,3);
                    int a=U16(p,1); ushort v=U16(p,3); op+=" address="+(a+1);
                    if(a>=Size)return Ex(fc,2);
                    ushort old=holding[a]; changed=old!=v; holding[a]=v; write=true;
                    op=changed ? "Holding "+(a+1)+" : "+old+" -> "+v : "Holding "+(a+1)+" = "+v+" (unchanged)"; return p;
                }
                if(fc==15) {
                    op="Write Multiple Coils";
                    if(p.Length<6)return Ex(fc,3);
                    int start=U16(p,1),qty=U16(p,3),bc=p[5]; op+=" start="+(start+1)+" qty="+qty;
                    if(qty<1||qty>1968||bc!=(qty+7)/8||p.Length!=6+bc)return Ex(fc,3);
                    if(!RangeOk(start,qty))return Ex(fc,2);
                    int n=0;
                    for(int i=0;i<qty;i++){bool v=(p[6+i/8]&(1<<(i%8)))!=0; if(coils[start+i]!=v){coils[start+i]=v;n++;}}
                    changed=n>0; write=true;
                    op="Coils "+(start+1)+".."+(start+qty)+" written ("+n+" of "+qty+" changed)"; return new byte[]{fc,p[1],p[2],p[3],p[4]};
                }
                if(fc==16) {
                    op="Write Multiple Registers";
                    if(p.Length<6)return Ex(fc,3);
                    int start=U16(p,1),qty=U16(p,3),bc=p[5]; op+=" start="+(start+1)+" qty="+qty;
                    if(qty<1||qty>123||bc!=qty*2||p.Length!=6+bc)return Ex(fc,3);
                    if(!RangeOk(start,qty))return Ex(fc,2);
                    int n=0;
                    for(int i=0;i<qty;i++){ushort v=U16(p,6+i*2); if(holding[start+i]!=v){holding[start+i]=v;n++;}}
                    changed=n>0; write=true;
                    op="Holding "+(start+1)+".."+(start+qty)+" written ("+n+" of "+qty+" changed)"; return new byte[]{fc,p[1],p[2],p[3],p[4]};
                }
            }
            op="Unsupported function "+fc; return Ex(fc,1);
        } catch { op="Internal error in function "+fc; return Ex(fc,4); }
    }

    // Local (GUI) write. Address is zero-based here; the GUI converts from the one-based display value.
    public string SetValue(string area,int address,int value) {
        if(address<0||address>=Size) throw new ArgumentException("Address must be between 1 and "+Size+".");
        string desc;
        lock(sync) {
            switch((area ?? "").ToUpperInvariant()) {
                case "HR": { if(value<0||value>65535)throw new ArgumentException("Register value must be between 0 and 65535."); ushort old=holding[address]; holding[address]=(ushort)value; desc="Holding "+(address+1)+" : "+old+" -> "+value; break; }
                case "IR": { if(value<0||value>65535)throw new ArgumentException("Register value must be between 0 and 65535."); ushort old=input[address]; input[address]=(ushort)value; desc="Input register "+(address+1)+" : "+old+" -> "+value; break; }
                case "C":  { if(value!=0&&value!=1)throw new ArgumentException("Coil value must be 0 or 1."); coils[address]=value==1; desc="Coil "+(address+1)+" = "+value; break; }
                case "DI": { if(value!=0&&value!=1)throw new ArgumentException("Discrete input value must be 0 or 1."); discrete[address]=value==1; desc="Discrete input "+(address+1)+" = "+value; break; }
                default: throw new ArgumentException("Area must be HR, IR, C or DI.");
            }
        }
        Emit("CHANGE","local",desc);
        return desc;
    }

    // Persistence format: one "AREA:zeroBasedAddress=value" per line; only non-zero/ON entries are written.
    public string[] ExportState() {
        var lines=new List<string>();
        lock(sync) {
            for(int i=0;i<Size;i++)if(holding[i]!=0)lines.Add("HR:"+i+"="+holding[i]);
            for(int i=0;i<Size;i++)if(input[i]!=0)lines.Add("IR:"+i+"="+input[i]);
            for(int i=0;i<Size;i++)if(coils[i])lines.Add("C:"+i+"=1");
            for(int i=0;i<Size;i++)if(discrete[i])lines.Add("DI:"+i+"=1");
        }
        return lines.ToArray();
    }
    // Returns null when the line was applied, "" when it was blank/comment, otherwise an error description.
    public string ImportStateLine(string line) {
        if(line==null)return "";
        line=line.Trim();
        if(line.Length==0 || line.StartsWith("#"))return "";
        int colon=line.IndexOf(':'), eq=line.IndexOf('=');
        if(colon<=0 || eq<=colon+1)return "expected AREA:address=value";
        string area=line.Substring(0,colon).ToUpperInvariant();
        int address,value;
        if(!int.TryParse(line.Substring(colon+1,eq-colon-1),out address))return "address is not a number";
        if(!int.TryParse(line.Substring(eq+1),out value))return "value is not a number";
        if(address<0||address>=Size)return "address "+address+" is outside the address space (0.."+(Size-1)+")";
        lock(sync) {
            switch(area) {
                case "HR": if(value<0||value>65535)return "register value out of range"; holding[address]=(ushort)value; return null;
                case "IR": if(value<0||value>65535)return "register value out of range"; input[address]=(ushort)value; return null;
                case "C":  if(value!=0&&value!=1)return "coil value must be 0 or 1"; coils[address]=value==1; return null;
                case "DI": if(value!=0&&value!=1)return "discrete input value must be 0 or 1"; discrete[address]=value==1; return null;
                default: return "unknown area '"+area+"' (expected HR, IR, C or DI)";
            }
        }
    }

    public void Stop() {
        TcpListener l=listener;
        if(l==null)return;
        listener=null;
        try{cancel.Cancel();}catch{}
        try{l.Stop();}catch{}
        // Connected clients are closed explicitly: cancelling the token alone does not interrupt a pending ReadAsync.
        foreach(var kv in sockets){ try{kv.Value.Close();}catch{} }
        Task[] pending; lock(clientTasks){ pending=clientTasks.ToArray(); clientTasks.Clear(); }
        try{Task.WaitAll(pending,3000);}catch{}
        try{ if(acceptTask!=null) acceptTask.Wait(1000); }catch{}
        try{cancel.Dispose();}catch{}
        cancel=null; acceptTask=null;
        Emit("SERVER","-","Stopped");
    }
    public void Dispose(){ Stop(); }
}
'@
Add-Type -TypeDefinition $source -Language CSharp

$base = $PSScriptRoot
if (-not $base) { $base = (Get-Location).Path }   # script pasted into a console or run through Invoke-Expression
$session = Get-Date -Format 'yyyyMMdd_HHmmss'
$allLog = Join-Path $base ("modbus_session_{0}.txt" -f $session)
$changeLog = Join-Path $base ("modbus_changes_{0}.txt" -f $session)
$stateFile = Join-Path $base 'modbus_values.txt'
$utf8 = [Text.UTF8Encoding]::new($false)
$engine = [ModbusEngine]::new($Port,$MaxClients,$AddressSpaceSize)
$engine.IdleTimeoutMs = $IdleTimeoutSeconds * 1000

# Log files stay open for the whole session and are flushed once per GUI tick instead of being reopened per line.
$script:allWriter = $null
$script:changeWriter = $null
function Write-LogLine([string]$Which,[string]$Line) {
    if ($Which -eq 'change') {
        if (-not $script:changeWriter) { $script:changeWriter = [IO.StreamWriter]::new($changeLog,$true,$utf8) }
        $script:changeWriter.WriteLine($Line)
    } else {
        if (-not $script:allWriter) { $script:allWriter = [IO.StreamWriter]::new($allLog,$true,$utf8) }
        $script:allWriter.WriteLine($Line)
    }
}
function Sync-LogFiles { foreach ($w in @($script:allWriter,$script:changeWriter)) { if ($w) { $w.Flush() } } }
function Close-LogFiles { foreach ($w in @($script:allWriter,$script:changeWriter)) { if ($w) { $w.Dispose() } }; $script:allWriter=$null; $script:changeWriter=$null }

# Persistence is debounced: writes mark the state dirty and the file is rewritten at most every 2 s, plus on demand and on exit.
$script:stateDirty = $false
$script:lastStateSave = [datetime]::MinValue
function Save-State {
    $tmp = $stateFile + '.tmp'
    [IO.File]::WriteAllLines($tmp,[string[]]$engine.ExportState(),$utf8)
    Move-Item -LiteralPath $tmp -Destination $stateFile -Force
    $script:stateDirty = $false
    $script:lastStateSave = Get-Date
}
function Import-State {
    $loaded = 0; $invalid = New-Object Collections.Generic.List[string]
    if (Test-Path -LiteralPath $stateFile) {
        $n = 0
        foreach ($line in [IO.File]::ReadAllLines($stateFile)) {
            $n++
            $err = $engine.ImportStateLine($line)
            if ($null -eq $err) { $loaded++ } elseif ($err) { $invalid.Add(("line {0} '{1}': {2}" -f $n,$line,$err)) }
        }
        $engine.Note('SERVER',("Loaded {0} value(s) from {1}" -f $loaded,[IO.Path]::GetFileName($stateFile)))
        $shown = 0
        foreach ($i in $invalid) { if ($shown -lt 20) { $engine.Note('WARN',"Ignored $i") }; $shown++ }
        if ($invalid.Count -gt 20) { $engine.Note('WARN',("... {0} more invalid line(s) ignored" -f ($invalid.Count-20))) }
    }
}
Import-State

$form=New-Object Windows.Forms.Form
$form.Text="Modbus TCP Server Monitor - port $Port"
$form.Size=[Drawing.Size]::new(1500,900)
$form.MinimumSize=[Drawing.Size]::new(1150,700)
$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Segoe UI',9)

# A fixed three-row layout prevents the first traffic line from being hidden by Dock/Z-order.
$root=New-Object Windows.Forms.TableLayoutPanel
$root.Dock='Fill'
$root.RowCount=3
$root.ColumnCount=1
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,36)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,66)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
$form.Controls.Add($root)

$tool=New-Object Windows.Forms.ToolStrip
$tool.GripStyle='Hidden'
$tool.Dock='Fill'
$tool.AutoSize=$false
$btnStart=New-Object Windows.Forms.ToolStripButton('Start')
$btnStop=New-Object Windows.Forms.ToolStripButton('Stop');$btnStop.Enabled=$false
$btnClear=New-Object Windows.Forms.ToolStripButton('Clear traffic')
$btnFolder=New-Object Windows.Forms.ToolStripButton('Open log folder')
$btnSave=New-Object Windows.Forms.ToolStripButton('Save values now')
$btnPause=New-Object Windows.Forms.ToolStripButton('Pause view');$btnPause.CheckOnClick=$true;$btnPause.ToolTipText='Freeze the traffic view to read it. Logging and counters continue; lines are shown when resumed.'
$btnFrames=New-Object Windows.Forms.ToolStripButton('Show RX/TX frames');$btnFrames.CheckOnClick=$true;$btnFrames.Checked=$true;$btnFrames.ToolTipText='Hide the hexadecimal frames from the view (they are still written to the session log).'
$lblSet=New-Object Windows.Forms.ToolStripLabel('Set value:')
$cmbArea=New-Object Windows.Forms.ToolStripComboBox;$cmbArea.DropDownStyle='DropDownList';$cmbArea.AutoSize=$false;$cmbArea.Size=[Drawing.Size]::new(165,25)
[void]$cmbArea.Items.AddRange([object[]]@('HR - Holding register','IR - Input register','C - Coil','DI - Discrete input'));$cmbArea.SelectedIndex=0
$lblAddr=New-Object Windows.Forms.ToolStripLabel('Addr')
$txtAddr=New-Object Windows.Forms.ToolStripTextBox;$txtAddr.AutoSize=$false;$txtAddr.Size=[Drawing.Size]::new(60,25);$txtAddr.ToolTipText='Address as displayed (one-based)'
$lblVal=New-Object Windows.Forms.ToolStripLabel('Value')
$txtVal=New-Object Windows.Forms.ToolStripTextBox;$txtVal.AutoSize=$false;$txtVal.Size=[Drawing.Size]::new(70,25);$txtVal.ToolTipText='0..65535 for registers, 0/1 for coils and discrete inputs'
$btnSet=New-Object Windows.Forms.ToolStripButton('Apply')
[void]$tool.Items.AddRange([Windows.Forms.ToolStripItem[]]@($btnStart,$btnStop,(New-Object Windows.Forms.ToolStripSeparator),$btnClear,$btnFolder,$btnSave,(New-Object Windows.Forms.ToolStripSeparator),$btnPause,$btnFrames,(New-Object Windows.Forms.ToolStripSeparator),$lblSet,$cmbArea,$lblAddr,$txtAddr,$lblVal,$txtVal,$btnSet))
$root.Controls.Add($tool,0,0)

$status=New-Object Windows.Forms.Label
$status.Dock='Fill'
$status.BackColor=[Drawing.Color]::FromArgb(30,72,120)
$status.ForeColor='White'
$status.Font=New-Object Drawing.Font('Consolas',10,[Drawing.FontStyle]::Bold)
$status.Padding=New-Object Windows.Forms.Padding(12,6,12,6)
$status.TextAlign='MiddleLeft'
$root.Controls.Add($status,0,1)

# Main workspace: real-time traffic on the left, operational data on the right.
$mainSplit=New-Object Windows.Forms.SplitContainer
$mainSplit.Dock='Fill'
$mainSplit.Orientation='Vertical'
$mainSplit.SplitterWidth=6
# SplitterDistance and minimum panel sizes are applied only after the form has a real size.
# Setting them here can fail because a newly created SplitContainer temporarily has Width = 0.
$root.Controls.Add($mainSplit,0,2)

$trafficPanel=New-Object Windows.Forms.Panel
$trafficPanel.Dock='Fill'
$mainSplit.Panel1.Controls.Add($trafficPanel)
$trafficHeader=New-Object Windows.Forms.Label
$trafficHeader.Dock='Top'
$trafficHeader.Height=32
$trafficHeader.Text='  LIVE MODBUS TCP TRAFFIC'
$trafficHeader.TextAlign='MiddleLeft'
$trafficHeader.Font=New-Object Drawing.Font('Segoe UI',9,[Drawing.FontStyle]::Bold)
$trafficHeader.BackColor=[Drawing.Color]::FromArgb(45,48,54)
$trafficHeader.ForeColor='White'
$traffic=New-Object Windows.Forms.RichTextBox
$traffic.Dock='Fill'
$traffic.ReadOnly=$true
$traffic.BackColor=[Drawing.Color]::FromArgb(20,22,26)
$traffic.ForeColor=[Drawing.Color]::Gainsboro
$traffic.Font=New-Object Drawing.Font('Consolas',9)
$traffic.WordWrap=$false
$traffic.HideSelection=$false
$trafficPanel.Controls.Add($traffic)
$trafficPanel.Controls.Add($trafficHeader)

$rightSplit=New-Object Windows.Forms.SplitContainer
$rightSplit.Dock='Fill'
$rightSplit.Orientation='Horizontal'
$rightSplit.SplitterWidth=6
$mainSplit.Panel2.Controls.Add($rightSplit)

$grpClients=New-Object Windows.Forms.GroupBox
$grpClients.Text='Active clients and packet counters'
$grpClients.Dock='Fill'
$rightSplit.Panel1.Controls.Add($grpClients)
$clients=New-Object Windows.Forms.ListView
$clients.Dock='Fill'
$clients.View='Details'
$clients.FullRowSelect=$true
$clients.GridLines=$true
$clients.HideSelection=$false
$clients.Sorting='Ascending'
foreach($c in @(@('Client',150),@('RX pkt',58),@('TX pkt',58),@('RX bytes',70),@('TX bytes',70),@('Reads',55),@('Writes',55),@('Last seen',72))){[void]$clients.Columns.Add($c[0],$c[1])}
$grpClients.Controls.Add($clients)

$grpChanges=New-Object Windows.Forms.GroupBox
$grpChanges.Text='Changed addresses and values'
$grpChanges.Dock='Fill'
$rightSplit.Panel2.Controls.Add($grpChanges)
$changes=New-Object Windows.Forms.ListView
$changes.Dock='Fill'
$changes.View='Details'
$changes.FullRowSelect=$true
$changes.GridLines=$true
$changes.HideSelection=$false
[void]$changes.Columns.Add('Time',72)
[void]$changes.Columns.Add('Client',145)
[void]$changes.Columns.Add('Address / value',260)
$grpChanges.Controls.Add($changes)

$maxChangeRows=500
$clientItems=@{}   # endpoint -> ListViewItem, so rows are updated in place instead of rebuilt every tick
$pausedLines=[Collections.Generic.Queue[object]]::new()
$script:pausedDropped=0
$script:lastDropped=[long]0

function Get-EventColor([string]$type) {
    switch($type){
        'RX'{[Drawing.Color]::Goldenrod}'TX'{[Drawing.Color]::DeepSkyBlue}'CHANGE'{[Drawing.Color]::LimeGreen}'WRITE'{[Drawing.Color]::DarkGray}
        'EXCEPTION'{[Drawing.Color]::Orchid}'ERROR'{[Drawing.Color]::Tomato}'WARN'{[Drawing.Color]::Orange}
        'CONNECT'{[Drawing.Color]::LightSkyBlue}'DISCONNECT'{[Drawing.Color]::LightSkyBlue}default{[Drawing.Color]::Silver}
    }
}
function Add-Traffic([string]$line,[Drawing.Color]$color){
    $traffic.SelectionStart=$traffic.TextLength;$traffic.SelectionLength=0;$traffic.SelectionColor=$color;$traffic.AppendText($line+[Environment]::NewLine)
}
function Show-TrafficLine([string]$line,[Drawing.Color]$color){
    if($btnPause.Checked){
        $pausedLines.Enqueue(@($line,$color))
        if($pausedLines.Count -gt 5000){[void]$pausedLines.Dequeue();$script:pausedDropped++}
        return
    }
    Add-Traffic $line $color
}
# Trimming and scrolling happen once per tick, not once per line.
function Complete-TrafficUpdate {
    if($traffic.TextLength -gt 500000){$traffic.Select(0,100000);$traffic.SelectedText=''}
    $traffic.SelectionStart=$traffic.TextLength;$traffic.SelectionLength=0;$traffic.ScrollToCaret()
}
function Add-ChangeRow($evt){
    $item=[Windows.Forms.ListViewItem]::new($evt.Time.ToString('HH:mm:ss'))
    [void]$item.SubItems.Add([string]$evt.Client)
    [void]$item.SubItems.Add([string]$evt.Message)
    [void]$changes.Items.Add($item)
    while($changes.Items.Count -gt $maxChangeRows){$changes.Items.RemoveAt(0)}
    $changes.EnsureVisible($changes.Items.Count-1)
}
function Update-ClientList {
    $live=@{}
    foreach($x in $engine.Clients.Values){$live[$x.Endpoint]=$x}
    $gone=@($clientItems.Keys | Where-Object { -not $live.ContainsKey($_) })
    $new=@($live.Keys | Where-Object { -not $clientItems.ContainsKey($_) })
    if($gone.Count -or $new.Count){$clients.BeginUpdate()}
    foreach($ep in $gone){$clients.Items.Remove($clientItems[$ep]);$clientItems.Remove($ep)}
    foreach($x in $live.Values){
        $vals=@([string]$x.RxFrames,[string]$x.TxFrames,[string]$x.RxBytes,[string]$x.TxBytes,[string]$x.Reads,[string]$x.Writes,$x.LastSeen.ToString('HH:mm:ss'))
        if($clientItems.ContainsKey($x.Endpoint)){
            $item=$clientItems[$x.Endpoint]
            for($i=0;$i -lt $vals.Count;$i++){ if($item.SubItems[$i+1].Text -ne $vals[$i]){$item.SubItems[$i+1].Text=$vals[$i]} }
        } else {
            $item=[Windows.Forms.ListViewItem]::new($x.Endpoint)
            foreach($v in $vals){[void]$item.SubItems.Add($v)}
            [void]$clients.Items.Add($item);$clientItems[$x.Endpoint]=$item
        }
    }
    if($gone.Count -or $new.Count){$clients.EndUpdate()}
}
function Update-Status {
    $running=$engine.IsRunning
    $up=if($running){(Get-Date)-$engine.Started}else{[timespan]::Zero}
    $line1='PORT {0}  |  BIND {1}  |  STATUS {2}  |  UPTIME {3:00}:{4:00}:{5:00}  |  CLIENTS {6}/{7}  |  CONNECTIONS {8}  |  IDLE TIMEOUT {9}' -f $Port,$BindAddress,$(if($running){'RUNNING'}else{'STOPPED'}),[int]$up.TotalHours,$up.Minutes,$up.Seconds,$engine.Clients.Count,$MaxClients,$engine.TotalConnections,$(if($IdleTimeoutSeconds){"$IdleTimeoutSeconds s"}else{'off'})
    $line2='RX {0} frames / {1} bytes  |  TX {2} frames / {3} bytes  |  READS {4}  |  WRITES {5}  |  EXCEPTIONS {6}  |  ERRORS {7}' -f $engine.TotalRxFrames,$engine.TotalRxBytes,$engine.TotalTxFrames,$engine.TotalTxBytes,$engine.TotalReads,$engine.TotalWrites,$engine.TotalExceptions,$engine.TotalErrors
    if($engine.DroppedEvents){$line2+='  |  DROPPED {0}' -f $engine.DroppedEvents}
    $status.Text=$line1+[Environment]::NewLine+$line2
}
function Invoke-EventPump {
    $evt=$null;$processed=0
    while($processed -lt 500 -and $engine.TryDequeueEvent([ref]$evt)){
        $processed++
        $line='{0:yyyy-MM-dd HH:mm:ss.fff} | {1,-10} | {2} | {3}' -f $evt.Time,$evt.Type,$evt.Client,$evt.Message
        Write-LogLine 'all' $line
        if($evt.Type -eq 'CHANGE'){
            Write-LogLine 'change' $line
            Add-ChangeRow $evt
            $script:stateDirty=$true
        }
        if(-not $btnFrames.Checked -and ($evt.Type -eq 'RX' -or $evt.Type -eq 'TX')){continue}
        Show-TrafficLine $line (Get-EventColor $evt.Type)
    }
    $dropped=$engine.DroppedEvents
    if($dropped -gt $script:lastDropped){
        $line='{0:yyyy-MM-dd HH:mm:ss.fff} | {1,-10} | - | GUI could not keep up: {2} RX/TX/READ event(s) were discarded and are missing from this log' -f (Get-Date),'WARN',($dropped-$script:lastDropped)
        Write-LogLine 'all' $line;Show-TrafficLine $line (Get-EventColor 'WARN');$script:lastDropped=$dropped;$processed++
    }
    if($processed -gt 0){Sync-LogFiles;if(-not $btnPause.Checked){Complete-TrafficUpdate}}
    if($script:stateDirty -and ((Get-Date)-$script:lastStateSave).TotalSeconds -ge 2){Save-State}
    Update-ClientList
    Update-Status
}
function Set-ResponsiveLayout {
    # Apply minimum sizes only when the controls have valid dimensions.
    if($mainSplit.ClientSize.Width -gt 960){
        $mainSplit.Panel1MinSize=600
        $mainSplit.Panel2MinSize=300
        $desired=[int]($mainSplit.ClientSize.Width * 0.70)
        $minimum=$mainSplit.Panel1MinSize
        $maximum=$mainSplit.ClientSize.Width-$mainSplit.Panel2MinSize-$mainSplit.SplitterWidth
        if($desired -lt $minimum){$desired=$minimum}
        if($desired -gt $maximum){$desired=$maximum}
        if($maximum -ge $minimum){$mainSplit.SplitterDistance=$desired}
    }
    if($rightSplit.ClientSize.Height -gt 460){
        $rightSplit.Panel1MinSize=200
        $rightSplit.Panel2MinSize=170
        $desired=[int]($rightSplit.ClientSize.Height * 0.55)
        $minimum=$rightSplit.Panel1MinSize
        $maximum=$rightSplit.ClientSize.Height-$rightSplit.Panel2MinSize-$rightSplit.SplitterWidth
        if($desired -lt $minimum){$desired=$minimum}
        if($desired -gt $maximum){$desired=$maximum}
        if($maximum -ge $minimum){$rightSplit.SplitterDistance=$desired}
    }
}

function Start-Server {
    try{$engine.Start($BindAddress);$btnStart.Enabled=$false;$btnStop.Enabled=$true}
    catch{[Windows.Forms.MessageBox]::Show($_.Exception.GetBaseException().Message,'Start error','OK','Error')|Out-Null}
}
function Stop-Server {$engine.Stop();$btnStart.Enabled=$true;$btnStop.Enabled=$false}
$btnStart.Add_Click({Start-Server})
$btnStop.Add_Click({Stop-Server})
$btnClear.Add_Click({$traffic.Clear();$pausedLines.Clear();$script:pausedDropped=0})
$btnFolder.Add_Click({Start-Process explorer.exe $base})
$btnSave.Add_Click({try{Save-State}catch{[Windows.Forms.MessageBox]::Show($_.Exception.GetBaseException().Message,'Save error','OK','Error')|Out-Null}})
$btnPause.Add_CheckedChanged({
    if($btnPause.Checked){return}
    while($pausedLines.Count){$p=$pausedLines.Dequeue();Add-Traffic $p[0] $p[1]}
    if($script:pausedDropped){Add-Traffic ("... {0} line(s) were skipped while the view was paused; see the session log" -f $script:pausedDropped) ([Drawing.Color]::Orange);$script:pausedDropped=0}
    Complete-TrafficUpdate
})
$btnSet.Add_Click({
    try{
        $area=([string]$cmbArea.SelectedItem).Split(' ')[0]
        $addr=0;$val=0
        if(-not [int]::TryParse($txtAddr.Text.Trim(),[ref]$addr)){throw 'Address must be a whole number (one-based, as displayed).'}
        if(-not [int]::TryParse($txtVal.Text.Trim(),[ref]$val)){throw 'Value must be a whole number.'}
        [void]$engine.SetValue($area,$addr-1,$val)
    }catch{[Windows.Forms.MessageBox]::Show($_.Exception.GetBaseException().Message,'Set value','OK','Warning')|Out-Null}
})

$timer=New-Object Windows.Forms.Timer;$timer.Interval=150
$timer.Add_Tick({
    try{Invoke-EventPump}
    catch{
        $msg='{0:yyyy-MM-dd HH:mm:ss.fff} | {1,-10} | - | GUI: {2}' -f (Get-Date),'ERROR',$_.Exception.GetBaseException().Message
        try{Write-LogLine 'all' $msg;Add-Traffic $msg ([Drawing.Color]::Tomato)}catch{}
    }
})
$form.Add_Shown({
    # BeginInvoke waits until the first layout pass has completed.
    [void]$form.BeginInvoke([Action]{Set-ResponsiveLayout})
    Start-Server
    $timer.Start()
})
$form.Add_Resize({
    if($form.WindowState -ne [Windows.Forms.FormWindowState]::Minimized){
        Set-ResponsiveLayout
    }
})
$form.Add_FormClosing({
    $timer.Stop()
    try{$engine.Stop()}catch{}
    # Drain the remaining events so the DISCONNECT/Stopped lines reach the session log.
    $rounds=0;while($engine.QueuedEvents -gt 0 -and $rounds -lt 200){try{Invoke-EventPump}catch{};$rounds++}
    try{Save-State}catch{}
    Close-LogFiles
    $engine.Dispose()
})
[void]$form.ShowDialog()
