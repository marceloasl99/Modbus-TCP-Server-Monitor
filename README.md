# Modbus TCP Server Monitor

A Windows PowerShell Modbus TCP server simulator with a responsive real-time GUI for monitoring client connections, Modbus traffic, packet counters, register and coil writes, persistent values, and session logs.

> Windows PowerShell Modbus TCP server with real-time traffic monitoring, active-client statistics, RX/TX packet counters, address/value change tracking, persistent values, and TXT session logs.

<img width="1920" height="1147" alt="photo_2026-07-13_09-56-48" src="https://github.com/user-attachments/assets/9aaaad4a-09dd-402a-80c2-02a939bbbb63" />

## Overview

**Modbus TCP Server Monitor** is a standalone PowerShell application for Windows. It starts a Modbus TCP server and displays live operational information in a graphical interface without requiring an external PowerShell module or third-party library.

The GUI keeps the live Modbus traffic visible on the left side while a dedicated right-side column shows:

- Active clients.
- RX and TX packet counts per client.
- RX and TX byte counts per client.
- Read and write counts per client.
- Last activity time.
- Recently changed Modbus addresses and values.

The application also creates a complete session log, a separate value-change log, and a persistent data file containing non-zero holding registers and active coils.

## Main features

### Modbus TCP server

- Configurable TCP listening port.
- Configurable bind address.
- Configurable maximum number of simultaneous clients.
- Configurable Modbus address-space size.
- Multiple concurrent Modbus TCP clients.
- Asynchronous socket processing to keep the GUI responsive.
- TCP frame reassembly using the complete MBAP header and PDU length.
- Modbus exception responses for unsupported functions and invalid requests.
- Unit ID from the request is preserved in the response.

### Supported Modbus functions

- **FC01** — Read Coils.
- **FC02** — Read Discrete Inputs.
- **FC03** — Read Holding Registers.
- **FC04** — Read Input Registers.
- **FC05** — Write Single Coil.
- **FC06** — Write Single Holding Register.
- **FC15** — Write Multiple Coils.
- **FC16** — Write Multiple Holding Registers.

### Real-time traffic view

The left side of the GUI continuously displays:

- Server start and stop events.
- Client connections and disconnections.
- RX Modbus TCP frames in hexadecimal.
- TX Modbus TCP frames in hexadecimal.
- Read operations.
- Address and value changes.
- Warnings.
- Errors.

The traffic view keeps automatic scrolling enabled and limits the amount of text retained in the GUI to avoid progressive interface slowdown. The complete history remains available in the session TXT log.

### Active-client panel

The upper-right panel shows one row per connected client with:

- Client endpoint in `IP:port` format.
- RX packet count.
- TX packet count.
- RX byte count.
- TX byte count.
- Read count.
- Write count.
- Last-seen time.

### Changed-address panel

The lower-right panel records recent write operations with:

- Time.
- Client endpoint.
- Address and value information.

Examples:

```text
09:25:12 | 192.168.1.50:50120 | Coil 10 = 1
09:25:15 | 192.168.1.50:50120 | Holding 25 : 0 -> 1500
09:26:10 | 192.168.1.50:50120 | Coils 10..20 updated (11)
09:26:15 | 192.168.1.50:50120 | Holding 100..110 updated (11)
```

### Global statistics

The status bar displays:

- Listening port.
- Running or stopped state.
- Uptime.
- Active clients and configured client limit.
- Total accepted connections.
- Total RX frames and bytes.
- Total TX frames and bytes.
- Total read operations.
- Total write operations.
- Total errors.

## Requirements

- Windows 10, Windows 11, or Windows Server with Windows Forms support.
- Windows PowerShell 5.1 is recommended.
- Permission to listen on the selected TCP port.
- Network/firewall rules allowing the required inbound connection.

No additional PowerShell module is required.

## Project structure

```text
modbus-tcp-server-monitor/
├── ModbusTcpServerMonitor.ps1
├── README.md
└── .gitignore
```

Files generated at runtime are excluded by `.gitignore`.

## Quick start

Open PowerShell in the project directory and unblock the downloaded script if required:

```powershell
Unblock-File -Path ".\ModbusTcpServerMonitor.ps1"
```

Run the application:

```powershell
.\ModbusTcpServerMonitor.ps1
```

If the current execution policy blocks unsigned scripts, run it for a single process without changing the permanent machine policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\ModbusTcpServerMonitor.ps1"
```

## Command-line parameters

```powershell
.\ModbusTcpServerMonitor.ps1 `
    -Port 502 `
    -MaxClients 50 `
    -AddressSpaceSize 10000 `
    -BindAddress "0.0.0.0"
```

### `-Port`

TCP port used by the Modbus server.

Default:

```text
502
```

Example using a non-standard test port:

```powershell
.\ModbusTcpServerMonitor.ps1 -Port 1502
```

### `-MaxClients`

Maximum number of simultaneous TCP clients.

Default:

```text
50
```

Valid range:

```text
1 to 200
```

### `-AddressSpaceSize`

Number of available addresses in each Modbus data area.

Default:

```text
10000
```

Valid range:

```text
100 to 65536
```

### `-BindAddress`

Local IP address on which the server listens.

Default:

```text
0.0.0.0
```

`0.0.0.0` listens on all available IPv4 interfaces. To restrict the listener to one interface:

```powershell
.\ModbusTcpServerMonitor.ps1 -BindAddress "192.168.1.20" -Port 502
```

## Using TCP port 502

TCP port `502` is the standard Modbus TCP port. Depending on the Windows configuration and security policies, opening this port may require an elevated PowerShell session.

For a first functional test, use port `1502`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File ".\ModbusTcpServerMonitor.ps1" `
    -Port 1502
```

Configure the Modbus client with the same destination port.

## Windows Firewall

If remote clients cannot connect, verify that Windows Firewall allows inbound TCP traffic on the selected port.

Example for TCP port `1502`, executed from an elevated PowerShell session:

```powershell
New-NetFirewallRule `
    -DisplayName "Modbus TCP Server Monitor 1502" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 1502 `
    -Action Allow
```

Remove the example rule when no longer required:

```powershell
Remove-NetFirewallRule -DisplayName "Modbus TCP Server Monitor 1502"
```

Apply firewall changes only according to the security policy of the environment.

## GUI controls

### Start

Starts the Modbus TCP listener.

### Stop

Stops the listener and prevents new connections.

### Clear traffic

Clears only the traffic text displayed in the GUI. It does not delete the session log.

### Open log folder

Opens the directory containing the script and generated log files.

### Save values now

Immediately writes the current non-zero holding registers and active coils to the persistent values file.

## Generated files

All generated files are created in the same directory as the PowerShell script.

### Complete session log

```text
modbus_session_YYYYMMDD_HHMMSS.txt
```

The session log includes:

- Server events.
- Connections and disconnections.
- RX frames.
- TX frames.
- Reads.
- Changes.
- Warnings.
- Errors.

Example:

```text
2026-07-13 09:10:20.125 | CONNECT    | 192.168.1.50:52144 | Connected
2026-07-13 09:10:20.141 | RX         | 192.168.1.50:52144 | 00 01 00 00 00 06 01 03 00 00 00 02
2026-07-13 09:10:20.143 | READ       | 192.168.1.50:52144 | Read Holding Registers start=1 qty=2
2026-07-13 09:10:20.145 | TX         | 192.168.1.50:52144 | 00 01 00 00 00 07 01 03 04 00 00 00 00
```

### Value-change log

```text
modbus_changes_YYYYMMDD_HHMMSS.txt
```

This file contains write/change events only.

Example:

```text
2026-07-13 09:12:04.310 | CHANGE | 192.168.1.50:52144 | Holding 10 : 0 -> 1500
2026-07-13 09:12:10.582 | CHANGE | 192.168.1.50:52144 | Coil 25 = 1
```

### Persistent values

```text
modbus_values.txt
```

This file stores:

- Non-zero holding registers.
- Coils in the ON state.

Example:

```text
HR:9=1500
HR:99=25
C:24=1
```

The stored addresses are internal zero-based addresses. The GUI and operational messages display addresses as one-based values.

## Addressing behavior

Modbus protocol addresses are zero-based. For operator readability, the GUI and logs display addresses beginning at `1`.

Example:

```text
Protocol address 0 → Displayed address 1
Protocol address 9 → Displayed address 10
```

The persistence file keeps the internal zero-based address.

## Testing with a Modbus client

Example client configuration:

```text
Host: IP address of the Windows computer running the script
Port: 502 or the custom port selected at startup
Unit ID: 1
Protocol: Modbus TCP
```

Suggested initial tests:

1. Read holding registers starting at protocol address `0`.
2. Write one holding register using FC06.
3. Confirm the change in the right-side panel.
4. Confirm the event in the session and change logs.
5. Read the register again and verify the returned value.
6. Write and read a coil using FC05 and FC01.

## Performance and responsiveness

- TCP client processing runs outside the Windows Forms UI thread.
- Events are transferred to the GUI through a concurrent queue.
- The GUI processes a bounded number of queued events per update cycle.
- The on-screen traffic buffer is trimmed when it becomes large.
- Complete history remains in the TXT session log.
- The right-side client counters and changes are updated without replacing the real-time traffic view.

Very high polling rates from many clients can still generate a large amount of disk I/O because every event is written to the session log.

## Troubleshooting

### The script is not digitally signed

Unblock the downloaded file:

```powershell
Unblock-File -Path ".\ModbusTcpServerMonitor.ps1"
```

Or run only the current process with execution-policy bypass:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\ModbusTcpServerMonitor.ps1"
```

### The server cannot start on port 502

Try an elevated PowerShell session or use port `1502`:

```powershell
.\ModbusTcpServerMonitor.ps1 -Port 1502
```

Also verify that another process is not already using the selected port:

```powershell
Get-NetTCPConnection -LocalPort 502 -ErrorAction SilentlyContinue
```

### A remote client cannot connect

Check:

- The correct server IP address.
- The same TCP port on the server and client.
- The `BindAddress` parameter.
- Windows Firewall.
- Network ACLs and routing.
- Whether the server status is `RUNNING`.

### RX/TX counters change but values do not

The client may be performing only read requests. Value changes occur only with supported write functions:

```text
FC05
FC06
FC15
FC16
```

### No value-change entry appears

Confirm that the write request is valid and that the requested address is inside the configured address space.

### Large traffic volume

Use **Clear traffic** to clear the visible buffer. The session log remains complete. If disk growth becomes a concern, archive or remove old `modbus_session_*.txt` and `modbus_changes_*.txt` files when the server is stopped.

## Security and operational considerations

This project is a test and monitoring server, not a hardened industrial controller.

- Run it only on authorized systems and networks.
- Do not expose the listener directly to the public Internet.
- Restrict inbound access with Windows Firewall and network ACLs.
- Use a non-production VLAN or laboratory environment for testing.
- Review generated logs before sharing because client IP addresses and Modbus traffic may be present.
- Stop the server when testing is complete.

## Repository topics

Suggested GitHub topics:

```text
modbus
modbus-tcp
powershell
windows-forms
industrial-automation
ot
scada
plc
network-monitoring
protocol-simulator
```

## License

No license is included. Add a license before allowing redistribution or reuse under defined terms.
'''
cat > "$project/.gitignore" <<'EOF'
# Runtime session logs
modbus_session_*.txt
modbus_changes_*.txt

# Persistent runtime values
modbus_values.txt
modbus_values.txt.tmp

# PowerShell and editor temporary files
*.tmp
*.bak
*.log
.vscode/
.idea/

# Windows metadata
Thumbs.db
Desktop.ini
