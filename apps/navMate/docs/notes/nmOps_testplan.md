# navMate -- nmOps Test Plan

Test cases for the nmOperations feature. For the design specification and pre-flight rules
see nmOperations.md (SS1-SS13). For the concrete UUID table and exact curl commands see
the companion nmOps_runbook.md (Claude-facing; written separately).

This plan uses [Name] notation throughout. All [Name] references are resolved in the
runbook UUID table. CTX_CMD constants are listed in §Infrastructure below.

**NEW_* commands are excluded from automation.** NEW_WAYPOINT (10510), NEW_GROUP (10520),
NEW_ROUTE (10530), and NEW_BRANCH (10550) open name-input dialogs that block the test
machinery.


## Database Shape Requirements

The baseline navMate.db must have the following structural shape. The runbook UUID table
selects specific named nodes to satisfy all requirements. Do not change the baseline DB
without updating the runbook.

**Isolated waypoints** -- at least three waypoints not in any group and not referenced in
any route. For clean copy/paste/delete without pre-flight side effects.

**WP referenced in a route** -- at least one waypoint that IS in a route. For the
DEL_WAYPOINT blocked path (SS8.1) and route dependency pre-flight (SS10.10).

**Group with no route refs** -- a group whose member WPs are not referenced by any route.
For DELETE_GROUP_WPS success path (§2.5).

**Group whose members ARE in a route** -- for DELETE_GROUP_WPS blocked path (§2.6) and
E80 route dependency tests.

**Route with at least 3 ordered route_waypoints** -- for PASTE_BEFORE/AFTER route sequence
tests (§2.14, §3.16). The runbook derives [RP1], [RP2], [RP3] from /api/nmdb at reset time.

**Branch safe for recursive delete** -- no member WP referenced by a route outside the
branch subtree. For DELETE_BRANCH (§2.7).

**Branch containing groups whose WPs are also route members** -- for the all-paste E80
ordering dependency test (§3.11). Groups upload first; routes then find WPs already present.

**Nested branch** -- a branch with at least one child branch. For the recursive paste
guard test (§5.9).

**At least one track** -- for DB cut/paste track move (§2.12) and E80 track tests (§4).

**Name collision setup** -- the baseline DB does not require duplicate-named items.
Collision tests in §5.10 and §5.11 use dynamic setup; see those sections.


## Infrastructure

### HTTP endpoints (port 9883)

| Endpoint | Key params | Returns |
|----------|-----------|---------|
| GET /api/log?since=SEQ | since= seq | {lines:[{seq,text},...], last_seq:N} |
| GET /api/command?cmd=mark | -- | marks log; response includes {seq:N} |
| GET /api/command?cmd=dialog_state | -- | logs "dialog_state: active" or "idle" |
| GET /api/command?cmd=close_dialog | -- | force-closes any hung ProgressDialog |
| GET /api/test?op=suppress&val=1 | val=0 to disable | auto-suppress all dialogs |
| GET /api/test?op=suppress&val=1&outcome=reject | -- | suppress with reject outcome (see below) |
| GET /api/test?op=refresh | -- | reloads navMate.db from disk |
| GET /api/test?panel=P&select=K&cmd=N | right_click=K optional | fires context-menu command |
| GET /api/nmdb | -- | navMate DB -- arrays: waypoints, collections, routes, route_waypoints, tracks |
| GET /api/db | -- | E80 live state -- hashes keyed by UUID: waypoints, groups, routes, tracks |

Base URL: http://localhost:9883 (port 9882 not accessible from Claude).

### Node key format

| Node type | Key |
|-----------|-----|
| Waypoint, route, track, group, branch | UUID string |
| Route point | rp:ROUTE_UUID:WP_UUID |
| E80 header nodes | header:groups, header:routes, header:tracks |
| E80 My Waypoints | my_waypoints (no header: prefix) |
| DB or E80 root | root |

DB tree uses lazy loading. A node inside a collapsed branch cannot be selected
programmatically until expanded in the UI.

### CTX_CMD constants

```
COPY = 10010    CUT = 10110

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

NEW_WAYPOINT = 10510   NEW_GROUP  = 10520
NEW_ROUTE    = 10530   NEW_BRANCH = 10550
```

COPY (10010) and CUT (10110) are unified commands. The selection set determines clipboard
contents; pre-flight at paste time classifies the items. The old per-type constants from
context_menu.md (COPY_WAYPOINT=10010, COPY_WAYPOINTS=10011, COPY_GROUP=10020, etc.) no
longer exist. PASTE_BEFORE/AFTER (10302-10305) are new constants with no predecessor.

### Suppress mechanism

`nmDialogs.pm` exports `$suppress_confirm`. When set to 1, all modal dialogs
(confirmation, warning, error, ancestor-wins, conflict resolution) auto-accept their
default response without blocking.

```
# Enable:
curl -s "http://localhost:9883/api/test?op=suppress&val=1"

# Disable:
curl -s "http://localhost:9883/api/test?op=suppress&val=0"
```

**Outcome control (two-outcome dialogs).** Some pre-flight paths produce dialogs with two
meaningful outcomes -- ancestor-wins (proceed vs. abort), UUID conflict (skip+continue vs.
abort), E80 DEL-WP with route-ref warning (proceed vs. abort). Testing the non-default
path requires `outcome=reject` support. See [nmOps testability prerequisites] in todo.md.
Tests in §5 that require outcome=reject are flagged PREREQUISITE in their headers.

For all other tests in this plan, suppress=1 with default accept behavior is assumed.

### Progress dialog pattern

Any Paste-to-E80 or Delete-from-E80 operation opens a ProgressDialog asynchronously.
The onIdle dispatch guard prevents the next /api/test command from firing while the
dialog is active. Always wait for idle before dispatching the next step.

```powershell
for ($i = 1; $i -le 20; $i++) {
    $result = curl -s "http://localhost:9883/api/command?cmd=dialog_state"
    $log    = curl -s "http://localhost:9883/api/log?since=$mark"
    if ($log -match "dialog_state: idle") { break }
    Start-Sleep 1
}
if ($i -gt 20) {
    [console]::beep(800, 200)
    # Inspect screen; if stuck: curl -s "http://localhost:9883/api/command?cmd=close_dialog"
}
```

Every E80 step must confirm `ProgressDialog '...' FINISHED` in the log before proceeding.
A STARTED without a FINISHED is at minimum a PARTIAL failure; a hung dialog that cannot
be closed is catastrophic.

### Log reading

```
curl -s "http://localhost:9883/api/log?since=SEQ" | perl -e "use JSON; my $d=decode_json(do{local$/;<STDIN>}); print $_->{seq},'  ',$_->{text},qq(\n) for @{$d->{lines}}"
```

Scan every log read for: ERROR, WARNING, IMPLEMENTATION ERROR.


## §1 Reset to Known State

Run all steps before any test. Record wall-clock start time (needed for last_testrun.md).

```
# Wall-clock start time
perl -e "use POSIX qw(strftime); print strftime('%Y-%m-%d %H:%M', localtime), qq(\n)"

# 1. Revert navMate.db to git baseline
git -C C:/dat/Rhapsody checkout -- navMate.db

# 2. Reload the database in navMate
curl -s "http://localhost:9883/api/test?op=refresh"

# 3. Enable suppress BEFORE any E80 operation (dialogs block if suppress is not set first)
curl -s "http://localhost:9883/api/test?op=suppress&val=1"

# 4. Clear E80:
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10430"
# wait for ProgressDialog FINISHED, then:
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10421"
# wait for ProgressDialog FINISHED; if ungrouped WPs remain:
curl -s "http://localhost:9883/api/test?panel=e80&select=my_waypoints&right_click=my_waypoints&cmd=10421"
# NOTE: key is 'my_waypoints' -- 'header:my_waypoints' fails (selects 0 nodes)

# 5. Mark log
curl -s "http://localhost:9883/api/command?cmd=mark"
```

After reset: verify git shows navMate.db clean; /api/db returns empty E80.

**Derive route point keys.** Get route_waypoints for [TestRoute] (a route with 3+ points),
sort by position, note the first three WP UUIDs as [RP1], [RP2], [RP3]:

```
curl -s "http://localhost:9883/api/nmdb" | perl -e "
  use JSON;
  my $d = decode_json(do{local$/;<STDIN>});
  my @rw = grep { $_->{route_uuid} eq 'ROUTE_UUID_HERE' } @{$d->{route_waypoints}};
  print $_->{position}, '  ', $_->{wp_uuid}, qq(\n)
    for sort { $a->{position} <=> $b->{position} } @rw;
"
```


## §2 Database Tests (no E80 required)

E80 need not be connected for this section.

---

### §2.1 Copy WP -> Paste New (duplicate with fresh UUID)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10301"
```

Expected: new WP with fresh navMate UUID appears in [DST]; [IsolatedWP1] unchanged.
Log: COPY STARTED/FINISHED, PASTE_NEW STARTED/FINISHED, no errors.
Verify /api/nmdb: new waypoint row, collection_uuid=[DST], uuid != [IsolatedWP1].

---

### §2.2 Cut WP -> Paste (move)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP2]&cmd=10110"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10300"
```

Expected: [IsolatedWP2] UUID unchanged; collection_uuid now = [DST].
Log: CUT STARTED/FINISHED, PASTE STARTED/FINISHED, no errors.

---

### §2.3 Delete WP (success)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP3]&right_click=[IsolatedWP3]&cmd=10410"
```

Expected: waypoint row deleted. Log: DELETE_WAYPOINT STARTED/FINISHED.
Verify /api/nmdb: [IsolatedWP3] UUID absent from waypoints array.

---

### §2.4 Delete Group -- dissolve (members reparented to parent collection)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[GroupNoRoute]&right_click=[GroupNoRoute]&cmd=10420"
```

Expected: group shell deleted; all member WPs reparented -- collection_uuid updated to the
group's former parent branch. Route references to member WPs unaffected (UUIDs unchanged).
Log: DELETE_GROUP STARTED/FINISHED, no warnings.
Verify /api/nmdb: [GroupNoRoute] absent from collections; former member WP rows present
with updated collection_uuid.

---

### §2.5 Delete Group+WPS -- success (members not in route)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[GroupNoRoute]&right_click=[GroupNoRoute]&cmd=10421"
```

If §2.4 already ran, use a second group with no route refs, or reorder §2.4/§2.5 to run
§2.5 first on the same group.

Expected: group shell and all member WPs deleted.
Verify /api/nmdb: group UUID absent; all member WP UUIDs absent.

---

### §2.6 Delete Group+WPS -- blocked (members in route) -- pre-flight failure

```
curl -s "http://localhost:9883/api/test?panel=database&select=[GroupInRoute]&right_click=[GroupInRoute]&cmd=10421"
```

Use a group whose members ARE referenced in a route.
Expected: pre-flight blocks -- WARNING in log; group and members unchanged.
Note: nmTest bypasses the menu guard and hits the handler-level sentinel directly; the
IMPLEMENTATION ERROR sentinel in the log is expected behavior for this path.

---

### §2.7 Delete Branch (recursive, safe)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[SafeBranch]&right_click=[SafeBranch]&cmd=10450"
```

Expected: branch and all descendants deleted (sub-collections, WPs, routes, route_waypoints,
tracks, track_points). Log: DELETE_BRANCH STARTED/FINISHED, no errors.
Verify /api/nmdb: branch UUID absent; all child UUIDs absent.

---

### §2.8 Copy Branch -> Paste New (duplicate branch contents, fresh UUIDs)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[RouteBranch]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10301"
```

Expected: all groups, routes, and WPs from [RouteBranch] duplicated into [DST] with fresh
navMate UUIDs. Tracks silently skipped (PASTE_NEW not supported for tracks per SS10.3).
Source [RouteBranch] unchanged.
Log: COPY STARTED/FINISHED, PASTE_NEW STARTED/FINISHED, no errors.

---

### §2.9 Cut Branch -> Paste (move branch contents)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[SomeBranch]&cmd=10110"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10300"
```

Expected: all branch contents (groups, routes, tracks, WPs) re-homed to [DST]; UUIDs
preserved. Source branch becomes empty shell.
Verify /api/nmdb: all former children have collection_uuid or parent_uuid = [DST].

---

### §2.10 Copy Route -> Paste New (fresh UUIDs, all members duplicated)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[TestRoute]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10301"
```

Expected: new route with fresh UUID in [DST]; each member WP also receives a fresh UUID.
Original [TestRoute] unchanged.

---

### §2.11 Cut Route -> Paste (move route record)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[TestRoute]&cmd=10110"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10300"
```

Expected: route record collection_uuid updated to [DST]; UUID unchanged;
route_waypoints sequence unchanged.

---

### §2.12 Cut Track -> Paste (move track record)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[TestTrack]&cmd=10110"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10300"
```

Expected: track collection_uuid updated to [DST]; UUID unchanged; track_points unchanged.

---

### §2.13 Paste New Before/After -- collection member (positional insertion)

Copy [IsolatedWP1], paste new before [IsolatedWP2] in the same collection:

```
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP2]&right_click=[IsolatedWP2]&cmd=10304"
```

(10304 = PASTE_NEW_BEFORE; copy operation uses PASTE_NEW variant)

Expected: fresh-UUID copy of [IsolatedWP1] appears with position FLOAT value less than
[IsolatedWP2]'s position and greater than [IsolatedWP2]'s predecessor's position.
Verify /api/nmdb: new waypoint row, position between expected bounds.

Then paste new after [IsolatedWP2]:

```
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP2]&right_click=[IsolatedWP2]&cmd=10305"
```

Expected: another fresh-UUID copy after [IsolatedWP2] in position order.

---

### §2.14 Paste Before/After -- route point (route sequence reordering)

Uses [TestRoute] with [RP1], [RP2], [RP3] derived at §1 reset.
Route point keys: rp:[TestRoute UUID]:[RP_UUID].

**Copy-splice (PASTE_NEW_BEFORE): insert duplicate reference**

```
curl -s "http://localhost:9883/api/test?panel=database&select=rp:[TestRoute]:[RP1]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=rp:[TestRoute]:[RP3]&right_click=rp:[TestRoute]:[RP3]&cmd=10304"
```

Expected: [RP1]'s WP UUID appears again in route_waypoints at a position between [RP2]
and [RP3]. Underlying waypoint record unchanged. Total route_waypoints count increased by 1.

**Cut-splice (PASTE_BEFORE): reorder without duplicating**

```
curl -s "http://localhost:9883/api/test?panel=database&select=rp:[TestRoute]:[RP3]&cmd=10110"
curl -s "http://localhost:9883/api/test?panel=database&select=rp:[TestRoute]:[RP2]&right_click=rp:[TestRoute]:[RP2]&cmd=10302"
```

Expected: [RP3]'s reference now appears before [RP2] in sequence. Total count unchanged
(move, not copy). Verify /api/nmdb: route_waypoints for [TestRoute] show updated ordering.


## §3 E80 Tests (upload/download)

E80 must be connected and empty after §1 reset.

---

### §3.0 Populate E80 with test data

Upload a WP, a group, and a route. Run all three before any §3 test.

**WP to E80 (ungrouped -- use header:groups, not my_waypoints):**

```
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10300"
```

Wait for ProgressDialog FINISHED.

**Group to E80:**

```
curl -s "http://localhost:9883/api/test?panel=database&select=[GroupWithRouteMembers]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10300"
```

Wait for ProgressDialog FINISHED.

**Route to E80** (pre-flight SS10.10 requires member WPs to exist on E80 first; the group
upload above puts them there if [GroupWithRouteMembers] contains the route's member WPs):

```
curl -s "http://localhost:9883/api/test?panel=database&select=[TestRoute]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10300"
```

Wait for ProgressDialog FINISHED.

Verify via /api/db: WP, group, and route all appear. Note E80-assigned UUIDs as [E80_WP],
[E80_GR], [E80_RT].

---

### §3.1 Copy E80 WP -> Paste to DB (UUID-preserving download)

```
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_WP]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10300"
```

Expected: WP inserted/updated in DB with E80's UUID. Log: COPY STARTED/FINISHED,
PASTE STARTED/FINISHED, no errors.
Verify /api/nmdb: waypoint row with uuid=[E80_WP], collection_uuid=[DST].

---

### §3.2 Copy E80 WP -> Paste New to DB (fresh UUID)

```
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_WP]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10301"
```

Expected: new WP in DB with fresh navMate UUID (byte 1 = 0x82) != [E80_WP]; name preserved.

---

### §3.3 Delete E80 WP

```
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_WP]&right_click=[E80_WP]&cmd=10410"
```

Wait for ProgressDialog FINISHED.
Expected: [E80_WP] absent from /api/db waypoints.

---

### §3.4 Delete E80 Group + members (DEL_GROUP_WPS)

```
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_GR]&right_click=[E80_GR]&cmd=10421"
```

Wait for ProgressDialog FINISHED.
Expected: [E80_GR] and all member WPs absent from /api/db.

---

### §3.5 Delete via E80 Groups header (all groups) -- SS8.2 header-node delete

```
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10421"
```

Wait for ProgressDialog FINISHED.
Expected: E80 groups empty; all member WPs absent. This exercises the SS8.2 header-node
Delete path -- right-clicking the Groups header operates on all groups in the folder.

---

### §3.6 Delete via E80 Routes header (all routes) -- SS8.2 header-node delete

```
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10430"
```

Wait for ProgressDialog FINISHED.
Expected: E80 routes empty; member WPs preserved.

---

### §3.7 Delete via E80 My Waypoints (all ungrouped WPs) -- SS8.2

Requires ungrouped WPs present. If [E80_WP] was deleted in §3.3, re-upload one first.

```
curl -s "http://localhost:9883/api/test?panel=e80&select=my_waypoints&right_click=my_waypoints&cmd=10421"
```

Wait for ProgressDialog FINISHED.
Expected: all ungrouped WPs deleted; named groups unaffected.

---

### §3.8 Delete via E80 Tracks header -- SS8.2

Requires tracks on E80. If teensyBoat is not available, defer to §4 or mark NOT_RUN.

```
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10440"
```

Wait for ProgressDialog FINISHED.
Expected: all E80 tracks erased. This exercises SS8.2's fourth header-node Delete rule.

---

### §3.9 Copy E80 Group -> Paste to DB (group download)

If §3.4 deleted [E80_GR], re-upload [GroupWithRouteMembers] first.

```
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_GR]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10300"
```

Expected: group collection and member WPs merged into DB under [DST].

---

### §3.10 Copy E80 Route -> Paste to DB (route download)

```
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_RT]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10300"
```

Expected: route record and member WPs inserted/updated in DB.

---

### §3.11 DB->E80 all-paste -- ordering dependency test

[RouteBranch] contains groups whose WPs are also route members. Exercises _pasteAllToE80
ordering: groups and their WPs upload first; when routes are processed, member WPs are
already present on E80 (no_change idempotency). If [GroupWithRouteMembers] WPs are already
on E80 from §3.0, those produce no_change entries in the log.

```
curl -s "http://localhost:9883/api/test?panel=database&select=[RouteBranch]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=root&right_click=root&cmd=10300"
```

Wait for ProgressDialog FINISHED (may take several seconds for large groups).

Expected log: COPY STARTED/FINISHED; PASTE STARTED/FINISHED; no_change entries for any
WPs already on E80; no ERROR or WARNING.
Verify /api/db: all groups and routes from [RouteBranch] present on E80; no duplicate
WP UUIDs.

---

### §3.12 Paste New WP to E80 (fresh UUID)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP2]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10301"
```

Wait for ProgressDialog FINISHED.
Expected: new WP on E80 with fresh navMate UUID != [IsolatedWP2]; name preserved.
Verify /api/db: waypoint count increased by 1; no entry with uuid=[IsolatedWP2].

---

### §3.13 Paste New Group to E80 (all-fresh UUIDs)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[GroupNoRoute]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10301"
```

Wait for ProgressDialog FINISHED.
Expected: new group on E80 with fresh UUID; each member WP has a fresh UUID.
If the original group UUID was already on E80, that copy is unchanged.
E80 now has two copies of the group with distinct UUIDs and distinct member WP UUIDs.

---

### §3.14 Paste New Route to E80 (all-fresh UUIDs)

PASTE_NEW for a route creates a fresh route UUID and fresh member WP UUIDs. The new WPs
are created on E80 as fresh items -- they do not reuse any existing E80 WP UUIDs.

```
curl -s "http://localhost:9883/api/test?panel=database&select=[TestRoute]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10301"
```

Wait for ProgressDialog FINISHED.
Expected: new route on E80 with fresh UUID; all member WPs created with fresh UUIDs
independent of any same-route WPs already on E80 from prior steps. Original [TestRoute]
on E80 unchanged.

---

### §3.15 Multi-select WPs -> Paste to E80 (homogeneous flat set)

Two WPs selected; single COPY command; pre-flight sees homogeneous flat set of waypoints.

```
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1],[IsolatedWP2]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10300"
```

Wait for ProgressDialog FINISHED.
Expected: both WP UUIDs appear in E80 waypoints. Log: COPY with items=2; PASTE with items=2.

---

### §3.16 Route point Paste Before/After on E80 (route sequence insertion)

Requires a route already on E80 with at least 3 route_waypoints. Use [E80_RT] from §3.0
or §3.11. Get the E80 route_waypoints for [E80_RT] from /api/db; note three consecutive
points as [E80_RP1], [E80_RP2], [E80_RP3].

Copy [E80_RP1]:
```
curl -s "http://localhost:9883/api/test?panel=e80&select=rp:[E80_RT]:[E80_RP1]&cmd=10010"
```

Paste Before [E80_RP3] (insert duplicate reference between [E80_RP2] and [E80_RP3]):
```
curl -s "http://localhost:9883/api/test?panel=e80&select=rp:[E80_RT]:[E80_RP3]&right_click=rp:[E80_RT]:[E80_RP3]&cmd=10302"
```

Wait for ProgressDialog FINISHED.
Expected: [E80_RP1]'s WP UUID now appears at a position between [E80_RP2] and [E80_RP3]
in [E80_RT]'s route_waypoints sequence. Total count increased by 1.
This exercises SS10.9: E80 Paste Before/After is valid only at route point destinations.


## §4 Track Tests (requires teensyBoat session)

Section §4 requires live track recording via teensyBoat (port 9881). Load boat_driving_guide.md
before starting. Skip entirely if teensyBoat is not available; mark all §4 steps NOT_RUN.

---

### §4.0 Prerequisite -- create test tracks on E80

Drive to create at least two short test tracks. Verify tracks appear in winE80 Tracks
section. Note E80-assigned UUIDs from /api/db as [E80_TK1], [E80_TK2].

Track creation pattern: AP=0 -> H=NNN -> S=50 -> start track -> drive -> stop track ->
name -> save. Expected non-fatal events: GET_CUR2 ERROR after each EVENT(0), "TRACK OUT
OF BAND" after save. Verify save: "got track(uuid) = 'name'" in log.

**UUID behavior (confirmed):** E80->DB paste for tracks does NOT preserve the E80 UUID.
navMate assigns a fresh UUID. Search by name in /api/nmdb, not by UUID. Color is
converted correctly: E80 index -> aabbggrr (0=ff0000ff, 1=ff00ffff, 2=ff00ff00,
3=ffff0000, 4=ffff00ff, 5=ff000000).

---

### §4.1 Copy E80 Track -> Paste to DB (download, track still on E80)

```
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_TK1]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10300"
```

Wait for ProgressDialog FINISHED.
Expected: track record and track_points in DB under [DST]; fresh UUID. Track still on E80.
Verify /api/nmdb: track found by name; point count matches E80 report.

---

### §4.2 Cut E80 Track -> Paste to DB (download + E80 erase)

```
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_TK2]&cmd=10110"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10300"
```

Wait for ProgressDialog FINISHED.
Expected: track in DB with fresh UUID; TRACK_CMD_ERASE sent to E80; track absent from
/api/db after erase. This is the end-to-end verification of the track erase path.

---

### §4.3 Guard -- Paste Track to E80 blocked (tracks read-only)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[TestTrack]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10300"
```

Expected: paste rejected per SS10.8 (E80 tracks destination accepts no paste). E80 unchanged.

---

### §4.4 Guard -- Paste New blocked for track clipboard

```
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_TK1]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10301"
```

Expected: PASTE_NEW rejected for track clipboard per SS10.3 ("PASTE_NEW not available
for tracks"). DB unchanged.


## §5 Pre-flight and Guard Tests

These verify that blocked operations fail cleanly. The /api/test endpoint fires cmd
unconditionally, bypassing menu-level guards -- verify results by reading the log, not by
absence of menu items. All blocked operations should produce WARNING or IMPLEMENTATION
ERROR in the log with no data change.

Tests marked **PREREQUISITE: outcome=reject** require `$suppress_outcome` support; see
[nmOps testability prerequisites] in todo.md. Run the accept-path variant only until the
prerequisite is implemented; mark the reject-path variant NOT_RUN.

---

### §5.1 DEL_WAYPOINT blocked -- WP referenced in route (DB panel)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[WPinRoute]&right_click=[WPinRoute]&cmd=10410"
```

Expected: WARNING in log (waypoint referenced in route); [WPinRoute] still in /api/nmdb.

---

### §5.2 DEL_BRANCH blocked -- member WP in external route (isBranchDeleteSafe=0)

Requires a branch whose WPs are referenced by routes OUTSIDE the branch subtree. If the
baseline DB does not have this configuration, mark NOT_RUN.

```
curl -s "http://localhost:9883/api/test?panel=database&select=[UnsafeBranch]&right_click=[UnsafeBranch]&cmd=10450"
```

Expected: WARNING in log (isBranchDeleteSafe=0); branch unchanged.

---

### §5.3 Paste blocked -- DB cut -> E80 destination (SS9, SS10.5)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10110"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10300"
```

Expected: paste rejected; WARNING in log; E80 unchanged; [IsolatedWP1] still in DB
(cut not consumed). DB is the authoritative repository -- uploads to E80 are copies only.

---

### §5.4 Paste blocked -- any clipboard -> E80 tracks header (SS10.8)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10300"
```

Expected: rejected (E80 tracks destination accepts no paste). E80 unchanged.

---

### §5.5 Paste blocked -- DB copy track -> DB paste (no UUID-preserving copy path)

```
curl -s "http://localhost:9883/api/test?panel=database&select=[TestTrack]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10300"
```

Expected: PASTE rejected per SS10.3 (homogeneous tracks, DB source, cut_flag=0: no PASTE
path). WARNING or IMPLEMENTATION ERROR in log; DB unchanged.

---

### §5.6 Route dependency check -- route paste before member WPs exist on E80 (SS10.10)

Ensure E80 has no WPs that match [TestRoute]'s member WP UUIDs. If needed, clear the E80
of all WPs first. Then:

```
curl -s "http://localhost:9883/api/test?panel=database&select=[TestRoute]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10300"
```

Expected: pre-flight SS10.10 route dependency check aborts -- WARNING in log listing the
missing WP UUIDs; E80 routes unchanged.

---

### §5.7 Ancestor-wins -- accept path (SS6.2)

Select both [GroupNoRoute] (intact compound) and one of its member WPs simultaneously.
With suppress=1 (accept default), ancestor-wins absorbs the member WP and proceeds with
the group only.

```
curl -s "http://localhost:9883/api/test?panel=database&select=[GroupNoRoute],[MemberWP_ofGroupNoRoute]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10301"
```

Wait for ProgressDialog FINISHED.
Expected: group uploaded as an intact compound object. [MemberWP_ofGroupNoRoute] does NOT
appear as a separate ungrouped WP on E80; it arrived inside the group. Log: ancestor-wins
resolution noted; confirmation dialog auto-accepted.

---

### §5.8 Ancestor-wins -- abort path (SS6.2) -- PREREQUISITE: outcome=reject

```
curl -s "http://localhost:9883/api/test?op=suppress&val=1&outcome=reject"
curl -s "http://localhost:9883/api/test?panel=database&select=[GroupNoRoute],[MemberWP_ofGroupNoRoute]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10301"
curl -s "http://localhost:9883/api/test?op=suppress&val=1&outcome=accept"
```

Expected: ancestor-wins dialog fires; suppressed with reject outcome; paste does not
proceed; E80 unchanged.

---

### §5.9 Recursive paste guard -- paste Branch into its own descendant (SS1.5, SS10.1 Step 3)

Copy [NestedBranch], then paste into [ChildBranch] (a branch that is a descendant of
[NestedBranch]):

```
curl -s "http://localhost:9883/api/test?panel=database&select=[NestedBranch]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=[ChildBranch]&right_click=[ChildBranch]&cmd=10301"
```

Expected: pre-flight SS10.1 Step 3 (recursive paste check) rejects -- WARNING in log
"recursive paste" or similar; DB unchanged.

---

### §5.10 Pre-flight: intra-clipboard name collision (SS10.2 Step 6)

Requires two items of the same type in the clipboard with the same name but different UUIDs.
The E80 enforces unique names; the DB allows duplicates.

**Setup option A** -- check /api/nmdb for any two WPs with the same name; use them.
**Setup option B** -- rename two WPs to the same name via UI before this step; undo after.
**Setup option C** -- mark REQUIRES_SETUP and flag for baseline DB augmentation.

If same-named [WP_A] and [WP_B] are available:

```
curl -s "http://localhost:9883/api/test?panel=database&select=[WP_A],[WP_B]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10301"
```

Expected: pre-flight SS10.2 Step 6 hard-aborts -- WARNING in log identifying the
colliding name; E80 unchanged.

---

### §5.11 Pre-flight: E80-wide name collision (SS10.2 Step 7)

Upload [IsolatedWP1] to E80. Then attempt to paste another DB WP with the same name.

If no second same-named WP exists in DB, create one via UI (NEW_WAYPOINT, same name as
[IsolatedWP1], manual). Use [SameNameWP] as its [Name] in the runbook.

```
# Upload IsolatedWP1 to E80 (if not already present)
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10300"
# Wait for ProgressDialog FINISHED

# Attempt to paste a different WP with the same name
curl -s "http://localhost:9883/api/test?panel=database&select=[SameNameWP]&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10300"
```

Expected: pre-flight SS10.2 Step 7 hard-aborts -- WARNING in log identifying the
conflicting name and type; E80 unchanged (second WP not created).

---

### §5.12 Pre-flight: UUID conflict -- clean create path (SS10.10)

Paste a DB WP to E80 whose UUID does not exist on E80. This is the normal upload path
(verifying that the clean create branch runs without false conflict detection).
Covered by §3.12 -- no separate curl command needed. Verify §3.12 log shows no
conflict-resolution dialog.

---

### §5.13 Pre-flight: UUID conflict -- conflict dialog path (SS10.10) -- PREREQUISITE: outcome=reject

Upload a WP to E80 (UUID now exists there). Modify the WP in DB so db_version > e80_version.
Attempt to paste again. Pre-flight should detect the UUID conflict and present the conflict
resolution dialog. With outcome=reject, abort path is taken.

Full setup for this test is deferred pending version increment wiring (see [db_version
increment wiring] in todo.md). Mark NOT_RUN until versioning is wired.


## Recording Results

Each test cycle produces `apps/navMate/docs/notes/last_testrun.md`. Format:

**Header** -- cycle number, date, wall-clock start and end times.

**Summary** -- one line per §section with overall result.

**Results table** -- every test step listed with Status:
- PASS -- completed as expected
- FAIL -- blocked, data corrupted, or catastrophic
- PARTIAL -- some sub-steps passed, others did not
- PASSED_BUT -- passed with notable caveats (unexpected warning, workaround required)
- NOT_RUN -- skipped (teensyBoat unavailable, prerequisite not met, etc.)

**Issues section** -- always present; "none" on a clean cycle. One prose subsection per
FAIL, PARTIAL, or PASSED_BUT entry. For each:
- Test step (§X.Y and name)
- Nodes involved by [Name]
- Expected vs. actual
- Data state left behind -- what is corrupted, missing, or unexpectedly changed
- Known bug (name the open_bugs.md entry) or new
- Catastrophic (prevents subsequent steps) or not

The Issues section is a triage guide for the next session -- write it so someone reading
cold knows exactly what went wrong and where things stand.
