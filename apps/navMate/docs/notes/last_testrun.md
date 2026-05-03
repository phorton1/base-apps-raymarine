# navMate Context-Menu Test Run — Cycle 3

**Date:** 2026-05-03
**Start:** ~00:00 (estimated session start, earlier in day)
**End:** ~01:43
**Cycle:** 3 (full §1–§5, first run with Items 6+7 implemented)

---

## Summary

- **§2 (database tests 2.1–2.13):** ALL PASS
- **§3.0–§3.6 (E80 populate/single-object ops):** ALL PASS
- **§3.7 (all-paste DB→E80):** **FAIL** — ProgressDialog hung at 47/93
- **§3.8–§3.10 (Paste New to E80):** ALL PASS
- **§3.11 (multi-select WPs → E80):** **FAIL** — name conflict on Waypoint 5
- **§4.0–§4.4 (track tests):** ALL PASS
- **§5.1–§5.3 (guard tests):** ALL PASS (§5.3 has caveat — silent skip, no WARNING)
- **§5.4 (D-CT-DB→E80 blocked):** **FAIL** — guard bypass + DB WP deleted

---

## Open Items (this run only)

### Item 8 — §3.7 ProgressDialog hang

**File:** `apps/navMate/nmOpsE80.pm`

The "Paste Route Michelle total=93" ProgressDialog stalled at step 47/93. User aborted.
E80 appeared to receive all data (Michelle route c84e16b013005fb2 present on E80 after abort).
Different failure mode from Cycle 2 §3.7 (which was a name-conflict error) — Items 1+2 fixed
the name conflict but a progress-counter hang emerged for large batches.

Hypothesis: total=93 is computed as (46 WPs × 2) + 1 route. Some WPs produce `no_change`
and may not advance the counter, leaving the dialog stranded waiting for steps that never fire.

**To reproduce:**
```
# State: E80 already has Popa group WPs from §3.0 (they become no_change in this paste)
# Source: Database → Navigation → Routes (branch f34ede180500ebac)
#   Children: Agua group (b64e05e2440027d2, 6 WPs), Michelle group (6c4e801e14004320, 46 WPs),
#             Popa group (f04eee9c0700bcc6, 11 WPs), Agua route (134ed6fe430035e4),
#             Michelle route (c84e16b013005fb2)
# Intent: COPY ALL → PASTE (UUID-preserving all-paste to E80 root)
curl -s "http://localhost:9883/api/test?panel=database&select=f34ede180500ebac&cmd=10099"
curl -s "http://localhost:9883/api/test?panel=e80&select=root&right_click=root&cmd=10300"
```
Watch for ProgressDialog "Paste Route Michelle total=93" — stalls at 47 and does not advance.

---

### Item 9 — §3.11 UUID-preserving paste missing `_deconflictE80Name`

**File:** `apps/navMate/nmOpsE80.pm` (`_pasteOneWaypointToE80`)

`_pasteOneWaypointToE80` (UUID-preserving path) does not call `_deconflictE80Name` before
`createWaypoint`. When an E80 WP with the same name but different UUID already exists,
`createWaypoint` returns `success=-1`. The Paste New paths (`_buildAndPasteWaypointToE80`)
have the deconflict call; UUID-preserving path does not.

**State at failure:** §3.8 created "Waypoint 5" with fresh UUID 6c4ebb408b04c4e6 on E80.
§3.11 then tried to UUID-preserve b74ea0349b005e4e (also named "Waypoint 5") → E80 rejected.

**To reproduce:**
```
# Prerequisite: E80 already has "Waypoint 5" with a different UUID (e.g. from §3.8 Paste New).
# Source: Database → oldE80 → Waypoints → (two WPs selected)
#   WP1: 634e538698009cee  "Waypoint 2"  (oldE80/Waypoints group b24ef59296004c48)
#   WP2: b74ea0349b005e4e  "Waypoint 5"  (oldE80/Waypoints group b24ef59296004c48)
# Intent: COPY WAYPOINTS (plural, cmd=10011, items=2)
# Destination: E80 → Groups header (header:groups)
curl -s "http://localhost:9883/api/test?panel=database&select=634e538698009cee,b74ea0349b005e4e&cmd=10011"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10300"
```
Expected (with fix): both WPs appear on E80; "Waypoint 5" auto-renamed to "Waypoint 5 (2)".
Actual (without fix): Waypoint 2 succeeds; Waypoint 5 → `ERROR: expected success(1) but got(-1)`.

---

### Item 10 — §5.4 doPaste has no guard for D-CT-DB→E80

**File:** `apps/navMate/nmOps.pm` (`doPaste`, E80 branch)

`canPaste` correctly blocks `cut=1 && source=database && panel=e80` (Item 7). But `doPaste`
itself has no matching guard. `/api/test` bypasses `canPaste` → paste runs to E80. In
Cycle 3, E80 happened to reject the WP (name conflict), so E80 was unchanged. But any WP
with a unique name would have been created on E80, defeating the guard intent.

**Fix:** Add explicit `if ($clipboard->{cut} && $clipboard->{source} eq 'database')` guard
at top of the E80 branch in `doPaste` (log IMPLEMENTATION ERROR warning + return).

---

### Item 11 — §5.4 DB WP deleted at cut time, not deferred until paste

**File:** `apps/navMate/nmOpsDB.pm`, `apps/navMate/nmOps.pm`

`doCut` for a database WP removes it from SQLite immediately. The test plan expected "source
WP remains in DB" when the paste is blocked. In Cycle 3, ff4eeafc8a0467da "Waypoint 5"
was permanently deleted from DB by the cut — even though the paste to E80 was (or should
have been) blocked. This is a data-loss scenario.

Design decision needed before fixing: defer deletion to paste-success (Option A), disallow
D-CT-DB from menu (Option B), or document cut=delete as by-design (Option C).

---

## Full Test Results — §2 through §5

| Section | Description | Command(s) | Result | Notes |
|---------|-------------|------------|--------|-------|
| §2.1 | D-CP-WP → Paste New | 10010 + 10301 | PASS | Fresh UUID for StarfishBeach in test branch |
| §2.2 | D-CT-WP → Paste (move) | 10110 + 10300 | PASS | Waypoint 3 UUID-preserved, moved to test branch |
| §2.3 | DEL-WP | 10410 | PASS | Waypoint 4 deleted |
| §2.4 | DEL-GR blocked (non-empty) | 10420 | PASS | Bocas group protected by non-empty guard |
| §2.5 | DEL-GR+WPS success | 10421 | PASS | Bocas + StarfishBeach deleted |
| §2.6 | DEL-GR+WPS blocked (members in route) | 10421 | PASS | Popa group protected; IMPLEMENTATION ERROR warning logged |
| §2.7 | DEL-BR recursive | 10450 | PASS | MandalaLogs branch (a04e77c42f048ed4) + all descendants deleted |
| §2.8 | D-CP-ALL clipboard set | 10099 | PASS | intent=all, source=database |
| §2.9 | D-CP-ALL → Paste New | 10301 | PASS | Fresh-UUID copies of test branch in Navigation |
| §2.10 | D-CT-ALL → Paste (move) | 10199 + 10300 | PASS | Test branch contents moved to Navigation |
| §2.11 | D-CT-RT → Paste (move) | 10130 + 10300 | PASS | Popa route UUID-preserved, moved to test branch |
| §2.12 | D-CP-RT → Paste New | 10030 + 10301 | PASS | Agua route + member WPs duplicated with fresh UUIDs |
| §2.13 | D-CT-TK → Paste (move) | 10140 + 10300 | PASS | claudeSpiral track moved to Navigation |
| §3.0 | Populate E80 (WP + group + route) | 10011/10020/10030 + 10300 | PASS | Waypoint 5, Michel_Agua, Popa route on E80 |
| §3.1 | E-CP-WP → Paste DB (UUID-preserving) | 10010 + 10300 | PASS | E80 WP UUID inserted/updated in DB |
| §3.2 | E-CP-WP → Paste New DB (fresh UUID) | 10010 + 10301 | PASS | Fresh navMate UUID copy in test branch |
| §3.3 | E-DEL-WP | 10410 | PASS | E80 WP deleted via DELETE_ITEM |
| §3.4 | E-DEL-GR+WPS | 10421 | PASS | Michel_Agua group + members deleted from E80 |
| §3.5 | E-CP-GR → Paste DB | 10020 + 10300 | PASS | Michel_Agua re-uploaded, then downloaded to DB |
| §3.6 | E-CP-RT → Paste DB | 10030 + 10300 | PASS | Popa route downloaded to DB |
| §3.7 | D-CP-ALL → E80 root (large batch) | 10099 + 10300 | **FAIL** | ProgressDialog "Paste Route Michelle total=93" hung at 47/93; user aborted |
| §3.8 | D-CP-WP → E80 Paste New | 10010 + 10301 | PASS | "Waypoint 5" on E80 with fresh UUID 6c4ebb408b04c4e6 |
| §3.9 | D-CP-GR → E80 Paste New | 10020 + 10301 | PASS | Michel_Agua second copy on E80 with fresh UUIDs |
| §3.10 | D-CP-RT → E80 Paste New | 10030 + 10301 | PASS | Agua route fresh-UUID copy + 6 fresh-UUID WPs |
| §3.11 | D-CP-WPS (2 WPs) → E80 | 10011 + 10300 | **FAIL** | Waypoint 5 (b74ea0349b005e4e) rejected by E80: name "Waypoint 5" exists (UUID 6c4ebb408b04c4e6 from §3.8) |
| §4.0 | Create test tracks on E80 (teensyBoat) | boat_driving_guide | PASS | testTrack1 + testTrack2 on E80 |
| §4.1 | E-CP-TK → Paste DB (download) | 10040 + 10300 | PASS | Track downloaded into test branch |
| §4.2 | E-CT-TK → Paste DB (download + erase) | 10140 + 10300 | PASS | testTrack1 erased from E80; d84ecbd8a20450c4 preserved in DB |
| §4.3 | Guard: D-CP-TK → E80 header:tracks blocked | 10040 + 10300 | PASS | "IMPLEMENTATION WARNING: paste intent='track' panel='e80' not implemented" |
| §4.4 | Guard: Paste New blocked for track clipboard | 10301 | PASS | "IMPLEMENTATION WARNING: paste intent='track' panel='database' not implemented" |
| §5.1 | Guard: DEL-WP blocked (WP in route) | 10410 | PASS | Popa0 (264e61a20800ee18) in route f14e059e0600c0b8; "IMPLEMENTATION ERROR: waypoint in route reached delete handler" |
| §5.2 | Guard: D-CP-TK → DB Paste blocked | 10040 + 10300 | PASS | "IMPLEMENTATION ERROR: _pasteTrackToDatabase: UUID-preserving DB-to-DB copy would create a duplicate" |
| §5.3 | Guard: any clipboard → E80 header:tracks blocked | 10010 + 10300 | PASS* | E80 unchanged (wps=99), but no WARNING logged — silent skip rather than explicit rejection |
| §5.4 | Guard: D-CT-DB → E80 blocked | 10110 + 10300 | **FAIL** | Paste ran to E80 (doPaste has no guard); E80 rejected due to name conflict by accident; ff4eeafc8a0467da "Waypoint 5" permanently deleted from DB at cut time |

---

## UUIDs referenced in this run

| UUID | Name | Location | Notes |
|------|------|----------|-------|
| f34ede180500ebac | Navigation/Routes branch | DB | Source for §3.7 COPY ALL |
| b64e05e2440027d2 | Agua group | DB → Navigation/Routes | Member of §3.7 all-paste |
| 6c4e801e14004320 | Michelle group | DB → Navigation/Routes | 46 WPs — ProgressDialog victim |
| f04eee9c0700bcc6 | Popa group | DB → Navigation/Routes | Popa0–10 already on E80 → no_change |
| c84e16b013005fb2 | Michelle route | DB + E80 | Appears on E80 after §3.7 abort |
| 134ed6fe430035e4 | Agua route | DB + E80 | |
| b74ea0349b005e4e | Waypoint 5 (original) | DB → oldE80/Waypoints | §3.11 UUID-preserving paste rejected |
| 6c4ebb408b04c4e6 | Waypoint 5 (§3.8 copy) | E80 | Paste New from §3.8; blocks §3.11 |
| 634e538698009cee | Waypoint 2 | DB → oldE80/Waypoints | §3.11 item 1 (PASS) |
| ff4eeafc8a0467da | Waypoint 5 (DB test branch copy) | DB → Navigation/test | §5.4 cut target — deleted from DB and lost |
| d84ecbd8a20450c4 | testTrack1 | DB → Navigation/test | Preserved in DB after §4.2 E80 erase |
| 264e61a20800ee18 | Popa0 | DB → Navigation/Routes/Popa | Used in §5.1 and §5.3 |
| 474e758e77044584 | test branch | DB → Navigation/test | Primary paste destination throughout |

---

*§5.3 PASS caveat: E80 is unchanged as required, but the rejection path produces no WARNING in the log.
The UI canPaste check correctly blocks this; the silent no-op happens only via `/api/test` bypass.*
