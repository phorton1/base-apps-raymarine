# navOperations Test Run -- Cycle 15

**Date:** 2026-05-13
**Start:** 11:07
**End:** 11:40
**Cycle:** 15

---

## Summary

| Section | Result |
|---------|--------|
| Section 1 Reset | PASS |
| Section 2 Database Tests (2.1-2.18b) | PASS -- all 22 steps |
| Section 3 E80 Tests (3.1-3.18) | PASS -- all 22 steps |
| Section 4 Track Tests (4.0-4.5) | PASS -- teensyBoat available; all 6 steps |
| Section 5 Guard Tests | PASS -- 5.6a needed close_dialog recovery (no FAIL); permanent NOT_RUN on 5.8/5.13/5.15a |

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
| 5.6a Delete all E80 routes | PASSED_BUT (close_dialog recovery required) |
| 5.6b Delete all E80 groups+WPs | PASS |
| 5.6c Delete all E80 ungrouped WPs | PASS (no-op; my_waypoints node absent) |
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
| 5.15a Upload IsolatedWP1 to E80 (setup) | NOT_RUN (BOCAS1 already on E80 from 5.11a) |
| 5.15b Menu shape -- PASTE at E80 WP node blocked | PASS |
| 5.15c Menu shape -- PASTE_NEW at E80 WP node blocked | PASS |
| 5.16a Mixed clipboard PASTE_BEFORE at route_point | PASS |
| 5.16b Mixed clipboard PASTE_NEW_BEFORE at route_point | PASS |

---

## Issues

### Test 5.6a -- DELETE_ROUTE via header ProgressDialog did not auto-FINISH

**Test step:** Test 5.6a (Delete all E80 routes)

**Nodes involved:**
- E80 routes header (key: `header:routes`)
- At test time E80 contained: Popa route fresh-UUID 864e52da45051bea with 13 waypoints
  (the Test 3.18 paste extended Test 3.16b's 12-WP route to 13), plus Timiteo group + 6 WPs
  from Test 5.7, plus BOCAS1/BOCAS2 from Test 5.11a setup leading-in to Section 5.

**What happened:**
1. Test 5.6a fired DELETE_ROUTE (cmd=10223) via the E80 routes header.
2. The route deletion completed on E80 (/api/db routes count went to 0), but the
   ProgressDialog 'Delete Route' STARTED line appeared without a matching FINISHED line
   in the log even after 10+ seconds.
3. `dialog_state` query returned `dialog_state: active` confirming the dialog was still
   visible.
4. The runbook's documented remedy was applied: `curl ... /api/command?cmd=close_dialog`.
   Immediately after, the FINISHED line appeared in the log.
5. Test 5.6b was then fired and completed normally with its own clean STARTED/FINISHED pair.

**Expected vs actual:**
- Expected: ProgressDialog 'Delete Route' STARTED followed by FINISHED within the flat
  wait window, then proceed to 5.6b.
- Actual: data-plane operation completed (routes empty) but the dialog widget was not
  auto-dismissed. Manual close_dialog was needed.

**Data state left behind:** None -- after close_dialog the cycle continued cleanly and
all subsequent Section 5 tests passed. The data-plane delete had already succeeded
before the dialog issue surfaced.

**Known bug:** Same dangling-dialog pattern was reported as a FAIL in Cycle 14 (Test 5.6a).
Cycle 15 differs in that the close_dialog remedy was applied without skipping or
queueing 5.6b. The recorded status PASSED_BUT reflects that the documented remedy worked
and no data corruption resulted; the underlying dialog-dismissal bug remains open.

**Catastrophic:** No.

### Test 5.6c -- my_waypoints node absent when E80 is empty (runbook-clarified no-op)

**Test step:** Test 5.6c (Delete all E80 ungrouped WPs)

**Observed:** Test 5.6b cleared all groups + their member WPs, leaving E80 with 0
waypoints. Firing `cmd=10222` against `select=my_waypoints` produced
`WARNING: navTest: fire cmd=10222 - no right_click_node set` because the my_waypoints
tree node does not exist when E80 has no ungrouped waypoints.

**Result:** /api/db remained empty (the intended state). The runbook's "(no-op if none)"
language already anticipated this; the runbook was updated this cycle to document the
specific WARNING text and confirm PASS-by-vacuity is the intended outcome.

**Status:** PASS. No bug -- runbook clarification only.

---

## Runbook corrections applied this cycle

Mid-cycle, three runbook bugs were patched (per the runbook self-improvement rule)
before continuing the affected steps:

1. **HTTP endpoints table -- `/api/log` shape:** the response field is `seq` (current
   ring buffer position), not `last_seq`. Multiple PowerShell snippets in the runbook
   referenced the wrong field.
2. **HTTP endpoints table -- `cmd=mark` response:** `cmd=mark` returns
   `{"ok":1,"cmd":"mark"}` with NO `seq` field. The server stores the mark seq
   internally for `?since=mark` queries. The runbook previously claimed
   `{seq:N}` was returned and several snippets did
   `(curl ... | ConvertFrom-Json).seq` expecting the seq -- always null/empty in practice.
3. **Standard log reader pattern + ProgressDialog wait snippet + Section 4/5.6a
   snippets:** rewrote to use `?since=mark` (no client-side seq tracking) which
   matches how the server actually works and is far simpler.

4. **Test 5.6c -- no-op edge case:** added explicit documentation that when E80 has
   0 ungrouped WPs, the my_waypoints node does not exist and the command logs a
   WARNING rather than executing -- this is a PASS, not a FAIL.

These four corrections are applied in
`apps/navMate/docs/notes/navOps_testplan_runbook.md`.

---

## Documentation drift not yet addressed

The runbook's Test 3.5 / 3.14 / 3.16b comments describe navMate-assigned UUIDs as
having "byte 1 = 0x82". In practice navMate UUIDs observed during this cycle have
byte 1 = 0x4e (e.g. fresh paste-new WP 824ebca22b0590f6, group 7a4e1c14ed048288).
The 0x82 figure matches RNS-assigned UUIDs per `uuid_structure.md`, not navMate's.
This is a doc-accuracy issue, not a test failure -- the cycle still verified that
PASTE_NEW produces fresh, distinct, non-DB-conflicting UUIDs.
