# navMate — UI Model

**[Raymarine](../../../docs/readme.md)** --
**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**UI Model** --
**[Implementation](implementation.md)** --
**[Context Menu](context_menu.md)** --
**[KML Specification](kml_specification.md)** --
**[GE Notes](ge_notes.md)**

## Overview

navMate runs three UI surfaces within a single process:

- **winDatabase** — navMate database tree: browse, edit, and upload collections
- **winE80** — live E80 device tree: view and delete routes, groups, and waypoints
- **Leaflet canvas** — geographic map view (partially implemented)

winDatabase and winE80 are the operative UI. They open as separate panels inside
the main notebook frame and together form a two-window transfer interface: items
can be uploaded from Database → E80, and items can be deleted from either side
independently. The Leaflet canvas is a planned third surface; the architectural
design is described below but it does not exist yet.

---

## winDatabase — Collection Tree

`winDatabase.pm` presents the navMate SQLite database as a lazily-loaded wx tree.
Top-level nodes are root collections; child nodes are loaded on first expand
(`EVT_TREE_ITEM_EXPANDING`). A right-click context menu provides all edit and
transfer operations.

### Tree Node Types

| `type` | Description |
|---|---|
| `collection` | Folder or group in the navMate hierarchy |
| `object` | Waypoint, route, or track (determined by `obj_type`) |
| `route_point` | An ordered waypoint within a route |

`collection` nodes carry `node_type` from the schema (`branch`, `group`, `routes`,
`tracks`, etc.). Context menu items vary by `node_type`.

### Layout

Both winDatabase and winE80 are `Wx::SplitterWindow` with a wx tree on the left
and a read-only monospaced text detail pane on the right. Selecting a tree node
populates the detail pane. Multi-select (`wxTR_MULTIPLE`) is supported in both
windows; Ctrl+click and Shift+click work normally.

### winDatabase Context Menu

| Node | Copy | Delete | New | Other |
|---|---|---|---|---|
| `collection` (branch) | All / Groups / Routes / Waypoints / Tracks | Delete Branch | Branch / Group / Route / Waypoint | Upload to E80 |
| `collection` (group) | Group / Waypoints | Delete Group / +WPs / +WPs+RPs | Branch / Group / Route / Waypoint | Upload to E80 |
| `object` (waypoint) | Waypoint | Delete Waypoint / +RoutePoints | — | — |
| `object` (route) | Route / Waypoints | Delete Route / +Waypoints | — | — |
| `object` (track) | Track | Delete Track | — | — |
| `route_point` | — | Remove RoutePoint | — | — |

**Upload to E80** — available on any `collection` node; calls
`nmUpload::uploadCollectionToE80` with a shared progress dialog. Uploads all
waypoints, routes, and groups in the collection.

### Database Menu

| Command | Description |
|---|---|
| Refresh Window | Reload the database tree from the current navMate.db |
| Import KML | Import (or re-import) `navMate.kml`; reconciles by UUID, additive |
| Export KML | Export full database to `navMate.kml` with ExtendedData UUID embedding |
| ExportToText | Export the entire database to a `.txt` backup file (one INSERT per table) |
| ImportFromText | Replace the entire database from a `.txt` backup file; prompts for confirmation |

ExportToText and ImportFromText both show a progress dialog ticking once per table (9 tables total). ImportFromText calls `resetDB()` before importing to ensure a clean schema.

**Paste** is always shown in the menu and enabled via `nmClipboard::canPaste`.

---

## winE80 — Live E80 View

`winE80.pm` is a read-only live view of the E80's WPMGR and TRACK in-memory
state. The tree is rebuilt whenever the global NET version counter increments
(meaning any WPMGR or TRACK item changed), with expansion and selection state
preserved across rebuilds.

### Tree Structure

```
Groups
    My Waypoints           ← synthesized; waypoints not in any named group
        waypoint ...
    GroupName (N wps)
        waypoint ...
Routes
    RouteName (N pts)
        route_point ...    ← ordered waypoints in the route
Tracks (N)
    TrackName (N pts)
```

**My Waypoints** is synthesized: there is no UUID for it on the E80. winE80
constructs it from `$wpmgr->{waypoints}` entries absent from every named group's
`uuids` list. The `my_waypoints` node has no `uuid` field.

**Route children** — each route expands to `route_point` nodes, each carrying
both `uuid` (the waypoint UUID) and `route_uuid` (the parent route).

**Detail pane** — uses `wpmgrRecordToText($item, $kind, 2, 0, undef, $wpmgr)`
at `detail_level=0`, which shows all semantic fields and suppresses structural
and hex fields.

**Refresh cycle** — triggered from `winMain::onIdle` when `getVersion()` changes,
gated by `$pending_commands == 0` so the tree does not rebuild while WPMGR
commands are still in flight.

### winE80 Context Menu — Delete Operations

All E80 deletes show a modal progress dialog. The dialog tracks the primary
DEL_ITEM operation plus the GET_ITEM commands that the E80 automatically generates
(one per modified waypoint or route point) as MODIFY events after the delete.

| Node | Delete options |
|---|---|
| `waypoint` | Delete Waypoint |
| `route_point` | Remove RoutePoint / Delete Waypoint |
| `route` | Delete Route |
| `group` | Delete Group / Delete Group + Waypoints |
| `my_waypoints` | Delete Group + Waypoints |
| `track` | Delete Track |

**Blocked deletes** — "Delete Waypoint" and "Delete Group + Waypoints" are
blocked (with a dialog) when the waypoint(s) are members of any route. Remove
the route memberships first.

**Tracks** — the TRACK service is read-only on the E80. Tracks are visible in
the tree but no delete or modify operations exist for them.

### winE80 Context Menu — Copy, Paste, New

The same `nmClipboard` machinery as winDatabase:

- **Copy** — copies the right-clicked node into the clipboard as a copy intent
  (waypoint, track, etc.); paste to Database is then enabled
- **Paste** — enabled when `canPaste` returns true for the clipboard intent and
  the target node type; currently only waypoint paste to E80 is implemented
- **New** — New Group and New Waypoint are offered on group-area nodes; New Route
  on the Routes header; not offered on tracks nodes (read-only)
- **Refresh E80** — forces an immediate tree rebuild regardless of version

---

## Context Operations — Clipboard Layer

`nmClipboard.pm` is the shared clipboard and context-menu generation layer used
by both windows. Neither window directly inspects node types for menu decisions;
all routing goes through nmClipboard.

### Clipboard State

```
$clipboard = {
    intent  => 'waypoint' | 'waypoints' | 'route' | 'routes' |
               'track'    | 'tracks'    | 'group' | 'groups' | 'all',
    source  => 'database' | 'e80',
    items   => [ { type => '...', uuid => '...', data => {...} }, ... ]
}
```

### Menu Generation

| Function | Purpose |
|---|---|
| `getCopyMenuItems($panel, @nodes)` | Copy items appropriate to the current selection |
| `getDeleteMenuItems($panel, $node)` | Delete items appropriate to the node type |
| `getNewMenuItems($panel, $node)` | New-object items; tracks nodes return empty |
| `canPaste($node, $panel)` | True when clipboard intent is compatible with the drop target |

`_analyzeNodes` categorizes the tree selection into type counts (`wp`, `route`,
`track`, `group`, `branch`, `header`); menu generation uses those counts to
decide which Copy options are available.

### Operation Dispatch

`onContextMenuCommand($cmd_id, $panel, $node, $tree)` in `nmClipboard.pm`
dispatches to:

- `nmOps::doCopy` — sets `$clipboard` via `nmClipboard::setCopy`
- `nmOps::doDelete` — routes to the correct `_delete*` or `_remove*` function in
  `nmOpsE80.pm` (E80 leg) or `nmOpsDB.pm` (database leg)
- `nmOps::doPaste` — routes to `_paste*` functions
- `nmOps::doNew` — routes to `_new*` functions

The clipboard status is reflected in the application status bar via
`nmClipboard::getClipboardText`.

### Implemented vs. Planned

**Implemented:**
- Copy: waypoint (single), track (single) — from either panel
- Paste waypoint: to database, to E80 (creates in named group or My Waypoints)
- Paste track: to database
- All delete operations listed in the winDatabase and winE80 tables above

**Not yet implemented (shows "not yet implemented" dialog):**
- Copy: group, groups, route, routes, all
- Paste: route, group, tracks to E80, and all multi-item variants

### Cut Semantics

Cut is Copy with deferred delete. The source item is not deleted at cut time;
it is deleted after each item is successfully created in the destination.
Items that are skipped or fail to paste remain in the source.

---

## Leaflet Canvas *(planned)*

The Leaflet canvas is the planned primary geographic surface. It is not yet
implemented; the wx tree windows are the operative UI for all geographic context.

### Intended Rendering

- **Waypoints** — point markers; `wp_type` determines symbol:
  - `nav`: hollow colored circle; color from `waypoints.color`
  - `label`: text div at coordinate; the name is the visible label
  - `sounding`: depth number; red when `depth_cm` below critical threshold
- **Routes** — dashed polyline connecting ordered waypoints
- **Tracks** — solid colored polyline

Collections are not rendered in Leaflet; they exist only in the database tree.

### Intended Visibility Model

A wx tree panel alongside the Leaflet canvas will present collections with
three-state checkboxes (checked / unchecked / partial). Checkbox state drives
what appears on the canvas:

- Checking a collection checks all descendants (and shows them)
- Unchecking a collection hides all descendants regardless of depth
- Partial state when some but not all descendants are checked

### Intended Two-Layer Canvas

**Active layer** — everything currently visible per checkbox state and viewport.

**Working set layer** — the current working set as a distinct visual overlay on
top of the active layer (color, opacity, or outline treatment TBD). Shows what
is selected for push to the connected device.

### Intended Selection Workflow

1. Browse the collection tree; check regions of interest → active layer populates
2. Draw a rectangle or lasso → items within bounds are selected
3. "Add to working set" → selected items appear in the working set layer
4. Inspect the working set layer; remove any items that don't belong
5. Upload working set to E80 (waypoints/routes via RAYNET; tracks via FSH export)

---

## Session State

UI state that persists between navMate invocations is stored in an ini-format
settings file alongside the main database (not in the database itself).

**Currently persisted:**
- winE80 expanded node keys — stored as a comma-joined string of node keys
  (UUIDs, `header:groups`, `header:routes`, `header:tracks`, `my_waypoints`, etc.)
- winE80 sash position (tree / detail split)
- winDatabase sash position

**Planned (not yet persisted):**
- Collection tree checkbox states (visibility)
- Currently active working set
- Last Leaflet viewport (center coordinates and zoom level)
- Full window geometry and panel layout

---

**Next:** [Implementation](implementation.md)
