param(
    [ValidateRange(1,65535)][int]$Port = 502,
    [ValidateRange(1,200)][int]$MaxClients = 50,
    [ValidateRange(100,65536)][int]$AddressSpaceSize = 10000,
    [string]$BindAddress = "0.0.0.0"
)

# Modbus TCP Server Monitor for Windows PowerShell 5.1+
# Supported FCs: 01, 02, 03, 04, 05, 06, 15, 16
# Address display is one-based by default: protocol address 0 is shown as 1.

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
    public byte[] Frame;
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
    public readonly ConcurrentQueue<MbEvent> Events = new ConcurrentQueue<MbEvent>();
    public readonly ConcurrentDictionary<string,MbClientInfo> Clients = new ConcurrentDictionary<string,MbClientInfo>();
    public readonly ConcurrentDictionary<int,ushort> Holding = new ConcurrentDictionary<int,ushort>();
    public readonly ConcurrentDictionary<int,ushort> Input = new ConcurrentDictionary<int,ushort>();
    public readonly ConcurrentDictionary<int,bool> Coils = new ConcurrentDictionary<int,bool>();
    public readonly ConcurrentDictionary<int,bool> Discrete = new ConcurrentDictionary<int,bool>();

    public long TotalConnections, TotalRxFrames, TotalTxFrames, TotalRxBytes, TotalTxBytes, TotalReads, TotalWrites, TotalErrors;
    public int Port, MaxClients, Size;
    public DateTime Started;
    TcpListener listener;
    CancellationTokenSource cancel;
    SemaphoreSlim slots;
    Task acceptTask;

    public ModbusEngine(int port, int maxClients, int size) { Port=port; MaxClients=maxClients; Size=size; }

    void Emit(string type,string client,string message,byte[] frame=null) {
        Events.Enqueue(new MbEvent { Time=DateTime.Now, Type=type, Client=client, Message=message, Frame=frame });
    }

    public void Start(string bindAddress) {
        if (listener != null) return;
        IPAddress ip;
        if (!IPAddress.TryParse(bindAddress, out ip)) throw new ArgumentException("Invalid bind address.");
        cancel = new CancellationTokenSource(); slots = new SemaphoreSlim(MaxClients,MaxClients);
        listener = new TcpListener(ip,Port); listener.Start(); Started=DateTime.Now;
        Emit("SERVER","-","Started on "+bindAddress+":"+Port);
        acceptTask = Task.Run(()=>AcceptLoop(cancel.Token));
    }

    async Task AcceptLoop(CancellationToken token) {
        while (!token.IsCancellationRequested) {
            TcpClient tcp=null;
            try {
                tcp=await listener.AcceptTcpClientAsync().ConfigureAwait(false);
                if (!await slots.WaitAsync(0).ConfigureAwait(false)) { Emit("WARN",tcp.Client.RemoteEndPoint.ToString(),"Rejected: maximum clients reached"); tcp.Close(); continue; }
                tcp.NoDelay=true; tcp.ReceiveTimeout=30000; tcp.SendTimeout=30000;
                Task clientTask = Task.Run(async ()=> { try { await ClientLoop(tcp,token).ConfigureAwait(false); } finally { slots.Release(); } });
            } catch (ObjectDisposedException) { break; }
            catch (Exception ex) { if(!token.IsCancellationRequested){Interlocked.Increment(ref TotalErrors);Emit("ERROR","-","Accept: "+ex.Message);} if(tcp!=null)tcp.Close(); }
        }
    }

    static async Task<bool> ReadExact(NetworkStream s,byte[] b,int count,CancellationToken token) {
        int offset=0;
        while(offset<count) { int n=await s.ReadAsync(b,offset,count-offset,token).ConfigureAwait(false); if(n==0)return false; offset+=n; }
        return true;
    }
    static ushort U16(byte[] b,int p){return (ushort)((b[p]<<8)|b[p+1]);}
    static void PutU16(List<byte> b,int v){b.Add((byte)((v>>8)&255));b.Add((byte)(v&255));}
    bool RangeOk(int start,int qty){return start>=0 && qty>0 && start+qty<=Size;}
    static string Hex(byte[] b){return BitConverter.ToString(b).Replace("-"," ");}

    async Task ClientLoop(TcpClient tcp,CancellationToken token) {
        string ep=tcp.Client.RemoteEndPoint.ToString();
        var info=new MbClientInfo {Endpoint=ep,Connected=DateTime.Now,LastSeen=DateTime.Now};
        Clients[ep]=info;Interlocked.Increment(ref TotalConnections);Emit("CONNECT",ep,"Connected");
        try {
            using(tcp) using(NetworkStream stream=tcp.GetStream()) {
                byte[] head=new byte[7];
                while(!token.IsCancellationRequested) {
                    if(!await ReadExact(stream,head,7,token).ConfigureAwait(false))break;
                    ushort len=U16(head,4);
                    if(U16(head,2)!=0 || len<2 || len>254) { Emit("WARN",ep,"Invalid MBAP length/protocol"); break; }
                    byte[] pdu=new byte[len-1];
                    if(!await ReadExact(stream,pdu,pdu.Length,token).ConfigureAwait(false))break;
                    byte[] request=new byte[7+pdu.Length];Buffer.BlockCopy(head,0,request,0,7);Buffer.BlockCopy(pdu,0,request,7,pdu.Length);
                    info.LastSeen=DateTime.Now;Interlocked.Increment(ref info.RxFrames);Interlocked.Add(ref info.RxBytes,request.Length);Interlocked.Increment(ref TotalRxFrames);Interlocked.Add(ref TotalRxBytes,request.Length);
                    Emit("RX",ep,Hex(request),request);
                    bool write=false,read=false;string op="";
                    byte[] responsePdu=Process(pdu,ref write,ref read,ref op);
                    int responseLen=1+responsePdu.Length;
                    byte[] response=new byte[7+responsePdu.Length];
                    response[0]=head[0];response[1]=head[1];response[2]=0;response[3]=0;response[4]=(byte)(responseLen>>8);response[5]=(byte)responseLen;response[6]=head[6];Buffer.BlockCopy(responsePdu,0,response,7,responsePdu.Length);
                    await stream.WriteAsync(response,0,response.Length,token).ConfigureAwait(false);
                    info.LastOperation=op;info.LastSeen=DateTime.Now;Interlocked.Increment(ref info.TxFrames);Interlocked.Add(ref info.TxBytes,response.Length);Interlocked.Increment(ref TotalTxFrames);Interlocked.Add(ref TotalTxBytes,response.Length);
                    Emit("TX",ep,Hex(response),response);
                    if(read){Interlocked.Increment(ref info.Reads);Interlocked.Increment(ref TotalReads);Emit("READ",ep,op);}
                    if(write){Interlocked.Increment(ref info.Writes);Interlocked.Increment(ref TotalWrites);Emit("CHANGE",ep,op);}
                }
            }
        } catch(OperationCanceledException) {}
        catch(Exception ex){Interlocked.Increment(ref TotalErrors);Emit("ERROR",ep,ex.Message);}
        finally { MbClientInfo gone;Clients.TryRemove(ep,out gone);Emit("DISCONNECT",ep,"Disconnected"); }
    }

    byte[] Ex(byte fc,byte code){return new byte[]{(byte)(fc|0x80),code};}
    byte[] Process(byte[] p,ref bool write,ref bool read,ref string op) {
        if(p.Length<1)return new byte[]{0x80,3}; byte fc=p[0];
        try {
            if(fc==1 || fc==2) {
                if(p.Length!=5)return Ex(fc,3);int start=U16(p,1),qty=U16(p,3);if(qty>2000||!RangeOk(start,qty))return Ex(fc,2);
                int bytes=(qty+7)/8;byte[] r=new byte[2+bytes];r[0]=fc;r[1]=(byte)bytes;
                for(int i=0;i<qty;i++){bool v; if(fc==1)Coils.TryGetValue(start+i,out v);else Discrete.TryGetValue(start+i,out v);if(v)r[2+i/8]|=(byte)(1<<(i%8));}
                read=true;op=(fc==1?"Read Coils":"Read Discrete Inputs")+" start="+(start+1)+" qty="+qty;return r;
            }
            if(fc==3 || fc==4) {
                if(p.Length!=5)return Ex(fc,3);int start=U16(p,1),qty=U16(p,3);if(qty>125||!RangeOk(start,qty))return Ex(fc,2);
                var r=new List<byte>();r.Add(fc);r.Add((byte)(qty*2));for(int i=0;i<qty;i++){ushort v;if(fc==3)Holding.TryGetValue(start+i,out v);else Input.TryGetValue(start+i,out v);PutU16(r,v);}
                read=true;op=(fc==3?"Read Holding Registers":"Read Input Registers")+" start="+(start+1)+" qty="+qty;return r.ToArray();
            }
            if(fc==5) {
                if(p.Length!=5)return Ex(fc,3);int a=U16(p,1),raw=U16(p,3);if(a>=Size)return Ex(fc,2);if(raw!=0 && raw!=0xFF00)return Ex(fc,3);bool v=raw==0xFF00;Coils[a]=v;write=true;op="Coil "+(a+1)+" = "+(v?1:0);return p;
            }
            if(fc==6) {
                if(p.Length!=5)return Ex(fc,3);int a=U16(p,1);if(a>=Size)return Ex(fc,2);ushort v=U16(p,3);ushort old;Holding.TryGetValue(a,out old);Holding[a]=v;write=true;op="Holding "+(a+1)+" : "+old+" -> "+v;return p;
            }
            if(fc==15) {
                if(p.Length<6)return Ex(fc,3);int start=U16(p,1),qty=U16(p,3),bc=p[5];if(qty>1968||!RangeOk(start,qty)||bc!=(qty+7)/8||p.Length!=6+bc)return Ex(fc,3);
                for(int i=0;i<qty;i++)Coils[start+i]=(p[6+i/8]&(1<<(i%8)))!=0;write=true;op="Coils "+(start+1)+".."+(start+qty)+" updated ("+qty+")";return new byte[]{fc,p[1],p[2],p[3],p[4]};
            }
            if(fc==16) {
                if(p.Length<6)return Ex(fc,3);int start=U16(p,1),qty=U16(p,3),bc=p[5];if(qty>123||!RangeOk(start,qty)||bc!=qty*2||p.Length!=6+bc)return Ex(fc,3);
                for(int i=0;i<qty;i++)Holding[start+i]=U16(p,6+i*2);write=true;op="Holding "+(start+1)+".."+(start+qty)+" updated ("+qty+")";return new byte[]{fc,p[1],p[2],p[3],p[4]};
            }
            op="Unsupported function "+fc;return Ex(fc,1);
        } catch { return Ex(fc,4); }
    }

    public void Stop(){if(cancel==null)return;try{cancel.Cancel();}catch{}try{listener.Stop();}catch{}foreach(var c in Clients){}Emit("SERVER","-","Stopped");listener=null;}
    public void Dispose(){Stop();if(cancel!=null)cancel.Dispose();if(slots!=null)slots.Dispose();}
}
'@
Add-Type -TypeDefinition $source -Language CSharp

$base = $PSScriptRoot
$session = Get-Date -Format 'yyyyMMdd_HHmmss'
$allLog = Join-Path $base ("modbus_session_{0}.txt" -f $session)
$changeLog = Join-Path $base ("modbus_changes_{0}.txt" -f $session)
$stateFile = Join-Path $base 'modbus_values.txt'
$logLock = New-Object object
$engine = [ModbusEngine]::new($Port,$MaxClients,$AddressSpaceSize)

function Append-FileLine([string]$Path,[string]$Line) {
    [Threading.Monitor]::Enter($logLock)
    try {[IO.File]::AppendAllText($Path,$Line+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))} finally {[Threading.Monitor]::Exit($logLock)}
}
function Save-State {
    $tmp=$stateFile+'.tmp';$lines=New-Object Collections.Generic.List[string]
    foreach($x in $engine.Holding.GetEnumerator()|Sort-Object Key){if($x.Value -ne 0){$lines.Add("HR:$($x.Key)=$($x.Value)")}}
    foreach($x in $engine.Coils.GetEnumerator()|Sort-Object Key){if($x.Value){$lines.Add("C:$($x.Key)=1")}}
    [IO.File]::WriteAllLines($tmp,$lines,[Text.UTF8Encoding]::new($false));Move-Item $tmp $stateFile -Force
}
function Load-State {
    if(!(Test-Path $stateFile)){return};foreach($line in [IO.File]::ReadAllLines($stateFile)){
        if($line -match '^HR:(\d+)=(\d+)$'){$engine.Holding[[int]$matches[1]]=[uint16]$matches[2]}
        elseif($line -match '^C:(\d+)=(0|1)$'){$engine.Coils[[int]$matches[1]]=($matches[2]-eq '1')}
    }
}
Load-State

$form=New-Object Windows.Forms.Form
$form.Text='Modbus TCP Server Monitor'
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
[void]$tool.Items.AddRange(@($btnStart,$btnStop,(New-Object Windows.Forms.ToolStripSeparator),$btnClear,$btnFolder,$btnSave))
$root.Controls.Add($tool,0,0)

$status=New-Object Windows.Forms.Label
$status.Dock='Fill'
$status.BackColor=[Drawing.Color]::FromArgb(30,72,120)
$status.ForeColor='White'
$status.Font=New-Object Drawing.Font('Consolas',10,[Drawing.FontStyle]::Bold)
$status.Padding=New-Object Windows.Forms.Padding(12,8,12,8)
$status.TextAlign='MiddleLeft'
$root.Controls.Add($status,0,1)

# Main workspace: unchanged real-time traffic on the left, operational data on the right.
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
# The vertical split is also sized after the form is displayed.
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

$recentChanges=[Collections.Generic.Queue[object]]::new()
function Add-Traffic([string]$line,[Drawing.Color]$color){$traffic.SelectionStart=$traffic.TextLength;$traffic.SelectionLength=0;$traffic.SelectionColor=$color;$traffic.AppendText($line+[Environment]::NewLine);if($traffic.TextLength -gt 500000){$traffic.Select(0,100000);$traffic.SelectedText=''};$traffic.SelectionStart=$traffic.TextLength;$traffic.ScrollToCaret()}
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

function Start-Server {try{$engine.Start($BindAddress);$btnStart.Enabled=$false;$btnStop.Enabled=$true}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Start error','OK','Error')|Out-Null}}
function Stop-Server {$engine.Stop();$btnStart.Enabled=$true;$btnStop.Enabled=$false}
$btnStart.Add_Click({Start-Server});$btnStop.Add_Click({Stop-Server});$btnClear.Add_Click({$traffic.Clear()});$btnFolder.Add_Click({Start-Process explorer.exe $base});$btnSave.Add_Click({Save-State})

$timer=New-Object Windows.Forms.Timer;$timer.Interval=150
$timer.Add_Tick({
    $evt=$null;$processed=0
    while($processed -lt 500 -and $engine.Events.TryDequeue([ref]$evt)){
        $processed++;$line='{0:yyyy-MM-dd HH:mm:ss.fff} | {1,-10} | {2} | {3}' -f $evt.Time,$evt.Type,$evt.Client,$evt.Message
        Append-FileLine $allLog $line
        $color=switch($evt.Type){'RX'{[Drawing.Color]::Goldenrod}'TX'{[Drawing.Color]::DeepSkyBlue}'CHANGE'{[Drawing.Color]::LimeGreen}'ERROR'{[Drawing.Color]::Tomato}'WARN'{[Drawing.Color]::Orange}default{[Drawing.Color]::Silver}}
        Add-Traffic $line $color
        if($evt.Type -eq 'CHANGE'){
            Append-FileLine $changeLog $line;$recentChanges.Enqueue([pscustomobject]@{Time=$evt.Time.ToString('HH:mm:ss');Client=$evt.Client;Value=$evt.Message});while($recentChanges.Count -gt 500){[void]$recentChanges.Dequeue()};Save-State
        }
    }
    $clients.BeginUpdate();$clients.Items.Clear()
    foreach($x in $engine.Clients.Values|Sort-Object Endpoint){
        $item=[Windows.Forms.ListViewItem]::new($x.Endpoint)
        [void]$item.SubItems.Add([string]$x.RxFrames)
        [void]$item.SubItems.Add([string]$x.TxFrames)
        [void]$item.SubItems.Add([string]$x.RxBytes)
        [void]$item.SubItems.Add([string]$x.TxBytes)
        [void]$item.SubItems.Add([string]$x.Reads)
        [void]$item.SubItems.Add([string]$x.Writes)
        [void]$item.SubItems.Add($x.LastSeen.ToString('HH:mm:ss'))
        [void]$clients.Items.Add($item)
    }
    $clients.EndUpdate()
    $changes.BeginUpdate();$changes.Items.Clear()
    foreach($x in $recentChanges){
        $item=[Windows.Forms.ListViewItem]::new([string]$x.Time)
        [void]$item.SubItems.Add([string]$x.Client)
        [void]$item.SubItems.Add([string]$x.Value)
        [void]$changes.Items.Add($item)
    }
    $changes.EndUpdate()
    if($changes.Items.Count){$changes.EnsureVisible($changes.Items.Count-1)}
    $up=if($engine.Started -gt [datetime]::MinValue){(Get-Date)-$engine.Started}else{[timespan]::Zero}
    $status.Text='PORT {0}  |  STATUS {1}  |  UPTIME {2:00}:{3:00}:{4:00}  |  CLIENTS {5}/{6}  |  CONNECTIONS {7}  |  RX {8} frames / {9} bytes  |  TX {10} frames / {11} bytes  |  READS {12}  |  WRITES {13}  |  ERRORS {14}' -f $Port,$(if($btnStop.Enabled){'RUNNING'}else{'STOPPED'}),[int]$up.TotalHours,$up.Minutes,$up.Seconds,$engine.Clients.Count,$MaxClients,$engine.TotalConnections,$engine.TotalRxFrames,$engine.TotalRxBytes,$engine.TotalTxFrames,$engine.TotalTxBytes,$engine.TotalReads,$engine.TotalWrites,$engine.TotalErrors
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
$form.Add_FormClosing({$timer.Stop();try{Save-State}catch{};$engine.Dispose()})
[void]$form.ShowDialog()
