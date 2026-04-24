# navMate — Implementation Plan

**[Raymarine](../../../docs/readme.md)** --
**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**Implementation**

## Approach

navMate is built bottom-up. Each layer is exercisable before the layers above it
exist. The console window (inherited from the shark pattern) is wired in early —
it provides a callable interface to lower layers before any wx panel or Leaflet
canvas exists.

The initial data population (KML import, phorton.com timestamp enrichment) is
handled by `migrate/` scripts rather than production modules. These run against
the real database and exercise the lower layers thoroughly before any UI is built.

## Module Structure

See [Architecture — Code Organization](architecture.md#code-organization) for the
full file list and naming conventions. In brief: lower layers use sparse alpha
prefixes with underscore-delimited lowercase names (`a_defs.pm`, `a_utils.pm`,
`c_db.pm`, `f_kml.pm`, `j_transport.pm`); application layer modules use camelCase
(`nmSession.pm`, `winMain.pm`).

## Phase Sequence

### Phase 1 — Foundation (`a_defs.pm`, `a_utils.pm`, `c_db.pm`)

- UUID generation (byte 1 = `0x4E` for navMate-created objects)
- SQLite schema creation — all tables: collections, waypoints, routes, tracks,
  working sets
- Basic CRUD operations
- Console window attached for direct invocation and smoke-testing

### Phase 2 — Data Population (`migrate/`)

One-time import scripts, not production modules:

- KML import pipeline — Navigation.kml, voyage logs, historical material
- phorton.com enrichment pass — cross-reference track names against `map_data/`
  index files, back-fill `ts_start`/`ts_end`, set `ts_source = 'phorton'`

Produces a real, populated database for all subsequent development phases.

### Phase 3 — Domain Layer (`f_kml.pm`, `f_wrgt.pm`)

- Production KML import/export with round-trip UUID embedding via `<ExtendedData>`
- WRGT business logic — collection tree operations, working set operations
- UUID-primary lookups; name lookup as convenience layer only

### Phase 4 — wx Panels (`navMate.pm`, `winMain.pm`, `winTree.pm`, `nmSession.pm`)

- Main frame and collection tree panel with three-state checkboxes
- Visibility state drives what is available to the Leaflet layer
- Session state persistence (viewport, tree state, active working set)

### Phase 5 — Leaflet Canvas (`nmLeaflet.pm`, `_site/`)

- Embedded HTTP server serving `_site/` content
- Active layer: waypoints, routes, and tracks rendered per tree visibility
- Working set layer: distinct visual overlay showing push target
- Selection operations: rectangle, lasso, individual click, multi-select

### Phase 6 — Transport (`j_transport.pm`)

- NET adapter wired in as a session-level, user-activated transport
- E80 sync: UUID set reconciliation via WPMGR
- Working set push: waypoints/routes via RAYNET; tracks via FSH export

---

**Back:** [UI Model](ui_model.md)
