# navMate - Implementation Reference

**[Raymarine](../../../docs/readme.md)** --
**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**Implementation** --
**[navOperations](navOperations.md)** --
**[KML Specification](kml_specification.md)** --
**[GE Notes](ge_notes.md)**

navMate is built bottom-up: each layer is exercisable before the layers above it exist. The console window (inherited from the [shark](../../shark/docs/shark.md) pattern) provides a callable interface to lower layers before any wx panel or Leaflet canvas is present. Modules use a four-tier lexical prefix convention: `n_` (foundational), `nav` (portable logic), `nm` (wx components), `win` (wx panes). No module may import from a higher layer.

navMate links the [NET](../../../NET/docs/readme.md) library directly into its process - not as a daemon or socket service. The NET layer provides the RAYNET protocol stack, WPMGR and TRACK services, and the HTTP server base. See the NET documentation for that layer's own module structure.

## Foundation layer - n_, nav (non-wx)

`n_defs.pm` and `n_utils.pm` form the no-dependency base. `n_defs` defines constants, type vocabulary, and the current schema version. `n_utils` provides UUID generation and establishes `$data_dir` and `$temp_dir` for the process. `navDB.pm` is the SQLite layer - it owns the schema DDL and all raw CRUD operations against navMate.db, including the `promoteWaypointOnlyBranches` post-import pass and an in-place migration runner in `openDB` that upgrades known prior schema versions to the current `'10.0'`. Exported visibility functions: `getCollectionVisibleState`, `setTerminalVisible`, `setCollectionVisibleRecursive`, `clearAllVisible`, `getAllVisibleFeatures`. `navPrefs.pm` is the preferences module; it wraps `Pub::Prefs` and re-exports its full API (except `initPrefs`), adding navMate-specific constants (`$DEPTH_DISPLAY_METERS`, `$DEPTH_DISPLAY_FEET`, `$PREF_DEPTH_DISPLAY`) and `init_prefs()`, which calls `Pub::Prefs::initPrefs` against `$data_dir/navMate.prefs` with `$DEPTH_DISPLAY_FEET` as the default. Callers `use navPrefs` and get the complete `Pub::Prefs` API; no caller needs `use Pub::Prefs` directly. Nothing in this layer carries any wx dependency; it is exercisable from a console-only process.

## Data transport - navKML, navUpload, navOneTimeImport, navOldE80

This group moves data between navMate's SQLite store and external systems with no wx dependency.

`navKML.pm` implements bidirectional KML import/export with ExtendedData UUID round-trip; it is the ongoing mechanism for all KML/GE interchange. `navUpload.pm` handles upload of collections to the E80 via WPMGR. `navOneTimeImport.pm` performed the initial database population from a GE export and is retained as a fallback; it is not used in normal operation. `navOldE80.pm` provides archaeology import tools for the oldE80 dataset.

## Context operations - navClipboard, navOps, navOpsDB, navOpsE80, navDialogs, navTest

These modules implement the context menu feature spanning both panels.

`navClipboard.pm` owns the clipboard state and generates the context menu item sets for both panels - neither window directly inspects node types for menu decisions. `navOps.pm` is the dispatch layer; it routes each command to `navOpsDB.pm` (database-side operations) or `navOpsE80.pm` (E80-side operations). `navDialogs.pm` provides shared modal dialogs used across this layer. `navTest.pm` is the HTTP-driven test dispatcher: it receives commands from the `/api/test` endpoint, walks the tree to set selection and right-click state, and calls `onContextMenuCommand` directly - the same code path as a real user interaction.

## HTTP server - navServer

`navServer.pm` extends `h_server.pm` from the NET library to provide navMate's embedded HTTP server on port 9883. It exposes the `/api/` endpoints: ring buffer log, command dispatch, database queries (`/api/nmdb`), GeoJSON features for Leaflet, and test dispatch. The Leaflet applet HTML/JS in `_site/` is served by this module. The `/poll` handler detects browser reconnect (gap >= 3 s since last poll) and signals via `pollBrowserConnectEvent()`; the `/clear` handler sets a flag consumed by `pollClearMapPending()`. Both are polled from `nmFrame::onIdle`.

## wx layer - navMate.pm, nmFrame, nmResources, winDatabase, winE80, winMonitor

`navMate.pm` is the wx process boundary - it initializes the wx application and runs the main loop. `nmFrame.pm` is the application frame: it owns the top-level menu dispatch, status bar, and `onIdle` heartbeat that drives WPMGR callbacks, tree refresh, and test dispatch. `nmResources.pm` defines shared wx resource constants (IDs, menu constants); `nmResources.pm` exports `$COMMAND_CLEAR_MAP = 10030` (View menu).

`winDatabase.pm` presents the navMate SQLite database as a lazily-loaded wx tree with an editor panel and read-only detail pane. The editor uses absolute positioning with named constants; the tree carries per-node visibility state images (unchecked/checked/indeterminate). `onBrowserConnect` and `onClearMap` handle Leaflet sync events dispatched from `nmFrame::onIdle`. `winE80.pm` presents the live E80 device state as a tree rebuilt whenever the NET version counter increments. `winMonitor.pm` is the console/log monitor panel.

## Standalone tools

`_e80_dedup.pm` is a standalone script (`package main`) for oldE80 archaeology - waypoint dedup and track strand matching against reference tracks. It is run directly from the command line and is not imported by the running application.

---

**Back:** [UI Model](ui_model.md)
