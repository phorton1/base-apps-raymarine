# navOps Test Suite -- UUID Index

Lookup registry. Modules reference `[Name]` tokens; UUIDs live only here. This is a dictionary -- look up entries by name, don't read sequentially.

For static-baseline vs setup-derived UUID concepts, see [`master_plan.md`](master_plan.md). For test execution context, see [`master_runbook.md`](master_runbook.md).

---

## Source Conventions

- `source=db` -- entry exists in the git-baseline `C:/dat/Rhapsody/navMate.db`. UUID derived from live `/api/nmdb` after `op=refresh`. Re-derive when baseline DB changes.
- `source=fsh:_fixtures/test.fsh` -- entry exists in the frozen FSH fixture. UUID is stable indefinitely (fixture is frozen by policy).
- `source=setup:<op>` -- entry is produced by a module setup operation; UUID assigned at runtime. Noted as `dynamic` in the UUID column; the operation that produces it is named in the source column.

UUIDs verified 2026-05-08 from live `/api/nmdb` (schema 10, git-baseline navMate.db). FSH-side entries to be populated as the fsh module is built.

---

## Static -- DB-side (`source=db`)

### Isolated waypoints

| [Name] | UUID | Notes |
|--------|------|-------|
| [IsolatedWP1] | ce4e43181f01b3ae | BOCAS1 -- in oldE80/Tracks branch; not in any group or route |
| [IsolatedWP2] | af4e23246d01bfa8 | BOCAS2 -- same parent branch |
| [IsolatedWP3] | 994e0f7ef900baa4 | TOBOBE -- same parent branch; consumed by db module's delete-WP test |

### WP referenced in a route

| [Name] | UUID | Notes |
|--------|------|-------|
| [WPinRoute] | 314e56cc09005332 | Popa0 -- in Popa group; pos=0 in Popa route |

### Group without route refs

| [Name] | UUID | Notes |
|--------|------|-------|
| [GroupNoRoute] | a74e90d60300a434 | Bocas group -- 2 members (StarfishBeach + Fishfarm), none in route. Used by delete-group-with-WPs test. |
| [GroupNoRoute_Dissolve] | 4e4e405a08033af4 | Places group (Part 1 - Before Trip) -- 5 members, none in route; safe to dissolve. |

### Group with route refs

| [Name] | UUID | Notes |
|--------|------|-------|
| [GroupInRoute] | 244e8e100800400a | Popa group -- 11 members all in Popa route |
| [GroupWithRouteMembers] | 244e8e100800400a | Alias for [GroupInRoute] (same node, different role in different tests) |

### Test group / member (for ancestor-wins, paste-to-E80)

| [Name] | UUID | Notes |
|--------|------|-------|
| [TestGroup] | 1a4eaf5a8c00e922 | Timiteo -- under oldE80/Groups ([UnsafeBranch]); 6 members (t01-t06), none in route. Name "Timiteo" never conflicts with E80 state at PASTE_NEW time. |
| [TestGroupMember] | d44e40468d000d96 | t01 -- first member of [TestGroup]. Used in ancestor-wins multi-select. |

### Route + route points

| [Name] | UUID | Notes |
|--------|------|-------|
| [TestRoute] | f34efdd6070022e8 | Popa route -- 11 WPs (Popa0-Popa10) |
| [RP1] | 314e56cc09005332 | Popa0 -- pos=0 in Popa route (= [WPinRoute]) |
| [RP2] | 8d4e68fa0a0073ee | Popa1 -- pos=1 |
| [RP3] | 454e11a80b002884 | Popa2 -- pos=2 |

### Branches (safe / unsafe / nested)

| [Name] | UUID | Notes |
|--------|------|-------|
| [SafeBranch] | 0a4e9820cc015cae | "Before Sumwood Channel" -- Places (7 WPs none in route) + empty Tracks sub-branch; isBranchDeleteSafe=1 |
| [RouteBranch] | ac4e2c500600b9aa | Navigation/Routes -- Agua/Michelle/Popa groups + matching routes |
| [SomeBranch] | 784e76f880029e1e | "MichellToKuna 2011-07" -- Places (4 WPs none in route) + empty Tracks sub-branch; isBranchDeleteSafe=1 |
| [NestedBranch] | 234e412e3104296e | MandalaLogs -- root level; Places + Tracks sub-branch |
| [ChildBranch] | 984e7898480427f6 | MandalaLogs/Tracks -- direct child of [NestedBranch]; used as recursive-paste target |
| [UnsafeBranch] | b84e8c3c51009446 | oldE80/Groups -- 62 descendant WPs in routes outside this branch |

### Track

| [Name] | UUID | Notes |
|--------|------|-------|
| [TestTrack] | 1a4eed924904ebbe | "2005-11-25-SanDiego2Oceanside" -- in MandalaLogs/Tracks; 500 pts, palette color (ff00ff00 green) |
| [DB_TRACK_SHORT] | 8a4e3c4a2201fac2 | "BOCAS1-001" -- 11 chars, 77 pts, color=ffff6666; short-name positive PASTE-to-E80 candidate |
| [DB_TRACK_LONG_NONPALETTE] | 824e8a104b04c37c | "2006-01-11-SanDiego2DanaPoint" -- 31 chars, 231 pts, color=ffffff00; exercises BOTH lossy-warn lines (name truncation + color snap) in a single paste |
| [DB_TRACK_MULTI_A] | 8a4e3c4a2201fac2 | = [DB_TRACK_SHORT]. The single-PASTE track in tracks.5; NOT used in multi-PASTE because by then it lives on E80 (uuid-preserving multi-PASTE collides). |
| [DB_TRACK_MULTI_B] | 664e93a624018e26 | "BOCAS1-002" -- 11 chars, 74 pts. First slot in the tracks.6 multi-PASTE batch. |
| [DB_TRACK_MULTI_C] | 694e27fe26016702 | "BOCAS1-003" -- 11 chars, 55 pts. Second slot in the tracks.6 multi-PASTE batch. |
| [DB_TRACKS_BRANCH] | 2b4e3308ca00cf66 | oldE80/Tracks branch -- 123 tracks; parent of the BOCAS1-* / BOCAS2-* / TOBOBE-* / SANBLAS-* etc. children used by multi-track tests. |

### Paste destination

| [Name] | UUID | Notes |
|--------|------|-------|
| [DST] | 6f4e72ceae0264de | "AguaAndTobobe c 2011-03-06" -- under Michelle; empty at module-baseline (0 WPs, 0 routes, 0 child collections). Accumulates module output within a cycle. |

### Name-collision setup

| [Name] | UUID | Notes |
|--------|------|-------|
| [WP_A] | dynamic | First of two same-named DB WPs (locate two WPs sharing a name via `/api/nmdb` group-by-name). |
| [WP_B] | dynamic | Second same-named WP (same name as [WP_A], different UUID). |
| [SameNameWP] | dynamic | DB WP whose name equals [IsolatedWP1]'s name ("BOCAS1"). Multiple candidates exist in baseline DB; the e80 module's runbook picks the first non-[IsolatedWP1] match. |

---

## Static -- FSH-side (`source=fsh:_fixtures/test.fsh`)

The fixture was copied 2026-05-17 from `FSH/test/working_oldE80.fsh`. Inventory: 50 isolated waypoints (under `my_waypoints`), 4 groups, 3 routes, 123 tracks. UUIDs below are FSH-native dashed-uppercase form -- the format returned by `/api/fsh` and stored in winFSH tree nodes. The navMate canonical form (16-hex lowercase, no dashes) is derived via `fshToNavUUID($fsh_uuid)` at the snapshot seam.

### Isolated waypoints (under FSH `my_waypoints`)

| [Name] | UUID | Notes |
|--------|------|-------|
| [FSH_IsolatedWP1] | 80B2-C48A-5400-D3AE | "Waypoint 25" -- top-level; no group, no route ref |
| [FSH_IsolatedWP2] | 83B2-167D-3F00-ED99 | "Waypoint 10" -- top-level; no group, no route ref |
| [FSH_IsolatedWP3] | 83B2-167D-3F00-37D9 | "Waypoint 14" -- top-level; consumed by delete-WP test |

### Group without members in route (safe delete with WPS)

| [Name] | UUID | Notes |
|--------|------|-------|
| [FSH_GroupNoRoute] | C482-CB97-D14E-67B2 | "test" group -- 79 embedded members, none referenced by any route. Safe for DELETE GROUP+WPS. |

### Groups with members in routes (delete-WPS blocked)

| [Name] | UUID | Notes |
|--------|------|-------|
| [FSH_GroupInRoute] | C482-CBA0-D14E-67B2 | "Timiteo" group -- 6 embedded members, all referenced by Timiteo route. Smallest of the three in-route groups. |
| [FSH_GroupAguaRoute] | C782-7BB6-7A46-4722 | "Michel_Agua" group -- 10 embedded members, all in Michel_Agua route. |
| [FSH_GroupSumwoodRoute] | C782-7BB7-7A46-4722 | "Michel_Sumwood" group -- 46 embedded members, all in Michel_Sumwood route. |

### Route + route points (Timiteo)

| [Name] | UUID | Notes |
|--------|------|-------|
| [FSH_TestRoute] | C482-CB9E-D14E-67B2 | "Timiteo" route -- 6 embedded points (t01..t06). |
| [FSH_RP1] | C482-CB98-D14E-67B2 | t01 -- first point of [FSH_TestRoute]. Also embedded in [FSH_GroupInRoute]. |
| [FSH_RP2] | C482-CB99-D14E-67B2 | t02 -- second point. |
| [FSH_RP3] | C482-CB9A-D14E-67B2 | t03 -- third point. |

### Track

| [Name] | UUID | Notes |
|--------|------|-------|
| [FSH_TestTrack] | A24E-672E-FE06-0A80 | "Track2-006" -- first track in fixture (123 tracks total). |
| [FSH_TRACK_BOCAS1_003] | 0E4E-0BEA-B407-584A | "BOCAS1-003" -- 74 pts, color=0 (palette). FSH-source positive PASTE-to-E80 candidate (clean path: short name + palette color, no lossy-warn fires). |

### FSH UUID format and selection-key construction

- FSH tree nodes use the dashed-uppercase UUID as the `uuid` field; `_getNodeKey` returns this verbatim. `select=<uuid>` in `/api/test?panel=fsh&select=...` uses the FSH-native form.
- Route point keys follow the same `rp:<route_uuid>:<wp_uuid>` shape as the database panel: `rp:C482-CB9E-D14E-67B2:C482-CB98-D14E-67B2`.
- Header keys: `header:groups`, `header:routes`, `header:tracks`. `my_waypoints` for the ungrouped WP node.
- When verifying state via `/api/nmdb` (DB side) after an FSH-to-DB op, expect lowercase-no-dash form -- run `$fsh_uuid -replace '-','' | ToLower` for cross-check.

---

## Setup-derived (`source=setup:...`)

These entries have no static UUID. The module's baseline setup creates them; the UUID is assigned at runtime and recorded in the module's working log for use by subsequent tests within the same module.

| [Name] | source | Notes |
|--------|--------|-------|
| [E80_WP] | setup:upload_wp([IsolatedWP1]) -- e80 module | Paste [IsolatedWP1] to E80 (UUID preserved). Used as the canonical upload-WP across e80 module tests. |
| [E80_GR] | setup:upload_group([GroupWithRouteMembers]) -- e80 module | Paste Popa group to E80 (UUID preserved). |
| [E80_RT] | setup:upload_route([TestRoute]) -- e80 module | Paste Popa route to E80 (UUID preserved). |
| [E80_TK1] | setup:teensyBoat_track(E80Track1) -- tracks module | First teensyBoat-recorded track; UUID assigned by E80 (byte 1 = B2). Lives on E80 across tracks.2/3 (COPY-only) and into Section 2. |
| [E80_TK2] | setup:teensyBoat_track(E80Track2) -- tracks module | Second teensyBoat-recorded track; fresh E80 uuid (byte 1 = B2). Used by tracks.4 as the CUT+PASTE record-creating positive (its uuid must be uncontaminated in DB because the 2026-05-29 uuid-collision preflight rejects spoke->DB paste at an existing DB uuid). |
| [E80_FRESH_WP] | setup:paste_new_wp -- e80 module | Fresh-UUID WP created by PASTE_NEW (navMate-assigned UUID, byte 1 = 0x4e). |
| [E80_FRESH_WP2] | setup:paste_new_wp -- e80 module | Second fresh-UUID WP. |
| [E80_RT_FRESH] | setup:paste_new_route -- e80 module | Fresh-UUID route from PASTE_NEW (preserves member WP UUIDs by reference). |
| [E80_RP1] / [E80_RP2] / [E80_RP3] | setup:paste_new_route -- e80 module | Route points in the fresh-UUID route; specific WP UUIDs documented in the e80 runbook's relevant test. |

Setup-derived UUIDs are derived from `/api/db` after the setup step completes and noted in the module's working log; they are NOT pre-resolved in this index.

---

## Lookups (not registered, for cross-reference)

These UUIDs are referenced in module specs for parent-collection navigation but do not get a `[Name]` token of their own:

| Description | UUID |
|-------------|------|
| Navigation top-level | 424e51840100072e |
| Navigation/Routes sub-branch | ac4e2c500600b9aa (= [RouteBranch]) |
| Navigation/Waypoints sub-branch | e54ede600200feee |
| oldE80 top-level | a14ede0850000360 |
| oldE80/Tracks branch | 2b4e3308ca00cf66 |
| oldE80/Groups branch | b84e8c3c51009446 (= [UnsafeBranch]) |
| StarfishBeach | 9d4e232a0500dd90 (member of [GroupNoRoute]) |
| Fishfarm (member of Bocas group) | 124e0eb404000564 (NOTE: a separate "Fishfarm" at e84e625e980095c6 lives under oldE80/Waypoints; unrelated) |
| Popa0 / Popa1 / Popa2 | 314e56cc09005332 / 8d4e68fa0a0073ee / 454e11a80b002884 |
| Michelle top-level | 034e6b8ccb01fffe |
| Part 1 - Before Trip | 214e7db00703a184 |
| Agua group | 204ecbd24500a678 |
| Agua route | d64e8c7e4400a186 |
| Michelle group | 104e199a1500e646 |
| Michelle route | 3b4e87f21400d81c |
| Timiteo route | 844ed11696001cba |

---

## Maintenance

When the baseline `navMate.db` changes, every `source=db` entry needs re-derivation:

1. Revert and refresh `navMate.db`.
2. For each `[Name]` entry: locate by role description; derive the new UUID from `/api/nmdb`.
3. Update the table here.
4. Module references survive automatically -- they cite `[Name]`, not UUID.

When `_fixtures/test.fsh` is regenerated, `source=fsh:...` entries need similar re-derivation. The fixture is frozen by policy, so this should be rare; only required if a test deliberately needs a new FSH shape.
