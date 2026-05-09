# navMate - Context Menu Specification

**[Raymarine](../../../docs/readme.md)** --
**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)** --
**Context Menu** --
**[KML Specification](kml_specification.md)** --
**[GE Notes](ge_notes.md)**

## Overview

This document is the design specification for navMate's context menu feature. It defines
exhaustively every possible context menu configuration, the conditions under which each
command appears or is disabled, and the expected output of every non-null operation.

**Null entries are first-class.** A command that does not appear for a given context is
a positive assertion, not merely an absence. Menu-building functions (`getCopyMenuItems`,
`getCutMenuItems`, `getDeleteMenuItems`, `canPaste`, `canPasteNew`) are correct only when
they produce exactly the non-null entries specified here and suppress everything else.

The feature decomposes into two sequential matrices:

- **Matrix 1** - The initial right-click: `(panel, selection set) x command -> null | clipboard state | DB/E80 change`
- **Matrix 2** - The paste target: `(clipboard state, destination node) x {Paste, Paste New} -> null | operation`

The clipboard state is the interface between the two matrices - the finite output vocabulary
of Matrix 1 copy/cut operations and the input vocabulary of Matrix 2.


## 1. Selection Set Taxonomy

The **selection set** is the full set of selected items when the right-click occurs.
The **right-click node** is the specific item right-clicked (may or may not be in the
selection, but is always the target for paste and the driver for delete and new).

For **copy/cut**, the selection set determines which commands appear.
For **delete** and **new**, the right-click node type determines which commands appear.
For **paste**, the right-click node is the paste target.

Short codes are used as column headers in the matrices below. The `B-` and `E-` prefixes
are used when both panels appear in the same context; within panel-specific sections the
prefix is dropped.

### 1.1 Database Selection Sets

| Code  | Right-click node type | Selection contents                    |
|-------|-----------------------|---------------------------------------|
| D-WP1 | object/waypoint       | exactly 1 waypoint                    |
| D-WPN | object/waypoint       | 2+ waypoints (homogeneous)            |
| D-RP  | route_point           | exactly 1 route_point                 |
| D-RT1 | object/route          | exactly 1 route                       |
| D-RTN | object/route          | 2+ routes (homogeneous)               |
| D-TK1 | object/track          | exactly 1 track                       |
| D-TKN | object/track          | 2+ tracks (homogeneous)               |
| D-GR1 | collection/group      | exactly 1 group                       |
| D-GRN | collection/group      | 2+ groups (homogeneous)               |
| D-BR  | collection/branch     | 1 branch (any contents)               |
| D-MXW | any                   | mixed types, includes at least 1 WP   |
| D-MX0 | any                   | mixed types, no waypoints             |

### 1.2 E80 Selection Sets

| Code  | Node type                   | Selection contents                    |
|-------|-----------------------------|---------------------------------------|
| E-WP1 | waypoint                    | exactly 1 waypoint                    |
| E-WPN | waypoint                    | 2+ waypoints (homogeneous)            |
| E-RP  | route_point                 | exactly 1 route_point                 |
| E-RT1 | route                       | exactly 1 route                       |
| E-RTN | route                       | 2+ routes (homogeneous)               |
| E-TK1 | track                       | exactly 1 track                       |
| E-TKN | track                       | 2+ tracks (homogeneous)               |
| E-GR1 | group or my_waypoints       | exactly 1 group (or My Waypoints)     |
| E-GRN | group                       | 2+ groups (homogeneous)               |
| E-HDG | header (kind=groups)        | the groups header node                |
| E-HDR | header (kind=routes)        | the routes header node                |
| E-HDT | header (kind=tracks)        | the tracks header node                |


## 2. Database Context Menu - Matrix 1

### 2.1 Copy Commands

Cell values name the clipboard intent set by the command. `-` = command not shown.
All database copy operations set `source:database, cut:0`. The `cut:0` flag is implicit.

Selection set codes (column headers): **WP1** = D-WP1, **WPN** = D-WPN, **RP** = D-RP,
**RT1** = D-RT1, **RTN** = D-RTN, **TK1** = D-TK1, **TKN** = D-TKN, **GR1** = D-GR1,
**GRN** = D-GRN, **BR** = D-BR, **MXW** = D-MXW, **MX0** = D-MX0.

| Command   | WP1 | WPN | RP  | RT1 | RTN | TK1 | TKN | GR1 | GRN | BR  | MXW | MX0 |
|-----------|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|
| COPY-WP   | WP  | -   | WP  | -   | -   | -   | -   | -   | -   | -   | -   | -   |
| COPY-WPS  | -   | WPS | -   | WPS | WPS | -   | -   | WPS | WPS | WPS | WPS | -   |
| COPY-GR   | -   | -   | -   | -   | -   | -   | -   | GR  | -   | -   | -   | -   |
| COPY-GRS  | -   | -   | -   | -   | -   | -   | -   | -   | GRS | GRS | -   | -   |
| COPY-RT   | -   | -   | -   | RT  | -   | -   | -   | -   | -   | -   | -   | -   |
| COPY-RTS  | -   | -   | -   | -   | RTS | -   | -   | -   | -   | RTS | -   | -   |
| COPY-TK   | -   | -   | -   | -   | -   | TK  | -   | -   | -   | -   | -   | -   |
| COPY-TKS  | -   | -   | -   | -   | -   | -   | TKS | -   | -   | TKS | -   | -   |
| COPY-ALL  | -   | -   | -   | -   | -   | -   | -   | -   | -   | ALL | -   | -   |

Notes:
- D-RP counts as a single waypoint in `_analyzeNodes` (type=`route_point` -> `$c{wp}++`), producing COPY-WP.
- D-MX0 (mixed without waypoints, e.g. route + track selected) produces no copy commands at all.
- D-MXW (mixed including waypoints) produces only COPY-WPS - the non-waypoint types in the selection are ignored.
- D-BR produces the full five-command set: ALL + GRS + RTS + WPS + TKS.

### 2.2 Cut Commands

The null/non-null pattern is identical to Copy (Section 2.1). All cut operations set `cut:1`.
The table is omitted to avoid redundancy; substitute `CUT-` for `COPY-` in every row
and append `cut:1` to the clipboard state. The resulting clipboard states are defined
in the vocabulary (Section 5).

### 2.3 Delete Commands

Delete is driven by the **right-click node type**, not the full selection set. The
selection provides the item list; singular/plural labeling adjusts accordingly.
All database deletes require confirmation. `DEL-BR` is blocked (informational message)
if the branch is non-empty.

| Right-click node type | Commands shown        | Action                                                |
|-----------------------|-----------------------|-------------------------------------------------------|
| collection/branch     | DEL-BR                | Delete branch + all contents recursively              |
| collection/group      | DEL-GR, DEL-GR+WPS   | Delete group shell / group + all members              |
| object/waypoint       | DEL-WP                | Delete selected waypoint(s)                           |
| object/route          | DEL-RT                | Delete selected route(s); member WPs remain           |
| object/track          | DEL-TK                | Delete selected track(s) and track_points             |
| route_point           | DEL-RP                | Remove point from route; WP record preserved          |

`DEL-BR` is hidden (not shown) if any waypoint in the branch subtree is referenced by a
route that lives **outside** the branch subtree (`isBranchDeleteSafe` returns 0). When
all referencing routes are within the branch, the deletion is safe: routes, waypoints,
tracks, and sub-collections are all deleted together. Requires confirmation.

`DEL-WP` is additionally blocked (informational message) if any selected waypoint is
referenced in a route (`getWaypointRouteRefCount > 0`). Similarly `DEL-GR+WPS` is
blocked if any member WP is in a route.

`DEL-GR` dissolves the group: all member waypoints are reparented to the group's parent
collection, then the group shell is deleted. Route references to member WPs are
unaffected (UUIDs preserved). Requires confirm.

`DEL-BR` is the primary bulk-delete path for the database panel.

### 2.4 New Commands

New is driven by the right-click node type only; selection has no effect.

| Right-click node type | Commands shown                 |
|-----------------------|--------------------------------|
| collection (any)      | NEW-BR, NEW-GR, NEW-RT, NEW-WP |
| object (any)          | - (none)                       |
| route_point           | - (none)                       |


## 3. E80 Context Menu - Matrix 1

### 3.1 Copy Commands

All E80 copy operations set `source:e80, cut:0`.

Selection set codes: **WP1** = E-WP1, **WPN** = E-WPN, **RP** = E-RP, **RT1** = E-RT1,
**RTN** = E-RTN, **TK1** = E-TK1, **TKN** = E-TKN, **GR1** = E-GR1, **GRN** = E-GRN,
**HDG** = E-HDG, **HDR** = E-HDR, **HDT** = E-HDT.

| Command   | WP1 | WPN | RP  | RT1 | RTN | TK1 | TKN | GR1 | GRN | HDG | HDR | HDT |
|-----------|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|
| COPY-WP   | WP  | -   | WP  | -   | -   | -   | -   | -   | -   | -   | -   | -   |
| COPY-WPS  | -   | WPS | -   | WPS | WPS | -   | -   | WPS | WPS | WPS | WPS | WPS |
| COPY-GR   | -   | -   | -   | -   | -   | -   | -   | GR  | -   | -   | -   | -   |
| COPY-GRS  | -   | -   | -   | -   | -   | -   | -   | -   | GRS | GRS | GRS | GRS |
| COPY-RT   | -   | -   | -   | RT  | -   | -   | -   | -   | -   | -   | -   | -   |
| COPY-RTS  | -   | -   | -   | -   | RTS | -   | -   | -   | -   | RTS | RTS | RTS |
| COPY-TK   | -   | -   | -   | -   | -   | TK  | -   | -   | -   | -   | -   | -   |
| COPY-TKS  | -   | -   | -   | -   | -   | -   | TKS | -   | -   | TKS | TKS | TKS |
| COPY-ALL  | -   | -   | -   | -   | -   | -   | -   | -   | -   | ALL | ALL | ALL |

Notes:
- All three header types (HDG, HDR, HDT) produce the same five-command set because
  `_analyzeNodes` classifies them all identically (`$c{header}++`). This means the
  routes header and tracks header each offer COPY-GRS, COPY-TKS, etc. - commands
  that are semantically irrelevant to their context. See **GAP-03**.
- E-GR1 includes the `my_waypoints` node type, which counts as `$c{group}++`.

### 3.2 Cut Commands

Null/non-null pattern is identical to E80 Copy (Section 3.1); substitute `CUT-` and set `cut:1`.

### 3.3 Delete Commands

| Right-click node type | Commands shown               | Action                                    |
|-----------------------|------------------------------|-------------------------------------------|
| waypoint (single)     | DEL-WP                       | Delete waypoint from E80                  |
| waypoint (multi)      | DEL-WP (plural label)        | Delete selected waypoints from E80        |
| route_point           | DEL-RP, DEL-WP               | Remove from route / delete WP entirely    |
| route                 | DEL-RT                       | Delete route from E80                     |
| group                 | DEL-GR, DEL-GR+WPS           | Delete group shell / group + members      |
| my_waypoints          | DEL-GR+WPS                   | Delete all ungrouped waypoints            |
| track                 | DEL-TK                       | Send TRACK erase command to E80           |
| header/routes         | DEL-RT (plural label)        | Delete all routes from E80                |
| header/groups         | DEL-GR, DEL-GR+WPS (plural)  | Delete all groups / groups + members      |
| header/tracks         | - (none)                     | Read-only; no delete offered              |

### 3.4 New Commands

| Right-click node type | Commands shown         |
|-----------------------|------------------------|
| header/groups         | NEW-GR, NEW-WP         |
| header/routes         | NEW-RT                 |
| my_waypoints          | NEW-WP                 |
| group                 | NEW-WP                 |
| route                 | NEW-RT, NEW-WP         |
| waypoint              | - (none)               |
| route_point           | - (none)               |
| header/tracks         | - (read-only)          |
| track                 | - (read-only)          |


## 4. Clipboard State Vocabulary

All valid clipboard states produced by the copy/cut matrices above. The code prefix
`D-CP` = database copy, `D-CT` = database cut, `E-CP` = E80 copy, `E-CT` = E80 cut.

| Code     | intent    | source  | cut |
|----------|-----------|---------|-----|
| D-CP-WP  | waypoint  | database | 0   |
| D-CP-WPS | waypoints | database | 0   |
| D-CP-GR  | group     | database | 0   |
| D-CP-GRS | groups    | database | 0   |
| D-CP-RT  | route     | database | 0   |
| D-CP-RTS | routes    | database | 0   |
| D-CP-TK  | track     | database | 0   |
| D-CP-TKS | tracks    | database | 0   |
| D-CP-ALL | all       | database | 0   |
| D-CT-WP  | waypoint  | database | 1   |
| D-CT-WPS | waypoints | database | 1   |
| D-CT-GR  | group     | database | 1   |
| D-CT-GRS | groups    | database | 1   |
| D-CT-RT  | route     | database | 1   |
| D-CT-RTS | routes    | database | 1   |
| D-CT-TK  | track     | database | 1   |
| D-CT-TKS | tracks    | database | 1   |
| D-CT-ALL | all       | database | 1   |
| E-CP-WP  | waypoint  | e80     | 0   |
| E-CP-WPS | waypoints | e80     | 0   |
| E-CP-GR  | group     | e80     | 0   |
| E-CP-GRS | groups    | e80     | 0   |
| E-CP-RT  | route     | e80     | 0   |
| E-CP-RTS | routes    | e80     | 0   |
| E-CP-TK  | track     | e80     | 0   |
| E-CP-TKS | tracks    | e80     | 0   |
| E-CP-ALL | all       | e80     | 0   |
| E-CT-WP  | waypoint  | e80     | 1   |
| E-CT-WPS | waypoints | e80     | 1   |
| E-CT-GR  | group     | e80     | 1   |
| E-CT-GRS | groups    | e80     | 1   |
| E-CT-RT  | route     | e80     | 1   |
| E-CT-RTS | routes    | e80     | 1   |
| E-CT-TK  | track     | e80     | 1   |
| E-CT-TKS | tracks    | e80     | 1   |
| E-CT-ALL | all       | e80     | 1   |


## 5. Paste Compatibility Matrix (Matrix 2)

**Paste** (UUID-preserving) and **Paste New** (fresh UUIDs) are shown as enabled (`Y`)
or disabled (`-`). Disabled means `canPaste` or `canPasteNew` returns 0 - the menu
item appears but is greyed out.

### 5.1 Database Destination

Destination node type is what was right-clicked as the paste target.

| Clipboard state        | Dest node        | Paste | Paste New | Semantic                            |
|------------------------|------------------|-------|-----------|-------------------------------------|
| D-CP-WP / D-CP-WPS     | any database node | -     | Y         | Duplicate with fresh UUID(s)        |
| D-CT-WP / D-CT-WPS     | any database node | Y     | -         | Move - re-home `collection_uuid`    |
| D-CP-GR / D-CP-GRS     | collection       | -     | Y         | Duplicate group(s) + fresh UUIDs    |
| D-CT-GR / D-CT-GRS     | collection       | Y     | -         | Move - re-home `parent_uuid`        |
| D-CP-RT / D-CP-RTS     | collection       | -     | Y         | Duplicate route(s) + fresh WP UUIDs |
| D-CT-RT / D-CT-RTS     | collection       | Y     | -         | Move - re-home `collection_uuid`    |
| D-CP-TK / D-CP-TKS     | collection       | -     | -         | No paste path (copy-only is blocked)|
| D-CT-TK / D-CT-TKS     | collection       | Y     | -         | Move - re-home `collection_uuid`    |
| D-CP-ALL               | collection       | -     | Y         | Duplicate branch contents, fresh UUIDs |
| D-CT-ALL               | collection       | Y     | -         | Move branch contents to new collection |
| D-CP-ALL / D-CT-ALL    | root             | -     | -         | Root is not a schema collection        |
| E-CP-WP / E-CP-WPS     | any database node | Y     | Y         | Download / download+duplicate       |
| E-CT-WP / E-CT-WPS     | any database node | Y     | -         | Download + delete from E80          |
| E-CP-GR / E-CP-GRS     | collection       | Y     | Y         | Download group(s)                   |
| E-CT-GR / E-CT-GRS     | collection       | Y     | -         | Download + delete from E80          |
| E-CP-RT / E-CP-RTS     | collection       | Y     | Y         | Download route(s)                   |
| E-CT-RT / E-CT-RTS     | collection       | Y     | -         | Download + delete from E80          |
| E-CP-TK / E-CP-TKS     | collection       | Y     | -         | Download track (no Paste New)       |
| E-CT-TK / E-CT-TKS     | collection       | Y     | -         | Download + E80 delete               |
| E-CP-ALL / E-CT-ALL    | collection       | Y     | -         | Download all; tracks included       |
| any                    | non-collection   | -     | -         | Target incompatible (WP/RT/TK/GR)  |

Note: waypoint/waypoints intent (`canPaste` check) returns `Y` for **any** database
destination node, not just collections. The implementation (`_pasteWaypointToDatabase`)
enforces the collection requirement with a `warning()` sentinel (ring buffer, no dialog).
Groups, routes, tracks, and all require a `collection` target node at the `canPaste` level.

### 5.2 E80 Destination

| Clipboard state              | Dest node type              | Paste | Paste New | Semantic                   |
|------------------------------|-----------------------------|-------|-----------|----------------------------|
| D-CP-WP / D-CP-WPS          | header, mywp, group,        | -     | Y         | Upload+duplicate (copy)    |
|                              | route, waypoint, route_pt   |       |           |                            |
| D-CT-WP / D-CT-WPS          | any E80 node                | -     | -         | DB->E80 cut blocked         |
| D-CT-GR / D-CT-GRS          | any E80 node                | -     | -         | DB->E80 cut blocked         |
| D-CT-RT / D-CT-RTS          | any E80 node                | -     | -         | DB->E80 cut blocked         |
| D-CT-TK / D-CT-TKS          | any E80 node                | -     | -         | DB->E80 cut blocked         |
| D-CT-ALL                    | any E80 node                | -     | -         | DB->E80 cut blocked         |
| E-CP-WP / E-CP-WPS          | header, mywp, group,        | Y     | Y         | Upload / upload+duplicate  |
|                              | route, waypoint, route_pt   |       |           |                            |
| E-CT-WP / E-CT-WPS          | same set as above           | Y     | -         | Upload + delete from E80   |
| D-CP-GR / D-CP-GRS          | header/groups               | Y     | Y         | Upload group(s) (copy)     |
| E-CP-GR / E-CP-GRS          | header/groups               | Y     | Y         | Upload group(s)            |
| E-CT-GR / E-CT-GRS          | header/groups               | Y     | -         | Upload + delete from E80   |
| D-CP-RT / D-CP-RTS          | header/routes               | Y     | Y         | Upload route(s) (copy)     |
| E-CP-RT / E-CP-RTS          | header/routes               | Y     | Y         | Upload route(s)            |
| E-CT-RT / E-CT-RTS          | header/routes               | Y     | -         | Upload + delete from E80   |
| any TK intent                | any E80 node                | -     | -         | Tracks read-only on E80    |
| D-CP-ALL / E-CP-ALL         | root                        | Y     | -         | Upload all; tracks skipped |
| E-CT-ALL                    | root                        | Y     | -         | Upload all + delete source |
| any ALL intent               | non-root E80 node           | -     | -         | Root is the only ALL target|
| any                          | header/tracks or track      | -     | -         | Target incompatible        |

Note: `D-CT-*` -> E80 is blocked entirely by `canPaste` (`cut=1 && source=database && panel=e80`).
The database is the authoritative repository; uploading to E80 is always a copy operation.
E80->DB cut (download + erase from E80) remains fully supported.


## 6. Operation Semantics

### 6.1 Paste to Database - E80 Source (download)

UUID-preserving merge into the navMate DB. For each item:
- UUID not in DB -> insert record in target collection.
- UUID in DB, data identical -> no-op (`no_change`).
- UUID in DB, data differs -> conflict dialog: Replace / Skip / Replace All / Skip All / Abort.

Groups: group collection created under target if absent (merge semantics - existing
members preserved). Member WPs merged individually per above.

Routes: member WPs merged into target collection individually. Route record inserted or
updated. Route waypoint list rebuilt as a set (cleared and replaced from clipboard).

Cut variant: after each item is successfully pasted (result not `skipped` or `aborted`),
the source item is deleted from E80 via WPMGR commands.

### 6.2 Paste to Database - Database Source, Cut (move)

Re-homes the object to the new collection without changing its UUID. No conflict check.
No separate delete step - the move IS the cut.

- Waypoints: `UPDATE waypoints SET collection_uuid = ? WHERE uuid = ?`
- Groups: `UPDATE collections SET parent_uuid = ? WHERE uuid = ?`
- Routes: `UPDATE routes SET collection_uuid = ? WHERE uuid = ?`
- Tracks: `UPDATE tracks SET collection_uuid = ? WHERE uuid = ?`

A group move carries only the group shell; member waypoints stay inside the group
and travel with it automatically (they reference the group's UUID, not the parent).

A route move carries only the route record; member waypoints remain in whatever
collection they currently occupy.

### 6.3 Paste New to Database

Always inserts with fresh navMate UUIDs regardless of source. No conflict check.
Only available for copy (not cut) - `canPasteNew` returns 0 when `cut:1`.

Routes: each member waypoint also receives a fresh UUID; the new route record
references the new WP UUIDs.

Track Paste New is not available (`canPasteNew` blocks all track intents). Database
track duplication requires Cut+Paste (move) or future explicit support.

### 6.4 Paste to E80 (upload)

Sends WPMGR `NEW_ITEM` commands. E80 assigns its own UUIDs. Order of operations:
- Waypoints: one NEW_ITEM per WP; followed by GET_ITEM to confirm.
- Groups: group created first, then member WPs created inside it.
- Routes: member WPs created first, then route created referencing them by E80 UUID.

Cut variant: only available when source=E80. After successful paste, source item is
deleted from E80 via WPMGR commands. Database-source cut to E80 is blocked by `canPaste`.

### 6.5 Delete (database)

- `DEL-WP`: blocked if any selected WP has `route_waypoints` references. Requires confirm.
- `DEL-GR`: dissolves the group. All member waypoints are reparented to the group's parent collection (`collection_uuid` updated in place), then the group shell is deleted. Route references to member WPs are unaffected (UUIDs unchanged). Requires confirm.
- `DEL-GR+WPS`: blocked if any member WP is in a route. Requires confirm.
- `DEL-RT`: deletes route and `route_waypoints` rows; member WPs preserved. Requires confirm.
- `DEL-TK`: deletes track and `track_points` rows. Requires confirm.
- `DEL-BR`: recursively deletes the branch and all its descendants (sub-collections,
  waypoints, routes, route_waypoints, tracks, track_points). Hidden (not shown) if any
  member WP is referenced by a route outside the branch subtree (`isBranchDeleteSafe`
  returns 0). Requires confirm.
- `DEL-RP`: removes one `route_waypoints` row (by position); WP record preserved. Requires confirm.

### 6.6 Delete (E80)

WPMGR DELETE commands handle waypoints, routes, and groups. `DEL-TK` sends a TRACK
erase command via `queueTRACKCommand`; end-to-end verification of the erase path is
pending. `DEL-GR` leaves member waypoints ungrouped. `DEL-GR+WPS` deletes the group
and its member WPs.


## 7. Testing

### 7.1 Machinery

Context menu operations are driven programmatically via the `/api/test` HTTP endpoint
(port 9883). The HTTP thread encodes the query params as JSON and stores them in a
shared variable; `winMain::onIdle` picks up the command within ~20 ms and calls
`nmTest::dispatchTestCommand`, which walks the tree to set the selection and right-click
node, then calls `onContextMenuCommand` directly - identical to a real right-click +
menu pick. Results appear in the ring buffer.

```
GET http://localhost:9883/api/test?PARAMS
```

| Param         | Description                                                              |
|---------------|--------------------------------------------------------------------------|
| `panel`       | `database` or `e80` (default: `database`)                               |
| `select`      | Comma-separated node keys to select (see node key table below)           |
| `right_click` | Node key of the right-click target (default: first key in `select`)      |
| `cmd`         | Numeric `CTX_CMD_*` constant to fire (see constant table below)          |
| `suppress`    | `1` = auto-confirm all dialogs before firing; `0` = restore prompt       |
| `op=suppress` | Set `suppress_confirm` without any tree or fire action; use with `val=0|1` |

**Node key format**

| Node type                 | Key                                   |
|---------------------------|---------------------------------------|
| Waypoint, route, track, group, collection/branch | UUID string          |
| Route point               | `rp:ROUTE_UUID:WP_UUID`               |
| E80 header nodes          | `header:groups`, `header:routes`, `header:tracks` |
| E80 My Waypoints          | `my_waypoints`                        |
| Root (bold Database/E80)  | `root`                                |

Database tree note: winDatabase uses lazy loading. A node inside a collapsed branch
is not in the tree and cannot be selected programmatically. Expand the branch in the
UI before issuing a `select` for items inside it.

**CTX_CMD_* constants**

```
COPY_WAYPOINT  = 10010    CUT_WAYPOINT  = 10110    DELETE_WAYPOINT    = 10410
COPY_WAYPOINTS = 10011    CUT_WAYPOINTS = 10111    DELETE_GROUP       = 10420
COPY_GROUP     = 10020    CUT_GROUP     = 10120    DELETE_GROUP_WPS   = 10421
COPY_GROUPS    = 10021    CUT_GROUPS    = 10121    DELETE_ROUTE       = 10430
COPY_ROUTE     = 10030    CUT_ROUTE     = 10130    REMOVE_ROUTEPOINT  = 10431
COPY_ROUTES    = 10031    CUT_ROUTES    = 10131    DELETE_TRACK       = 10440
COPY_TRACK     = 10040    CUT_TRACK     = 10140    DELETE_BRANCH      = 10450
COPY_TRACKS    = 10041    CUT_TRACKS    = 10141    DELETE_ALL         = 10499
COPY_ALL       = 10099    CUT_ALL       = 10199
                                                   NEW_WAYPOINT = 10510
PASTE     = 10300                                  NEW_GROUP    = 10520
PASTE_NEW = 10301                                  NEW_ROUTE    = 10530
                                                   NEW_BRANCH   = 10550
```

Check results via the ring buffer:
```
curl -s "http://localhost:9883/api/command?cmd=mark"   # returns seq N
curl -s "http://localhost:9883/api/log?since=N"        # entries after mark
```

### 7.2 Reset to known state

A test cycle begins from a fully known system state. Perform all three steps before
running any tests.

#### 7.2.1 Restore navMate.db

Git-revert `C:/dat/Rhapsody/navMate.db` to the committed test baseline, then reload:
Database -> Refresh in navMate.

#### 7.2.2 Clear the E80

The E80 must contain no waypoints, groups, routes, or tracks. Use the test machinery
or the winE80 context menu. After each dispatch, wait for `dialog_state: idle`
(see Section 7.2.4 before proceeding):

```
# Delete all routes
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10430&suppress=1"
curl -s "http://localhost:9883/api/command?cmd=dialog_state"   # poll until idle

# Delete all named groups and their member waypoints
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10421&suppress=1"
curl -s "http://localhost:9883/api/command?cmd=dialog_state"   # poll until idle

# If ungrouped waypoints remain (wps > 0, groups = 0), clear the My Waypoints node.
# NOTE: the node key is 'my_waypoints' - no 'header:' prefix.
# 'header:my_waypoints' will fail (selected 0 nodes).
curl -s "http://localhost:9883/api/test?panel=e80&select=my_waypoints&right_click=my_waypoints&cmd=10421&suppress=1"
curl -s "http://localhost:9883/api/command?cmd=dialog_state"   # poll until idle

# Tracks: delete individually via DEL-TK (10440) if any are present
```

#### 7.2.3 Mark the log and enable suppress

```
curl -s "http://localhost:9883/api/command?cmd=mark"
curl -s "http://localhost:9883/api/test?op=suppress&val=1"
```

Suppress remains set for the duration of the test cycle. Reset with `val=0` if a
specific test needs to verify that a confirmation dialog fires.

#### 7.2.4 Running a step

Any test step that dispatches an E80 context operation (delete, copy/paste, etc.) may
open a ProgressDialog that runs asynchronously. The general polling pattern:

**1. Dispatch the operation** via `/api/test`, then poll `dialog_state`:

```
curl -s "http://localhost:9883/api/command?cmd=dialog_state"
```

Each call logs `dialog_state: active` or `dialog_state: idle` to the ring buffer.
Repeat until `idle` is seen before issuing the next dispatch.

**2. Watch the progress count** (human observation). While the dialog is open, the
counter increments for each E80 callback completed. If the count stops advancing
for an unreasonable time (roughly 10 seconds), the operation may be stuck.

**3. Timeout and force-close**. If the dialog remains active past the expected
duration, issue:

```
curl -s "http://localhost:9883/api/command?cmd=close_dialog"
```

This sets `$_force_close = 1` in `Pub::WX::Dialogs`; `winMain::onIdle` calls
`forceCloseActive()` on the next tick, which calls `Destroy()` on the open dialog.
After a force-close, scan the ring buffer for ERROR or WARNING entries before
continuing.

**Bounded polling example:**

```powershell
for ($i = 1; $i -le 20; $i++) {
    $result = curl -s "http://localhost:9883/api/command?cmd=dialog_state"
    $log    = curl -s "http://localhost:9883/api/log?since=$mark"
    if ($log -match "dialog_state: idle") { break }
    Start-Sleep 1
}
if ($i -gt 20) {
    [console]::beep(800, 200)   # stuck - inspect screen; optionally close_dialog
}
```

Important: the dispatch guard in `winMain::onIdle` prevents the next `/api/test`
command from firing while a ProgressDialog is active. Always wait for `dialog_state:
idle` before dispatching the next step, or the command will be silently skipped.
