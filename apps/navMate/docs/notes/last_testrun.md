# nmOperations Test Run — Cycle 7

**Date:** 2026-05-08
**Start:** ~10:10
**End:** ~13:00
**Cycle:** 7 (full §1-§5 except §4 Tracks; first run of restructured testplan with new §2.13-§2.14 and full §5)

---

## Summary

- **§1 (reset):** PASS
- **§2 (database tests 2.1-2.14):** ALL PASS (14 steps; first run of new §2.13-§2.14 PASTE_BEFORE/AFTER)
- **§3 (E80 tests):** PARTIAL — 11 PASS, 1 PASSED_BUT, 4 FAIL, 2 NOT_RUN
- **§4 (track tests):** NOT_RUN — teensyBoat unavailable this cycle
- **§5 (guard tests):** PARTIAL — 6 PASS, 4 FAIL, 3 NOT_RUN

6 bugs found; no catastrophic errors; test cycle completed without navMate restart.

---

## Full Test Results

| Section | Description | Result | Notes |
|---------|-------------|--------|-------|
| §1 | Reset (git revert, reload, clear E80) | PASS | |
| §2.1 | Copy WP → Paste New | PASS | Fresh UUID in [DST] |
| §2.2 | Cut WP → Paste (move) | PASS | UUID preserved; collection changed |
| §2.3 | Delete WP (success) | PASS | TOBOBE absent |
| §2.4 | Delete Group dissolve | PASS | 3 members reparented to Part 1 |
| §2.5 | Delete Group+WPS (success) | PASS | Bocas group + 2 WPs deleted |
| §2.6 | Delete Group+WPS (blocked) | PASS | IMPLEMENTATION ERROR sentinel; Popa group intact |
| §2.7 | Delete Branch recursive | PASS | Before Sumwood Channel fully deleted |
| §2.8 | Copy Branch → Paste New | PASS | All groups/routes/WPs duplicated with fresh UUIDs |
| §2.9 | Cut Branch → Paste (move) | PASS | Places group + Tracks re-homed to [DST] |
| §2.10 | Copy Route → Paste New | PASS | Fresh-UUID route + 11 WPs in [DST] |
| §2.11 | Cut Route → Paste (move) | PASS | Popa route moved to [DST]; UUID unchanged |
| §2.12 | Cut Track → Paste (move) | PASS | Track moved to [DST]; UUID unchanged |
| §2.13 | PASTE_NEW_BEFORE/AFTER WP | PASS | Positional midpoint insertion correct |
| §2.14 | PASTE_BEFORE/AFTER route point | PASS | Two-step shift fix; PASTE_NEW reuses wp_uuid |
| §3.0a | Paste WP to E80 (UUID-preserving) | PASS | BOCAS1 (ce4e43181f01b3ae) on E80 as ungrouped WP |
| §3.0b | Paste Group to E80 (UUID-preserving) | PASS | Popa group + 11 member WPs on E80 |
| §3.0c | Paste Route to E80 (UUID-preserving) | FAIL | Route created on E80 with 0 route_waypoints |
| §3.1 | Copy E80 WP → Paste to DB (UUID-preserving) | PASSED_BUT | WP updated in place; minor caveat noted in log |
| §3.2 | Copy E80 WP → Paste New to DB (fresh UUID) | PASS | Fresh navMate UUID (byte 1=0x82) |
| §3.3 | Delete E80 WP | PASS | [E80_WP] absent from /api/db |
| §3.4 | Delete E80 Group+members | PASS | Popa group + 11 WPs deleted from E80 |
| §3.5 | Delete via E80 Groups header (SS8.2) | PASS | E80 groups empty |
| §3.6 | Delete via E80 Routes header (SS8.2) | PASS | E80 routes empty |
| §3.7 | Delete via E80 My Waypoints (SS8.2) | PASS | All ungrouped WPs deleted |
| §3.8 | Delete via E80 Tracks header (SS8.2) | NOT_RUN | teensyBoat unavailable |
| §3.9 | Copy E80 Group → Paste to DB | PASS | Popa group + 11 WPs merged into DB under [DST] |
| §3.10 | Copy E80 Route → Paste to DB | PASS | Route + member WPs inserted/updated in DB |
| §3.11 | DB→E80 all-paste ([RouteBranch]) | FAIL | Homogeneity check blocks group+route mix after branch dissolution |
| §3.12 | Paste New WP to E80 (fresh UUID) | PASS | Fresh UUID; name BOCAS2; no conflict dialog |
| §3.13 | Paste New Group to E80 (fresh UUIDs) | PASS | Timiteo group + 6 fresh-UUID WPs on E80 |
| §3.14 | Paste New Route to E80 (fresh UUIDs) | FAIL | Step 7 name collision: 'Popa' already on E80 from §3.11 |
| §3.15 | Multi-select WPs → Paste to E80 | FAIL | Step 7 name collision: 'BOCAS2' already on E80 from §3.12 |
| §3.16 | Route point PASTE_BEFORE/AFTER on E80 | NOT_RUN | E80 route has 0 waypoints (route_points/members bug) |
| §4.0 | Create test tracks on E80 | NOT_RUN | teensyBoat unavailable |
| §4.1 | Copy E80 Track → Paste to DB | NOT_RUN | teensyBoat unavailable |
| §4.2 | Cut E80 Track → Paste to DB | NOT_RUN | teensyBoat unavailable |
| §4.3 | Guard: track → E80 blocked (SS10.8) | NOT_RUN | teensyBoat unavailable |
| §4.4 | Guard: Paste New for track blocked (SS10.3) | NOT_RUN | teensyBoat unavailable |
| §5.1 | Guard: DEL_WAYPOINT blocked (WP in route) | FAIL | Popa0 deleted; getWaypointRouteRefCount returned 0 |
| §5.2 | Guard: DEL_BRANCH blocked (WP in external route) | PASS | isBranchDeleteSafe=0; branch unchanged |
| §5.3 | Guard: DB cut → E80 paste blocked (SS9) | PASS | WARNING fired; E80 unchanged |
| §5.4 | Guard: any clipboard → E80 tracks header (SS10.8) | FAIL | BOCAS1 created ungrouped on E80; guard not enforced |
| §5.5 | Guard: DB copy track → DB paste blocked | PASS | WARNING fired; DB unchanged |
| §5.6 | Route dependency check (SS10.10) | FAIL | Empty route created silently; route_points/members bug |
| §5.7 | Ancestor-wins accept (SS6.2) | PASS | Timiteo group on E80; t01 not added as separate ungrouped WP |
| §5.8 | Ancestor-wins abort | NOT_RUN | outcome=reject prerequisite not implemented |
| §5.9 | Recursive paste guard | FAIL | New MandalaLogs branch created inside MandalaLogs/Tracks |
| §5.10 | Intra-clipboard name collision (Step 6) | PASS | Abort: "Clipboard contains duplicate waypoint name 'BOCAS1'" |
| §5.11 | E80-wide name collision (Step 7) | PASS | Abort: "E80 already has a waypoint named 'BOCAS1'" |
| §5.12 | UUID conflict clean path | PASS | Covered by §3.12; no conflict dialog observed |
| §5.13 | UUID conflict dialog path | NOT_RUN | db_version wiring prerequisite not done |

---

## Issues

### §3.0c PASSED_BUT / §3.16 NOT_RUN / §5.6 FAIL

**Observed (§3.0c):** Route pasted to E80. ProgressDialog completed without error.
/api/db showed the route was created on E80 with 0 route_waypoints despite 11 in the DB.

**Observed (§5.6):** Route pasted to E80 with all member WPs cleared beforehand. No WARNING
fired. Route created silently with 0 route_waypoints. Expected: WARNING; route not created.

**Analysis:** `_pasteRouteToE80` (nmOpsE80.pm:833) reads `$item->{members}` from the clipboard
item. Route clipboard items are built with key `route_points` (nmOps.pm:298). Since `{members}`
is absent from route items, the `// []` fallback fires and the route_point loop executes zero
times. The route is then created with an empty waypoint list. The same key mismatch causes the
§5.6 dependency check never to fire -- no route_points are iterated, so no missing-WP check
can occur.

**Resolution (proposed):** Change `$item->{members}` to `$item->{route_points}` at
nmOpsE80.pm:833; fix the corresponding count at nmOpsE80.pm:918. Note: once corrected,
§5.6 will exercise a different code path -- a design decision is still needed on whether
UUID-preserving route paste should block or proceed when member WPs are absent from E80.

---

### §3.11 FAIL

**Observed:** ERROR logged: "E80 paste requires homogeneous content (cannot mix routes,
tracks, and waypoints)". No items pasted to E80. [RouteBranch] was the clipboard source;
paste destination was E80 root.

**Analysis:** [RouteBranch] (Navigation/Routes) contains both groups and routes. Pre-flight
Step 4 (branch dissolution) expands its members, yielding a mixed group+route set. Step 5
homogeneity check (nmOps.pm:562) permits only waypoint+group as a two-type mix; group+route
is rejected.

**Resolution (proposed):** Expand the permitted two-type mixes to include group+route.

---

### §3.14 FAIL

**Observed:** Step 7 aborted PASTE_NEW route with ERROR: "E80 already has a route named
'Popa'". No new route created. [TestRoute] (Popa) was already on E80 from §3.11.

**Analysis:** Step 7 fires for routes in the PASTE_NEW path the same as for UUID-preserving
PASTE. WP PASTE_NEW applies `_deconflictE80Name` to avoid this; route PASTE_NEW does not.

**Resolution (proposed):** Apply name deconfliction to routes in the PASTE_NEW path.

---

### §3.15 FAIL

**Observed:** Step 7 aborted PASTE of [IsolatedWP1]+[IsolatedWP2] (multi-select) to E80
with ERROR: "E80 already has a waypoint named 'BOCAS2'". No items created.

**Analysis:** §3.12 created a fresh-UUID copy of BOCAS2 (name='BOCAS2') on E80. [IsolatedWP2]
carries the original DB UUID (af4e23246d01bfa8), which differs from the §3.12 copy. Step 7
correctly identifies a name collision between two different UUIDs. The guard functioned as
designed; the failure is a test-sequencing issue -- §3.15 ran into state left by §3.12.

**Resolution (proposed):** Redesign §3.15 to use WPs not affected by prior steps, or specify
cleanup of §3.12 state before §3.15 runs.

---

### §5.1 FAIL

**Observed:** DEL_WAYPOINT fired on [WPinRoute] (Popa0, 314e56cc09005332). No WARNING in
log. /api/nmdb confirmed Popa0 was absent after the operation. Expected: WARNING, no deletion.

**Analysis:** The DEL_WAYPOINT handler checks route reference count before deleting; if count
> 0 it blocks. The count returned 0 for Popa0, allowing deletion to proceed. Why the count
was 0 is not established from this test -- Popa0 is a known route_waypoints entry. A possible
explanation is that §2.14 PASTE_BEFORE/AFTER operations altered Popa0's route_waypoints row,
but this has not been verified by DB inspection.

**Resolution (proposed):** On the next cycle, inspect route_waypoints state for Popa0
immediately after §2.14 completes. Determine whether the two-step position shift corrupted
the entry. Fix accordingly.

---

### §5.4 FAIL

**Observed:** BOCAS1 WP was created on E80 as an ungrouped waypoint. The right-click
destination was the E80 Tracks header. No rejection or WARNING.

**Analysis:** SS10.8 specifies that the E80 tracks destination accepts no paste. The guard
is not in place -- the paste executed as if the destination were ungrouped waypoints.

**Resolution (proposed):** Add destination-type check before dispatching in `_pasteE80` or
`_pasteAllToE80`; reject when destination is the Tracks header.

---

### §5.9 FAIL

**Observed:** [NestedBranch] (MandalaLogs) pasted into [ChildBranch] (MandalaLogs/Tracks).
Expected: rejection. Actual: new MandalaLogs branch created inside MandalaLogs/Tracks
(/api/nmdb confirmed new branch UUID db4e140825056ffe under 984e7898480427f6).

**Analysis:** The recursive paste guard in `_doPaste` checks only whether a clipboard item's
UUID equals the destination UUID. It does not check whether the destination is a descendant
of the clipboard item, so the branch-into-own-descendant case passes silently.

**Resolution (proposed):** Walk the DB ancestor chain from the destination UUID upward;
abort if any ancestor UUID matches a clipboard item's UUID.

---

