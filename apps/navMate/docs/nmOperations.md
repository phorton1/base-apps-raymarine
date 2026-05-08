# navMate -- nmOperations

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
"Send to E80" command. The same Copy -> Paste gesture that moves items within the database
is extended unchanged to the cross-panel case.

The central mechanism is **pre-flight**: a classification and validation step that runs
before any operation begins -- Delete, Copy, Cut, and Paste alike. Pre-flight interprets
the current selection (or clipboard) in the context of the right-click node and the
destination panel, determines which commands are valid, and either commits to execution
or aborts with a user-facing explanation. The rule sections (SS8-SS10) are the pre-flight
specification; they are not a separate documentation view from the operation behavior.

The feature is implemented across four modules: `nmClipboard.pm` owns the clipboard state;
`nmOps.pm` dispatches each command; `nmOpsDB.pm` executes database-side operations;
`nmOpsE80.pm` executes E80-side operations. The `nmTest.pm` module provides the HTTP-driven
test dispatcher. See [Implementation](implementation.md) for the full module inventory.


## 1. Invariants

nmOperations is a primary database/E80 data modification system. It must enforce data model
invariants not enforced by the database schema itself.

### 1.1 A Group is a Homogeneous Collection of Waypoints

Adding an item to a Group that is not a Waypoint object invalidates this invariant. On the
database side, if this occurs, the Group must be demoted to a Branch. On the E80 side this
invariant is also enforced by the E80 firmware; no E80 boundary operations may ever attempt
to create a situation that violates it.

### 1.2 A Route is an Ordered List of Waypoint References

The system must never allow a route to contain a reference to a waypoint that does not exist
in that side's database representation. Every route paste operation -- PASTE or PASTE_NEW,
to any destination -- must verify before execution begins that all referenced waypoint UUIDs
either already exist at the destination or are present in the current operation and will be
processed first. If any are missing and not covered by the operation, pre-flight rejects.
This check applies universally: E80-destination and DB-destination alike (SS10.1 Step 4).

On the E80 side this check is non-trivial: the WPMGR must already contain the waypoints
before the route is created. On the DB side this check is satisfied trivially for
DB-sourced route pastes (the referenced waypoints already exist in the DB), and explicitly
for E80-sourced route pastes where the referenced waypoints may or may not be in the DB.

### 1.3 The E80 Enforces Unique Names and UUIDs

The database allows multiple UUIDs to share the same name regardless of type. The E80 will
fail if Waypoints, Routes, or Groups share names. Pre-flight must detect and prevent this
before any E80 write.

### 1.4 The FLOAT Position Ordering Scheme Must Be Maintained and Repacked

All nmOperations must correctly maintain the FLOAT position ordering scheme when modifying
the database. New position FLOAT values must be assigned during operations such as cut/paste
and copy/paste new. A repacking mechanism must execute when the ordering values approach
the 32-bit boundary (not the 51-bit limit).

### 1.5 Recursive Paste of Parent to Children is Prohibited

Re-parenting an item to one of its own children is illogical and must be prevented in
pre-flight.

### 1.6 Route Paste Always Preserves Waypoint UUID References

There is no paste operation for routes that creates new waypoint records as a side effect.
PASTE and PASTE_NEW for a route both produce route records whose route_waypoints references
point to the same underlying waypoint UUIDs as the source. The distinction between PASTE
and PASTE_NEW is whether the route record itself receives a fresh UUID (PASTE_NEW) or
preserves its source UUID (PASTE). The waypoint UUIDs the route references are always
preserved exactly. No new waypoint records are ever created as part of any route paste.

### 1.7 E80 Paste Operations Must Be Type-Homogeneous

Each paste to the E80 must contain items of a single user-level type: waypoints, groups,
routes, or tracks. Mixed-type pastes to the E80 are not permitted. This is a deliberate
design choice to enable clean pre-flight validation and unambiguous execution semantics.
The one exception is the mixed waypoints-and-route-points clipboard, which is accepted at
E80 route point destinations only (SS10.9). DB-destination pastes are unaffected -- the
DB accepts heterogeneous pastes.


## 2. Command Vocabulary

The commands below constitute the nmOperations context menu. Each has a symbolic name
used throughout this document and a numeric CTX_CMD constant used in the Wx implementation
and the HTTP test API.

### 2.1 Copy and Cut

**COPY** (10010) -- captures the current selection into the clipboard without modifying
the source.

**CUT** (10110) -- captures the current selection with move intent. On the DB side, marks
items for re-homing; on the E80 side, marks items for download and deletion from E80 after
paste.

### 2.2 Paste

**PASTE** (10300) -- executes the clipboard into the destination, preserving source UUIDs.
Available for cut operations and E80-source downloads.

**PASTE_NEW** (10301) -- executes the clipboard into the destination with fresh
navMate-generated UUIDs. Available for copy operations only.

### 2.3 Paste Before and After

**PASTE_BEFORE** (10302) / **PASTE_AFTER** (10303) -- insert clipboard contents immediately
before or after the right-clicked node within its parent collection.

**PASTE_NEW_BEFORE** (10304) / **PASTE_NEW_AFTER** (10305) -- same positional insertion
with fresh UUIDs. Available for copy operations only.

### 2.4 Delete

**DELETE_WAYPOINT** (10410) -- removes a waypoint record.

**DELETE_GROUP** (10420) -- dissolves a group: member waypoints are re-parented to the
group's parent collection; the group shell is removed.

**DELETE_GROUP_WPS** (10421) -- removes a group shell and all its member waypoints.

**DELETE_ROUTE** (10430) -- removes a route record and its `route_waypoints` rows; member
waypoints are preserved.

**REMOVE_ROUTEPOINT** (10431) -- removes one `route_waypoints` reference at the selected
position; the underlying waypoint record is preserved. The menu label is "Delete."

**DELETE_TRACK** (10440) -- removes a track record and its `track_points` rows.

**DELETE_BRANCH** (10450) -- recursively removes a branch and all descendants.

### 2.5 New

**NEW_WAYPOINT** (10510), **NEW_GROUP** (10520), **NEW_ROUTE** (10530),
**NEW_BRANCH** (10550) -- create a new item of the named type. All open a name-input
dialog. Placement follows the New command rules in SS11. New commands are excluded from
automated testing.


## 3. The Selection Model

The selection set on either tree is arbitrary and enforced only by the multi-selection
available in the wxTreeControl. It may contain a single item or any combination of items in
the tree, including items at different hierarchy levels, ancestors alongside their
descendants, items from different parent collections, and items of mixed types.

No classification or validation is applied to the selection by the tree control itself. All
interpretation occurs in pre-flight at the moment an operation is invoked.

**Right-click behavior.** A right-click on a selected item does not change the selection
set. A right-click on an unselected item changes the selection set to that single item. This
right-click-to-select behavior is not provided by wxTreeControl and must be implemented in
the right-click event handler.

**Right-click context.** The right-click target node carries two distinct roles when the
clipboard is non-empty: it may be interpreted as a paste destination, or it may be the
intended start of a new Copy or Cut selection. This ambiguity is resolved by which command
the user ultimately picks from the menu -- Delete and Paste use the current selection and/or
clipboard; Copy and Cut begin a new selection from the right-click target.

The formal vocabulary for characterizing selection and clipboard contents is defined in SS6.
No rule in SS8-SS10 uses an informal type label where a term from that vocabulary applies.


## 4. The Clipboard

The clipboard is populated by Copy and Cut. It holds:

- **`source`** -- DB or E80: which panel the operation originated from.
- **`cut_flag`** -- whether the operation was Cut (move intent) or Copy.
- **`items`** -- the list of nodes selected at the time of the operation. Each node carries
  its own type. The list is stored without classification or normalization -- it is an exact
  snapshot of the selection at copy/cut time, including any nested selections or partial
  compounds that were present.

The clipboard does not carry a type label of its own. All classification of clipboard
contents is performed by paste pre-flight (SS10) at the time a paste destination is
evaluated.

The clipboard remains populated until replaced by a subsequent Copy or Cut. Paste does not
clear the clipboard.


## 5. Pre-flight

Pre-flight is the classification and validation layer that runs before any operation begins.
It is not limited to E80 writes; it runs before Delete, Copy, Cut, and Paste alike.

**Inputs:**
- The raw selection (for Delete, Copy, Cut)
- The clipboard contents (for Paste)
- The right-click target node
- The destination panel (DB or E80)
- The command being invoked

**Outputs:**
- Valid: the operation proceeds with the parameters pre-flight determined
- Invalid: the operation is aborted; the user receives a specific explanatory message

**Failure behavior.** If pre-flight fails, no database writes and no E80 writes occur. The
failure message identifies what was checked and why it failed.

**Execution guarantee.** Once pre-flight passes and execution begins, the operation runs to
completion. The only permitted partial outcome is a genuine E80 protocol failure
(disconnect, unexpected NAK). A protocol failure leaves the operation in whatever state it
reached; the user is informed via the ring buffer and the progress dialog.

**The rule sections.** Pre-flight does not enumerate its rules inline. The rules are:

- SS8 -- Pre-flight Rules: Delete
- SS9 -- Pre-flight Rules: Copy and Cut
- SS10 -- Pre-flight Rules: Paste

These sections are the pre-flight specification. The menu commands that appear for any
right-click, and the behavior of any invoked command, are fully determined by those
sections.


## 6. Selection and Clipboard Vocabulary

This section defines formal terms used throughout SS8-SS10. Rules in those sections use
these terms in place of informal labels.

### 6.1 Selection structure terms

**Empty selection** -- no nodes are selected. COPY, CUT, and Delete are not offered.

**Single item of type X** -- exactly one node is selected, of type X (waypoint, group,
route, track, branch, or route point).

**Homogeneous flat set of type X** -- two or more nodes selected, all of the same
user-level type X, with no ancestor/descendant relationships among the selected nodes.

**Heterogeneous flat set** -- two or more nodes selected, of two or more different
user-level types, with no ancestor/descendant relationships among the selected nodes.

**Nested selection** -- the selected set contains at least one ancestor/descendant pair:
a node and one or more of its direct or indirect descendants are both present in the
selection. Examples: a Group node and one of its member Waypoints; a Branch and an item
within it.

**Intact compound object** -- a Group, Route, or Branch node selected as a unit.
- A selected Group node implies the group shell and all its current member Waypoints travel
  together as one unit; the members are not independently selected items but contents of
  the compound.
- A selected Route node implies the route record and its entire ordered sequence of
  `route_waypoints` references travel together. The route point children are not
  independently selectable when the Route itself is selected.
- A selected Branch node implies the branch shell and all its current descendants.

The interior items of an intact compound object are not individually accessible as
selection members -- they travel as a whole or not at all.

**Partial compound** -- member items of a Group, Route, or Branch are selected without the
parent node being selected, or the parent node is selected and one or more of its member
items are also individually present in the selection. This is a structurally degenerate
configuration that arises from arbitrary multi-selection. Each rule section specifies how
pre-flight handles it.

### 6.2 Ancestor-wins resolution

When paste pre-flight encounters a nested selection or partial compound in `items`, it
applies ancestor-wins resolution before evaluating any rule:

For each ancestor/descendant pair found in `items`, the descendant entries are removed from
consideration. Resolution is applied iteratively until no ancestor/descendant pairs remain
in the working list.

The resolved items list is used for all subsequent pre-flight evaluation. Resolution is
computed fresh at each paste pre-flight invocation; it is not stored in the clipboard.

If the resolved items list is empty after resolution (all items were absorbed as descendants
of other selected ancestors), the paste is rejected with an explanatory message.

**UI surfacing requirement.** Ancestor-wins resolution changes what will be operated on
relative to what the user explicitly selected. This is not a silent transformation. When
resolution removes one or more items from consideration, pre-flight must present a
confirmation dialog before proceeding. The dialog identifies which items were absorbed
(by name and type) and what will actually be operated on. The user may proceed or abort.
This requirement applies to all operations that invoke ancestor-wins resolution.

### 6.3 Effective contents (E80 destination only)

For any E80-destination paste, after ancestor-wins resolution, pre-flight dissolves Branch
items: each Branch node is replaced by its direct and indirect descendants at their native
types. The resulting set is the **effective contents** for this paste evaluation.

Branch items are DB-only constructs and have no E80 representation. They cannot be sent to
the E80 as Branch objects.

Effective contents are computed fresh at each paste evaluation; they are not stored.

If effective contents are empty after dissolution (the branch was empty or contained only
items that are not valid on E80), the paste is rejected.

### 6.4 Clipboard structural categories

The following terms describe `items` after ancestor-wins resolution (SS6.2). For
E80-destination evaluations, these terms apply to the effective contents (SS6.3) after
branch dissolution.

**Single-item clipboard** -- the resolved items list has exactly one entry.

**Homogeneous clipboard of type X** -- the resolved items list contains only items of
user-level type X, with no ancestor/descendant pairs remaining after resolution.

**Intact-group clipboard** -- the resolved items list contains one or more Group nodes,
each as an intact compound object. May be a single Group or a homogeneous set of Groups.
No non-Group items are present.

**Branch clipboard** -- the resolved items list contains one or more Branch nodes.
Valid for DB-destination pastes only. For E80-destination pastes, branch dissolution
produces effective contents evaluated by their post-dissolution structural category.

**Mixed waypoints-and-route-points clipboard** -- the resolved items list contains a
combination of Waypoint nodes and Route point nodes, with no other types present. This is
the one heterogeneous configuration accepted for route-point positional insertion (SS10.4
and SS10.9).

**Heterogeneous clipboard** -- the resolved items list contains items of two or more
different user-level types, not reducible to a homogeneous category by the above. Most
destinations reject this.

### 6.5 Destination categories

**DB collection root** -- a node that acts as a container for member items: the DB root
node, any Branch node, or any Group node (subject to Group's type restriction in SS1.1).

**DB member node** -- a Waypoint (not in a Group), a Route, a Track, or a Group within a
Branch, held directly in a collection. When this is the right-click target for a plain
paste (not before/after), pre-flight treats the parent collection as the insertion point
and inserts adjacent to the member node (PASTE_AFTER semantics).

**DB route point node** -- a `route_waypoints` reference node within a Route. Distinct
from DB member node: paste-before/after at a route point means route sequence insertion,
not collection insertion. Accepts homogeneous waypoints, homogeneous route points, and the
mixed waypoints-and-route-points clipboard.

**E80 Groups header** -- the E80 collection root for the waypoint/group area. Accepts
Group uploads (compound operations, SS10.6) and ungrouped Waypoint uploads (landing in
My Waypoints). Also a valid Delete right-click target: Delete operates on all groups in
the folder (SS8.2).

**E80 My Waypoints** -- a pseudo-group reserved for the E80's display of ungrouped
waypoints. Accepts Waypoint pastes (result is ungrouped). Cannot be dissolved.
Cannot be created as a named group by navMate. Also a valid Delete right-click target:
Delete operates on all ungrouped waypoints under My Waypoints (SS8.2).

**E80 Group node** -- a named group container within the Groups area. Accepts Waypoint
pastes; waypoints land inside this group. Paste-before/after is not supported at this
destination -- waypoints within a group are ordered by name on the E80 (see SS10.9).

**E80 Waypoint node** -- a member Waypoint within a Group (or My Waypoints). For plain
paste, the incoming waypoints land in the same group as this node. Paste-before/after is
not supported at this destination -- waypoint ordering within a group is by name on the
E80.

**E80 Routes header** -- the E80 collection root for the routes area. Accepts Route
uploads. Paste-before/after is not supported at this destination -- routes are ordered by
name on the E80. Also a valid Delete right-click target: Delete operates on all routes in
the folder (SS8.2).

**E80 Route node** -- a Route as a member of the Routes area. For plain paste, treated as
equivalent to Routes header (the route list is the containing collection). Paste-before/
after is not supported -- route ordering within the Routes folder is by name on the E80.

**E80 Route point node** -- a `route_waypoints` reference node within an E80 Route.
Distinct from E80 Waypoint node: for paste-before/after, accepts homogeneous waypoints,
homogeneous route points, and the mixed waypoints-and-route-points clipboard -- all insert
as `route_waypoints` sequence references. This is the E80-side route reordering and
insertion destination.

**E80 Tracks header / track node / track point** -- no paste accepted; tracks are
read-only on E80. E80 Tracks header is a valid Delete right-click target: Delete operates
on all tracks in the folder (SS8.2).


## 7. Type-Specific Behaviors

Three object types have structural or E80-specific properties that affect their behavior
throughout clipboard, paste, and delete operations. These properties are stated once here
and assumed throughout SS8-SS10.

### 7.1 Groups -- compound objects

A group carries two levels: the group identity (UUID, name) and its member waypoints. When
a group enters the clipboard, both levels travel together as an intact compound object.

Pasting a group to E80 is a compound operation: the group shell is created first via WPMGR,
then each member waypoint is created inside it. This is not a waypoint operation with a
label attached -- the group's existence on E80 as a named, identity-preserving container is
the primary object of the operation.

### 7.2 My Waypoints -- E80 pseudo-group

**My Waypoints** is a reserved name belonging exclusively to the E80. It is the E80 display
node for ungrouped waypoints -- a display container with no UUID of its own, not a real
group. A DB group may never be named "My Waypoints." Any operation that would create a
group with that name in the database must reject or remap it.

On the E80 side, My Waypoints cannot be dissolved; only DELETE_GROUP_WPS applies to it.

When downloading from the E80's My Waypoints node, the contents arrive as individual
ungrouped waypoints in the target DB collection. No group is created; the name is not used.

### 7.3 Route points -- references, not records

Route points are ordered references -- `route_waypoints` rows -- that define a route's
waypoint sequence. They appear in the tree for editing convenience. A route point is not
an independent object; it is a UUID pointer to a waypoint record.

Route points are first-class clipboard objects: COPY and CUT operate on them, producing a
clipboard of ordered waypoint UUID references.

**CUT + PASTE_BEFORE/PASTE_AFTER** is the route reordering mechanism.

**COPY + PASTE** inserts the same waypoint UUID references at the destination -- within one
route (adding a duplicate reference) or across routes.

**REMOVE_ROUTEPOINT** removes the `route_waypoints` row at that position; the underlying
waypoint record is preserved. The menu label is "Delete."

Because a route point and a waypoint both ultimately represent a waypoint UUID, the type
distinction dissolves at route insertion points: a mixed waypoints-and-route-points
clipboard (SS6.4) is accepted for PASTE_BEFORE/PASTE_AFTER at a route point destination on
both panels.

**PASTE_NEW for route points:** inserts new `route_waypoints` reference rows at the
destination position pointing to the same underlying waypoint UUIDs as the clipboard
source. No new waypoint records are created. "New" in this context means a new reference
position in the route sequence, not a new waypoint identity. This applies on both the DB
and E80 panels. The distinction between PASTE and PASTE_NEW collapses for route-point
clipboards: both operations insert references to the same waypoints, and the only
meaningful difference is the position in the route where the references are inserted.

### 7.4 Routes -- compound paste behavior

A route clipboard item carries the route record and its ordered list of waypoint UUID
references. When a route is pasted -- PASTE or PASTE_NEW, to any destination -- the
referenced waypoint UUIDs are always preserved exactly (invariant SS1.6). No new waypoint
records are created as part of a route paste. PASTE_NEW for a route means the route record
receives a fresh UUID; the waypoint references it carries are unchanged.

Pre-flight (SS10.1 Step 4) must confirm that all referenced waypoint UUIDs exist at the
destination before execution begins. If any are missing and not present in the current
operation, the paste is rejected.

When a selection contains both a route and waypoints that are members of that route, those
waypoints are not independently duplicated by the route paste. They are handled separately
by whatever paste rule applies to waypoints in the selection. The route's own
route_waypoints references always point to the original source UUIDs regardless of what
else is in the selection.


## 8. Pre-flight Rules: Delete

Delete pre-flight takes the raw selection and the panel. It does not consult the clipboard.

For nested selections and partial compounds, the ancestor node takes precedence:
descendants already covered by a selected ancestor are not processed separately.

### 8.1 Delete -- DB panel

**Empty selection:** Delete is not offered.

**Single item or homogeneous flat set of Waypoints:**
DELETE_WAYPOINT is offered. Pre-flight checks for `route_waypoints` references on each
selected waypoint. If any selected waypoint has route references, the operation is blocked
with an informational message listing the affected routes. Requires confirm.

**Single item or homogeneous flat set of Routes:**
DELETE_ROUTE is offered. Removes each route record and its `route_waypoints` rows;
member waypoints are preserved. Requires confirm.

**Single item or homogeneous flat set of Tracks:**
DELETE_TRACK is offered. Removes each track record and its `track_points` rows.
Requires confirm.

**Single Group node or homogeneous flat set of Group nodes (intact compound objects):**
Both DELETE_GROUP and DELETE_GROUP_WPS are offered.
- DELETE_GROUP (dissolve): re-parents all member waypoints of all selected groups to each
  group's parent collection, then removes the group shells. Route references to member
  waypoints are unaffected (UUIDs unchanged). Requires confirm.
- DELETE_GROUP_WPS: blocked (with informational message) if any member waypoint of any
  selected group has `route_waypoints` references. If not blocked, removes all member
  waypoints and group shells. Requires confirm.

**Single Branch node (intact compound object):**
DELETE_BRANCH is offered only if `isBranchDeleteSafe` returns true -- meaning no member
waypoint within the branch subtree is referenced by a route outside the subtree. If the
branch is not safe, DELETE_BRANCH is not offered and an informational message explains that
route references must be resolved first. Requires confirm.

**Route point node (REMOVE_ROUTEPOINT):**
Menu label is "Delete." Removes the `route_waypoints` row at the selected position.
The underlying waypoint record is preserved. Route point nodes cannot appear in a
selection alongside nodes of other types; if they do, pre-flight rejects with an error
message. Requires confirm.

**Partial compound -- members selected without their parent:**
Members are treated as individual items of their own type. Waypoints within a partial
Group selection are treated as a homogeneous flat set of Waypoints (the Group type rules
do not apply; no DELETE_GROUP or DELETE_GROUP_WPS is offered).

**Partial compound -- parent selected with some members also individually selected:**
Ancestor-wins: the parent is treated as an intact compound object per the Group or Branch
rules above; the individually selected members are absorbed and not processed separately.

**Heterogeneous flat set (mixed types, no ancestor/descendant pairs):**
Each item is processed by its own type rule above. Route point nodes cannot appear
alongside other types in a heterogeneous selection; if they do, pre-flight rejects.
Execution sequence: DELETE_BRANCH first, then DELETE_ROUTE, then
DELETE_GROUP / DELETE_GROUP_WPS, then DELETE_WAYPOINT, then DELETE_TRACK.

### 8.2 Delete -- E80 panel

Pre-flight walks the raw selection. Ancestor-wins applies to nested selections.
No upfront blocking; dependency warnings are surfaced at confirm time.

Execution order is always enforced regardless of selection order:
DELETE_ROUTE first, then DELETE_GROUP / DELETE_GROUP_WPS, then DELETE_WAYPOINT,
then DELETE_TRACK.

**E80 Routes header (right-clicked as sole selection target):**
Operates on all routes currently in the Routes folder. Equivalent to selecting all routes
and deleting them. DELETE_ROUTE for each. Confirm dialog states the count: "Delete all N
routes from the E80 Routes folder?" Member waypoints are preserved. Requires confirm.

**E80 Groups header (right-clicked as sole selection target):**
Operates on all groups currently in the Groups folder. Both DELETE_GROUP and
DELETE_GROUP_WPS are offered, with the same semantics as for an individual Group (see
Groups rule below). Confirm dialog states count and operation type. Route-dependency check
applies to all member waypoints across all groups. Requires confirm.

**E80 My Waypoints (right-clicked as sole selection target):**
Operates on all ungrouped waypoints under My Waypoints. DELETE_GROUP_WPS only -- My
Waypoints cannot be dissolved (SS7.2). Route-dependency check applies. Confirm dialog
states count. Requires confirm.

**E80 Tracks header (right-clicked as sole selection target):**
Operates on all tracks in the Tracks folder. DELETE_TRACK (TRACK_CMD_ERASE) for each.
Confirm dialog states count. Requires confirm.

**Waypoints:**
DELETE_WAYPOINT. Pre-flight checks whether any selected waypoint is a member of a route
not also in the selection. If so, the user is warned at confirm time and offered:
Abort, or Proceed (route references removed before the waypoint is deleted).

**Groups:**
DELETE_GROUP and DELETE_GROUP_WPS are both offered, with the same member-waypoint
route-check as above. My Waypoints as a group node offers only DELETE_GROUP_WPS -- it
cannot be dissolved.

**Routes:**
DELETE_ROUTE. Member waypoints preserved on E80.

**Tracks:**
DELETE_TRACK (TRACK_CMD_ERASE).

**Route points (REMOVE_ROUTEPOINT):**
Removes the `route_waypoints` reference at the selected position; the underlying waypoint
is preserved on E80. Cannot appear alongside other node types in the selection.

**Partial compound:** same rules as DB panel -- members without parent are treated as
individual items of their type; parent with some members selected uses ancestor-wins.

**Heterogeneous flat set:** per-item processing per the above; same enforced execution
order.


## 9. Pre-flight Rules: Copy and Cut

Copy and Cut are maximally permissive: they accept any non-empty selection on either panel.
Pre-flight validates only that the selection is non-empty.

The selection is snapshotted into the clipboard as `{source, cut_flag, items[]}`. No
normalization, ancestor-wins resolution, or homogeneity check is performed at copy/cut
time. The clipboard carries the raw selection exactly as captured -- including nested
selections and partial compounds.

Ancestor-wins resolution (SS6.2) is deferred to paste pre-flight (SS10) where the
destination provides context for interpretation.

**Cut from DB** records the current collection membership of each item so paste can
re-home it. Source items remain in place until paste executes.

**Cut from E80** records the E80 identity of each item so paste can delete them from E80
after a successful download.

**Cut from DB to E80 is never valid.** A DB-sourced cut clipboard is rejected at any E80
paste destination. This constraint is enforced in paste pre-flight, not at cut time.

**Recursive paste (invariant SS1.5) is not checked here.** The destination is unknown at
copy/cut time. The check runs in SS10.1 Step 3 when the destination is known.


## 10. Pre-flight Rules: Paste

Paste pre-flight takes the clipboard, the right-click destination node, and the destination
panel. It applies a sequence of resolution steps and then evaluates destination-specific
rules.

### 10.1 Resolution steps -- all destinations

These steps run before any destination-specific rule.

**Step 1 -- Ancestor-wins resolution.** Apply SS6.2 to `items`. If the resolved list is
empty, reject with message.

**Step 2 -- Empty clipboard guard.** If the resolved list is empty (belt-and-suspenders
guard), reject.

**Step 3 -- Recursive paste check (invariant SS1.5).** Walk the ancestry of the
destination node upward through the panel tree. If any ancestor of the destination --
including the destination itself -- has a UUID that matches any item in the resolved
clipboard, reject with a message identifying the offending item. This prevents re-parenting
an item into one of its own descendants. On the DB panel this primarily guards against
pasting a Branch or Group into a descendant Branch or Group. On the E80 panel deep nesting
is uncommon but the check runs regardless.

**Step 4 -- Route dependency check (invariant SS1.2, route clipboards only).** If the
resolved clipboard contains any route items, verify that every waypoint UUID referenced by
those routes either already exists at the destination or is present in the current clipboard
and will be processed before the route (waypoints and groups are always processed before
routes -- SS12.1, SS12.5). If any referenced waypoint UUID is absent from both the
destination and the clipboard, reject with a message identifying the affected routes and
missing waypoints. This check applies to all destinations -- DB and E80 alike.

### 10.2 Additional resolution -- E80 destination only

**Step 5 -- Branch dissolution.** Dissolve Branch items per SS6.3 to produce effective
contents. If effective contents are empty, reject.

**Step 6 -- Homogeneity check.** If effective contents are heterogeneous (not all the same
user-level type) and are not a mixed waypoints-and-route-points clipboard, no paste command
is offered at this E80 destination. Pre-flight does not abort -- it simply makes no paste
commands available, leaving Copy, Cut, and Delete as the only menu options.

**Step 7 -- Intra-clipboard name collision check.** Within the effective contents, check
for duplicate names among items of the same user-level type: waypoints against waypoints,
routes against routes, groups against groups. If any two items in the effective contents
share a name within their type, the paste is hard-aborted with a message identifying the
colliding names. This check is necessary because the navMate database permits multiple
items of the same type to share a name (distinguished by UUID); the E80 does not. The
collision cannot be resolved by the paste operation itself -- the user must rename one of
the items in the database before retrying.

For group pastes: member waypoint names are checked across all groups in the effective
contents. Two member waypoints in different groups that share a name constitute an
intra-clipboard collision.

**Step 8 -- E80-wide name collision check.** For each item in the effective contents whose
UUID does not already exist on the E80, check its name against the complete E80 in-memory
database for that type. This is a full breadth scan: waypoint names are checked against
all E80 waypoints regardless of which group they belong to; route names against all E80
routes; group names against all E80 groups. The E80 enforces name uniqueness per type
across the entire device.

If any item's name is already in use on the E80 by an item with a different UUID, the
paste is hard-aborted with a message identifying the conflicting item by name and type.
No auto-rename; no "continue anyway." The user must resolve the name conflict before
retrying.

For group pastes: group shell names are checked first; a group-level name collision aborts
before member waypoints are inspected.

Items passing Steps 7 and 8 have confirmed name safety. UUID-based conflict resolution
(where the clipboard item's UUID already exists on the E80) is deferred to SS10.10.

### 10.3 Paste to DB -- collection root or member node

**Destination: DB collection root or DB member node.** Member node destinations: pre-flight
uses the member's parent collection as the insertion point and inserts adjacent to the
member node (PASTE_AFTER semantics). DB root accepts all clipboard types. Group node
destinations accept Waypoints and intact-group clipboards only (invariant SS1.1); all other
types are rejected with an informational message.

| Clipboard category (after SS10.1)      | source | cut_flag | PASTE | PASTE_NEW | Notes                                               |
|----------------------------------------|--------|----------|-------|-----------|-----------------------------------------------------|
| Homogeneous waypoints                  | DB     | no       | --    | Y         | Duplicate with fresh UUIDs                          |
| Homogeneous waypoints                  | DB     | yes      | Y     | --        | Move -- re-home collection_uuid                     |
| Intact-group clipboard                 | DB     | no       | --    | Y         | Duplicate group + members, fresh UUIDs              |
| Intact-group clipboard                 | DB     | yes      | Y     | --        | Move group shell; members travel with it            |
| Homogeneous routes                     | DB     | no       | --    | Y         | Fresh route UUID; waypoint refs preserved (SS1.6)   |
| Homogeneous routes                     | DB     | yes      | Y     | --        | Move route record; waypoint refs preserved          |
| Homogeneous tracks                     | DB     | no       | --    | --        | DB track copy not supported                         |
| Homogeneous tracks                     | DB     | yes      | Y     | --        | Move track                                          |
| Branch clipboard                       | DB     | no       | --    | Y         | Duplicate all branch contents, fresh UUIDs          |
| Branch clipboard                       | DB     | yes      | Y     | --        | Move all branch contents to new parent collection   |
| Heterogeneous flat set                 | DB     | no       | --    | Y         | Duplicate all items, fresh UUIDs                    |
| Heterogeneous flat set                 | DB     | yes      | Y     | --        | Move all items                                      |
| Homogeneous waypoints                  | E80    | no       | Y     | Y         | Download / download with fresh UUID                 |
| Homogeneous waypoints                  | E80    | yes      | Y     | --        | Download + delete from E80                          |
| Intact-group clipboard                 | E80    | no       | Y     | Y         | Download group + members                            |
| Intact-group clipboard                 | E80    | yes      | Y     | --        | Download group + members + delete from E80          |
| Homogeneous routes                     | E80    | no       | Y     | Y         | Download route                                      |
| Homogeneous routes                     | E80    | yes      | Y     | --        | Download route + delete from E80                    |
| Homogeneous tracks                     | E80    | no       | Y     | --        | Download; PASTE_NEW not available for tracks        |
| Homogeneous tracks                     | E80    | yes      | Y     | --        | Download + E80 erase                                |
| Heterogeneous flat set                 | E80    | no       | Y     | Y         | Download all; waypoints/groups before routes; existing UUIDs updated in-place (SS12.1) |
| Heterogeneous flat set                 | E80    | yes      | Y     | --        | Download + E80 delete; same ordering                |

My Waypoints download (source = E80 WP destination, My Waypoints node): contents arrive
as individual ungrouped Waypoints in the target DB collection. No Group is created; the
name "My Waypoints" is not used.

### 10.4 Paste Before and After -- DB panel

Available when the right-click target is a DB member node or a DB route point node.
PASTE_NEW variants are available for copy operations only.

| Clipboard category (after SS10.1)              | Destination node        | PASTE_B/A | PASTE_NEW_B/A  | Notes                      |
|------------------------------------------------|-------------------------|-----------|----------------|----------------------------|
| Homogeneous waypoints                          | Waypoint                | Y         | Y (copy only)  | Insert at position         |
| Homogeneous routes                             | Route                   | Y         | Y (copy only)  | Insert at position         |
| Homogeneous tracks                             | Track                   | Y         | Y (copy only)  | Insert at position         |
| Intact-group clipboard                         | Group                   | Y         | Y (copy only)  | Insert at position         |
| Homogeneous route points                       | Route point             | Y         | Y (copy only)  | Reference splice           |
| Homogeneous waypoints                          | Route point             | Y         | Y (copy only)  | Reference splice           |
| Mixed waypoints-and-route-points               | Route point             | Y         | Y (copy only)  | Reference splice (only accepted mixed case) |
| Branch clipboard                               | any                     | --        | --             | Branch not positional      |
| Homogeneous type A                             | type B node             | --        | --             | Type mismatch              |
| Any other heterogeneous                        | any                     | --        | --             | Mixed rejected             |

### 10.5 Paste to E80 -- WP destinations

Applies after SS10.2. DB-sourced cut is never valid at any E80 destination.

| Effective contents category    | source | cut_flag | PASTE | PASTE_NEW | Notes                          |
|--------------------------------|--------|----------|-------|-----------|--------------------------------|
| Homogeneous waypoints          | DB     | no       | Y     | Y         | Upload                         |
| Homogeneous waypoints          | DB     | yes      | --    | --        | DB cut -> E80 blocked          |
| Homogeneous waypoints          | E80    | no       | Y     | Y         | Re-upload / duplicate          |
| Homogeneous waypoints          | E80    | yes      | Y     | --        | Re-home on E80 + delete source |

### 10.6 Paste to E80 -- Groups header (group upload)

| Effective contents category    | source | cut_flag | PASTE | PASTE_NEW | Notes                               |
|--------------------------------|--------|----------|-------|-----------|-------------------------------------|
| Intact-group clipboard         | DB     | no       | Y     | Y         | Upload group (compound operation)   |
| Intact-group clipboard         | DB     | yes      | --    | --        | DB cut -> E80 blocked               |
| Intact-group clipboard         | E80    | no       | Y     | Y         | Re-upload / duplicate group         |
| Intact-group clipboard         | E80    | yes      | Y     | --        | Re-home on E80 + delete source      |

### 10.7 Paste to E80 -- Routes header

| Effective contents category    | source | cut_flag | PASTE | PASTE_NEW | Notes                               |
|--------------------------------|--------|----------|-------|-----------|-------------------------------------|
| Homogeneous routes             | DB     | no       | Y     | Y         | Upload route                        |
| Homogeneous routes             | DB     | yes      | --    | --        | DB cut -> E80 blocked               |
| Homogeneous routes             | E80    | no       | Y     | Y         | Re-upload / duplicate               |
| Homogeneous routes             | E80    | yes      | Y     | --        | Re-home on E80 + delete source      |

### 10.8 Paste to E80 -- Tracks header, track node, or track point

No paste of any kind is accepted. Tracks are read-only on the E80.

### 10.9 Paste Before and After -- E80 panel

On the E80 panel, PASTE_BEFORE and PASTE_AFTER are valid **only for Route point
destinations**. The E80 does not support explicit positional placement of waypoints within
groups, routes within the Routes folder, or groups within the Groups folder -- those
collections are displayed in name-sorted order by the E80 tree (see SS6.5). Attempting
positional paste to any E80 destination other than a Route point node is not offered.

Applies after SS10.2. DB-sourced cut is blocked. PASTE_NEW variants for copy only.

| Effective contents category              | Destination node | PASTE_B/A | PASTE_NEW_B/A  | Notes               |
|------------------------------------------|------------------|-----------|----------------|---------------------|
| Homogeneous route points                 | Route point      | Y         | Y (copy only)  | Reference splice    |
| Homogeneous waypoints                    | Route point      | Y         | Y (copy only)  | Reference splice    |
| Mixed waypoints-and-route-points         | Route point      | Y         | Y (copy only)  | Reference splice    |
| Any clipboard                            | non-route-point  | --        | --             | Not supported on E80|

### 10.10 E80-specific checks (all E80 destinations, SS10.5-SS10.9)

These checks run for all E80-destination paste operations after the structural pre-flight
above passes. Name collision hard-aborts have already been handled by Steps 7 and 8 in
SS10.2; the items reaching this point have confirmed name safety. The route dependency
check (SS10.1 Step 4) has already confirmed all referenced waypoints exist on E80 or are
in the current operation. This section handles UUID-based conflict resolution.

**UUID conflict check.** For each item to be created on E80 (name safety already
confirmed by Step 6):

- UUID not on E80 -> **clean create**; proceed.
- UUID on E80, `db_version` > `e80_version` -> **refresh**; update without prompting.
  *(Version increment wiring is deferred; currently treated as a plain conflict.)*
- UUID on E80, version relationship unclear -> **conflict**; user is warned and decides
  whether to overwrite.

**Group-level conflict check.** For group pastes, the UUID check runs first for the group
shell, then for each member waypoint. A group-level conflict that the user chooses to skip
removes the entire group (shell and members) from the operation.

**Item count dialog.** If any items fall into the conflict category, the user chooses:
skip conflicting items and continue with clean creates, or abort. If Abort, no E80 writes
occur.


## 11. New Item Placement

New commands are placement-driven. Pre-flight for New is minimal: it reads only the
right-click node type; selection state is ignored. All New commands open a name-input
dialog and are excluded from automated testing.

A New command on a collection node places the new item first in that collection. A New
command on a terminal node places it immediately after the right-clicked node.

**DB panel:**

| Right-click node    | Commands offered                                          |
|---------------------|-----------------------------------------------------------|
| DB root, Branch     | New Branch, New Group, New Route, New Waypoint            |
| Group               | New Waypoint                                              |
| Waypoint            | New Waypoint (sibling, inserts after)                     |
| Route               | New Route (sibling, inserts after)                        |
| Route point         | -- *[needs validation]*                                   |
| Track, track point  | --                                                        |

**E80 panel:**

| Right-click node          | Commands offered                                      |
|---------------------------|-------------------------------------------------------|
| Groups header             | New Group, New Waypoint (ungrouped -> My Waypoints)   |
| My Waypoints              | New Waypoint                                          |
| Group                     | New Waypoint (inside this group)                      |
| Waypoint                  | New Waypoint (sibling, inserts after)                 |
| Routes header             | New Route                                             |
| Route, route point        | -- *[needs validation]*                               |
| Tracks header, track      | --                                                    |


## 12. Operation Semantics

Operation Semantics describes what happens after pre-flight passes and execution begins.
Pre-flight is assumed to have validated all preconditions; the execution code does not
re-check what pre-flight already confirmed.

### 12.1 Paste to Database from E80 -- download

UUID-preserving merge into the navMate DB. For each item in the clipboard:

- UUID not in DB -> insert record in target collection.
- UUID in DB, data identical -> no-op.
- UUID in DB, data differs -> conflict dialog: Replace / Skip / Replace All / Skip All / Abort.

**Replace means update in-place.** When a UUID already exists in the DB, Replace updates
the record's data fields but does not change its collection_uuid. Existing items stay where
they are in the DB hierarchy. Only items whose UUIDs do not exist anywhere in the DB are
placed at the paste destination. The paste destination is the landing zone for new items
only, not a re-homing target for existing ones.

**Execution ordering (E80-source pastes only).** When the clipboard source is E80,
waypoints and group members are always processed before routes, regardless of the order
items appear in the clipboard. For DB-source pastes this ordering is not required -- the
referenced waypoints already exist in the DB and the route paste simply references their
existing UUIDs (SS1.6). The ordering guarantee for E80-source pastes ensures that any
user-initiated Abort during the conflict dialog leaves the DB in a consistent state:
orphaned waypoints may result from an Abort during the waypoint phase, but route records
with broken waypoint references cannot result from an Abort during the route phase, because
all waypoints will already have been processed.

**Groups:** the group collection is created under the target if absent (merge semantics;
existing members are preserved). Member waypoints are merged individually per the above.
My Waypoints content arrives as ungrouped waypoints -- no group is created.

**Routes:** the route record is inserted (if UUID new to DB) or updated in-place (if UUID
exists). The route_waypoints list is rebuilt from the clipboard. Waypoint UUID references
are preserved exactly (SS1.6); no new waypoint records are created by the route paste.

**Cut variant:** after each item is successfully pasted, the source item is deleted from
E80 via WPMGR commands.

### 12.2 Paste to Database from Database -- Cut (move)

Re-homes the object to the new collection without changing its UUID. No conflict check.

- Waypoints: `UPDATE waypoints SET collection_uuid = ? WHERE uuid = ?`
- Groups: `UPDATE collections SET parent_uuid = ? WHERE uuid = ?`
- Routes: `UPDATE routes SET collection_uuid = ? WHERE uuid = ?`
- Tracks: `UPDATE tracks SET collection_uuid = ? WHERE uuid = ?`

A group move carries only the group shell; member waypoints remain inside the group and
travel with it (they reference the group UUID, not the parent collection). A route move
carries only the route record; member waypoints stay in their current collections.

### 12.3 Paste New to Database

Inserts with fresh navMate UUIDs regardless of source. No conflict check. Available for
copy operations only.

**Routes:** the new route record receives a fresh UUID. The route_waypoints references
preserve the source waypoint UUIDs exactly -- no new waypoint records are created (SS1.6).
Pre-flight (SS10.1 Step 4) has already confirmed all referenced waypoints exist in the DB.

**Tracks:** PASTE_NEW is not available for any track clipboard. Track duplication within
the database requires Cut -> Paste (move).

### 12.4 Version field management

Every item in the navMate database carries two version fields: `db_version` (incremented
each time the DB record is modified) and `e80_version` (the `db_version` value that was
current at the time the item was last successfully written to the E80). These fields are
maintained by nmOperations on every write path.

**New item created in DB (any NEW_* command):**
`db_version` is set to 1. `e80_version` is set to NULL, indicating the item has never
been uploaded to the E80.

**DB record modified (any operation that changes item fields):**
`db_version` is incremented by 1. `e80_version` is unchanged. If `e80_version` was not
NULL, the item is now in a db-ahead state (db_version > e80_version), which the
synchronization color scheme and refresh logic use to detect staleness.

**PASTE_NEW to DB (duplicating from any source):**
New record, `db_version` = 1, `e80_version` = NULL. The new item has no E80 history
regardless of source.

**Successful upload to E80 (PASTE or PASTE_NEW to E80, any type):**
After WPMGR confirms the item was created or updated on the E80, set
`e80_version` = `db_version` for that item. The item is now in a synchronized state.
For group uploads, this update applies to the group shell record and to each member
waypoint record individually.

**Refresh (upload where db_version > e80_version):**
Pre-flight step 7 (SS10.2) identifies this case. Execution overwrites the E80 item
without prompting, then sets `e80_version` = `db_version` on success.

**Download from E80 to DB (PASTE or PASTE_NEW from E80 source):**
- PASTE (UUID-preserving): if the item UUID already exists in DB, update the record and
  set `db_version` incremented, `e80_version` = current `db_version` (synchronized).
  If UUID is new to DB, insert with `db_version` = 1, `e80_version` = 1 (synchronized
  at import).
- PASTE_NEW (fresh UUIDs): new record, `db_version` = 1, `e80_version` = NULL. The
  downloaded item is treated as a new DB item with no further E80 relationship.

**Cut from E80 + Paste to DB (download + E80 erase):**
Same as download above for the DB record. After successful paste, the E80 item is
deleted; `e80_version` is set to NULL on the DB record to reflect that the item no
longer exists on the E80.

### 12.5 Paste to E80 -- upload

Sends WPMGR NEW_ITEM commands in dependency order:

- **Waypoints:** one NEW_ITEM per waypoint, followed by GET_ITEM to confirm. The
  destination node determines group assignment per SS6.5.
- **Groups:** compound operation. Create the group shell first (NEW_ITEM for the group),
  then create each member waypoint inside it.
- **Routes:** pre-flight has already verified all member waypoint UUIDs exist on E80.
  Create the route referencing those existing UUIDs. No waypoints are created as a
  side effect.
- **Branch (dissolved):** effective contents reaching execution are homogeneous -- the
  homogeneity check (SS10.2 Step 6) has already rejected any mixed-type dissolution. The
  upload proceeds per the rules for that single type above.

The progress dialog protection pattern wraps all Paste-to-E80 operations, using the same
pattern as `_doRefreshE80Data` in `winMain.pm`. Do not reinvent this pattern.

### 12.6 Paste Before and After

**DB -- collection ordering:** inserts items at the specified position within the parent
collection, adjacent to the right-clicked node. Position FLOAT values are assigned to
accommodate the insertion per the ordering scheme (SS1.4).

**DB -- route point insertion:** when the destination is a route point, inserts clipboard
waypoints into `route_waypoints` at the specified sequence position. Existing references
at and after that position are shifted. Underlying waypoint records are referenced, not
duplicated.

**E80 -- route point insertion only:** on the E80 panel, PASTE_BEFORE and PASTE_AFTER
are valid only at Route point destinations (SS10.9). Inserts the clipboard waypoints or
route point references into the route's `route_waypoints` sequence at the specified
position. The E80 does not support explicit positional placement of waypoints within
groups or routes within the Routes folder; those are ordered by name. No WPMGR
position-aware create is required -- the route_waypoints sequence is rebuilt in the
correct order during upload.

Paste New Before/After at a route point destination: inserts new `route_waypoints`
references pointing to the same underlying waypoint UUIDs (copy semantics --
no new waypoint records are created; see SS7.3).

### 12.7 Delete -- Database

Execution follows the pre-flight determination from SS8.1.

- **DELETE_WAYPOINT:** deletes the waypoint record.
- **DELETE_GROUP (dissolve):** re-parents member waypoints to the group's parent
  collection (`collection_uuid` updated in place), then deletes the group shell.
- **DELETE_GROUP_WPS:** deletes each member waypoint, then the group shell.
- **DELETE_ROUTE:** deletes the route and its `route_waypoints` rows; member waypoints
  are preserved.
- **DELETE_TRACK:** deletes the track and its `track_points` rows.
- **DELETE_BRANCH:** recursively deletes the branch and all descendants: sub-collections,
  waypoints, routes, route_waypoints, tracks, and track_points.
- **REMOVE_ROUTEPOINT:** removes the one `route_waypoints` row at the selected position.

### 12.8 Delete -- E80

Execution follows pre-flight determination from SS8.2 in the enforced order:
DELETE_ROUTE -> DELETE_GROUP / DELETE_GROUP_WPS -> DELETE_WAYPOINT -> DELETE_TRACK.

- **DELETE_WAYPOINT:** WPMGR DELETE_ITEM for each waypoint.
- **DELETE_GROUP (dissolve):** removes the group shell; member waypoints become ungrouped
  (attached to My Waypoints).
- **DELETE_GROUP_WPS:** WPMGR DELETE_ITEM for each member waypoint, then the group shell.
- **DELETE_ROUTE:** WPMGR DELETE_ITEM for the route.
- **DELETE_TRACK:** sends TRACK_CMD_ERASE.
- **REMOVE_ROUTEPOINT:** removes the route_waypoints reference; the underlying waypoint is
  preserved.


## 13. Testability

### 13.1 Suppress mechanism

`nmDialogs.pm` exports `$suppress_confirm`, a threads-shared variable. When set to 1,
both confirmation dialogs **and** error/warning dialogs are suppressed -- they auto-accept
their default response without user interaction. This covers all modal dialogs in the
nmOperations flow and enables fully automated test execution through failure paths, not
just success paths.

Reset `$suppress_confirm` to 0 for any test step that needs to verify a specific dialog
fires rather than auto-accepting.

### 13.2 /api/test endpoint

Context menu operations are driven programmatically via the `/api/test` HTTP endpoint
(port 9883). The HTTP thread encodes the query params as JSON and stores them in a shared
variable; `winMain::onIdle` picks up the command within ~20 ms and calls
`nmTest::dispatchTestCommand`, which walks the tree to set the selection and right-click
node, then calls `onContextMenuCommand` directly -- the same code path as a real right-click
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

### 13.3 CTX_CMD constants

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

### 13.4 Progress dialog pattern

Any Paste-to-E80 operation opens a ProgressDialog using the same pattern as
`_doRefreshE80Data` in `winMain.pm`. The `onIdle` dispatch guard prevents new
`/api/test` commands from firing while the dialog is active. Poll `dialog_state` before
issuing the next step:

```
curl -s "http://localhost:9883/api/command?cmd=dialog_state"
```

Returns `dialog_state: active` or `dialog_state: idle` in the ring buffer. If stuck:

```
curl -s "http://localhost:9883/api/command?cmd=close_dialog"
```

**Bounded polling example:**

```powershell
for ($i = 1; $i -le 20; $i++) {
    $result = curl -s "http://localhost:9883/api/command?cmd=dialog_state"
    $log    = curl -s "http://localhost:9883/api/log?since=$mark"
    if ($log -match "dialog_state: idle") { break }
    Start-Sleep 1
}
if ($i -gt 20) {
    [console]::beep(800, 200)   # stuck -- inspect screen; optionally close_dialog
}
```

---

**Back:** [Implementation](implementation.md)
