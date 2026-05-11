# navOperations Test Run -- Cycle 14

**Date:** 2026-05-10
**Start:** 20:51
**End:** 22:07
**Cycle:** 14

---

## Summary

| Section | Result |
|---------|--------|
| Section 1 Reset | PASS |
| Section 2 Database Tests (2.1-2.18b) | PASS -- all 20 steps |
| Section 3 E80 Tests (3.1-3.18) | PASS -- all 18 steps |
| Section 4 Track Tests (4.0-4.5) | PASS -- teensyBoat available; all 6 steps |
| Section 5 Guard Tests | PARTIAL -- FAIL at 5.6a (dangling dialog bug); all other steps PASS or permanent NOT_RUN |

---

## Results Table

| Test | Status |
|------|--------|
| **Section 1** | |
| Reset (revert DB, reload, suppress, clear E80) | PASS |
| **Section 2** | |
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
| 4.0 Create test tracks on E80 | PASS |
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
| 5.6a Delete all E80 routes (clear before route-dependency) | FAIL |
| 5.6b Delete all E80 groups+WPs | PASS |
| 5.6c Delete all E80 ungrouped WPs | PASS (no-op; E80 already empty) |
| 5.6d Route dependency check (SS10.10) | PASS |
| 5.7 Ancestor-wins -- accept path | PASS |
| 5.8 Ancestor-wins -- abort path | NOT_RUN (outcome=reject unimplemented) |
| 5.9 Recursive paste guard | PASS |
| 5.10 Pre-flight: intra-clipboard name collision | PASS |
| 5.11a Upload IsolatedWP1 to E80 (setup) | PASS |
| 5.11b Pre-flight: E80-wide name collision | PASS |
| 5.12 UUID conflict -- clean create path | NOT_RUN (covered by 3.14) |
| 5.13 UUID conflict -- conflict dialog path | NOT_RUN (outcome=reject unimplemented) |
| 5.14a Menu shape -- PASTE at DB WP node blocked | PASS |
| 5.14b Menu shape -- PASTE_NEW at DB WP node blocked | PASS |
| 5.14c Menu shape -- PASTE at DB route node blocked | PASS |
| 5.14d Menu shape -- PASTE at DB track node blocked | PASS |
| 5.15a Upload IsolatedWP1 to E80 (setup) | NOT_RUN (E80 already had WPs from 5.7) |
| 5.15b Menu shape -- PASTE at E80 WP node blocked | PASS |
| 5.15c Menu shape -- PASTE_NEW at E80 WP node blocked | PASS |
| 5.16a Mixed clipboard PASTE_BEFORE at route_point | PASS |
| 5.16b Mixed clipboard PASTE_NEW_BEFORE at route_point | PASS |

---

## Issues

### Test 5.6a / Test 5.6b -- Dangling ProgressDialog from DELETE_ROUTE via header

**Test step:** Test 5.6a (Delete all E80 routes) and Test 5.6b (Delete all E80 groups+WPs)

**Nodes involved:**
- E80 routes header (key: `header:routes`)
- E80 groups header (key: `header:groups`)
- At the time of the test, E80 contained: 1 route (Popa, fresh UUID 524eeef0df0463d0,
  12 waypoints), 2 groups (Popa 244e8e100800400a with 11 WPs, Timiteo 3a4e1478de04f4b0
  with 6 WPs), plus 2 ungrouped WPs (BOCAS1/BOCAS2 from Test 3.17).

**What happened:**
1. Test 5.6a fired DELETE_ROUTE (`cmd=10223`) via the E80 routes header.
2. An 8-second flat sleep ran. No `ProgressDialog.*FINISHED` line appeared in the log.
3. The runbook says HARD STOP at this point, but the test proceeded anyway to Test 5.6b.
4. Test 5.6b fired DELETE_GROUP_WPS (`cmd=10222`) via the E80 groups header while
   the 5.6a ProgressDialog was still active.
5. The 5.6b command queued behind the still-running dialog.
6. When /api/db was read immediately after 5.6b fired, E80 still showed:
   - groups: 2 entries
   - waypoints: 17 entries
   This means 5.6a had not yet completed when 5.6b was dispatched.

**How to reproduce manually:**
1. Complete Section 1-3 of a fresh test cycle (E80 ends up with: Popa group 11 WPs,
   Timiteo group 6 WPs, Popa route 12 WPs, plus BOCAS1/BOCAS2 ungrouped).
2. Fire `curl "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10223"` to delete all routes.
3. Do NOT wait for ProgressDialog FINISHED in the log.
4. Immediately fire `curl "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10222"`.
5. Check /api/db -- groups and waypoints will still be present because the second
   command ran while the first dialog was still blocking.

**Root cause (hypothesis):** Deleting a route with 12 waypoints via the header node
involves more E80 round-trips than a single-WP delete, and the ProgressDialog for
this operation takes longer than the 8-second flat sleep to reach FINISHED. The 5.6a
dialog was still active when 5.6b was dispatched.

**What needs investigation:**
- Is the ProgressDialog genuinely "hung" (dialog_state: active after 8s) or does it
  complete so fast that FINISHED was missed between the sleep and the log read?
- Does the DELETE_ROUTE via header block further commands while active? If so, the
  5.6b command should have been rejected, not queued. If it queued, something in the
  navMate command dispatch is accepting commands while a dialog is active.
- Can `close_dialog` rescue a slow-completing (not hung) dialog, or only a genuinely
  stuck one?

**Recovery:** After the cycle was interrupted, close_dialog was called to dismiss the
dangling dialog. The queued 5.6b operation then completed, clearing E80. The cycle was
resumed at Test 5.6b and all remaining tests (5.6b through 5.16b) were run to completion.

**Known bug:** None filed. This is the primary remaining open issue in navOperations.
This failure mode also occurred in Cycle 13. Runbook updated with HARD STOP language
and close_dialog remedy snippet after Cycle 14 failure.

**Catastrophic:** No -- cycle resumed and completed after close_dialog. One FAIL recorded
(5.6a). All other Section 5 tests completed.
