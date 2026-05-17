# fsh Module -- Plan

DB <-> FSH cross-panel operations (upload, download, push, paste-new, multi-select, route-point ops on FSH) plus DB-FSH guards (FSH destination-side blocks, name collisions, UUID conflict resolution). Includes FSH-unique track-write operations (E80 blocks paste-to-tracks; FSH allows).

For shared philosophy and status definitions, see [`../master_plan.md`](../master_plan.md). For shared toolbox, see [`../master_runbook.md`](../master_runbook.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md). For execution, see [`runbook.md`](runbook.md).

---

## Module Scope

This module exercises navOps operations that span the DB and FSH transports:

- UUID-preserving uploads (DB -> FSH via PASTE) for waypoint, group, route, **track** (FSH-unique)
- PASTE_NEW uploads (DB -> FSH with fresh FSH-assigned UUIDs)
- FSH -> DB downloads (COPY/CUT then PASTE / PASTE_NEW)
- Push (FSH -> DB) for waypoint, group, route, multi-item
- FSH-side deletes via header nodes and specific nodes
- FSH-side route-point insertion
- DB-FSH guards: paste from DB-cut to FSH, name collisions, descendant-paste, UUID conflict
- FSH track-write tests (covers paste-to-tracks-header as an ALLOWED path, contra E80's guard)

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

Tests are listed in execution order. The module mirrors the e80 module's structure but drops ProgressDialog-related criteria and adds FSH-unique track tests.

### Upload (DB -> FSH, UUID-preserving)

| Test | What it verifies |
|------|------------------|
| 1 | Paste WP to FSH (DB UUID converted to FSH dashed-upper via navToFSHUUID; round-trip preserves the original DB UUID via fshToNavUUID) |
| 2 | Paste Group to FSH (UUID preserved; embedded member WP UUIDs preserved) |
| 3 | Paste Route to FSH (UUID preserved; embedded route_waypoints preserved) |
| 4 | Paste Track to FSH (UUID preserved -- FSH-unique; E80 blocks this) |

### Push (FSH -> DB existing record)

Pushes back the items uploaded in tests 1-3. UUIDs match after round-trip conversion; push updates the DB record's spoke-managed fields without moving the record.

| Test | What it verifies |
|------|------------------|
| 5    | Copy FSH WP, Push to DB |
| 6    | Copy FSH Group, Push to DB |
| 7    | Copy FSH Route, Push to DB |
| 8    | Multi-select Group + Route, Push to DB |

### Download (FSH -> DB)

| Test | What it verifies |
|------|------------------|
| 9    | Copy FSH WP, Paste New to DB (fresh navMate UUID; FSH WP unaffected) |
| 10   | Cut FSH WP, Paste to DB (UUID preserved into DB; FSH-side WP gone) |

### FSH deletes

| Test | What it verifies |
|------|------------------|
| 11a  | Delete FSH WP (specific WP node under my_waypoints) |
| 11b  | Delete FSH Group -- dissolve (group shell removed; embedded members migrate to top-level my_waypoints; routes referencing those UUIDs unaffected). Parallels db.5. |
| 12   | Delete FSH Group+WPS blocked (members in route; ERROR sentinel) |
| 13   | Delete via FSH Routes header (all routes) |
| 14   | Delete via FSH Groups header (all groups + members) |
| 15   | Delete FSH Group + members via specific group node |
| 16   | Delete via FSH My Waypoints (all top-level ungrouped WPs) |

### Re-uploads (intra-module setup interleaved with deletes)

Analogous to e80.9a / e80.11a / e80.12a / e80.16a.

| Test | What it does |
|------|--------------|
| 17a  | Re-upload [FSH_GroupInRoute] (after fsh.14 cleared groups) |
| 17b  | Re-upload [FSH_TestRoute] (after fsh.13 cleared routes) |

### PASTE_NEW variants (fresh-UUID uploads to FSH)

| Test | What it verifies |
|------|------------------|
| 18   | Paste New WP to FSH (fresh FSH UUID; original DB UUID NOT preserved) |
| 19   | Paste New Group to FSH (fresh group UUID + fresh member UUIDs) |
| 20   | Paste New Route to FSH (fresh route UUID; member WPs reused if already on FSH, else fresh) |

### Multi-select

| Test | What it verifies |
|------|------------------|
| 21   | Multi-select WPs, Paste to FSH (homogeneous flat set; both UUIDs preserved) |

### FSH-side route point operations

| Test | What it verifies |
|------|------------------|
| 22   | Route point Paste Before/After on FSH |

### Track-specific (FSH-unique)

FSH allows track writes (PASTE to tracks). E80 blocks the same path; tests 4 and 23-26 exercise the difference.

| Test | What it verifies |
|------|------------------|
| 23   | Cut FSH Track, Paste to DB (UUID preserved; FSH-side track gone) |
| 24   | Copy FSH Track, Paste New to DB (fresh navMate UUID; FSH track stays) |
| 25   | Delete FSH Track (specific node) |
| 26   | Delete via FSH Tracks header (all tracks cleared) |

### Cross-transport guards

| Test | What it verifies |
|------|------------------|
| 27   | DB-cut to FSH destination blocked (parallels e80.19) |
| 28   | Lossy-transform pre-flight: db_to_fsh long-name truncation warning |
| 29   | Intra-clipboard name collision (hard-abort; parallels e80.24) |
| 30a  | Ensure [FSH_IsolatedWP1] on FSH (precondition for 30b) |
| 30b  | FSH-wide name collision (parallels e80.25b). Self-establishes a second DB BOCAS1 via PASTE_NEW if the fixture-DB precondition is absent, then verifies the collision sentinel. |
| 31   | UUID conflict clean-create path (parallels e80.26) |
| 32a  | Ensure [FSH_IsolatedWP1] on FSH (precondition for 32b/c). PASS if already present OR if the paste step lands it; FAIL otherwise. |
| 32b  | PASTE at FSH WP object node blocked (descendant-paste guard; parallels e80.28b) |
| 32c  | PASTE_NEW at FSH WP object node blocked (parallels e80.28c) |

## Intra-module sequencing

Tests within this module build state on FSH progressively, like the e80 module. Internal sequencing is intentional; independence is at the module boundary only.

Key sequencing decisions:

- Tests 1-4 upload sources, populating FSH with WP / Group / Route / Track that have UUID-preserved DB counterparts. Tests 5-8 then push back.
- Tests 9-10 exercise FSH->DB downloads using items from tests 1-2.
- Tests 11-16 progressively clear FSH (specific deletes -> group blocked guard -> header deletes).
- Tests 17a/b re-populate state for the paste-new and route-point tests.
- Tests 23-26 exercise tracks last (so the 123-track fixture is preserved through earlier tests).
- Guards (27-32c) run at the end.

## Notes

- Test 5 (UUID conflict dialog path -- e80.27 equivalent) is **omitted** for FSH. The clean-create path (test 31) is exercised; the dialog path requires DB versioning infrastructure that does not yet exist (same blocker as e80.27).
- FSH dashed-uppercase UUIDs in `select=` strings can be passed verbatim (no URL encoding needed for hyphens). Mixed selects across panels stay panel-scoped -- one panel per `/api/test` call.
- The 50 isolated WPs under FSH `my_waypoints` and the 79-member `test` group (none in route) give the safe-delete tests substantial state to exercise without consuming the small-and-useful structures.
- FSH has a pseudo `my_waypoints` -- the top-level `/api/fsh.waypoints` hash is the ungrouped pool, analogous to E80's `my_waypoints` node. Group dissolve (cmd=10221) moves embedded wpts to that pool; routes referencing the same UUIDs are unaffected because FSH routes carry their own embedded wpt records.
- Open observation from alpha: same-UUID PASTE-WP to FSH may hit the name-uniqueness guard before the UUID-match in-place-update check. Not blocking, but worth probing if `_doPaste` precedence is ever touched.
