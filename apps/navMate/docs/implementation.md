# navMate — Implementation Reference

**[Raymarine](../../../docs/readme.md)** --
**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**Implementation** --
**[Context Menu](context_menu.md)** --
**[KML Specification](kml_specification.md)** --
**[GE Notes](ge_notes.md)**

navMate is built bottom-up: each layer is exercisable before the layers above it exist. The console window (inherited from the [shark](../../shark/docs/shark.md) pattern) provides a callable interface to lower layers before any wx panel or Leaflet canvas is present. Lower layers use sparse alphabetic prefixes (`a_`, `c_`) with underscore-delimited lowercase names; application layer modules use camelCase. No lower-layer module may import from a higher-prefixed module.

navMate links the [NET](../../../NET/docs/readme.md) library directly into its process — not as a daemon or socket service. The NET layer provides the RAYNET protocol stack, WPMGR and TRACK services, and the HTTP server base. See the NET documentation for that layer's own module structure.

## Foundation layer — a_, c_

`a_defs.pm` and `a_utils.pm` form the no-dependency base. `a_defs` defines constants, type vocabulary, and the current schema version. `a_utils` provides UUID generation and establishes `$data_dir` and `$temp_dir` for the process. `c_db.pm` is the SQLite layer — it owns the schema DDL and all raw CRUD operations against navMate.db, including the `promoteWaypointOnlyBranches` post-import pass. `nmPrefs.pm` is the preferences module; it wraps `Pub::Prefs` and re-exports its full API (except `initPrefs`), adding navMate-specific constants (`$DEPTH_DISPLAY_METERS`, `$DEPTH_DISPLAY_FEET`, `$PREF_DEPTH_DISPLAY`) and `init_prefs()`, which calls `Pub::Prefs::initPrefs` against `$data_dir/navMate.prefs` with `$DEPTH_DISPLAY_FEET` as the default. Callers `use nmPrefs` and get the complete `Pub::Prefs` API; no caller needs `use Pub::Prefs` directly. Nothing in this layer carries any wx dependency; it is exercisable from a console-only process.

## Data transport — nmKML, nmUpload, nmOneTimeImport, nmOldE80

This group moves data between navMate's SQLite store and external systems with no wx dependency.

`nmKML.pm` implements bidirectional KML import/export with ExtendedData UUID round-trip; it is the ongoing mechanism for all KML/GE interchange. `nmUpload.pm` handles upload of collections to the E80 via WPMGR. `nmOneTimeImport.pm` performed the initial database population from a GE export and is retained as a fallback; it is not used in normal operation. `nmOldE80.pm` provides archaeology import tools for the oldE80 dataset.

## Context operations — nmClipboard, nmOps, nmOpsDB, nmOpsE80, nmDialogs, nmTest

These modules implement the context menu feature spanning both panels.

`nmClipboard.pm` owns the clipboard state and generates the context menu item sets for both panels — neither window directly inspects node types for menu decisions. `nmOps.pm` is the dispatch layer; it routes each command to `nmOpsDB.pm` (database-side operations) or `nmOpsE80.pm` (E80-side operations). `nmDialogs.pm` provides shared modal dialogs used across this layer. `nmTest.pm` is the HTTP-driven test dispatcher: it receives commands from the `/api/test` endpoint, walks the tree to set selection and right-click state, and calls `onContextMenuCommand` directly — the same code path as a real user interaction.

## HTTP server — nmServer

`nmServer.pm` extends `h_server.pm` from the NET library to provide navMate's embedded HTTP server on port 9883. It exposes the `/api/` endpoints: ring buffer log, command dispatch, database queries (`/api/nmdb`), GeoJSON features for Leaflet, and test dispatch. The Leaflet applet HTML/JS in `_site/` is served by this module.

## wx layer — navMate.pm, winMain, winDatabase, winE80, winMonitor, w_frame, w_resources

`navMate.pm` is the wx process boundary — it initializes the wx application and runs the main loop. `winMain.pm` owns the top-level frame and menu dispatch; its `onIdle` handler is the heartbeat that drives WPMGR callbacks, tree refresh, and test dispatch.

`winDatabase.pm` presents the navMate SQLite database as a lazily-loaded wx tree with a read-only detail pane; it is the primary interface for browsing, organizing, and uploading data. `winE80.pm` presents the live E80 device state as a tree rebuilt whenever the NET version counter increments. `winMonitor.pm` is the console/log monitor panel.

`w_frame.pm` and `w_resources.pm` provide shared wx base utilities and resource constants (IDs, menu constants) used across all window modules.

## Standalone tools

`_e80_dedup.pm` is a standalone script (`package main`) for oldE80 archaeology — waypoint dedup and track strand matching against reference tracks. It is run directly from the command line and is not imported by the running application.

---

**Back:** [UI Model](ui_model.md)
