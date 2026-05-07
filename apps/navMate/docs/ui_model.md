# navMate — UI Model

**[Raymarine](../../../docs/readme.md)** --
**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**UI Model** --
**[Implementation](implementation.md)** --
**[nmOperations](nmOperations.md)** --
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

Both windows are `Wx::SplitterWindow` with a wx tree on the left. Selecting a
tree node populates the right pane. Multi-select (`wxTR_MULTIPLE`) is supported
in both windows; Ctrl+click and Shift+click work normally.

**winE80 right pane** — a single read-only monospaced detail `TextCtrl`.

**winDatabase right pane** — a nested `Wx::SplitterWindow` (`right_split`) with
an editor panel on top and the monospaced detail `TextCtrl` on the bottom (sash
opens at `$ED_INITIAL_SASH`; gravity 0 keeps the editor pane fixed on window resize).

#### winDatabase Editor Panel

The editor panel uses absolute positioning with named layout constants. All
controls are placed directly on the panel at computed positions — no intermediate
sub-panels. Name and comment (the long-string controls) resize with the panel.

**Header row:** The **Save** button occupies the upper-left (label column). A
bold title `StaticText` (displaying "Waypoint", "Route", "Track", "Branch", or
"Group") sits to its right (ctrl column). A **Visible** three-state checkbox
(`ed_visible`, `wxCHK_3STATE`) is placed to the right of the title.

**Field rows** are shown or hidden by `_ed_show_row` based on node type:

| Node type | Visible rows |
|---|---|
| Collection | name, comment |
| Waypoint | name, comment, lat, lon, wp_type, color, depth |
| Route | name, comment, color |
| Track | name, color |
| Route point | none (`_clearEditor`) |

Control details:
- **name, comment** — plain `TextCtrl`
- **lat, lon** — `TextCtrl` [110px] with a live DDM `StaticText` label (e.g. `9°26.142' N`) that updates on every keystroke; `parseLatLon()` accepts DD or DDM with optional leading minus or N/S/E/W suffix
- **wp_type** — `Wx::Choice` with nav / label / sounding strings
- **color** — 28×20 swatch `Panel` (`wxSIMPLE_BORDER`) plus "Pick…" `Button`; opens `Wx::ColourDialog`; value round-trips as aabbggrr with alpha byte preserved; `_setColorSwatch()` converts aabbggrr → `Wx::Colour` for display
- **depth** — `TextCtrl` [70px] plus a static unit label ("ft" or "m") from `$PREF_DEPTH_DISPLAY` (read at panel creation); `depth_cm = 0` displays as empty string; ft↔cm multiply/divide by 30.48, m↔cm multiply/divide by 100
- **Visible** checkbox — three-state; value loaded from the DB `visible` field; shown for all node types except route_point

**Save button:** Disabled when the editor is clean; enabled on any field change.
Dirty state is silently discarded on node focus change. `_onSave` writes to the
database via `c_db` wrappers where available and direct SQL for collections and
tracks, then calls `$this->refresh()` to reload the tree and editor.

#### Tree Visibility Checkboxes

Each tree node displays a three-state checkbox icon (unchecked / checked / indeterminate).

- **Object nodes** (waypoint, route, track): checked or unchecked from the `visible` DB column
- **Collection nodes**: indeterminate when only some descendants are visible, determined
  by a recursive DB query across all descendants

Clicking the checkbox icon toggles `visible` for terminal nodes or bulk-sets all
descendants for collection nodes, updates the Leaflet canvas accordingly, and
refreshes ancestor checkbox states.

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

### View Menu

| Command | Description |
|---|---|
| Open Map | Opens the Leaflet canvas in the default browser |
| Clear Map | Sets `visible=0` on all four tables, clears the Leaflet canvas, and refreshes all tree checkboxes to unchecked; also triggered by the Leaflet `/clear` HTTP command |

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

The full context menu feature is implemented across both panels. For the complete
specification of every operation, clipboard state, and paste compatibility matrix,
see [Context Menu](context_menu.md).

### Cut Semantics

Cut is Copy with deferred delete. The source item is not deleted at cut time;
it is deleted after each item is successfully created in the destination.
Items that are skipped or fail to paste remain in the source.

---

## Leaflet Canvas *(partial)*

The Leaflet canvas is the primary geographic surface. Basic rendering of routes
and waypoints is partially implemented; the wx tree windows remain the operative
UI for all geographic context until the full model described below is built.

### Intended Rendering

- **Waypoints** — point markers; `wp_type` determines symbol:
  - `nav`: hollow colored circle; color from `waypoints.color`
  - `label`: text div at coordinate; the name is the visible label
  - `sounding`: depth number; red when `depth_cm` below critical threshold
- **Routes** — dashed polyline connecting ordered waypoints
- **Tracks** — solid colored polyline

Collections are not rendered in Leaflet; they exist only in the database tree.

### Visibility Model

Visibility state is persisted in the `visible` column of navMate.db (0 = hidden,
1 = visible; default 0 on all new objects). The winDatabase tree displays all
nodes with three-state checkboxes; checking or unchecking a node immediately
updates the DB and the Leaflet canvas:

- Checking an object node sets `visible=1` and pushes a GeoJSON feature to Leaflet
- Unchecking removes the feature from Leaflet
- Checking a collection bulk-sets all descendants via `setCollectionVisibleRecursive`
  and pushes their features; unchecking pulls them all
- Collection nodes show indeterminate state when only some descendants are visible

On browser connect, `onBrowserConnect` clears the Leaflet canvas and re-pushes all
`visible=1` features, keeping the canvas in sync after page reload or reconnect.

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
- Collection tree visibility state — `visible` column in navMate.db (0/1 for all
  WRT objects and collections; persists across sessions)

**Planned (not yet persisted):**
- Currently active working set
- Last Leaflet viewport (center coordinates and zoom level)
- Full window geometry and panel layout

---

**Next:** [Implementation](implementation.md)
