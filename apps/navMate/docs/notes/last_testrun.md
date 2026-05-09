# nmOperations Test Run -- Cycle 10

**Date:** 2026-05-09
**Start:** ~23:00 (approximate; §1/§2 completed in prior session before context compaction)
**End:** 2026-05-09 02:41
**Tester:** Patrick Horton

---

## Summary

| Section | Result | Notes |
|---------|--------|-------|
| §1 Reset | PASS | DB reverted; E80 cleared; suppress enabled |
| §2 Database Tests | PASS | All 18 steps pass |
| §3 E80 Tests | PARTIAL | 17 PASS, 1 PASSED_BUT, 1 FAIL |
| §4 Track Tests | PASS | All 5 steps pass |
| §5 Pre-flight and Guard Tests | PARTIAL | 10 PASS, 3 PASSED_BUT, 1 FAIL, 2 NOT_RUN |

---

## Results

### §1 Reset to Known State

| Step | Status |
|------|--------|
| §1 Reset | PASS |

### §2 Database Tests

| Step | Status |
|------|--------|
| §2.1 Copy WP -> Paste New | PASS |
| §2.2 Cut WP -> Paste (move) | PASS |
| §2.3 Delete WP | PASS |
| §2.4 Dissolve group (DEL_GROUP) | PASS |
| §2.5 Delete group + WPs (DEL_GROUP_WPS) | PASS |
| §2.6 Delete group blocked -- WP in route | PASS |
| §2.7 Delete safe branch | PASS |
| §2.8 Copy branch -> Paste New | PASS |
| §2.9 Cut branch -> Paste (move) | PASS |
| §2.10 Copy route -> Paste New | PASS |
| §2.11 Cut route -> Paste (move) | PASS |
| §2.12 Cut track -> Paste (move) | PASS |
| §2.13 Copy route point -> Paste New | PASS |
| §2.14 Cut route point -> Paste (move) | PASS |
| §2.15 Paste Before/After -- route object as anchor | PASS |
| §2.16 Paste Before/After -- group node as anchor | PASS |
| §2.17 Paste Before/After -- branch node as anchor | PASS |
| §2.18 Paste Before/After -- non-waypoint item in clipboard | PASS |

### §3 E80 Tests

| Step | Status |
|------|--------|
| §3.1 Paste WP to E80 (UUID-preserving upload) | PASS |
| §3.2 Paste Group to E80 (UUID-preserving upload) | PASS |
| §3.3 Paste Route to E80 (UUID-preserving upload) | PASS |
| §3.4 Copy E80 WP -> Paste to DB | PASS |
| §3.5 Copy E80 WP -> Paste New to DB | PASS |
| §3.6 Delete E80 WP | PASS |
| §3.7 Delete via E80 Routes header | PASS |
| §3.8 Delete via E80 Groups header | PASS |
| §3.9 Delete E80 Group + members | PASS |
| §3.10 Delete via E80 My Waypoints | PASS |
| §3.11 Delete via E80 Tracks header | FAIL |
| §3.12 Copy E80 Group -> Paste to DB | PASS |
| §3.13 Copy E80 Route -> Paste to DB | PASS |
| §3.14 Copy E80 Group+Route -> Paste to DB (ordered heterogeneous) | PASS |
| §3.15 Paste New WP to E80 (fresh UUID) | PASS |
| §3.16 Paste New Group to E80 (all-fresh UUIDs) | PASS |
| §3.17 Paste New Route to E80 (fresh route UUID, WP refs preserved) | PASS |
| §3.18 Multi-select WPs -> Paste to E80 | PASS |
| §3.19 Route point Paste Before/After on E80 | PASSED_BUT |

### §4 Track Tests

| Step | Status |
|------|--------|
| §4.0 Create test tracks on E80 | PASS |
| §4.1 Copy E80 Track -> Paste to DB | PASS |
| §4.2 Cut E80 Track -> Paste to DB | PASS |
| §4.3 Guard -- Paste Track to E80 blocked (SS10.8) | PASS |
| §4.4 Paste New E80 Track to DB | PASS |

### §5 Pre-flight and Guard Tests

| Step | Status |
|------|--------|
| §5.1 DEL_WAYPOINT blocked -- WP referenced in route | PASS |
| §5.2 DEL_BRANCH blocked -- member WP in external route | PASS |
| §5.3 Paste blocked -- DB cut -> E80 destination | PASS |
| §5.4 Paste blocked -- any clipboard -> E80 tracks header | PASSED_BUT |
| §5.5 Paste blocked -- DB copy track -> DB paste | PASS |
| §5.6 Route dependency check -- paste route before WPs exist on E80 | PASS |
| §5.7 Ancestor-wins -- accept path | PASS |
| §5.8 Ancestor-wins -- abort path | NOT_RUN |
| §5.9 Recursive paste guard -- paste Branch into own descendant | FAIL |
| §5.10 Pre-flight: intra-clipboard name collision | PASS |
| §5.11 Pre-flight: E80-wide name collision | PASS |
| §5.12 UUID conflict -- clean create path | PASS |
| §5.13 UUID conflict -- conflict dialog path | NOT_RUN |
| §5.14 Menu shape -- DB object node: PASTE and PASTE_NEW absent | PASS |
| §5.15 Menu shape -- E80 WP node: all paste items absent | PASSED_BUT |
| §5.16 Menu shape -- route_point with mixed clipboard | PASSED_BUT |

---

## Issues

### §3.11 FAIL -- DELETE_TRACK via E80 Tracks header sends empty UUID

**Observed:** Fired DELETE_TRACK (cmd=10440) on E80 Tracks header (select=header:tracks).
Log: `queueTRACKCommand(4=GENERAL_COMMAND) uuid() extra(erase)` with EMPTY uuid.
Followed by `ERROR - do_general: no uuid`. Tracks on E80 unchanged.

**Analysis:** The E80 tracks header delete path does not iterate track UUIDs the way group/route
header deletes iterate their members. It fires a single GENERAL_COMMAND with no UUID, which fails
the uuid-required check. The route and group header deletes call `_deleteE80GroupsAndWPs` and
`_deleteRoutes` which loop over E80 members; the track header path needs similar iteration.

**Data state:** E80 tracks unchanged. Non-catastrophic. Test was retried after §4.0 (when tracks
were present); confirmed same failure mode.

---

### §3.19 PASSED_BUT -- E80 route_point PASTE_BEFORE succeeded but required Popa2 workaround

**Observed:** Initial COPY of RP1 (Popa0, 314e56cc09005332) captured 2 items because Popa0 appears
twice in the fresh-UUID route from §3.17 due to §2.14 copy-splice operations. Pre-flight fired
"Clipboard contains duplicate route_point name 'Popa0' -- aborting". Workaround: used Popa2
(454e11a80b002884, which is unique in the route) as source. PASTE_BEFORE Popa3 succeeded; route
count 12->13.

**Analysis:** The Popa0 duplication is a side effect of §2.14 cut-and-splice operations in the
ORIGINAL Popa route. The fresh-UUID route from §3.17 inherits this duplication. PASTE_BEFORE
itself works correctly; the workaround was required to avoid the pre-flight name collision.

**Data state:** Fresh-UUID route has 13 WPs after the paste. Non-catastrophic.

---

### §4.3 PASS -- Improvement from Cycle 9

Cycle 9 §4.3 was PASSED_BUT (SS10.8 guard fired silently). Cycle 10: IMPLEMENTATION ERROR logged
explicitly ("_pasteE80: tracks destination reached paste handler (SS10.8)"). Full PASS.

---

### §4.4 PASS -- Runbook clarification

Runbook updated: E80->DB PASTE_NEW of track is ALLOWED (SS10.3 only blocks DB->DB track copy).
Cycle 9 §4.4 was FAIL because the test expected the operation to be blocked. Cycle 10 correctly
treats it as PASS. New track created in DST with fresh UUID; track still on E80.

---

### §5.4 PASSED_BUT -- Name collision fires before SS10.8 check

**Observed:** COPY [IsolatedWP1] (BOCAS1) to clipboard; PASTE to E80 tracks header.
Result: `ERROR - E80 already has a waypoint named 'BOCAS1' -- aborting`. E80 tracks unchanged.

**Analysis:** BOCAS1 was on E80 (from §5.11 setup). The E80-wide name collision guard fires
before the SS10.8 (tracks-destination) guard is reached. The operation IS correctly rejected;
SS10.8 was independently confirmed in §4.3.

**Data state:** E80 unchanged. Non-catastrophic.

---

### §5.9 FAIL -- Recursive paste guard not triggered; DB corrupted

**Observed:** [NestedBranch] = MandalaLogs (234e412e3104296e). [ChildBranch] = MandalaLogs/Tracks
(984e7898480427f6). Pasted [NestedBranch] into [ChildBranch] with PASTE_NEW. No WARNING produced.
Operation succeeded; new MandalaLogs (UUID 684e521aea0463ee) created inside MandalaLogs/Tracks,
creating a cycle in the DB tree.

**Analysis:** Same root cause as Cycle 9. The recursive paste guard in nmOps.pm/_doPaste is not
detecting the ancestor relationship. Guard likely checks if destination UUID equals source UUID
but does not walk the ancestor chain.

**Data state:** DB has unintended cycle: 684e521aea0463ee is inside 984e7898480427f6, which is
inside 234e412e3104296e (the pasted content). DB corrupted at this subtree. Non-catastrophic for
remaining §5 steps. Revert DB before Cycle 11.

---

### §5.15 PASSED_BUT -- E80 WP node paste rejected by wrong guard

**Observed:** COPY [IsolatedWP1] (BOCAS1, ce4e43181f01b3ae) to clipboard. BOCAS1 was on E80 with
same UUID. Fired PASTE and PASTE_NEW at the E80 WP node directly.
Result both times: `ERROR - Cannot paste: destination is a descendant of an item in the clipboard`.
E80 unchanged.

**Analysis:** The UUID-match/descendant guard fires before the "individual waypoint node
destination" IMPLEMENTATION ERROR guard. The paste is correctly rejected (E80 unchanged), but
with a different message than the runbook expects.

**Data state:** E80 unchanged. Non-catastrophic.

---

### §5.16 PASSED_BUT -- PASTE_BEFORE blocked (PASS); PASTE_NEW_BEFORE count off by 1

**Observed (PASTE_BEFORE sub-test -- PASS):** Loaded mixed clipboard (rp:[TestRoute]:[RP1] +
[IsolatedWP1]). COPY captured 3 items (Popa0 appears twice in route). Fired PASTE_BEFORE at RP2.
Result: `IMPLEMENTATION ERROR: _pasteDB: PASTE_BEFORE/AFTER route_point: clipboard has
non-route_point items`. Route unchanged at 12. Guard correctly blocks mixed-clipboard PASTE_BEFORE.

**Observed (PASTE_NEW_BEFORE sub-test -- PASSED_BUT):** Same mixed clipboard; fired PASTE_NEW_BEFORE
at RP2. Clipboard contained 2 Popa0 route_point items + 1 IsolatedWP1 WP item. PASTE_NEW_BEFORE
filtered IsolatedWP1 correctly but processed BOTH Popa0 items, inserting 2 new entries. Count
went 12->14 instead of expected 12->13.

**Analysis:** The Popa0 duplication (Popa0 at pos=0 and pos=3, from §2.14 operations) causes the
multi-select to capture 2 route_point clipboard items for RP1. PASTE_NEW_BEFORE processes all
route_point items in clipboard, so both Popa0 entries are inserted. This is technically correct
behavior given the clipboard state; the +2 is a side effect of Popa0 duplication, not a bug in
the guard logic. The critical guard (PASTE_BEFORE rejection) is confirmed working.

**Data state:** TestRoute has 14 route_waypoints (was 12). Non-catastrophic.
