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
- DB-E80 guards: paste from DB-cut to E80, route-dependency pre-flight, ancestor-wins (accept and reject paths), intra-clipboard name collision, E80-wide name collision, post-truncation name collision (NEW 2026-05-29), UUID conflict clean-create, descendant-paste guard at E80 nodes

Track-paste-to-E80 tests live in the `tracks/` module per the 2026-05-29 reorganization (track ops use the TRACK writer-session protocol, distinct from this module's WPMGR-based coverage).

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
- **SS10.10** -- route-dependency pre-flight (member WPs must be on E80 OR in same clipboard)
- **SS12.x** -- route-waypoint UUID preservation through PASTE_NEW
- **Post-truncation collision** (NEW 2026-05-29) -- `_collectNameConflicts` compares lc-keys at post-truncation length (`$E80_MAX_NAME = 15`), so two long-named DB items truncating to the same 15-char prefix are detected at preflight rather than failing silently at the wire.

Full pre-flight semantic catalog lives in the legacy `apps/navMate/docs/notes/navOps_testplan.md`.

## Test Inventory

Two-section structure per master_runbook's Test Organization Convention: positives first (`e80.<N>`), guards second (`e80.G<N>`).  Tests within each section follow their natural execution sequence -- state-dependent ordering is preserved.

### Positive Tests

| Test  | What it verifies |
|-------|------------------|
| e80.1   | Paste WP to E80 (UUID preserved) |
| e80.2   | Paste Group to E80 (UUID preserved; all member WP UUIDs preserved) |
| e80.3   | Paste Route to E80 (UUID preserved; route_waypoints sequence preserved) |
| e80.4   | Copy E80 WP, Push to DB (DB record updated from E80 values; DB-managed fields preserved) |
| e80.5   | Copy E80 WP, Paste New to DB (fresh navMate UUID) |
| e80.6   | Delete E80 WP (specific WP node) |
| e80.7   | Delete via E80 Routes header (all routes) |
| e80.8   | Delete via E80 Groups header (all groups + members) |
| e80.9a  | Re-upload Popa group to E80 (after Test 8) |
| e80.9b  | Delete E80 Group + members via specific group node |
| e80.10a | Re-upload IsolatedWP1 to E80 (if deleted by Test 6) |
| e80.10b | Delete via E80 My Waypoints (all ungrouped WPs; documented empty-list no-op path) |
| e80.11a | Re-upload Popa group (after Test 9b) |
| e80.11b | Copy E80 Group, Push to DB |
| e80.12a | Re-upload TestRoute (after Test 7) |
| e80.12b | Copy E80 Route, Push to DB |
| e80.13  | Multi-select Group + Route, Push to DB |
| e80.14  | Paste New WP to E80 (fresh UUID assigned by navMate) |
| e80.14b | Copy E80 fresh-UUID WP, Paste to DB (UUID preserved into DB; fresh UUID becomes static) |
| e80.14c | Mixed-classified E80 clipboard: PASTE_NEW (push-classified + paste-classified -> only PASTE_NEW offered) |
| e80.15  | Paste New Group to E80 (fresh group UUID + fresh member UUIDs) |
| e80.16a | Delete all E80 routes (cleanup if same-named route present) |
| e80.16b | Paste New Route to E80 (fresh route UUID; member WP UUIDs reused) |
| e80.17  | Multi-select WPs, Paste to E80 (homogeneous flat set; both UUIDs preserved) |
| e80.18  | Route point Paste Before/After on E80 |
| e80.20a | Pre-cleanup: delete BOCAS1 from E80 if present |
| e80.20b | Pre-cleanup: delete BOCAS2 from E80 if present |
| e80.21a | Delete all E80 routes (cleanup before route-dependency guard) |
| e80.21b | Delete all E80 groups+WPS (cleanup) |
| e80.21c | Delete all E80 ungrouped WPs (no-op path documented) |
| e80.22  | Ancestor-wins accept path (group + member -> group absorbs member) |
| e80.25a | Upload IsolatedWP1 to E80 (setup for the name-collision guard) |
| e80.26  | UUID conflict clean-create path |
| e80.27  | UUID conflict dialog path -- `NOT_RUN (db_versioning)` -- infrastructure absent |
| e80.28a | Upload IsolatedWP1 to E80 if absent (setup for descendant-paste guards) |

### Guard Tests

Renamed from previous numbers; old-number cross-reference kept inline for log/code archaeology.  The 2026-05-29 post-truncation guards (e80.G3 / e80.G4) are new and use baseline candidates `BajaCalifornia~1` and `BajaCalifornia~2` (three full names truncating to `BajaCalifornia~` at 15 chars; the only true post-truncation collision pair in baseline DB).  No post-truncation candidates exist in baseline for groups or routes, so those code paths are exercised by the WP variants alone (single shared `_collectNameConflicts` codepath).

| Test    | What it verifies | (was) |
|---------|------------------|-------|
| e80.G1  | DELETE GROUP+WPS blocked -- members in route | e80.6b |
| e80.G2  | DB-cut to E80 destination blocked | e80.19 |
| e80.G3  | Intra-batch post-truncation WP collision -- two `BajaCalifornia~N` DB WPs PASTE'd together to E80 my_waypoints; `_collectNameConflicts` rejects via post-truncation lc-key comparison | (new) |
| e80.G4  | Vs-spoke post-truncation WP collision -- one `BajaCalifornia~N` already on E80, PASTE a DIFFERENT `BajaCalifornia~M` from DB; preflight rejects | (new) |
| e80.G5  | Route-dependency pre-flight: paste route to empty E80 blocks with member-not-on-E80 error | e80.21d |
| e80.G6  | Ancestor-wins reject path (confirmation rejected; no E80 write) | e80.23 |
| e80.G7  | Intra-clipboard name collision (hard-abort) | e80.24 |
| e80.G8  | E80-wide name collision (hard-abort) | e80.25b |
| e80.G9  | Menu shape: PASTE at E80 WP object node blocked | e80.28b |
| e80.G10 | Menu shape: PASTE_NEW at E80 WP object node blocked | e80.28c |
| e80.G11 | DELETE_GROUP at E80 my_waypoints node blocked (predicate D4) | e80.29 |
| e80.G12 | DELETE_GROUP_WPS with mixed my_waypoints + named group blocked (predicate D5) | e80.30 |
| e80.G13 | D6 spoke content-vs-destination: WP at E80 routes header blocked | e80.32 |
| e80.G14 | D6 spoke content-vs-destination: Group at E80 my_waypoints blocked | e80.33 |
| e80.G15 | D6 spoke content-vs-destination: Route at E80 groups header blocked | e80.34 |
| e80.G16 | D6 spoke content-vs-destination: Group at E80 named-group node blocked | e80.35 |

## Intra-module sequencing

Tests within this module build state on E80 progressively. The module follows the structure of the legacy Sections 3 + 5 -- upload phase, push phase, delete phase, re-upload phase, paste-new phase, route-point phase, then guards. Like the db module, internal sequencing is intentional; independence is at the module boundary only.

## Notes

- Test 27 (UUID conflict dialog path) requires DB versioning infrastructure that does not exist. Record as `NOT_RUN (db_versioning)`.
- Tests 22 / 23 (ancestor-wins) require E80 to be empty before Test 22 to verify the fresh-paste path. Tests 21a/b/c provide that cleanup.
- Test 21c is the documented empty-list path -- when E80 has 0 ungrouped WPs, DELETE_GROUP_WPS at `my_waypoints` runs as a real no-op (ProgressDialog STARTED + FINISHED, zero members touched). PASS if /api/db is still empty after.
- E80 fresh-UUID byte 1 = `0x4e` (navMate-assigned, observed in cycle 19). Earlier docs reference `0x82` (RNS-historical); the new docs use `0x4e` matching observed.
