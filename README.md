# Modbus TCP Server Monitor

A Windows PowerShell Modbus TCP server simulator with a responsive real-time GUI for monitoring client connections, Modbus traffic, packet counters, register and coil writes, persistent values, and session logs.

> Windows PowerShell Modbus TCP server with real-time traffic monitoring, active-client statistics, RX/TX packet counters, address/value change tracking, persistent values, and TXT session logs.

<img width="1920" height="1147" alt="Modbus TCP Server Monitor main window" src="https://github.com/user-attachments/assets/9aaaad4a-09dd-402a-80c2-02a939bbbb63" />

## Overview

**Modbus TCP Server Monitor** is a standalone PowerShell application for Windows. It starts a Modbus TCP server and displays live operational information in a graphical interface without requiring an external PowerShell module or third-party library. The whole application is a single `.ps1` file; the protocol engine is C# compiled in memory at startup.

The GUI keeps the live Modbus traffic visible on the left side while a dedicated right-side column shows:

- Active clients.
- RX and TX packet counts per client.
- RX and TX byte counts per client.
- Read and write counts per client.
- Last activity time.
- Recently changed Modbus addresses and values.

The application also creates a complete session log, a separate value-change log, and a persistent data file containing the current non-zero registers and active coils/discrete inputs.

## Main features

### Modbus TCP server

- Configurable TCP listening port and bind address.
- Configurable maximum number of simultaneous clients.
- Configurable Modbus address-space size.
- Configurable idle timeout; idle clients are disconnected and their slot is released.
- Multiple concurrent Modbus TCP clients.
- Asynchronous socket processing to keep the GUI responsive.
- TCP frame reassembly using the complete MBAP header and PDU length.
- Modbus exception responses for unsupported functions and invalid requests, with the exception codes defined by the Modbus Application Protocol specification.
- Multi-register reads and writes are atomic with respect to each other.
- Unit ID from the request is preserved in the response. The Unit ID is not filtered: every Unit ID is served by the same data tables.

### Supported Modbus functions

- **FC01** — Read Coils.
- **FC02** — Read Discrete Inputs.
- **FC03** — Read Holding Registers.
- **FC04** — Read Input Registers.
- **FC05** — Write Single Coil.
- **FC06** — Write Single Holding Register.
- **FC15** — Write Multiple Coils.
- **FC16** — Write Multiple Holding Registers.

Any other function code receives exception `01` (illegal function).

### Real-time traffic view

The left side of the GUI continuously displays one line per event:

| Type | Colour | Meaning |
|---|---|---|
| `SERVER` | grey | Server started/stopped, persistent values loaded. |
| `CONNECT` / `DISCONNECT` | light blue | Client connected or disconnected (with the reason: client closed, idle timeout, server stopped, invalid frame, error). |
| `RX` | yellow | Request frame in hexadecimal. |
| `TX` | blue | Response frame in hexadecimal. |
| `READ` | grey | A successful read request (function, start address, quantity). |
| `CHANGE` | green | A write that changed at least one value. |
| `WRITE` | dark grey | A write whose values were already equal to the current ones. |
| `EXCEPTION` | violet | A request answered with a Modbus exception, with the exception code and its meaning. |
| `WARN` | orange | Rejected connection, invalid MBAP header, idle timeout, ignored persistence line, dropped events. |
| `ERROR` | red | Socket or internal error. |

The traffic view limits the amount of text retained in the GUI to avoid progressive interface slowdown. The complete history remains available in the session TXT log.

**Pause view** freezes the traffic view so it can be read; logging, counters and the right-side panels keep running, and the pending lines are shown when the view is resumed. **Show RX/TX frames** hides the hexadecimal frames from the view; they are still written to the session log.

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

Rows are updated in place, so selection and scroll position are preserved while counters change.

### Changed-address panel

The lower-right panel records recent write operations that changed a value, with time, client endpoint and the address/value information. Writes made from the **Set value** toolbar appear with the client `local`.

Examples:

```text
09:25:12 | 192.168.1.50:50120 | Coil 10 = 1
09:25:15 | 192.168.1.50:50120 | Holding 25 : 0 -> 1500
09:26:10 | 192.168.1.50:50120 | Coils 10..20 written (11 of 11 changed)
09:26:15 | 192.168.1.50:50120 | Holding 100..110 written (3 of 11 changed)
09:27:01 | local              | Input register 7 : 0 -> 250
```

### Set value toolbar

Values can be written locally from the toolbar, without a Modbus client:

1. Choose the area: `HR` (holding register), `IR` (input register), `C` (coil) or `DI` (discrete input).
2. Type the address as displayed in the GUI (one-based).
3. Type the value: `0..65535` for registers, `0` or `1` for coils and discrete inputs.
4. Click **Apply**.

This is the way to populate input registers and discrete inputs, which Modbus clients can only read.

### Global statistics

The status bar displays:

- Listening port and bind address.
- Running or stopped state and uptime.
- Active clients and configured client limit, total accepted connections, idle timeout.
- Total RX and TX frames and bytes.
- Total read operations, write operations, Modbus exception responses and errors.
- Number of dropped events, if the GUI could not keep up (see *Performance*).

## Requirements

- Windows 10, Windows 11, or Windows Server with Windows Forms support.
- Windows PowerShell 5.1 (the script is also expected to work on PowerShell 7 on Windows).
- Permission to listen on the selected TCP port.
- Network/firewall rules allowing the required inbound connection.

No additional PowerShell module is required.

## Project structure

```text
Modbus-TCP-Server-Monitor/
├── ModbusTcpServerMonitor.ps1    # the application (GUI + embedded C# engine)
├── tests/
│   └── Invoke-EngineTests.ps1    # headless engine tests over loopback TCP
├── README.md
├── CHANGELOG.md
├── LICENSE
└── .gitignore
```

Files generated at runtime (`modbus_session_*.txt`, `modbus_changes_*.txt`, `modbus_values.txt`) are excluded by `.gitignore`.

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

The server starts automatically when the window opens. If the port cannot be opened, an error is shown and **Start** can be clicked again once the cause is fixed.

## Command-line parameters

```powershell
.\ModbusTcpServerMonitor.ps1 `
    -Port 502 `
    -MaxClients 50 `
    -AddressSpaceSize 10000 `
    -BindAddress "0.0.0.0" `
    -IdleTimeoutSeconds 60
```

| Parameter | Default | Range | Description |
|---|---|---|---|
| `-Port` | `502` | 1–65535 | TCP port used by the Modbus server. |
| `-MaxClients` | `50` | 1–200 | Maximum number of simultaneous TCP clients. Additional connections are closed immediately and a `WARN` event is logged. |
| `-AddressSpaceSize` | `10000` | 100–65536 | Number of addresses in each Modbus data area (coils, discrete inputs, holding registers, input registers). |
| `-BindAddress` | `0.0.0.0` | IPv4 address | Local IP address on which the server listens. `0.0.0.0` listens on all IPv4 interfaces. |
| `-IdleTimeoutSeconds` | `60` | 0–86400 | A client that sends nothing for this long is disconnected and its slot released. `0` disables the timeout. |

Examples:

```powershell
# Non-standard test port
.\ModbusTcpServerMonitor.ps1 -Port 1502

# One interface only, no idle timeout
.\ModbusTcpServerMonitor.ps1 -BindAddress "192.168.1.20" -Port 502 -IdleTimeoutSeconds 0
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

| Control | Action |
|---|---|
| **Start** | Starts the Modbus TCP listener. |
| **Stop** | Stops the listener, closes every connected client and prevents new connections. |
| **Clear traffic** | Clears only the traffic text displayed in the GUI. It does not delete the session log. |
| **Open log folder** | Opens the directory containing the script and generated files. |
| **Save values now** | Immediately writes the current values to the persistent values file. |
| **Pause view** | Freezes the traffic view; pending lines are shown when the view is resumed. |
| **Show RX/TX frames** | Shows or hides the hexadecimal frames in the traffic view. |
| **Set value** | Writes a register, coil or discrete input locally (see above). |

## Generated files

All generated files are created in the same directory as the PowerShell script.

### Complete session log

```text
modbus_session_YYYYMMDD_HHMMSS.txt
```

The session log includes every event type listed under *Real-time traffic view*.

Example:

```text
2026-07-13 09:10:20.125 | CONNECT    | 192.168.1.50:52144 | Connected
2026-07-13 09:10:20.141 | RX         | 192.168.1.50:52144 | 00 01 00 00 00 06 01 03 00 00 00 02
2026-07-13 09:10:20.143 | READ       | 192.168.1.50:52144 | Read Holding Registers start=1 qty=2
2026-07-13 09:10:20.145 | TX         | 192.168.1.50:52144 | 00 01 00 00 00 07 01 03 04 00 00 00 00
2026-07-13 09:10:25.002 | EXCEPTION  | 192.168.1.50:52144 | Read Holding Registers start=1 qty=200 -> exception 3 (Illegal data value)
2026-07-13 09:11:30.410 | WARN       | 192.168.1.50:52144 | No data received for 60 s; closing idle connection
2026-07-13 09:11:30.411 | DISCONNECT | 192.168.1.50:52144 | Closed: idle timeout
```

### Value-change log

```text
modbus_changes_YYYYMMDD_HHMMSS.txt
```

This file contains `CHANGE` events only: writes that changed at least one value, including local writes from the toolbar.

Example:

```text
2026-07-13 09:12:04.310 | CHANGE     | 192.168.1.50:52144 | Holding 10 : 0 -> 1500
2026-07-13 09:12:10.582 | CHANGE     | 192.168.1.50:52144 | Coil 25 = 1
```

### Persistent values

```text
modbus_values.txt
```

This file stores every non-zero holding register (`HR`), non-zero input register (`IR`), coil in the ON state (`C`) and discrete input in the ON state (`DI`). It is loaded when the application starts, rewritten at most every 2 seconds while values change, on **Save values now**, and when the window is closed.

Example:

```text
# lines starting with # are ignored
HR:9=1500
HR:99=25
IR:6=250
C:24=1
DI:0=1
```

The stored addresses are internal zero-based addresses. The GUI and operational messages display addresses as one-based values. Lines that cannot be applied (unknown area, address outside the configured space, value out of range) are reported as `WARN` events at startup and ignored; they do not stop the application.

The file can be edited by hand while the server is stopped to pre-load a test scenario.

## Addressing behavior

Modbus protocol addresses are zero-based. For operator readability, the GUI and logs display addresses beginning at `1`.

Example:

```text
Protocol address 0 → Displayed address 1
Protocol address 9 → Displayed address 10
```

The persistence file keeps the internal zero-based address.

## Exception responses

| Situation | Exception code |
|---|---|
| Function code not supported | `01` Illegal function |
| Start address + quantity outside the configured address space | `02` Illegal data address |
| Quantity outside the allowed range (1–2000 bits, 1–125 registers, 1–1968 coils or 1–123 registers for writes), wrong byte count or PDU length, invalid coil value | `03` Illegal data value |
| Unexpected internal error while processing a request | `04` Server device failure |

A frame whose MBAP protocol identifier is not `0` or whose length field is outside `2..254` is considered invalid; the connection is closed and a `WARN` is logged.

## Testing with a Modbus client

Example client configuration:

```text
Host: IP address of the Windows computer running the script
Port: 502 or the custom port selected at startup
Unit ID: 1 (any value is accepted)
Protocol: Modbus TCP
```

Suggested initial tests:

1. Read holding registers starting at protocol address `0`.
2. Write one holding register using FC06.
3. Confirm the change in the right-side panel.
4. Confirm the event in the session and change logs.
5. Read the register again and verify the returned value.
6. Write and read a coil using FC05 and FC01.
7. Set an input register from the toolbar and read it with FC04.

## Automated tests

`tests/Invoke-EngineTests.ps1` compiles the engine from the script and exercises it over loopback TCP without opening the GUI: exception codes, read/write round trips, Start retry after a failed bind, Stop closing clients, idle timeout, client limit, invalid MBAP handling and the persistence format. It needs no external module.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-EngineTests.ps1
```

The script prints one `[PASS]`/`[FAIL]` line per test and exits with code `1` when any test fails.

## Performance and responsiveness

- TCP client processing runs outside the Windows Forms UI thread.
- Events are transferred to the GUI through a bounded concurrent queue (50 000 events). If the GUI falls behind, RX/TX/READ events are discarded, counted in the status bar (`DROPPED`) and a `WARN` line is written to the log; control events (connections, changes, exceptions, errors) are never dropped.
- The GUI processes a bounded number of queued events per 150 ms update cycle.
- Log files stay open and are flushed once per update cycle.
- Persistent values are saved at most every 2 seconds.
- The on-screen traffic buffer is trimmed when it becomes large; the complete history remains in the session log.
- The right-side panels are updated incrementally.

Very high polling rates from many clients still generate a large amount of disk I/O because every event is written to the session log. Hiding the RX/TX frames from the view reduces GUI load but not disk I/O.

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

After fixing the cause, click **Start** again; the application does not need to be restarted.

### A remote client cannot connect

Check:

- The correct server IP address.
- The same TCP port on the server and client.
- The `BindAddress` parameter.
- Windows Firewall.
- Network ACLs and routing.
- Whether the server status is `RUNNING`.
- Whether the client limit was reached (a `WARN | Rejected: maximum clients reached` line appears in the traffic view).

### A client is disconnected after a while

The idle timeout closed a connection that sent nothing for `-IdleTimeoutSeconds` (default 60 s). Increase the value or pass `-IdleTimeoutSeconds 0` for clients that keep a connection open without polling.

### RX/TX counters change but values do not

The client may be performing only read requests, or writing values that are already stored (shown as `WRITE` in the traffic view). Value changes occur only with supported write functions:

```text
FC05
FC06
FC15
FC16
```

### No value-change entry appears

Confirm that the write request is valid and that the requested address is inside the configured address space. An `EXCEPTION` line in the traffic view shows exactly why a request was refused.

### Large traffic volume

Use **Show RX/TX frames** to hide the frames, **Pause view** to read the current content, or **Clear traffic** to clear the visible buffer. The session log remains complete. If disk growth becomes a concern, archive or remove old `modbus_session_*.txt` and `modbus_changes_*.txt` files when the server is stopped.

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

This project is released under the [MIT License](LICENSE).
