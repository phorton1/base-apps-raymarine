# navMate Context-Menu Test Run — Cycle 5

**Date:** 2026-05-04
**Start:** ~23:36
**End:** ~late night (same day)
**Cycle:** 5 (full §1 + §3.0–§3.7 + §5.1–§5.4; §2 and §3.8–§3.11 accepted from prior Cycle 5 session)

---

## Summary

- **§2 (database tests 2.1–2.13):** ALL PASS (carried from earlier Cycle 5 session, 2026-05-04)
- **§3.0–§3.7 (E80 populate + all-paste):** ALL PASS (clean §3.7 run — fix confirmed)
- **§3.8–§3.11 (Paste New + multi-select):** ALL PASS (carried from Cycle 4 / prior Cycle 5 session)
- **§4 (track tests):** SKIP (teensyBoat required)
- **§5.1–§5.4 (guard tests):** ALL PASS (§5.4 now PASS — Item 10 fix applied)

---

## Code Changes This Cycle

### Item 10 fix — §5.4 doPaste guard (nmOps.pm)

| File | Change |
|------|--------|
| `apps/navMate/nmOps.pm` | Added explicit guard at top of E80 branch in `doPaste`: blocks `cut=1 && source=database` with IMPLEMENTATION ERROR warning and returns without executing |

### Threading race fix — queueWPMGRCommand / commandThread

Crash: `Thread 9 terminated abnormally: Invalid value for shared scalar at d_WPMGR.pm line 127`

Root cause: Thread 9 (b_sock/sockThread) iterates `command_queue` for duplicate-check while Thread 10 (commandThread) concurrently calls `shift` on the same shared array — no lock anywhere. The shared array's internal iterator state is clobbered mid-FETCH.

| File | Change |
|------|--------|
| `NET/d_WPMGR.pm init()` | Added `$this->{queue_lock} = &threads::shared::share({})` — per-instance shared hash used as a lock target |
| `NET/d_WPMGR.pm queueWPMGRCommand()` | Added `lock(%{$this->{queue_lock}})` after pre-flight checks; held for duration of function (duplicate-check loop through enqueue, both `$front` paths) |
| `NET/b_sock.pm commandThread()` | Wrapped check + `shift` in narrow inner block with `lock(%{$this->{queue_lock}}) if $this->{queue_lock}`; lock released before `handleCommand` is called. Non-WPMGR services (no `queue_lock`) unaffected |

---

## §3.7 Clean Run

§3.7 was the outstanding failure from Cycle 4 (singleton bug) and the dirty-state re-run from early Cycle 5 (Agua name conflict). With the singleton fix already in place, this cycle provided the clean run: fresh §1 reset → §3.0–§3.6 → §3.7.

**Verified:** Navigation/Routes branch (ac4e2c500600b9aa) — Agua group (204ecbd24500a678),
Michelle group (104e199a1500e646), Popa group (244e8e100800400a) all present on E80;
Agua route (d64e8c7e4400a186) and Michelle route (3b4e87f21400d81c) present;
E80 wps=77 groups=4 routes=3; no duplicate WP UUIDs.

---

## §5 Guard Tests

| Test | Result | Notes |
|------|--------|-------|
| §5.1 DEL-WP blocked (WP in route) | PASS | IMPLEMENTATION ERROR warning; Popa0 314e56cc09005332 still in DB |
| §5.2 D-CP-TK → DB paste blocked | PASS | IMPLEMENTATION ERROR warning; UUID-preserving DB-to-DB track copy blocked |
| §5.3 Any clipboard → E80 header:tracks | PASS | PASTE ran but no WP added; E80 wps count unchanged at 77 |
| §5.4 D-CT-DB → E80 blocked | PASS | Item 10 guard fires: IMPLEMENTATION ERROR logged; Popa0 still in DB; E80 unchanged |

---

## Full Test Results

| Section | Description | Result | Notes |
|---------|-------------|--------|-------|
| §1 | Reset (git revert, reload, clear E80) | PASS | Threading crash on first attempt (race in queueWPMGRCommand); fixed and re-run |
| §2.1–§2.13 | Database tests | PASS | Carried from earlier Cycle 5 session same day |
| §3.0 | Populate E80 (WP + group + route) | PASS | Waypoint 5, Michel_Agua, Popa route; all retained DB UUIDs |
| §3.1 | E-CP-WP → Paste DB (UUID-preserving) | PASS | |
| §3.2 | E-CP-WP → Paste New DB (fresh UUID) | PASS | |
| §3.3 | E-DEL-WP | PASS | wps=21 after delete |
| §3.4 | E-DEL-GR+WPS | PASS | First clean run post-locking-fix; no crash during MOD flood |
| §3.5 | E-CP-GR → Paste DB | PASS | |
| §3.6 | E-CP-RT → Paste DB | PASS | |
| §3.7 | D-CP-ALL → E80 root (large batch) | PASS | Clean run; singleton fix validated; no errors; no_change for Popa WPs |
| §3.8–§3.11 | Paste New WP/GR/RT + multi-select WPs | PASS | Carried from prior sessions; §3.11 fix (Item 9) confirmed from Cycle 5 earlier session |
| §4 | Track tests (teensyBoat) | SKIP | |
| §5.1 | Guard: DEL-WP blocked (WP in route) | PASS | |
| §5.2 | Guard: D-CP-TK → DB Paste blocked | PASS | |
| §5.3 | Guard: any clipboard → E80 header:tracks | PASS | |
| §5.4 | Guard: D-CT-DB → E80 blocked | PASS | Item 10 fix working |

---

## Open Items After This Cycle

### Item 11 — DB WP deletion timing at cut (design decision)

Still deferred. The exact cut-path behavior for route-member WPs at cut time (delete-at-cut vs delete-at-paste vs never-delete) remains undecided. See Cycle 4 last_testrun.md for details.

### Color Test D — pending

From the separate color boundary test session (2026-05-04). Tests A/B/C confirmed route/WP color round-trip (E80↔DB). Test D (track E80→DB) requires teensyBoat — deferred with §4.
