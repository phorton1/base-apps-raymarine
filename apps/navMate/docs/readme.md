# navMate — Lifelong Navigation Knowledge Management

**[Raymarine](../../../docs/readme.md)** --
**Home** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)** --
**[Context Menu](context_menu.md)** --
**[KML Specification](kml_specification.md)** --
**[GE Notes](ge_notes.md)**

**navMate** is a desktop application for managing a mariner's complete navigation
data — waypoints, groups, routes, and tracks — across a lifetime of voyaging, across
multiple boats, and across multiple chartplotter devices. It is the primary management
surface for that data, not a companion to any single device.

Where chartplotters are operationally scoped — designed for the region your boat is in
right now, with the dozens of objects relevant to the current passage — navMate operates
at a different scale and time horizon entirely. A career sailor accumulates thousands of
waypoints, hundreds of routes, and years of track history. That knowledge has no home on
any chartplotter. navMate is that home.

The Raymarine E80/E120 SeatalkHS protocol (**RAYNET**) is the first transport
implementation. navMate's architecture is designed to support additional chartplotter
protocols and navigation systems behind a common transport abstraction. The knowledge
base, data model, and UI are the product. Everything else is a boundary adapter.

## Documentation Outline

- **[Architecture](architecture.md)** —
  Architectural vision: scope, UI layers, transport abstraction, relationship to
  chartplotters and OpenCPN, distribution path.

- **[Data Model](data_model.md)** —
  SQLite schema: collections hierarchy, WRT tables (Waypoints, Routes, Tracks),
  waypoint types, working sets, UUID strategy, timestamp sources, design decisions.

- **[UI Model](ui_model.md)** —
  Three concurrent UI surfaces (console, wx panels, Leaflet canvas), collection
  tree with checkbox visibility control, active and working set layers, Leaflet
  selection operations, session state persistence.

- **[Implementation](implementation.md)** —
  Module inventory by layer: foundation, data transport, context operations,
  HTTP server, and wx UI.

- **[Context Menu](context_menu.md)** —
  Full specification of every context menu configuration across both panels,
  clipboard state vocabulary, paste compatibility matrix, operation semantics,
  and HTTP test machinery.

- **[KML Specification](kml_specification.md)** —
  KML file structure, style naming and templates, ExtendedData tags, object-to-KML
  mapping for collections, waypoints, routes, and tracks; re-import semantics.

- **[GE Notes](ge_notes.md)** —
  Google Earth round-trip workflow, safe and unsafe GE editing operations, the
  additive-only re-import asymmetry, track editing policy.

## Third-Party Libraries

- **[Leaflet](https://leafletjs.com/)** (v1.9.4) — open-source JavaScript library
  for the interactive map canvas (BSD 2-Clause license). Tile imagery sourced
  separately from Google Maps and Esri.
- **[Google Maps](https://developers.google.com/maps)** — satellite tile imagery
  via the Maps JavaScript API (`lyrs=s`). Requires a Google Maps Platform API key;
  usage subject to Google Maps Platform Terms of Service.
- **[Esri](https://www.esri.com/)** — place name label overlay tiles via the
  ArcGIS Online REST tile service. Free for display use; attribution required.

## License

Copyright (C) 2026 Patrick Horton

navMate is free software, released under the
[GNU General Public License v3](../LICENSE.TXT) or any later version.
See [LICENSE.TXT](../LICENSE.TXT) or <https://www.gnu.org/licenses/> for details.

---

**Next:** [Architecture](architecture.md)
