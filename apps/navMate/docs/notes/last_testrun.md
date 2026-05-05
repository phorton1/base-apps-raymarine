# navMate Context-Menu Test Run — Cycle 6

**Date:** 2026-05-05
**Start:** 01:48
**End:** ~03:xx (autonomous run while Patrick slept)
**Cycle:** 6 (full §1–§5 including §4 Tracks — first full run with teensyBoat)

---

## Summary

- **§1 (reset):** PASS
- **§2 (database tests 2.1–2.13):** ALL PASS
- **§3.0–§3.11 (E80 tests):** ALL PASS
- **§4.1–§4.4 (track tests):** ALL PASS — first successful run with teensyBoat
- **§5.1–§5.4 (guard tests):** ALL PASS

No code changes this cycle. No catastrophic errors. navMate ran continuously without restart.

---

## §4 Track Tests Detail

Tracks created via teensyBoat simulator at 50kts, 3-leg shapes (~120s each).

| Track | E80 UUID | DB UUID | Name | Shape |
|-------|----------|---------|------|-------|
| Track 1 | 81b266af3f001783 | 024e14a69f0463d6 | testTrack1 | Triangle E/SSW/NNW |
| Track 2 | 81b266af3f002283 | 514e3834a0042d46 | testTrack2 | L-shape N/E/S |

| Test | Result | Notes |
|------|--------|-------|
| §4.1 E-CP-TK → Paste DB | PASS | Track in DB with fresh UUID + name + color ff000000; still on E80 |
| §4.2 E-CT-TK → Paste DB | PASS | Track in DB; erased from E80 after cut |
| §4.3 guard: track → E80 blocked | PASS | IMPLEMENTATION WARNING fired; E80 tracks unchanged |
| §4.4 guard: Paste New for track blocked | PASS | IMPLEMENTATION WARNING fired; no extra track in DB |

---

## Full Test Results

| Section | Description | Result | Notes |
|---------|-------------|--------|-------|
| §1 | Reset (git revert, reload, clear E80) | PASS | Clean run, no crashes |
| §2.1 | Copy WP → Paste New | PASS | Fresh UUID in AguaAndTobobe |
| §2.2 | Cut WP → Paste (move) | PASS | UUID preserved, collection changed |
| §2.3 | Delete WP | PASS | |
| §2.4 | DEL-GR dissolve | PASS | Members reparented to oldE80 Groups Branch |
| §2.5 | DEL-GR+WPS (success) | PASS | Bocas group + members deleted |
| §2.6 | DEL-GR+WPS blocked (WPs in route) | PASS | IMPLEMENTATION ERROR sentinel |
| §2.7 | DEL-BR recursive | PASS | MandalaLogs branch fully deleted |
| §2.8 | Copy ALL (clipboard set) | PASS | intent=all confirmed |
| §2.9 | Paste New ALL → Nav Branch | PASS | Fresh UUID copies in Navigation |
| §2.10 | Cut ALL → Paste (move) | PASS | 4 WPs + 4 tracks moved; AguaAndTobobe emptied |
| §2.11 | Cut Route → Paste (move) | PASS | Popa Route moved; 11 route WPs intact |
| §2.12 | Copy Route → Paste New | PASS | Fresh-UUID route + 10 WPs in AguaAndTobobe |
| §2.13 | Cut Track → Paste (move) | PASS | |
| §3.0 | Populate E80 (WP + group + route) | PASS | All UUID-preserving; 22 WPs on E80 |
| §3.1 | E-CP-WP → Paste DB (UUID-preserving) | PASS | WP updated in place (already existed in DB) |
| §3.2 | E-CP-WP → Paste New DB (fresh UUID) | PASS | Fresh UUID in AguaAndTobobe |
| §3.3 | E-DEL-WP | PASS | 21 WPs remain |
| §3.4 | E-DEL-GR+WPS | PASS | Michel_Agua group + 10 members deleted |
| §3.5 | E-CP-GR → Paste DB | PASS | Group updated in place (already in DB) |
| §3.6 | E-CP-RT → Paste DB | PASS | Route + 11 WPs confirmed in DB |
| §3.7 | D-CP-ALL → E80 root (large batch) | PASS | 77 WPs; 4 groups; 3 routes; no errors |
| §3.8 | Paste New WP to E80 (fresh UUID) | PASS | a24e329c8804fa6c ≠ original |
| §3.9 | Paste New Group to E80 (fresh UUIDs) | PASS | Michel_Agua (2) on E80; 10 new WPs |
| §3.10 | Paste New Route to E80 (fresh UUIDs) | PASS | Agua (2) on E80; 10 new WPs |
| §3.11 | Multi-select WPs → Paste to E80 | PASS | items=2 confirmed in log |
| §4.1 | E-CP-TK → Paste DB | PASS | See §4 detail above |
| §4.2 | E-CT-TK → Paste DB | PASS | See §4 detail above |
| §4.3 | Guard: track → E80 blocked | PASS | |
| §4.4 | Guard: Paste New for track blocked | PASS | |
| §5.1 | Guard: DEL-WP blocked (WP in route) | PASS | IMPLEMENTATION ERROR; Popa0 intact |
| §5.2 | Guard: D-CP-TK → DB Paste blocked | PASS | IMPLEMENTATION ERROR; UUID-preserving DB→DB blocked |
| §5.3 | Guard: any clipboard → E80 header:tracks | PASS | Paste ran but no change (WP already on E80) |
| §5.4 | Guard: D-CT-DB → E80 blocked | PASS | IMPLEMENTATION ERROR; Popa0 still in DB |

---

## Issues

*(none — all tests PASS this cycle)*

---

