# SeatalkHS — NET Protocol Documentation

**[Home](../../docs/readme.md)** --
**NET** --
**[RAYNET](RAYNET.md)** --
**[RAYSYS](RAYSYS.md)** --
**[WPMGR](WPMGR.md)** --
**[TRACK](TRACK.md)** --
**[FILESYS](FILESYS.md)** --
**[DBNAV](DBNAV.md)** --
**[shark](shark.md)** --
**[Cables](ethernet_cables.md)**

The NET folder contains Perl implementations of the Raymarine **SeatalkHS**
ethernet protocols, along with the engineering tool (**shark**) used to explore
them, and supporting documentation.

Throughout this documentation and the implementation code, **RAYNET** is used
as the working shorthand for the complete SeatalkHS ethernet protocol suite —
every UDP, TCP, and multicast service that operates over SeatalkHS, as observed
on the E80 and E120. For background on this name, see the
[project home page](../../docs/readme.md). All protocol knowledge documented
here was derived from packet capture, probing, and analysis. No official
Raymarine developer documentation exists for these protocols.

This page is the overview. It is organized in two parts: **Protocols**
covers the reverse-engineered SeatalkHS services; **Engineering Tools**
covers the software and hardware used to work with them.

## Protocols

The entry point into RAYNET is **RAYSYS** — the service discovery protocol at
**224.0.0.1:5800** — through which every device on the network advertises the
services it provides. RAYSYS is the key to the whole system: without it, none
of the service protocols below can be located. All implemented and observed ports
in the table below were discovered through RAYSYS advertisement packets. The
protocol was originally named **RAYDP** (Raymarine Discovery Protocol) in this
codebase, which more accurately captures its role, and that name appears in older
notes and probe files.

Every advertised port is identified by a **RAYNAME** — a name assigned to
reflect the current level of understanding of that port:

- **ALLCAPS** — a fully decoded and implemented protocol with its own
  documentation. These are named protocols: RAYSYS, WPMGR, TRACK, FILESYS,
  DBNAV. FILE_RNS and MY_FILE are listener ports that have been identified
  and can be monitored.
- **Capitalized** — a port identified with a known Raymarine service (visible
  in the E80's ethernet Services dialog), connected to and observed, but not
  yet fully decoded or implemented. Examples: Database, Navig, Alarm.
- **lowercase** — a port observed in traffic, either a secondary
  protocol variant of an identified service, or not yet associated with any
  known Raymarine function. Examples: func8_u, func35_m, alarm, hidden_t.

The full RAYNAME convention and the protocol architecture that underlies all
services are documented in **[RAYNET](RAYNET.md)**.

| Port  | Proto | SID | RAYNAME   | Status      | Description                          |
| ----- | ----- | --- | --------- | ----------- | ------------------------------------ |
| 5800  | mcast |  0  | RAYSYS    | Implemented | Service discovery (224.0.0.1:5800)   |
| 2052  | tcp   | 15  | WPMGR     | Implemented | Waypoint / Route / Group management  |
| 2053  | tcp   | 19  | TRACK     | Implemented | Track management                     |
| 2049  | udp   |  5  | FILESYS   | Implemented | CF card filesystem access (read-only)|
| 2050  | tcp   | 16  | Database  | Implemented | Navigation field database (TCP)      |
| 2562  | mcast | 16  | DBNAV     | Implemented | Navigation data broadcast            |
| 2054  | tcp   |  7  | Navig     | Observed    | Navigation TCP — not decoded         |
| 2055  | tcp   | 22  | func22_t  | Observed    | Gets 9-byte msgs — not decoded       |
| 5801  | mcast | 27  | Alarm     | Observed    | Alarm multicast — not decoded        |
| 5802  | udp   | 27  | alarm     | Observed    | Alarm UDP — not decoded              |
| 2048  | udp   | 35  | func35_u  | Observed    | Appears with teensyBoat active       |
| 2051  | udp   | 16  | database  | Observed    | DB UDP variant — not decoded         |
| 2056  | udp   |  8  | func8_u   | Observed    | Appears with teensyBoat compass/GPS  |
| 2560  | mcast | 35  | func35_m  | Observed    | Multicast variant of func35          |
| 2561  | mcast |  5  | filesys   | Observed    | FILESYS multicast — purpose unclear  |
| 2563  | mcast |  8  | func8_m   | Observed    | Packets seen when RNS running        |
| 6668  | tcp   | —   | hidden_t  | Observed    | Found by port scan, not advertised   |
| 18432 | udp   |  5  | FILE_RNS  | Identified  | RNS's FILESYS listener port          |
| 18433 | udp   |  5  | MY_FILE   | Identified  | shark's FILESYS listener port        |

Ports 2048–2055 and 2560–2563 appear on a bare E80. Port 2056 appears only
when teensyBoat is providing compass and GPS. func8_m (2563) receives packets
when RNS is running and the E80 is underway.

### Protocol Documentation

- **[RAYNET](RAYNET.md)** —
  Protocol architecture: message framing, service model, the RAYNAME naming
  convention, and the common message structure shared across all services.

- **[RAYSYS](RAYSYS.md)** —
  The service discovery protocol: multicast advertisement packets, device
  identification, and service port enumeration. The foundation on which all
  other RAYNET services rest. Originally named RAYDP in this codebase.

- **[WPMGR](WPMGR.md)** —
  Waypoint, Route, and Group management over TCP port 2052. The most fully
  reverse-engineered and implemented service.

- **[TRACK](TRACK.md)** —
  Track management over TCP port 2053: start/stop/save/erase, track retrieval,
  naming, and the complete command and reply tables.

- **[FILESYS](FILESYS.md)** —
  Read-only access to the CF card filesystem over UDP port 2049: directory
  listing, file size, file contents, card identification, and advisory locking.

- **[DBNAV](DBNAV.md)** —
  Navigation field database (port 2050 TCP) and live navigation data broadcast
  (port 2562 multicast): field IDs, query protocol, and known field table.

## Engineering Tools

Working with the E80 over SeatalkHS requires physical ethernet access and
the **shark** engineering application. Each E80 has its own IP address,
assigned by its DHCP server or by static configuration; addresses vary across
units and networks. The specific addresses used in development are recorded in
`NET/a_defs.pm`. A standard **shielded** ethernet cable is required between
the laptop and the E80 (or a router that bridges them); see
**[Cables](ethernet_cables.md)** for wiring details and the 3D-printed
field-installable waterproof connector.

### Implementation Architecture

The NET Perl implementation follows a layered naming convention (one letter
prefix per layer):

| Prefix | Layer        | Examples                                          |
| ------ | ------------ | ------------------------------------------------- |
| a_     | Definitions  | a_defs.pm — feature flags, shared constants       |
| b_     | Base classes | b_sock.pm, b_parser.pm, b_probe.pm                |
| c_     | RAYSYS       | c_RAYSYS.pm — discovery protocol                  |
| d_     | Services     | d_WPMGR.pm, d_TRACK.pm, d_FILESYS.pm, d_DB.pm    |
| e_     | APIs         | e_wp_api.pm, e_wp_defs.pm — WPMGR API and constants |
| f_     | FSH bridge   | fshWriter.pm — writes FSH from live E80 data      |
| w_     | wxPerl UI    | w_frame.pm, winShark, winRAYSYS, winFILESYS, etc. |

The main application entry point is **shark.pm**.

### Engineering Tool Documentation

- **[shark](shark.md)** —
  The wxPerl engineering application: serial command vocabulary, feature flags,
  GUI panels, and the probe system for exploring unknown ports and services.

- **[Cables](ethernet_cables.md)** —
  Physical connection requirements: shielded ethernet cables, the E80/E120
  ethernet port, and the 3D-printed field-installable waterproof connector.

---

**Next:** [RAYNET](RAYNET.md)
