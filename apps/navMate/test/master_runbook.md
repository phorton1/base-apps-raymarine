# navOps Test Suite -- Master Runbook

Shared execution-layer content for the navOps modular test suite. Every module's `runbook.md` references this document for toolbox commands, helpers, conventions, and the cycle results file format.

For philosophy, status definitions, and module ordering, see [`master_plan.md`](master_plan.md). For UUID lookup, see [`uuid_index.md`](uuid_index.md).

---

## Test Execution Rules

### One test per tool call -- no batching, no temp scripts

**ONE test step per PowerShell/Bash tool call.** Within a tool call, issue all the curls, sleeps, log reads, and state assertions you need for THAT ONE TEST. Do NOT chain two or more tests into one tool call. After each test, evaluate it (PASS / PASSED_BUT / FAIL / NOT_RUN) and announce the result before firing the next tool call.

Batching hides intermediate state, removes the per-test stop-on-catastrophic decision, lets state drift invisibly, and forces post-hoc forensics when something breaks.

Exceptions (do not invent new ones):

- A test documented with a built-in batched script (e.g. a stress-test loop) runs as written.
- Helper function definitions may share a tool call with the test that uses them, but only one test per call.

### Read-the-log convention

After every command, read `/api/log?since=mark` and scan for `ERROR`, `WARNING`, `IMPLEMENTATION ERROR`. `{ok:1}` from `/api/command` or `/api/test` only means *dispatched* -- it says nothing about whether the operation succeeded.

### Mark tagging

Every `cmd=mark` call carries an identifier of the test that owns it: `cmd=mark+<tag>` (URL-encode spaces as `+`). Tag format = `Test+<module>.<N>` -- the word `Test`, then the module-qualified test identifier (e.g. `mark+Test+db.7` decodes to log tag `Test db.7`). Multi-phase tests append a phase sub-tag (`mark+Test+db.1+anchors`, `mark+Test+db.1+main+loop`).

The tag is echoed in the log as `------ MARK: <tag> ------`. Tags let a human reviewing the log match each mark to its source test.

---

## HTTP Endpoints

Base URL: `http://localhost:9883`.

| Endpoint | Key params | Returns |
|----------|-----------|---------|
| `GET /api/log?since=SEQ` | `since=seq` or `since=mark` | `{lines:[{seq,color,text},...], overflow:N, seq:N}`. Field is `seq` (current ring seq), NOT `last_seq`. |
| `GET /api/command?cmd=mark` or `cmd=mark+<tag>` | -- | Snapshots ring seq for `?since=mark`. Response is `{"ok":1,"cmd":"mark"}` -- NO seq returned. Optional tag included in log as `------ MARK: <tag> ------`. |
| `GET /api/command?cmd=dialog_state` | -- | Logs "dialog_state: active" or "idle" in the LOG (not the response body -- see Pitfalls below). |
| `GET /api/command?cmd=close_dialog` | -- | Force-closes any hung ProgressDialog. |
| `GET /api/test?op=refresh` | `panel=database\|e80\|fsh` (optional, default `database`) | Refreshes the named panel. For DB it reloads navMate.db from disk; for e80 and fsh it re-renders the panel tree against current spoke state. |
| `GET /api/test?op=suppress&val=1` | `val=0` to disable; `outcome=reject` for reject path | Enables auto-suppress (no confirmation dialogs). |
| `GET /api/test?op=clear_e80` | -- | Deletes all E80 routes, groups, waypoints, tracks. Requires suppress=1. |
| `GET /api/test?op=create_branch&name=NAME` | `parent_uuid` optional (omitted = root) | Dialog-free NEW_BRANCH. Returns `{ok:1,queued:1}`; new branch's UUID appears in log as `navTest: create_branch '<name>' uuid=<uuid>`. |
| `GET /api/test?op=load_fsh&path=<abs>` | `path` = absolute filesystem path to a `.fsh` archive | Loads FSH file via `navFSH::loadFSH`; opens or refreshes winFSH pane. Log: `navTest: load_fsh done path=<path>` on success; `WARNING: navTest: load_fsh failed for <path>` on parse failure. **Requires `suppress=1` first** if the in-memory FSH may be dirty -- see Suppress ordering note in Reset Primitives. |
| `GET /api/test?panel=P&select=K&cmd=N` | `right_click=K` optional; `P` = `database`, `e80`, or `fsh` | Fires context-menu command N on panel P at node K. |
| `GET /api/nmdb` | -- | navMate DB state: arrays -- waypoints, collections, routes, route_waypoints, tracks. |
| `GET /api/db` | -- | E80 live state: hashes keyed by UUID -- waypoints, groups, routes, tracks. |
| `GET /api/fsh` | -- | navFSH in-memory state: hashes keyed by FSH-native UUID (dashed-uppercase) -- waypoints, groups, routes, tracks; plus `filename`. Returns `{error:"no FSH database loaded"}` before any `load_fsh`. |

### `/api/test` queue rule

`/api/test` is single-slot: the server stores at most one pending test command. A second `/api/test` call fired before the wx idle loop picks up the first will overwrite the first. Any sequenced multi-step test (COPY then PASTE, looped pastes) MUST wait for each command to actually run before issuing the next. Use the `Wait-NavCmdFinished` helper below.

### `/api/nmdb` shape and field names

Top-level keys: `collections`, `routes`, `route_waypoints`, `tracks`, `waypoints`. **There is no top-level `groups` array.** Groups live inside `collections`, distinguished by `node_type='group'`. Branches have `node_type='branch'`. So a group-presence check looks like:

```powershell
@($nmdb.collections | Where-Object { $_.uuid -eq $grp_uuid -and $_.node_type -eq 'group' }).Count
```

NOT `@($nmdb.groups | Where-Object { ... })` -- that property doesn't exist and the filter silently returns 0, which can masquerade as "group deleted". This bit cycle 20 partway through db.5/db.6/db.7; the runbook prose says "Bocas group gone" without specifying the underlying property, so check authors have to know the schema.

| Entity        | Parent field      | WP-ref field | Type field |
|---------------|-------------------|--------------|------------|
| waypoints     | `collection_uuid` | -- | -- |
| collections   | `parent_uuid`     | -- | `node_type` (group/branch) |
| routes        | `collection_uuid` | -- | -- |
| route_waypoints | `route_uuid`    | `wp_uuid` | -- |
| tracks        | `collection_uuid` | -- | -- |

Use `parent_uuid` for collections (branches, groups). `collection_uuid` on a collection always returns empty.

### `/api/db` (E80) shape

E80 group and route objects do NOT have `waypoints` or `members` fields. Use:

- `num_uuids` / `num_wpts` -- integer count
- `uuids` -- array of UUID strings (member WPs)

`$grp.waypoints` and `$rt.waypoints` are always null -- false zeros if you compare them.

---

## Command Constants

`cmd=N` must be NUMERIC (navTest.pm does arithmetic). String names cause "isn't numeric" errors.

| Command           | Value | Log name when dispatched |
|-------------------|-------|--------------------------|
| COPY              | 10200 | `COPY` |
| CUT               | 10201 | `CUT` |
| PASTE             | 10210 | `PASTE` |
| PASTE_NEW         | 10211 | `PASTE NEW` |
| PASTE_BEFORE      | 10212 | `PASTE BEFORE` |
| PASTE_NEW_BEFORE  | 10214 | `PASTE NEW BEFORE` |
| PASTE_NEW_AFTER   | 10215 | `PASTE NEW AFTER` |
| DELETE_WAYPOINT   | 10220 | `DELETE WAYPOINT` |
| DELETE_GROUP      | 10221 | `DELETE GROUP` |
| DELETE_GROUP_WPS  | 10222 | `DELETE GROUP+WPS` |
| DELETE_ROUTE      | 10223 | `DELETE ROUTE` |
| DELETE_TRACK      | 10225 | `DELETE TRACK` |
| DELETE_BRANCH     | 10226 | `DELETE BRANCH` |
| PUSH              | 10250 | `PUSH` |

The log-name column is what to pass as `Wait-NavCmdFinished -cmdName`.

---

## Node Key Format

| Node type | Key |
|-----------|-----|
| Waypoint, route, track, group, branch | UUID string |
| Route point | `rp:ROUTE_UUID:WP_UUID` |
| E80 header nodes | `header:groups`, `header:routes`, `header:tracks` |
| E80 My Waypoints | `my_waypoints` (no `header:` prefix) |
| DB or E80 root | `root` |

URL-encode `:` as `%3A` when embedding in `header:groups` etc. inside a query string (most curls already use it that way).

---

## Reset Primitives

Module baseline setup composes these primitives. The exact composition is per-module; what follows is the catalog.

```powershell
# Revert navMate.db to git baseline
git -C C:/dat/Rhapsody checkout -- navMate.db

# Refresh navMate to load reverted DB
curl.exe -s "http://localhost:9883/api/test?op=refresh"

# Enable suppress (required BEFORE any E80 op AND before load_fsh on a
# possibly-dirty in-memory FSH; see "Suppress ordering" below)
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1"

# Clear E80 (requires suppress=1)
curl.exe -s "http://localhost:9883/api/test?op=clear_e80"
# Wait for ProgressDialog FINISHED (see ProgressDialog Pattern below)

# Load FSH fixture (absolute path required; suppress must already be enabled
# to auto-discard the dirty-bit confirm dialog if the in-memory FSH is dirty)
curl.exe -s "http://localhost:9883/api/test?op=load_fsh&path=C:/base/apps/raymarine/apps/navMate/test/_fixtures/test.fsh"

# Mark log with module tag for since=mark queries
curl.exe -s "http://localhost:9883/api/command?cmd=mark+<module-name>+reset"
```

The `load_fsh` primitive takes an absolute filesystem path (URL-encode separators if needed). It calls `navFSH::loadFSH($path)` and either refreshes the existing winFSH pane or opens a new one. Log markers: `navTest: load_fsh done path=<path>` on success; `WARNING: navTest: load_fsh failed for <path>` on parse failure. Wired in `navTest.pm` 2026-05-17.

### Suppress ordering -- mandatory before load_fsh

`op=suppress&val=1` MUST be issued before `op=load_fsh` whenever the in-memory FSH may be dirty (Patrick's interactive session, a prior module test run, or any state that left winFSH with unsaved changes). When dirty, `loadFSH` raises a `discard / save / save-as / cancel` confirm dialog; with suppress enabled the dialog is auto-handled as DISCARD so the test can proceed unattended. Without suppress, the dialog blocks the wx idle loop and the test sequence hangs.

A clean cold start of navMate has no dirty FSH, so out-of-order suppress would happen to work -- until it doesn't. Always set suppress first; the cost is one curl.

---

## Helpers (PowerShell)

Drop these near the top of any module's runbook script.

### Wait-NavCmdFinished

Eliminates fixed sleeps; total test time tracks actual command processing.

```powershell
$global:nav_cmd_seen = @{}

function Wait-NavCmdFinished
{
    param(
        [Parameter(Mandatory=$true)] [string]$cmdName,    # e.g. "COPY", "PASTE NEW"
        [Parameter(Mandatory=$true)] [string]$panel,      # "database" or "e80"
        [int]$timeout_ms = 8000
    )
    $key = "$panel/$cmdName"
    if (-not $global:nav_cmd_seen.ContainsKey($key)) { $global:nav_cmd_seen[$key] = 0 }
    $global:nav_cmd_seen[$key]++
    $expected = $global:nav_cmd_seen[$key]
    $pattern  = "===== $cmdName ($panel) FINISHED ====="

    # Initial wait avoids flooding /api/log while command is still dispatching
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
```

### Mark-Phase

Tags phase boundaries inside a multi-phase test, and resets the `Wait-NavCmdFinished` counter so the next phase starts from zero.

```powershell
function Mark-Phase
{
    param([Parameter(Mandatory=$true)] [string]$tag)
    $encoded = [uri]::EscapeDataString($tag)
    curl.exe -s "http://localhost:9883/api/command?cmd=mark+$encoded" | Out-Null
    $global:nav_cmd_seen = @{}
}
```

---

## ProgressDialog Pattern

Primary pattern: flat sleep + single log read. Do NOT loop-read the log (floods the ring buffer). Do NOT check the dialog_state response body (it never contains "idle" -- see Pitfalls).

```powershell
Start-Sleep 5   # flat wait; adjust up for multi-WP pastes (11 WPs needs ~5s)
$r = curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json
$finished = $r.lines | Where-Object { $_.text -match "ProgressDialog.*FINISHED" }
if (-not $finished) {
    # Not finished yet -- check dialog state via the LOG, not the response body
    curl.exe -s "http://localhost:9883/api/command?cmd=dialog_state" | Out-Null
    $r2 = curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json
    $isIdle = $r2.lines | Where-Object { $_.text -match "dialog_state: idle" }
    if (-not $isIdle) {
        # Genuinely hung
        [console]::beep(800, 200)
        # Try: curl.exe -s "http://localhost:9883/api/command?cmd=close_dialog"
    }
}
```

ProgressDialog auto-completion is a pass criterion. Any E80 step that opens a ProgressDialog has two pass criteria: (a) the data outcome matches expected AND (b) the dialog auto-FINISHED. Both must hold for PASS.

If ProgressDialog hangs and `close_dialog` rescues the cycle, the step is **FAIL** (criterion (b) not met), not PASSED_BUT.

If `close_dialog` itself fails: catastrophic. Beep and stop.

Missing FINISHED for fast/no-op operations (e.g. empty-list cleanup paths) is NOT a failure. Only beep when `dialog_state: active` in the log confirms a genuine hang.

---

## Pitfalls

Known traps documented from prior cycles.

- **No background pollers waiting on navMate state.** `until [ X = 0 ]; do sleep; done` run with `run_in_background: true` hangs across navMate restarts -- the curl returns garbage during a restart, the loop interprets it as "not yet", keeps looping. Five manual kills via /tasks in one hub-alpha session. Use finite-sleep + single curl probe; if not done, say so and let the operator decide rather than spawning a poller.

- **`dialog_state` response body.** Always returns `{"ok":1}` regardless of dialog state. The words "idle" or "active" appear ONLY in the navMate log. Checking the response body for "idle" is always FALSE -- always check the log.
- **`my_waypoints` empty-list path.** When E80 has zero ungrouped WPs, the `my_waypoints` tree node is still selectable. `cmd=10222 select=my_waypoints` enters `_deleteE80GroupsAndWPs`, hits the empty-members guard, and returns cleanly. Under `suppress=1` (automated runs) it logs `WARNING: My Waypoints is empty.` -- no modal, no ProgressDialog. DELETE GROUP+WPS STARTED and FINISHED both appear (the wrapper emits FINISHED on clean return). Under no suppress (interactive) it shows a modal info dialog instead of the warning. PASS criterion: `/api/db` still empty AND `WARNING: My Waypoints is empty.` in log AND DELETE GROUP+WPS FINISHED present AND no IMPL ERROR. (Prior behavior: node did not exist; `WARNING: navTest: fire cmd=10222 - no right_click_node set`.)
- **PowerShell variable + colon parsing.** When a variable in a string is immediately followed by `:`, PowerShell parses `$var:` as a drive reference. Always use `${var}` in string interpolation: `"rp:${E80_RT}:${E80_RP1}"`.
- **PSCustomObject property counting.** `$db.waypoints.PSObject.Properties.Count` may print empty. Use `@($db.waypoints.PSObject.Properties).Count`.
- **E80 group membership.** WP record on the E80 side does NOT carry a `group_uuid` field. Check membership via `$group.uuids -contains $wp_uuid`, not via the WP record.

---

## Known-Quiet Warnings

These warning patterns are documented background noise. They do NOT, by themselves, constitute test failure. A WARNING line is a failure ONLY if:

(i) it is `IMPLEMENTATION ERROR` AND the test does not expect one as a guard-fired sentinel, OR
(ii) the warning correlates with an actual wrong data outcome, OR
(iii) the warning explicitly reports that the test step failed.

Random unfamiliar WARNINGs are noted in observations and the cycle continues.

| Pattern | Source | Why quiet |
|---------|--------|-----------|
| `WARNING: navDB::moveWaypoint: position not specified for '<uuid>'...` | navDB.pm | Reparent works; warning flags caller-side TODO. Common in group-dissolve tests. |
| `WARNING: deleting waypoints(<uuid>) <Name>` | d_WPMGR.pm | Normal protocol chatter during `clear_e80` / E80 delete. |
| `WARNING: enquing mod(...)` | d_WPMGR.pm (~line 625) | Pre-existing E80/NET warning. Expected during E80 ops. Not expected during DB-only tests -- if it appears in db module, that IS a regression. |
| Track-record warnings: `TRACK EVENT(N)`, `enquing GET_CUR2`, `handleEvent() returning undef`, `bad points(0) != expected(N)`, `TRACK OUT OF BAND` | d_TRACK.pm, e_TRACK.pm, b_sock.pm | Normal protocol noise during teensyBoat-driven track creation. Save succeeds when `got track(uuid) = '<name>'` appears. |

---

## Cycle Results File Format

A completed full cycle writes `_results/cycle_NN.md` with the following structure. Test names MUST match the module's runbook exactly (do not invent or paraphrase). In the flat Results Table, prefix each test identifier with the module name and a dot (e.g. `db.1`, `e80.14b`, `tracks.3`) so identifiers are unambiguous across modules. Module-local books use unprefixed numbers (`Test 1`).

```
# navOperations Test Run -- Cycle NN

**Date:** YYYY-MM-DD
**Start:** HH:MM
**End:** HH:MM
**Cycle:** NN

---

## Summary

| Module | Result |
|--------|--------|
| db     | PASS -- all N steps |
| e80    | PASS -- all N steps |
| tracks | PASS -- teensyBoat available; all N steps |
| fsh    | NOT_RUN (stub) |
| hub    | NOT_RUN (stub) |

---

## Results Table

| Test | Status |
|------|--------|
| **db** | |
| <test name from runbook> | <status> |
| ... | ... |
| **e80** | |
| ... | ... |
| **tracks** | |
| ... | ... |
| **fsh** | |
| ... | ... |
| **hub** | |
| ... | ... |

---

## Issues

(One prose subsection per FAIL / PARTIAL / PASSED_BUT item from THIS cycle. Each subsection includes:
 - Test name and module
 - Nodes involved by [Name] and UUID
 - Expected vs. actual
 - Data state left behind (what is corrupted, missing, or unexpectedly changed)
 - Catastrophic or not
 No causation analysis, no fix suggestions -- observations and reproduction context only.
 "none" on a clean cycle.)
```

Issues section is THIS cycle only -- no improvements-over-prior-cycle entries, no regression confirmations, no notes about tests that passed.

---

## Start-Time Helper

`full_cycle_runbook.md` writes the start time to `C:\base_data\temp\raymarine\testrun_start.txt` as the first step. Recover with:

```powershell
Get-Content "C:\base_data\temp\raymarine\testrun_start.txt"
```

The file survives context compaction; in-memory start times do not.
