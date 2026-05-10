# navOperations Test Run -- Cycle 11

**Date:** 2026-05-09
**Start:** unknown (lost in context compaction -- session spans two Claude conversations)
**End:** 2026-05-09
**Tester:** Patrick Horton

---

## Summary

| Section | Result | Notes |
|---------|--------|-------|
| Section 1 Reset | PASS | DB reverted; E80 cleared; suppress enabled |
| Section 2 Database Tests | PASS | All 18 tests pass |
| Section 3 E80 Tests | PASS | All 26 tests pass |
| Section 4 Track Tests | PARTIAL | 4 PASS, 2 FAIL |
| Section 5 Pre-flight and Guard Tests | PARTIAL | 24 PASS, 1 PASSED_BUT, 3 NOT_RUN |

---

## Results

### Section 1 Reset to Known State

| Test | Status |
|------|--------|
| Section 1 Reset | PASS |

### Section 2 Database Tests

| Test | Status |
|------|--------|
| Section 2.1 Copy WP -> Paste New | PASS |
| Section 2.2 Cut WP -> Paste (move) | PASS |
| Section 2.3 Delete WP | PASS |
| Section 2.4 Dissolve group (DEL_GROUP) | PASS |
| Section 2.5 Delete group + WPs (DEL_GROUP_WPS) | PASS |
| Section 2.6 Delete group blocked -- WP in route | PASS |
| Section 2.7 Delete safe branch | PASS |
| Section 2.8 Copy branch -> Paste New | PASS |
| Section 2.9 Cut branch -> Paste (move) | PASS |
| Section 2.10 Copy route -> Paste New | PASS |
| Section 2.11 Cut route -> Paste (move) | PASS |
| Section 2.12 Cut track -> Paste (move) | PASS |
| Section 2.13 Copy route point -> Paste New | PASS |
| Section 2.14 Cut route point -> Paste (move) | PASS |
| Section 2.15 Paste Before/After -- route object as anchor | PASS |
| Section 2.16 Paste Before/After -- group node as anchor | PASS |
| Section 2.17 Paste Before/After -- branch node as anchor | PASS |
| Section 2.18 Paste Before/After -- non-waypoint item in clipboard | PASS |

### Section 3 E80 Tests

| Test | Status |
|------|--------|
| Section 3.1 Paste WP to E80 (UUID-preserving upload) | PASS |
| Section 3.2 Paste Group to E80 (UUID-preserving upload) | PASS |
| Section 3.3 Paste Route to E80 (UUID-preserving upload) | PASS |
| Section 3.4 Copy E80 WP -> Push to DB (push-classified) | PASS |
| Section 3.5 Copy E80 WP -> Paste New to DB (fresh UUID) | PASS |
| Section 3.6 Delete E80 WP | PASS |
| Section 3.6b Delete E80 Group+WPS -- blocked (member in route) | PASS |
| Section 3.7 Delete via E80 Routes header (all routes) | PASS |
| Section 3.8 Delete via E80 Groups header (all groups) | PASS |
| Section 3.9a Re-upload Popa group to E80 | PASS |
| Section 3.9b Delete E80 Group + members via specific group node | PASS |
| Section 3.10a Re-upload IsolatedWP1 to E80 | PASS |
| Section 3.10b Delete via E80 My Waypoints (all ungrouped WPs) | PASS |
| Section 3.11a Re-upload Popa group to E80 | PASS |
| Section 3.11b Copy E80 Group -> Sync to DB (sync-classified) | PASS |
| Section 3.12a Re-upload TestRoute to E80 | PASS |
| Section 3.12b Copy E80 Route -> Sync to DB (sync-classified) | PASS |
| Section 3.13 Copy E80 Group+Route -> Sync to DB (ordered heterogeneous) | PASS |
| Section 3.14 Paste New WP to E80 (fresh UUID) | PASS |
| Section 3.14b Copy E80 fresh-UUID WP -> Paste to DB (paste-classified: absent) | PASS |
| Section 3.14c Mixed-classified E80 clipboard: status bar + PASTE_NEW | PASS |
| Section 3.15 Paste New Group to E80 (all-fresh UUIDs) | PASS |
| Section 3.16a Delete all E80 routes (pre-step) | PASS |
| Section 3.16b Paste New Route to E80 (fresh route UUID, WP refs preserved) | PASS |
| Section 3.17 Multi-select WPs -> Paste to E80 (homogeneous flat set) | PASS |
| Section 3.18 Route point Paste Before/After on E80 | PASS |

### Section 4 Track Tests

| Test | Status |
|------|--------|
| Section 4.0 Create test tracks on E80 | PASS |
| Section 4.1 Copy E80 Track -> Paste to DB (download, track remains on E80) | FAIL |
| Section 4.2 Cut E80 Track -> Paste to DB (download + E80 erase) | FAIL |
| Section 4.3 Guard -- Paste Track to E80 blocked (SS10.8) | PASS |
| Section 4.4 Paste New E80 Track to DB (download, fresh UUID) | PASS |
| Section 4.5 Delete via E80 Tracks header -- SS8.2 | PASS |

### Section 5 Pre-flight and Guard Tests

| Test | Status |
|------|--------|
| Section 5.1 DEL_WAYPOINT blocked -- WP referenced in route | PASS |
| Section 5.2 DEL_BRANCH blocked -- member WP in external route | PASS |
| Section 5.3 Paste blocked -- DB cut -> E80 destination (SS9, SS10.5) | PASS |
| Section 5.4a Delete BOCAS1 from E80 (setup) | PASS |
| Section 5.4b Delete BOCAS2 from E80 (setup) | PASS |
| Section 5.4c Paste blocked -- any clipboard -> E80 tracks header (SS10.8) | PASSED_BUT |
| Section 5.5 Paste blocked -- DB copy track -> DB paste | PASS |
| Section 5.6a Delete all E80 routes (pre-step) | PASS |
| Section 5.6b Delete all E80 groups+WPs (pre-step) | PASS |
| Section 5.6c Delete all E80 ungrouped WPs (pre-step) | PASS |
| Section 5.6d Route dependency check -- paste route before WPs exist on E80 (SS10.10) | PASS |
| Section 5.7 Ancestor-wins -- accept path (SS6.2) | PASS |
| Section 5.8 Ancestor-wins -- abort path | NOT_RUN |
| Section 5.9 Recursive paste guard -- paste Branch into own descendant | PASS |
| Section 5.10 Pre-flight: intra-clipboard name collision (SS10.2 Step 6) | PASS |
| Section 5.11a Upload IsolatedWP1 to E80 (setup for name collision test) | PASS |
| Section 5.11b Pre-flight: E80-wide name collision (SS10.2 Step 7) | PASS |
| Section 5.12 UUID conflict -- clean create path | PASS |
| Section 5.13 UUID conflict -- conflict dialog path | NOT_RUN |
| Section 5.14a Menu shape -- PASTE at DB WP object node blocked | PASS |
| Section 5.14b Menu shape -- PASTE_NEW at DB WP object node blocked | PASS |
| Section 5.14c Menu shape -- PASTE at DB route object node blocked | PASS |
| Section 5.14d Menu shape -- PASTE at DB track object node blocked | PASS |
| Section 5.15a Upload IsolatedWP1 to E80 (setup) | NOT_RUN |
| Section 5.15b Menu shape -- PASTE at E80 WP object node blocked | PASS |
| Section 5.15c Menu shape -- PASTE_NEW at E80 WP object node blocked | PASS |
| Section 5.16a Mixed clipboard PASTE_BEFORE at route_point (SS6.4) | PASS |
| Section 5.16b Mixed clipboard PASTE_NEW_BEFORE at route_point (SS6.4) | PASS |

---

## Issues

### Section 4.1 and 4.2 FAIL -- Track UUID not preserved during E80->DB copy/cut (regression)

**Observed:** Copy E80 Track1 (UUID 81b266af3f0024fa, byte[1]=B2, E80-assigned) via COPY, then
PASTE to DB. Track appears in DB with a fresh navMate-style UUID (byte[1]=4e) instead of the
original E80 UUID. Same failure for CUT+PASTE (Test 4.2): Track2 (81b266af3f002ffa) appears in DB
with UUID f14eca5ee1048e1e.

**Analysis:** Regression: navOpsDB.pm:695-696 correctly passes uuid=>$item->{uuid} when source=e80
and !fresh, but insertTrack in navDB.pm did not honor the uuid parameter at the time the test was
run. Working-tree navDB.pm has the fix ($a{uuid} // newUUID($dbh)); needs re-test after navMate
restart to confirm.

**Data state:** DB has Track1 (084eb796e0040fb0) and Track2 (f14eca5ee1048e1e) with navMate-style
UUIDs instead of E80-style UUIDs. Non-catastrophic for remaining tests. Revert DB before Cycle 12.

---

### Section 5.4c PASSED_BUT -- Name collision fires before SS10.8 check

**Observed:** COPY [IsolatedWP1] (BOCAS1) to clipboard; PASTE to E80 tracks header.
**Result:** `ERROR - E80 already has a waypoint named 'BOCAS1' -- aborting`. E80 tracks unchanged.

**Analysis:** BOCAS1 was on E80 (from Section 5.11b setup). The E80-wide name collision guard fires
before the SS10.8 (tracks-destination) guard is reached. The operation IS correctly rejected;
SS10.8 was independently confirmed in Section 4.3.

**Data state:** E80 unchanged. Non-catastrophic.

