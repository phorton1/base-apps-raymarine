# navMate - UI Model

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**UI Model** --
**[Implementation](implementation.md)** --
**[navOperations](navOperations.md)** --
**[Spoke Contract](navOps_spoke_contract.md)** --
**[KML Specification](kml_specification.md)** --
**[GE Notes](ge_notes.md)** --
**[Testing](testing.md)** --
**[winFSH](winFSH.md)** --
**[winMultiEditor](winMultiEditor.md)**

Folders: **[Raymarine](../../../docs/readme.md)** --
**[NET](../../../NET/docs/readme.md)** --
**[FSH](../../../FSH/docs/readme.md)** --
**[CSV](../../../CSV/docs/readme.md)** --
**[shark](../../../apps/shark/docs/shark.md)** --
**navMate**

## Overview

navMate runs four UI surfaces within a single process:

- **winDatabase** - navMate SQLite database tree: browse, edit, organize, sync
- **winE80** - live E80 device tree: browse, edit, sync routes, groups, waypoints, and tracks
- **winFSH** - FSH archive file browser: read-only inspection of a loaded `.fsh` file, with editor panel for in-memory edits prior to Save / Save As
- **Leaflet canvas** - geographic map view rendered in a browser, fed via the embedded HTTP server

winDatabase, winE80, and winFSH are full wx panels that open in the main notebook
frame. winDatabase and winE80 jointly form the navMate <-> E80 transfer surface;
winFSH is a third tree that sits alongside them for inspecting and converting
FSH archives. Each tree drives the same Leaflet canvas via per-source visibility
state.

The context-operations layer (copy / cut / paste / push / new / delete) is wired
into all three trees via `navClipboard.pm` and `navOps.pm`; each panel passes
its own source string (`'database'` / `'e80'` / `'fsh'`) when building the menu.
winFSH is a first-class navOps spoke -- the same Delete / New / Copy+Cut /
Push / Paste blocks appear there with FSH-side semantics implemented in
`navOps::navOpsFSH`.

Multi-item operations on homogeneous or eligible selections are surfaced by
two cross-tree dialogs:

- **Multi Edit** (`winMultiEditor.pm`) -- batch-edit shared properties (color,
  comment, type/sym) across a 2+ selection in winDatabase or winFSH. See
  [winMultiEditor](winMultiEditor.md) for the descriptor-driven design.
- **Rename...** (`winRename.pm`) -- pattern-with-`{N}`-token serial rename
  across a homogeneous waypoint/route/track/group selection in winDatabase
  or winFSH. Spoke-local; bypasses navOps deliberately.

---

## winDatabase - Collection Tree

`winDatabase.pm` presents the navMate SQLite database as a lazily-loaded wx tree.
Top-level nodes are root collections; child nodes are loaded on first expand
(`EVT_TREE_ITEM_EXPANDING`). A right-click context menu provides all edit and
transfer operations.

### Tree Node Types

| `type` | Description |
|---|---|
| `root` | Hidden tree root; right-click on it opens a paste-into-root context menu |
| `collection` | Folder or group in the navMate hierarchy |
| `object` | Waypoint, route, or track (discriminated by `obj_type`: `'waypoint'` / `'route'` / `'track'`) |
| `route_point` | An ordered waypoint within a route; carries both `uuid` (the waypoint) and `route_uuid` (the parent route) |

`collection` nodes carry `node_type` from the schema. The only persisted values
are `'branch'` (general organizer) and `'group'` (waypoint-only leaf that maps
to an E80 WPMGR group); see [Data Model: collections](data_model.md#collections).
Context menu items vary by `node_type` -- see [winDatabase Context Menu](#windatabase-context-menu).

### Layout

All three wx panels (winDatabase, winE80, winFSH) share the same layout:
an outer `Wx::SplitterWindow` with the tree on the left and a single grey
`Wx::Panel` (`right_panel`) on the right. The right panel holds the editor
widgets at the top (packed top-down by the `winTreeBase::_layoutEditor` walker
based on which fields the selected item type uses) and a read-only
**monospaced detail `TextCtrl`** (white background) immediately below them,
filling the remaining vertical space. One blank row of grey separates the two.
No inner splitter; the editor strip's height is determined by the selected item
type, not by a user-draggable sash. Multi-select (`wxTR_MULTIPLE`) is supported
in all three panels; Ctrl+click and Shift+click work normally.

Selecting a tree node updates both the editor panel (with type-appropriate fields)
and the detail TextCtrl (with the full structural / hex dump of the underlying
record).

#### winDatabase Editor Panel

The editor panel uses absolute positioning with named layout constants. All
controls are placed directly on the panel at computed positions - no intermediate
sub-panels. Name and comment (the long-string controls) resize with the panel.

**Header row:** The **Save** button occupies the upper-left (label column). A
bold title `StaticText` (displaying "Waypoint", "Route", "Track", "Branch", or
"Group") sits to its right (ctrl column). A **Visible** three-state checkbox
(`ed_visible`, `wxCHK_3STATE`) is placed to the right of the title.

**Field rows** are packed top-down by `winTreeBase::_layoutEditor` based on
node type (declared in each window's `$this->{_ed_field_widgets}` registry):

| Node type | Visible rows |
|---|---|
| Collection | name, comment |
| Waypoint | name, comment, lat, lon, wp_type, color, depth |
| Route | name, comment, color |
| Track | name, color |
| Route point | none (`_clearEditor`) |

Control details:
- **name, comment** - plain `TextCtrl`
- **lat, lon** - `TextCtrl` [110px] with a live DDM `StaticText` label (e.g. `9deg26.142' N`) that updates on every keystroke; `parseLatLon()` accepts DD or DDM with optional leading minus or N/S/E/W suffix
- **wp_type** - `Wx::Choice` with nav / label / sounding strings
- **color** - 28x20 swatch `Panel` (`wxSIMPLE_BORDER`) plus "Pick..." `Button`; opens `Wx::ColourDialog`; value round-trips as aabbggrr with alpha byte preserved; `_setColorSwatch()` converts aabbggrr -> `Wx::Colour` for display
- **depth** - `TextCtrl` [70px] plus a static unit label ("ft" or "m") from `$PREF_DEPTH_DISPLAY` (read at panel creation); `depth_cm = 0` displays as empty string; ft<->cm multiply/divide by 30.48, m<->cm multiply/divide by 100
- **Visible** checkbox - three-state; value loaded from the in-memory visibility state (navMate.json); shown for all node types except route_point

**Save button:** Disabled when the editor is clean; enabled on any field change.
Dirty state is silently discarded on node focus change. `_onSave` writes to the
database via `navDB` wrappers where available and direct SQL for collections and
tracks, then calls `$this->refresh()` to reload the tree and editor.

#### Tree Visibility Checkboxes

Each tree node displays a three-state checkbox icon (unchecked / checked / indeterminate).

- **Object nodes** (waypoint, route, track): checked or unchecked from in-memory visibility state
- **Collection nodes**: indeterminate when only some descendants are visible, determined
  by a recursive query across all descendants

Clicking the checkbox icon toggles visibility for terminal nodes or bulk-sets all
descendants for collection nodes, updates the Leaflet canvas accordingly, and
refreshes ancestor checkbox states.

### winDatabase Context Menu

The right-click context menu is assembled by `navOps::buildContextMenu('database', ...)`,
which delegates to `navClipboard.pm` for each block of items. Blocks are
separator-divided in this order: **Delete / New / Copy+Cut / Push / Paste**.
Below the navOps block, `winDatabase::_buildContextMenu` appends the
**Show/Hide on Map** and **Import/Export** items described in the next section.

What appears in each block depends on the right-clicked node's type
(`root`, `collection`, `object`, `route_point`) and -- for collections --
the `node_type` (`branch`, `group`):

| Block | branch | group | waypoint | route | track | route_point | root |
|---|---|---|---|---|---|---|---|
| **Delete** | Delete Branch | Delete Group / Delete Group + Waypoints | Delete Waypoint | Delete Route | Delete Track | Delete | - |
| **New** | Branch / Group / Route / Waypoint | Waypoint | Waypoint | Route | - | - | Branch / Group / Route / Waypoint |
| **Copy / Cut** | Copy / Cut | Copy / Cut | Copy / Cut | Copy / Cut | Copy / Cut | Copy / Cut | - |
| **Push** | - | Push to E80 (if all in WPMGR) | Push to E80 (if in WPMGR) | Push to E80 (if in WPMGR) | - | - | - |
| **Paste** | Paste / Paste New / Paste Before / After / Paste New Before / After | Paste / Paste New / Paste Before / After / Paste New Before / After | Paste Before / After / Paste New Before / After | Paste Before / After / Paste New Before / After | Paste Before / After / Paste New Before / After | (limited to within-route reorder) | Paste / Paste New |

Multi-select labels are pluralized ("Delete Waypoints", "Delete Groups + Waypoints",
etc.). Delete items present for collections and objects only when the entire
selection is of compatible types; mixed-type selections fall back to permissive
Copy/Cut and an empty Delete block.

**Push to E80** (`navOps::getPushMenuItems`) is offered when every selected node
has an existing counterpart on the E80 (`$wpmgr->{waypoints|routes|groups}` or
`$track->{tracks}`). It is a direct selection-based operation that does not use
the clipboard. The mirror operation **Push to DB** appears on the winE80 panel
when every selected E80 item has a counterpart already in the database.

**Paste** semantics are detailed in [navOperations](navOperations.md); the
six paste variants and their behaviour are summarised in
[Context Operations -- Clipboard Layer](#context-operations---clipboard-layer)
below.

#### Rename and Multi Edit

Two multi-item dialogs appear below the navOps block when the selection
qualifies:

- **Rename...** -- shown when `winRename::isRenameHomogeneous('database', @nodes)`
  reports a homogeneous waypoint / route / track / group selection.  Pattern
  with a `{N}` token plus pad-digits / start-index produces a serially-numbered
  new name per item.  DB writes go through the standard `navDB` update path
  (no preflight; the DB is deliberately unconstrained).
- **Multi Edit (N items)...** -- shown when the selection contains 2+ eligible
  waypoint / route / track items.  Opens `winMultiEditor` with the DB descriptor
  (ABGR color with Custom + Pick..., wp_type for waypoints, no comment limit).
  Commits run inside one SQLite transaction.  See [winMultiEditor](winMultiEditor.md).

#### Map and Import/Export Commands

The right-click menu also includes view-state and KML/GPS commands, gated by
node type. These appear below the navOps block (Delete / New / Copy+Cut / Push /
Paste), separated by a divider.

| Command | Available on | Action |
|---|---|---|
| Show on Map | any non-root node | Mark the node visible on the Leaflet canvas |
| Hide on Map | any non-root node | Mark the node hidden on the Leaflet canvas |
| Export KML file (.kml)... | any non-root node | Subtree export via `navKML::exportKMLSubtree($path, $uuid)`; the subtree's own top-level element lands directly under `<Document>` (no `navMate` wrapper). Default filename is the node's sanitized name |
| Import KML file (.kml)... | branch collection only | Subtree import via `navKML::importKMLSubtree($path, $target_uuid)`. Restricted to branches (not groups, not leaf objects) to keep the "import into container" semantics distinct from paste-before-node / paste-after-node |
| Import GPS file (.gpx[, .gdb])... | any collection (branch or group) | Import GPX (and `.gdb` when `gpsbabel` is on PATH) via `gpsImport::import_gps_file` |

Last-used directory for both KML dialogs is persisted under config key `kml_dir`,
shared with the top-level `Database -> Import KML` / `Export KML` commands.

---

## Main Menu

The top-level menu bar order is **View / Database / E80 / FSH / Utils**, defined
in `nmResources.pm`. View also includes Pub::WX-provided sub-items appended
after the navMate entries.

### View Menu

| Command | Description |
|---|---|
| Database | Opens a new winDatabase panel (multi-instance: each invocation creates an additional panel) |
| E80 | Opens (or focuses) the winE80 panel |
| Monitor | Opens (or focuses) the winMonitor console panel |
| FSH | Opens (or focuses) the winFSH panel |
| Open Map | Opens the Leaflet canvas in the default browser; no-op if already connected |
| Clear Map | Clears all in-memory visibility state (DB, E80, and FSH), clears the Leaflet canvas, and refreshes all tree checkboxes to unchecked; also triggered by the Leaflet `/clear` HTTP command |

### Database Menu

| Command | Description |
|---|---|
| Refresh Window | Reload all winDatabase panels from the current `navMate.db` |
| Commit | Prompts for a commit message, runs `git add navMate.db` + `git commit` against the local git repo; enabled only when `navMate.db` shows as dirty (polled every 2s via `git status --porcelain`) |
| Revert | Prompts for confirmation, runs `git restore navMate.db`, reopens the DB, refreshes all winDatabase panels; enabled only when dirty (same poll as Commit) |
| Save Outline | Captures the focused winDatabase tree's expansion state via `navOutline` and saves it |
| Restore Outline | Loads the saved outline and applies it to all winDatabase panels |
| Save Selection... | Prompts for a name, saves the focused winDatabase tree's current selection as a named set via `navSelection` |
| Restore Selection | Shows a picker of saved selection set names; applies the chosen set to the focused winDatabase tree |
| Import from Text | Replace the entire database from a `.txt` backup file; prompts for confirmation; calls `resetDB()` before importing |
| Export to Text | Export the entire database to a `.txt` backup file (one INSERT per table) |
| Import KML | Additive re-import from a navMate KML file; reconciles by UUID |
| Export KML | Export full database to a KML file with ExtendedData UUID embedding |
| Compact Positions | Renumber every container's child positions to 1.0, 2.0, 3.0, ...; prompts for confirmation. Used once to normalize legacy zero-positions, and thereafter for FLOAT precision-wall reclamation (see [Data Model: Compaction](data_model.md#position-computing-rules)) |

Import / Export Text both show a progress dialog ticking once per table.

### E80 Menu

| Command | Description |
|---|---|
| Refresh Window | Rebuilds the winE80 tree from current in-memory WPMGR/TRACK data; no network traffic |
| Refresh E80-DB | Re-queries all waypoints, routes, groups, and tracks from the E80 via WPMGR and TRACK protocols; shows a progress dialog; requires an active E80 connection |
| Clear | Deletes all routes, groups, waypoints, and tracks from the E80; prompts for confirmation showing item counts before proceeding; uses a progress dialog; enabled only when WPMGR is connected and the E80 has at least one item |

### FSH Menu

The FSH menu commands operate on the currently-loaded FSH archive
(`$navFSH::fsh_db` + `$navFSH::fsh_filename`). Save / Save As / Save Outline /
Restore Outline / Convert are enabled only when an FSH file is loaded.

| Command | Description |
|---|---|
| Open File... | Choose a `.fsh` file; loads it via `navFSH::loadFSH` and opens (or refreshes) the winFSH panel |
| Save File | Round-trip rewrite back to the current FSH filename; prompts for confirmation (overwrite warning) |
| Save File As... | Saves the in-memory FSH archive to a new `.fsh` file and switches the current filename |
| Convert to navMate Working Copy | In-memory transform: replace each multi-segment track with N single-segment `-NNN` named tracks; idempotent on already-converted single-segment tracks. Use Save File / Save As to persist |
| Save Outline | Saves the winFSH tree expansion state to its outline file (key `'fsh'` in `navOutline`) |
| Restore Outline | Loads the FSH outline and re-applies expansion state |

### Utils Menu

| Command | Description |
|---|---|
| OneTimeImportKML | Destructive: prompts for confirmation, then deletes and rebuilds the entire navMate database from the canonical KML source files via `navOneTimeImport::run()` |

---

## winE80 - Live E80 View

`winE80.pm` is a live view of the E80's WPMGR and TRACK in-memory state.
The tree is rebuilt whenever the global NET version counter increments
(meaning any WPMGR or TRACK item changed), with expansion and selection state
preserved across rebuilds. The panel uses the same editor-on-top +
detail-on-bottom layout as winDatabase (see [Layout](#layout)).

### Tree Structure

```
Groups
    My Waypoints           <- synthesized; waypoints not in any named group
        waypoint ...
    GroupName (N wps)
        waypoint ...
Routes
    RouteName (N pts)
        route_point ...    <- ordered waypoints in the route
Tracks (N)
    TrackName (N pts)
```

**My Waypoints** is synthesized: there is no UUID for it on the E80. winE80
constructs it from `$wpmgr->{waypoints}` entries absent from every named group's
`uuids` list. The `my_waypoints` node has no `uuid` field.

**Route children** - each route expands to `route_point` nodes, each carrying
both `uuid` (the waypoint UUID) and `route_uuid` (the parent route).

**Editor panel** - waypoint, group, and route nodes can be edited in place via
the editor panel's Name (15 char limit), Comment (31 char limit), Lat / Lon,
Sym (WPICON 0-39), Color (route color index), Depth, Temp, and Date / Time
controls. Field visibility is type-driven. Save commits the edit to WPMGR via
the existing wp/route/group APIs; the row is then refreshed on the next idle
tick.

**Detail pane** - uses `wpmgrRecordToText($item, 'WAYPOINT'|'GROUP'|'ROUTE', 2, 0, undef, $wpmgr)`,
which shows all semantic fields and suppresses structural and hex fields.

**Refresh cycle** - `nmFrame::onIdle` reacts to two signals: an
`onSessionStart` triggers the full tree rebuild when WPMGR has completed its
first query of a session; thereafter, `getVersion()` changes mark the tree
dirty, and a quiescence timer (no pending WPMGR commands + 200 ms idle) drives
an incremental `refresh()`. The ProgressDialog lifecycle is observed so the
tree does not rebuild while a multi-step E80 operation is in flight.

### winE80 Context Menu

winE80's context menu is built by the same
`navOps::buildContextMenu` / `navClipboard.pm` machinery as winDatabase, with
`'e80'` as the panel argument. Block order and semantics are identical:
**Delete / New / Copy+Cut / Push / Paste**. Below the navOps block,
`winE80::_buildContextMenu` appends:

- **Show on Map / Hide on Map** - on any non-root node
- **Clear E80 DB** - on the root node, when the E80 has any content (same as
  the E80 menu command)
- **Refresh winE80** - always

E80-specific routing rules:

- The `tracks` header and individual `track` nodes are **read-only**: no Delete,
  New, Copy, Cut, Push, or Paste appears for them (the TRACK service offers no
  upload or delete path).
- The `header:routes` and `header:tracks` and `header:groups` nodes expose
  bulk Delete (Delete Routes, Delete Tracks, Delete Groups / Delete Groups + Waypoints).
- **Push to DB** appears on E80 selections whose every member has a counterpart
  in the navMate DB. The mirror "Push to E80" appears on winDatabase.
- The pre-flight blocker for "Delete Waypoint" and "Delete Group + Waypoints"
  rejects (with a dialog) any waypoint that is a member of an existing route;
  the user must remove the route memberships first.
- **SS10.10 paste suppression**: when the clipboard holds a route whose member
  waypoints are missing from the E80, PASTE and PASTE_NEW are suppressed in
  winE80's menu; user must paste the waypoints first.

All E80 deletes show a modal `ProgressDialog`. The dialog's expected-step count
tracks the primary DEL_ITEM operation plus the GET_ITEM commands the E80
automatically generates (one per modified waypoint or route point) as MODIFY
events after the delete.

---

## winFSH - FSH Archive Browser

`winFSH.pm` is a tree browser for an FSH archive file loaded into memory by
`navFSH::loadFSH()`. It is single-instance (only one FSH file is loaded at a
time). Like winE80, it uses the editor-on-top + detail-on-bottom layout and
inherits from `winTreeBase`.

### Tree Structure

The shape parallels winE80:

```
<filename.fsh>
Groups
    My Waypoints           <- BLK_WPT standalone waypoints
        waypoint ...
    GroupName              <- BLK_GRP
        waypoint ...
Routes
    RouteName
        route_point ...
Tracks
    TrackName
        track_segment ...
```

The root node displays the loaded filename (basename only). The Groups / Routes
/ Tracks header nodes are unconditional even when empty.

### Editor Panel

Tree nodes are editable in memory; changes are written into `$navFSH::fsh_db`
and persisted only when the user issues FSH -> Save File or Save File As
(`navFSH::markDirty` flags the document and prefixes the root label with `*`).
Field visibility is type-driven, parallel to winDatabase / winE80:

| Node type | Visible rows |
|---|---|
| Waypoint | name, comment, lat, lon, sym, color, depth, temp, date, time |
| Group    | name |
| Route    | name, comment, color |
| Track    | name, color |

**Color** in winFSH is stored as a packed palette index (0..N), not as ABGR.
The Choice offers only the named E80 palette; the swatch is a read-only paint
computed from the selected index.  No Custom entry, no Pick... button, no
ABGR exposure in any FSH-context UI -- distinct from the winDatabase /
winE80 color editors that work in ABGR end-to-end.  **Sym** for waypoints
uses the full `WPICON_TABLE` (0..N).

FSH transport limits are enforced at write time: name <= 15 chars
(`$FSH_MAX_NAME`), comment <= 31 chars (`$FSH_MAX_COMMENT`).

### Context Menu

winFSH is a first-class navOps spoke. `navOps::buildContextMenu('fsh', ...)`
provides the same **Delete / New / Copy+Cut / Push / Paste** blocks as
winDatabase / winE80 (FSH-side semantics live in `navOps::navOpsFSH`). On top
of the navOps block, `winFSH::_buildContextMenu` appends:

- **Rename...** -- pattern-with-`{N}` serial rename, gated by
  `winRename::isRenameHomogeneous('fsh', @nodes)` on a homogeneous
  waypoint / route / track / group selection (N=1 allowed; the rename engine
  also handles single items).
- **Multi Edit (N items)...** -- when the selection contains 2+ eligible
  waypoint / route / track items.  Opens `winMultiEditor` with the FSH
  descriptor (palette-index color, sym for waypoints, comment hard-rejected
  past 31 chars).  See [winMultiEditor](winMultiEditor.md).
- **Show on Map / Hide on Map** -- any non-root node.
- **Find This...** -- waypoint / track / route only.

### Visibility

Checkboxes drive Leaflet visibility for FSH items independently of DB and E80
visibility. State is kept in `navVisibility` under the `fsh` namespace
(`getFSHVisible` / `setFSHVisible` / `getAllFSHVisibleUUIDs` /
`batchRemoveFSHVisible`).

---

## Context Operations - Clipboard Layer

`navClipboard.pm` owns the clipboard state and the menu-item generators.
`navOps.pm` owns command dispatch and the cross-panel orchestration; it
delegates the actual database and E80 work to `navOpsDB.pm` and `navOpsE80.pm`
respectively (both packaged under `navOps::` and loaded by `navOps.pm`).

### Clipboard State

```perl
$clipboard = {
    source          => 'database' | 'e80',
    cut_flag        => 0 | 1,            # 1 = cut (deferred-delete-after-paste)
    items           => [ { type => '...', uuid => '...', ... }, ... ],
    clipboard_class => 'paste' | 'push' | 'mixed',   # source='e80' only
};
```

There is no `intent` field. `source` records which panel the items came from;
`cut_flag` distinguishes Cut (identity-preserving move, set by `setCut`) from
Copy (fresh-UUID duplicate, set by `setCopy`). `items` holds opaque per-type
records sufficient for the destination panel to recreate or reference them.

`clipboard_class` is computed only for e80-sourced clipboards by
`_classifyE80Items`: each item is looked up in the navMate DB by UUID, and the
clipboard is classified as:

- **`'paste'`** -- no items already exist in the DB (a true copy into the DB)
- **`'push'`** -- all items already exist in the DB (a versioning push, not a duplicate)
- **`'mixed'`** -- some present, some absent (paste-into-DB and push-into-DB cannot
  both apply; the user is told to use Paste New to force duplicate creation)

`getClipboardText` formats the active clipboard for the status bar; the
"mixed" case appends a hint that Paste / Push are unavailable.

### Menu Generators

All menu generators live in `navClipboard.pm` and are called by
`navOps::buildContextMenu`:

| Generator | Returns |
|---|---|
| `getDeleteMenuItems($panel, $right_click_node, @nodes)` | Delete / Remove items keyed off node type; multi-select pluralises labels |
| `getNewMenuItems($panel, $right_click_node)` | New Branch / Group / Route / Waypoint, gated by node type and panel (E80 tracks header is empty) |
| `getCopyMenuItems($panel, @nodes)` | `Copy` for any non-empty selection that excludes the root node |
| `getCutMenuItems($panel, @nodes)` | `Cut` (same gating as Copy) |
| `getPushMenuItems($panel, $wpmgr, @nodes)` | `Push to E80` (DB panel) or `Push to DB` (E80 panel) when every selected node has a counterpart on the other side |
| `getPasteMenuItems($panel, $right_click_node)` | Up to six paste variants, gated by destination kind, cut/copy flag, and clipboard source/class |

### Paste Variants

Six paste commands are exported from `n_defs.pm`:

| Command | Use |
|---|---|
| `PASTE` | Insert into a collection-like destination, preserving identity (UUIDs) where the destination is a different panel from the source, or moving in-panel when the clipboard is a cut. Push to E80 of an in-DB item is rendered as `Push` rather than `Paste` for E80-source-with-DB-counterpart clipboards. |
| `PASTE_NEW` | Insert into a collection-like destination with **fresh** navMate UUIDs (forced duplication). Available only for Copy (not Cut). |
| `PASTE_BEFORE` / `PASTE_AFTER` | Insert positionally adjacent to an object / route_point / collection anchor (above or below in the position-sort order). Same identity rules as PASTE. |
| `PASTE_NEW_BEFORE` / `PASTE_NEW_AFTER` | Positional variants of PASTE_NEW (fresh UUIDs); available only for Copy. |

Destination kinds:

- **Collection-like** (accepts PASTE / PASTE_NEW *into* itself): in DB,
  `root` and any `collection` node; in E80, the Groups / Routes headers,
  `my_waypoints`, `group`, and `route` (treated as an ordered waypoint container).
- **Positional** (accepts PASTE_BEFORE / AFTER *next to* itself): in DB,
  any `object`, `route_point`, or `collection` (anything but `root`); in E80,
  `route_point` only.

A `route_point` anchor restricts non-NEW positional paste to clipboards
consisting entirely of `route_point` or `waypoint` items (a within-route
reorder); mixed clipboards are forced to the PASTE_NEW variants.

### Operation Dispatch

`navOps::onContextMenuCommand($cmd_id, $panel, $right_click_node, $tree, @nodes)`
is the single entry point from both winDatabase and winE80. It branches on the
command-ID ranges defined in `n_defs.pm`:

| CMD ID range | Handler |
|---|---|
| `$CTX_CMD_COPY` / `$CTX_CMD_CUT` | `_doCopy` / `_doCut` -- populate `$clipboard` via `setCopy` / `setCut` |
| `10210..10215` (PASTE family) | `_doPaste` -- routes to `_paste*` in `navOpsDB.pm` or `navOpsE80.pm` based on destination panel + variant |
| `10220..10226` (DELETE family) | `_doDelete` -- routes to `_delete*` / `_remove*` |
| `10230..10233` (NEW family) | `_doNew` -- routes to `_new*` |
| `$CTX_CMD_PUSH` | `_doPush` -- direct selection-based cross-panel sync |

The status bar reflects clipboard state via `navClipboard::getClipboardText`,
called from `setCopy` / `setCut` / `clearClipboard` and rendered by
`nmFrame::setClipboardStatus`.

For the complete specification of every operation -- pre-flight rules, paste
compatibility matrix, identity reconciliation, and HTTP test hooks -- see
[navOperations](navOperations.md).

### Cut Semantics

Cut is Copy with deferred per-item delete. The source row is not removed at
cut time. After each item is successfully created in the destination, the
corresponding source item is deleted. Items that are skipped or fail to paste
remain in the source. The cut indicator (greyed/italic tree style applied by
`_applyCutStyle`) is cleared once the operation completes.

### Push Semantics

Push is a direct, selection-based cross-panel operation -- the clipboard is
not used. The generator (`getPushMenuItems`) walks the current tree selection
and confirms every selected item has a counterpart on the other side:
- **DB panel -> Push to E80**: every selected waypoint / route / group must
  exist in `$wpmgr->{...}`.
- **E80 panel -> Push to DB**: every selected E80 item must already exist in
  the navMate DB (looked up by UUID).

If the check passes, the menu offers a single `Push to E80` / `Push to DB`
item which dispatches through `_doPush`. Push is the natural verb for
versioning sync: it implies the destination already has these items, and the
operation is a re-send of the current source state.

---

## Leaflet Canvas

The Leaflet canvas is the geographic surface. It runs as a static HTML/JS page
(`apps/navMate/_site/map.html` + `map.js` / `map.css` / `nmEdit.js` / `nmEdit.css`)
served by `navServer.pm` over HTTP on `localhost:9883`; the browser polls the
server for GeoJSON features and the server pushes incremental adds/removes as
the user toggles visibility.

### Rendering

- **Waypoints** - point markers; `wp_type` determines symbol:
  - `nav`: hollow colored circle; color from `waypoints.color`
  - `label`: text div at coordinate; the name is the visible label
  - `sounding`: depth number; red when `depth_cm` below critical threshold
- **Routes** - dashed polyline connecting ordered waypoints
- **Tracks** - solid colored polyline with start (green) and end (red) markers
  when selected for editing

Collections are not rendered in Leaflet; they exist only in the tree panels.

### Track and Route Editing

Track editing is implemented in `nmEdit.js` / `nmEdit.css` (Geoman is no longer
used). Selecting a track via the editor panel exposes per-vertex drag, insert,
delete, trim, split, and join operations; start/end markers are rendered green
and red. Route editing reuses the same `editSubject` abstraction (waypoint
append, in-route reorder); see the `route_edit_plan.md` design note for the
phased rollout.

### Visibility Model

Visibility state is persisted in `navMate.json` (in `$temp_dir`) and managed by
`navVisibility.pm`. State is partitioned by source -- DB, E80, FSH -- with
separate in-memory hashes and separate accessors:

| Source | Accessors | Tree |
|---|---|---|
| DB | `getDbVisible` / `setDbVisible` / `batchSetDbVisible` / `clearAllDbVisible` | winDatabase |
| E80 | `getE80Visible` / `setE80Visible` / `clearAllE80Visible` / `getAllE80VisibleUUIDs` / `batchRemoveE80Visible` | winE80 |
| FSH | `getFSHVisible` / `setFSHVisible` / `clearAllFSHVisible` / `getAllFSHVisibleUUIDs` / `batchRemoveFSHVisible` | winFSH |

Each tree displays three-state checkboxes (unchecked / checked / indeterminate);
checking or unchecking immediately updates the in-memory state for that source
and pushes a GeoJSON add/remove to Leaflet via `addRenderFeatures` /
`removeRenderFeatures`.  Render identity on the server is composite
(`"$source:$uuid"`), so DB / E80 / FSH versions of the same UUID coexist on
the map as distinct renderable features.  `addRenderFeatures` reads the
source from each feature's `data_source` property; `removeRenderFeatures`
takes an explicit `($source, $uuids_ref)` since callers do not have the
features at remove time.  Collection nodes bulk-set their descendants.

The persisted JSON file holds three top-level keys (`db_visibility`,
`e80_visibility`, `fsh_visibility`). It is loaded at startup
(`loadViewState`) and saved on clean frame close (`saveViewState` in
`nmFrame::onCloseFrame`).

Browser reconnect is handled entirely on the client (see `_site/map.js`
top-of-file comment): on fetch timeout or `visibilitychange`, the client
resets `_last_rendered_version` and the next successful poll triggers a
full `/geojson` resync.  The server has no reconnect notion -- it just
answers `/poll` and `/geojson`.  After a DB swap (revert), the DB pane
calls `resyncDbToLeaflet` to evict its previous contributions and
re-publish from the new DB state, scoped to source `'db'` so FSH and E80
features are unaffected.

---

## Session State

UI state persists across navMate invocations through three independent files:

| File | Owner | Contents |
|---|---|---|
| `<appdata>/navMate.ini` (Pub::WX::AppConfig) | `nmFrame` and each pane's `getDataForIniFile` | Window geometry, sash positions, winE80 expanded node keys (comma-joined), winFSH filename + sashes, last-used dialog directories (`db_backup_dir`, `kml_dir`, `fsh_dir`) |
| `$temp_dir/navMate.json` | `navVisibility.pm` | Per-source visibility hashes (`db_visibility`, `e80_visibility`, `fsh_visibility`); written on clean frame close, loaded at startup |
| `$temp_dir/navMate*Outline.json` | `navOutline.pm` | Tree expansion state per source (`db`, `fsh`); explicit Save / Restore Outline commands |

winDatabase tree expansion state is captured per panel into the outline file
on Save Outline / on frame close; winE80 expansion lives in the ini file and
restores automatically on panel open. winFSH expansion uses the outline
mechanism (`navOutline` key `'fsh'`).

---

**Next:** [Implementation](implementation.md)
