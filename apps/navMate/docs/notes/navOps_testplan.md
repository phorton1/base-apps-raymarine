# navMate -- navOps Test Plan

Test cases for the navOperations feature. For the design specification and pre-flight rules
see navOperations.md (SS1-SS13). For the companion execution script with UUID table and curl
commands see navOps_testplan_runbook.md (in docs/notes/).

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
For DELETE_GROUP and DELETE_GROUP_WPS success paths (Test 2.4, Test 2.5). Two such groups are
required -- Test 2.4 and Test 2.5 each consume their target group and cannot share one.

**Group whose members ARE in a route** -- for DELETE_GROUP_WPS blocked path (Test 2.6) and
E80 route dependency tests.

**Route with at least 3 ordered route_waypoints** -- for PASTE_BEFORE/AFTER route sequence
tests (Tests 2.14a-b, Test 3.18). The runbook pre-resolves the first three points as RP1, RP2, RP3.

**Branch safe for recursive delete** -- no member WP referenced by a route outside the
branch subtree. For DELETE_BRANCH (Test 2.7).

**Collection nodes for positional anchor tests** -- a group node and a branch node are
required as PASTE_BEFORE/AFTER anchor targets (Test 2.16, Test 2.17). Any group and any branch in
the DB qualify; the runbook selects specific nodes.

**Nested branch** -- a branch with at least one child branch. For the recursive paste
guard test (Test 5.9).

**At least one track** -- for DB cut/paste track move (Test 2.12) and E80 track tests (Section 4).

**Name collision setup** -- the baseline DB does not require duplicate-named items.
Collision tests in Test 5.10 and Test 5.11a-5.11b use dynamic setup; see those sections.


## Infrastructure

### Command names

```
COPY  CUT

PASTE  PASTE_NEW  PASTE_BEFORE  PASTE_AFTER  PASTE_NEW_BEFORE  PASTE_NEW_AFTER

DELETE_WAYPOINT  DELETE_GROUP  DELETE_GROUP_WPS
DELETE_ROUTE  REMOVE_ROUTEPOINT  DELETE_TRACK  DELETE_BRANCH

NEW_WAYPOINT  NEW_GROUP  NEW_ROUTE  NEW_BRANCH

PUSH
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
path requires outcome=reject support. See [navOps testability prerequisites] in todo.md.
Tests in Section 5 that require outcome=reject are flagged PREREQUISITE in their headers.

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

### Test execution discipline

Tests must run in the order listed. Do NOT defer a test to a later section or skip ahead
and return to it. If a test cannot run at its scheduled position (pre-condition unmet,
feature unavailable), mark it NOT_RUN and continue from the next test in sequence.
Reordering sections or revisiting deferred steps mid-cycle is prohibited.


## Section 1 Reset to Known State

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


## Section 2 Database Tests (no E80 required)

E80 need not be connected for this section.

---

### Test 2.1 Copy WP -> Paste New (duplicate with fresh UUID)

Select a single waypoint that is not in any group and not referenced in any route. COPY it.
Right-click a destination branch and PASTE_NEW.

Expected: a new waypoint with the same name and attributes appears in the destination with
a fresh UUID different from the source. The source waypoint is unchanged in its original
location.
Log: COPY STARTED/FINISHED, PASTE_NEW STARTED/FINISHED, no errors.

---

### Test 2.2 Cut WP -> Paste (move)

Select a different isolated waypoint (not the one used in Test 2.1). CUT it. Right-click the
destination branch and PASTE.

Expected: the waypoint moves to the destination with its UUID unchanged. It is absent from
its original location.
Log: CUT STARTED/FINISHED, PASTE STARTED/FINISHED, no errors.

---

### Test 2.3 Delete WP (success)

Select a third isolated waypoint (not used in Test 2.1 or Test 2.2). Right-click and DELETE_WAYPOINT.

Expected: the waypoint is deleted. It no longer appears anywhere in the database.
Log: DELETE_WAYPOINT STARTED/FINISHED, no errors.

---

### Test 2.4 Delete Group -- dissolve (members reparented to parent collection)

Select a group whose member WPs are not referenced in any route. This must be a **different
group from the one used in Test 2.5** -- both steps require a group with no route refs, and each
consumes its target group. Right-click and DELETE_GROUP.

Expected: the group shell is deleted. All member WPs are reparented to the group's former
parent branch with their UUIDs unchanged. Any route references to those WPs remain unaffected.
Log: DELETE_GROUP STARTED/FINISHED, no warnings.

---

### Test 2.5 Delete Group+WPS -- success (members not in route)

Select a second group (intact after Test 2.4) whose member WPs are not referenced in any route.
Right-click and DELETE_GROUP_WPS.

Expected: the group shell and all member WPs are deleted. Neither the group nor any of its
former members appear in the database.

---

### Test 2.6 Delete Group+WPS -- blocked (members in route) -- pre-flight failure

Select a group whose member WPs ARE referenced in a route. Right-click and DELETE_GROUP_WPS.

Expected: the operation is blocked by the pre-flight check. WARNING in the log. The group
and all its member WPs are unchanged.
Note: the test API bypasses the menu guard and hits the handler-level sentinel directly;
the IMPLEMENTATION ERROR sentinel in the log is expected behavior for this path.

---

### Test 2.7 Delete Branch (recursive, safe)

Select a branch whose entire descendant tree contains no WP referenced by a route outside
the branch subtree (isBranchDeleteSafe=1). Right-click and DELETE_BRANCH.

Expected: the branch and all descendants are deleted -- sub-collections, member WPs, routes,
route_waypoints, tracks, track_points. Nothing from the branch subtree remains.
Log: DELETE_BRANCH STARTED/FINISHED, no errors.

---

### Test 2.8 Copy Branch -> Paste New (duplicate branch contents, fresh UUIDs)

Select a branch that contains groups and routes. COPY it. Right-click the destination branch
and PASTE_NEW.

Expected: all groups, routes, and WPs from the source branch are duplicated in the
destination with fresh navMate UUIDs. Tracks in the source are silently skipped (PASTE_NEW
is not supported for tracks). The source branch is unchanged.
Log: COPY STARTED/FINISHED, PASTE_NEW STARTED/FINISHED, no errors.

---

### Test 2.9 Cut Branch -> Paste (move branch as a unit)

Select a branch that has groups and tracks (with WPs not in routes). CUT it. Right-click
the destination branch and PASTE.

Expected: the branch node itself moves to the destination with its UUID and all contents
(groups, tracks, WPs) intact inside it. The branch is reparented to the destination; it
does not become empty. This is consistent with how CUT+PASTE works for all other node
types (WPs, groups, routes) -- the node moves as a unit.

---

### Test 2.10 Copy Route -> Paste New (fresh route UUID, WP refs preserved)

Select a route. COPY it. Right-click the destination branch and PASTE_NEW.

Expected: a new route record appears in the destination with a fresh UUID (byte 1 = 0x82).
The route_waypoints sequence is rebuilt referencing the same WP UUIDs as the source -- no new
waypoint records are created (SS1.6, SS12.3). Pre-flight Step 4 confirms all referenced WP
UUIDs exist in the DB. The original route and its member WPs are unchanged.

---

### Test 2.11 Cut Route -> Paste (move route record)

Select the test route. CUT it. Right-click the destination branch and PASTE.

Expected: the route record moves to the destination with its UUID unchanged. The
route_waypoints sequence is unchanged. The route is absent from its original location.
(After this step, the test route UUID is still valid and used in Tests 2.14a-b, 2.15a-b, 2.18a-b, and Section 3.x.)

---

### Test 2.12 Cut Track -> Paste (move track record)

Select a track. CUT it. Right-click the destination branch and PASTE.

Expected: the track moves to the destination with its UUID unchanged. Track points are
unchanged. The track is absent from its original location.
(After this step, the track UUID is still valid and used in Test 4.3 and Test 5.5.)

---

### Test 2.13a Paste New Before -- collection member (positional insertion before sibling)

Copy a waypoint. Right-click a sibling waypoint in the same collection and PASTE_NEW_BEFORE.

Expected: a fresh-UUID copy of the source appears at a position between the sibling's
predecessor and the sibling. Position is a float-valued ordering field; confirm the new
position value falls between the predecessor and sibling values.

---

### Test 2.13b Paste New After -- collection member (positional insertion after sibling)

Copy the same source waypoint. Right-click the same sibling and PASTE_NEW_AFTER.

Expected: another fresh-UUID copy appears at a position after the sibling.

---

### Test 2.14a Copy-splice route point (PASTE_NEW_BEFORE -- insert duplicate reference)

Uses the test route (now in the destination branch after Test 2.11 -- UUID still valid) with
its first three route points RP1, RP2, RP3 in position order.

Copy route point RP1. Right-click route point RP3 and PASTE_NEW_BEFORE (insert before RP3,
between RP2 and RP3).

Expected: RP1's WP UUID appears again in the route at a position between RP2 and RP3. The
underlying waypoint record is unchanged. Total route point count increases by 1.

---

### Test 2.14b Cut-splice route point (PASTE_BEFORE -- reorder without duplicating)

Cut route point RP3. Right-click route point RP2 and PASTE_BEFORE.

Expected: RP3's reference now appears before RP2 in the route sequence. Total count is
unchanged (move, not copy).

---

### Test 2.15a Paste New Before -- route object as anchor

The anchor is a route node (object node, obj_type=route). This exercises the cross-table
neighbor query when the anchor is a route object rather than a waypoint.

COPY an isolated waypoint. Right-click the test route ([TestRoute], now in [DST] after
Test 2.11) as the anchor and PASTE_NEW_BEFORE.

Expected: a fresh-UUID copy of the waypoint appears at a collection position immediately
before [TestRoute] within [DST]'s ordering. The position value falls between the route's
predecessor and the route's own position. [TestRoute] and its route_waypoints are unchanged.

---

### Test 2.15b Paste New After -- route object as anchor

COPY the same isolated waypoint. Right-click [TestRoute] and PASTE_NEW_AFTER.

Expected: another fresh-UUID copy appears at a position immediately after [TestRoute] in
[DST]'s ordering.

---

### Test 2.16 Paste Before/After -- group node as anchor

The anchor is a group node (collection node, node_type=group). This exercises the neighbor
query across the group boundary.

COPY an isolated waypoint. Right-click a group node as anchor and PASTE_NEW_BEFORE.

Expected: a fresh-UUID copy of the waypoint appears at a position immediately before the
group in the group's parent collection ordering. The group's membership is unchanged; the
new WP is a sibling of the group in the parent collection, not a member.

---

### Test 2.17 Paste Before/After -- branch node as anchor

The anchor is a branch node (collection node, node_type=branch). This exercises the neighbor
query at a branch boundary.

COPY an isolated waypoint. Right-click a branch node as anchor and PASTE_NEW_BEFORE.

Expected: a fresh-UUID copy of the waypoint appears at a position immediately before the
branch in the branch's parent collection ordering. The branch's contents are unchanged.

---

### Test 2.18a Paste New Before -- route in clipboard

COPY [TestRoute] (still in [DST] after Test 2.11). Right-click a sibling waypoint anchor
in [DST] and PASTE_NEW_BEFORE.

Expected: a fresh-UUID copy of the route appears at a position before the anchor in [DST]'s
ordering. The new route record has a fresh UUID; its route_waypoints reference the same WP
UUIDs as the source (SS1.6). No new waypoint records are created.

---

### Test 2.18b Paste New Before -- group in clipboard

COPY a group (one with no route refs so pre-flight Step 4 passes trivially). Right-click
the same or a different waypoint anchor in [DST] and PASTE_NEW_BEFORE.

Expected: a fresh-UUID copy of the group (with fresh UUIDs for the group shell and all member
WPs) appears before the anchor. The source group and its members are unchanged.


## Section 3 E80 Tests (upload/download)

E80 must be connected and empty after Section 1 reset.

**State note entering Section 3:** the test route (UUID unchanged from Test 2.11) is in the destination
branch. The group containing the test route's member WPs is intact (Test 2.6 was blocked).

**Test 3.1-Test 3.3 dual role:** Test 3.1, Test 3.2, and Test 3.3 each populate the E80 with data that later
tests in Section 3 depend on, but they are also actual tests in their own right -- each exercises
a distinct UUID-preserving DB-to-E80 paste path (single WP, group, route). All three must
pass before proceeding; a failure in any one affects the validity of later tests.

---

### Test 3.1 Paste WP to E80 (UUID-preserving upload)

COPY an isolated waypoint from the DB. In the E80 panel, right-click the Groups header and
PASTE. Wait for ProgressDialog FINISHED. Note the E80 UUID (should equal the DB UUID).

Expected: waypoint appears on E80 as an ungrouped WP with the same UUID as in the DB.

---

### Test 3.2 Paste Group to E80 (UUID-preserving upload)

COPY a group whose member WPs are also members of the test route. In the E80 panel,
right-click the Groups header and PASTE. Wait for ProgressDialog FINISHED. Note the E80
group UUID.

Expected: group appears on E80 with the same UUID as in the DB; all member WPs appear as
members of that group, each with their DB UUIDs preserved.

---

### Test 3.3 Paste Route to E80 (UUID-preserving upload)

COPY the test route. In the E80 panel, right-click the Routes header and PASTE. The route's
member WPs must already be on the E80 (Test 3.2 put them there; SS10.10 pre-flight verifies
this). Wait for ProgressDialog FINISHED. Note the E80 route UUID.

Expected: route appears on E80 with the same UUID as in the DB; its route_waypoints sequence
matches the DB ordering (same WP UUIDs, same positional order).

---

### Test 3.4 Copy E80 WP -> Push to DB (push-classified: UUID present in DB)

At COPY time from an E80 source, `_classifyE80Items` checks each item UUID against the
navMate DB. After Test 3.1 uploads [IsolatedWP1] to E80, [E80_WP] UUID equals [IsolatedWP1]'s
UUID -- which already exists in DB. This gives clipboard_class='push'.

In the E80 panel, COPY [E80_WP]. Right-click [DST] in the DB panel. The context menu shows
PUSH (not PASTE) because the clipboard is push-classified from an E80 source. Execute PUSH.

Expected: `_pushFromE80` updates the [IsolatedWP1] DB record from E80 field values (name,
lat, lon, comment, depth_cm). DB-managed fields (wp_type, color, source) are preserved from
the existing record. The WP's collection_uuid (tree location) is unchanged. Clipboard is
cleared after PUSH completes.
Log: PUSH STARTED/FINISHED, no errors.

---

### Test 3.5 Copy E80 WP -> Paste New to DB (fresh UUID)

COPY the same E80 waypoint. Right-click the destination branch and PASTE_NEW.

Expected: a new waypoint appears in the DB with a fresh navMate UUID (byte 1 = 0x82)
different from the E80's UUID. The name is preserved.

---

### Test 3.6 Delete E80 WP

In the E80 panel, right-click the uploaded waypoint and DELETE_WAYPOINT. Wait for
ProgressDialog FINISHED.

Expected: the waypoint is absent from the E80.

---

### Test 3.6b Delete E80 Group+WPS -- blocked (member in route)

After Test 3.3, [E80_GR] (Popa group) has members that are also waypoints in [E80_RT] (Popa
route). Right-click [E80_GR] and DELETE_GROUP_WPS.

Expected: the operation is blocked. With suppress on (test API): an ERROR appears in the
log explaining that route references must be resolved first. With suppress off (UI): an
error dialog appears with the same message. Either way, E80 state is unchanged -- [E80_GR]
and all its member waypoints are still present, and [E80_RT] is unaffected.
No IMPLEMENTATION ERROR in the log.
Note: DELETE_GROUP_WPS is always offered in the menu regardless of route membership; the
block is enforced at handler level (SS8.2).

---

### Test 3.7 Delete via E80 Routes header (all routes) -- SS8.2

In the E80 panel, right-click the Routes header and DELETE_ROUTE. Wait for ProgressDialog
FINISHED.

Expected: all E80 routes are deleted. Member WPs are preserved.
Note: routes must be deleted before any group delete -- the member-in-route guard blocks
group deletes while route_waypoints reference group members.

---

### Test 3.8 Delete via E80 Groups header (all groups) -- SS8.2 header-node delete

In the E80 panel, right-click the Groups header and DELETE_GROUP_WPS. Wait for
ProgressDialog FINISHED.

Expected: all E80 groups and their member WPs are deleted. This exercises the SS8.2
header-node delete path -- right-clicking the Groups header operates on all groups at once.

---

### Test 3.9a Re-upload Popa group (setup for Test 3.9b)

Test 3.8 deleted all groups. Re-upload the Popa group to the E80. Wait for ProgressDialog FINISHED.

Expected: the Popa group and its member WPs are present on the E80.

---

### Test 3.9b Delete E80 group + members via specific group node (DEL_GROUP_WPS)

Right-click the uploaded Popa group node and DELETE_GROUP_WPS. Wait for ProgressDialog FINISHED.

Expected: the group and all its member WPs are absent from the E80.

---

### Test 3.10a Re-upload isolated WP if absent (setup for Test 3.10b)

If the waypoint was deleted in Test 3.6, re-upload one isolated WP to the E80. Wait for
ProgressDialog FINISHED if re-uploaded.

Expected: at least one ungrouped WP is present on the E80.

---

### Test 3.10b Delete all ungrouped WPs via My Waypoints node -- SS8.2

Right-click the My Waypoints node and DELETE_GROUP_WPS. Wait for ProgressDialog FINISHED.

Expected: all ungrouped WPs are deleted. Named groups are unaffected.

---

### Test 3.11a Re-upload Popa group if absent (setup for Test 3.11b)

If Test 3.9b deleted [E80_GR], re-upload the Popa group to the E80. Wait for ProgressDialog FINISHED.

Expected: the Popa group and its member WPs are present on the E80.

---

### Test 3.11b Copy E80 Group -> Push to DB (group push-classified)

COPY [E80_GR]. The Popa group UUID exists in DB -> clipboard_class='push'. Right-click [DST]
in the DB panel: PUSH is offered (not PASTE). Execute PUSH.

Expected: `_pushFromE80` updates the Popa group record (name) and all 11 member WPs
(name, lat, lon, comment, depth_cm) from E80 field values. DB-managed fields (wp_type,
color, source) for each WP are preserved. Collection memberships are unchanged.
Log: PUSH STARTED/FINISHED, no errors. Clipboard cleared.

---

### Test 3.12a Re-upload test route if absent (setup for Test 3.12b)

Re-upload [TestRoute] to E80 if absent (deleted by Test 3.7). Wait for ProgressDialog FINISHED.

Expected: [E80_RT] is present on the E80.

---

### Test 3.12b Copy E80 Route -> Push to DB (route push-classified)

COPY [E80_RT]. The Popa route UUID (f34efdd6070022e8) exists in DB -> clipboard_class='push'.
Right-click [DST] in the DB panel: PUSH is offered (not PASTE). Execute PUSH.

Expected: `_pushFromE80` updates the route name/color/comment from E80 and rebuilds
route_waypoints to match the E80 sequence. Member WP UUIDs are preserved; no new WP records
created. Route's collection_uuid (tree location) unchanged.
Log: PUSH STARTED/FINISHED, no errors. Clipboard cleared.

---

### Test 3.13 Copy E80 Group+Route -> Push to DB (multi-item push)

After Test 3.11b and Test 3.12b, E80 has both [E80_GR] (Popa group + 11 WPs) and [E80_RT] (Popa route).
Both UUIDs exist in DB -> clipboard_class='push' for the multi-item selection. Select both
simultaneously. COPY. Right-click [DST]: PUSH is offered. Execute PUSH.

Expected: `_pushFromE80` processes both items -- group (name + member WP fields) and route
(name/color/comment + route_waypoints sequence). All WP UUIDs remain unchanged in DB. No new
records created. Clipboard cleared.
Log: PUSH STARTED/FINISHED, no errors.
Note: SS12.1 item-ordering (groups before routes) is enforced in the paste path only. The push
path updates existing records and does not require ordered processing.

---

### Test 3.14 Paste New WP to E80 (fresh UUID)

COPY an isolated waypoint from the DB. In the E80 panel, right-click the Groups header and
PASTE_NEW. Wait for ProgressDialog FINISHED.

Expected: a new WP appears on the E80 with a fresh navMate UUID (byte 1 = 0x82) different
from the source WP's UUID. The name is preserved. No conflict-resolution dialog fires (this
is the clean create path; Test 5.12 verifies this by checking the Test 3.14 log).

---

### Test 3.14b Copy E80 fresh-UUID WP -> Paste to DB (paste-classified: UUID absent)

After Test 3.14, the E80 has a WP with a fresh navMate UUID (byte 1 = 0x82) that is NOT in the
navMate DB. COPY that WP. At copy time, clipboard_class='paste' (UUID absent from DB). Right-
click [DST] in the DB panel: PASTE is offered (not PUSH, because the UUID is absent). Execute
PASTE.

Expected: a new WP record is inserted in [DST] with the E80's fresh UUID preserved (byte 1 =
0x82). Name is preserved from E80. No existing DB record is affected.
Log: COPY STARTED/FINISHED, PASTE STARTED/FINISHED, no errors.

This exercises the paste-classified branch of E80->DB download (absent UUID -> insert). For the
push-classified branch (present UUID -> push-down), see Test 3.4.

---

### Test 3.14c Mixed-classified E80 clipboard: status bar and PASTE_NEW

The mixed-classified case requires two E80 WPs: one with UUID present in DB (push-classified)
and one with UUID absent (paste-classified). After Test 3.14b: [E80_FRESH_WP] is still on E80
and its UUID is now in DB (Test 3.14b pasted it there) -- it is push-classified. A second WP
must be created on E80 via PASTE_NEW from DB to obtain [E80_FRESH_WP2] -- a new fresh UUID that
is not in DB, making it paste-classified.

Setup: PASTE_NEW an isolated DB waypoint to E80 to create [E80_FRESH_WP2]. Derive its UUID from
/api/db. Then select both [E80_FRESH_WP] (push-classified) and [E80_FRESH_WP2] (paste-classified)
in the E80 panel. COPY. At copy time, clipboard_class='mixed' (some present, some absent). Verify
the status bar shows:
"[e80] copy (2) -- Paste/Push not available: clipboard contains both new and existing items --
use Paste New"

Right-click [DST] in the DB panel: PASTE_NEW is offered; PASTE and PUSH are absent from the
menu (verified visually -- test API bypasses menu). Execute PASTE_NEW.

Expected: both WPs inserted in [DST] with fresh navMate UUIDs (PASTE_NEW always assigns fresh
UUIDs regardless of classification). Two new WP records in [DST].

---

### Test 3.15 Paste New Group to E80 (all-fresh UUIDs)

COPY a group that has no route refs and whose name does not conflict with any group already
on the E80 at this point in the cycle. In the E80 panel, right-click the Groups header and
PASTE_NEW. Wait for ProgressDialog FINISHED.

Expected: a new group appears on the E80 with a fresh UUID. Each member WP has a fresh UUID.
Note: this group remains on E80; Tests 5.6a-5.6c clear all E80 content before the route-dependency test.

---

### Test 3.16a Delete E80 routes if same-named route present (setup for Test 3.16b)

If a same-named route already exists on the E80, delete all E80 routes. Wait for
ProgressDialog FINISHED. Skip (NOT_RUN) if no route name conflict.

Expected: no same-named route on E80 that would block Test 3.16b.

---

### Test 3.16b Paste New Route to E80 (fresh route UUID, WP refs preserved)

COPY the test route from the DB. In the E80 panel, right-click the Routes header and
PASTE_NEW. Wait for ProgressDialog FINISHED.

Expected: a new route appears on the E80 with a fresh navMate UUID (byte 1 = 0x82) different
from the source UUID. The route's member WPs must already exist on the E80 (SS10.10; confirmed
by Test 3.11a). The route_waypoints sequence references those existing WP UUIDs -- no new WP records
are created on the E80 (SS1.6, C3 fix). The route name is preserved.

---

### Test 3.17 Multi-select WPs -> Paste to E80 (homogeneous flat set)

Select two isolated waypoints simultaneously in the DB panel. COPY the selection. In the
E80 panel, right-click the Groups header and PASTE. Wait for ProgressDialog FINISHED.

Expected: both WPs appear on the E80. Log: COPY with items=2; PASTE with items=2.

---

### Test 3.18 Route point Paste Before/After on E80 (route sequence insertion)

A route must be on the E80 with at least 3 route_waypoints. After Test 3.16b, the fresh-UUID
route from PASTE_NEW serves as the source. Note three consecutive points as E80_RP1,
E80_RP2, E80_RP3.

COPY E80_RP1. Right-click E80_RP3 and PASTE_BEFORE (insert between RP2 and RP3). Wait for
ProgressDialog FINISHED.

Expected: RP1's WP UUID now appears at a position between RP2 and RP3 in the route's
waypoint sequence. Total count increases by 1. This exercises SS10.9: E80 PASTE_BEFORE/AFTER
is valid only at route point destinations.


## Section 4 Track Tests (requires teensyBoat session)

Section Section 4 requires live track recording via teensyBoat (port 9881). Load
boat_driving_guide.md before starting. Skip entirely if teensyBoat is not available;
mark all Section 4 steps NOT_RUN.

---

### Test 4.0 Prerequisite -- create test tracks on E80

Drive to create at least two short test tracks. Verify tracks appear in the E80 Tracks
section. Record the E80-assigned UUIDs.

Track creation pattern: AP=0 -> H=NNN -> S=50 -> start track -> drive -> stop track ->
name -> save. Expected non-fatal events: GET_CUR2 ERROR after each EVENT(0); "TRACK OUT
OF BAND" after save. Verify save: "got track(uuid) = 'name'" in log.

**UUID behavior:** PASTE from E80 preserves the E80-assigned UUID (byte 1 = B2); identify
by UUID in /api/nmdb. PASTE_NEW assigns a fresh navMate UUID (byte 1 = 0x82); identify by name.
Color conversion: E80 color index maps to aabbggrr -- 0=ff0000ff, 1=ff00ffff, 2=ff00ff00,
3=ffff0000, 4=ffff00ff, 5=ff000000.

---

### Test 4.1 Copy E80 Track -> Paste to DB (download, track still on E80)

COPY the first E80 track. Right-click the destination branch in the DB panel and PASTE.
Wait for ProgressDialog FINISHED.

Expected: the track appears in the DB with the E80's UUID preserved (byte 1 = B2); track
points present. The track remains on the E80 (COPY, not CUT). Identify by UUID in /api/nmdb.

---

### Test 4.2 Cut E80 Track -> Paste to DB (download + E80 erase)

CUT the second E80 track. Right-click the destination branch and PASTE. Wait for
ProgressDialog FINISHED.

Expected: the track appears in the DB with the E80's UUID preserved (byte 1 = B2).
TRACK_CMD_ERASE is sent to the E80; the track is absent from the E80 after erase. This is
the end-to-end verification of the track erase path. Identify by UUID in /api/nmdb.

---

### Test 4.3 Guard -- Paste Track to E80 blocked (tracks read-only)

COPY the test track from the DB (the one moved in Test 2.12). In the E80 panel, right-click
the Tracks header and PASTE.

Expected: paste rejected per SS10.8 (E80 tracks destination accepts no paste). E80 unchanged.

---

### Test 4.4 Paste New E80 Track to DB (download, fresh UUID)

COPY an E80 track (e.g., [E80_TK1]). Right-click the destination branch in the DB panel
and PASTE_NEW.

Expected: PASTE_NEW succeeds. The track appears in DB with a fresh navMate UUID; track points
are present. The SS10.3 restriction (DB-to-DB track UUID-preserving copy) does not apply to
E80-to-DB PASTE_NEW. Track remains on E80 (COPY, not CUT).
Log: PASTE_NEW STARTED/FINISHED, no errors.
Note: the SS10.3 guard (UUID-preserving DB-to-DB track copy blocked) is still tested in Test 5.5.

---

### Test 4.5 Delete via E80 Tracks header -- SS8.2

Requires tracks on E80. [E80_TK1] remains on E80 after Test 4.4 (COPY, not CUT). Right-click
the Tracks header and DELETE_TRACK. Wait for ProgressDialog FINISHED.

Expected: all E80 tracks are erased. This exercises the fourth SS8.2 header-node delete rule.


## Section 5 Pre-flight and Guard Tests

These verify that blocked operations fail cleanly. The test API fires commands
unconditionally, bypassing menu-level guards -- verify results by reading the log, not by
absence of menu items. All blocked operations should produce WARNING or IMPLEMENTATION
ERROR in the log with no data change.

Tests marked **PREREQUISITE: outcome=reject** require `$suppress_outcome` support; see
[navOps testability prerequisites] in todo.md. Run the accept-path variant only until the
prerequisite is implemented; mark the reject-path variant NOT_RUN.

---

### Test 5.1 DEL_WAYPOINT blocked -- WP referenced in route (DB panel)

Select a waypoint that IS referenced in a route. Right-click and DELETE_WAYPOINT.

Expected: WARNING in the log (waypoint referenced in route). The waypoint and its route
references are unchanged.

---

### Test 5.2 DEL_BRANCH blocked -- member WP in external route (isBranchDeleteSafe=0)

Select a branch whose descendant WPs are referenced by routes OUTSIDE the branch subtree
(isBranchDeleteSafe=0). Right-click and DELETE_BRANCH.

Expected: WARNING in the log; branch unchanged.

---

### Test 5.3 Paste blocked -- DB cut -> E80 destination (SS9, SS10.5)

CUT an isolated waypoint from the DB panel. In the E80 panel, right-click the Groups
header and PASTE.

Expected: paste rejected. WARNING in the log. E80 unchanged. The cut waypoint remains in
the DB (cut not consumed). DB is the authoritative repository -- uploads to E80 are copies only.

---

### Test 5.4a Delete BOCAS1 from E80 if present (setup for Test 5.4c)

If a waypoint named BOCAS1 (left over from Test 3.17) is present on the E80, delete it.
Wait for ProgressDialog FINISHED. Skip (NOT_RUN) if BOCAS1 not on E80.

Expected: BOCAS1 absent from E80.

---

### Test 5.4b Delete BOCAS2 from E80 if present (setup for Test 5.4c)

If a waypoint named BOCAS2 (may have a fresh UUID from Test 3.14) is present on the E80,
delete it. Wait for ProgressDialog FINISHED. Skip (NOT_RUN) if BOCAS2 not on E80.

Expected: BOCAS2 absent from E80.

---

### Test 5.4c Paste blocked -- any clipboard -> E80 tracks header (SS10.8)

Prerequisite: BOCAS1 and BOCAS2 absent from E80 (Tests 5.4a-5.4b). If either remains,
the E80-wide name collision guard fires before SS10.8 and the test does NOT verify SS10.8.

COPY a waypoint from the DB. In the E80 panel, right-click the Tracks header and PASTE.

Expected: rejected (E80 tracks destination accepts no paste). E80 unchanged.

---

### Test 5.5 Paste blocked -- DB copy track -> DB paste (no UUID-preserving copy path)

COPY a track from the DB. Right-click the destination branch and PASTE.

Expected: PASTE rejected per SS10.3 (homogeneous track clipboard, DB source, not a cut:
no PASTE path exists). WARNING or IMPLEMENTATION ERROR in the log. DB unchanged.

---

### Test 5.6a Delete all E80 routes (clear before route-dependency test)

Right-click the E80 Routes header and DELETE_ROUTE. Wait for ProgressDialog FINISHED.

Expected: no routes on E80.

---

### Test 5.6b Delete all E80 groups+WPs

Right-click the E80 Groups header and DELETE_GROUP_WPS. Wait for ProgressDialog FINISHED.

Expected: no groups or member WPs on E80.

---

### Test 5.6c Delete all E80 ungrouped WPs (no-op if none)

Right-click the My Waypoints node and DELETE_GROUP_WPS. Wait for ProgressDialog FINISHED.
Verify E80 is completely empty (no waypoints, groups, routes, or tracks).

Expected: E80 is empty.

---

### Test 5.6d Route dependency check -- paste route before member WPs exist on E80 (SS10.10)

Prerequisite: Tests 5.6a-5.6c have cleared E80 completely. COPY the test route (whose
member WPs are now absent from the E80). In the E80 panel, right-click the Routes header
and PASTE.

Expected: pre-flight SS10.10 route dependency check aborts. WARNING in the log listing the
missing WP UUIDs. E80 routes unchanged.
Note: E80 is empty entering Test 5.7; Test 5.7 pastes the test group fresh from this clean state.

---

### Test 5.7 Ancestor-wins -- accept path (SS6.2)

Select a group AND one of its member WPs simultaneously. With suppress=1 (accept default),
ancestor-wins absorbs the member WP into the group upload.
Prerequisite: E80 is empty after Tests 5.6a-5.6c clear.

COPY the group+member selection. In the E80 panel, right-click the Groups header and
PASTE_NEW. Wait for ProgressDialog FINISHED.

Expected: the group is uploaded as an intact compound object. The selected member WP does
NOT appear as a separate ungrouped WP on the E80; it arrived inside the group. Log:
ancestor-wins resolution noted; confirmation dialog auto-accepted.

---

### Test 5.8 Ancestor-wins -- abort path (SS6.2) -- PREREQUISITE: outcome=reject

Set outcome=reject. Select a group and one of its member WPs. COPY. PASTE_NEW to the E80
Groups header. Reset outcome to accept after the step.

Expected: the ancestor-wins dialog fires; suppressed with reject outcome; paste does not
proceed; E80 unchanged.

---

### Test 5.9 Recursive paste guard -- paste Branch into its own descendant (SS1.5, SS10.1 Step 3)

COPY a branch that has at least one child branch. Right-click that child branch and PASTE_NEW.

Expected: the pre-flight SS10.1 Step 3 recursive paste check rejects. WARNING in the log.
DB unchanged.

---

### Test 5.10 Pre-flight: intra-clipboard name collision (SS10.2 Step 6)

Requires two waypoints with the same name but different UUIDs both in the clipboard.

Setup: check the DB for any two WPs with the same name. If none exist, rename two WPs to
the same name via the UI before this step. Select both and COPY. In the E80 panel,
right-click the Groups header and PASTE_NEW.

Expected: pre-flight SS10.2 Step 6 hard-aborts. WARNING in the log identifying the
colliding name. E80 unchanged.

---

### Test 5.11a Upload IsolatedWP1 to E80 (setup: put BOCAS1 on E80 for name collision test)

Upload [IsolatedWP1] (BOCAS1) to the E80 Groups header via PASTE. Wait for ProgressDialog FINISHED.

Expected: [IsolatedWP1] (BOCAS1) is present on the E80.

---

### Test 5.11b Pre-flight: E80-wide name collision (SS10.2 Step 7)

If no second DB waypoint with the same name (BOCAS1) exists, create one via the UI
(NEW_WAYPOINT, same name). COPY the second same-named waypoint. Right-click the E80
Groups header and PASTE.

Expected: pre-flight SS10.2 Step 7 hard-aborts. WARNING in the log identifying the
conflicting name and type. E80 unchanged (second WP not created).

---

### Test 5.12 Pre-flight: UUID conflict -- clean create path (SS10.10)

Paste a DB WP to the E80 whose UUID does not exist there. This is the normal upload path,
verifying that the clean create branch runs without false conflict detection. Covered by
Test 3.14 -- no separate operation needed. Verify the Test 3.14 log shows no conflict-resolution
dialog.

---

### Test 5.13 Pre-flight: UUID conflict -- conflict dialog path (SS10.10) -- PREREQUISITE: outcome=reject

Upload a WP to the E80. Modify it in the DB so db_version exceeds the E80 version. Paste
again. Pre-flight should detect the UUID conflict and present the conflict resolution dialog.
With outcome=reject, the abort path is taken.

Full setup deferred pending version increment wiring (see [db_version increment wiring] in
todo.md). Mark NOT_RUN until versioning is wired.

---

### Test 5.14a Menu shape -- PASTE at DB WP object node blocked

With a clipboard loaded, fire PASTE at a DB object node (a waypoint UUID as the right-click
target, not a collection).

Expected: IMPLEMENTATION ERROR in the log. DB object nodes are not valid paste-destination
containers; only PASTE_BEFORE/AFTER variants are valid at object nodes. DB unchanged.

---

### Test 5.14b Menu shape -- PASTE_NEW at DB WP object node blocked

Fire PASTE_NEW at the same DB WP object node.

Expected: IMPLEMENTATION ERROR in the log. DB unchanged.

---

### Test 5.14c Menu shape -- PASTE at DB route object node blocked

Fire PASTE at a DB route node with the same loaded clipboard.

Expected: IMPLEMENTATION ERROR in the log. DB unchanged.

---

### Test 5.14d Menu shape -- PASTE at DB track object node blocked

Fire PASTE at a DB track node with the same loaded clipboard.

Expected: IMPLEMENTATION ERROR in the log. DB unchanged.

---

### Test 5.15a Upload IsolatedWP1 to E80 if absent (setup for Tests 5.15b-5.15c)

If E80 is empty after Test 5.7, upload [IsolatedWP1] to the E80 Groups header via PASTE.
Wait for ProgressDialog FINISHED. Skip (NOT_RUN) if E80 already has a WP.

Expected: at least one WP present on E80 (note UUID as [E80_WP]).

---

### Test 5.15b Menu shape -- PASTE at E80 WP object node blocked

With a clipboard loaded from the DB, fire PASTE at the individual E80 WP node ([E80_WP]).

Expected: IMPLEMENTATION ERROR. Individual E80 WP nodes are not valid paste destinations;
paste is accepted only at header nodes (Groups, Routes), my_waypoints, group nodes, route
nodes, and route_point nodes. Guard in `_pasteE80`. E80 unchanged.

---

### Test 5.15c Menu shape -- PASTE_NEW at E80 WP object node blocked

Fire PASTE_NEW at the same E80 WP node ([E80_WP]).

Expected: IMPLEMENTATION ERROR. E80 unchanged.

---

### Test 5.16a Mixed clipboard PASTE_BEFORE at route_point (SS6.4 accepted case)

"Mixed" here means the clipboard contains both route_point AND waypoint items. Per SS6.4
this is the one accepted heterogeneous case at a route_point destination.

Load a mixed clipboard: select both a route_point and a waypoint. Fire PASTE_BEFORE at a
route_point anchor.

Expected: succeeds. All clipboard items (both route_point and waypoint) are inserted as
route_waypoints entries before the anchor using their WP UUIDs. Route count increases by
clipboard item count. No IMPLEMENTATION ERROR in log.

---

### Test 5.16b Mixed clipboard PASTE_NEW_BEFORE at route_point (SS6.4 accepted case)

Fire PASTE_NEW_BEFORE at the same route_point anchor with the same mixed clipboard.

Expected: succeeds. All clipboard items (route_point and waypoint) are inserted as
route_waypoints entries before the anchor using their existing WP UUIDs. No new waypoint
records created. Route count increases by clipboard item count.


## Recording Results

Each test cycle produces `apps/navMate/docs/notes/last_testrun.md`. See the runbook for
the exact format: header, summary, results table (PASS/FAIL/PARTIAL/PASSED_BUT/NOT_RUN),
and issues section.
