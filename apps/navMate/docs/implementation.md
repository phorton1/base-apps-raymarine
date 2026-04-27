# navMate — Implementation Plan

**[Raymarine](../../../docs/readme.md)** --
**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**Implementation**

## Approach

navMate is built bottom-up. Each layer is exercisable before the layers above it
exist. The console window (inherited from the [shark](../../shark/docs/shark.md) pattern) is wired in early —
it provides a callable interface to lower layers before any wx panel or Leaflet
canvas exists.

The initial data population (KML import, phorton.com timestamp enrichment) is
handled by `migrate/` scripts rather than production modules. These run against
the real database and exercise the lower layers thoroughly before any UI is built.

## Module Structure

See [Architecture — Code Organization](architecture.md#code-organization) for the
full file list and naming conventions. In brief: lower layers use sparse alpha
prefixes with underscore-delimited lowercase names (`a_defs.pm`, `a_utils.pm`,
`c_db.pm`); application layer modules use camelCase (`nmServer.pm`, `winMain.pm`,
`winBrowser.pm`).

## Phase Sequence

### Phase 1 — Foundation (`a_defs.pm`, `a_utils.pm`, `c_db.pm`)  ✓ done

- UUID generation (byte 1 = `0x4E` for navMate-created objects)
- SQLite schema creation — all tables: collections (node_type: 'branch'/'group'), waypoints (with
  wp_type and color), routes, tracks, working sets
- CRUD operations; console window for smoke-testing

### Phase 2 — Data Population (`migrate/`)  ✓ substantially done; import being redesigned

One-time import scripts, not production modules. Single source:
`C:/junk/My Places.kml`. Config-driven per-folder rules for all 8 folders
(fully characterized before import rules were written — see Data Model).

- `_import_kml.pm` — config-driven import from `My Places.kml`; waypoints
  classified by wp_type and color at parse time
- `_enrich_phorton.pm` — cross-reference RhapsodyLogs/MandalaLogs track names
  against `C:\var\www\phorton\map_data\` index files; back-fill `ts_start`/`ts_end`;
  set `ts_source = 'phorton'`

### Phase 3 — wx Panels (`winMain.pm`, `winBrowser.pm`)  ✓ substantially done

- Main frame and collection tree with three-state checkboxes — built
- Collection labels derived from content counts — in progress
- Object detail panel (fixed-width font, full DB record) — in progress
- Upload to E80 via [WPMGR](../../../NET/docs/WPMGR.md) (`nmUpload.pm`): waypoints, routes, groups — built
- E80-side panel (`winE80.pm`): view E80 state, fileClient-style differencing — in progress
- Session state persistence (`nmSession.pm`) — planned

### Phase 4 — Leaflet Canvas (`nmServer.pm`, `_site/`)  in progress

- Embedded HTTP server with GeoJSON API — built (`nmServer.pm`)
- Route rendering (dashed line + waypoint markers) — partially built
- Track rendering (colored polylines from track_points) — pending
- Waypoint wp_type-based rendering (hollow circles, labels, sounding numbers) — pending
- Click-to-select persistent detail panel — pending
- Working set layer (distinct visual overlay) — planned
- Selection operations (rectangle, lasso, multi-select) — planned

### Phase 5 — Deduplication (`c_match.pm`)  planned

Requires the tree (Phase 3) and map (Phase 4) to be useful.
`c_match.pm` is the recurring service for all future import and sync work:

- Proximity search (`findNearbyWaypoints`) and name-similarity candidates
- Merge operations that rewrite all foreign-key references before discarding duplicates
- Dedup UI: collision candidates surfaced in the tree and visible on the map

`c_match.pm` is also called by Phase 7 sync for every incoming E80 object.

### Phase 6 — Domain Layer (`f_kml.pm`, `f_wrgt.pm`)  planned

- Production KML import/export with round-trip UUID embedding via `<ExtendedData>`
- WRT business logic — collection tree operations, working set operations
- KML export: reorganized, deduplicated output suitable as a clean GE archive

### Phase 7 — Transport (`j_transport.pm`)  planned

- NET adapter wired in as a session-level, user-activated transport
- E80 sync: UUID set reconciliation via [WPMGR](../../../NET/docs/WPMGR.md); incoming objects run through
  `c_match.pm` before insert
- Working set push: waypoints/routes via [RAYNET](../../../NET/docs/RAYNET.md); tracks via FSH export

---

**Back:** [UI Model](ui_model.md)
