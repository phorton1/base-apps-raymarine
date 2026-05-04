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

## Approach

navMate is built bottom-up. Each layer is exercisable before the layers above it
exist. The console window (inherited from the [shark](../../shark/docs/shark.md)
pattern) provides a callable interface to lower layers before any wx panel or
Leaflet canvas exists.

Module naming follows two zones: lower layers use sparse alpha prefixes with
underscore-delimited lowercase names (`a_defs.pm`, `c_db.pm`); application layer
modules use camelCase (`nmServer.pm`, `winMain.pm`). See
[Architecture — Code Organization](architecture.md#code-organization) for the full
file list and naming conventions.

## What Is Built

| Module | Status | Notes |
|--------|--------|-------|
| `a_defs.pm` | built | constants, type vocabulary, schema version |
| `a_utils.pm` | built | UUID generation, `$data_dir`/`$temp_dir` setup |
| `c_db.pm` | built | SQLite schema, all CRUD operations |
| `navMate.pm` | built | wx init, main loop |
| `nmServer.pm` | built | embedded HTTP server (port 9883), Leaflet bridge, GeoJSON API |
| `nmUpload.pm` | built | upload collections to E80 via WPMGR |
| `nmOpsDB.pm` | built | database-side context operations (copy, paste, delete, new) |
| `nmOpsE80.pm` | built | E80-side context operations |
| `nmOps.pm` | built | dispatch layer for context operations |
| `nmClipboard.pm` | built | clipboard state and context menu generation |
| `nmDialogs.pm` | built | shared modal dialogs |
| `nmOldE80.pm` | built | oldE80 archaeology import tools |
| `nmOneTimeImport.pm` | built | one-time KML migration from `navMate.kml` |
| `winMain.pm` | built | main frame, menu dispatch |
| `winDatabase.pm` | built | collection tree + detail panel; context menu |
| `winE80.pm` | built | live E80 device tree; view and delete operations |
| `winMonitor.pm` | built | console/log monitor panel |
| `w_frame.pm` | built | wx frame/panel base utilities |
| `w_resources.pm` | built | wx resource constants (IDs, menus) |
| `nmKML.pm` | built | KML import/export with ExtendedData UUID round-trip |

---

**Back:** [UI Model](ui_model.md)
