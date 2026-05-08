# navMate -- nmOps Test Plan

Test cases for the nmOperations feature. For the design specification and pre-flight rules
see nmOperations.md (SS1-SS13). For the companion execution script with UUID table and curl
commands see nmOps_testplan_runbook.md (Claude-facing, in the memory folder).

This plan describes WHAT to test and WHAT to expect -- in terms of user operations and
system behavior. It reads as a spec a human tester could follow manually without knowing
the implementation. All node-level identifiers, data shapes, and curl commands live in
the runbook.

**NEW_* commands are excluded from automation.** NEW_WAYPOINT, NEW_GROUP, NEW_ROUTE, and
NEW_BRANCH open name-input dialogs that block the test machinery.


## Database Shape Requirements

The baseline navMate.db must have the following structural shape. The runbook UUID table
selects specific named nodes to satisfy all requirements. Do not change the baseline DB
without updating the runbook.

**Isolated waypoints** -- at least three waypoints not in any group and not referenced in
any route. For clean copy/paste/delete without pre-flight side effects.

**WP referenced in a route** -- at least one waypoint that IS in a route. For the
DEL_WAYPOINT blocked path (SS8.1) and route dependency pre-flight (SS10.10).

**Group with no route refs** -- a group whose member WPs are not referenced by any route.
For DELETE_GROUP and DELETE_GROUP_WPS success paths (§2.4, §2.5). Two such groups are
required -- §2.4 and §2.5 each consume their target group and cannot share one.

**Group whose members ARE in a route** -- for DELETE_GROUP_WPS blocked path (§2.6) and
E80 route dependency tests.

**Route with at least 3 ordered route_waypoints** -- for PASTE_BEFORE/AFTER route sequence
tests (§2.14, §3.19). The runbook pre-resolves the first three points as RP1, RP2, RP3.

**Branch safe for recursive delete** -- no member WP referenced by a route outside the
branch subtree. For DELETE_BRANCH (§2.7).

**Collection nodes for positional anchor tests** -- a group node and a branch node are
required as PASTE_BEFORE/AFTER anchor targets (§2.16, §2.17). Any group and any branch in
the DB qualify; the runbook selects specific nodes.

**Nested branch** -- a branch with at least one child branch. For the recursive paste
guard test (§5.9).

**At least one track** -- for DB cut/paste track move (§2.12) and E80 track tests (§4).

**Name collision setup** -- the baseline DB does not require duplicate-named items.
Collision tests in §5.10 and §5.11 use dynamic setup; see those sections.


## Infrastructure

### Command constants

These are the context-menu command names used throughout this plan.

```
COPY  = 10010
CUT   = 10110

PASTE             = 10300
PASTE_NEW         = 10301
PASTE_BEFORE      = 10302
PASTE_AFTER       = 10303
PASTE_NEW_BEFORE  = 10304
PASTE_NEW_AFTER   = 10305

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

COPY and CUT are unified commands. The selection set determines clipboard contents;
pre-flight at paste time classifies the items. PASTE_BEFORE/AFTER variants are new and
have no prior equivalent.

### Suppress mechanism

All modal dialogs (confirmation, warning, ancestor-wins, conflict resolution) can be
auto-accepted via the suppress mechanism. Enable it via the test API before any operation
that would otherwise block on user input.

**Outcome control (two-outcome dialogs).** Some pre-flight paths produce dialogs with two
meaningful outcomes -- ancestor-wins (proceed vs. abort), UUID conflict (skip+continue vs.
abort), E80 DEL-WP with route-ref warning (proceed vs. abort). Testing the non-default
path requires outcome=reject support. See [nmOps testability prerequisites] in todo.md.
Tests in §5 that require outcome=reject are flagged PREREQUISITE in their headers.

For all other tests in this plan, suppress=1 with default accept behavior is assumed.

### Progress dialog

Any Paste-to-E80 or Delete-from-E80 operation opens a ProgressDialog asynchronously. The
onIdle dispatch guard prevents the next test command from firing while the dialog is active.
Always wait for ProgressDialog FINISHED before proceeding.

A STARTED without a matching FINISHED is at minimum a PARTIAL failure. A hung dialog that
cannot be closed is catastrophic.

### Log verification

After every command, scan the log since the preceding mark for: ERROR, WARNING,
IMPLEMENTATION ERROR. Do not proceed to the next step until the log is clean (or the
expected warning has been confirmed for guard tests).


## §1 Reset to Known State

Run all steps before any test. Record wall-clock start time (needed for last_testrun.md).

1. Record wall-clock start time.
2. Revert navMate.db to the git baseline in C:/dat/Rhapsody.
3. Reload the database in navMate.
4. Enable suppress **before** any E80 operation -- suppress must be set before dialogs
   can be triggered; any E80 operation without suppress will block.
5. Clear the E80: delete all routes first (wait for ProgressDialog FINISHED), then all
   groups and their WPs (wait for ProgressDialog FINISHED), then any remaining ungrouped
   WPs (wait for ProgressDialog FINISHED).
6. Mark the log and record the sequence number.

After reset: verify navMate.db is clean in git. Verify the E80 state is empty --
no waypoints, groups, routes, or tracks.

Route point derivation: the runbook has pre-resolved static UUIDs for the first three
route_waypoints of the test route (sorted by position). Re-derive only if the baseline
DB changes.


## §2 Database Tests (no E80 required)

E80 need not be connected for this section.

---

### §2.1 Copy WP -> Paste New (duplicate with fresh UUID)

Select a single waypoint that is not in any group and not referenced in any route. COPY it.
Right-click a destination branch and PASTE_NEW.

Expected: a new waypoint with the same name and attributes appears in the destination with
a fresh UUID different from the source. The source waypoint is unchanged in its original
location.
Log: COPY STARTED/FINISHED, PASTE_NEW STARTED/FINISHED, no errors.

---

### §2.2 Cut WP -> Paste (move)

Select a different isolated waypoint (not the one used in §2.1). CUT it. Right-click the
destination branch and PASTE.

Expected: the waypoint moves to the destination with its UUID unchanged. It is absent from
its original location.
Log: CUT STARTED/FINISHED, PASTE STARTED/FINISHED, no errors.

---

### §2.3 Delete WP (success)

Select a third isolated waypoint (not used in §2.1 or §2.2). Right-click and DELETE_WAYPOINT.

Expected: the waypoint is deleted. It no longer appears anywhere in the database.
Log: DELETE_WAYPOINT STARTED/FINISHED, no errors.

---

### §2.4 Delete Group -- dissolve (members reparented to parent collection)

Select a group whose member WPs are not referenced in any route. This must be a **different
group from the one used in §2.5** -- both steps require a group with no route refs, and each
consumes its target group. Right-click and DELETE_GROUP.

Expected: the group shell is deleted. All member WPs are reparented to the group's former
parent branch with their UUIDs unchanged. Any route references to those WPs remain unaffected.
Log: DELETE_GROUP STARTED/FINISHED, no warnings.

---

### §2.5 Delete Group+WPS -- success (members not in route)

Select a second group (intact after §2.4) whose member WPs are not referenced in any route.
Right-click and DELETE_GROUP_WPS.

Expected: the group shell and all member WPs are deleted. Neither the group nor any of its
former members appear in the database.

---

### §2.6 Delete Group+WPS -- blocked (members in route) -- pre-flight failure

Select a group whose member WPs ARE referenced in a route. Right-click and DELETE_GROUP_WPS.

Expected: the operation is blocked by the pre-flight check. WARNING in the log. The group
and all its member WPs are unchanged.
Note: the test API bypasses the menu guard and hits the handler-level sentinel directly;
the IMPLEMENTATION ERROR sentinel in the log is expected behavior for this path.

---

### §2.7 Delete Branch (recursive, safe)

Select a branch whose entire descendant tree contains no WP referenced by a route outside
the branch subtree (isBranchDeleteSafe=1). Right-click and DELETE_BRANCH.

Expected: the branch and all descendants are deleted -- sub-collections, member WPs, routes,
route_waypoints, tracks, track_points. Nothing from the branch subtree remains.
Log: DELETE_BRANCH STARTED/FINISHED, no errors.

---

### §2.8 Copy Branch -> Paste New (duplicate branch contents, fresh UUIDs)

Select a branch that contains groups and routes. COPY it. Right-click the destination branch
and PASTE_NEW.

Expected: all groups, routes, and WPs from the source branch are duplicated in the
destination with fresh navMate UUIDs. Tracks in the source are silently skipped (PASTE_NEW
is not supported for tracks). The source branch is unchanged.
Log: COPY STARTED/FINISHED, PASTE_NEW STARTED/FINISHED, no errors.

---

### §2.9 Cut Branch -> Paste (move branch contents)

Select a branch that has groups and tracks (with WPs not in routes). CUT it. Right-click
the destination branch and PASTE.

Expected: all contents of the source branch (groups, tracks, WPs) move to the destination
with UUIDs preserved. The source branch shell becomes empty.

---

### §2.10 Copy Route -> Paste New (fresh route UUID, WP refs preserved)

Select a route. COPY it. Right-click the destination branch and PASTE_NEW.

Expected: a new route record appears in the destination with a fresh UUID (byte 1 = 0x82).
The route_waypoints sequence is rebuilt referencing the same WP UUIDs as the source -- no new
waypoint records are created (SS1.6, SS12.3). Pre-flight Step 4 confirms all referenced WP
UUIDs exist in the DB. The original route and its member WPs are unchanged.

---

### §2.11 Cut Route -> Paste (move route record)

Select the test route. CUT it. Right-click the destination branch and PASTE.

Expected: the route record moves to the destination with its UUID unchanged. The
route_waypoints sequence is unchanged. The route is absent from its original location.
(After this step, the test route UUID is still valid and used in §2.14, §2.15, §2.18, and §3.x.)

---

### §2.12 Cut Track -> Paste (move track record)

Select a track. CUT it. Right-click the destination branch and PASTE.

Expected: the track moves to the destination with its UUID unchanged. Track points are
unchanged. The track is absent from its original location.
(After this step, the track UUID is still valid and used in §4.3 and §5.5.)

---

### §2.13 Paste New Before/After -- collection member (positional insertion)

Copy a waypoint. Right-click a sibling waypoint in the same collection and PASTE_NEW_BEFORE.

Expected: a fresh-UUID copy of the source appears at a position between the sibling's
predecessor and the sibling. Position is a float-valued ordering field; confirm the new
position value falls between the predecessor and sibling values.

Copy the same source again. Right-click the same sibling and PASTE_NEW_AFTER.

Expected: another fresh-UUID copy appears at a position after the sibling.

---

### §2.14 Paste Before/After -- route point (route sequence reordering)

Uses the test route (now in the destination branch after §2.11 -- UUID still valid) with
its first three route points RP1, RP2, RP3 in position order.

**Copy-splice (PASTE_NEW_BEFORE): insert duplicate reference**

Copy route point RP1. Right-click route point RP3 and PASTE_NEW_BEFORE (insert before RP3,
between RP2 and RP3).

Expected: RP1's WP UUID appears again in the route at a position between RP2 and RP3. The
underlying waypoint record is unchanged. Total route point count increases by 1.

**Cut-splice (PASTE_BEFORE): reorder without duplicating**

Cut route point RP3. Right-click route point RP2 and PASTE_BEFORE.

Expected: RP3's reference now appears before RP2 in the route sequence. Total count is
unchanged (move, not copy).

---

### §2.15 Paste Before/After -- route object as anchor

The anchor is a route node (object node, obj_type=route). This exercises the cross-table
neighbor query when the anchor is a route object rather than a waypoint.

COPY an isolated waypoint. Right-click the test route ([TestRoute], now in [DST] after
§2.11) as the anchor and PASTE_NEW_BEFORE.

Expected: a fresh-UUID copy of the waypoint appears at a collection position immediately
before [TestRoute] within [DST]'s ordering. The position value falls between the route's
predecessor and the route's own position. [TestRoute] and its route_waypoints are unchanged.

COPY the same waypoint again. Right-click [TestRoute] and PASTE_NEW_AFTER.

Expected: another fresh-UUID copy appears at a position immediately after [TestRoute] in
[DST]'s ordering.

---

### §2.16 Paste Before/After -- group node as anchor

The anchor is a group node (collection node, node_type=group). This exercises the neighbor
query across the group boundary.

COPY an isolated waypoint. Right-click a group node as anchor and PASTE_NEW_BEFORE.

Expected: a fresh-UUID copy of the waypoint appears at a position immediately before the
group in the group's parent collection ordering. The group's membership is unchanged; the
new WP is a sibling of the group in the parent collection, not a member.

---

### §2.17 Paste Before/After -- branch node as anchor

The anchor is a branch node (collection node, node_type=branch). This exercises the neighbor
query at a branch boundary.

COPY an isolated waypoint. Right-click a branch node as anchor and PASTE_NEW_BEFORE.

Expected: a fresh-UUID copy of the waypoint appears at a position immediately before the
branch in the branch's parent collection ordering. The branch's contents are unchanged.

---

### §2.18 Paste Before/After -- non-waypoint item in clipboard

Tests PASTE_BEFORE/AFTER where the clipboard contains a route or group object rather than
a plain waypoint.

**Route clipboard:** COPY [TestRoute] (still in [DST] after §2.11). Right-click a sibling
waypoint anchor in [DST] and PASTE_NEW_BEFORE.

Expected: a fresh-UUID copy of the route appears at a position before the anchor in [DST]'s
ordering. The new route record has a fresh UUID; its route_waypoints reference the same WP
UUIDs as the source (SS1.6). No new waypoint records are created.

**Group clipboard:** COPY a group (one with no route refs so pre-flight Step 4 passes
trivially). Right-click the same or a different waypoint anchor in [DST] and PASTE_NEW_BEFORE.

Expected: a fresh-UUID copy of the group (with fresh UUIDs for the group shell and all member
WPs) appears before the anchor. The source group and its members are unchanged.


## §3 E80 Tests (upload/download)

E80 must be connected and empty after §1 reset.

**State note entering §3:** the test route (UUID unchanged from §2.11) is in the destination
branch. The group containing the test route's member WPs is intact (§2.6 was blocked).

**§3.1-§3.3 dual role:** §3.1, §3.2, and §3.3 each populate the E80 with data that later
steps in §3 depend on, but they are also actual tests in their own right -- each exercises
a distinct UUID-preserving DB-to-E80 paste path (single WP, group, route). All three must
pass before proceeding; a failure in any one affects the validity of later steps.

---

### §3.1 Paste WP to E80 (UUID-preserving upload)

COPY an isolated waypoint from the DB. In the E80 panel, right-click the Groups header and
PASTE. Wait for ProgressDialog FINISHED. Note the E80 UUID (should equal the DB UUID).

Expected: waypoint appears on E80 as an ungrouped WP with the same UUID as in the DB.

---

### §3.2 Paste Group to E80 (UUID-preserving upload)

COPY a group whose member WPs are also members of the test route. In the E80 panel,
right-click the Groups header and PASTE. Wait for ProgressDialog FINISHED. Note the E80
group UUID.

Expected: group appears on E80 with the same UUID as in the DB; all member WPs appear as
members of that group, each with their DB UUIDs preserved.

---

### §3.3 Paste Route to E80 (UUID-preserving upload)

COPY the test route. In the E80 panel, right-click the Routes header and PASTE. The route's
member WPs must already be on the E80 (§3.2 put them there; SS10.10 pre-flight verifies
this). Wait for ProgressDialog FINISHED. Note the E80 route UUID.

Expected: route appears on E80 with the same UUID as in the DB; its route_waypoints sequence
matches the DB ordering (same WP UUIDs, same positional order).

---

### §3.4 Copy E80 WP -> Paste to DB (UUID-preserving download)

In the E80 panel, COPY the uploaded waypoint. Right-click the destination branch in the DB
panel and PASTE.

Expected: the waypoint appears in the DB with the E80's UUID (byte 1 = 0xB2) preserved.
Log: COPY STARTED/FINISHED, PASTE STARTED/FINISHED, no errors.

---

### §3.5 Copy E80 WP -> Paste New to DB (fresh UUID)

COPY the same E80 waypoint. Right-click the destination branch and PASTE_NEW.

Expected: a new waypoint appears in the DB with a fresh navMate UUID (byte 1 = 0x82)
different from the E80's UUID. The name is preserved.

---

### §3.6 Delete E80 WP

In the E80 panel, right-click the uploaded waypoint and DELETE_WAYPOINT. Wait for
ProgressDialog FINISHED.

Expected: the waypoint is absent from the E80.

---

### §3.7 Delete E80 Group + members (DEL_GROUP_WPS)

In the E80 panel, right-click the uploaded group and DELETE_GROUP_WPS. Wait for
ProgressDialog FINISHED.

Expected: the group and all its member WPs are absent from the E80.

---

### §3.8 Delete via E80 Groups header (all groups) -- SS8.2 header-node delete

In the E80 panel, right-click the Groups header and DELETE_GROUP_WPS. Wait for
ProgressDialog FINISHED.

Expected: all E80 groups and their member WPs are deleted. This exercises the SS8.2
header-node delete path -- right-clicking the Groups header operates on all groups at once.

---

### §3.9 Delete via E80 Routes header (all routes) -- SS8.2

In the E80 panel, right-click the Routes header and DELETE_ROUTE. Wait for ProgressDialog
FINISHED.

Expected: all E80 routes are deleted. Member WPs are preserved.

---

### §3.10 Delete via E80 My Waypoints (all ungrouped WPs) -- SS8.2

Requires ungrouped WPs present. If the waypoint was deleted in §3.6, re-upload one.
Right-click the My Waypoints node and DELETE_GROUP_WPS. Wait for ProgressDialog FINISHED.

Expected: all ungrouped WPs are deleted. Named groups are unaffected.

---

### §3.11 Delete via E80 Tracks header -- SS8.2

Requires tracks on E80. If teensyBoat is not available, defer to §4 or mark NOT_RUN.
Right-click the Tracks header and DELETE_TRACK. Wait for ProgressDialog FINISHED.

Expected: all E80 tracks are erased. This exercises the fourth SS8.2 header-node delete rule.

---

### §3.12 Copy E80 Group -> Paste to DB (group download)

If §3.7 deleted the group, re-upload the group first. COPY the E80 group. Right-click the
destination branch in the DB panel and PASTE.

Expected: the group and its member WPs are merged into the DB under the destination branch.

---

### §3.13 Copy E80 Route -> Paste to DB (route download)

Re-upload [TestRoute] to the E80 if absent (deleted by §3.9). COPY the E80 route.
Right-click the destination branch and PASTE.

Expected: the route record is inserted or updated in the DB. Member WP UUIDs are
preserved. No new WP records are created (WPs already exist in DB from prior steps).

---

### §3.14 Copy E80 Group+Route -> Paste to DB (E80-source heterogeneous paste, ordering enforced)

E80 must have both the Popa group (with its 11 member WPs) and the Popa route simultaneously.
After §3.12 and §3.13, both are present. Select both the E80 group and the E80 route in the
E80 panel simultaneously. COPY the multi-item selection. Right-click [DST] in the DB panel
and PASTE.

Expected: the paste succeeds. navMate processes non-route items (the group and its member
WPs) first, then processes the route (SS12.1 ordering, I1 fix). The route's route_waypoints
reference WP UUIDs that now exist in the DB (inserted from the group paste or already present
from earlier DB state). Route and group appear in [DST] with UUIDs preserved. No ERROR or
WARNING in the log.

---

### §3.15 Paste New WP to E80 (fresh UUID)

COPY an isolated waypoint from the DB. In the E80 panel, right-click the Groups header and
PASTE_NEW. Wait for ProgressDialog FINISHED.

Expected: a new WP appears on the E80 with a fresh navMate UUID (byte 1 = 0x82) different
from the source WP's UUID. The name is preserved. No conflict-resolution dialog fires (this
is the clean create path; §5.12 verifies this by checking the §3.15 log).

---

### §3.16 Paste New Group to E80 (all-fresh UUIDs)

COPY a group that has no route refs and whose name does not conflict with any group already
on the E80 at this point in the cycle. In the E80 panel, right-click the Groups header and
PASTE_NEW. Wait for ProgressDialog FINISHED.

Expected: a new group appears on the E80 with a fresh UUID. Each member WP has a fresh UUID.
Note: this group remains on E80; §5.6 clears all E80 content before its route-dependency test.

---

### §3.17 Paste New Route to E80 (fresh route UUID, WP refs preserved)

If a same-named route already exists on the E80, delete all E80 routes first (wait for
ProgressDialog FINISHED) to avoid the Step 7 name-collision abort.

COPY the test route from the DB. In the E80 panel, right-click the Routes header and
PASTE_NEW. Wait for ProgressDialog FINISHED.

Expected: a new route appears on the E80 with a fresh navMate UUID (byte 1 = 0x82) different
from the source UUID. The route's member WPs must already exist on the E80 (SS10.10; confirmed
by §3.12). The route_waypoints sequence references those existing WP UUIDs -- no new WP records
are created on the E80 (SS1.6, C3 fix). The route name is preserved.

---

### §3.18 Multi-select WPs -> Paste to E80 (homogeneous flat set)

Select two isolated waypoints simultaneously in the DB panel. COPY the selection. In the
E80 panel, right-click the Groups header and PASTE. Wait for ProgressDialog FINISHED.

Expected: both WPs appear on the E80. Log: COPY with items=2; PASTE with items=2.

---

### §3.19 Route point Paste Before/After on E80 (route sequence insertion)

A route must be on the E80 with at least 3 route_waypoints. After §3.17, the fresh-UUID
route from PASTE_NEW serves as the source. Note three consecutive points as E80_RP1,
E80_RP2, E80_RP3.

COPY E80_RP1. Right-click E80_RP3 and PASTE_BEFORE (insert between RP2 and RP3). Wait for
ProgressDialog FINISHED.

Expected: RP1's WP UUID now appears at a position between RP2 and RP3 in the route's
waypoint sequence. Total count increases by 1. This exercises SS10.9: E80 PASTE_BEFORE/AFTER
is valid only at route point destinations.


## §4 Track Tests (requires teensyBoat session)

Section §4 requires live track recording via teensyBoat (port 9881). Load
boat_driving_guide.md before starting. Skip entirely if teensyBoat is not available;
mark all §4 steps NOT_RUN.

---

### §4.0 Prerequisite -- create test tracks on E80

Drive to create at least two short test tracks. Verify tracks appear in the E80 Tracks
section. Record the E80-assigned UUIDs.

Track creation pattern: AP=0 -> H=NNN -> S=50 -> start track -> drive -> stop track ->
name -> save. Expected non-fatal events: GET_CUR2 ERROR after each EVENT(0); "TRACK OUT
OF BAND" after save. Verify save: "got track(uuid) = 'name'" in log.

**UUID behavior (confirmed):** E80->DB paste for tracks does NOT preserve the E80 UUID.
navMate assigns a fresh UUID. Identify downloaded tracks by name in the DB, not by UUID.
Color conversion: E80 color index maps to aabbggrr -- 0=ff0000ff, 1=ff00ffff, 2=ff00ff00,
3=ffff0000, 4=ffff00ff, 5=ff000000.

---

### §4.1 Copy E80 Track -> Paste to DB (download, track still on E80)

COPY the first E80 track. Right-click the destination branch in the DB panel and PASTE.
Wait for ProgressDialog FINISHED.

Expected: the track appears in the DB with a fresh UUID; track points present. The track
remains on the E80 (COPY, not CUT). Find the downloaded track by name.

---

### §4.2 Cut E80 Track -> Paste to DB (download + E80 erase)

CUT the second E80 track. Right-click the destination branch and PASTE. Wait for
ProgressDialog FINISHED.

Expected: the track appears in the DB with a fresh UUID. TRACK_CMD_ERASE is sent to the
E80; the track is absent from the E80 after erase. This is the end-to-end verification of
the track erase path.

---

### §4.3 Guard -- Paste Track to E80 blocked (tracks read-only)

COPY the test track from the DB (the one moved in §2.12). In the E80 panel, right-click
the Tracks header and PASTE.

Expected: paste rejected per SS10.8 (E80 tracks destination accepts no paste). E80 unchanged.

---

### §4.4 Guard -- Paste New blocked for track clipboard

COPY an E80 track. Right-click the destination branch in the DB panel and PASTE_NEW.

Expected: PASTE_NEW rejected for a track clipboard per SS10.3. DB unchanged.


## §5 Pre-flight and Guard Tests

These verify that blocked operations fail cleanly. The test API fires commands
unconditionally, bypassing menu-level guards -- verify results by reading the log, not by
absence of menu items. All blocked operations should produce WARNING or IMPLEMENTATION
ERROR in the log with no data change.

Tests marked **PREREQUISITE: outcome=reject** require `$suppress_outcome` support; see
[nmOps testability prerequisites] in todo.md. Run the accept-path variant only until the
prerequisite is implemented; mark the reject-path variant NOT_RUN.

---

### §5.1 DEL_WAYPOINT blocked -- WP referenced in route (DB panel)

Select a waypoint that IS referenced in a route. Right-click and DELETE_WAYPOINT.

Expected: WARNING in the log (waypoint referenced in route). The waypoint and its route
references are unchanged.

---

### §5.2 DEL_BRANCH blocked -- member WP in external route (isBranchDeleteSafe=0)

Select a branch whose descendant WPs are referenced by routes OUTSIDE the branch subtree
(isBranchDeleteSafe=0). Right-click and DELETE_BRANCH.

Expected: WARNING in the log; branch unchanged.

---

### §5.3 Paste blocked -- DB cut -> E80 destination (SS9, SS10.5)

CUT an isolated waypoint from the DB panel. In the E80 panel, right-click the Groups
header and PASTE.

Expected: paste rejected. WARNING in the log. E80 unchanged. The cut waypoint remains in
the DB (cut not consumed). DB is the authoritative repository -- uploads to E80 are copies only.

---

### §5.4 Paste blocked -- any clipboard -> E80 tracks header (SS10.8)

COPY a waypoint from the DB. In the E80 panel, right-click the Tracks header and PASTE.

Expected: rejected (E80 tracks destination accepts no paste). E80 unchanged.

---

### §5.5 Paste blocked -- DB copy track -> DB paste (no UUID-preserving copy path)

COPY a track from the DB. Right-click the destination branch and PASTE.

Expected: PASTE rejected per SS10.3 (homogeneous track clipboard, DB source, not a cut:
no PASTE path exists). WARNING or IMPLEMENTATION ERROR in the log. DB unchanged.

---

### §5.6 Route dependency check -- route paste before member WPs exist on E80 (SS10.10)

Clear the E80: delete all routes (wait for ProgressDialog FINISHED), then all groups+WPs
(wait for ProgressDialog FINISHED), then any remaining ungrouped WPs (wait for
ProgressDialog FINISHED). Verify the E80 is empty.

COPY the test route (whose member WPs are absent from the E80 after the clear). In the E80
panel, right-click the Routes header and PASTE.

Expected: pre-flight SS10.10 route dependency check aborts. WARNING in the log listing the
missing WP UUIDs. E80 routes unchanged.
Note: E80 is empty after this step; §5.7 pastes the test group fresh from this clean state.

---

### §5.7 Ancestor-wins -- accept path (SS6.2)

Select a group AND one of its member WPs simultaneously. With suppress=1 (accept default),
ancestor-wins absorbs the member WP into the group upload.
Prerequisite: E80 is empty after §5.6 clear.

COPY the group+member selection. In the E80 panel, right-click the Groups header and
PASTE_NEW. Wait for ProgressDialog FINISHED.

Expected: the group is uploaded as an intact compound object. The selected member WP does
NOT appear as a separate ungrouped WP on the E80; it arrived inside the group. Log:
ancestor-wins resolution noted; confirmation dialog auto-accepted.

---

### §5.8 Ancestor-wins -- abort path (SS6.2) -- PREREQUISITE: outcome=reject

Set outcome=reject. Select a group and one of its member WPs. COPY. PASTE_NEW to the E80
Groups header. Reset outcome to accept after the step.

Expected: the ancestor-wins dialog fires; suppressed with reject outcome; paste does not
proceed; E80 unchanged.

---

### §5.9 Recursive paste guard -- paste Branch into its own descendant (SS1.5, SS10.1 Step 3)

COPY a branch that has at least one child branch. Right-click that child branch and PASTE_NEW.

Expected: the pre-flight SS10.1 Step 3 recursive paste check rejects. WARNING in the log.
DB unchanged.

---

### §5.10 Pre-flight: intra-clipboard name collision (SS10.2 Step 6)

Requires two waypoints with the same name but different UUIDs both in the clipboard.

Setup: check the DB for any two WPs with the same name. If none exist, rename two WPs to
the same name via the UI before this step. Select both and COPY. In the E80 panel,
right-click the Groups header and PASTE_NEW.

Expected: pre-flight SS10.2 Step 6 hard-aborts. WARNING in the log identifying the
colliding name. E80 unchanged.

---

### §5.11 Pre-flight: E80-wide name collision (SS10.2 Step 7)

Upload a waypoint to the E80. Then attempt to paste a different DB waypoint with the same
name.

If no second same-named waypoint exists in the DB, create one via the UI (NEW_WAYPOINT,
same name). COPY the second waypoint. Right-click the E80 Groups header and PASTE.

Expected: pre-flight SS10.2 Step 7 hard-aborts. WARNING in the log identifying the
conflicting name and type. E80 unchanged (second WP not created).

---

### §5.12 Pre-flight: UUID conflict -- clean create path (SS10.10)

Paste a DB WP to the E80 whose UUID does not exist there. This is the normal upload path,
verifying that the clean create branch runs without false conflict detection. Covered by
§3.15 -- no separate operation needed. Verify the §3.15 log shows no conflict-resolution
dialog.

---

### §5.13 Pre-flight: UUID conflict -- conflict dialog path (SS10.10) -- PREREQUISITE: outcome=reject

Upload a WP to the E80. Modify it in the DB so db_version exceeds the E80 version. Paste
again. Pre-flight should detect the UUID conflict and present the conflict resolution dialog.
With outcome=reject, the abort path is taken.

Full setup deferred pending version increment wiring (see [db_version increment wiring] in
todo.md). Mark NOT_RUN until versioning is wired.

---

### §5.14 Menu shape -- DB object node: PASTE and PASTE_NEW absent

With a clipboard loaded, fire PASTE at a DB object node (a waypoint UUID as the right-click
target, not a collection). Fire PASTE_NEW at the same object node.

Expected: both operations produce IMPLEMENTATION ERROR in the log. DB object nodes are not
valid paste-destination containers; only PASTE_BEFORE/AFTER variants are valid at object
nodes. DB unchanged.

Also fire PASTE at a DB route node and at a DB track node with the same loaded clipboard.
Expected: IMPLEMENTATION ERROR in both cases.

---

### §5.15 Menu shape -- E80 WP node: all paste items absent

With a clipboard loaded from the DB, fire PASTE at an individual E80 waypoint node (not a
header node, not a route_point). Fire PASTE_NEW at the same node.

Expected: IMPLEMENTATION ERROR for both. Individual E80 WP nodes are not valid paste
destinations in the E80 panel; paste is only accepted at header nodes (Groups, Routes),
the root node, or route_point nodes. E80 unchanged.

---

### §5.16 Menu shape -- route_point with mixed clipboard: PASTE_BEFORE/AFTER absent

Load a mixed clipboard: select both a route_point and a waypoint (or any other
non-route_point item). Fire PASTE_BEFORE at a route_point anchor.

Expected: IMPLEMENTATION ERROR -- PASTE_BEFORE/AFTER at a route_point requires a pure
route_point clipboard (every item must be obj_type=route_point). The mixed clipboard is
rejected for positional route-sequence operations.

Fire PASTE_NEW_BEFORE at the same route_point anchor with the same mixed clipboard.

Expected: succeeds -- a new route_waypoints entry is inserted before the anchor,
referencing the route_point item's WP UUID. The non-route_point item in the clipboard is
silently filtered (only route_point items are eligible for route-sequence positional paste).


## Recording Results

Each test cycle produces `apps/navMate/docs/notes/last_testrun.md`. See the runbook for
the exact format: header, summary, results table (PASS/FAIL/PARTIAL/PASSED_BUT/NOT_RUN),
and issues section.
