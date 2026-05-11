# FSH - Raymarine Binary Navigation File Format

Folders: **[Raymarine](../../docs/readme.md)** --
**[NET](../../NET/docs/readme.md)** --
**FSH** --
**[CSV](../../CSV/docs/readme.md)** --
**[shark](../../apps/shark/docs/shark.md)** --
**[navMate](../../apps/navMate/docs/readme.md)**

Raymarine uses a proprietary binary format called **FSH** for storing navigation
data (Waypoints, Routes, Groups, and Tracks). The file is named `ARCHIVE.FSH`
and lives at the root level of the CF card. The traditional way to access it
is by removing the CF card and reading it directly on a laptop with a card reader.

`ARCHIVE.FSH` can also be retrieved over ethernet from a running E80 without
removing the CF card, using the FILESYS protocol documented in
[NET Protocols](../../NET/docs/FILESYS.md). FILESYS is a read-only protocol;
writing files to the CF card via ethernet is not possible. The CF card path
remains the only way to deliver a written FSH file to the E80.

**Note on `\Archive\`:** Raytech RNS (a historical Raymarine Windows application,
difficult to obtain) expects to find and write `ARCHIVE.FSH` in `C:\Archive\`
on the Windows machine where it runs. That is an RNS convention, not the CF card
layout. RNS provides an additional workflow path: an `ARCHIVE.FSH` loaded into
RNS can be synchronized to the E80 over RAYNET, covering Waypoints, Groups, and
Routes. Tracks are a notable exception - FSH Tracks do not pass through RNS,
which has its own separate logging and track-generation concept.

It is beyond the scope of this FSH documentation to describe RNS and its usage
in full detail. Later user-oriented documentation *may* document specific
workflows in which FSH files are used as intermediates or storage for
Waypoint/Route/Group/Track management, as this repository continues to grow
and evolve.

The FSH format was initially decoded by the open-source
[**parsefsh**](https://github.com/rahra/parsefsh) project. The implementation here
extends parsefsh significantly: additional block types, corrected coordinate handling,
and the first known FSH *writer*.

## File Structure

An FSH file is structured as a file header followed by a sequence of **flobs**
(flash blobs), each exactly 64K bytes:

```
File header (28 bytes)
    signature: "RL90 FLASH FILE" (16 bytes, null-padded)
    ... header fields ...

Flob 0 (65536 bytes)
    signature: "RAYFLOB1" (8 bytes)
    flob header (14 bytes; third field = 0xfffe, 0xfffc, or 0xfff0)
    [ block* ]

Flob 1 ... Flob N
```

Each **block** within a flob has a 14-byte block header followed by block data:

```
block_type  (uint16)   - identifies the content type
block_len   (uint16)   - length of block data
active      (uint16)   - 0x4000 = active block; other values = deleted/superseded
uuid        (8 bytes)  - unique identifier for this record
block data  ...
```

## Block Types

| Type   | Constant | Description              |
| ------ | -------- | ------------------------ |
| 0x0001 | BLK_WPT  | Waypoint                 |
| 0x000d | BLK_TRK  | Track points             |
| 0x000e | BLK_MTA  | Track metadata (name, color, endpoints, UUID reference) |
| 0x0021 | BLK_RTE  | Route                    |
| 0x0022 | BLK_GRP  | Group (waypoint folder)  |
| 0xffff | BLK_ILL  | Invalid / unused block   |

## Archive Semantics

ARCHIVE.FSH is a true archive: saving a Route, Waypoint, or Group that already
exists does **not** overwrite its old block - it appends a new block and marks
the old one as deleted (active != 0x4000). The file grows over time.

To reconstruct the current state of the navigation database, you must:

1. Parse all blocks in order
2. For each UUID, keep only the **last** occurrence
3. Ignore blocks where `active != 0x4000`

The E80 tracks which blocks are current internally. ARCHIVE means it really is
an archive of all past states.

`fshFile.pm` uses `ACTIVE_BLOCKS_ONLY=1` to handle this correctly.

## Coordinate Systems

**Waypoints** store coordinates in two representations:

- **1e7-scaled integers** - `lat_int` and `lon_int`, where the value is
  `degrees x 1e7`. These are the accurate coordinates. *Use these.*
- **Mercator northing/easting** - also stored, but slightly less accurate.
  The borrowed C code from parsefsh used these; the implementation here
  was corrected to prefer the 1e7 integers.

**Track points** store only Mercator northing/easting. Conversion is via
`northEastToLatLon()`.

## Waypoint Structure

Each BLK_WPT block contains (in order): lat (1e7), lon (1e7), northing, easting,
symbol number, temperature, depth, time, date, name_length, comment_length,
then the name string, then the comment string.

## Track Structure

Tracks are stored as a **BLK_TRK + BLK_MTA pair**. The MTA always follows its
TRK in the file and references the TRK by UUID.

**BLK_MTA fields** (58 bytes + guid_cnt x 8 bytes):
`k1_1(1) cnt(2) _cnt(2) k2_0(2) length(4) north_start(4) east_start(4)
temp_start(2) depth_start(4) north_end(4) east_end(4) temp_end(2)
depth_end(4) color(1) name(16, not null-terminated)`

In FSH files from the real E80, `u1` (byte 56) is always 204 - not zero as
the parsefsh documentation claims.

**BLK_TRK** contains a header (8 bytes: `a(4) cnt(2) b(2)`) followed by
`cnt` track points, each 14 bytes: `north(4) east(4) tempr(2) depth(2) c(2)`.

Track segment separators are represented as `ffffffff ffffffff ffffffff ffff`
(a 14-byte run of 0xff bytes) in the track point stream.

## FSH vs WPMGR Field Discrepancies

Some fields differ between what the E80 returns via WPMGR and what appears
in FSH files. Known discrepancies (from `fshBlocks.pm`):

| Field     | WPMGR / E80          | FSH file             |
| --------- | -------------------- | -------------------- |
| u2_0200   | `02000000`           | `00000000`           |
| u3        | `b8975601`           | `00000000`           |
| u6        | `c81c`               | `2100`               |
| u4_self   | SELF_UUID            | different value      |

## Programs

**`FSH/fshConvert.pm`** - reads an FSH file and converts it to KML or GPX.
Takes up to two command-line arguments:

```
perl fshConvert.pm [input_file [output_file]]
```

Default input: `/Archive/ARCHIVE.FSH`. Default output:
`FSH/output/created_from_ARCHIVE_FSH.kml`. Output format is determined by
the output file extension: `.kml` -> KML, `.gpx` -> GPX; any other extension
parses the FSH but writes no output file. Depends on: `fshBlocks.pm`,
`fshFile.pm`, `fshUtils.pm`, `genKML.pm`, `genGPX.pm`.

**`FSH/kmlToFSH.pm`** - reads a KML file and writes an FSH file. Input and
output paths are hardcoded in the script (`/junk/tracks.kml` ->
`/junk/tracks.fsh`); edit the script to change them. The KML must contain
a `Tracks` folder with Placemarks using `<LineString><coordinates>` for track
points and `<ExtendedData>` for MTA/TRK UUIDs and line color. This is
believed to be the only working FSH writer in existence outside of Raymarine
itself.

**`NET/fshWriter.pm`** - not a standalone application. This is a module
within the `shark.pm` engineering tool (invoked via the `write` serial
command) that queries live E80 data over RAYNET - using WPMGR and TRACK -
and assembles it into an FSH file, without requiring CF card access. It is
currently a test implementation; its practical status and completeness
should be verified against the current source.

## Advances Beyond parsefsh

The following differences from parsefsh's documented structures were identified during
implementation against actual E80 `ARCHIVE.FSH` files. Each is either a structural
correction, a newly discovered field, or a new capability.

**Block header - `active` field** *(newly discovered)*

A 16-bit field at offset 12 in the 14-byte block header is not documented in parsefsh:
`0x4000` = block is in use; `0x0000` = block is deleted. This field is fundamental to
both reading and writing, and to the archive model itself.

A parser that does not filter on `active` will process deleted blocks as live data.

A writer must set `active = 0x4000` on every block it emits, or the E80 will treat
those blocks as free space. More critically: a writer that does not understand both
values of `active` cannot implement the true archive update model at all. Updating an
existing record - the way the E80 itself does - means appending a new block with
`active = 0x4000` and writing `active = 0x0000` back into the superseded block's
header. Without the ability to retire old blocks deliberately, a writer is limited to
producing fresh files from scratch. It cannot extend a living archive, cannot round-trip
with an E80 that has accumulated its own history, and cannot participate in the same
file the E80 continues to write.

See [Archive Semantics](#archive-semantics).

**Waypoint record - 8-byte lead-in with 1e7 coordinates** *(structural correction)*

parsefsh's `fsh_wpt_data` struct begins at byte +8 within the actual on-disk waypoint
record. The record opens with two `int32_t` fields - latitude and longitude as
degrees x 10,000,000 - that parsefsh's struct omits entirely. These integer coordinates
are more accurate than the Mercator-derived lat/lon that parsefsh produces; the Mercator
fields remain at the same relative offsets within the struct but are shifted +8 from
their actual disk positions. See [Coordinate Systems](#coordinate-systems) and
[Waypoint Structure](#waypoint-structure).

**Route point structure (BLK_RTE)** *(entirely corrected)*

parsefsh's route point layout was incorrect. The correct 10-byte `fsh_pt` structure:

| Offset | Size | Type       | Field        | Notes |
| ------ | ---- | ---------- | ------------ | ----- |
| 0      | 2    | `int16_t`  | `bearing`    | Bearing from previous waypoint, radians x 10,000. To degrees: `(bearing / 10000) x (180 / pi)` |
| 2      | 4    | `uint32_t` | `leg_length` | Distance from previous waypoint, meters |
| 6      | 4    | `uint32_t` | `tot_length` | Cumulative route distance, meters |

**Route header - two newly discovered fields (BLK_RTE)**

Two fields absent from parsefsh:

- **`color`** - byte 7 of the first route header (`fsh_route21_header`). Color index:
  0 = red, 1 = yellow, 2 = green, 3 = blue, 4 = magenta, 5 = black.
- **`distance`** - bytes 16-19 of the second route header (`fsh_hdr2`), type `uint32_t`.
  Total route distance in meters.

**BLK_MTA - field `j` correction (byte 56)**

parsefsh documents byte 56 of `fsh_track_meta` (field `j`) as "always 0". In actual
E80 `ARCHIVE.FSH` files this byte is always **204** (0xCC). A writer that outputs 0
will not match E80 output.

**FSH writer** *(new capability)*

This is the first known FSH writer. parsefsh is read-only. The writer constructs valid
flob structure, pads to minimum file size (16 flobs / 1 MB), and uses BLK_ILL (`0xFFFF`)
as a flob terminator. Written files contain only active blocks; there is no support for
in-place update of an existing FSH file.

*Known gap:* The inverse coordinate transform (lat/lon -> Mercator northing/easting,
required for encoding track points) uses a linear approximation rather than the correct
ellipsoidal inverse. Read-back coordinates will not round-trip exactly.

## License

Copyright (C) 2026 Patrick Horton

This repository is free software, released under the
[GNU General Public License v3](../LICENSE.TXT) or any later version.
See [LICENSE.TXT](../LICENSE.TXT) or <https://www.gnu.org/licenses/> for details.

---

**Next:** [Home](../../docs/readme.md)
