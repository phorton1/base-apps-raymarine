---
name: navOps test plan runbook
description: Self-contained runbook for the navOps test cycle (Section 1-Section 5). UUID table fully resolved 2026-05-08 from live /api/nmdb. Update UUID table only when baseline DB changes; all test steps reference [Names] only.
type: project
originSessionId: 47373f12-a3cc-4767-91a2-a2ddda32ef3f
---
# navOps Test Cycle Runbook

Companion to `apps/navMate/docs/notes/navOps_testplan.md`. Read that first for design context,
pre-flight rules (SS1-SS13), and the full expected-behavior spec. This runbook is the
execution layer: UUID table, exact curl commands, pass/fail pattern.

---

## Runbook self-improvement rule

**This runbook is always writable.** Whenever a fact is discovered mid-run -- wrong
endpoint, wrong data shape, new timing constraint, corrected command -- update this
runbook immediately before continuing the next step. Do not defer to end-of-session;
context fills up and the fact gets lost. The runbook IS the persistent memory for
this test cycle; treat every correction as a first-class commit.

---

## Toolbox

### Rule: new tools

If mid-run you discover you need a tool not listed here -- stop, build it properly:
write it to `apps/navMate/` with a `_` prefix, add it to this toolbox with its call
signature and return shape. Do not write a one-off improvised script.

### HTTP endpoints

| Endpoint | Key params | Returns |
|----------|-----------|---------|
| `GET /api/log?since=SEQ` | `since=` seq OR `since=mark` | `{lines:[{seq,color,text},...], overflow:N, seq:N}`. Field is `seq` (current ring seq), NOT `last_seq`. |
| `GET /api/command?cmd=mark` or `cmd=mark+<tag>` | -- | snapshots ring seq server-side for `?since=mark`. Response is `{"ok":1,"cmd":"mark"}` -- NO seq returned. Optional tag (anything after the first whitespace, URL-encode spaces as `+`) is included in the log as `------ MARK: <tag> ------`. Use tagged marks at phase boundaries inside a multi-phase test for human readability. **Preferred pattern: `/api/log?since=mark` reads all lines since the last mark, no client-side seq tracking needed.** |
| `GET /api/command?cmd=dialog_state` | -- | logs "dialog_state: active" or "idle" |
| `GET /api/command?cmd=close_dialog` | -- | force-closes any hung ProgressDialog |
| `GET /api/test?op=suppress&val=1` | val=0 to disable | enables auto-suppress (no confirmation dialogs) |
| `GET /api/test?op=suppress&val=1&outcome=reject` | -- | suppress with reject (non-default path) |
| `GET /api/test?op=refresh` | -- | reloads navMate.db from disk |
| `GET /api/test?op=clear_e80` | -- | deletes all E80 routes, groups, waypoints, and tracks |
| `GET /api/test?op=create_branch&parent_uuid=PUUID&name=NAME` | `parent_uuid` omitted -> root-level branch | dialog-free NEW_BRANCH. Returns `{ok:1, queued:1}`; the new branch's uuid is not in the response -- look it up in `/api/nmdb` by name after a brief settle |

**`/api/test` queue is single-slot:** the server stores at most one pending
test command. A second `/api/test` call fired before the wx idle loop has
picked up the first will overwrite the first. Any sequenced multi-step
test (COPY then PASTE_NEW, looped pastes, etc.) **must** wait for each
command to actually run before issuing the next. Use the
`Wait-NavCmdFinished` helper below, which polls `/api/log?since=mark`
until the expected `===== <CMD> ... FINISHED =====` line appears.
Single-shot tests (just `?op=refresh`, `?op=suppress`, `?op=clear_e80`)
do not need the helper -- they have nothing chained behind them.

### Wait-NavCmdFinished -- log-polling sync helper

Drop this near the top of any PowerShell test script that fires multiple
`/api/test?cmd=N` calls. It eliminates the need for fixed sleeps; total
test time tracks actual command processing time instead of the worst-case
guess.

```powershell
# Count of FINISHED-line occurrences seen so far, keyed by command name.
# Each call to Wait-NavCmdFinished bumps the expected count for that command,
# then polls /api/log?since=mark until the count of matching FINISHED lines
# in the log reaches the new expected count.
$global:nav_cmd_seen = @{}

function Wait-NavCmdFinished
{
    param(
        [Parameter(Mandatory=$true)] [string]$cmdName,    # e.g. "COPY", "PASTE NEW", "PASTE NEW BEFORE", "DELETE BRANCH"
        [Parameter(Mandatory=$true)] [string]$panel,      # "database" or "e80"
        [int]$timeout_ms = 8000
    )
    $key = "$panel/$cmdName"
    if (-not $global:nav_cmd_seen.ContainsKey($key)) { $global:nav_cmd_seen[$key] = 0 }
    $global:nav_cmd_seen[$key]++
    $expected = $global:nav_cmd_seen[$key]
    $pattern  = "===== $cmdName ($panel) FINISHED ====="

    # Initial wait: typical commands complete in well under 1s. Starting to
    # poll immediately would flood /api/log with several requests before
    # the command has even finished, polluting the ring buffer.
    Start-Sleep -Milliseconds 1000

    $deadline = (Get-Date).AddMilliseconds($timeout_ms)
    while ((Get-Date) -lt $deadline)
    {
        $log   = curl.exe -s "http://localhost:9883/api/log?since=mark"
        $count = ([regex]::Matches($log, [regex]::Escape($pattern))).Count
        if ($count -ge $expected) { return $true }
        Start-Sleep -Milliseconds 250
    }
    Write-Host "Wait-NavCmdFinished TIMEOUT: $pattern (seen $count of $expected after ${timeout_ms}ms)"
    return $false
}

# Helper for tagging phase boundaries inside a multi-phase test.
# `cmd=mark` server-side accepts text after the command name (splits on
# first whitespace) and logs `------ MARK: <tag> ------`. Each Mark-Phase
# call also resets the wait-helper counter so the next phase's commands
# are counted from zero against the new since=mark window.

function Mark-Phase
{
    param([Parameter(Mandatory=$true)] [string]$tag)
    $encoded = [uri]::EscapeDataString($tag)
    curl.exe -s "http://localhost:9883/api/command?cmd=mark+$encoded" | Out-Null
    $global:nav_cmd_seen = @{}
}

# Typical use at the start of a test:
#   Mark-Phase "Test 2.0 start"
# At each phase boundary:
#   Mark-Phase "Test 2.0 main loop"
# After this, /api/log?since=mark scopes to the current phase.
```

Command-name strings to pass as `-cmdName` are the all-caps form that
appears in the log's `===== <NAME> (<panel>) STARTED =====` line:
`COPY`, `CUT`, `PASTE`, `PASTE NEW`, `PASTE BEFORE`, `PASTE AFTER`,
`PASTE NEW BEFORE`, `PASTE NEW AFTER`, `DELETE WAYPOINT`, `DELETE BRANCH`,
etc.

For `/api/test?op=...` operations that do not produce a `===== ... =====`
line (such as `op=create_branch`), poll for an op-specific log signature
instead. The `create_branch` op logs
`navTest: create_branch '<name>' uuid=<uuid>`; the runbook's Test 2.0 polls
this string directly.
| `GET /api/test?panel=P&select=K&cmd=N` | `right_click=K` optional | fires context-menu command N on panel P at node K |
| `GET /api/nmdb` | -- | navMate DB: arrays -- waypoints, collections, routes, route_waypoints, tracks |
| `GET /api/db` | -- | E80 live state: hashes keyed by UUID -- waypoints, groups, routes, tracks |

Base URL: `http://localhost:9883` (9882 not accessible from Claude).

**`/api/nmdb` field names - parent field differs by entity type:**

| Entity | Parent field | WP-ref field | Notes |
|--------|-------------|-------------|-------|
| waypoints | `collection_uuid` | -- | standard |
| collections (branches, groups) | `parent_uuid` | -- | NOT `collection_uuid` |
| routes | `collection_uuid` | -- | standard |
| route_waypoints | `route_uuid` | `wp_uuid` | NOT `waypoint_uuid` |
| tracks | `collection_uuid` | -- | standard |

Always use `parent_uuid` when filtering collections by parent. Using `collection_uuid` on a collection always returns empty results.

**PASTE_NEW of a route (confirmed 2026-05-08):** creates fresh route UUID; route_waypoints reference the SAME original WP UUIDs (per SS1.6, SS12.3) - no new WP records created. This is correct per the testplan (navOps_testplan.md Section 2.10 line 250-251). The runbook's prior expected-behavior text "new member WPs (all fresh UUIDs)" was wrong.

**E80 route structure from /api/db (confirmed Cycle 9):** E80 route objects do NOT have a `waypoints` field.
Use `num_wpts` (integer count) and `uuids` (array of WP UUID strings) to check route waypoint membership.
`$rt.waypoints` is always null; `$rt.waypoints.Count` always returns 0 - this is a false zero, not a real failure.
Correct check: `$rt.uuids.Count -gt 0` or `$rt.num_wpts -gt 0`.

**E80 group structure from /api/db (confirmed Cycle 9):** E80 group objects do NOT have a `waypoints` or `members`
field. Use `num_uuids` (integer count) and `uuids` (array of member WP UUID strings).
`$grp.waypoints` and `$grp.members` are always null/0 - false zeros. Correct check: `$grp.uuids.Count -gt 0`
or `$grp.num_uuids -gt 0`.

**ProgressDialog timing (confirmed Cycle 9):** Fast E80 operations complete before any sleep window.
A TIMEOUT does NOT mean failure - check /api/db. Never beep on TIMEOUT alone.

**`dialog_state` API response (confirmed Cycle 9 - CRITICAL):** `curl.exe .../api/command?cmd=dialog_state`
returns `{"ok":1,"cmd":"dialog_state"}` in BOTH idle and active states. The words "idle" or "active" appear
ONLY in the navMate LOG, not in the HTTP response body. Checking `$response -match "idle"` is ALWAYS FALSE
regardless of dialog state. **Never check the response body of dialog_state.** To determine state, read the
log after firing the command and look for "dialog_state: idle" or "dialog_state: active" in log text.
However, the preferred pattern is to read the log for `ProgressDialog.*FINISHED` after a flat sleep - this
avoids dialog_state entirely for normal operations.

**Node key format:**

| Node type | Key |
|-----------|-----|
| Waypoint, route, track, group, branch | UUID string |
| Route point | `rp:ROUTE_UUID:WP_UUID` |
| E80 header nodes | `header:groups`, `header:routes`, `header:tracks` |
| E80 My Waypoints | `my_waypoints` (no `header:` prefix) |
| DB or E80 root | `root` |

### Command constants

**cmd= parameter must be NUMERIC** -- navTest.pm does arithmetic with it; string names cause "isn't numeric" error. Use the numeric values from curl commands; this table is name-to-number reference only.

| Command | Value |
|---------|-------|
| `COPY`             | 10200 |
| `CUT`              | 10201 |
| `PASTE`            | 10210 |
| `PASTE_NEW`        | 10211 |
| `PASTE_BEFORE`     | 10212 |
| `PASTE_NEW_BEFORE` | 10214 |
| `PASTE_NEW_AFTER`  | 10215 |
| `DELETE_WAYPOINT`  | 10220 |
| `DELETE_GROUP`     | 10221 |
| `DELETE_GROUP_WPS` | 10222 |
| `DELETE_ROUTE`     | 10223 |
| `DELETE_TRACK`     | 10225 |
| `DELETE_BRANCH`    | 10226 |
| `PUSH`             | 10250 |

---

### Standard log reader

**Preferred pattern (PowerShell, uses since=mark - no seq tracking needed):**
```powershell
$r = curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json
$r.lines | ForEach-Object { "$($_.seq)  $($_.text)" }
```

Scan every log read for: `ERROR`, `WARNING`, `IMPLEMENTATION ERROR`.

**Note on seq tracking:** Each `/api/log` response has `seq` (current ring buffer position) and `overflow`. Use `since=mark` to get all lines since the last `cmd=mark`. Only fall back to explicit `since=N` if you need to read past the mark window without re-marking.

### ProgressDialog wait snippet (PowerShell)

**Primary pattern: flat sleep + single log read.** Do NOT loop-read the log (floods ring buffer).
Do NOT check the dialog_state response body (it never contains "idle" -- see note above).

```powershell
# Before the step: curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+N.X" | Out-Null    # tag identifies which test owns the mark
# After firing an E80 command:
Start-Sleep 5   # flat wait -- adjust up for multi-WP pastes (11 WPs = 5s is enough)
$r = curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json
$finished = $r.lines | Where-Object { $_.text -match "ProgressDialog.*FINISHED" }
if (-not $finished) {
    # Not finished yet -- fire dialog_state, then re-read since mark for "dialog_state: idle/active"
    curl.exe -s "http://localhost:9883/api/command?cmd=dialog_state" | Out-Null
    $r2 = curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json
    $isIdle = $r2.lines | Where-Object { $_.text -match "dialog_state: idle" }
    if (-not $isIdle) {
        # Dialog genuinely still active -- genuine hang
        [console]::beep(800, 200)
        "GENUINE HANG -- try: curl.exe -s http://localhost:9883/api/command?cmd=close_dialog"
    }
}
# Scan log for ERROR / WARNING / IMPLEMENTATION ERROR
$r.lines | Where-Object { $_.text -match "IMPLEMENTATION ERROR|^ERROR|WARNING" } | ForEach-Object { "$($_.seq)  $($_.text)" }
```

**Note:** `since=mark` reads from the LAST `cmd=mark` call. If you re-mark mid-step, prior log lines become inaccessible. Mark once per test step, just before firing the operation.

**Mark tagging convention (required):** every `cmd=mark` call in this
runbook MUST carry an identifier of the test/section that owns it, in the
form `cmd=mark+<tag>` (URL-encode spaces as `+`). The tag is echoed in the
log as `------ MARK: <tag> ------`. Tags allow human review of the log to
match each mark to its source test. The minimum tag is the section or test
number (`Section+1+reset`, `Test+2.7`); multi-phase tests append a phase
sub-tag (`Test+2.0+anchors`, `Test+2.0+main+loop`). Inside PowerShell, use
the `Mark-Phase` helper which URL-encodes for you and also resets the
sync-helper counter.

After waiting: missing FINISHED is NOT automatically a failure for fast/no-op operations.
Only beep if dialog_state log entry confirms "active" after the full wait (genuine hang).

---

## Test execution rules

- Record wall-clock start time before Section 1 reset (needed for last_testrun.md)
- Run continuously until an issue is found, then stop and present a summary
- Do NOT stop between passing steps to ask for confirmation
- **[Name] tokens in curl commands** must be resolved to UUIDs from the UUID table before
  firing. E.g. `select=[IsolatedWP1]` -> `select=ce4e43181f01b3ae`. The table is the only
  place UUIDs live; the steps themselves never change when the DB changes.
- **COPY+PASTE timing rule:** After firing COPY, poll the log until "COPY.*FINISHED" appears
  before firing PASTE. Rapid-fire COPY+PASTE causes PASTE to execute with stale clipboard state.
- **E80 group/WP deletes:** If E80 has routes whose route_points include group members, the
  member-in-route guard will block group deletes. Delete all E80 routes FIRST (wait for
  ProgressDialog FINISHED), then delete groups and ungrouped WPs.
- **STRICT ORDERING -- no deferring:** Run tests exactly in the order listed. Do NOT skip a
  test and plan to revisit it later. If a test cannot run at its scheduled position
  (pre-condition unmet, feature unavailable), mark it NOT_RUN immediately and move to the
  next step. Reordering sections or deferring tests mid-cycle is prohibited.
- Each test step:
  1. Mark the log and note the seq
  2. Resolve any [Name] tokens in the curl command, then fire
  3. Read log since mark -- scan for ERROR/WARNING/IMPLEMENTATION ERROR
  4. If E80 step: confirm every ProgressDialog STARTED has a matching FINISHED
  5. Verify DB state via /api/nmdb as called out in the test
  6. Verify E80 state via /api/db as called out in the test
  7. Determine PASS / FAIL / PARTIAL / PASSED_BUT / NOT_RUN
- **ProgressDialog auto-completion is a pass criterion.** Any E80 step that opens a
  ProgressDialog has two pass criteria: (a) the data outcome (DB/E80 state matches
  expected) AND (b) the dialog auto-FINISHED in the log on its own. Both must hold for PASS.
- If ProgressDialog hangs: fire `close_dialog` to recover the cycle and continue, but the
  step is **FAIL** -- criterion (b) was not met. PASSED_BUT is not appropriate here; a
  violated pass criterion is FAIL even when the cycle was rescued.
- If `close_dialog` itself fails: catastrophic. `[console]::beep(800,200)` and stop.
- After each test, record status immediately -- do not batch
- **Never infer a result from a different test.** Each step is evaluated solely on whether
  IT reached its intended code path and produced its expected outcome. If a different guard
  fires first (wrong message, wrong code path), that is a FAIL -- even if the net result
  (e.g., E80 unchanged) happens to be correct, and even if another step already confirmed
  the same guard via a different clipboard type. Test 5.4c (Cycle 10) is the canonical example:
  SS10.8 never fired; name-collision fired instead; recorded as PASSED_BUT citing Test 4.3 --
  that was wrong. The test did not pass.

---

## UUID table

**Update only this table when the baseline DB changes.**
**All test steps in navOps_testplan.md reference [Names] from this table -- steps
themselves never need to change when the DB changes.**

UUIDs verified 2026-05-08 from live /api/nmdb (schema 10, git-baseline navMate.db).

### Static node UUIDs

| [Name] | UUID | Notes |
|--------|------|-------|
| **Isolated waypoints (parent=branch, not in any route)** | | |
| [IsolatedWP1] | ce4e43181f01b3ae | BOCAS1 -- in oldE80/Tracks branch (2b4e3308ca00cf66); directly in branch, not in any group or route |
| [IsolatedWP2] | af4e23246d01bfa8 | BOCAS2 -- same parent branch |
| [IsolatedWP3] | 994e0f7ef900baa4 | TOBOBE -- same parent branch; consumed by Section 2.3 delete |
| **WP referenced in a route** | | |
| [WPinRoute] | 314e56cc09005332 | Popa0 -- in Popa group (244e8e100800400a); pos=0 in Popa route |
| **Group with no route refs (used by Section 2.5 delete test)** | | |
| [GroupNoRoute] | a74e90d60300a434 | Bocas group -- Navigation/Waypoints (e54ede600200feee); 2 members (StarfishBeach + Fishfarm), none in route. Used for Section 2.5 (delete+WPs) ONLY. |
| **Group for Section 2.4 dissolve test** | | |
| [GroupNoRoute_Dissolve] | 4e4e405a08033af4 | Places group -- in Part 1 - Before Trip (214e7db00703a184); 3 members, none in route; small and safe to dissolve |
| **Group for Test 3.15 (paste new to E80) and Test 5.7 (ancestor-wins)** | | |
| [TestGroup] | 1a4eaf5a8c00e922 | Timiteo -- under oldE80/Groups ([UnsafeBranch]); 6 members (t01-t06), none in any route; survives all Section 2 tests; name "Timiteo" never conflicts with E80 state at Test 3.15 time (which has Popa from Test 3.11b); Test 5.2 blocks [UnsafeBranch] delete so Timiteo is always safe; also used as group anchor in Test 2.16 |
| [TestGroupMember] | d44e40468d000d96 | t01 -- first member of [TestGroup]; used in Section 5.7 multi-select to trigger ancestor-wins |
| **Group whose members ARE in a route** | | |
| [GroupInRoute] | 244e8e100800400a | Popa group -- Navigation/Routes (ac4e2c500600b9aa); 11 members all in Popa route |
| **Group containing route members (E80 upload + ordering tests)** | | |
| [GroupWithRouteMembers] | 244e8e100800400a | Popa group -- same node as [GroupInRoute] |
| **Route with 3+ ordered waypoints** | | |
| [TestRoute] | f34efdd6070022e8 | Popa route -- Navigation/Routes (ac4e2c500600b9aa); 11 WPs (Popa0-Popa10) |
| [RP1] | 314e56cc09005332 | Popa0 -- pos=0 in Popa route (same UUID as [WPinRoute]) |
| [RP2] | 8d4e68fa0a0073ee | Popa1 -- pos=1 in Popa route |
| [RP3] | 454e11a80b002884 | Popa2 -- pos=2 in Popa route |
| **Branch safe for recursive delete** | | |
| [SafeBranch] | 0a4e9820cc015cae | "Before Sumwood Channel" -- under Michelle (034e6b8ccb01fffe); has Places group (7 WPs, none in route) + empty Tracks sub-branch; isBranchDeleteSafe=1; does NOT contain [TestTrack] |
| **Branch for Section 2.8 copy-branch test** | | |
| [RouteBranch] | ac4e2c500600b9aa | Navigation/Routes -- under Navigation (424e51840100072e); has Agua/Michelle/Popa groups + matching routes |
| **Branch for cut/paste move test** | | |
| [SomeBranch] | 784e76f880029e1e | "MichellToKuna 2011-07" -- under Michelle; has Places group (4 WPs, none in route) + Tracks sub-branch (empty); isBranchDeleteSafe=1 |
| **Track** | | |
| [TestTrack] | 1a4eed924904ebbe | "2005-11-25-SanDiego2Oceanside" -- in MandalaLogs/Tracks (984e7898480427f6); NOT in [SafeBranch] |
| **Paste destination** | | |
| [DST] | 6f4e72ceae0264de | "AguaAndTobobe c 2011-03-06" -- under Michelle (034e6b8ccb01fffe); empty (0 WPs, 0 routes, 0 child collections); accumulates test output throughout Section 2 and Section 3 |
| **Nested branch (has at least one child branch)** | | |
| [NestedBranch] | 234e412e3104296e | MandalaLogs -- ROOT level; has Places group + Tracks sub-branch |
| [ChildBranch] | 984e7898480427f6 | MandalaLogs/Tracks -- direct child branch of [NestedBranch]; used as recursive paste target in Section 5.9 |
| **Unsafe branch (WPs in external route)** | | |
| [UnsafeBranch] | b84e8c3c51009446 | oldE80/Groups -- child of oldE80 (a14ede0850000360); 62 descendant WPs in routes outside this branch (Michel_Agua, Michel_Sumwood, Timiteo groups whose routes are in oldE80/Routes) |
| **Name-collision WPs -- dynamic setup** | | |
| [WP_A] | [dynamic Section 5.10] | First of two same-named WPs; find in /api/nmdb or create via UI |
| [WP_B] | [dynamic Section 5.10] | Second same-named WP (same name as [WP_A], different UUID) |
| [SameNameWP] | [dynamic Section 5.11] | DB WP with same name as [IsolatedWP1] ("BOCAS1"); create via UI if needed |

### E80 runtime UUIDs (derived during test run)

| [Name] | Derived at | How |
|--------|-----------|-----|
| [E80_WP] | Test 3.1 | /api/db waypoints after [IsolatedWP1] upload |
| [E80_GR] | Test 3.2 | /api/db groups after [GroupWithRouteMembers] upload |
| [E80_RT] | Test 3.3 | /api/db routes after [TestRoute] upload |
| [E80_TK1] | Test 4.0 | /api/db tracks after first teensyBoat track recorded |
| [E80_TK2] | Test 4.0 | /api/db tracks after second track recorded |
| [E80_FRESH_WP] | Test 3.14 | /api/db waypoints after Test 3.14 PASTE_NEW -- byte 1=0x82, NOT in DB |
| [E80_FRESH_WP2] | Test 3.14c | /api/db waypoints after Test 3.14c setup PASTE_NEW -- second fresh UUID, NOT in DB |
| [E80_RP1], [E80_RP2], [E80_RP3] | Test 3.18 | /api/db route_waypoints for fresh-UUID route from Test 3.16b, sorted by position. [E80_RP1] MUST be Popa2 (454e11a80b002884) -- see Test 3.18 note. |

### Key supporting UUIDs

| Name | UUID | Context |
|------|------|---------|
| Navigation top-level | 424e51840100072e | Parent of Routes, Waypoints sub-branches |
| Navigation/Routes sub-branch | ac4e2c500600b9aa | = [RouteBranch] |
| Navigation/Waypoints sub-branch | e54ede600200feee | Parent of Bocas group |
| oldE80 top-level | a14ede0850000360 | Parent of Groups, Routes, Tracks, Waypoints |
| oldE80/Tracks branch | 2b4e3308ca00cf66 | Parent of [IsolatedWP1/2/3] and 120+ other nav WPs |
| oldE80/Groups branch | b84e8c3c51009446 | = [UnsafeBranch] |
| Popa group | 244e8e100800400a | = [GroupInRoute] = [GroupWithRouteMembers] |
| Popa route | f34efdd6070022e8 | = [TestRoute] |
| Bocas group | a74e90d60300a434 | = [GroupNoRoute] |
| StarfishBeach | 9d4e232a0500dd90 | member of Bocas group (= [GroupNoRoute]); deleted by Section 2.5 |
| Popa0 | 314e56cc09005332 | = [WPinRoute] = [RP1] |
| Popa1 | 8d4e68fa0a0073ee | = [RP2] |
| Popa2 | 454e11a80b002884 | = [RP3] |
| MandalaLogs | 234e412e3104296e | = [NestedBranch]; ROOT level; safe (no WPs in external routes) |
| MandalaLogs/Tracks | 984e7898480427f6 | = [ChildBranch]; contains [TestTrack] |
| AguaAndTobobe c 2011-03-06 | 6f4e72ceae0264de | = [DST]; empty; under Michelle |
| Before Sumwood Channel | 0a4e9820cc015cae | = [SafeBranch]; under Michelle |
| MichellToKuna 2011-07 | 784e76f880029e1e | = [SomeBranch]; under Michelle |
| Michelle top-level | 034e6b8ccb01fffe | Parent of DST, SafeBranch, SomeBranch, NestedBranch... |
| Part 1 - Before Trip | 214e7db00703a184 | Parent of [GroupNoRoute_Dissolve] |
| Places (Part 1) | 4e4e405a08033af4 | = [GroupNoRoute_Dissolve]; 3 members, none in route |
| Agua group | 204ecbd24500a678 | Navigation/Routes; 10 WPs all in Agua route |
| Agua route | d64e8c7e4400a186 | Navigation/Routes |
| Michelle group | 104e199a1500e646 | Navigation/Routes; 46 WPs all in Michelle route |
| Michelle route | 3b4e87f21400d81c | Navigation/Routes |
| Timiteo group | 1a4eaf5a8c00e922 | = [TestGroup]; oldE80/Groups; 6 members (t01-t06), none in route_waypoints (confirmed nm_groups.pl 2026-05-08) |
| Timiteo route | 844ed11696001cba | oldE80/Routes |

---

## Section 1 Reset to Known State

Run ALL before any test. **Write start time to file immediately -- this is the only fact
that survives context compaction.** The start time is needed for last_testrun.md; if it
is only in context it will be lost before the run ends.

```powershell
# Record start time to file BEFORE anything else -- survives context compaction
$start = (Get-Date -Format "yyyy-MM-dd HH:mm")
$start | Out-File -Encoding utf8 "C:\base_data\temp\raymarine\testrun_start.txt"
"Start time written: $start"
```

To recover after a compact:
```powershell
Get-Content "C:\base_data\temp\raymarine\testrun_start.txt"
```

```
# 1. Revert navMate.db to git baseline
git -C C:/dat/Rhapsody checkout -- navMate.db

# 2. Reload the database in navMate
curl -s "http://localhost:9883/api/test?op=refresh"

# 3. Enable suppress BEFORE any E80 operation (dialogs block if not set first)
curl -s "http://localhost:9883/api/test?op=suppress&val=1"

# 4. Clear E80 (suppress must already be on; auto-accepts confirmDialog; no-op if already empty)
curl -s "http://localhost:9883/api/test?op=clear_e80"
# wait for ProgressDialog FINISHED

# 5. Mark log with section tag (server-side snapshot for ?since=mark queries)
curl -s "http://localhost:9883/api/command?cmd=mark+Section+1+reset"
```

After reset: verify git shows navMate.db clean; /api/db returns empty E80.

**[RP1/RP2/RP3] are pre-resolved** (Popa0/1/2 confirmed from live DB). Use the static UUIDs
in the table above. No need to re-derive at reset unless the baseline DB changes.

Verification query (run if in doubt):
```
curl -s "http://localhost:9883/api/nmdb" | perl "C:/temp/nm_verify_rps.pl"
```
(Create that script if needed: filter route_waypoints where route_uuid=f34efdd6070022e8, sort by position, print first 3.)

---

## Section 2 Database Tests

For each test: tag the mark with the test number (`cmd=mark+Test+2.X`),
fire, read log since mark, verify /api/nmdb. No E80 required. See the
"Mark tagging convention" rule in the Toolbox.

**Test 2.0 runs first** and is self-contained (creates and destroys its own
test branch). It can be invoked standalone -- a Section 1 reset is not
required for it.

**Test 2.4/Test 2.5 ordering note:** Both tests need a group with no route refs. Test 2.4 (dissolve)
uses [GroupNoRoute_Dissolve] (Places/Part1, 4e4e405a08033af4) to preserve [GroupNoRoute]
(Bocas) for Test 2.5. Run Test 2.4 before Test 2.5.

---

### Test 2.0 Position precision -- 32 bisections force auto-renumber

Verifies the position allocator detects approaching float-precision
underflow and automatically renumbers the destination container.

Self-contained: creates a disposable branch, exercises the trigger, deletes
the branch. UUIDs are resolved at runtime, not from the static UUID table.

**Synchronization:** uses `Wait-NavCmdFinished` (see Toolbox) to gate each
command on its log FINISHED line; `Mark-Phase` (also in Toolbox) tags
phase boundaries in the log and resets the sync counter.

**Clipboard:** COPY is issued exactly once. `PASTE_NEW` / `PASTE_NEW_BEFORE`
preserve the clipboard (only CUT clears it via `navOpsDB.pm:803`), so the
same source WP is reused for all 34 inserts -- no re-COPY needed.

```powershell
$WP      = "ce4e43181f01b3ae"   # [IsolatedWP1] -- single COPY source
$URL_DB  = "http://localhost:9883/api/test?panel=database"

# --- Phase 1: setup ---
Mark-Phase "Test 2.0 start"
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null

# Create the disposable branch at root; poll for its log line.
curl.exe -s "http://localhost:9883/api/test?op=create_branch&name=PrecisionTestBranch" | Out-Null
$deadline = (Get-Date).AddMilliseconds(5000)
$branch = ""
Start-Sleep -Milliseconds 1000
while ((Get-Date) -lt $deadline -and -not $branch)
{
    $log = curl.exe -s "http://localhost:9883/api/log?since=mark"
    if ($log -match "navTest: create_branch 'PrecisionTestBranch' uuid=([0-9a-f]+)")
    {
        $branch = $matches[1]
        break
    }
    Start-Sleep -Milliseconds 250
}
if (-not $branch) { Write-Host "FAIL: create_branch did not appear in log"; return }

# --- Phase 2: anchor setup (one COPY, two PASTE_NEW) ---
Mark-Phase "Test 2.0 anchors"
curl.exe -s "$URL_DB&select=$WP&cmd=10200" | Out-Null
if (-not (Wait-NavCmdFinished -cmdName "COPY" -panel "database")) { return }
curl.exe -s "$URL_DB&select=$branch&right_click=$branch&cmd=10211" | Out-Null
if (-not (Wait-NavCmdFinished -cmdName "PASTE NEW" -panel "database")) { return }
curl.exe -s "$URL_DB&select=$branch&right_click=$branch&cmd=10211" | Out-Null
if (-not (Wait-NavCmdFinished -cmdName "PASTE NEW" -panel "database")) { return }

$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$wps  = $nmdb.waypoints | Where-Object { $_.collection_uuid -eq $branch } | Sort-Object position
if ($wps.Count -ne 2) { Write-Host "FAIL: expected 2 anchor WPs, got $($wps.Count)"; return }
$anchorB = $wps[-1].uuid   # higher position; push-down-stack places second paste above first

# --- Phase 3: 32 PASTE_NEW_BEFORE iterations on the upper anchor ---
Mark-Phase "Test 2.0 main loop"
for ($i = 1; $i -le 32; $i++)
{
    curl.exe -s "$URL_DB&select=$anchorB&right_click=$anchorB&cmd=10214" | Out-Null
    if (-not (Wait-NavCmdFinished -cmdName "PASTE NEW BEFORE" -panel "database")) { Write-Host "FAIL at iter $i"; return }
}

# --- Phase 4: verify ---
Mark-Phase "Test 2.0 verify"
$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$wps  = $nmdb.waypoints | Where-Object { $_.collection_uuid -eq $branch }
$n    = ($wps | Measure-Object).Count
$pos_distinct = (($wps | Select-Object -ExpandProperty position | Sort-Object -Unique) | Measure-Object).Count

# AutoCompact warning visibility spans phases, so widen the log read past
# the most recent mark by reading the whole ring tail. Match the warning
# anywhere -- it would have fired during Phase 3.
$log = curl.exe -s "http://localhost:9883/api/log?tail=2000"
$trig = if ($log -match "AutoCompact FLOAT positions") { 'YES' } else { 'NO' }
$loop_inserts = $n - 2   # subtract the 2 anchors to get the loop-insert count
Write-Host "Test 2.0: loop_inserts=$loop_inserts (REQUIRED 32), total_branch_count=$n, distinct_positions=$pos_distinct (expect $n), AutoCompact_seen=$trig (expect YES)"
if ($loop_inserts -ne 32) { Write-Host "HARD FAIL: 32 PASTE_NEW_BEFORE operations did not produce 32 WPs in the branch (loop inserts dropped)." }

# --- Phase 5: teardown ---
Mark-Phase "Test 2.0 teardown"
curl.exe -s "$URL_DB&select=$branch&right_click=$branch&cmd=10226" | Out-Null
if (-not (Wait-NavCmdFinished -cmdName "DELETE BRANCH" -panel "database"))
{
    Write-Host "TEARDOWN FAIL: DELETE BRANCH did not complete; PrecisionTestBranch may remain in DB."
}
```

Pass (all three required):
- **The 32 main-loop PASTE_NEW_BEFORE operations produced exactly 32 new
  waypoints in the branch** (loop_inserts == 32, equivalently branch
  count == 34 with the two anchors). Load-bearing: any count below 32
  loop inserts means a paste was silently dropped (test-driver queue
  overwrite, guard rejection, or other) and the test FAILS regardless of
  the other checks. Verify this first.
- Log contains at least one warning-color line
  `AutoCompact FLOAT positions for container <coll_uuid>`. Direct
  evidence the precision trigger fired.
- All 34 positions are distinct (no two WPs share a position value).

Fail (any of):
- loop_inserts != 32 (one or more loop pastes dropped, or duplicates
  produced).
- Log contains no `AutoCompact FLOAT positions` warning (the trigger
  never fired -- either eps is mis-tuned, the allocator is not wiring
  through, or the loop count is insufficient).
- Two or more WPs share a position value.

If the teardown DELETE BRANCH did not complete (the timeout message in
the script above prints), the next Test 2.0 run will see an orphan
`PrecisionTestBranch` instance and must clean it up before proceeding.

---

### Test 2.1 Copy WP -> Paste New

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.1"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10211"
```
Expected: new WP (fresh UUID) in [DST] (AguaAndTobobe); [IsolatedWP1] (BOCAS1) unchanged in oldE80/Tracks.

---

### Test 2.2 Cut WP -> Paste (move)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.2"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP2]&cmd=10201"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10210"
```
Expected: [IsolatedWP2] (BOCAS2) UUID unchanged; collection_uuid now = [DST].

---

### Test 2.3 Delete WP (success)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.3"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP3]&right_click=[IsolatedWP3]&cmd=10220"
```
Expected: [IsolatedWP3] (TOBOBE) absent from /api/nmdb waypoints.

---

### Test 2.4 Delete Group -- dissolve (members reparented)

Uses [GroupNoRoute_Dissolve] (Places/Part1), NOT Bocas, to preserve Bocas for Section 2.5 and Section 5.7.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.4"
curl -s "http://localhost:9883/api/test?panel=database&select=[GroupNoRoute_Dissolve]&right_click=[GroupNoRoute_Dissolve]&cmd=10221"
```
Expected: group shell ([GroupNoRoute_Dissolve]) deleted; 3 member WPs reparented to Part 1 - Before Trip; WP UUIDs unchanged.

---

### Test 2.5 Delete Group+WPS -- success (members not in route)

Uses [GroupNoRoute] = Bocas (a74e90d60300a434), intact after Test 2.4.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.5"
curl -s "http://localhost:9883/api/test?panel=database&select=[GroupNoRoute]&right_click=[GroupNoRoute]&cmd=10222"
```
Expected: [GroupNoRoute] (Bocas) and both member WPs (StarfishBeach + Fishfarm) deleted.

---

### Test 2.6 Delete Group+WPS -- blocked (members in route)

Uses [GroupInRoute] = Popa group (244e8e100800400a), all 11 WPs in Popa route.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.6"
curl -s "http://localhost:9883/api/test?panel=database&select=[GroupInRoute]&right_click=[GroupInRoute]&cmd=10222"
```
Expected: WARNING in log; group and members unchanged.
Note: "IMPLEMENTATION ERROR" sentinel is expected -- navTest bypasses menu guard, hits handler-level check.

---

### Test 2.7 Delete Branch (recursive, safe)

Uses [SafeBranch] = Before Sumwood Channel (0a4e9820cc015cae).
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.7"
curl -s "http://localhost:9883/api/test?panel=database&select=[SafeBranch]&right_click=[SafeBranch]&cmd=10226"
```
Expected: branch and all descendants gone (Places group + 7 member WPs + Tracks sub-branch).
Log: DELETE_BRANCH STARTED/FINISHED, no errors.

---

### Test 2.8 Copy Branch -> Paste New

Uses [RouteBranch] = Navigation/Routes (ac4e2c500600b9aa) -- source unchanged by paste new.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.8"
curl -s "http://localhost:9883/api/test?panel=database&select=[RouteBranch]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10211"
```
Expected: all groups/routes/WPs in Navigation/Routes duplicated with fresh UUIDs in [DST];
tracks silently skipped; [RouteBranch] unchanged.

---

### Test 2.9 Cut Branch -> Paste (move branch contents)

Uses [SomeBranch] = MichellToKuna 2011-07 (784e76f880029e1e).
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.9"
curl -s "http://localhost:9883/api/test?panel=database&select=[SomeBranch]&cmd=10201"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10210"
```
Expected: SomeBranch node itself moves to [DST] with UUID and all contents intact
(Places group + Tracks sub-branch stay inside it). parent_uuid changes from Michelle to DST.
Branch is NOT emptied -- moves as a unit, consistent with CUT+PASTE for all other node types.
Note: Test 2.17 says "in Michelle" -- stale after Test 2.9; UUID still valid, test still works.

---

### Test 2.10 Copy Route -> Paste New

Uses [TestRoute] = Popa route (f34efdd6070022e8).
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.10"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestRoute]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10211"
```
Expected: new route record in [DST] with fresh UUID; route_waypoints rebuilt referencing same WP UUIDs as source -- no new WP records created (SS1.6, SS12.3). Original Popa route unchanged.

---

### Test 2.11 Cut Route -> Paste (move)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.11"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestRoute]&cmd=10201"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10210"
```
Expected: Popa route collection_uuid = [DST]; UUID ([TestRoute]) unchanged;
route_waypoints sequence unchanged. (After this, [TestRoute] is in [DST] -- UUID still valid.)

---

### Test 2.12 Cut Track -> Paste (move)

Uses [TestTrack] = 2005-11-25-SanDiego2Oceanside (1a4eed924904ebbe).
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.12"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestTrack]&cmd=10201"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10210"
```
Expected: track collection_uuid = [DST]; UUID unchanged; track_points unchanged.

---

### Test 2.13a Paste New Before -- collection member (positional insertion before sibling)

Uses [IsolatedWP1] (ce4e43181f01b3ae) as source; [IsolatedWP2] (af4e23246d01bfa8) as anchor
(now in [DST] after Test 2.2).

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.13a"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP2]&right_click=[IsolatedWP2]&cmd=10214"
```
Expected: fresh-UUID copy at position < [IsolatedWP2]'s position and > predecessor's position.

---

### Test 2.13b Paste New After -- collection member (positional insertion after sibling)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.13b"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP2]&right_click=[IsolatedWP2]&cmd=10215"
```
Expected: fresh-UUID copy at position > [IsolatedWP2]'s position.

---

### Test 2.14a Copy-splice -- PASTE_NEW_BEFORE route point (insert duplicate between RP2 and RP3)

[TestRoute] is now in [DST] after Test 2.11 -- UUID unchanged.
Route point keys: `rp:[TestRoute]:[RPn]`

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.14a"
curl -s "http://localhost:9883/api/test?panel=database&select=rp:[TestRoute]:[RP1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=rp:[TestRoute]:[RP3]&right_click=rp:[TestRoute]:[RP3]&cmd=10214"
```
Expected: Popa0's WP appears again in route_waypoints between Popa1 and Popa2; total count = 12.

---

### Test 2.14b Cut-splice -- PASTE_BEFORE route point (reorder RP3 to before RP2)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.14b"
curl -s "http://localhost:9883/api/test?panel=database&select=rp:[TestRoute]:[RP3]&cmd=10201"
curl -s "http://localhost:9883/api/test?panel=database&select=rp:[TestRoute]:[RP2]&right_click=rp:[TestRoute]:[RP2]&cmd=10212"
```
Expected: Popa2 now before Popa1 in sequence; count unchanged.

---

### Test 2.15a Paste New Before -- route object as anchor

[TestRoute] = Popa route (f34efdd6070022e8, now in [DST] after Test 2.11). [IsolatedWP1] (ce4e43181f01b3ae) is still in its original location (oldE80/Tracks), untouched.

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.15a"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestRoute]&right_click=[TestRoute]&cmd=10214"
```
Expected: fresh WP copy at position < [TestRoute] position in [DST] collection; > predecessor position.
Verify via /api/nmdb: waypoints where collection_uuid=[DST], check position ordering.

---

### Test 2.15b Paste New After -- route object as anchor

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.15b"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestRoute]&right_click=[TestRoute]&cmd=10215"
```
Expected: another fresh WP at position > [TestRoute] position.

---

### Test 2.16 Paste Before/After -- group node as anchor

[TestGroup] = Timiteo (1a4eaf5a8c00e922), in oldE80/Groups (b84e8c3c51009446). [IsolatedWP1] as clipboard source.

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.16"
# PASTE_NEW_BEFORE (10214): fresh WP at position before Timiteo group in oldE80/Groups ordering
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestGroup]&right_click=[TestGroup]&cmd=10214"
```
Expected: fresh WP copy inserted at position < [TestGroup] position in oldE80/Groups; predecessor position midpoint used.
Group membership and group shell unchanged. WP is a sibling of the group, not a member.

---

### Test 2.17 Paste Before/After -- branch node as anchor

[SomeBranch] = MichellToKuna 2011-07 (784e76f880029e1e), in Michelle (034e6b8ccb01fffe). After Test 2.9 its contents were moved to [DST]; the branch shell still exists. [IsolatedWP1] as clipboard source.

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.17"
# PASTE_NEW_BEFORE (10214): fresh WP at position before [SomeBranch] in Michelle's ordering
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[SomeBranch]&right_click=[SomeBranch]&cmd=10214"
```
Expected: fresh WP copy inserted at position < [SomeBranch] position in Michelle's children ordering.
[SomeBranch] (empty shell) is unchanged.

---

### Test 2.18a Paste New Before -- route clipboard before waypoint anchor

[IsolatedWP2] (af4e23246d01bfa8) is in [DST] after Test 2.2; it is the positional anchor.

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.18a"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestRoute]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP2]&right_click=[IsolatedWP2]&cmd=10214"
```
Expected: new route record in [DST] at position < [IsolatedWP2]; fresh route UUID (byte 1=0x82);
route_waypoints reference same WP UUIDs as source (SS1.6); no new WP records created.

---

### Test 2.18b Paste New Before -- group clipboard before waypoint anchor

[TestGroup] = Timiteo (1a4eaf5a8c00e922); [IsolatedWP2] as anchor.

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+2.18b"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestGroup]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP2]&right_click=[IsolatedWP2]&cmd=10214"
```
Expected: new group (fresh UUID) + 6 fresh-UUID member WPs in [DST] at position < [IsolatedWP2].
[TestGroup] and its members unchanged in oldE80/Groups.

---

## Section 3 E80 Tests

E80 must be connected and empty after Section 1 reset. Run these after Section 2 completes cleanly.

Mark tagging follows the same rule as Section 2: tag each test's mark with
its number, e.g. `cmd=mark+Test+3.4`. See the "Mark tagging convention"
rule in the Toolbox.

**State note entering Section 3:** [TestRoute] (f34efdd6070022e8) is now in [DST] after Test 2.11 -- select by UUID still works. [GroupWithRouteMembers] = Popa group (244e8e100800400a) is intact (Test 2.6 was blocked).

**Test 3.1-Test 3.3 dual role:** Test 3.1, Test 3.2, and Test 3.3 each populate E80 with data that later Section 3 steps
depend on, but each is also an actual test in its own right (single WP, group, route via
UUID-preserving paste). All three must pass before proceeding.

---

### Test 3.1 Paste WP to E80 (UUID-preserving upload)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.1"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210"
```
Wait for ProgressDialog FINISHED.
Expected: [IsolatedWP1] (BOCAS1, ce4e43181f01b3ae) on E80 as ungrouped WP with same UUID.
Note [E80_WP] = ce4e43181f01b3ae from /api/db waypoints.

---

### Test 3.2 Paste Group to E80 (UUID-preserving upload)

[GroupWithRouteMembers] = Popa group (244e8e100800400a); 11 member WPs all in [TestRoute].
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.2"
curl -s "http://localhost:9883/api/test?panel=database&select=[GroupWithRouteMembers]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210"
```
Wait for ProgressDialog FINISHED.
Expected: Popa group (244e8e100800400a) on E80; all 11 member WPs present with DB UUIDs preserved.
Note [E80_GR] = 244e8e100800400a from /api/db groups.

---

### Test 3.3 Paste Route to E80 (UUID-preserving upload)

Member WPs must already be on E80 -- Test 3.2 put them there; SS10.10 pre-flight verifies this.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.3"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestRoute]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10210"
```
Wait for ProgressDialog FINISHED.
Expected: Popa route (f34efdd6070022e8) on E80; route_waypoints sequence matches DB (11 WPs, same UUIDs, same positional order).
Note [E80_RT] = f34efdd6070022e8 from /api/db routes.

---

### Test 3.4 Copy E80 WP -> Push to DB (push-classified)

[E80_WP] = [IsolatedWP1] UUID (ce4e43181f01b3ae). That UUID is in DB -> clipboard_class='push'.
PUSH (10250) is offered at DB destination; PASTE is not.

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.4"
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_WP]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10250"
```
Expected: [IsolatedWP1] DB record updated from E80 field values (name, lat, lon, comment,
depth_cm). DB-managed fields (wp_type, color, source) preserved. collection_uuid unchanged.
Clipboard cleared. Log: PUSH STARTED/FINISHED, no errors.

---

### Test 3.5 Copy E80 WP -> Paste New to DB (fresh UUID)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.5"
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_WP]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10211"
```
Expected: new WP with fresh navMate UUID (byte 1 = 0x82) != [E80_WP].

---

### Test 3.6 Delete E80 WP

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.6"
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_WP]&right_click=[E80_WP]&cmd=10220"
```
Wait for ProgressDialog FINISHED. Expected: [E80_WP] absent from /api/db.

---

### Test 3.6b Delete E80 Group+WPS -- blocked (member in route)

Prerequisite: Test 3.3 has run; [E80_GR] (Popa, 244e8e100800400a) and [E80_RT] (Popa route,
f34efdd6070022e8) are both present on E80. [E80_RT] references [E80_GR]'s members.

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.6b"
curl -s "http://localhost:9883/api/test?panel=e80&select=244e8e100800400a&right_click=244e8e100800400a&cmd=10222"
```

No ProgressDialog for this path (operation is blocked before any E80 write).

Expected (suppress on): `ERROR` line in log containing "Cannot delete group" and "used in a
route". No IMPLEMENTATION ERROR. No ProgressDialog STARTED. [E80_GR] and all its member
waypoints present in /api/db. [E80_RT] unchanged.

Pass: log has ERROR with route-block message; /api/db shows group + members intact.
Fail: IMPLEMENTATION ERROR in log, or group/WPs absent from /api/db, or ProgressDialog
STARTED without expected ERROR.

---

### Test 3.7 Delete via E80 Routes header (all routes) -- SS8.2

Routes MUST be deleted before any group delete. While route_waypoints reference group
members, DEL_GROUP_WPS will be blocked by the handler-level route-dependency check
(Test 3.6b verified this). Deleting routes first clears the dependency.
```
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+3.7"
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10223"
```
Wait for ProgressDialog FINISHED. Expected: E80 routes empty; member WPs preserved.

---

### Test 3.8 Delete via E80 Groups header (all groups) -- SS8.2

```
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+3.8"
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10222"
```
Wait for ProgressDialog FINISHED. Expected: E80 groups and all member WPs deleted.

---

### Test 3.9a Re-upload Popa group to E80 (Test 3.8 deleted all groups)

```
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+3.9a"
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&cmd=10200"
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210"
```
Wait for ProgressDialog FINISHED.
Expected: Popa group (244e8e100800400a) present on E80 with all 11 member WPs.

---

### Test 3.9b Delete E80 Group + members via specific group node (DEL_GROUP_WPS)

```
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+3.9b"
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=[E80_GR]&right_click=[E80_GR]&cmd=10222"
```
Wait for ProgressDialog FINISHED.
Expected: [E80_GR] and all member WPs (11 Popa WPs) absent from /api/db.

---

### Test 3.10a Re-upload IsolatedWP1 to E80 (if deleted by Test 3.6)

If [E80_WP] was deleted in Test 3.6, re-upload [IsolatedWP1] (ce4e43181f01b3ae):
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.10a"
curl -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210"
```
Wait for ProgressDialog FINISHED.
Expected: at least one ungrouped WP present on E80.
Skip (NOT_RUN) if [E80_WP] is still present from Test 3.1.

---

### Test 3.10b Delete via E80 My Waypoints (all ungrouped WPs) -- SS8.2

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.10b"
curl -s "http://localhost:9883/api/test?panel=e80&select=my_waypoints&right_click=my_waypoints&cmd=10222"
```
Wait for ProgressDialog FINISHED.
Expected: all ungrouped WPs deleted; named groups unaffected.

---

### Test 3.11a Re-upload Popa group to E80 (if deleted by Test 3.9b)

If [E80_GR] is absent after Test 3.9b:
```
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+3.11a"
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&cmd=10200"
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210"
```
Wait for ProgressDialog FINISHED.
Expected: Popa group (244e8e100800400a) present on E80 with all 11 member WPs.
Skip (NOT_RUN) if [E80_GR] is still present.

---

### Test 3.11b Copy E80 Group -> Push to DB (group push-classified)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.11b"
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_GR]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10250"
```
Expected: Popa group name and 11 member WPs (name/lat/lon/comment/depth_cm) updated from E80.
DB-managed fields (wp_type, color, source) preserved. Collection memberships unchanged.
Clipboard cleared. Log: PUSH STARTED/FINISHED, no errors.

---

### Test 3.12a Re-upload [TestRoute] to E80 (if deleted by Test 3.7)

If [E80_RT] is absent after Test 3.7:
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.12a"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestRoute]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10210"
```
Wait for ProgressDialog FINISHED.
Expected: [TestRoute] (Popa route, f34efdd6070022e8) present on E80.
Skip (NOT_RUN) if [E80_RT] is still present.

---

### Test 3.12b Copy E80 Route -> Push to DB (route push-classified)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.12b"
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_RT]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10250"
```
Expected: route name/color/comment updated from E80; route_waypoints rebuilt to match E80 sequence.
Member WP UUIDs preserved; no new WP records. collection_uuid unchanged. Clipboard cleared.
Log: PUSH STARTED/FINISHED, no errors.

---

### Test 3.13 Copy E80 Group+Route -> Push to DB (multi-item push)

After Test 3.11b and Test 3.12b, E80 has both [E80_GR] (Popa group + 11 WPs) and [E80_RT] (Popa route).
Both UUIDs in DB -> clipboard_class='push'. Select both simultaneously (cmd=10250):
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.13"
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_GR],[E80_RT]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10250"
```
Expected: group (name + 11 member WPs) and route (name/color/route_waypoints) both pushed.
All UUIDs preserved; no new records. Clipboard cleared. No ERROR or WARNING.
Note: SS12.1 ordering only matters for paste (new items); push updates existing records and
needs no ordering guarantee.

---

### Test 3.14 Paste New WP to E80 (fresh UUID)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.14"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP2]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211"
```
Wait for ProgressDialog FINISHED. Expected: new WP on E80, fresh UUID != [IsolatedWP2], name="BOCAS2".

---

### Test 3.14b Copy E80 fresh-UUID WP -> Paste to DB (paste-classified: absent)

The Test 3.14 PASTE_NEW created a WP on E80 with a fresh UUID (byte 1 = 0x82) NOT in DB.
Determine that fresh UUID from /api/db (it is NOT ce4e43181f01b3ae = [IsolatedWP1]).
Call it [E80_FRESH_WP]. clipboard_class='paste' when it's copied (UUID absent from DB).

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.14b"
# COPY the fresh-UUID WP from E80 (find its UUID in /api/db waypoints after Test 3.14)
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_FRESH_WP]&cmd=10200"
# PASTE to DB (offered because paste-classified)
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10210"
```
Expected: new WP record in [DST] with [E80_FRESH_WP] UUID preserved (byte 1 = 0x82). Name = "BOCAS2".
Log: COPY STARTED/FINISHED, PASTE STARTED/FINISHED, no errors.

---

### Test 3.14c Mixed-classified E80 clipboard: status bar + PASTE_NEW

**State after Test 3.14b:** [E80_FRESH_WP] is on E80 and its UUID is NOW IN DB (Test 3.14b
pasted it there) -- it is push-classified. [E80_WP] (IsolatedWP1) was deleted back in Test 3.6
and is NOT on E80. The test requires two E80 WPs: one push-classified and one paste-classified.

**Setup -- create [E80_FRESH_WP2]:** PASTE_NEW [IsolatedWP1] from DB to E80 to generate a second
fresh UUID that is NOT in DB (paste-classified). Call it [E80_FRESH_WP2]; derive UUID from /api/db.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.14c+setup"
curl -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211"
```
Wait for ProgressDialog FINISHED. Note [E80_FRESH_WP2] UUID from /api/db waypoints
(it will be byte 1 = 0x82, different from ce4e43181f01b3ae and different from [E80_FRESH_WP]).

Now select both [E80_FRESH_WP] (push-classified: UUID in DB) and [E80_FRESH_WP2]
(paste-classified: UUID not in DB) -> clipboard_class='mixed'.

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.14c"
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_FRESH_WP],[E80_FRESH_WP2]&cmd=10200"
```
Verify status bar text in navMate UI: "[e80] copy (2) -- Paste/Push not available: ..."

Execute PASTE_NEW (10211) -- the only collection option for mixed clipboard:
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.14c+paste"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10211"
```
Expected: two WP records inserted in [DST] with fresh navMate UUIDs (PASTE_NEW always
assigns fresh UUIDs). Name values preserved from E80. No IMPL ERROR. Log clean.

---

### Test 3.15 Paste New Group to E80 (all-fresh UUIDs)

[TestGroup] = Timiteo (1a4eaf5a8c00e922); 6 members (t01-t06), none in any route, under oldE80/Groups.
Survives all Section 2 tests. Name "Timiteo" never conflicts with E80 state at Test 3.15 time (E80 has Popa from Test 3.11b/Test 3.12b).
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.15"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestGroup]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211"
```
Wait for ProgressDialog FINISHED. Expected: new group on E80 with fresh UUID; each of 6 member WPs has fresh UUID; group name "Timiteo".
Note: leaves Timiteo group (and members) on E80; Tests 5.6a-5.6c clear all E80 content before the route-dependency test.

---

### Test 3.16a Delete all E80 routes (if same-named route present)

Check /api/db routes. If a same-named route exists on E80:
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.16a"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10223"
```
Wait for ProgressDialog FINISHED.
Expected: E80 routes empty.
Skip (NOT_RUN) if E80 routes were already empty.

---

### Test 3.16b Paste New Route to E80 (fresh route UUID, WP refs preserved)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.16b"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestRoute]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10211"
```
Wait for ProgressDialog FINISHED.
Expected: new route on E80 with fresh UUID (byte 1=0x82); member WPs (from Test 3.11a) referenced by UUID; no new WP records created.

---

### Test 3.17 Multi-select WPs -> Paste to E80 (homogeneous flat set)

**PRE-CLEANUP REQUIRED:** Tests 3.14 and 3.14c leave two fresh-UUID WPs on E80 with names that
collide with [IsolatedWP1] and [IsolatedWP2]. Both must be deleted before running Test 3.17:
- [E80_FRESH_WP2] -- named "BOCAS1" (fresh UUID from Test 3.14c); collides with [IsolatedWP1]
- [E80_FRESH_WP] -- named "BOCAS2" (fresh UUID from Test 3.14); collides with [IsolatedWP2]

Delete both from E80 before proceeding (select each by its fresh UUID and fire DELETE_WAYPOINT):
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.17+pre-cleanup"
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_FRESH_WP2]&right_click=[E80_FRESH_WP2]&cmd=10220"
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_FRESH_WP]&right_click=[E80_FRESH_WP]&cmd=10220"
```
Wait for ProgressDialog FINISHED after each. Verify /api/db shows neither UUID remaining.

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.17"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1],[IsolatedWP2]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210"
```
Wait for ProgressDialog FINISHED. Expected log: COPY with items=2; PASTE with items=2.

---

### Test 3.18 Route point Paste Before/After on E80

Requires a route on E80 with 3+ waypoints. After Test 3.16b, the fresh-UUID route from PASTE_NEW
serves as the source. Derive its route UUID from /api/db routes at this point.
Route point keys: `rp:[E80_RT]:[E80_RP_UUID]`

**KNOWN ISSUE -- Popa0 is duplicated:** The Test 3.16b fresh-UUID route inherits the Test 2.14a
copy-splice: Popa0 (314e56cc09005332) appears twice. Copying Popa0 grabs 2 clipboard items
and triggers the intra-clipboard name-collision abort. Do NOT use Popa0 as source.

Use these fixed UUIDs -- all three are unique in the post-Test-2.14a route (Popa0 appears twice
and must not be used; these three each appear exactly once):
- [E80_RP1] = Popa2 (454e11a80b002884) -- pos=1 in the 12-WP fresh route
- [E80_RP2] = Popa1 (8d4e68fa0a0073ee) -- pos=2
- [E80_RP3] = Popa3 (384e30760c00e63e) -- pos=4 (pos=3 is the duplicate Popa0; skip it)

**PowerShell variable syntax -- CRITICAL:** When storing the fresh-UUID route's UUID in a variable
(e.g., `$E80_RT_FRESH`) and referencing it in a string followed by `:`, PowerShell parses
`$E80_RT_FRESH:` as a drive reference and fails. Always use `${E80_RT_FRESH}` (braces) in
string interpolation, e.g., `"rp:${E80_RT_FRESH}:${E80_RP1}"`.

Derive the fresh route UUID from /api/db and store it before building route-point keys:
```powershell
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$E80_RT_FRESH = ($db.routes.PSObject.Properties | Where-Object { $_.Value.name -match "Popa" -and $_.Value.uuid -ne "f34efdd6070022e8" }).Name
"Fresh route UUID: $E80_RT_FRESH"
# Then build keys using braces: "rp:${E80_RT_FRESH}:454e11a80b002884"
```

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+3.18"
# Copy [E80_RP1] (Popa2 -- unique in route)
curl -s "http://localhost:9883/api/test?panel=e80&select=rp:[E80_RT]:[E80_RP1]&cmd=10200"
# Paste Before [E80_RP3]: inserts RP1's WP between RP2 and RP3
curl -s "http://localhost:9883/api/test?panel=e80&select=rp:[E80_RT]:[E80_RP3]&right_click=rp:[E80_RT]:[E80_RP3]&cmd=10212"
```
Wait for ProgressDialog FINISHED. Expected: [E80_RP1] WP between [E80_RP2] and [E80_RP3]; count +1.

---

## Section 4 Track Tests (requires teensyBoat on port 9881)

Mark tagging follows the same rule as Section 2: tag each test's mark with
its number, e.g. `cmd=mark+Test+4.1`. See the "Mark tagging convention"
rule in the Toolbox.

### Test 4 Pre-Check: teensyBoat Availability (run first -- do not skip)

```powershell
$tb = try { curl.exe -s "http://localhost:9881/api/command?cmd=SIM" | ConvertFrom-Json } catch { $null }
if ($tb -and $tb.ok) { "teensyBoat is running -- proceed with Section 4" }
else { "teensyBoat NOT available -- mark all Section 4 steps NOT_RUN and skip to Section 5" }
```

If NOT available: mark Section 4.0 through Section 4.5 all NOT_RUN and continue to Section 5.

---

### Test 4.0 Create test tracks on E80

Drive to create at least two short tracks. Note E80-assigned UUIDs as [E80_TK1], [E80_TK2].
**Track creation command sequence (all curl to port 9881 for boat, port 9883 for navMate):**

```powershell
# Step 1 -- disable autopilot and set heading/speed
curl.exe -s "http://localhost:9881/api/command?cmd=AP%3D0"
curl.exe -s "http://localhost:9881/api/command?cmd=H%3D90"    # heading East
curl.exe -s "http://localhost:9881/api/command?cmd=S%3D50"    # 50 knots

# Step 2 -- verify motion (confirm non-zero sog in SIM output)
$seq = (curl.exe -s "http://localhost:9881/api/log?tail=1" | ConvertFrom-Json).seq
curl.exe -s "http://localhost:9881/api/command?cmd=SIM" | Out-Null
Start-Sleep 2
curl.exe -s "http://localhost:9881/api/log?since=$seq" | ConvertFrom-Json |
    Select-Object -Expand lines | Where-Object { $_.text -match "^SIM" } |
    ForEach-Object { $_.text }

# Step 3 -- mark navMate log and start recording
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+4.0+record" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=t+start"

# Step 4 -- drive legs (3-leg triangle, ~30s total at 50 knots)
# Run in background; do NOT sleep before first echo
```

Background leg script (run with run_in_background):
```
echo "L1-start" && Start-Sleep 10 && curl.exe -s "http://localhost:9881/api/command?cmd=H%3D210" | Out-Null && echo "L2-start" && Start-Sleep 10 && curl.exe -s "http://localhost:9881/api/command?cmd=H%3D330" | Out-Null && echo "L3-start" && Start-Sleep 10 && echo "ALL_LEGS_DONE"
```

After ALL_LEGS_DONE notification:
```powershell
# Step 5/6/7 -- stop, name, save (order is critical: stop -> name -> save)
curl.exe -s "http://localhost:9883/api/command?cmd=t+stop"
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/command?cmd=t+name+Track1"   # <= 15 chars
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/command?cmd=t+save"
Start-Sleep 2

# Verify save in log: look for 'got track(uuid)' line
curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json |
    Select-Object -Expand lines | Where-Object { $_.text -match "got track|ERROR|WARNING" } |
    ForEach-Object { $_.text }
```

Repeat the full sequence to create Track2. After two tracks saved, note [E80_TK1] and [E80_TK2]
UUIDs from `/api/db` tracks.

Non-fatal expected: GET_CUR2 ERROR after EVENT(0); "TRACK OUT OF BAND" after save.
Verify save: "got track(uuid) = 'name'" in log.

After both tracks are created, park the boat:
```
curl.exe -s "http://localhost:9881/api/command?cmd=S%3D0"
```
**NEVER use `STOP` -- that halts the simulator entirely. `S%3D0` zeroes speed only.**

**UUID behavior:** PASTE from E80 preserves the E80-assigned UUID (byte 1 = B2) -- identify
in /api/nmdb by UUID after Test 4.1/Test 4.2. PASTE_NEW assigns a fresh navMate UUID (byte 1 = 0x82)
-- identify by name after Test 4.4.
Color conversion: E80 index -> aabbggrr: 0=ff0000ff, 1=ff00ffff, 2=ff00ff00, 3=ffff0000, 4=ffff00ff, 5=ff000000.

---

### Test 4.1 Copy E80 Track -> Paste to DB (download, track remains on E80)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+4.1"
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_TK1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10210"
```
Wait for ProgressDialog FINISHED. Expected: track in DB with E80 UUID preserved (byte 1 = B2); still on E80.
Verify: /api/nmdb tracks where uuid = [E80_TK1].

---

### Test 4.2 Cut E80 Track -> Paste to DB (download + E80 erase)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+4.2"
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_TK2]&cmd=10201"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10210"
```
Wait for ProgressDialog FINISHED. Expected: track in DB with E80 UUID preserved (byte 1 = B2); TRACK_CMD_ERASE sent; absent from /api/db. Identify by UUID in /api/nmdb.

---

### Test 4.3 Guard -- Paste Track to E80 blocked (SS10.8)

[TestTrack] is now in [DST] after Test 2.12, UUID unchanged.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+4.3"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestTrack]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210"
```
Expected: `ERROR - Cannot paste to E80 tracks header -- tracks are read-only`; E80 unchanged.

---

### Test 4.4 Paste New E80 Track to DB (download, fresh UUID)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+4.4"
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_TK1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10211"
```
Wait for ProgressDialog FINISHED.
Expected: PASTE_NEW succeeds. Track in DB with fresh navMate UUID; track_points present.
[E80_TK1] still on E80 (COPY not CUT). Log: PASTE_NEW STARTED/FINISHED, no errors.
(SS10.3 guard for DB-to-DB track copy is tested in Section 5.5, not here.)

---

### Test 4.5 Delete via E80 Tracks header -- SS8.2

[E80_TK1] is still on E80 after Section 4.4 (COPY, not CUT). At least one track is present.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+4.5"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10225"
```
Wait for ProgressDialog FINISHED. Expected: all E80 tracks erased; /api/db tracks empty.
This exercises the fourth SS8.2 header-node delete rule.

---

## Section 5 Pre-flight and Guard Tests

All blocked operations produce WARNING or IMPLEMENTATION ERROR with no data change.
Any test header carrying `PREREQUISITE: <label>` is structurally non-runnable until the named infrastructure exists; record as `NOT_RUN (<label>)`.

Mark tagging follows the same rule as Section 2: tag each test's mark with
its number, e.g. `cmd=mark+Test+5.2`. See the "Mark tagging convention"
rule in the Toolbox.

---

### Test 5.1 DEL_WAYPOINT blocked -- WP referenced in route

[WPinRoute] = Popa0, in Popa route.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.1"
curl -s "http://localhost:9883/api/test?panel=database&select=[WPinRoute]&right_click=[WPinRoute]&cmd=10220"
```
Expected: WARNING in log; [WPinRoute] still in /api/nmdb.

---

### Test 5.2 DEL_BRANCH blocked -- member WP in external route

[UnsafeBranch] = oldE80/Groups; 62 WPs in routes outside this branch.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.2"
curl -s "http://localhost:9883/api/test?panel=database&select=[UnsafeBranch]&right_click=[UnsafeBranch]&cmd=10226"
```
Expected: ERROR in log ("Cannot delete ... waypoints are referenced by external routes"); branch unchanged.
Note: log says ERROR not WARNING; both indicate the guard fired correctly.

---

### Test 5.3 Paste blocked -- DB cut -> E80 destination (SS9, SS10.5)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.3"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10201"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210"
```
Expected: paste rejected; WARNING; E80 unchanged; [IsolatedWP1] still in DB (cut not consumed).

---

### Test 5.4a Delete BOCAS1 from E80 (if present after Test 3.17)

Check /api/db for UUID ce4e43181f01b3ae. If present:
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.4a"
curl -s "http://localhost:9883/api/test?panel=e80&select=ce4e43181f01b3ae&right_click=ce4e43181f01b3ae&cmd=10220"
```
Wait for ProgressDialog FINISHED.
Expected: ce4e43181f01b3ae absent from /api/db.
Skip (NOT_RUN) if BOCAS1 not present on E80.

---

### Test 5.4b Delete BOCAS2 from E80 (if present after Test 3.17)

BOCAS2 may have a fresh UUID from Test 3.14 PASTE_NEW. Find it via /api/db name match. If present:
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.4b"
curl -s "http://localhost:9883/api/test?panel=e80&select=[BOCAS2_UUID]&right_click=[BOCAS2_UUID]&cmd=10220"
```
Wait for ProgressDialog FINISHED.
Expected: BOCAS2 (fresh UUID) absent from /api/db.
Skip (NOT_RUN) if BOCAS2 not present on E80.

---

### Test 5.4c Paste blocked -- any clipboard -> E80 tracks header (SS10.8)

Prerequisite: BOCAS1 and BOCAS2 absent from E80 (Tests 5.4a-5.4b). If either remains, the E80-wide
name collision guard fires before SS10.8 and the test does NOT verify SS10.8.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.4c"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210"
```
Expected: `ERROR - Cannot paste to E80 tracks header -- tracks are read-only`; E80 unchanged.

---

### Test 5.5 Paste blocked -- DB copy track -> DB paste (no UUID-preserving copy path)

[TestTrack] is in [DST] after Test 2.12, UUID unchanged.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.5"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestTrack]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[DST]&right_click=[DST]&cmd=10210"
```
Expected: WARNING or IMPLEMENTATION ERROR; DB unchanged.

---

### Test 5.6a Delete all E80 routes (clear before route-dependency test)

Test 3.15 left Timiteo group and possibly other content on E80. Clear all routes first.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.6a"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10223"
```
Wait for ProgressDialog FINISHED. **HARD STOP: do NOT proceed to Test 5.6b until FINISHED is
confirmed in the log.** 5.6b queues behind a hung dialog and runs unexpectedly late, leaving
E80 non-empty. This failure mode has occurred in cycles 13 and 14.

**If no FINISHED after flat sleep:**
```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=dialog_state" | Out-Null
Start-Sleep 2
$r = curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json
$isActive = $r.lines | Where-Object { $_.text -match "dialog_state: active" }
if ($isActive) {
    curl.exe -s "http://localhost:9883/api/command?cmd=close_dialog" | Out-Null
    Start-Sleep 3
    # Re-read log to confirm FINISHED now appears
    $r2 = curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json
    $r2.lines | Where-Object { $_.text -match "ProgressDialog.*FINISHED|dialog_state" } | ForEach-Object { "$($_.seq)  $($_.text)" }
}
```
Do not fire Test 5.6b until the dialog is confirmed idle (either FINISHED in log or dialog_state: idle).
Expected: /api/db routes empty.

---

### Test 5.6b Delete all E80 groups+WPs

Prerequisite: Test 5.6a ProgressDialog is confirmed FINISHED. Do not fire until confirmed.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.6b"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10222"
```
Wait for ProgressDialog FINISHED. Apply same close_dialog remedy as Test 5.6a if FINISHED is not seen.
Expected: /api/db groups empty; all member WPs deleted.

---

### Test 5.6c Delete all E80 ungrouped WPs (no-op if none)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.6c"
curl -s "http://localhost:9883/api/test?panel=e80&select=my_waypoints&right_click=my_waypoints&cmd=10222"
```
Wait for ProgressDialog FINISHED.
Expected: /api/db returns empty E80 (no waypoints, groups, routes, or tracks).

**Edge case (PASS, no-op):** when E80 has 0 ungrouped WPs, the `my_waypoints` tree node does not exist
and the command logs `WARNING: navTest: fire cmd=10222 - no right_click_node set` instead of executing
the delete. There is no ProgressDialog. This is the documented no-op path -- count PASS as long as
/api/db is still empty.

---

### Test 5.6d Route dependency check -- paste route before member WPs exist on E80 (SS10.10)

Prerequisite: Tests 5.6a-5.6c have cleared E80 completely. Verify /api/db empty before proceeding.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.6d"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestRoute]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10210"
```
Expected: `ERROR - Route 'Popa': member waypoint(s) not on E80 and not in clipboard: [UUIDs]`; E80 routes unchanged.
Note: E80 is empty entering Test 5.7; Test 5.7 pastes Timiteo fresh from this clean state.

---

### Test 5.7 Ancestor-wins -- accept path (SS6.2)

[TestGroup] = Timiteo (1a4eaf5a8c00e922); [TestGroupMember] = t01 (d44e40468d000d96).
Select the group AND one of its members; ancestor-wins logic should upload the group once
and suppress t01 as a separate ungrouped WP.
Prerequisite: E80 is empty (Tests 5.6a-5.6c cleared it; the Timiteo group from Test 3.15 is gone).
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.7"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestGroup],[TestGroupMember]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211"
```
Wait for ProgressDialog FINISHED.
Expected: Timiteo group on E80 with fresh UUID; t01 NOT present as a separate ungrouped WP.
Log: ancestor-wins resolution noted; confirmation dialog auto-accepted.

---

### Test 5.8 Ancestor-wins -- abort path (SS6.2)

[TestGroup] = Timiteo (1a4eaf5a8c00e922); [TestGroupMember] = t01 (d44e40468d000d96).
Select the group AND one of its members; the ancestor-wins resolution absorbs t01 into
the group and fires a confirmation dialog. With outcome=reject the dialog is auto-rejected
and `_doPaste` returns before any E80 write -- no name-collision check or downstream guard
runs. Works regardless of whether Timiteo is on E80 from Test 5.7.

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.8"
# Switch suppress to reject mode for this test only
curl -s "http://localhost:9883/api/test?op=suppress&val=1&outcome=reject"

curl -s "http://localhost:9883/api/test?panel=database&select=[TestGroup],[TestGroupMember]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211"

# Restore default accept mode
curl -s "http://localhost:9883/api/test?op=suppress&val=1&outcome=accept"
```

Expected: `PASTE NEW (e80) STARTED` and `PASTE NEW (e80) FINISHED` lines present and
adjacent; **no `ProgressDialog 'Paste'` line** between them (the function returned at the
ancestor-wins step before opening any dialog); **no `ERROR` / `IMPLEMENTATION` line**
(it was not a name-collision or other guard abort); /api/db shows no new items added by
this step.

**Important:** the "absorbed by an ancestor" message text only appears in the log when a
real `confirmDialog` UI fires. With `suppress_confirm` on, the dialog is bypassed and the
message is never logged -- so do NOT grep for "absorbed" as a pass criterion. The
PASTE-NEW-without-ProgressDialog-and-without-error signature IS the reject-path evidence.

---

### Test 5.9 Recursive paste guard -- paste Branch into its own descendant

[NestedBranch] = MandalaLogs; [ChildBranch] = MandalaLogs/Tracks.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.9"
curl -s "http://localhost:9883/api/test?panel=database&select=[NestedBranch]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[ChildBranch]&right_click=[ChildBranch]&cmd=10211"
```
Expected: WARNING "recursive paste" or similar; DB unchanged.

---

### Test 5.10 Pre-flight: intra-clipboard name collision (SS10.2 Step 6)

Need two WPs with same name, different UUIDs. Check /api/nmdb; create via UI if needed.
oldE80/Tracks has many "BOCAS1-001" etc. -- check if any duplicates exist in DB first.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.10"
curl -s "http://localhost:9883/api/test?panel=database&select=[WP_A],[WP_B]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211"
```
Expected: hard-abort (WARNING identifying colliding name); E80 unchanged.

---

### Test 5.11a Upload IsolatedWP1 to E80 (setup: put BOCAS1 on E80 for name collision test)

[SameNameWP] = a DB WP with name "BOCAS1" (same as [IsolatedWP1]); create via UI if needed.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.11a"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210"
```
Wait for ProgressDialog FINISHED.
Expected: [IsolatedWP1] (BOCAS1, ce4e43181f01b3ae) present on E80.

---

### Test 5.11b Pre-flight: E80-wide name collision (SS10.2 Step 7)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.11b"
curl -s "http://localhost:9883/api/test?panel=database&select=[SameNameWP]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210"
```
Expected: hard-abort (WARNING: conflicting name); E80 unchanged (second WP not created).

---

### Test 5.12 UUID conflict -- clean create path

Source UUID must not be on E80 at this point. Use [IsolatedWP2] (af4e23246d01bfa8):
in DB at [DST] after Test 2.2; was on E80 briefly in Test 3.17 and deleted in Test 5.4b;
not on E80 at Test 5.12 time. Name "BOCAS2" also not present on E80 (entering 5.12 the
E80 has BOCAS1 + Timiteo group + 6 t01-t06 members from Tests 5.7/5.11a).

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.12"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP2]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210"
```
Wait for ProgressDialog FINISHED.
Expected: [IsolatedWP2] appears on E80 with UUID preserved (af4e23246d01bfa8); no
conflict-resolution dialog fires; only the standard Paste ProgressDialog appears in the
log; PASTE STARTED/FINISHED clean.

---

### Test 5.13 UUID conflict -- conflict dialog path -- PREREQUISITE: db_versioning

---

### Test 5.14a Menu shape -- PASTE at DB WP object node blocked

Use [IsolatedWP2] in the clipboard and [IsolatedWP1] as the destination -- different UUIDs so the
descendant guard does not fire first and the destination-type guard (IMPLEMENTATION ERROR) is reached.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.14a"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP2]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&right_click=[IsolatedWP1]&cmd=10210"
```
Expected: IMPLEMENTATION ERROR in log; DB unchanged.

---

### Test 5.14b Menu shape -- PASTE_NEW at DB WP object node blocked

Clipboard retains [IsolatedWP2] from Test 5.14a -- no new COPY needed.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.14b"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&right_click=[IsolatedWP1]&cmd=10211"
```
Expected: IMPLEMENTATION ERROR in log; DB unchanged.

---

### Test 5.14c Menu shape -- PASTE at DB route object node blocked

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.14c"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestRoute]&right_click=[TestRoute]&cmd=10210"
```
Expected: IMPLEMENTATION ERROR; DB unchanged.

---

### Test 5.14d Menu shape -- PASTE at DB track object node blocked

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.14d"
curl -s "http://localhost:9883/api/test?panel=database&select=[TestTrack]&right_click=[TestTrack]&cmd=10210"
```
Expected: IMPLEMENTATION ERROR; DB unchanged.

---

### Test 5.15a Upload IsolatedWP1 to E80 if absent (setup for Tests 5.15b-5.15c)

If [IsolatedWP1] is not on the E80:
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.15a"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210"
```
If the upload action was run, wait for ProgressDialog FINISHED.

Expected: [IsolatedWP1] present on E80 (note UUID as [E80_WP]). If the upload action was
run, ProgressDialog FINISHED appears in the log.

---

### Test 5.15b Menu shape -- PASTE at E80 WP object node blocked

Note: [E80_WP] UUID equals [IsolatedWP1] UUID in clipboard. The _doPaste Step 3 UUID-match guard
fires first; do NOT look for "individual waypoint node destination" in the log here.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.15b"
curl -s "http://localhost:9883/api/test?panel=database&select=[IsolatedWP1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_WP]&right_click=[E80_WP]&cmd=10210"
```
Expected: `ERROR - Cannot paste: destination is a descendant of an item in the clipboard`. E80 unchanged.

---

### Test 5.15c Menu shape -- PASTE_NEW at E80 WP object node blocked

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.15c"
curl -s "http://localhost:9883/api/test?panel=e80&select=[E80_WP]&right_click=[E80_WP]&cmd=10211"
```
Expected: same `ERROR - Cannot paste: destination is a descendant of an item in the clipboard`. E80 unchanged.

---

### Test 5.16a Mixed clipboard PASTE_BEFORE at route_point (SS6.4 accepted case)

"Mixed" here = clipboard has both route_point AND waypoint items.
Note: [RP1] is Popa0. Popa0 may appear more than once in [TestRoute] after Section 2 operations --
check route point count before this test and use that as the baseline.
```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.16a"
curl -s "http://localhost:9883/api/test?panel=database&select=rp:[TestRoute]:[RP1],[IsolatedWP1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=rp:[TestRoute]:[RP2]&right_click=rp:[TestRoute]:[RP2]&cmd=10212"
```
Expected: succeeds. No IMPLEMENTATION ERROR. Both [RP1] (route_point) and [IsolatedWP1]
(waypoint) inserted as route_waypoints entries before [RP2] using their WP UUIDs.
Route count increases by clipboard item count.

---

### Test 5.16b Mixed clipboard PASTE_NEW_BEFORE at route_point (SS6.4 accepted case)

```
curl -s "http://localhost:9883/api/command?cmd=mark+Test+5.16b"
curl -s "http://localhost:9883/api/test?panel=database&select=rp:[TestRoute]:[RP1],[IsolatedWP1]&cmd=10200"
curl -s "http://localhost:9883/api/test?panel=database&select=rp:[TestRoute]:[RP2]&right_click=rp:[TestRoute]:[RP2]&cmd=10214"
```
Expected: succeeds. All clipboard items (route_point and waypoint) inserted as route_waypoints
entries before [RP2] using their existing WP UUIDs. No new waypoint records created.
Route count increases by clipboard item count.

---

## Ordering constraints summary

- Test 3.15 must run before Test 5.7: Test 3.15 leaves Timiteo on E80; Tests 5.6a-5.6c clear E80; Test 5.7 tests a
  fresh Timiteo paste from a clean E80. If Test 3.15 is NOT_RUN, Test 5.7 can still run but E80 must
  be verified empty first.
- Test 2.3 consumes [IsolatedWP3] (TOBOBE); don't use 994e0f7ef900baa4 after Test 2.3.
- Test 2.7 deletes [SafeBranch] (Before Sumwood Channel); Test 2.17 uses [SomeBranch] as the branch
  anchor (not [SafeBranch]); Test 2.9 empties [SomeBranch] but it persists as a node.
- Test 2.11 moves [TestRoute] to [DST]; UUID (f34efdd6070022e8) still valid for Tests 2.14a-b, 2.15a-b,
  2.18a-b, and Section 3.x.
- Test 2.12 moves [TestTrack] to [DST]; UUID (1a4eed924904ebbe) still valid for Test 4.3 and Test 5.5.
- Test 2.16 uses [TestGroup] (Timiteo, 1a4eaf5a8c00e922) as group anchor; Test 3.15 uses it for
  PASTE_NEW to E80; Test 5.7 uses it for ancestor-wins. All three uses are independent (none
  destructive to [TestGroup] itself).
- Test 3.14b and Test 3.14c require Test 3.14 to run first (they need a fresh-UUID WP on E80). The
  fresh-UUID WP is [E80_FRESH_WP] -- derive its UUID from /api/db after Test 3.14 runs (it is
  NOT [IsolatedWP2]'s UUID; it is a fresh byte-1=0x82 UUID assigned by navMate at PASTE_NEW time).
  Test 3.14c also requires a second fresh WP [E80_FRESH_WP2] created via PASTE_NEW at the start
  of that step (see Test 3.14c setup).

---

## last_testrun.md format

**Test numbers in last_testrun.md MUST match the runbook exactly.** The runbook is the
canonical source of test numbers. Do not use numbers from memory, prior testruns, or the
testplan prose. Copy the Test X.Y label from the runbook heading for each step you execute.

**Title:** `# navOperations Test Run -- Cycle N`

**Header:** Cycle number, date, wall-clock start and end times.

**Summary:** One line per Section with overall result.

**Results table:** Every test step listed with Status column:
- PASS -- all pass criteria met without intervention.
- FAIL -- one or more pass criteria not met: blocked, data corrupted, ProgressDialog did
  not auto-FINISH (even if `close_dialog` rescued the cycle), or catastrophic.
- PARTIAL -- some sub-steps passed, others did not.
- PASSED_BUT -- all of the step's own pass criteria were met but with notable non-fatal
  caveats (unexpected log warning that does not violate a pass criterion, etc.). NOT for
  cases where a primary criterion was violated and the cycle was rescued -- those are FAIL.
- NOT_RUN -- structurally non-runnable. Either PREREQUISITE-blocked (record as
  `NOT_RUN (<label>)` using the prereq label, e.g. `NOT_RUN (db_versioning)`) or
  environment-blocked (e.g. `NOT_RUN (teensyBoat unavailable)`).

**Issues section:** Always present; "none" on clean cycle. One prose subsection per
FAIL, PARTIAL, or PASSED_BUT item from THIS cycle only. Include:
- Test step (Test X.Y and name)
- Nodes involved by [Name] and UUID
- Expected vs. actual
- Data state left behind -- what is corrupted, missing, or unexpectedly changed
- Known bug (name the open_bugs.md entry) or new
- Catastrophic (prevents subsequent steps) or not

Do NOT include entries for PASS steps, improvements over prior cycles, or regression
confirmations. If a step passed, it gets a PASS in the results table and nothing in Issues.

**No "New Knowledge" section** -- discoveries go in the runbook immediately.
**No "Open Items" section** -- open items live in todo.md.
