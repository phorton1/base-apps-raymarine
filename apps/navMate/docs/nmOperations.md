# navMate — nmOperations

**[Raymarine](../../../docs/readme.md)** --
**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)** --
**nmOperations** --
**[KML Specification](kml_specification.md)** --
**[GE Notes](ge_notes.md)**

## Overview

nmOperations is the feature that bridges navMate's two panels through familiar Copy / Cut /
Paste / New / Delete semantics. The **database panel** shows the navMate SQLite knowledge store; the
**E80 panel** shows the live device state. nmOperations defines every right-click context
menu action across both panels: what commands appear, under what conditions, what the
clipboard holds after a copy or cut, and what happens when the user pastes.

The organizing principle is that **Paste-to-E80 is the upload path**. There is no separate
"Send to E80" command. The same Copy → Paste gesture that moves items within the database
is extended unchanged to the cross-panel case. Pre-flight validation (§5) runs before any
E80 write, enforcing dependencies and resolving conflicts before anything is touched.

The feature is implemented across four modules: `nmClipboard.pm` owns the clipboard state
and determines which menu items appear; `nmOps.pm` dispatches each command; `nmOpsDB.pm`
executes database-side operations; `nmOpsE80.pm` executes E80-side operations. The
`nmTest.pm` module provides the HTTP-driven test dispatcher. See
[Implementation](implementation.md) for the full module inventory.


## 1. The Copy / Cut / Paste Model

### 1.1 Copy

Copy is non-destructive. It records what was selected, where it came from (DB or E80),
and the items themselves. Nothing in the source changes until Paste is invoked.

### 1.2 Cut

**Cut from DB** is a DB-internal move. The clipboard records what was selected so Paste
can re-home it by updating `collection_uuid` or `parent_uuid`. A DB-sourced cut is never
a valid source for Paste-to-E80 — the database is the authoritative owner of its records,
and uploading to E80 is always a copy operation, not a transfer of ownership.

**Cut from E80** transfers ownership to navMate. The items are downloaded into the DB on
Paste, then erased from E80. The primary intended use case is tracks: record on the E80
during a voyage, then Cut → Paste-to-DB to bring them home permanently.

### 1.3 Paste and Paste New

**Paste** executes the operation, preserving UUIDs from the clipboard source. For a
DB-to-DB copy, UUID-preserving paste would create a duplicate UUID in the database, so
Paste is only available for cut (move) operations and E80-source downloads.

**Paste New** inserts with fresh navMate-generated UUIDs regardless of source. It is
available for copy operations only — a cut is a move, not a duplication.

For any Paste-to-E80 operation, the full pre-flight validation sequence (§5) runs before
any E80 write begins. Operations are all-or-nothing: pre-flight either passes completely
or the operation is aborted.

### 1.4 Paste Before and After

**Paste Before** and **Paste After** insert clipboard contents at a specific position
within a collection, relative to the right-clicked node, rather than appending to the
collection root. **Paste New Before** and **Paste New After** do the same with fresh UUIDs.
These operations are the mechanism for ordering items within a collection and for inserting
waypoints at a specific position within a route.


## 2. Selection and Clipboard Rules

### 2.1 Copy and cut — no type restriction

Neither panel places a type restriction on Copy or Cut. Any selection produces a clipboard.
The menu label is always "Copy" / "Cut" regardless of selection type or count. The
clipboard holds exactly what was selected; it is the destination that enforces type
compatibility at paste time.

### 2.2 E80 paste — homogeneous effective contents required

E80 paste pre-flight runs before the paste context menu is built. It evaluates the
clipboard's **effective contents** — after dissolving any branch items. A branch carries
no meaning on the E80; its contents float up and are evaluated as if held directly in the
clipboard. Pre-flight then asks: are all effective items the same user-level type? If yes,
it offers paste to the compatible E80 destination for that type. If no, no E80 paste is
offered.

This is a completeness guarantee: what the menu offers is what gets pasted, entirely.
A branch containing only waypoints pastes to E80 waypoint destinations exactly as a
waypoints clipboard would. A branch containing mixed types produces no E80 paste option.
A mixed (non-branch) clipboard likewise produces no E80 paste option.

### 2.3 Paste Before and After — type matching

Paste Before/After is offered on any node that is a member of a collection (not the
collection root itself). The clipboard type must be compatible with the destination node
type.

On the **DB side**, Paste Before/After is as permissive as Paste to a collection — no
same-type requirement at the destination node. The route point destination is the special
case: pasting before/after a route point is a reference-splicing operation on the parent
route. The clipboard may contain waypoints, route points, or a mix of both — all resolve
to waypoint UUID references and are inserted as `route_waypoints` rows at the specified
position. This is the one context where a mixed clipboard is accepted. The full semantics
— including whether Paste New inserts new waypoint records or new `route_waypoints` rows
referencing existing waypoints — are deferred to implementation.

On the **E80 side**, the rule is stricter for all types except route point destinations,
which follow the same mixed-accepted rule: waypoints, route points, or a mix of both may
be pasted before/after a route point. For all other E80 destinations the clipboard must
be truly homogeneous and the same type as the destination node.

### 2.4 Groups as compound objects on E80

A group in the clipboard carries two levels: the group identity (UUID, name) and its member
waypoints. When pasting a group to E80, both levels must go through pre-flight (§5.3) and
execute as a compound operation: the group shell is created first, then each member waypoint
is created inside it. This is not a simple waypoint operation with a label attached — the
group's existence on E80 as a named, identity-preserving container is the primary object
of the operation.

Waypoints and groups share the same E80 WPMGR destination area but are distinct operation
types. The destination node for a waypoint paste (§6.2) determines which group the
waypoints land in.

### 2.5 My Waypoints — E80-only pseudo-group

**My Waypoints** is a reserved name that belongs exclusively to the E80. It is the E80 UI
node representing ungrouped waypoints and has no group identity of its own — it is a display
container, not a real group. A DB group may never be named "My Waypoints." Any operation
that would create a group with that name in the database (New Group, or a download from
E80) must reject or remap it.

When downloading from the E80's My Waypoints node, the contents arrive as individual
ungrouped waypoints in the target DB collection. No group is created; the name is not used.

### 2.6 Route points in the tree

Route points are ordered references — `route_waypoints` rows — that define a route's
waypoint sequence. They are shown in the tree for route editing convenience. Route points
are first-class clipboard objects: Copy and Cut operate on them, producing a clipboard of
ordered waypoint-UUID references.

**Cut + Paste Before/After** is the route reordering mechanism: remove a reference from
its current position and insert it elsewhere in the same route.

**Copy + Paste** inserts the same waypoint-UUID references at the destination position.
This works within one route (duplication) or across routes (copying a subset of one route
into another). Because route points are references, not independent objects, "copy" means
inserting new `route_waypoints` rows that point to the same underlying waypoints — the
waypoint records are unaffected. This enables a real-world workflow: copy several route
points from Route A and paste them into Route B.

**Delete** removes the `route_waypoints` reference at that position; the UI label is
"Delete" even though the implementation is a splice. The underlying waypoint record is
preserved.

Because a route point and a waypoint are both ultimately a waypoint UUID reference,
the clipboard type distinction between the two dissolves at the route insertion point.
A clipboard of real waypoints, a clipboard of route points, or a mix of both are all
equally valid sources for a Paste Before/After into a route — all insert as
`route_waypoints` rows referencing the relevant waypoint UUIDs. This applies on both
the DB side and the E80 side.

The full semantics of Paste New for route points (whether it inserts new waypoint records
or new `route_waypoints` rows referencing the same waypoints) are deferred to
implementation.


## 3. The Clipboard

The clipboard is a container. It holds:

- **Source** — DB or E80: which panel the operation came from.
- **Cut flag** — whether the operation was a cut (move intent) or a copy.
- **Items** — the list of items selected at the time of the operation, each carrying its
  own type. The list may be homogeneous or mixed.

The clipboard does not have a type label of its own. The destination's pre-flight
evaluates the clipboard before building the paste context menu:

1. Dissolve any branch items — their contents float up, replacing the branch item.
2. Are all effective items the same user-level type? (homogeneity check)
3. If homogeneous — what is that type?
4. Is it a cut?
5. What is the source?

These properties, together with the destination node, determine which paste operations are
offered. The clipboard answers queries; it does not pre-classify itself.

The user-level types are: **waypoint**, **route**, **track**, **group**, **branch**.
A group carries its member waypoints as part of its payload (compound object). A route
carries its member waypoint UUID list. A branch carries all contents of the selected
subtree. Branch is a DB-only type; it has no counterpart on the E80.

`[concept notion]` shorthand (e.g., `[copy waypoints from DB]`, `[cut routes from E80]`)
is used in the test plan and runbook as a readable label for a specific test clipboard
setup — "perform this operation to establish this clipboard state, then proceed." These
are test case identifiers, not clipboard type labels. The clipboard itself has no such
enumeration.


## 4. Menu Matrices

### 4.1 DB Panel — Copy and Cut

Copy and Cut are available for any selection in the DB panel except the root node (paste
target only). The label is always "Copy" / "Cut"; the command ID is always COPY / CUT;
see §8.3.

### 4.2 E80 Panel — Copy and Cut

Copy and Cut are available for any selection in the E80 panel including the the root node.
The label is always "Copy" / "Cut"; the command ID is always COPY / CUT;
see §8.3.


### 4.3 Delete Commands

The Delete command are available for any selection in either Panel.

The context menu offers at most two items: **Delete** and **Delete Group + Waypoints**.
The confirmation dialog presents what will be deleted, its type, and quantity. Route
reference dependencies are surfaced at confirmation time, not as separate menu items.

Delete on Collections (i.e. Branches, E80 Groups, Routes, and Tracks) operates on
all items within the collection.  The E80 has specific ordering when deleting Groups
(Groups before Waypoints).

**Delete Group + Waypoints** is the only distinct command: it appears alongside Delete
when the selection is a group, or a homogenous set of Groups (i.e. the Groups Folder
on the E80). because Delete on a group dissolves it (members
survive) while Delete Group + Waypoints removes the members too. My Waypoints on E80
offers only Delete Group + Waypoints (it cannot be dissolved).


### 4.4 Paste Before and After

Paste Before, Paste After, Paste New Before, and Paste New After are offered when the
right-click target is a member node within a collection (not the collection root). They
are governed by the type-matching rules in §2.3.

| Context                                              | Paste Before/After     | Paste New Before/After |
|------------------------------------------------------|------------------------|------------------------|
| DB: clipboard type matches destination node type     | Y                      | Y (copy only)          |
| DB: waypoints clipboard, destination is route point  | Y (inserts into route) | Y (copy only)          |
| DB: type mismatch or mixed clipboard                 | —                      | —                      |
| E80: clipboard homogeneous, same type as destination | Y                      | Y (copy only)          |
| E80: any other case                                  | —                      | —                      |

Paste New Before/After inserts with fresh UUIDs; available for copy operations only.

### 4.5 New Commands

New is driven by the right-click node type only; selection has no effect. All New commands
open a name-input dialog and are excluded from automated testing (see §8.2).  The new
item is place as the new 1st item in a Collection if the right click is on a collection,
or with the Paste-After semantic if clicked on a terminal object type.



## 5. Pre-flight Validation

Pre-flight runs before any E80 write operation begins. The checks execute in order. If any
check fails, the entire operation is aborted — no E80 writes occur.

### 5.1 Route dependency check

Before creating any route, navMate verifies that every member waypoint UUID already exists in
the WPMGR memory on the E80, or in the database.

If any UUID is missing, an error dialog lists the affected route(s) and the missing waypoints,
then aborts. navMate does not secretly paste waypoints as a side effect of a route paste. The
user must paste the missing waypoints to E80 first, then retry the route paste.


### 5.2 UUID and name conflict check

For each item in the paste, check whether its UUID or name conflicts with existing E80
content. Each item falls into one of these categories:

- **Clean create** — UUID not on E80, name not in use. Will create; no action required.
- **Refresh** — UUID on E80, `db_version` > `e80_version`. The DB record is known to be
  newer; refresh without prompting. *(Version increment wiring is deferred; this category
  is not yet distinguished. Currently treated as a plain conflict.)*
- **Conflict** — UUID on E80, version relationship unclear. The user is warned and decides
  whether to overwrite.
- **Name collision** — UUID not on E80, but the same name already exists on E80.
  **Hard abort.** No auto-renaming; no "continue anyway" dialog. The user must resolve
  the name conflict manually before retrying.


### 5.3 Group-level conflict check

For group pastes to E80, the pre-flight applies the UUID and name conflict check at two
levels — first for the group shell itself, then for each member waypoint:

- Does the group UUID already exist on E80? → conflict resolution per §5.2.
- Does a group with the same name already exist on E80 (different UUID)? → name collision
  → hard abort.
- "My Waypoints" as a group name → hard abort. This name is reserved for the E80's own
  ungrouped waypoints display node and cannot be created by navMate.
- For each member waypoint: same UUID and name checks as §5.2.

The group-level check runs before member waypoint checks. A group-level name collision
aborts before any member is inspected.


### 5.4 Item count dialog

After categorizing, if any items fall into the conflict category, the user is offered a
choice: skip the conflicting items and continue with the clean creates, or abort. If the
user chooses Abort, no E80 writes occur.


### 5.5 All-or-nothing guarantee

Once pre-flight passes and execution begins, the operation runs to completion. The only
permitted partial-execution outcome is a genuine E80 protocol failure (disconnect,
unexpected NAK, etc.). A protocol failure leaves the operation in whatever state it
reached at the time of failure; the user is informed via the ring buffer and the progress
dialog.


## 6. Paste Compatibility

### 6.1 Paste to Database

The destination must be a collection node, except for waypoints, which `canPaste` accepts
for any DB node (the implementation enforces the collection requirement internally).

| Source | Type      | Cut | Paste | Paste New | Notes                                          |
|--------|-----------|-----|-------|-----------|------------------------------------------------|
| DB     | waypoints | no  | —     | Y         | Duplicate with fresh UUID(s)                   |
| DB     | waypoints | yes | Y     | —         | Move — re-home `collection_uuid`               |
| DB     | groups    | no  | —     | Y         | Duplicate group + members, fresh UUIDs         |
| DB     | groups    | yes | Y     | —         | Move group shell; members travel with it       |
| DB     | routes    | no  | —     | Y         | Duplicate route + fresh member WP UUIDs        |
| DB     | routes    | yes | Y     | —         | Move route record                              |
| DB     | tracks    | no  | —     | —         | DB track copy+paste not supported              |
| DB     | tracks    | yes | Y     | —         | Move track                                     |
| DB     | branch    | no  | —     | Y         | Duplicate all branch contents, fresh UUIDs     |
| DB     | branch    | yes | Y     | —         | Move all branch contents to new collection     |
| DB     | mixed     | no  | —     | Y         | Duplicate all items, fresh UUIDs               |
| DB     | mixed     | yes | Y     | —         | Move all items                                 |
| E80    | waypoints | no  | Y     | Y         | Download / download with fresh UUID            |
| E80    | waypoints | yes | Y     | —         | Download + delete from E80                     |
| E80    | groups    | no  | Y     | Y         | Download group + members                       |
| E80    | groups    | yes | Y     | —         | Download + delete from E80                     |
| E80    | routes    | no  | Y     | Y         | Download route                                 |
| E80    | routes    | yes | Y     | —         | Download + delete from E80                     |
| E80    | tracks    | no  | Y     | —         | Download; Paste New not available for tracks   |
| E80    | tracks    | yes | Y     | —         | Download + E80 erase                           |

My Waypoints download (E80 waypoints, destination DB): creates individual ungrouped
waypoints in the target collection. No group is created; the name "My Waypoints" is not
used.


### 6.2 Paste to E80

Clipboard must be homogeneous for any E80 paste, except for a DB branch clipboard pasting
to the E80 root. Pre-flight (§5) runs before all operations in this table.

| Source | Type      | Cut | Destination                  | Paste | Paste New | Notes                                                                                    |
|--------|-----------|-----|------------------------------|-------|-----------|------------------------------------------------------------------------------------------|
| DB     | waypoints | no  | WP destinations¹             | Y     | Y         | Upload / upload with fresh UUID                                                          |
| DB     | waypoints | yes | any                          | —     | —         | DB cut → E80 blocked                                                                     |
| DB     | groups    | no  | Groups header                | Y     | Y         | Upload group (compound op, §7.4)                                                         |
| DB     | groups    | yes | any                          | —     | —         | DB cut → E80 blocked                                                                     |
| DB     | routes    | no  | Routes header                | Y     | Y         | Upload route                                                                             |
| DB     | routes    | yes | any                          | —     | —         | DB cut → E80 blocked                                                                     |
| DB     | tracks    | any | any                          | —     | —         | Tracks read-only on E80                                                                  |
| DB     | branch    | no  | compatible E80 destination²  | Y     | —         | Branch dissolves; contents evaluated as their native type; offered only if homogeneous   |
| DB     | branch    | yes | any                          | —     | —         | DB cut → E80 blocked                                                                     |
| DB     | mixed     | any | any                          | —     | —         | Heterogeneous after dissolution → no E80 paste                                           |
| E80    | waypoints | no  | WP destinations¹             | Y     | Y         | Re-upload / duplicate                                                                    |
| E80    | waypoints | yes | WP destinations¹             | Y     | —         | Re-home on E80 + delete source                                                           |
| E80    | groups    | no  | Groups header                | Y     | Y         | Re-upload / duplicate group                                                              |
| E80    | groups    | yes | Groups header                | Y     | —         | Re-home on E80 + delete source                                                           |
| E80    | routes    | no  | Routes header                | Y     | Y         | Re-upload / duplicate route                                                              |
| E80    | routes    | yes | Routes header                | Y     | —         | Re-home on E80 + delete source                                                           |
| E80    | tracks    | any | any                          | —     | —         | Tracks read-only on E80                                                                  |
| any    | any       | any | Tracks header, track         | —     | —         | Target incompatible                                                                      |

¹ WP destinations: Groups header, My Waypoints node, group node, waypoint node,
route point node. The destination node determines which group the waypoints land in.

² Branch destination is whichever E80 destination is compatible with the dissolved
content type (e.g., waypoints → WP destinations¹; routes → Routes header).

### 6.3 Paste Before and After

Paste Before/After inserts at a specific position relative to the right-clicked node.
Type compatibility rules are in §2.3. Paste New variants produce fresh UUIDs; available
for copy operations only.

**DB Panel:**

| Clipboard type                          | Destination node | Available                      |
|-----------------------------------------|------------------|--------------------------------|
| waypoints                               | waypoint         | Y                              |
| route points                            | route point      | Y (reference splice)           |
| waypoints                               | route point      | Y (reference splice)           |
| mixed waypoints + route points          | route point      | Y (reference splice)           |
| routes                                  | route            | Y                              |
| tracks                                  | track            | Y                              |
| groups                                  | group            | Y                              |
| any type                                | different type   | —                              |
| mixed (other than waypoints+route points) | any            | —                              |
| branch                                  | any              | — (branch dissolves; see §2.2) |

**E80 Panel:**

| Clipboard type                          | Destination node | Available             |
|-----------------------------------------|------------------|-----------------------|
| waypoints (homogeneous)                 | waypoint         | Y                     |
| route points                            | route point      | Y (reference splice)  |
| waypoints                               | route point      | Y (reference splice)  |
| mixed waypoints + route points          | route point      | Y (reference splice)  |
| routes (homogeneous)                    | route            | Y                     |
| groups (homogeneous)                    | group            | Y                     |
| tracks                                  | any              | — (tracks read-only)  |
| homogeneous type A                      | type B node      | —                     |
| mixed (other than waypoints+route points) | any            | —                     |


## 7. Operation Semantics

### 7.1 Paste to Database from E80 — download

UUID-preserving merge into the navMate DB. For each item in the clipboard:

- UUID not in DB → insert record in target collection.
- UUID in DB, data identical → no-op.
- UUID in DB, data differs → conflict dialog: Replace / Skip / Replace All / Skip All / Abort.

**Groups:** the group collection is created under the target if absent (merge semantics;
existing members are preserved). Member waypoints are merged individually per the above.
My Waypoints content arrives as ungrouped waypoints — no group is created.

**Routes:** member waypoints are merged into the target collection. The route record is
inserted or updated. The route waypoint list is rebuilt from the clipboard.

**Cut variant:** after each item is successfully pasted, the source item is deleted from
E80 via WPMGR commands.

### 7.2 Paste to Database from Database — Cut (move)

Re-homes the object to the new collection without changing its UUID. No conflict check.

- Waypoints: `UPDATE waypoints SET collection_uuid = ? WHERE uuid = ?`
- Groups: `UPDATE collections SET parent_uuid = ? WHERE uuid = ?`
- Routes: `UPDATE routes SET collection_uuid = ? WHERE uuid = ?`
- Tracks: `UPDATE tracks SET collection_uuid = ? WHERE uuid = ?`

A group move carries only the group shell; member waypoints remain inside the group and
travel with it automatically (they reference the group UUID, not the parent). A route move
carries only the route record; member waypoints stay in their current collections.

### 7.3 Paste New to Database

Inserts with fresh navMate UUIDs regardless of source. No conflict check. Available for
copy operations only — a cut is a move, not a duplication.

**Routes:** each member waypoint also receives a fresh UUID; the new route references the
new waypoint UUIDs.

**Tracks:** Paste New is not available for any track clipboard state. Track duplication
within the database requires Cut → Paste (move).

### 7.4 Paste to E80 — upload

The pre-flight sequence (§5) must pass before any E80 write begins. Sends WPMGR NEW_ITEM
commands in dependency order:

- **Waypoints:** one NEW_ITEM per waypoint, followed by GET_ITEM to confirm. The
  destination node determines group assignment on E80.
- **Groups:** compound operation. Pre-flight (§5.3) checks the group shell and all members.
  Execution: create the group shell first (NEW_ITEM for the group), then create each member
  waypoint inside it. Both the group identity and the member waypoints are created as a
  unit.
- **Routes:** pre-flight has already verified all member waypoint UUIDs exist on E80. The
  route is created referencing those existing E80 UUIDs. No waypoints are created as a
  side effect of a route paste.
- **Branch:** groups and their waypoints first, then routes. Track items are skipped
  silently.

The progress dialog protection pattern (the same pattern used by `_doRefreshE80Data` in
`winMain.pm`) wraps all Paste-to-E80 operations. Do not reinvent this pattern.

### 7.5 Paste Before and After

**DB — collection ordering:** inserts items at the specified position within the parent
collection, adjacent to the right-clicked node. The sequence field of the surrounding
items is adjusted to accommodate the insertion.

**DB — route point insertion:** when the destination is a route point, inserts the
clipboard waypoints into `route_waypoints` at the specified sequence position. The
existing route point references at and after that position are shifted. The underlying
waypoint records are referenced, not duplicated.

**E80 — position-aware upload:** sends WPMGR commands with position-aware ordering for
waypoints within groups or routes. Protocol specifics for E80 route point insertion depend
on WPMGR sequencing support and are confirmed during implementation.

Paste New Before/After uses the same position mechanics with fresh UUIDs for the incoming
items.

### 7.6 Delete — Database

- **DELETE_WAYPOINT:** blocked (informational message) if any selected WP has
  `route_waypoints` references. Requires confirm.
- **DELETE_GROUP (dissolve):** reparents all member waypoints to the group's parent
  collection (`collection_uuid` updated in place), then deletes the group shell. Route
  references to member waypoints are unaffected (UUIDs unchanged). Requires confirm.
- **DELETE_GROUP_WPS:** blocked (informational message) if any member WP is in a route.
  Requires confirm.
- **DELETE_ROUTE:** deletes the route and its `route_waypoints` rows; member waypoints are
  preserved. Requires confirm.
- **DELETE_TRACK:** deletes the track and its `track_points` rows. Requires confirm.
- **DELETE_BRANCH:** recursively deletes the branch and all descendants — sub-collections,
  waypoints, routes, route_waypoints, tracks, and track_points. Hidden (not shown) if any
  member waypoint is referenced by a route outside the branch subtree
  (`isBranchDeleteSafe` returns 0). Requires confirm.
- **Route point delete (labeled "Delete"):** removes one `route_waypoints` row at the
  selected position; the underlying waypoint record is preserved. Implementation constant
  is REMOVE_ROUTEPOINT. Requires confirm.

### 7.7 Delete — E80

No upfront UI blocks. Pre-flight detects dependencies and warns the user if any selected
waypoint is a member of a route that is not also being deleted. The user can proceed
(route references are removed first) or abort.

Execution order is always: DELETE_ROUTE first, then DELETE_GROUP / DELETE_GROUP_WPS, then
DELETE_WAYPOINT. This ordering ensures waypoints are never deleted while routes still
reference them.

- **DELETE_WAYPOINT:** WPMGR DELETE_ITEM for each waypoint.
- **DELETE_GROUP (dissolve):** removes the group shell; member waypoints become ungrouped
  (attached to My Waypoints on E80).
- **DELETE_GROUP_WPS:** WPMGR DELETE_ITEM for each member waypoint, then for the group
  shell.
- **DELETE_ROUTE:** WPMGR DELETE_ITEM for the route.
- **DELETE_TRACK:** sends TRACK_CMD_ERASE.
- **Route point delete (labeled "Delete"):** removes the route_waypoints reference; the
  underlying waypoint is preserved on E80.


## 8. Testability

### 8.1 Suppress mechanism

`nmDialogs.pm` exports `$suppress_confirm`, a threads-shared variable. When set to 1,
both confirmation dialogs **and** error/warning dialogs are suppressed — they auto-accept
their default response without user interaction. This covers all modal dialogs in the
nmOperations flow and enables fully automated test execution through failure paths, not
just success paths.

Reset `$suppress_confirm` to 0 for any test step that needs to verify a specific dialog
fires rather than auto-accepting.

### 8.2 /api/test endpoint

Context menu operations are driven programmatically via the `/api/test` HTTP endpoint
(port 9883). The HTTP thread encodes the query params as JSON and stores them in a shared
variable; `winMain::onIdle` picks up the command within ~20 ms and calls
`nmTest::dispatchTestCommand`, which walks the tree to set the selection and right-click
node, then calls `onContextMenuCommand` directly — the same code path as a real right-click
and menu pick.

```
GET http://localhost:9883/api/test?PARAMS
```

| Param         | Description                                                                    |
|---------------|--------------------------------------------------------------------------------|
| `panel`       | `database` or `e80` (default: `database`)                                      |
| `select`      | Comma-separated node keys to select                                            |
| `right_click` | Node key of the right-click target (default: first key in `select`)            |
| `cmd`         | Numeric CTX_CMD constant to fire                                               |
| `suppress`    | `1` = auto-suppress all dialogs; `0` = restore prompt                          |
| `op=suppress` | Set suppress without any tree action or fire; use with `val=0\|1`              |

**Node key format:**

| Node type                                 | Key                                                      |
|-------------------------------------------|----------------------------------------------------------|
| Waypoint, route, track, group, collection | UUID string                                              |
| Route point                               | `rp:ROUTE_UUID:WP_UUID`                                  |
| E80 header nodes                          | `header:groups`, `header:routes`, `header:tracks`        |
| E80 My Waypoints                          | `my_waypoints`                                           |
| E80 root                                  | `root`                                                   |

DB tree note: winDatabase uses lazy loading. A node inside a collapsed branch cannot be
selected programmatically until the branch is expanded in the UI.

Check results via the ring buffer:

```
curl -s "http://localhost:9883/api/command?cmd=mark"    # returns seq N
curl -s "http://localhost:9883/api/log?since=N"         # entries after mark
```

### 8.3 CTX_CMD constants

The menu label is always "Copy" and "Cut" regardless of selection type or count.
REMOVE_ROUTEPOINT is an internal constant; the menu item is labeled "Delete" in the UI.

```
COPY = 10010    CUT = 10110

PASTE          = 10300
PASTE_NEW      = 10301
PASTE_BEFORE   = 10302
PASTE_AFTER    = 10303
PASTE_NEW_BEFORE = 10304
PASTE_NEW_AFTER  = 10305

DELETE_WAYPOINT   = 10410
DELETE_GROUP      = 10420
DELETE_GROUP_WPS  = 10421
DELETE_ROUTE      = 10430
REMOVE_ROUTEPOINT = 10431
DELETE_TRACK      = 10440
DELETE_BRANCH     = 10450

NEW_WAYPOINT = 10510
NEW_GROUP    = 10520
NEW_ROUTE    = 10530
NEW_BRANCH   = 10550
```

NEW_* commands open name-input dialogs and are excluded from automation.

### 8.4 Progress dialog pattern

Any Paste-to-E80 operation opens a ProgressDialog using the same pattern as
`_doRefreshE80Data` in `winMain.pm`. The `onIdle` dispatch guard prevents new
`/api/test` commands from firing while the dialog is active. Poll `dialog_state` before
issuing the next step:

```
curl -s "http://localhost:9883/api/command?cmd=dialog_state"
```

Returns `dialog_state: active` or `dialog_state: idle` in the ring buffer. If the dialog
is stuck, force-close it:

```
curl -s "http://localhost:9883/api/command?cmd=close_dialog"
```

The `dialog_state` and `close_dialog` endpoints carry forward from the previous
implementation unchanged.

**Bounded polling example:**

```powershell
for ($i = 1; $i -le 20; $i++) {
    $result = curl -s "http://localhost:9883/api/command?cmd=dialog_state"
    $log    = curl -s "http://localhost:9883/api/log?since=$mark"
    if ($log -match "dialog_state: idle") { break }
    Start-Sleep 1
}
if ($i -gt 20) {
    [console]::beep(800, 200)   # stuck — inspect screen; optionally close_dialog
}
```

---

**Back:** [Implementation](implementation.md)
