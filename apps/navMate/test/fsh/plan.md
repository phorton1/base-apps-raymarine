# fsh Module -- Plan

DB <-> FSH cross-panel operations (upload, download, push, paste-new, multi-select, route-point ops on FSH) plus DB-FSH guards (FSH destination-side blocks, name collisions, UUID conflict resolution).  FSH also accepts track writes (paste-to-tracks-header), historically considered FSH-unique; since 2026-05-27 E80 also accepts track writes via the writer-session protocol, so FSH track-paste is no longer asymmetric (track-write E80 coverage lives in the `tracks/` module).

For shared philosophy and status definitions, see [`../master_plan.md`](../master_plan.md). For shared toolbox, see [`../master_runbook.md`](../master_runbook.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md). For execution, see [`runbook.md`](runbook.md).

---

## Module Scope

This module exercises navOps operations that span the DB and FSH transports:

- UUID-preserving uploads (DB -> FSH via PASTE) for waypoint, group, route, track
- PASTE_NEW uploads (DB -> FSH with fresh FSH-assigned UUIDs)
- FSH -> DB downloads (COPY/CUT then PASTE / PASTE_NEW)
- Push (FSH -> DB) for waypoint, group, route, multi-item
- FSH-side deletes via header nodes and specific nodes
- FSH-side route-point insertion
- DB-FSH guards: paste from DB-cut to FSH, name collisions, descendant-paste, UUID conflict
- FSH track-write tests (paste-to-tracks-header allowed; E80 also allows since the 2026-05-27 writer-session protocol)

FSH is the first **synchronous** spoke -- all operations mutate the in-memory `$navFSH::fsh_db` hash directly. No ProgressDialog renders; operations complete in a single wx idle tick. Test sleeps are 1-2 seconds typical; no `Wait-NavCmdFinished` helper needed.

FSH stores UUIDs in dashed-uppercase form; navMate canonical clipboard form is lowercase-no-dash. Conversion happens at the snapshot seam (`navToFSHUUID` / `fshToNavUUID`). Tests use FSH-native form for `select=` on the FSH panel and lowercase-no-dash for `select=` on the database panel; cross-checks across `/api/fsh` and `/api/nmdb` apply the conversion as needed.

## Baseline

The fsh module's baseline:

1. `git -C C:/dat/Rhapsody checkout -- navMate.db`
2. `op=refresh`
3. `op=suppress&val=1`
4. `op=clear_e80` (with brief wait)
5. `op=load_fsh&path=C:/base/apps/raymarine/apps/navMate/test/_fixtures/test.fsh`
6. `cmd=mark+fsh+module+reset`

After setup: `/api/db` empty; `/api/nmdb` returns the full git-baseline DB; `/api/fsh` returns 50 waypoints / 4 groups / 3 routes / 123 tracks.

## Pre-flight rules invoked (selected)

- **SS6.x** -- positional insert semantics, ancestor-wins
- **SS9 / SS10.5** -- DB-cut to FSH destination blocked
- **SS10.2** -- name collision (intra-clipboard, FSH-wide)
- **SS12.x** -- route-waypoint UUID preservation through PASTE_NEW
- **`db_to_fsh` lossy transform** -- name > 15, comment > 31, route color not in FSH palette (FSH inherits identical limits + palette as E80)
- **`fsh_to_db` lossy transform** -- route/track color mismatch against existing DB record

Full pre-flight semantic catalog lives in the legacy `apps/navMate/docs/notes/navOps_testplan.md`.

## Test Inventory

Two-section structure per master_runbook's Test Organization Convention: positives first (`fsh.<N>`), guards second (`fsh.G<N>`).  Tests within each section follow their natural execution sequence -- state-dependent ordering is preserved.

### Positive Tests

| Test    | What it verifies |
|---------|------------------|
| fsh.1   | Paste WP to FSH (DB UUID converted to FSH dashed-upper via navToFSHUUID) |
| fsh.2   | Paste Group to FSH (UUID preserved; embedded member WP UUIDs preserved) |
| fsh.3   | Paste Route to FSH (UUID preserved; embedded route_waypoints preserved) |
| fsh.4   | Paste Track to FSH (UUID preserved).  E80 also accepts paste-track since 2026-05-27; this remains as the FSH-destination coverage. |
| fsh.5   | Copy FSH WP, Push to DB |
| fsh.6   | Copy FSH Group, Push to DB |
| fsh.7   | Copy FSH Route, Push to DB |
| fsh.8   | Multi-select Group + Route, Push to DB |
| fsh.9   | Copy FSH WP, Paste New to DB (fresh navMate UUID; FSH WP unaffected) |
| fsh.10  | Cut FSH WP, Paste to DB (UUID preserved into DB; FSH-side WP gone) |
| fsh.11a | Delete FSH WP (specific WP node under my_waypoints) |
| fsh.11b | Delete FSH Group -- dissolve (group shell removed; embedded members migrate to top-level my_waypoints; routes referencing those UUIDs unaffected).  Parallels db.5. |
| fsh.13  | Delete via FSH Routes header (all routes) |
| fsh.14  | Delete via FSH Groups header (all groups + members) |
| fsh.15a | Re-upload Popa group to FSH |
| fsh.15b | Delete FSH Group + members via specific group node |
| fsh.16a | Re-upload IsolatedWP1 to FSH |
| fsh.16b | Delete via FSH My Waypoints (all top-level ungrouped WPs) |
| fsh.17a | Re-upload [FSH_GroupInRoute] (after fsh.14 cleared groups) |
| fsh.17b | Re-upload [FSH_TestRoute] (after fsh.13 cleared routes) |
| fsh.18  | Paste New WP to FSH (fresh FSH UUID; original DB UUID NOT preserved) |
| fsh.19  | Paste New Group to FSH (fresh group UUID + fresh member UUIDs) |
| fsh.20  | Paste New Route to FSH (fresh route UUID; member WPs reused if already on FSH, else fresh) |
| fsh.21  | Multi-select WPs, Paste to FSH (homogeneous flat set; both UUIDs preserved) |
| fsh.22  | Route point Paste Before/After on FSH |
| fsh.23  | Cut FSH Track, Paste to DB (UUID preserved; FSH-side track gone) |
| fsh.24  | Copy FSH Track, Paste New to DB (fresh navMate UUID; FSH track stays) |
| fsh.25  | Delete FSH Track (specific node) |
| fsh.26  | Delete via FSH Tracks header (all tracks cleared) |
| fsh.28  | Lossy-transform pre-flight: db_to_fsh long-name truncation warning fires; user accepts; paste proceeds with truncation |
| fsh.30a | Ensure [FSH_IsolatedWP1] on FSH (precondition for the FSH-wide collision guard) |
| fsh.31  | UUID conflict clean-create path (parallels e80.26) |
| fsh.32a | Ensure [FSH_IsolatedWP1] on FSH (precondition for the descendant-paste guards) |

### Guard Tests

Renamed from previous numbers; old-number cross-reference kept inline for log/code archaeology.  The 2026-05-29 post-truncation guard (`fsh.G11`) is new and uses the same `BajaCalifornia~N` baseline candidates as `e80.G3` -- `_collectNameConflicts` shares its codepath across E80 and FSH destinations.

| Test    | What it verifies | (was) |
|---------|------------------|-------|
| fsh.G1  | Delete FSH Group+WPS blocked -- members in route (ERROR sentinel) | fsh.12 |
| fsh.G2  | DB-cut to FSH destination blocked (parallels e80.G2) | fsh.27 |
| fsh.G3  | Intra-clipboard name collision (hard-abort; parallels e80.G7) | fsh.29 |
| fsh.G4  | FSH-wide name collision (parallels e80.G8).  Self-establishes a second DB BOCAS1 via PASTE_NEW if the fixture-DB precondition is absent, then verifies the collision sentinel. | fsh.30b |
| fsh.G5  | PASTE at FSH WP object node blocked (descendant-paste guard; parallels e80.G9) | fsh.32b |
| fsh.G6  | PASTE_NEW at FSH WP object node blocked (parallels e80.G10) | fsh.32c |
| fsh.G7  | D6 spoke content-vs-destination: WP at FSH routes header blocked (parallels e80.G13) | fsh.33 |
| fsh.G8  | D6 spoke content-vs-destination: Group at FSH my_waypoints blocked (parallels e80.G14) | fsh.34 |
| fsh.G9  | D6 spoke content-vs-destination: Route at FSH groups header blocked (parallels e80.G15) | fsh.35 |
| fsh.G10 | D6 spoke content-vs-destination: Group at FSH named-group node blocked (parallels e80.G16) | fsh.36 |
| fsh.G11 | Intra-batch post-truncation WP collision on FSH destination -- two `BajaCalifornia~N` DB WPs PASTE'd to FSH my_waypoints; `_collectNameConflicts` rejects via post-truncation lc-key comparison.  Parallels e80.G3. | fsh.37 |

## Intra-module sequencing

Tests within this module build state on FSH progressively, like the e80 module. Internal sequencing is intentional; independence is at the module boundary only.

Key sequencing decisions:

- Tests 1-4 upload sources, populating FSH with WP / Group / Route / Track that have UUID-preserved DB counterparts. Tests 5-8 then push back.
- Tests 9-10 exercise FSH->DB downloads using items from tests 1-2.
- Tests 11-16 progressively clear FSH (specific deletes -> group blocked guard -> header deletes).
- Tests 17a/b re-populate state for the paste-new and route-point tests.
- Tests 23-26 exercise tracks last (so the 123-track fixture is preserved through earlier tests).
- Guards (27-32c, 33-36) run at the end.

## Notes

- Test 5 (UUID conflict dialog path -- e80.27 equivalent) is **omitted** for FSH. The clean-create path (test 31) is exercised; the dialog path requires DB versioning infrastructure that does not yet exist (same blocker as e80.27).
- FSH dashed-uppercase UUIDs in `select=` strings can be passed verbatim (no URL encoding needed for hyphens). Mixed selects across panels stay panel-scoped -- one panel per `/api/test` call.
- The 50 isolated WPs under FSH `my_waypoints` and the 79-member `test` group (none in route) give the safe-delete tests substantial state to exercise without consuming the small-and-useful structures.
- FSH has a pseudo `my_waypoints` -- the top-level `/api/fsh.waypoints` hash is the ungrouped pool, analogous to E80's `my_waypoints` node. Group dissolve (cmd=10221) moves embedded wpts to that pool; routes referencing the same UUIDs are unaffected because FSH routes carry their own embedded wpt records.
- Open observation from alpha: same-UUID PASTE-WP to FSH may hit the name-uniqueness guard before the UUID-match in-place-update check. Not blocking, but worth probing if `_doPaste` precedence is ever touched.
