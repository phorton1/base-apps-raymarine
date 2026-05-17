# fsh Module -- Plan (STUB)

**Status: STUB.** This module's content is not yet defined. It is filled in as the winFSH operations land and are exercised end-to-end (Phase 3 of the navOps rework).

For shared philosophy and status definitions, see [`../master_plan.md`](../master_plan.md). For shared toolbox, see [`../master_runbook.md`](../master_runbook.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md). For execution, see [`runbook.md`](runbook.md).

---

## Intended Scope

When filled in, this module will cover DB <-> FSH cross-panel operations, structured the same way as the e80 module:

- **Upload (DB → FSH, UUID-preserving)** -- PASTE waypoint, group, route, track from DB to FSH spoke
- **PASTE_NEW (DB → FSH, fresh UUID)** -- where applicable
- **Download (FSH → DB)** -- COPY/CUT FSH item, PASTE / PASTE_NEW to DB
- **Push (FSH → DB existing)** -- update DB from FSH-side values
- **FSH-side deletes** -- header-node deletes, specific-node deletes
- **DB-FSH guards** -- analogues of the e80 module's guard tests, adapted to FSH semantics

Open design questions:

- **`load_fsh` primitive** -- RESOLVED 2026-05-17. `/api/test?op=load_fsh&path=<absolute-path>` is wired in `navTest.pm`; takes an absolute filesystem path, calls `navFSH::loadFSH`, opens/refreshes the winFSH pane. Log markers documented in `../master_runbook.md`.
- FSH-side UUID registry entries -- to be added to `uuid_index.md` once the fixture's static UUIDs are identified.
- ProgressDialog semantics for synchronous FSH I/O -- whether ProgressDialog auto-FINISHED is a pass criterion the same way it is for E80 (likely yes, but pending Phase 3's wiring).

## Baseline (intended)

When filled in:

1. `git -C C:/dat/Rhapsody checkout -- navMate.db`
2. `op=refresh`
3. `op=suppress&val=1`
4. `op=clear_e80` (with ProgressDialog wait)
5. `op=load_fsh&path=C:/base/apps/raymarine/apps/navMate/test/_fixtures/test.fsh`
6. `cmd=mark+fsh+module+reset`

After setup: `/api/db` empty (E80 side); FSH spoke loaded with the test fixture; `/api/nmdb` returns git-baseline DB.

## Fixture

`../_fixtures/test.fsh` -- frozen copy of `FSH/test/working_oldE80.fsh` (already promoted to navMate, with stable 16-hex UUIDs). The fixture's specific structure (waypoints, groups, routes, tracks present) is documented when the FSH-side UUID registry entries are added to [`../uuid_index.md`](../uuid_index.md).

## Current Stub Behavior

All tests in this module currently record as `NOT_RUN (stub)`. The runbook contains placeholder test slots only.
