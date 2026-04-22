# Raymarine Reverse Engineering — SeatalkHS, FSH, CSV, and Navionics Charts

**Home** --
**[NET Protocols](../NET/docs/readme.md)** --
**[FSH Format](../FSH/docs/readme.md)** --
**[CSV Tool](../CSV/docs/readme.md)** --
**[Navionics Charts](../Navionics/docs/readme.md)**

This repository documents the results of a systematic reverse-engineering effort
targeting Raymarine's proprietary protocols and file formats: the **SeatalkHS**
ethernet protocol suite, the **FSH** binary navigation file format, the **CSV**
import format used by Raytech RNS, and the **Navionics NV2** binary chart format
used on Raymarine CF card chartsets. It includes working Perl implementations of
the protocols, tools for reading and writing FSH files, tools for converting
navigation data between formats, and original documentation of the NV2 format.

The primary goal is direct **Route, Waypoint, and Track management** on Raymarine
MFDs from a laptop over an ethernet cable, without running Raymarine's RNS software.
The work was conducted on a Raymarine **E80** chartplotter, but the SeatalkHS
protocol is also used by E120-series MFDs, the DSM300 sonar module, and other
Raymarine hardware of the same generation.

## About This Work

**SeatalkHS ethernet protocols (RAYNET):** At the time this work was conducted, no
public documentation existed for the SeatalkHS ethernet protocol suite — not in
Raymarine's published materials, not in any forum post, not in any open-source
project, and not anywhere else on the internet that exhaustive searching could find.
The only technical breadcrumb discovered was a handful of undocumented C++ lines
buried inside an OpenCPN plugin for Raymarine radar (`RMRadar_pi`), which exposed
enough to identify the discovery protocol. Everything else — the WPMGR, TRACK,
FILESYS, and Database protocols; the complete port and service table — was derived
from scratch through packet capture, probing, and analysis.

Raymarine does not publish developer documentation for SeatalkHS. This repository
is believed to be the only structured technical record of these protocols.

**FSH file format:** The open-source [parsefsh](https://github.com/rahra/parsefsh)
project by Bernhard R. Fischer provided substantial groundwork: the initial decoding
of the FSH file format and the C struct definitions for block types and coordinates.
This repository extends parsefsh significantly — additional block types, corrected
coordinate handling, and the first known implementation that can both *read* and
*write* FSH files. parsefsh itself is no longer maintained.

## A Note on the Name "RAYNET"

Throughout this codebase, **RAYNET** is used as the working name for the SeatalkHS
ethernet protocol suite. The name was chosen for brevity — SeatalkHS is long to type
and appears to be a Raymarine registered trademark. RAYNET as used here means
*the collection of UDP and TCP protocols that operate over the SeatalkHS physical layer*,
as observed on the E80.

Raymarine subsequently introduced a product line also called "RAYNET" — their
next-generation ethernet networking standard. This coincidence of names is
unfortunate. The use of "RAYNET" in this repository predates awareness of that
branding and refers specifically to the older SeatalkHS-based protocols documented
here, not to Raymarine's newer RAYNET product line.

All Raymarine brand names (SeatalkHS, RAYNET, Raymarine, E80, E120, DSM300, RNS,
Raytech) are used descriptively for identification purposes. No affiliation with
or endorsement by Raymarine Ltd. is implied or claimed. This work is independent
reverse engineering for personal and educational purposes.

## Documentation Outline

- **[NET Protocols](../NET/docs/readme.md)** —
  The SeatalkHS ethernet protocol suite: discovery, waypoint/route/track management,
  filesystem access, navigation data, and the engineering tool used to explore them.

- **[FSH Format](../FSH/docs/readme.md)** —
  Raymarine's proprietary binary navigation file format (ARCHIVE.FSH): structure,
  block types, coordinate systems, and tools for reading and writing FSH files.

- **[CSV Tool](../CSV/docs/readme.md)** —
  Conversion from Google Earth KML to Raymarine RNS-compatible CSV format,
  enabling a Google Earth → RNS → E80 navigation data workflow.

- **[Navionics Charts](../Navionics/docs/readme.md)** —
  Active reverse engineering of the Navionics NV2 binary chart format, as found
  on Raymarine CF card chartsets.  The NV2 structure (catalog, sections, spatial
  index, feature vector) is substantially decoded; correct geographic rendering
  of panel streams is an open problem.  Primary target: Caribbean charts for
  Panama (Bocas del Toro, San Blas / Guna Yala) — regions with no current
  alternative chart source.

## Credits

- [**parsefsh**](https://github.com/rahra/parsefsh) by Bernhard R. Fischer —
  open-source C project that provided the initial decoding of the FSH file format,
  including C struct definitions for block types and coordinate representations.
  This repository derives from and significantly extends that work.

- [**RMRadar_pi**](https://github.com/douwefokkema/RMRadar_pi) —
  OpenCPN plugin for Raymarine radar. The only public source found containing
  any SeatalkHS packet structure information. Provided the initial clue that
  led to decoding the RAYDP discovery protocol.

## License

This software is released under the
[**GNU General Public License v3**](../LICENSE.TXT).

## Please Also See

- [**phorton1/base-apps-raymarine**](https://github.com/phorton1/base-apps-raymarine) —
  this repository on GitHub

- [**teensyBoat.ino**](https://github.com/phorton1/Arduino-boat-teensyBoat) —
  Arduino/Teensy4.0 physical boat simulator used to drive the E80 to known and
  reproducible states during protocol reverse engineering. Implements Seatalk1,
  NMEA0183, and NMEA2000 encoders and decoders; includes KiCad PCB schematic and design.

- [**teensyBoat.pm**](https://github.com/phorton1/base-apps-teensyBoat) —
  Perl application companion to teensyBoat.ino; provides remote monitoring and
  control of the teensyBoat device over TCP/IP and UDP.

---

**Next:** [NET Protocols](../NET/docs/readme.md)
