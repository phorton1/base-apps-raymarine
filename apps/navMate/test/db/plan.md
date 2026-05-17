# db Module -- Plan

DB-internal operations (copy/cut/paste/delete within the database) and DB-only guards. No E80 contact, no FSH contact.

For shared philosophy and status definitions, see [`../master_plan.md`](../master_plan.md). For shared toolbox, helpers, and the cycle results format, see [`../master_runbook.md`](../master_runbook.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md). For execution, see [`runbook.md`](runbook.md).

---

## Module Scope

This module exercises navOps operations whose source and destination are both inside the navMate database:

- COPY / CUT / PASTE / PASTE_NEW of waypoints, groups, routes, tracks, branches, and route points
- Positional inserts: PASTE_NEW_BEFORE, PASTE_NEW_AFTER (across all valid anchor types)
- Position-allocator stress (32-iteration bisection forcing AutoCompact)
- DELETE of waypoints, groups, group+WPs, branches, routes, tracks
- DB-only guards: delete-blocked-by-route, delete-branch-blocked-by-external-route, paste-blocked at object nodes (waypoint, route, track), recursive-paste guard, DB-to-DB track paste guard, mixed-clipboard route-point operations

E80 panel is empty throughout this module. The module does not call any `/api/test?panel=e80` endpoint.

## Baseline

The db module's baseline is the git-baseline `navMate.db`. Setup:

1. `git -C C:/dat/Rhapsody checkout -- navMate.db`
2. `op=refresh`
3. `op=suppress&val=1`
4. `op=clear_e80` (no-op if already empty; required to confirm E80 is empty before module run)
5. `cmd=mark+db+module+reset`

After setup: `/api/db` returns 0 waypoints / 0 groups / 0 routes / 0 tracks. `/api/nmdb` returns the full git-baseline DB state.

## Pre-flight rules invoked (selected)

- **SS1.x** -- COPY / CUT clipboard semantics, multi-item COPY
- **SS6.x** -- positional insert semantics, ancestor-wins (DB-side variant; E80-side handled in e80 module)
- **SS12.x** -- route-waypoint UUID preservation across PASTE_NEW

Full pre-flight semantic catalog lives in the legacy `apps/navMate/docs/notes/navOps_testplan.md` (to be split across module plans during Phase E).

## Test Inventory

Tests are listed in execution order. Tests are numbered locally to the module (1..N); the cycle results table prefixes the module name (`db.1`, `db.2`, ...).

### Positive paths -- COPY / CUT / PASTE / DELETE

| Test | What it verifies |
|------|------------------|
| 1  | Position allocator: 32 PASTE_NEW_BEFORE bisections force AutoCompact (stress test, self-contained) |
| 2  | COPY WP -> PASTE_NEW (fresh UUID in [DST]; source unchanged) |
| 3  | CUT WP -> PASTE (UUID preserved; collection_uuid changes to [DST]) |
| 4  | DELETE WP success (no route refs) |
| 5  | DELETE GROUP -- dissolve (group shell deleted; members reparented to grandparent) |
| 6  | DELETE GROUP+WPS -- success (no route refs) |
| 7  | DELETE GROUP+WPS -- blocked (members in route; IMPLEMENTATION ERROR sentinel) |
| 8  | DELETE BRANCH -- recursive, safe (descendants gone) |
| 9  | COPY BRANCH -> PASTE_NEW (fresh UUIDs throughout; source unchanged; tracks silently skipped) |
| 10  | CUT BRANCH -> PASTE (branch moves as a unit; UUID and contents preserved) |
| 11 | COPY ROUTE -> PASTE_NEW (fresh route UUID; route_waypoints reference same WP UUIDs as source) |
| 12 | CUT ROUTE -> PASTE (UUID and route_waypoints preserved; collection_uuid changes) |
| 13 | CUT TRACK -> PASTE (UUID and track_points preserved; collection_uuid changes) |

### Positional inserts

| Test | What it verifies |
|------|------------------|
| 14a | PASTE_NEW_BEFORE with collection-member anchor (insert at midpoint) |
| 14b | PASTE_NEW_AFTER with collection-member anchor |
| 15a | PASTE_NEW_BEFORE on route point (copy-splice; route count +1) |
| 15b | PASTE_BEFORE on route point (cut-splice; count unchanged) |
| 16a | PASTE_NEW_BEFORE with route-object anchor |
| 16b | PASTE_NEW_AFTER with route-object anchor |
| 17  | PASTE_NEW_BEFORE with group-object anchor |
| 18  | PASTE_NEW_BEFORE with branch-object anchor |
| 19a | PASTE_NEW_BEFORE with route clipboard + WP anchor |
| 19b | PASTE_NEW_BEFORE with group clipboard + WP anchor |

### DB-only guards (formerly Section 5)

| Test | What it verifies |
|------|------------------|
| 20  | DEL_WAYPOINT blocked -- WP referenced in route (IMPL ERROR sentinel) |
| 21  | DEL_BRANCH blocked -- member WP in external route |
| 22  | PASTE blocked -- DB-copy track to DB destination (no UUID-preserving DB-to-DB track copy path) |
| 23  | Recursive PASTE_NEW guard -- branch into its own descendant |
| 24a | Menu shape -- PASTE at DB WP object node blocked |
| 24b | Menu shape -- PASTE_NEW at DB WP object node blocked |
| 24c | Menu shape -- PASTE at DB route object node blocked |
| 24d | Menu shape -- PASTE at DB track object node blocked |
| 25a | Mixed clipboard PASTE_BEFORE at route_point |
| 25b | Mixed clipboard PASTE_NEW_BEFORE at route_point |

## Intra-module sequencing

Tests within this module are not commutative -- they build on each other (BOCAS2 moves into [DST] in Test 3 and becomes the anchor for Test 14a/b; [TestRoute] moves into [DST] in Test 12 and is used for Test 15a/b, Test 16a/b, Test 19a, Test 25a/b). This is intentional and was the structure of the legacy Section 2.

The independence guarantee is at the MODULE boundary: this module is independent of e80, tracks, fsh, hub. Tests INSIDE the module retain their natural sequence.

## Notes

- Test 1 is self-contained (creates and destroys its own `PrecisionTestBranch`). It runs first because position-allocator failures invalidate everything downstream.
- DB-only guard tests (Test 20, 21, 22, 23, 24a-d, 25a/b) run at the end. They depend on the state built up by Tests 2-19b -- specifically [TestRoute] in [DST] and the Test 15a-introduced duplicate Popa0 in [TestRoute].
- BOCAS2 (and other moved items) leave the module's [DST] populated with various accumulated WPs, routes, and a moved branch. This is the natural end state of the module; it has no significance once the module completes (next module's baseline reverts the DB).
