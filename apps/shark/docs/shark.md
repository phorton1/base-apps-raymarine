# shark - The SeatalkHS Engineering Tool

**shark** --
**[winRAYDP](winRAYDP.md)** --
**[winSniffer](winSniffer.md)** --
**[winShark](winShark.md)** --
**[winFILESYS](winFILESYS.md)** --
**[winDBNAV](winDBNAV.md)**

Folders: **[Raymarine](../../../docs/readme.md)** --
**[NET](../../../NET/docs/readme.md)** --
**[FSH](../../../FSH/docs/readme.md)** --
**[CSV](../../../CSV/docs/readme.md)** --
**shark** --
**[navMate](../../../apps/navMate/docs/readme.md)**

**shark** (`apps/shark/shark.pm`) is the engineering application for probing and
operating the SeatalkHS protocols. It is a **wxPerl** GUI application that uses the
**NET library** (`NET/`) to connect to an E80 via [RAYDP](../../../NET/docs/RAYDP.md), [WPMGR](../../../NET/docs/WPMGR.md), [TRACK](../../../NET/docs/TRACK.md), [FILESYS](../../../NET/docs/FILESYS.md), and
other services. shark also starts a serial command interface, a tshark-based packet
sniffer, and an HTTP server (`s_server.pm`, port 9882) for Google Earth waypoint
serving. The HTTP server extends `NET/h_server.pm`, the shared base class also used
by navMate.

## Feature Flags

Compile-time feature flags in `a_defs.pm` enable or disable components:

| Flag                              | Default | Description                              |
| --------------------------------- | ------- | ---------------------------------------- |
| `$WITH_SERIAL`                    | 1       | Serial command interface                 |
| `$WITH_RAYDP`                     | 1       | RAYDP discovery listener                 |
| `$WITH_HTTP_SERVER`               | 1       | HTTP server for Google Earth (port 9882) |
| `$WITH_SNIFFER`                   | 1       | tshark packet sniffer                    |
| `$WITH_TCP_SCANNER`               | 0       | TCP port scanner (disabled by default)   |
| `$WITH_UDP_SCANNER`               | 0       | UDP port scanner (disabled; requires sniffer off) |
| `$WITH_WX`                        | 1       | wxPerl GUI                               |
| `$WITH_TRACK`                     | 1       | TRACK service                            |
| `$WITH_WPMGR`                     | 1       | WPMGR service                            |
| `$WITH_FILESYS`                   | 1       | FILESYS service                          |
| `$WITH_DBNAV`                     | 1       | DBNAV multicast listener                 |
| `$WITH_DB`                        | 1       | Database TCP service                     |
| `$AUTO_START_IMPLEMENTED_SERVICES`| 1       | Auto-start services on RAYDP discovery   |

## Serial Command Interface

shark accepts commands over a Win32 serial port connection. Commands are typed
into a serial terminal and processed by `handleSerialCommand()`.

**System:**

| Command             | Description                                         |
| ------------------- | --------------------------------------------------- |
| `wakeup`            | Send E80 wakeup packet                              |
| `db`                | Show local waypoint database                        |
| `kml`               | Print RAYSYS KML to console (kml_RAYSYS)            |
| `s`                 | Clear shark.log                                     |
| `r`                 | Clear rns.log                                       |
| `log <message>`     | Write labeled separator to both log files           |

**Database (DB):**

| Command             | Description                                         |
| ------------------- | --------------------------------------------------- |
| `i`                 | Call DB `uiInit()`                                  |
| `fids`              | Show all known FIDs via `showFids()`                |

**[DBNAV](../../../NET/docs/DBNAV.md):**

| Command             | Description                                         |
| ------------------- | --------------------------------------------------- |
| `v`                 | Show current DBNAV field values                     |

**[FILESYS](../../../NET/docs/FILESYS.md):**

| Command                    | Description                                  |
| -------------------------- | -------------------------------------------- |
| `f <cmd> <path>`           | File command: cmd = DIR, SIZE, FILE, or ID   |

**[TRACK](../../../NET/docs/TRACK.md):**

| Command                    | Description                                  |
| -------------------------- | -------------------------------------------- |
| `t start`                  | Start Current Track                          |
| `t stop`                   | Stop Current Track                           |
| `t save`                   | Save Current Track                           |
| `t discard`                | Discard unsaved Current Track                |
| `t state`                  | Get recording state                          |
| `t bump`                   | Bump the default track name counter          |
| `t cur`                    | Get Current Track MTA                        |
| `t cur2`                   | Get Current Track MTA + points               |
| `t mta <name>`             | Get MTA for named saved track                |
| `t name <name>`            | Set Current Track name                       |
| `t nth <n>`                | Get Nth point of Current Track               |
| `t erase <name>`           | Erase saved track by name                    |
| `t rename <old> <new>`     | Rename a saved track                         |

**[WPMGR](../../../NET/docs/WPMGR.md):**

| Command                    | Description                                  |
| -------------------------- | -------------------------------------------- |
| `q`                        | Query all waypoints, routes, and groups      |
| `create wp <num>`          | Create a test waypoint                       |
| `create route <num> [...]` | Create a test route                          |
| `create group <num>`       | Create a test group                          |
| `delete wp <name>`         | Delete waypoint by name                      |
| `delete route <name>`      | Delete route by name                         |
| `delete group <name>`      | Delete group by name                         |
| `route <num> + <wp_num>`   | Add waypoint to route                        |
| `route <num> - <wp_num>`   | Remove waypoint from route                   |
| `wp <wp_num> <group_num>`  | Set waypoint group                           |
| `wp <name>`                | Show waypoint info                           |
| `route <name>`             | Show route info                              |
| `group <name>`             | Show group info                              |

**Port scanning:**

| Command                    | Description                                  |
| -------------------------- | -------------------------------------------- |
| `scan <low> <high>`        | TCP port scan range                          |
| `udp [a] <low> <high>`     | UDP scan (a = aggressive mode)               |

**Probe execution:**

| Command                           | Description                           |
| --------------------------------- | ------------------------------------- |
| `p <name> <ident> [params]`       | Execute a probe: name = TRACK, WPMGR, FILESYS, DB (or t/w/f/d shortcuts); ident = probe name from .txt file |

**FSH writing:**

| Command    | Description                           |
| ---------- | ------------------------------------- |
| `write`    | Invoke `fshWriter::write()`           |

## GUI Panels

| Panel       | Description                                        |
| ----------- | -------------------------------------------------- |
| [winShark](winShark.md)    | Protocol monitoring control - per-port active/log/only checkboxes |
| [winSniffer](winSniffer.md)  | tshark sniffer control - per-port active/log/only/self checkboxes and live packet counts |
| [winRAYDP](winRAYDP.md)    | Live RAYDP service discovery - connect/spawn controls per advertised service |
| [winFILESYS](winFILESYS.md)  | CF card file browser - directory navigation and file download |
| [winDBNAV](winDBNAV.md)    | Live navigation data - decoded DBNAV multicast field values |

## Probe System

shark can execute probe files from `NET/probes/*.txt` using the `p` command.
Probe files are written in a custom meta-language implemented in `b_probe.pm`.

Available probe targets: `TRACK`, `WPMGR`, `FILESYS`, `DB`, `filecast`, `func22_t`

Probe file directives: `PROBE`, `MSG`, `RAW`, `INC_SEQ`, `WAIT`, `UDP_DEST`, `UDP_PORT`, `>>>`

Substitution tokens: `{time}`, `{seq}`, `{sid}`, `{port}`, `{string name}`, `{name16 name}`, `{params}`

Probe files for implemented protocols are in `NET/probes/`. The probe system was
the primary tool for discovering command semantics by sending structured guesses
to the E80 and observing responses.

## License

Copyright (C) 2026 Patrick Horton

This repository is free software, released under the
[GNU General Public License v3](../LICENSE.TXT) or any later version.
See [LICENSE.TXT](../LICENSE.TXT) or <https://www.gnu.org/licenses/> for details.

---

**Next:** [winRAYDP](winRAYDP.md)
