# e80 Module -- Plan

DB <-> E80 cross-panel operations (upload, download, push, paste-new, multi-select, route-point ops on E80) plus DB-E80 guards (E80 destination-side blocks, name collisions, UUID conflict resolution).

For shared philosophy and status definitions, see [`../master_plan.md`](../master_plan.md). For shared toolbox, see [`../master_runbook.md`](../master_runbook.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md). For execution, see [`runbook.md`](runbook.md).

---

## Module Scope

This module exercises navOps operations that span the DB and E80 transports:

- UUID-preserving uploads (DB → E80 via PASTE) for waypoint, group, route
- PASTE_NEW uploads (DB → E80 with fresh navMate-assigned UUIDs)
- E80 → DB downloads (COPY/CUT then PASTE in DB) -- though the tracks module owns track-specific downloads
- Push (E80 → DB) for waypoint, group, route, multi-item
- E80-side deletes via header nodes and specific nodes
- E80-side route-point insertion
- DB-E80 guards: paste from DB-cut to E80, paste to E80 tracks header, route-dependency pre-flight, ancestor-wins (accept and reject paths), intra-clipboard name collision, E80-wide name collision, UUID conflict clean-create, descendant-paste guard at E80 nodes

E80 is empty at module baseline; populated during the module run by the tests themselves.

## Baseline

The e80 module's baseline is the git-baseline `navMate.db` plus empty E80. Setup:

1. `git -C C:/dat/Rhapsody checkout -- navMate.db`
2. `op=refresh`
3. `op=suppress&val=1`
4. `op=clear_e80` (with ProgressDialog wait)
5. `cmd=mark+e80+module+reset`

After setup: `/api/db` returns 0 waypoints / 0 groups / 0 routes / 0 tracks. `/api/nmdb` returns the full git-baseline DB state.

## Pre-flight rules invoked (selected)

- **SS6.x** -- ancestor-wins resolution (accept and reject paths)
- **SS8.2** -- header-node delete operations (delete-all on E80)
- **SS9 / SS10.5** -- DB-cut to E80 destination blocked
- **SS10.2** -- name collision (intra-clipboard, E80-wide)
- **SS10.3** -- DB-to-DB track copy blocked (covered in db module, referenced here for context)
- **SS10.8** -- paste to E80 tracks header blocked (tracks are read-only on E80 paste side)
- **SS10.10** -- route-dependency pre-flight (member WPs must be on E80 OR in same clipboard)
- **SS12.x** -- route-waypoint UUID preservation through PASTE_NEW

Full pre-flight semantic catalog lives in the legacy `apps/navMate/docs/notes/navOps_testplan.md`.

## Test Inventory

Tests are listed in execution order. Tests are numbered locally to the module (1..N); the cycle results table prefixes the module name (`e80.1`, `e80.2`, ...).

### Upload (DB → E80, UUID-preserving)

| Test | What it verifies |
|------|------------------|
| 1  | Paste WP to E80 (UUID preserved) |
| 2  | Paste Group to E80 (UUID preserved; all member WP UUIDs preserved) |
| 3  | Paste Route to E80 (UUID preserved; route_waypoints sequence preserved) |

### Push (E80 → DB existing record)

| Test | What it verifies |
|------|------------------|
| 4   | Copy E80 WP, Push to DB (DB record updated from E80 values; DB-managed fields preserved) |
| 11b | Copy E80 Group, Push to DB |
| 12b | Copy E80 Route, Push to DB |
| 13  | Multi-select Group + Route, Push to DB |

### Download (E80 → DB)

| Test | What it verifies |
|------|------------------|
| 5   | Copy E80 WP, Paste New to DB (fresh navMate UUID) |
| 14  | Paste New WP to E80 (fresh UUID assigned by navMate; uploaded with fresh UUID) |
| 14b | Copy E80 fresh-UUID WP, Paste to DB (UUID preserved into DB; fresh UUID becomes static) |
| 14c | Mixed-classified E80 clipboard: PASTE_NEW (push-classified + paste-classified -> only PASTE_NEW offered) |

### E80 deletes

| Test | What it verifies |
|------|------------------|
| 6  | Delete E80 WP (specific WP node) |
| 6b | Delete E80 Group+WPS blocked (members in route; ERROR message) |
| 7  | Delete via E80 Routes header (all routes) |
| 8  | Delete via E80 Groups header (all groups + members) |
| 9b | Delete E80 Group + members via specific group node |
| 10b | Delete via E80 My Waypoints (all ungrouped WPs) |

### Setup interleaved with deletes (intra-module re-uploads)

| Test | What it verifies / does |
|------|--------------------------|
| 9a  | Re-upload Popa group to E80 (after Test 8) |
| 10a | Re-upload IsolatedWP1 to E80 (if deleted by Test 6) |
| 11a | Re-upload Popa group (after Test 9b) |
| 12a | Re-upload TestRoute (after Test 7) |
| 16a | Delete all E80 routes (if same-named route present) |

### Paste-new uploads (fresh-UUID variants)

| Test | What it verifies |
|------|------------------|
| 15  | Paste New Group to E80 (fresh group UUID + fresh member UUIDs) |
| 16b | Paste New Route to E80 (fresh route UUID; member WP UUIDs reused) |
| 17  | Multi-select WPs, Paste to E80 (homogeneous flat set; both UUIDs preserved) |

### E80-side route point operations

| Test | What it verifies |
|------|------------------|
| 18 | Route point Paste Before/After on E80 |

### Cross-transport guards

| Test | What it verifies |
|------|------------------|
| 19   | DB-cut to E80 destination blocked |
| 20a  | Pre-cleanup: delete BOCAS1 from E80 if present |
| 20b  | Pre-cleanup: delete BOCAS2 from E80 if present |
| 20c  | Paste to E80 tracks header blocked (`SS10.8`) |
| 21a  | Delete all E80 routes (cleanup before route-dependency test) |
| 21b  | Delete all E80 groups+WPS (cleanup) |
| 21c  | Delete all E80 ungrouped WPs (no-op path documented) |
| 21d  | Route-dependency pre-flight: paste route to empty E80 blocks with member-not-on-E80 error |
| 22   | Ancestor-wins accept path (group + member -> group absorbs member) |
| 23   | Ancestor-wins reject path (confirmation rejected; no E80 write) |
| 24  | Intra-clipboard name collision (hard-abort) |
| 25a | Upload IsolatedWP1 to E80 (setup for Test 25b) |
| 25b | E80-wide name collision (hard-abort) |
| 26  | UUID conflict clean-create path |
| 28a | Upload IsolatedWP1 to E80 if absent (setup for Test 28b/c) |
| 28b | Menu shape: PASTE at E80 WP object node blocked |
| 28c | Menu shape: PASTE_NEW at E80 WP object node blocked |

## Intra-module sequencing

Tests within this module build state on E80 progressively. The module follows the structure of the legacy Sections 3 + 5 -- upload phase, push phase, delete phase, re-upload phase, paste-new phase, route-point phase, then guards. Like the db module, internal sequencing is intentional; independence is at the module boundary only.

## Notes

- Test 27 (UUID conflict dialog path) requires DB versioning infrastructure that does not exist. Record as `NOT_RUN (db_versioning)`.
- Tests 22 / 23 (ancestor-wins) require E80 to be empty before Test 22 to verify the fresh-paste path. Tests 21a/b/c provide that cleanup.
- Test 21c is the documented no-op path -- when E80 has 0 ungrouped WPs, the `my_waypoints` node doesn't exist and the command logs a `no right_click_node set` warning. PASS if /api/db is still empty after.
- E80 fresh-UUID byte 1 = `0x4e` (navMate-assigned, observed in cycle 19). Earlier docs reference `0x82` (RNS-historical); the new docs use `0x4e` matching observed.
