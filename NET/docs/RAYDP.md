# RAYDP — Service Discovery Protocol

**[Home](../../docs/readme.md)** --
**[NET](readme.md)** --
**[RAYNET](RAYNET.md)** --
**RAYDP** --
**[WPMGR](WPMGR.md)** --
**[TRACK](TRACK.md)** --
**[FILESYS](FILESYS.md)** --
**[DBNAV](DBNAV.md)** --
**[shark](shark.md)** --
**[Cables](ethernet_cables.md)**

**RAYDP** (Raymarine Discovery Protocol) is the SeatalkHS service discovery
protocol — the entry point into RAYNET. It operates as a multicast UDP broadcast
on **224.0.0.1:5800**. On the E80, this service is labeled "Sys" in the ethernet
diagnostics Services dialog. The implementation class is `c_RAYDP.pm`.

The protocol was named **RAYSYS** for a time in this codebase, to match the
Raymarine "Sys" label, but has been renamed back to **RAYDP** because that name
more accurately captures its role as a discovery protocol (analogous to SSDP).
Older notes and probe files may still use RAYSYS; the two names refer to the
same protocol.

## Role

Every SeatalkHS device on the network periodically broadcasts advertisement packets
to 224.0.0.1:5800. Each packet identifies a device and advertises one or more
**ip:port** combinations for a specific **service_id** (called **func** in the
implementation). A client joins the multicast group, listens for these advertisements,
and uses the ip:port information to connect to the services it wants.

This is conceptually similar to SSDP — the device announces itself; the client
decides whether to connect.

## Device Identification

Each advertisement carries a **device id** — a 4-byte value that uniquely identifies
the advertising device. Known device IDs:

| Device ID  | Device                         |
| ---------- | ------------------------------ |
| `37a681b2` | E80 #1 (master device)         |
| `37ad80b2` | E80 #2                         |
| `ffffffff` | RNS (advertising its own Alarm port) |

## Advertisement Packet Structure

The packet length determines how many ports are being advertised. All packets share
a common 20-byte header: `type(4) id(4) func(4) x1(4) x2(4)`. The payload
following the header depends on packet length:

| Length | Structure                                                              |
| ------ | ---------------------------------------------------------------------- |
| 28     | `ip(4) port(4)` — single port                                          |
| 36     | `mcast_ip(4) mcast_port(4) tcp_ip(4) tcp_port(4)` — two ports         |
| 37     | same as 36 plus a `flags(1)` byte                                      |
| 40     | `tcp_ip(4) tcp_port1(4) tcp_port2(4) mcast_ip(4) mcast_port(4)`       |

The `x1` and `x2` fields in the header are present in all packets but their
meaning has not been fully decoded. The `type` field is 0 for all observed E80
advertisements.

Example decoded RAYDP session at startup (from `NET/docs/logs/raydp_startup_capture.txt`).
The `RAYDP` prefix in the log lines is the implementation's label in `c_RAYDP.pm`:

```
RAYDP IDENT(54) type(RAYTECH) id(RNS) vers(6.3) ip(128.118.142.1) role(UNDEFINED)
RAYDP IDENT(56) type(E80) id(E80 #1) vers(5.69) ip(10.0.241.54) role(MASTER)

RAYDP 36:0 RNS      func(27)     mcast_ip(224.0.0.2) mcast_port(5801) ip(10.0.241.200) port(5802)
RAYDP 28:0 E80 #1   WPMGR(15)    ip(10.0.241.54) port(2052)
RAYDP 37:0 E80 #1   FILESYS(5)   mcast_ip(224.30.38.194) mcast_port(2561) ip(10.0.241.54) port(2049) flags(1)
RAYDP 28:0 E80 #1   Navig(7)     ip(10.0.241.54) port(2054)
RAYDP 36:0 E80 #1   func(8)      mcast_ip(224.30.38.196) mcast_port(2563) ip(10.0.241.54) port(2056)
RAYDP 40:0 E80 #1   Database(16) ip(10.0.241.54) port1(2050) port2(2051) mcast_ip(224.30.38.195) mcast_port(2562)
RAYDP 28:0 E80 #1   Track(19)    ip(10.0.241.54) port(2053)
RAYDP 28:0 E80 #1   func(22)     ip(10.0.241.54) port(2055)
RAYDP 36:0 E80 #1   func(27)     mcast_ip(224.0.0.2) mcast_port(5801) ip(10.0.241.54) port(5802)
RAYDP 36:0 E80 #1   func(35)     mcast_ip(224.30.38.193) mcast_port(2560) ip(10.0.241.54) port(2048)
```

Note that both the E80 and RNS advertise func(27)/Alarm on port 5802.

## IDENT Packets

In addition to service advertisements, devices send **IDENT** packets that identify
the device type, name, software version, IP, and role (e.g. MASTER). These are larger
packets (54–56 bytes) that do not follow the standard advertisement structure and are
displayed separately. The E80 typically advertises as role MASTER.

## Implementation Notes

**Service timeouts:** Advertised service ports are pruned from the internal table
after a configurable timeout (`$SERVICE_PORT_TIMEOUT`) if no new advertisement
arrives. This handles devices that go offline.

**Auto-start:** Implemented services (WPMGR, TRACK, FILESYS, DB, DBNAV) are started
automatically when their ports are discovered via RAYDP, if
`$AUTO_START_IMPLEMENTED_SERVICES = 1` in `a_defs.pm`. Implemented services use
`EXIT_ON_CLOSE=0` and will attempt to reconnect if the E80 reboots.

**Spawned services:** Ports that are recognized but not implemented use
`EXIT_ON_CLOSE=1` — a TCP listener thread is spawned to observe traffic, but it
does not send any requests.

**Thread safety:** The RAYDP `service_ports` hash is shared across threads. All
access requires `lock($raydp)`.

---

**Next:** [WPMGR](WPMGR.md)
