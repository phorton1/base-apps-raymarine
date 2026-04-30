# navMate — Lifelong Navigation Knowledge Management

**[Raymarine](../../../docs/readme.md)** --
**Home** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)**

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
  waypoint types, working sets, UUID strategy, sync model, timestamp sources,
  KML import/export.

- **[UI Model](ui_model.md)** —
  Three concurrent UI surfaces (console, wx panels, Leaflet canvas), collection
  tree with checkbox visibility control, active and working set layers, Leaflet
  selection operations, session state persistence.

- **[Implementation](implementation.md)** —
  Module naming conventions, code organization, bottom-up implementation sequence
  by phase.

## Status

navMate implementation is underway. Foundation layers (schema, CRUD, wx panels, embedded
HTTP server) are built. Upload to E80 via WPMGR is implemented (`nmUpload.pm`): waypoints,
routes, and groups are uploaded from the collection tree context menu in `winBrowser.pm`.
A companion E80-side panel (`winE80.pm`) is under development. Basic Leaflet rendering of
routes and waypoints is partially built.

The underlying **NET transport layer** was redesigned in 2026-04 from a per-`recv()`
packet model to a **stream-based message extraction model** (see
[NET documentation](../../NET/docs/readme.md)). Upload to E80 — including delete of
routes with many waypoints — is confirmed working end-to-end.

Current focus: Leaflet renderer expansion (tracks, wp_type-based rendering,
click-to-select detail), `winE80.pm` E80-side panel, and import redesign from
`My Places.kml`. All 8 historical KML source folders have been fully characterized;
import rules are defined.

See the **[NET protocols documentation](../../NET/docs/readme.md)** for the
underlying RAYNET protocol library, and **[shark](../../apps/shark/docs/shark.md)**
for the companion engineering tool.

---

**Next:** [Architecture](architecture.md)
