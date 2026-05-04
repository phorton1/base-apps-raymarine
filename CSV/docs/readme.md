# CSV — Google Earth to Raymarine RNS Conversion

**[Home](../../docs/readme.md)** --
**CSV Tool**

**`kmlToCSV.pm`** converts a Google Earth KML export into a Raymarine RNS-compatible
CSV file, enabling a workflow for managing navigation data in Google Earth and
transferring it to the E80 via Raytech RNS.

## Workflow

```
Google Earth
    → export Navigation.kml
        → kmlToCSV.pm
            → output/Navigation.text   (import into Raytech RNS)
            → output/ge_routes.h       (optional: Arduino teensyBoat NMEA0183 simulator)
                → RNS saves as ARCHIVE.FSH
                    → CF card → E80
```

## Google Earth Folder Structure

The input file is `input/Navigation.kml`, exported from Google Earth. The KML
structure must follow exact naming conventions — folders with unexpected names
produce only a warning and are otherwise silently ignored.

The top-level KML Document must contain a folder named exactly **`Navigation`**.
Inside `Navigation`, two sub-folders are recognized:

```
Navigation/
    Waypoints/          ← E80 "My Waypoints" + named Groups
        <Placemarks>    ← go into E80 "My Waypoints" group
        GroupName/      ← sub-folders become named E80 Groups
            <Placemarks>
    Routes/             ← E80 Routes
        RouteName/      ← each sub-folder is one Route
            <Placemarks>    ← waypoints in order along the route
```

**Critical naming rules:**

- The outer folder must be named `Navigation` (case-sensitive)
- The waypoint sub-folder must be named `Waypoints`
- The route sub-folder must be named `Routes`
- Any Placemark named exactly `Route` is silently skipped — these are
  Google Earth line-string path overlays, not waypoints

## Symbol Assignment

Waypoint symbols are assigned automatically based on context. There is no
user control over symbol selection — the symbol number in the KML is ignored.

| Context                     | Symbol Name       | E80 Number |
| --------------------------- | ----------------- | ---------- |
| "My Waypoints" group        | SYM_X             | 18         |
| Named group waypoints       | SYM_CIRCLE        | 25         |
| First waypoint of a route   | SYM_SQUARE        | 3          |
| Last waypoint of a route    | SYM_SQUARE_WITH_X | 37         |
| Intermediate route waypoint | SYM_TRIANGLE      | 48         |

`kmlToCSV.pm` contains the full 50-entry symbol table mapping both the
symbol names used here and the E80's own label for each symbol.

## Outputs

### output/Navigation.text

The output file is named **`.text`** (not `.csv` or `.txt`). The `.text`
extension is deliberate: it makes the file easier to navigate to within the
Raytech RNS file browser, which otherwise buries `.csv` files in its interface.

This is the file imported into Raytech RNS.

**Route double-output:** Every route is written twice. First, the route's
waypoints are output as a named **Waypoint Group** (so the group appears
in the E80's group list). Then the route itself is written as a **Route header**
followed by its waypoints as route points. It is not possible to generate
routes without also generating the corresponding waypoint groups. The groups
can be deleted in Raytech or on the E80 after import if not wanted.

The CSV begins with a 10-line header (the "stupidHeader") that embeds field
documentation as comments inside the first record. The fields written for each
waypoint are, in order:

```
Loc, Name, Lat, Long, Rng, Bear, Bmp, Fixed, Locked, Notes,
Rel, RelSet, RcCount, RcRadius, Show, RcShow, SeaTemp, Depth,
Time, MarkedForTransfer, GUID
```

The `GUID` field is an incrementing integer, not a true UUID.

Timestamps are recognized in the code but the timestamp output is currently
disabled (`if (0)` block). All waypoints are written with an empty Time field.

### output/ge_routes.h

A C header file for the
[**teensyBoat**](https://github.com/phorton1/Arduino-boat-teensyBoat)
Arduino NMEA0183 route simulator. Contains:

- One `waypoint_t` array per route, listing coordinates in order
- A `route_t routes[]` array referencing all route arrays

Copy this file manually to the teensyBoat Arduino sketch to synchronize
the simulator's route data with the current Google Earth waypoints.

## Raytech RNS Import Requirements

For RNS to accept CSV imports, all of the following must be in place on the
Windows PC running Raytech:

- `C:\Archive\` directory must exist
- `C:\Archive\RTWptRte.TXT` must exist — RNS checks for this file to enable
  the CSV import menu option; without it the import option is unavailable
- An `ARCHIVE.FSH` should be present as RNS's working navigation database

RNS does **not** use or mirror E80 tracks. It can facilitate extracting tracks
from the E80 indirectly via ARCHIVE.FSH read from a CF card.

## License

Copyright (C) 2026 Patrick Horton

This repository is free software, released under the
[GNU General Public License v3](../LICENSE.TXT) or any later version.
See [LICENSE.TXT](../LICENSE.TXT) or <https://www.gnu.org/licenses/> for details.

---

**Next:** [Home](../../docs/readme.md)
