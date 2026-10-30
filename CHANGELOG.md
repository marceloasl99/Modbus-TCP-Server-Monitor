# Changelog

## 1.1.0 - 2026-10-30

### Fixed

- **Start could not be retried after a failure.** When the listener failed to bind (for example, port 502 without elevation or a port already in use), subsequent clicks on *Start* did nothing. The listener is now published only after it is really listening.
- **Modbus exception codes.** An illegal quantity (for example FC03 with more than 125 registers, or quantity 0) now returns exception `03` (illegal data value) and an address outside the configured space returns `02` (illegal data address) for every function code, as the Modbus Application Protocol specifies. Previously FC01–04 always returned `02` and FC15/16 always returned `03`.
- **Idle connections were never closed.** `Socket.ReceiveTimeout` has no effect on asynchronous reads, so idle clients stayed connected forever and held a slot in `-MaxClients`. The server now enforces a real idle timeout (`-IdleTimeoutSeconds`, default 60).
- **Stop did not disconnect connected clients.** Clients remained open (and listed) until they sent their next request, which was then dropped without a response. *Stop* now closes every client socket and waits for the client tasks to finish.
- **A write with an unchanged value was reported as a change.** It is now logged as `WRITE` instead of `CHANGE`, and does not appear in the changed-address panel or in the change log. FC15/FC16 report how many of the written values actually changed.
- An invalid line in `modbus_values.txt` (for example a value above 65535) aborted the program at startup. Invalid lines are now reported as warnings and ignored.
- The final `DISCONNECT` and `Stopped` events were lost when the window was closed; the queue is now drained before exit.
- The script can be run from a pasted console session (`$PSScriptRoot` empty); files are then created in the current directory.

### Performance

- Persistent values are saved at most every 2 seconds (plus on demand and on exit) instead of once per change event.
- Session and change logs keep their files open and are flushed once per GUI tick instead of being reopened for every line.
- The *Active clients* panel updates rows in place; the *Changed addresses* panel appends new rows only. Both lists were previously rebuilt from scratch every 150 ms, even when idle.
- The traffic view trims and scrolls once per tick instead of once per line.
- The event queue is bounded (50 000 events). If the GUI cannot keep up, RX/TX/READ events are dropped, counted (`DROPPED` in the status bar) and a `WARN` line is written to the log.
- Data tables are now plain arrays under one lock, so multi-register reads and writes are atomic.

### Added

- `-IdleTimeoutSeconds` parameter (0 disables the timeout).
- **Set value** toolbar: write a holding register, input register, coil or discrete input locally. Input registers and discrete inputs can now be populated (previously they were always zero).
- `IR:` and `DI:` entries in `modbus_values.txt`; comment lines starting with `#` are allowed.
- **Pause view** button: freezes the traffic view for reading while logging and counters continue.
- **Show RX/TX frames** toggle: hides the hexadecimal frames from the view (they are still logged).
- `EXCEPTION` event type and counter for Modbus exception responses; `DISCONNECT` events include the reason.
- Two-line status bar with bind address, idle timeout, exception and dropped-event counters.
- `tests/Invoke-EngineTests.ps1`: headless tests of the engine over loopback TCP, with no external dependencies.
- `.gitignore`, `LICENSE` (MIT) and this changelog.

## 1.0.0

- Initial release.
