# db Module -- Runbook

Execution-layer steps for the db module. For shared toolbox, helpers, and conventions, see [`../master_runbook.md`](../master_runbook.md). For module scope and test inventory, see [`plan.md`](plan.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md).

---

## Baseline Setup

Run before any test. Skip if the orchestrator (`../full_cycle_runbook.md`) just performed the same setup.

```powershell
git -C C:/dat/Rhapsody checkout -- navMate.db
curl.exe -s "http://localhost:9883/api/test?op=refresh" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+db+module+reset" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=clear_e80" | Out-Null
Start-Sleep 5
# Verify Clear E80 DB FINISHED in log; verify /api/db is empty
```

The helpers `Wait-NavCmdFinished` and `Mark-Phase` (see `../master_runbook.md`) are used by Test 1 only; other tests use the simpler mark + curl + sleep pattern.

---

## Positive Tests

### Test 1 -- Position precision (32 PASTE_NEW_BEFORE bisections force AutoCompact)

Self-contained. Creates and destroys its own `PrecisionTestBranch`. Runs first because position-allocator failures invalidate everything downstream.

```powershell
$global:nav_cmd_seen = @{}

function Wait-NavCmdFinished {
    param([Parameter(Mandatory=$true)] [string]$cmdName, [Parameter(Mandatory=$true)] [string]$panel, [int]$timeout_ms = 8000)
    $key = "$panel/$cmdName"
    if (-not $global:nav_cmd_seen.ContainsKey($key)) { $global:nav_cmd_seen[$key] = 0 }
    $global:nav_cmd_seen[$key]++
    $expected = $global:nav_cmd_seen[$key]
    $pattern  = "===== $cmdName ($panel) FINISHED ====="
    Start-Sleep -Milliseconds 1000
    $deadline = (Get-Date).AddMilliseconds($timeout_ms)
    while ((Get-Date) -lt $deadline) {
        $log = curl.exe -s "http://localhost:9883/api/log?since=mark"
        $count = ([regex]::Matches($log, [regex]::Escape($pattern))).Count
        if ($count -ge $expected) { return $true }
        Start-Sleep -Milliseconds 250
    }
    Write-Host "Wait-NavCmdFinished TIMEOUT: $pattern (seen $count of $expected after ${timeout_ms}ms)"
    return $false
}

function Mark-Phase {
    param([Parameter(Mandatory=$true)] [string]$tag)
    $encoded = [uri]::EscapeDataString($tag)
    curl.exe -s "http://localhost:9883/api/command?cmd=mark+$encoded" | Out-Null
    $global:nav_cmd_seen = @{}
}

$WP     = "ce4e43181f01b3ae"   # [IsolatedWP1]
$URL_DB = "http://localhost:9883/api/test?panel=database"

Mark-Phase "Test db.1 start"
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=create_branch&name=PrecisionTestBranch" | Out-Null

$deadline = (Get-Date).AddMilliseconds(5000); $branch = ""
Start-Sleep -Milliseconds 1000
while ((Get-Date) -lt $deadline -and -not $branch) {
    $log = curl.exe -s "http://localhost:9883/api/log?since=mark"
    if ($log -match "navTest: create_branch 'PrecisionTestBranch' uuid=([0-9a-f]+)") { $branch = $matches[1]; break }
    Start-Sleep -Milliseconds 250
}
if (-not $branch) { Write-Host "FAIL: create_branch did not appear in log"; return }

Mark-Phase "Test db.1 anchors"
curl.exe -s "$URL_DB&select=$WP&cmd=10200" | Out-Null
if (-not (Wait-NavCmdFinished -cmdName "COPY" -panel "database")) { return }
curl.exe -s "$URL_DB&select=$branch&right_click=$branch&cmd=10211" | Out-Null
if (-not (Wait-NavCmdFinished -cmdName "PASTE NEW" -panel "database")) { return }
curl.exe -s "$URL_DB&select=$branch&right_click=$branch&cmd=10211" | Out-Null
if (-not (Wait-NavCmdFinished -cmdName "PASTE NEW" -panel "database")) { return }

$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$wps = $nmdb.waypoints | Where-Object { $_.collection_uuid -eq $branch } | Sort-Object position
if ($wps.Count -ne 2) { Write-Host "FAIL: expected 2 anchor WPs, got $($wps.Count)"; return }
$anchorB = $wps[-1].uuid

Mark-Phase "Test db.1 main loop"
for ($i = 1; $i -le 32; $i++) {
    curl.exe -s "$URL_DB&select=$anchorB&right_click=$anchorB&cmd=10214" | Out-Null
    if (-not (Wait-NavCmdFinished -cmdName "PASTE NEW BEFORE" -panel "database")) { Write-Host "FAIL at iter $i"; return }
}

Mark-Phase "Test db.1 verify"
$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$wps = $nmdb.waypoints | Where-Object { $_.collection_uuid -eq $branch }
$n = ($wps | Measure-Object).Count
$pos_distinct = (($wps | Select-Object -ExpandProperty position | Sort-Object -Unique) | Measure-Object).Count
$log = curl.exe -s "http://localhost:9883/api/log?tail=2000"
$trig = if ($log -match "AutoCompact FLOAT positions") { 'YES' } else { 'NO' }
$loop_inserts = $n - 2
Write-Host "Test db.1: loop_inserts=$loop_inserts (REQUIRED 32), branch_count=$n, distinct_positions=$pos_distinct (expect $n), AutoCompact_seen=$trig (expect YES)"

Mark-Phase "Test db.1 teardown"
curl.exe -s "$URL_DB&select=$branch&right_click=$branch&cmd=10226" | Out-Null
if (-not (Wait-NavCmdFinished -cmdName "DELETE BRANCH" -panel "database")) { Write-Host "TEARDOWN FAIL" }
```

**Pass (all three):** `loop_inserts == 32` AND `AutoCompact FLOAT positions` warning in log AND all 34 positions distinct.

**Fail:** any of the above unmet. If teardown timed out, the next Test 1 run must clean up the orphan `PrecisionTestBranch` first.

---

### Test 2 -- Copy WP -> Paste New

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.2" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
Start-Sleep 2
```

**Pass:** new WP (fresh UUID) named "BOCAS1" appears in [DST] (`collection_uuid=6f4e72ceae0264de`); [IsolatedWP1] still at `collection_uuid=2b4e3308ca00cf66` (oldE80/Tracks). COPY + PASTE NEW STARTED/FINISHED in log.

---

### Test 3 -- Cut WP -> Paste (move)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.3" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=af4e23246d01bfa8&cmd=10201" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** [IsolatedWP2] (BOCAS2, `af4e23246d01bfa8`) UUID unchanged; `collection_uuid` now = `6f4e72ceae0264de` ([DST]). CUT + PASTE STARTED/FINISHED.

---

### Test 4 -- Delete WP (success)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.4" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=994e0f7ef900baa4&right_click=994e0f7ef900baa4&cmd=10220" | Out-Null
Start-Sleep 3
```

**Pass:** [IsolatedWP3] (TOBOBE, `994e0f7ef900baa4`) absent from `/api/nmdb` waypoints. DELETE WAYPOINT STARTED/FINISHED.

---

### Test 5 -- Delete Group (dissolve)

Uses [GroupNoRoute_Dissolve] (Places/Part 1, `4e4e405a08033af4`) to preserve [GroupNoRoute] for Test 6.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.5" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=4e4e405a08033af4&right_click=4e4e405a08033af4&cmd=10221" | Out-Null
Start-Sleep 3
```

**Pass:** group shell (`4e4e405a08033af4`) absent from collections; 5 member WPs now have `collection_uuid=214e7db00703a184` (Part 1 - Before Trip); member UUIDs unchanged. `WARNING: navDB::moveWaypoint: position not specified` lines are known-quiet noise.

---

### Test 6 -- Delete Group+WPS (success)

Uses [GroupNoRoute] = Bocas group (`a74e90d60300a434`).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.6" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=a74e90d60300a434&right_click=a74e90d60300a434&cmd=10222" | Out-Null
Start-Sleep 3
```

**Pass:** Bocas group gone; StarfishBeach (`9d4e232a0500dd90`) gone; Fishfarm (`124e0eb404000564`, member of Bocas) gone.

---

### Test 8 -- Delete Branch (recursive, safe)

Uses [SafeBranch] = "Before Sumwood Channel" (`0a4e9820cc015cae`).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.8" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=0a4e9820cc015cae&right_click=0a4e9820cc015cae&cmd=10226" | Out-Null
Start-Sleep 3
```

**Pass:** branch absent from collections; all descendants gone. DELETE BRANCH STARTED/FINISHED.

---

### Test 9 -- Copy Branch -> Paste New

Uses [RouteBranch] = Navigation/Routes (`ac4e2c500600b9aa`).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.9" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ac4e2c500600b9aa&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
Start-Sleep 4
```

**Pass:** new "Routes" branch in [DST] (fresh UUID); contains 3 fresh-UUID groups (Agua/Michelle/Popa) + 3 fresh-UUID routes. Source ([RouteBranch]) and its contents unchanged.

---

### Test 10 -- Cut Branch -> Paste (move)

Uses [SomeBranch] = "MichellToKuna 2011-07" (`784e76f880029e1e`).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.10" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=784e76f880029e1e&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** [SomeBranch] UUID preserved; `parent_uuid` now = [DST]; contents (Places group + empty Tracks sub-branch) intact.

---

### Test 11 -- Copy Route -> Paste New

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.11" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
Start-Sleep 3
```

**Pass:** new "Popa" route in [DST] (fresh UUID); 11 route_waypoints; each `wp_uuid` matches the corresponding original Popa route_waypoint (no new WP records created). Original [TestRoute] still at `collection_uuid=ac4e2c500600b9aa`.

---

### Test 12 -- Cut Route -> Paste (move)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.12" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** [TestRoute] (`f34efdd6070022e8`) UUID preserved; `collection_uuid` now = [DST]; 11 route_waypoints unchanged.

---

### Test 13 -- Cut Track -> Paste (move)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.13" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eed924904ebbe&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** [TestTrack] (`1a4eed924904ebbe`) UUID preserved; `collection_uuid` now = [DST]; track_points unchanged.

---

### Test 14a -- Paste New Before (collection-member anchor)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.14a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=af4e23246d01bfa8&right_click=af4e23246d01bfa8&cmd=10214" | Out-Null
Start-Sleep 3
```

**Pass:** fresh BOCAS1 (new UUID) inserted in [DST] at a `position` less than [IsolatedWP2]'s position and greater than its predecessor's.

---

### Test 14b -- Paste New After (collection-member anchor)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.14b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=af4e23246d01bfa8&right_click=af4e23246d01bfa8&cmd=10215" | Out-Null
Start-Sleep 3
```

**Pass:** another fresh BOCAS1 at `position > [IsolatedWP2]'s position` and `<` the next greater sibling's position.

---

### Test 15a -- PASTE_NEW_BEFORE route point (copy-splice)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.15a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=rp:f34efdd6070022e8:314e56cc09005332&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=rp:f34efdd6070022e8:454e11a80b002884&right_click=rp:f34efdd6070022e8:454e11a80b002884&cmd=10214" | Out-Null
Start-Sleep 3
```

**Pass:** Popa route now has 12 route_waypoints; Popa0 (`314e56cc09005332`) appears between Popa1 (`8d4e68fa0a0073ee`) and Popa2 (`454e11a80b002884`).

---

### Test 15b -- PASTE_BEFORE route point (cut-splice)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.15b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=rp:f34efdd6070022e8:454e11a80b002884&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=rp:f34efdd6070022e8:8d4e68fa0a0073ee&right_click=rp:f34efdd6070022e8:8d4e68fa0a0073ee&cmd=10212" | Out-Null
Start-Sleep 3
```

**Pass:** route_waypoints count unchanged (12); Popa2 (`454e11a80b002884`) now appears before Popa1 (`8d4e68fa0a0073ee`).

---

### Test 16a -- Paste New Before (route-object anchor)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.16a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&right_click=f34efdd6070022e8&cmd=10214" | Out-Null
Start-Sleep 3
```

**Pass:** fresh BOCAS1 in [DST] at `position` less than [TestRoute]'s position.

---

### Test 16b -- Paste New After (route-object anchor)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.16b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&right_click=f34efdd6070022e8&cmd=10215" | Out-Null
Start-Sleep 3
```

**Pass:** another fresh BOCAS1 at `position > [TestRoute]'s position` and `<` the next greater sibling.

---

### Test 17 -- Paste New Before (group-object anchor)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.17" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eaf5a8c00e922&right_click=1a4eaf5a8c00e922&cmd=10214" | Out-Null
Start-Sleep 4
```

**Pass:** fresh BOCAS1 inserted in oldE80/Groups (`b84e8c3c51009446`) at `position < [TestGroup]'s position` (Timiteo). [TestGroup] and its 6 members unchanged.

---

### Test 18 -- Paste New Before (branch-object anchor)

After Test 10, [SomeBranch] now lives in [DST]. The test still anchors on [SomeBranch] -- its parent changed but the UUID is valid.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.18" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=784e76f880029e1e&right_click=784e76f880029e1e&cmd=10214" | Out-Null
Start-Sleep 3
```

**Pass:** fresh BOCAS1 in [DST] at `position < [SomeBranch]'s position`. [SomeBranch] (empty shell) unchanged.

---

### Test 19a -- Paste New Before (route clipboard, WP anchor)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.19a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=af4e23246d01bfa8&right_click=af4e23246d01bfa8&cmd=10214" | Out-Null
Start-Sleep 3
```

**Pass:** new "Popa" route in [DST] (fresh UUID) at `position < [IsolatedWP2]'s position`; 12 route_waypoints; member `wp_uuid`s match the source [TestRoute] (SS1.6, no new WP records).

---

### Test 19b -- Paste New Before (group clipboard, WP anchor)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.19b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eaf5a8c00e922&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=af4e23246d01bfa8&right_click=af4e23246d01bfa8&cmd=10214" | Out-Null
Start-Sleep 4
```

**Pass:** new "Timiteo" group in [DST] (fresh UUID) + 6 fresh-UUID member WPs at `position < [IsolatedWP2]'s position`. [TestGroup] (`1a4eaf5a8c00e922`) and its members unchanged in oldE80/Groups.

---

### Test 35 -- PASTE waypoint at DB route object (D3: REF append)

D3 positive: a DB route object is now a valid PASTE / PASTE_NEW destination. Waypoint clipboard items become new `route_waypoints` rows on the target route (REF append, no record creation). Uses [IsolatedWP1] (`ce4e43181f01b3ae`) and [TestRoute] (`f34efdd6070022e8`, in [DST] after db.12).

```powershell
$rwp_before = (curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json).route_waypoints | Where-Object { $_.route_uuid -eq "f34efdd6070022e8" } | Measure-Object | Select-Object -ExpandProperty Count
$wp_before  = (curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json).waypoints     | Where-Object { $_.uuid       -eq "ce4e43181f01b3ae" } | Measure-Object | Select-Object -ExpandProperty Count

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.35" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&right_click=f34efdd6070022e8&cmd=10210" | Out-Null
Start-Sleep 3

$rwp_after = (curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json).route_waypoints | Where-Object { $_.route_uuid -eq "f34efdd6070022e8" } | Measure-Object | Select-Object -ExpandProperty Count
$wp_after  = (curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json).waypoints     | Where-Object { $_.uuid       -eq "ce4e43181f01b3ae" } | Measure-Object | Select-Object -ExpandProperty Count
Write-Host "TestRoute route_waypoints: before=$rwp_before after=$rwp_after (expect +1); IsolatedWP1 row count: before=$wp_before after=$wp_after (expect unchanged at 1)"
```

**Pass:** PASTE STARTED/FINISHED; no IMPL ERROR; `$rwp_after == $rwp_before + 1`; `$wp_after == $wp_before` (no new waypoints row); the last route_waypoints row on TestRoute has `wp_uuid = ce4e43181f01b3ae`.

---

### Test 37 -- Pure route_point COPY+PASTE_BEFORE at route_point anchor (D1 carve-out)

D1 positive (coverage): the DB-to-DB record-creation guard carves out REF-only destinations. A pure route_point clipboard pasted at a route_point anchor with non-fresh PASTE_BEFORE is a REF copy (one new `route_waypoints` row referencing the existing wp_uuid).

```powershell
$rwp_before = (curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json).route_waypoints | Where-Object { $_.route_uuid -eq "f34efdd6070022e8" } | Measure-Object | Select-Object -ExpandProperty Count

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.37" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=rp:f34efdd6070022e8:454e11a80b002884&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=rp:f34efdd6070022e8:8d4e68fa0a0073ee&right_click=rp:f34efdd6070022e8:8d4e68fa0a0073ee&cmd=10212" | Out-Null
Start-Sleep 3

$rwp_after = (curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json).route_waypoints | Where-Object { $_.route_uuid -eq "f34efdd6070022e8" } | Measure-Object | Select-Object -ExpandProperty Count
Write-Host "TestRoute route_waypoints: before=$rwp_before after=$rwp_after (expect +1)"
```

**Pass:** PASTE BEFORE STARTED/FINISHED; no IMPL ERROR; `$rwp_after == $rwp_before + 1`.

---

End of db module tests.
---

## Guard Tests

### Test G1 -- Delete Group+WPS blocked (members in route) [was db.7]

Uses [GroupInRoute] = Popa group (`244e8e100800400a`).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G1" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&right_click=244e8e100800400a&cmd=10222" | Out-Null
Start-Sleep 3
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: group member waypoint is referenced by a route` (expected sentinel; navTest bypasses menu guard); group and 11 members intact in `/api/nmdb`.

---

### Test G2 -- DEL_WAYPOINT blocked (WP in route) [was db.20]

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G2" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=314e56cc09005332&right_click=314e56cc09005332&cmd=10220" | Out-Null
Start-Sleep 3
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: waypoint is referenced by a route` (expected sentinel); [WPinRoute] still in `/api/nmdb`.

---

### Test G3 -- DEL_BRANCH blocked (member WP in external route) [was db.21]

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G3" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=b84e8c3c51009446&right_click=b84e8c3c51009446&cmd=10226" | Out-Null
Start-Sleep 3
```

**Pass:** `ERROR - Cannot delete 'Groups': waypoints are referenced by external routes`; [UnsafeBranch] still present.

---

### Test G4 -- DB-copy track to DB destination blocked [was db.22]

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G4" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eed924904ebbe&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: DB-to-DB track copy via PASTE not implemented`; DB unchanged.

---

### Test G5 -- Recursive paste guard (branch into own descendant) [was db.23]

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G5" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=234e412e3104296e&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=984e7898480427f6&right_click=984e7898480427f6&cmd=10211" | Out-Null
Start-Sleep 3
```

**Pass:** `ERROR - Cannot paste: destination is a descendant of an item in the clipboard`; DB unchanged.

---

### Test G6 -- Menu shape: PASTE at DB WP object node blocked [was db.24a]

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G6" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=af4e23246d01bfa8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&right_click=ce4e43181f01b3ae&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: paste target type 'object' is not a collection`; DB unchanged.

---

### Test G7 -- Menu shape: PASTE_NEW at DB WP object node blocked [was db.24b]

Clipboard retains [IsolatedWP2] from Test 24a.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G7" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&right_click=ce4e43181f01b3ae&cmd=10211" | Out-Null
Start-Sleep 3
```

**Pass:** same IMPL ERROR; DB unchanged.

---

### Test G8 -- Menu shape: PASTE at DB track object node blocked [was db.24d]

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G8" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eed924904ebbe&right_click=1a4eed924904ebbe&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** IMPL ERROR sentinel; DB unchanged.

---

### Test G9 -- Mixed clipboard PASTE_BEFORE at route_point [was db.25a]

Clipboard mixes a route_point and a waypoint. After Test 15a, Popa0 appears twice in [TestRoute] -- selecting `rp:Popa0` matches both rows, so COPY reports 3 items (2 rp:Popa0 + 1 waypoint).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G9" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=rp:f34efdd6070022e8:314e56cc09005332,ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=rp:f34efdd6070022e8:8d4e68fa0a0073ee&right_click=rp:f34efdd6070022e8:8d4e68fa0a0073ee&cmd=10212" | Out-Null
Start-Sleep 4
```

**Pass:** log shows `_doCopy: database 3 item(s)`; PASTE BEFORE STARTED/FINISHED; no IMPL ERROR; route_waypoints count increased by exactly the clipboard item count (12 -> 15).

---

### Test G10 -- Mixed clipboard PASTE_NEW_BEFORE at route_point [was db.25b]

Same clipboard species; Test 25a's inserts cause Popa0 to appear more times, so this COPY's item count may be larger.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G10" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=rp:f34efdd6070022e8:314e56cc09005332,ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=rp:f34efdd6070022e8:8d4e68fa0a0073ee&right_click=rp:f34efdd6070022e8:8d4e68fa0a0073ee&cmd=10214" | Out-Null
Start-Sleep 4
```

**Pass:** PASTE NEW BEFORE STARTED/FINISHED; no IMPL ERROR; route_waypoints count increased by exactly the COPY-reported item count. No new WP records (`SS1.6`).

**Timing note:** the `_doCopy: database N item(s)` log line is racy to capture mid-sequence -- grepping for it before the COPY has actually finished returns nothing, and a checker that records `copy_count=0` will then false-FAIL the delta assertion. If the count can't be captured reliably, fall back to `delta > 0 AND no new WP records (SS1.6 holds) AND no IMPL ERROR`; that combination is sufficient evidence the splice landed correctly.

---

### Test G11 -- COPY WP -> PASTE blocked (predicate; DB-to-DB waypoint copy) [was db.26]

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G11" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: DB-to-DB waypoint copy via PASTE not implemented (use Paste New)`; DB unchanged.

---

### Test G12 -- COPY group -> PASTE blocked (predicate; DB-to-DB group copy) [was db.27]

Uses [TestGroup] = Timiteo (`1a4eaf5a8c00e922`).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G12" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eaf5a8c00e922&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: DB-to-DB group copy via PASTE not implemented (use Paste New)`; DB unchanged.

---

### Test G13 -- COPY route -> PASTE blocked (predicate; DB-to-DB route copy) [was db.28]

Uses Agua route (`d64e8c7e4400a186`).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G13" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=d64e8c7e4400a186&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: DB-to-DB route copy via PASTE not implemented (use Paste New)`; DB unchanged.

---

### Test G14 -- COPY branch -> PASTE blocked (predicate; DB-to-DB branch copy) [was db.29]

Uses [RouteBranch] = Navigation/Routes (`ac4e2c500600b9aa`).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G14" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ac4e2c500600b9aa&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: DB-to-DB branch copy via PASTE not implemented (use Paste New)`; DB unchanged.

---

### Test G15 -- COPY track -> PASTE_BEFORE blocked (predicate; the original-bug case) [was db.30]

Uses [TestTrack] = `1a4eed924904ebbe` (moved to [DST] by test 13). PASTE_BEFORE anchor is [IsolatedWP2] = `af4e23246d01bfa8` (also in [DST] after test 3).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G15" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eed924904ebbe&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=af4e23246d01bfa8&right_click=af4e23246d01bfa8&cmd=10212" | Out-Null
Start-Sleep 3
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: DB-to-DB track copy via PASTE_BEFORE/AFTER not implemented`; DB unchanged.

---

### Test G16 -- COPY track -> PASTE_AFTER blocked (predicate; symmetry with db.30) [was db.31]

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G16" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eed924904ebbe&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=af4e23246d01bfa8&right_click=af4e23246d01bfa8&cmd=10213" | Out-Null
Start-Sleep 3
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: DB-to-DB track copy via PASTE_BEFORE/AFTER not implemented`; DB unchanged.

---

### Test G17 -- NEW_WAYPOINT at non-collection target blocked (predicate) [was db.32]

Right-click target is [IsolatedWP1] (a waypoint object). The menu does not offer NEW_WAYPOINT at an object node; API bypass forces the dispatch to verify the predicate guard.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G17" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&right_click=ce4e43181f01b3ae&cmd=10230" | Out-Null
Start-Sleep 2
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: new waypoint target is not a collection`; DB unchanged.

---

### Test G18 -- NEW_ROUTE at non-collection target blocked (predicate) [was db.33]

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G18" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&right_click=ce4e43181f01b3ae&cmd=10232" | Out-Null
Start-Sleep 2
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: new route target is not a collection`; DB unchanged.

---

### Test G19 -- PASTE_BEFORE at route_point with non-WP clipboard blocked (predicate) [was db.34]

Clipboard has [TestTrack] (non-WP). Anchor is [RP1] = Popa0 in [TestRoute] (which was moved to [DST] by test 12). The predicate's route_point-anchor rule fires before the DB-to-DB track-copy rule.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G19" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eed924904ebbe&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=rp:f34efdd6070022e8:314e56cc09005332&right_click=rp:f34efdd6070022e8:314e56cc09005332&cmd=10212" | Out-Null
Start-Sleep 3
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: PASTE_BEFORE/AFTER at route_point requires waypoint or route_point items only`; DB unchanged.

---

### Test G20 -- COPY route_point, PASTE at collection blocked (D2: route_point at non-route) [was db.36]

D2 negative: a route_point clipboard item is meaningful only at a route or route_point destination. Anywhere else (collection, branch, object) the predicate rejects with `route_point_at_non_route` IMPL ERROR.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+db.G20" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=rp:f34efdd6070022e8:454e11a80b002884&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: route_point items can only be pasted at a route or route_point destination`; DB unchanged.

---

