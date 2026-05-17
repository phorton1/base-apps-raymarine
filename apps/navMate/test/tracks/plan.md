# tracks Module -- Plan

Track download from E80 to DB via the teensyBoat simulator. The module's tests require a running teensyBoat at `http://localhost:9881` and verify the full track lifecycle: record-on-E80, copy/paste to DB, cut/paste to DB, paste-new (fresh UUID), delete via E80 tracks header. Track-paste-to-E80 is blocked (read-only on the paste side) and is covered here as a guard.

For shared philosophy and status definitions, see [`../master_plan.md`](../master_plan.md). For shared toolbox, see [`../master_runbook.md`](../master_runbook.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md). For execution, see [`runbook.md`](runbook.md).

---

## Module Scope

Tracks are different from other transport objects in two key ways:

1. **Tracks can only be CREATED on E80** -- never uploaded from DB to E80. The E80 track-paste path is guarded (Test 4 verifies the guard).
2. **Track UUIDs are E80-assigned** (byte 1 = `0xB2`) and preserved through E80-to-DB COPY/CUT. PASTE_NEW assigns a fresh navMate UUID instead.

## Baseline

The tracks module's baseline:

1. `git -C C:/dat/Rhapsody checkout -- navMate.db`
2. `op=refresh`
3. `op=suppress&val=1`
4. `op=clear_e80` (with ProgressDialog wait)
5. `cmd=mark+tracks+module+reset`
6. **teensyBoat pre-check** -- if teensyBoat is unavailable at `http://localhost:9881`, the entire module records as `NOT_RUN (teensyBoat unavailable)` and stops.

After setup: `/api/db` empty; teensyBoat is reachable and responding to `?cmd=SIM`.

## Pre-flight rules invoked

- **SS8.2** -- delete-via-tracks-header
- **SS10.3** -- DB-to-DB track copy blocked (covered in db module)
- **SS10.8** -- paste-to-tracks-header blocked

## Test Inventory

| Test | What it verifies |
|------|------------------|
| 1  | Create two test tracks on E80 via teensyBoat (Track1, Track2). Each is a 3-leg triangle at 50 knots. |
| 2  | COPY E80 Track, PASTE to DB (E80 track stays; DB record has E80 UUID preserved, byte 1 = B2) |
| 3  | CUT E80 Track, PASTE to DB (E80 erases the track; DB record has E80 UUID preserved) |
| 4  | Guard: PASTE Track to E80 tracks header blocked (`SS10.8`) |
| 5  | PASTE_NEW E80 Track to DB (fresh navMate UUID; original E80 track stays) |
| 6  | DELETE via E80 Tracks header (`SS8.2`) |

## Notes

- Test 1 generates ~30s of track data per track (10s per leg, 3 legs). With teensyBoat running, total module wall time is ~3-5 minutes for two tracks plus the COPY/CUT/PASTE tests.
- Track record warnings (`TRACK EVENT(N)`, `enquing GET_CUR2`, `handleEvent() returning undef`, `bad points(0) != expected(N)`, `TRACK OUT OF BAND`) are documented protocol noise during recording. Save succeeds when `got track(<uuid>) = '<name>'` appears in the log.
- After both tracks are saved, park the simulator with `S=0` (never `STOP` -- that halts the simulator entirely).
- `[E80_TK1]` and `[E80_TK2]` UUIDs are derived at runtime from `/api/db` tracks after save; they vary per cycle.
