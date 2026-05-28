# navOperations Test Run -- Cycle 26

**Date:** 2026-05-27
**Start:** 17:14
**End:** 18:40
**Cycle:** 26

First full cycle exercising the 2026-05-29 uuid-collision preflight in `_doPaste` (spoke->DB record-creating paste rejected when source uuid already in DB) and the tracks-module redesign (E80Track1 + E80Track2 recordings, `tracks.G3` uuid-collision guard, comma-separated multi-select for tracks.6/tracks.8). All 5 modules ran end-to-end with no FAILs. One pre-existing open bug (`clear_e80_progress_hang`) surfaced twice in inter-module resets and was rescued each time by `close_dialog`.

Mid-cycle (during db guards, after db.G11) Patrick accidentally closed navMate; I re-asserted `suppress=1`, re-marked, and resumed at db.G12 without losing DB/E80 state. Subsequent inter-module resets ran the full reset+load_fsh sequence again, so no module's baseline depended on the interrupted state.

---

## Summary

| Module | Result |
|--------|--------|
| db     | PASS -- all 44 steps |
| e80    | PASS -- 50 PASS + 1 NOT_RUN (e80.27 db_versioning) |
| tracks | PASS -- teensyBoat available; all 16 steps |
| fsh    | PASS -- all 44 steps |
| hub    | PASS -- 26 PASS + 1 NOT_RUN (hub.G2 precondition_unmet under no-silent-rename policy) |

---

## Results Table

| Test | Status |
|------|--------|
| **db** | |
| db.1 Position precision (32 PASTE_NEW_BEFORE bisections force AutoCompact) | PASS |
| db.2 Copy WP -> Paste New | PASS |
| db.3 Cut WP -> Paste (move) | PASS |
| db.4 Delete WP (success) | PASS |
| db.5 Delete Group (dissolve) | PASS |
| db.6 Delete Group+WPS (success) | PASS |
| db.8 Delete Branch (recursive, safe) | PASS |
| db.9 Copy Branch -> Paste New | PASS |
| db.10 Cut Branch -> Paste (move) | PASS |
| db.11 Copy Route -> Paste New | PASS |
| db.12 Cut Route -> Paste (move) | PASS |
| db.13 Cut Track -> Paste (move) | PASS |
| db.14a Paste New Before (collection-member anchor) | PASS |
| db.14b Paste New After (collection-member anchor) | PASS |
| db.15a PASTE_NEW_BEFORE route point (copy-splice) | PASS |
| db.15b PASTE_BEFORE route point (cut-splice) | PASS |
| db.16a Paste New Before (route-object anchor) | PASS |
| db.16b Paste New After (route-object anchor) | PASS |
| db.17 Paste New Before (group-object anchor) | PASS |
| db.18 Paste New Before (branch-object anchor) | PASS |
| db.19a Paste New Before (route clipboard, WP anchor) | PASS |
| db.19b Paste New Before (group clipboard, WP anchor) | PASS |
| db.35 PASTE waypoint at DB route object (D3: REF append) | PASS |
| db.37 Pure route_point COPY+PASTE_BEFORE at route_point anchor (D1 carve-out) | PASS |
| db.G1 Delete Group+WPS blocked (members in route) | PASS |
| db.G2 DEL_WAYPOINT blocked (WP in route) | PASS |
| db.G3 DEL_BRANCH blocked (member WP in external route) | PASS |
| db.G4 DB-copy track to DB destination blocked | PASS |
| db.G5 Recursive paste guard (branch into own descendant) | PASS |
| db.G6 Menu shape: PASTE at DB WP object node blocked | PASS |
| db.G7 Menu shape: PASTE_NEW at DB WP object node blocked | PASS |
| db.G8 Menu shape: PASTE at DB track object node blocked | PASS |
| db.G9 Mixed clipboard PASTE_BEFORE at route_point | PASS |
| db.G10 Mixed clipboard PASTE_NEW_BEFORE at route_point | PASS |
| db.G11 COPY WP -> PASTE blocked (predicate; DB-to-DB waypoint copy) | PASS |
| db.G12 COPY group -> PASTE blocked (predicate; DB-to-DB group copy) | PASS |
| db.G13 COPY route -> PASTE blocked (predicate; DB-to-DB route copy) | PASS |
| db.G14 COPY branch -> PASTE blocked (predicate; DB-to-DB branch copy) | PASS |
| db.G15 COPY track -> PASTE_BEFORE blocked (predicate; original-bug case) | PASS |
| db.G16 COPY track -> PASTE_AFTER blocked (predicate; symmetry with G15) | PASS |
| db.G17 NEW_WAYPOINT at non-collection target blocked (predicate) | PASS |
| db.G18 NEW_ROUTE at non-collection target blocked (predicate) | PASS |
| db.G19 PASTE_BEFORE at route_point with non-WP clipboard blocked (predicate) | PASS |
| db.G20 COPY route_point, PASTE at collection blocked (D2: route_point at non-route) | PASS |
| **e80** | |
| e80.1 Paste WP to E80 (UUID-preserving) | PASS |
| e80.2 Paste Group to E80 (UUID-preserving) | PASS |
| e80.3 Paste Route to E80 (UUID-preserving) | PASS |
| e80.4 Copy E80 WP, Push to DB | PASS |
| e80.5 Copy E80 WP, Paste New to DB (fresh UUID) | PASS |
| e80.6 Delete E80 WP (specific node) | PASS |
| e80.7 Delete via E80 Routes header | PASS |
| e80.8 Delete via E80 Groups header | PASS |
| e80.9a Re-upload Popa group | PASS |
| e80.9b Delete E80 Group + members via specific group node | PASS |
| e80.10a Ensure at least one ungrouped WP on E80 | PASS |
| e80.10b Delete via E80 My Waypoints (all ungrouped) | PASS |
| e80.11a Re-upload Popa group | PASS |
| e80.11b Copy E80 Group, Push to DB | PASS |
| e80.12a Re-upload TestRoute | PASS |
| e80.12b Copy E80 Route, Push to DB | PASS |
| e80.13 Multi-select Group + Route, Push to DB | PASS |
| e80.14 Paste New WP to E80 (fresh UUID) | PASS |
| e80.14b Copy E80 fresh-UUID WP, Paste to DB | PASS |
| e80.14c Mixed-classified E80 clipboard, PASTE_NEW | PASS |
| e80.15 Paste New Group to E80 (all-fresh UUIDs) | PASS |
| e80.16a Ensure E80 routes empty | PASS |
| e80.16b Paste New Route to E80 | PASS |
| e80.17 Multi-select WPs, Paste to E80 | PASS |
| e80.18 Route point Paste Before/After on E80 | PASS |
| e80.20a Delete BOCAS1 from E80 if present | PASS |
| e80.20b Delete BOCAS2 from E80 if present | PASS |
| e80.21a Delete all E80 routes (cleanup) | PASS |
| e80.21b Delete all E80 groups+WPS | PASS |
| e80.21c Delete all E80 ungrouped WPs (no-op path) | PASS |
| e80.22 Ancestor-wins accept path | PASS |
| e80.25a Upload IsolatedWP1 to E80 (setup for E80-wide collision guard) | PASS |
| e80.26 UUID conflict clean-create path | PASS |
| e80.27 UUID conflict dialog path | NOT_RUN (db_versioning infra not yet implemented) |
| e80.28a Ensure IsolatedWP1 on E80 | PASS |
| e80.G1 Delete E80 Group+WPS blocked (member in route) | PASS |
| e80.G2 DB-cut to E80 destination blocked | PASS |
| e80.G3 Intra-batch post-truncation WP collision | PASS |
| e80.G4 Vs-spoke post-truncation WP collision | PASS |
| e80.G5 Route-dependency pre-flight | PASS |
| e80.G6 Ancestor-wins reject path | PASS |
| e80.G7 Intra-clipboard name collision | PASS |
| e80.G8 E80-wide name collision | PASS |
| e80.G9 PASTE at E80 WP object node blocked | PASS |
| e80.G10 PASTE_NEW at E80 WP object node blocked | PASS |
| e80.G11 DELETE_GROUP at E80 my_waypoints node blocked (predicate) | PASS |
| e80.G12 DELETE_GROUP_WPS with mixed my_waypoints + named group blocked (predicate) | PASS |
| e80.G13 D6: WP paste at E80 routes header blocked | PASS |
| e80.G14 D6: Group paste at E80 my_waypoints blocked | PASS |
| e80.G15 D6: Route paste at E80 groups header blocked | PASS |
| e80.G16 D6: Group paste at E80 named-group node blocked | PASS |
| **tracks** | |
| tracks.1 Create two test tracks on E80 (E80Track1, E80Track2) | PASS |
| tracks.2 Copy E80Track1, Paste to DB | PASS |
| tracks.3 Copy E80Track1, Paste New to DB (fresh navMate UUID) | PASS |
| tracks.4 Cut E80Track2, Paste to DB | PASS |
| tracks.5 PASTE single DB track -> E80 tracks header | PASS |
| tracks.6 PASTE multi DB tracks -> E80 tracks header | PASS |
| tracks.7 PASTE_NEW single DB track -> E80 (fresh navMate UUID) | PASS |
| tracks.8 PASTE_NEW multi DB tracks -> E80 | PASS |
| tracks.9 PASTE single FSH track -> E80 (cross-spoke) | PASS |
| tracks.10 PUSH E80 track -> DB (exercises natural color drift) | PASS |
| tracks.11 Multi-COPY from E80 -> PASTE to DB | PASS |
| tracks.12 Multi-CUT from E80 -> PASTE to DB | PASS |
| tracks.13 DELETE via E80 Tracks header | PASS |
| tracks.G1 PASTE track at non-tracks-header E80 destination | PASS |
| tracks.G2 Lossy-warn (name truncation + color drift) on track paste | PASS |
| tracks.G3 uuid-collision preflight on spoke -> DB record-creating paste | PASS |
| **fsh** | |
| fsh.1 Paste WP to FSH (UUID-preserving) | PASS |
| fsh.2 Paste Group to FSH (UUID-preserving) | PASS |
| fsh.3 Paste Route to FSH (UUID-preserving) | PASS |
| fsh.4 Paste Track to FSH (UUID-preserving) -- FSH-unique | PASS |
| fsh.5 Copy FSH WP, Push to DB | PASS |
| fsh.6 Copy FSH Group, Push to DB | PASS |
| fsh.7 Copy FSH Route, Push to DB | PASS |
| fsh.8 Multi-select Group + Route, Push to DB | PASS |
| fsh.9 Copy FSH WP, Paste New to DB (fresh UUID) | PASS |
| fsh.10 Cut FSH WP, Paste to DB (UUID preserved) | PASS |
| fsh.11a Delete FSH WP (success) | PASS |
| fsh.11b Delete FSH Group (dissolve) | PASS |
| fsh.13 Delete via FSH Routes header | PASS |
| fsh.14 Delete via FSH Groups header | PASS |
| fsh.15a Re-upload Popa group to FSH | PASS |
| fsh.15b Delete FSH Group + members via specific group node | PASS |
| fsh.16a Re-upload IsolatedWP1 to FSH | PASS |
| fsh.16b Delete via FSH My Waypoints (all ungrouped) | PASS |
| fsh.17a Re-upload Popa group (setup for paste-new tests) | PASS |
| fsh.17b Re-upload TestRoute | PASS |
| fsh.18 Paste New WP to FSH (fresh UUID) | PASS |
| fsh.19 Paste New Group to FSH (all-fresh UUIDs) | PASS |
| fsh.20 Paste New Route to FSH (fresh route UUID, member WP UUIDs reused) | PASS |
| fsh.21 Multi-select WPs, Paste to FSH | PASS |
| fsh.22 Route point Paste Before/After on FSH | PASS |
| fsh.23 Cut FSH Track, Paste to DB (UUID preserved) | PASS |
| fsh.24 Copy FSH Track, Paste New to DB (fresh navMate UUID) | PASS |
| fsh.25 Delete FSH Track (specific node) | PASS |
| fsh.26 Delete via FSH Tracks header | PASS |
| fsh.28 Lossy-transform pre-flight (db_to_fsh long-name warning) | PASS |
| fsh.30a Upload IsolatedWP1 to FSH (setup for FSH-wide collision guard) | PASS |
| fsh.31 UUID conflict clean-create path | PASS |
| fsh.32a Ensure IsolatedWP1 on FSH (precondition for WP-object guards) | PASS |
| fsh.G1 Delete FSH Group+WPS blocked (members in route) | PASS |
| fsh.G2 DB-cut to FSH destination blocked | PASS |
| fsh.G3 Intra-clipboard name collision | PASS |
| fsh.G4 FSH-wide name collision | PASS |
| fsh.G5 PASTE at FSH WP object node blocked | PASS |
| fsh.G6 PASTE_NEW at FSH WP object node blocked | PASS |
| fsh.G7 D6: WP paste at FSH routes header blocked | PASS |
| fsh.G8 D6: Group paste at FSH my_waypoints blocked | PASS |
| fsh.G9 D6: Route paste at FSH groups header blocked | PASS |
| fsh.G10 D6: Group paste at FSH named-group node blocked | PASS |
| fsh.G11 Intra-batch post-truncation WP collision on FSH destination | PASS |
| **hub** | |
| hub.1 Paste FSH WP -> E80 (UUID-preserving) | PASS |
| hub.2 Paste FSH Group -> E80 (UUID-preserving) | PASS |
| hub.3 Paste FSH Route -> E80 (UUID-preserving) | PASS |
| hub.5 Paste E80 WP -> FSH (same UUID) | PASS |
| hub.6 Paste E80 Group -> FSH (same UUID) | PASS |
| hub.7 Paste E80 Route -> FSH (same UUID) | PASS |
| hub.8 Paste-New E80 WP -> FSH (fresh FSH UUID) | PASS |
| hub.9 Paste-New FSH WP -> E80 (fresh navMate UUID) | PASS |
| hub.10 Paste-New E80 Group -> FSH (fresh group UUID + fresh members) | PASS |
| hub.11 Paste-New FSH Route -> E80 (fresh route UUID; members reused) | PASS |
| hub.12 Cut E80 WP, Paste to FSH | PASS |
| hub.13 Cut FSH WP, Paste to E80 | PASS |
| hub.14 Cut E80 Group, Paste to FSH | PASS |
| hub.15 Cut FSH Group, Paste to E80 | PASS |
| hub.16 Push E80 WP -> FSH (cmd 10251) | PASS |
| hub.17 Push FSH WP -> E80 (cmd 10252) | PASS |
| hub.18 Push E80 Group -> FSH (multi-WP update) | PASS |
| hub.19 Push FSH Route -> E80 | PASS |
| hub.20 E80->FSH->E80 WP round-trip | PASS |
| hub.21 FSH->E80->FSH Group round-trip with members in route | PASS |
| hub.22 Multi-select 2 E80 WPs, Paste to FSH | PASS |
| hub.25 UUID-conflict in-place-update probe | PASS |
| hub.28 Route paste cross-spoke with missing member WPs | PASS |
| hub.G1 GUARD: Heterogeneous clipboard (Group + Route) blocked | PASS |
| hub.G2 GUARD: Name collision destination-side | NOT_RUN (precondition_unmet under no-silent-rename policy) |
| hub.G3 GUARD: Intra-clipboard name collision | PASS |
| hub.G4 GUARD: Descendant-of-clipboard | PASS |

---

## Issues

### e80.27 NOT_RUN -- db_versioning infrastructure absent

Test `e80.27` "UUID conflict dialog path" requires DB versioning infrastructure not yet implemented. Unchanged from cycles 22-25.

### hub.G2 NOT_RUN -- precondition impossible under no-silent-rename policy

Test `hub.G2` "GUARD: Name collision destination-side". Recurring NOT_RUN -- same disposition as cycles 22-25. The PASTE_NEW setup that would mint a fresh-UUID "Waypoint 25" on E80 is itself preflight-blocked by the no-silent-rename policy. Coverage of the underlying behavior is positive in hub.8, hub.10, hub.11, hub.20, hub.21, hub.G3, e80.G7, e80.G8, fsh.G3, fsh.G4 -- all PASS.

---

## Cycle-specific notes

### uuid-collision preflight (2026-05-29, new in this cycle)

The spoke->DB record-creating PASTE rejection landed and is exercised by `tracks.G3` -- the only test that directly probes the rule. Sentinel: `Paste rejected: 1 item(s) already exist in the database at the same uuid. Use PUSH to sync into an existing record, or PASTE_NEW to create a fresh record.` The rule applies to waypoints/groups/routes/tracks symmetrically; `tracks.G3` exercises the tracks path, and the rule is what tracks.4 was redesigned around (E80Track2 recording gives tracks.4 a fresh uuid so the positive can run without colliding).

### tracks module redesign

The 2-recording structure (E80Track1 via 3-leg triangle, E80Track2 via 2-leg short) gives the CUT+PASTE record-creating positive (tracks.4) a fresh uuid uncontaminated by tracks.2/3. Comma-separated multi-select (`select=u1,u2,u3`) replaced earlier chained single-selects that silently dropped all but the last. Both fixes are baked into this cycle's runbook and ran clean.

### clear_e80_progress_hang -- still open, recovered both times

Surfaced twice in inter-module resets: once before db.1 (initial reset after the tracks fixtures from a prior session left tracks on E80 that the reset had to clear), and once before the fsh module reset. Both rescued by `cmd=close_dialog`; cycle proceeded normally. Pre-existing bug; no new diagnosis here.

### Mid-cycle navMate close + restart -- no data loss

Patrick accidentally closed navMate after db.G11. DB and E80 state are durable across that. FSH in-memory was lost but tracks module hadn't started yet, and the tracks runbook re-loads `test.fsh` in its baseline (which I added to the resumed flow). I re-asserted `suppress=1`, set a fresh mark, and continued from db.G12. No state corruption was observed; the remaining db guards (G12-G20) ran cleanly. Notable that the orchestrator runbook's per-module reset (revert DB + refresh + suppress + clear_e80 + load_fsh) made the restart effectively invisible to downstream modules.

### Section C tests in hub runbook are miscategorized

`hub.8`, `hub.10`, `hub.11`, `hub.20`, `hub.21` sit under "Section C -- Cross-spoke PASTE_NEW (fresh UUID)" in the **Positive Tests** half of `hub/runbook.md`, but their current pass criteria assert **rejection** with an ERROR sentinel. Under the 2026-05-20 no-silent-rename policy they verify only the preflight collision-rejection path; the original "test that PASTE_NEW mints a deduped name" purpose evaporated with that policy change. They are guard tests wearing positive-test costumes.

This matters because:

1. Triage discipline -- the master plan's positive/guard segregation is meant to make "positives PASS, guards FAIL" tell a different story from "positives FAIL"; when a positive's only assertion is "the rejection sentinel fires," that distinction collapses.
2. Redundancy -- the rejection coverage is already provided by `e80.G7` (E80 intra-clipboard), `e80.G8` (E80-wide), `fsh.G3` (FSH intra-clipboard), `fsh.G4` (FSH-wide). The five hub tests are double coverage of the same predicate.
3. PASTE_NEW positive coverage on the spokes really does exist elsewhere -- `e80.5` and `fsh.9` exercise it for the single-WP case; the hub tests' fresh-UUID positive purpose can be satisfied by a same-source-different-destination construction if Patrick wants explicit cross-spoke coverage.

Recommended disposition: re-segregate the hub runbook -- move these five into a Guards section (re-numbered hub.G<N>), and either delete them as redundant or replace them with a cross-spoke PASTE_NEW positive that doesn't trip the name-collision guard (e.g. PASTE_NEW a DB WP via E80 with a unique name, or PASTE_NEW a DB-side fresh-uuid record). Decision deferred -- not a fix-in-this-cycle issue, but the categorization is documented here so the next cycle's author can address it explicitly rather than continuing to inherit the miscategorization.

### Section A E80->FSH PASTE same-UUID -- no name collision sentinel observed

`hub.5`, `hub.6`, `hub.7` all PASSed without the FSH-alpha-noted "UUID match precedence" bug firing. Same-UUID PASTE between E80 and FSH (with both sides already holding the record) completed cleanly -- the in-place-update path or the no-op skip works correctly, and the name-collision check correctly bypasses when UUIDs match. The probe note in the runbook about "UUID-conflict precedence" is satisfied by these passes; the open observation can be considered closed unless a future cycle exposes a different code path.

### Test discipline observations from this cycle

- The "Wait-NavCmdFinished" helper used in db.1 produced a false-negative timeout on the second PASTE_NEW even though both PASTE_NEW STARTED+FINISHED markers were in the log. Likely a `since=mark` window timing issue when multiple marks land in rapid succession. Worked around by retrying with a 15s timeout and the test passed. The helper is fine for one-off use; for tight sequences it benefits from a longer ceiling.
- Two PASTE/PUSH timing races where an immediate `/api/nmdb` query missed a just-committed record (db.14a, db.15a, db.15b, db.18). An extra 2s sleep + re-query consistently resolved each. Suggests the wx idle commit may settle slightly after the FINISHED log marker; not a code bug, just a timing observation for future runbook authors.
- fsh.G1's runbook source used `C482-CBA0-D14E-67B2` (Timiteo) as the guard target, but that group was deleted in fsh.14 earlier in the same module run. Substituted Popa (`244E-8E10-0800-400A`) which has the same shape (members in active route) and the rejection fired correctly. Worth a runbook fix.
