# tracks Module -- Plan

E80<->DB and FSH->E80 track operations.  Owns ALL E80 track test coverage: track recording (teensyBoat), download (E80->DB), upload (DB->E80, FSH->E80 via writer-session protocol), PUSH (E80->DB metadata sync), and track-specific guards.

The track-writer protocol (`NET/docs/notes/TRACK_writing.md`, confirmed live 2026-05-27) provides a wire path for DB->E80 track paste.  The previous "tracks read-only on E80" assumption has been retired; the corresponding obsolete guard tests in `e80/` and `hub/` are removed and their replacement coverage lives here.

For shared philosophy and status definitions, see [`../master_plan.md`](../master_plan.md).  For shared toolbox, see [`../master_runbook.md`](../master_runbook.md).  For UUID lookup, see [`../uuid_index.md`](../uuid_index.md).  For execution, see [`runbook.md`](runbook.md).

---

## Module Scope

Tracks differ from WGR (waypoints/groups/routes) operationally:

1. **Recording happens only on E80** -- via teensyBoat (test path) or chartplotter UI (real-world).  No remote-start protocol.
2. **Upload uses the TRACK writer-session protocol** -- distinct from WPMGR; one TCP session per track upload on `E80:2053`.  Wired into `navOpsE80::_writeTrackToE80` / `_pasteTrackToE80` / `_pasteNewTrackToE80`.
3. **Track UUIDs on E80 are FID-keyed**, not name-keyed.  No name-uniqueness enforcement on the E80 spoke.  Per-chunk uuids on the wire are transient markers; only the MTA uuid is canonical.

## Baseline

The tracks module's baseline:

1. `git -C C:/dat/Rhapsody checkout -- navMate.db`
2. `op=refresh`
3. `op=suppress&val=1`
4. `op=clear_e80` (with ProgressDialog wait)
5. `op=load_fsh&path=C:/base/apps/raymarine/apps/navMate/test/_fixtures/test.fsh`
6. `cmd=mark+tracks+module+reset`
7. **teensyBoat pre-check** -- if teensyBoat is unavailable at `http://localhost:9881`, the entire module records as `NOT_RUN (teensyBoat unavailable)` and stops.

After setup: `/api/db` empty; `/api/nmdb` returns the full git-baseline DB; `/api/fsh` returns the test.fsh fixture (50 WPs / 4 groups / 3 routes / 123 tracks); teensyBoat reachable and responding to `?cmd=SIM`.

## Pre-flight rules invoked

- **SS8.2** -- delete-via-tracks-header.
- **SS10.3** -- DB-to-DB track copy blocked (covered in db module; referenced here for context).
- **Track preflight** (`navClipboard::_pasteTracksToE80Allows`) -- hard rules: `point_count > 0`, non-empty `mta_uuid`.  Name length and color drift are NOT hard rules; both are lossy transforms reported via the `lossyTransformWarning` dialog as advisory consent, then applied at the wire seam (silent truncation via `_truncForE80`, color snap via `abgrToE80Index`).
- **Lossy transform** -- DB-side long name (> `$E80_MAX_NAME` = 15) and non-palette color fire `_preflightLossyTransform`.  Tracks were added to the color-drift collector alongside routes 2026-05-28.
- **D6 spoke content-vs-destination** -- track item pasted at a non-tracks-header E80 destination is rejected by the predicate layer in `_pasteRuleAllows`.

---

## Test Inventory

Two-section structure per master runbook's Test Organization Convention: positives first (`tracks.<N>`), guards last (`tracks.G<N>`).

### Section 1 -- teensyBoat + single-track E80->DB

| Test | What it verifies |
|------|------------------|
| tracks.1 | teensyBoat records TWO tracks on E80 (tracks.1a E80Track1, tracks.1b E80Track2 -- the second exists so tracks.4 has a fresh E80 uuid for the CUT+PASTE record-creating positive after tracks.2/3 contaminate the first uuid in DB) |
| tracks.2 | Copy E80Track1, Paste to DB (E80 UUID preserved; E80 track stays) |
| tracks.3 | Copy E80Track1, Paste New to DB (fresh navMate UUID; E80 unchanged) |
| tracks.4 | Cut E80Track2, Paste to DB (E80Track2 consumed by CUT; PASTE creates DB row at preserved E80Track2 uuid -- uuid is uncontaminated, so the 2026-05-29 uuid-collision preflight does not fire) |

End-of-Section-1 state: E80 has E80Track1 (tracks.2/3 are COPY, not CUT); DB has 3 records (E80Track1@preserved-E80, E80Track1@fresh-navMate, E80Track2@preserved-E80).  Section 2's tracks.5+ tolerates the leftover E80Track1.

### Section 2 -- DB/FSH -> E80 + multi-from-E80

| Test | What it verifies |
|------|------------------|
| tracks.5 | PASTE single DB track [DB_TRACK_SHORT] -> E80 tracks header (mta_uuid preserved; writer-session protocol) |
| tracks.6 | PASTE multi DB tracks [DB_TRACK_MULTI_B/C] -> E80 tracks header (two tracks land at preserved uuids).  001 is excluded because tracks.5 already pasted it to E80, and `_pasteAllToE80` rejects a batch that contains any uuid already present on the spoke. |
| tracks.7 | PASTE_NEW single DB track [DB_TRACK_SHORT] -> E80 (fresh navMate UUID minted at writer seam; DB unchanged) |
| tracks.8 | PASTE_NEW multi DB tracks -> E80 |
| tracks.9 | PASTE single FSH track [FSH_TRACK_BOCAS1_003] -> E80 (cross-spoke FSH-to-E80 via writer-session) |
| tracks.10 | PUSH E80 track -> DB (modify name/color on E80, push, observe DB row update) |
| tracks.11 | Multi-COPY from E80 -> PASTE to DB (E80 UUIDs preserved; PASTE hits in-place-update for any matching DB rows) |
| tracks.12 | Multi-CUT from E80 -> PASTE to DB (E80-side consumed; DB receives moved tracks) |
| tracks.13 | DELETE via E80 tracks header (mass cleanup of whatever remains) |

### Section 3 -- Guards

| Test | What it verifies |
|------|------------------|
| tracks.G1 | PASTE track at non-tracks-header E80 destination rejected (D6 spoke content-vs-destination sub-rule).  E80 unchanged. |
| tracks.G2 | Lossy-warn fires both `truncated_names` and `color_mismatch` lines for [DB_TRACK_LONG_NONPALETTE]; under `suppress=1` (auto-accept), paste succeeds with name truncated at wire seam and color snapped to nearest palette index.  Log evidence: two `lossyTransformWarning:` lines (emitted before the suppress short-circuit so they appear in automated-run logs). |
| tracks.G3 | uuid-collision preflight rejects spoke->DB record-creating PASTE when the source uuid already exists in DB.  Setup re-establishes shared uuid (PASTE BOCAS1-001 from DB to E80) then exercises the rejection (COPY from E80, PASTE to DB).  Sentinel names PUSH / PASTE_NEW as the alternatives. |

## Intra-module sequencing

Tests build E80 state progressively from the empty baseline:

- Section 1 creates one E80 track (tracks.1), exercises COPY/PASTE_NEW (preserves E80), then CUT (consumes E80).  End of Section 1: E80 empty.
- Section 2 first repopulates E80 via DB->E80 paste tests (tracks.5-9), then exercises PUSH (tracks.10), then multi-from-E80 (tracks.11-12), then final cleanup (tracks.13).  End of Section 2: E80 empty.
- Section 3 guards run last; their setup uses [DB_TRACK_LONG_NONPALETTE] and any track item (Section 2 may leave one for cleanup; if not, the guard's setup pastes a fresh one).

## Notes

- **Two teensyBoat tracks needed**.  E80Track1 stays on E80 across tracks.2/3 (COPY, not CUT); its uuid is now in DB twice (preserved + fresh-navMate).  tracks.4 must CUT a record-creating positive at a fresh uuid -- the 2026-05-29 uuid-collision preflight rejects spoke->DB PASTE at an already-existing DB uuid -- so E80Track2 exists for tracks.4 to cut.  Mechanical multiplication via the writer-session protocol still serves Section 2's volume tests.
- Track-record protocol warnings (`TRACK EVENT(N)`, `enquing GET_CUR2`, `handleEvent() returning undef`, `bad points(0) != expected(N)`, `TRACK OUT OF BAND`) are documented protocol noise; see `../master_runbook.md` Known-Quiet Warnings.
- After tracks.1's recording, park the teensyBoat simulator with `S=0` (never `STOP` -- that halts the simulator entirely).
- tracks.G2 exercises both lossy-warn entries (name truncation + color snap) in a single test because `[DB_TRACK_LONG_NONPALETTE]` has BOTH a >15-char name AND a non-palette color.  Cheaper than two tests for the same dialog code path.
- `_pasteTracksToE80Allows`'s `point_count > 0` and non-empty `mta_uuid` hard rules are NOT exercised here.  No real-world UI flow can produce a DB row in those states (every DB track has positive points by construction; every DB row has a non-empty primary-key uuid).  The defensive code remains; integration-test coverage is omitted as unreachable.  See `survey_report.txt` 2026-05-29.
- `tracks.10` exercises the **natural color drift** from tracks.5's PASTE -- no out-of-band modify step.  The DB track had a non-palette color (`ffff6666`); the wire seam snapped it to a palette index; PUSH back to DB lands the palette-exact ABGR, which differs from the original.  This is a genuine diff sync without requiring chartplotter UI or external helpers.
- `[E80_TK1]` / `[E80_TK2]` UUIDs are derived at runtime from `/api/db` tracks after tracks.1a / tracks.1b save; vary per cycle.
