# navOperations Test Run -- Cycle 17

**Date:** 2026-05-13
**Start:** 21:17
**End:** 21:56
**Cycle:** 17

---

## Summary

| Section | Result |
|---------|--------|
| Section 1 Reset | PASS |
| Section 2 Database Tests (2.0-2.18b) | PASS -- all 23 steps (including Test 2.0 32-iteration precision loop) |
| Section 3 E80 Tests (3.1-3.18) | PASS -- all 22 steps |
| Section 4 Track Tests (4.0-4.5) | PASS -- teensyBoat available; all 6 steps |
| Section 5 Guard Tests | PASS -- all runnable steps |

**Second consecutive clean cycle.** Only NOT_RUN is the single structural blocker `5.13 NOT_RUN (db_versioning)`.

---

## Results Table

| Test | Status |
|------|--------|
| **Section 1** | |
| Reset (revert DB, reload, suppress, clear E80) | PASS |
| **Section 2** | |
| 2.0 Position precision -- 32 bisections force auto-renumber | PASS (loop_inserts=32, total=34, distinct_positions=34, AutoCompact_seen=YES) |
| 2.1 Copy WP -> Paste New | PASS |
| 2.2 Cut WP -> Paste (move) | PASS |
| 2.3 Delete WP (success) | PASS |
| 2.4 Delete Group -- dissolve | PASS |
| 2.5 Delete Group+WPS -- success | PASS |
| 2.6 Delete Group+WPS -- blocked (in route) | PASS |
| 2.7 Delete Branch (recursive, safe) | PASS |
| 2.8 Copy Branch -> Paste New | PASS |
| 2.9 Cut Branch -> Paste (move) | PASS |
| 2.10 Copy Route -> Paste New | PASS |
| 2.11 Cut Route -> Paste (move) | PASS |
| 2.12 Cut Track -> Paste (move) | PASS |
| 2.13a Paste New Before -- collection member | PASS |
| 2.13b Paste New After -- collection member | PASS |
| 2.14a Copy-splice -- PASTE_NEW_BEFORE route point | PASS |
| 2.14b Cut-splice -- PASTE_BEFORE route point | PASS |
| 2.15a Paste New Before -- route object as anchor | PASS |
| 2.15b Paste New After -- route object as anchor | PASS |
| 2.16 Paste Before/After -- group node as anchor | PASS |
| 2.17 Paste Before/After -- branch node as anchor | PASS |
| 2.18a Paste New Before -- route clipboard before WP anchor | PASS |
| 2.18b Paste New Before -- group clipboard before WP anchor | PASS |
| **Section 3** | |
| 3.1 Paste WP to E80 (UUID-preserving) | PASS |
| 3.2 Paste Group to E80 (UUID-preserving) | PASS |
| 3.3 Paste Route to E80 (UUID-preserving) | PASS |
| 3.4 Copy E80 WP -> Push to DB | PASS |
| 3.5 Copy E80 WP -> Paste New to DB (fresh UUID) | PASS |
| 3.6 Delete E80 WP | PASS |
| 3.6b Delete E80 Group+WPS -- blocked (member in route) | PASS |
| 3.7 Delete E80 Routes header (all routes) | PASS |
| 3.8 Delete E80 Groups header (all groups) | PASS |
| 3.9a Re-upload Popa group to E80 | PASS |
| 3.9b Delete E80 Group+members via specific node | PASS |
| 3.10a Re-upload IsolatedWP1 to E80 | PASS |
| 3.10b Delete E80 My Waypoints (all ungrouped) | PASS |
| 3.11a Re-upload Popa group to E80 | PASS |
| 3.11b Copy E80 Group -> Push to DB | PASS |
| 3.12a Re-upload TestRoute to E80 | PASS |
| 3.12b Copy E80 Route -> Push to DB | PASS |
| 3.13 Copy E80 Group+Route -> Push to DB (multi-item) | PASS |
| 3.14 Paste New WP to E80 (fresh UUID) | PASS |
| 3.14b Copy E80 fresh-UUID WP -> Paste to DB | PASS |
| 3.14c Mixed-classified E80 clipboard: PASTE_NEW | PASS |
| 3.15 Paste New Group to E80 (all-fresh UUIDs) | PASS |
| 3.16a Delete all E80 routes (if present) | PASS |
| 3.16b Paste New Route to E80 (fresh route UUID) | PASS |
| 3.17 Multi-select WPs -> Paste to E80 | PASS |
| 3.18 Route point Paste Before/After on E80 | PASS |
| **Section 4** | |
| 4 Pre-Check teensyBoat availability | PASS (available) |
| 4.0 Create test tracks on E80 | PASS (Track1=81b266af40007847, Track2=81b266af40008647) |
| 4.1 Copy E80 Track -> Paste to DB | PASS |
| 4.2 Cut E80 Track -> Paste to DB (erase) | PASS |
| 4.3 Guard -- Paste Track to E80 blocked | PASS |
| 4.4 Paste New E80 Track to DB (fresh UUID) | PASS |
| 4.5 Delete E80 Tracks header | PASS |
| **Section 5** | |
| 5.1 DEL_WAYPOINT blocked -- WP in route | PASS |
| 5.2 DEL_BRANCH blocked -- member in external route | PASS |
| 5.3 Paste blocked -- DB cut -> E80 destination | PASS |
| 5.4a Delete BOCAS1 from E80 (setup) | PASS |
| 5.4b Delete BOCAS2 from E80 (setup) | PASS |
| 5.4c Paste blocked -- any clipboard -> E80 tracks header | PASS |
| 5.5 Paste blocked -- DB copy track -> DB paste | PASS |
| 5.6a Delete all E80 routes | PASS |
| 5.6b Delete all E80 groups+WPs | PASS |
| 5.6c Delete all E80 ungrouped WPs | PASS (no-op as documented; E80 already empty) |
| 5.6d Route dependency check (SS10.10) | PASS |
| 5.7 Ancestor-wins -- accept path | PASS |
| 5.8 Ancestor-wins -- abort path | PASS (reject-path signature confirmed: PASTE NEW STARTED/FINISHED adjacent, no ProgressDialog, no ERROR) |
| 5.9 Recursive paste guard | PASS |
| 5.10 Pre-flight: intra-clipboard name collision | PASS (used Popa2 duplicate pair) |
| 5.11a Upload IsolatedWP1 to E80 (setup) | PASS |
| 5.11b Pre-flight: E80-wide name collision | PASS |
| 5.12 UUID conflict -- clean create path | PASS (direct verification via [IsolatedWP2]) |
| 5.13 UUID conflict -- conflict dialog path | NOT_RUN (db_versioning) |
| 5.14a Menu shape -- PASTE at DB WP node blocked | PASS |
| 5.14b Menu shape -- PASTE_NEW at DB WP node blocked | PASS |
| 5.14c Menu shape -- PASTE at DB route node blocked | PASS |
| 5.14d Menu shape -- PASTE at DB track node blocked | PASS |
| 5.15a Upload IsolatedWP1 to E80 (setup) | PASS (postcondition already met from 5.11a) |
| 5.15b Menu shape -- PASTE at E80 WP node blocked | PASS |
| 5.15c Menu shape -- PASTE_NEW at E80 WP node blocked | PASS |
| 5.16a Mixed clipboard PASTE_BEFORE at route_point | PASS (route count +3, matches actual clipboard items=3) |
| 5.16b Mixed clipboard PASTE_NEW_BEFORE at route_point | PASS (route count +5, matches clipboard items=5) |

---

## Issues

none

---

## Runbook adjustments applied mid-cycle

- **Run tests inline rule.** Added explicit "Rule: run tests inline, not via scripts" to the Toolbox after Patrick objected to writing a standalone PowerShell script in `$temp_dir` for Test 2.0. The rule clarifies that embedded PowerShell snippets in the runbook (Test 2.0's loop, Wait-NavCmdFinished helper) are acceptable as single-tool-call paste-ins, but fresh scripts in temp folders are not. Existing "Rule: new tools" was also tightened to reference `$temp_dir` explicitly.
- **Test 5.16a clipboard-count expectation.** Updated the test's note to acknowledge that the rp:f34efdd6070022e8:Popa0 selection matches BOTH Popa0 instances in [TestRoute] (Popa0 appears twice after Test 2.14a), so COPY reports 3 items (not 2) and the route gains 3 entries. The "Route count increases by clipboard item count" rule still holds; the prior prose example understated the clipboard size.

## Notable confirmations this cycle

- **Test 2.0 first full pass on a fresh cycle.** Previous testrun was the introduction of Test 2.0. Cycle 17 confirms loop_inserts=32, total=34, distinct_positions=34, AutoCompact warning fired -- all three pass criteria met.
- **Two consecutive all-PASS cycles.** Cycle 16 and now Cycle 17 both clean, with the single structural NOT_RUN (`5.13 db_versioning`) being a known prerequisite gap, not a regression.
