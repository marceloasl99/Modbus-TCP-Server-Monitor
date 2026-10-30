<#
.SYNOPSIS
    Headless tests for the Modbus engine embedded in ModbusTcpServerMonitor.ps1.
.DESCRIPTION
    Extracts the C# engine from the script, compiles it and exercises it over real TCP sockets
    on the loopback interface. No GUI is opened and no external module (Pester, etc.) is needed.
    Exit code 0 when every test passes, 1 otherwise.
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-EngineTests.ps1
#>
param([string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'ModbusTcpServerMonitor.ps1'))

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not ('ModbusEngine' -as [type])) {
    $text = [IO.File]::ReadAllText($ScriptPath)
    $m = [regex]::Match($text, "(?s)\`$source = @'\r?\n(.*?)\r?\n'@")
    if (-not $m.Success) { throw "Could not find the C# engine block in $ScriptPath" }
    Add-Type -TypeDefinition $m.Groups[1].Value -Language CSharp
}

$script:passed = 0; $script:failed = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "[PASS] $Name" -ForegroundColor Green }
    catch { $script:failed++; Write-Host "[FAIL] $Name`n       $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-Equal($Expected, $Actual, [string]$What) {
    if ("$Expected" -ne "$Actual") { throw "$What - expected '$Expected' but got '$Actual'" }
}
function Assert-True($Condition, [string]$What) { if (-not $Condition) { throw $What } }

function Get-FreePort {
    $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start()
    $p = $l.LocalEndpoint.Port; $l.Stop(); $p
}
function New-Engine([int]$MaxClients = 5, [int]$Size = 1000, [int]$IdleTimeoutMs = 0) {
    $e = [ModbusEngine]::new((Get-FreePort), $MaxClients, $Size); $e.IdleTimeoutMs = $IdleTimeoutMs
    $e.Start('127.0.0.1'); $e
}
function Connect-Client([ModbusEngine]$Engine) { [Net.Sockets.TcpClient]::new('127.0.0.1', $Engine.Port) }
# Sends a PDU wrapped in an MBAP header (unit id 1) and returns the response PDU as "XX XX ..." or $null when the socket closed/timed out.
function Send-Pdu([Net.Sockets.TcpClient]$Client, [byte[]]$Pdu, [int]$Tid = 1, [int]$ProtocolId = 0) {
    $s = $Client.GetStream(); $len = $Pdu.Length + 1
    $frame = [byte[]]@(($Tid -shr 8), ($Tid -band 255), ($ProtocolId -shr 8), ($ProtocolId -band 255), ($len -shr 8), ($len -band 255), 1) + $Pdu
    $s.Write($frame, 0, $frame.Length)
    $buf = New-Object byte[] 300; $s.ReadTimeout = 1500
    try { $n = $s.Read($buf, 0, $buf.Length) } catch { return $null }
    if ($n -le 7) { return $null }
    [BitConverter]::ToString($buf, 7, $n - 7).Replace('-', ' ')
}
function Get-Events([ModbusEngine]$Engine) {
    Start-Sleep -Milliseconds 150
    $list = @(); $ev = $null
    while ($Engine.TryDequeueEvent([ref]$ev)) { $list += $ev }
    $list
}

Test-Case 'FC03 with quantity > 125 returns exception 03 (illegal data value)' {
    $e = New-Engine; try { $c = Connect-Client $e; Assert-Equal '83 03' (Send-Pdu $c ([byte[]]@(3, 0, 0, 0, 200))) 'response'; $c.Close() } finally { $e.Dispose() }
}
Test-Case 'FC01 with quantity 0 returns exception 03' {
    $e = New-Engine; try { $c = Connect-Client $e; Assert-Equal '81 03' (Send-Pdu $c ([byte[]]@(1, 0, 0, 0, 0))) 'response'; $c.Close() } finally { $e.Dispose() }
}
Test-Case 'FC03 outside the address space returns exception 02 (illegal data address)' {
    $e = New-Engine; try { $c = Connect-Client $e; Assert-Equal '83 02' (Send-Pdu $c ([byte[]]@(3, 0x0F, 0xFF, 0, 1))) 'response'; $c.Close() } finally { $e.Dispose() }
}
Test-Case 'FC16 outside the address space returns exception 02' {
    $e = New-Engine; try { $c = Connect-Client $e; Assert-Equal '90 02' (Send-Pdu $c ([byte[]]@(16, 0x0F, 0xFF, 0, 1, 2, 0, 1))) 'response'; $c.Close() } finally { $e.Dispose() }
}
Test-Case 'Unsupported function returns exception 01 and emits an EXCEPTION event' {
    $e = New-Engine; try {
        $c = Connect-Client $e
        Assert-Equal 'AB 01' (Send-Pdu $c ([byte[]]@(0x2B, 0x0E, 1, 0))) 'response'
        $ex = @(Get-Events $e | Where-Object Type -eq 'EXCEPTION'); Assert-Equal 1 $ex.Count 'EXCEPTION events'
        Assert-Equal 1 $e.TotalExceptions 'TotalExceptions'; $c.Close()
    } finally { $e.Dispose() }
}
Test-Case 'FC06 write is echoed, read back by FC03, and a repeated identical write is WRITE not CHANGE' {
    $e = New-Engine; try {
        $c = Connect-Client $e
        Assert-Equal '06 00 05 04 D2' (Send-Pdu $c ([byte[]]@(6, 0, 5, 4, 0xD2))) 'FC06 echo'
        Assert-Equal '03 02 04 D2' (Send-Pdu $c ([byte[]]@(3, 0, 5, 0, 1))) 'FC03 read back'
        [void](Send-Pdu $c ([byte[]]@(6, 0, 5, 4, 0xD2)))
        $ev = Get-Events $e
        Assert-Equal 1 @($ev | Where-Object Type -eq 'CHANGE').Count 'CHANGE events'
        Assert-Equal 1 @($ev | Where-Object Type -eq 'WRITE').Count 'WRITE events'
        Assert-Equal 2 $e.TotalWrites 'TotalWrites'; $c.Close()
    } finally { $e.Dispose() }
}
Test-Case 'FC16 writes multiple registers and FC03 reads them back' {
    $e = New-Engine; try {
        $c = Connect-Client $e
        Assert-Equal '10 00 0A 00 03' (Send-Pdu $c ([byte[]]@(16, 0, 10, 0, 3, 6, 0, 1, 0, 2, 0, 3))) 'FC16 response'
        Assert-Equal '03 06 00 01 00 02 00 03' (Send-Pdu $c ([byte[]]@(3, 0, 10, 0, 3))) 'FC03 read back'
        $ch = @(Get-Events $e | Where-Object Type -eq 'CHANGE'); Assert-Equal 1 $ch.Count 'CHANGE events'
        Assert-True ($ch[0].Message -like '*3 of 3 changed*') "message was '$($ch[0].Message)'"; $c.Close()
    } finally { $e.Dispose() }
}
Test-Case 'FC15/FC05 write coils and FC01 reads the bit pattern back' {
    $e = New-Engine; try {
        $c = Connect-Client $e
        Assert-Equal '0F 00 00 00 0A' (Send-Pdu $c ([byte[]]@(15, 0, 0, 0, 10, 2, 0xCD, 0x01))) 'FC15 response'
        Assert-Equal '05 00 0B FF 00' (Send-Pdu $c ([byte[]]@(5, 0, 11, 0xFF, 0))) 'FC05 response'
        Assert-Equal '01 02 CD 09' (Send-Pdu $c ([byte[]]@(1, 0, 0, 0, 12))) 'FC01 read back'
        Assert-Equal '85 03' (Send-Pdu $c ([byte[]]@(5, 0, 1, 0x12, 0x34))) 'FC05 invalid value'; $c.Close()
    } finally { $e.Dispose() }
}
Test-Case 'Start can be retried after a failed Start (port busy)' {
    $port = Get-FreePort
    $blocker = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port); $blocker.Start()
    $e = [ModbusEngine]::new($port, 5, 1000)
    try {
        $threw = $false; try { $e.Start('127.0.0.1') } catch { $threw = $true }
        Assert-True $threw 'first Start should throw while the port is busy'
        Assert-True (-not $e.IsRunning) 'IsRunning should be false after a failed Start'
        $blocker.Stop()
        $e.Start('127.0.0.1'); Assert-True $e.IsRunning 'IsRunning after retry'
        $c = Connect-Client $e; Assert-Equal '03 02 00 00' (Send-Pdu $c ([byte[]]@(3, 0, 0, 0, 1))) 'request after retry'; $c.Close()
    } finally { $e.Dispose(); try { $blocker.Stop() } catch {} }
}
Test-Case 'Stop closes connected clients and removes them from the client table' {
    $e = New-Engine; try {
        $c = Connect-Client $e; [void](Send-Pdu $c ([byte[]]@(3, 0, 0, 0, 1)))
        Assert-Equal 1 $e.Clients.Count 'clients before Stop'
        $e.Stop()
        Assert-Equal 0 $e.Clients.Count 'clients after Stop'
        $s = $c.GetStream(); $s.ReadTimeout = 1000; $buf = New-Object byte[] 16
        $n = try { $s.Read($buf, 0, 16) } catch { -1 }
        Assert-Equal 0 $n 'client read should return 0 (socket closed by server)'
        $types = @(Get-Events $e | ForEach-Object Type)
        Assert-True ($types -contains 'DISCONNECT') 'DISCONNECT event'; Assert-True ($types[-1] -eq 'SERVER') 'last event is SERVER Stopped'; $c.Close()
    } finally { $e.Dispose() }
}
Test-Case 'Idle clients are disconnected after IdleTimeoutMs' {
    $e = New-Engine -IdleTimeoutMs 500; try {
        $c = Connect-Client $e; Start-Sleep -Milliseconds 1500
        Assert-Equal 0 $e.Clients.Count 'clients after idle period'
        $ev = Get-Events $e
        Assert-True (@($ev | Where-Object { $_.Type -eq 'WARN' -and $_.Message -like '*idle*' }).Count -eq 1) 'WARN idle event'
        Assert-True (@($ev | Where-Object { $_.Type -eq 'DISCONNECT' -and $_.Message -like '*idle*' }).Count -eq 1) 'DISCONNECT idle reason'; $c.Close()
    } finally { $e.Dispose() }
}
Test-Case 'Connections above MaxClients are rejected with a WARN event' {
    $e = New-Engine -MaxClients 1; try {
        $c1 = Connect-Client $e; [void](Send-Pdu $c1 ([byte[]]@(3, 0, 0, 0, 1)))
        $c2 = Connect-Client $e
        Assert-True ($null -eq (Send-Pdu $c2 ([byte[]]@(3, 0, 0, 0, 1)))) 'second client should get no response'
        Assert-True (@(Get-Events $e | Where-Object { $_.Type -eq 'WARN' -and $_.Message -like 'Rejected*' }).Count -eq 1) 'WARN rejected event'
        $c1.Close(); $c2.Close()
    } finally { $e.Dispose() }
}
Test-Case 'Invalid MBAP protocol id closes the connection with a WARN' {
    $e = New-Engine; try {
        $c = Connect-Client $e
        Assert-True ($null -eq (Send-Pdu $c ([byte[]]@(3, 0, 0, 0, 1)) -ProtocolId 1)) 'no response expected'
        Start-Sleep -Milliseconds 200; Assert-Equal 0 $e.Clients.Count 'client removed'
        Assert-True (@(Get-Events $e | Where-Object { $_.Type -eq 'WARN' -and $_.Message -like 'Invalid MBAP*' }).Count -eq 1) 'WARN event'; $c.Close()
    } finally { $e.Dispose() }
}
Test-Case 'SetValue / ExportState / ImportStateLine round-trip, invalid lines are reported' {
    $e = [ModbusEngine]::new((Get-FreePort), 5, 100)
    [void]$e.SetValue('HR', 4, 1234); [void]$e.SetValue('IR', 9, 7); [void]$e.SetValue('C', 7, 1); [void]$e.SetValue('DI', 0, 1)
    $lines = $e.ExportState()
    Assert-Equal 'HR:4=1234|IR:9=7|C:7=1|DI:0=1' ($lines -join '|') 'exported lines'
    Assert-Equal 4 @(Get-Events $e | Where-Object Type -eq 'CHANGE').Count 'CHANGE events from SetValue'
    $e2 = [ModbusEngine]::new((Get-FreePort), 5, 100)
    foreach ($l in $lines) { Assert-True ($null -eq $e2.ImportStateLine($l)) "import '$l'" }
    Assert-Equal ($lines -join '|') ($e2.ExportState() -join '|') 're-exported lines'
    Assert-Equal '' $e2.ImportStateLine('# comment') 'comment line is skipped'
    Assert-True ($e2.ImportStateLine('HR:5=70000') -like '*out of range*') 'value out of range reported'
    Assert-True ($e2.ImportStateLine('HR:500=1') -like '*outside the address space*') 'address out of range reported'
    Assert-True ($e2.ImportStateLine('XX:1=1') -like '*unknown area*') 'unknown area reported'
    $threw = $false; try { [void]$e.SetValue('C', 1, 5) } catch { $threw = $true }; Assert-True $threw 'SetValue rejects coil value 5'
    $e.Dispose(); $e2.Dispose()
}

Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:passed, $script:failed) -ForegroundColor $(if ($script:failed) { 'Red' } else { 'Green' })
exit $(if ($script:failed) { 1 } else { 0 })
