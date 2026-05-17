# hub Module -- Runbook

Execution-layer steps for the hub module. For shared toolbox, see [`../master_runbook.md`](../master_runbook.md). For module scope and test inventory, see [`plan.md`](plan.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md).

The hub module exercises E80<->FSH cross-spoke operations. Some tests are synchronous (FSH-side writes); others render an E80 ProgressDialog that must FINISH. Every test states its ProgressDialog expectation explicitly in pass criteria.

UUIDs: FSH-native form is dashed-uppercase (`80B2-C48A-5400-D3AE`); navMate canonical / E80 / DB form is lowercase no-dash (`80b2c48a5400d3ae`). The `select=` parameter for `panel=fsh` uses FSH-native form; for `panel=e80` and `panel=database` it uses navMate canonical form. Conversion is purely textual.

---

## Baseline Setup

Order matters: `op=suppress&val=1` MUST precede `op=load_fsh`. See `../master_runbook.md` *Suppress ordering*.

```powershell
git -C C:/dat/Rhapsody checkout -- navMate.db
curl.exe -s "http://localhost:9883/api/test?op=refresh" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+hub+module+reset" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=clear_e80" | Out-Null
Start-Sleep 5
curl.exe -s "http://localhost:9883/api/test?op=load_fsh&path=C:/base/apps/raymarine/apps/navMate/test/_fixtures/test.fsh" | Out-Null
Start-Sleep 3

# Verify baseline
$d = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$e80_wp_n = @($d.waypoints.PSObject.Properties).Count
$fsh_wp_n = @($f.waypoints.PSObject.Properties).Count
$fsh_gr_n = @($f.groups.PSObject.Properties).Count
$fsh_rt_n = @($f.routes.PSObject.Properties).Count
$fsh_tk_n = @($f.tracks.PSObject.Properties).Count
Write-Host "Baseline: E80 wp=$e80_wp_n (expect 0); FSH wp=$fsh_wp_n gr=$fsh_gr_n rt=$fsh_rt_n tk=$fsh_tk_n (expect 50 4 3 123)"
```

## UUID Conversion Helpers

```powershell
function dbToFsh
{
    param([string]$db_uuid)
    $u = $db_uuid.ToUpper()
    return "$($u.Substring(0,4))-$($u.Substring(4,4))-$($u.Substring(8,4))-$($u.Substring(12,4))"
}
function fshToDb
{
    param([string]$fsh_uuid)
    return ($fsh_uuid -replace '-','').ToLower()
}
```

## Wait-NavCmdFinished helper (from master_runbook)

```powershell
$global:nav_cmd_seen = @{}

function Wait-NavCmdFinished
{
    param(
        [Parameter(Mandatory=$true)] [string]$cmdName,
        [Parameter(Mandatory=$true)] [string]$panel,
        [int]$timeout_ms = 10000
    )
    $key = "$panel/$cmdName"
    if (-not $global:nav_cmd_seen.ContainsKey($key)) { $global:nav_cmd_seen[$key] = 0 }
    $global:nav_cmd_seen[$key]++
    $expected = $global:nav_cmd_seen[$key]
    $pattern  = "===== $cmdName ($panel) FINISHED ====="

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

---

## Module Tests

### Section A -- FSH->E80 PASTE (UUID-preserving): seeds E80 organically

#### Test 1 -- Paste FSH WP -> E80 (UUID-preserving)

Uses [FSH_IsolatedWP1] = `80B2-C48A-5400-D3AE` ("Waypoint 25", top-level under FSH my_waypoints). After paste, E80 should have a WP at navMate-form UUID `80b2c48a5400d3ae`.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.1" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=80B2-C48A-5400-D3AE&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 6
```

**Pass:** ProgressDialog 'Paste' STARTED + FINISHED in log. `/api/db` waypoints contains `80b2c48a5400d3ae` named "Waypoint 25". `/api/fsh` still contains the FSH-form record (FSH unchanged). No `ERROR -` or `IMPLEMENTATION ERROR` in log. Record `[HUB_WP] = 80b2c48a5400d3ae` (E80) / `80B2-C48A-5400-D3AE` (FSH).

---

#### Test 2 -- Paste FSH Group -> E80 (UUID-preserving)

Uses [FSH_GroupInRoute] = `C482-CBA0-D14E-67B2` ("Timiteo" group, 6 embedded WPs t01..t06, all referenced by Timiteo route). E80 should get group `c482cba0d14e67b2` with 6 members.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.2" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=C482-CBA0-D14E-67B2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 10
```

**Pass:** ProgressDialog 'Paste' STARTED + FINISHED. `/api/db` groups contains `c482cba0d14e67b2` named "Timiteo" with `num_uuids=6`. All 6 t01..t06 WPs present in `/api/db` waypoints with UUIDs preserved from FSH. FSH state unchanged. Record `[HUB_GR] = c482cba0d14e67b2`.

---

#### Test 3 -- Paste FSH Route -> E80 (UUID-preserving)

Uses [FSH_TestRoute] = `C482-CB9E-D14E-67B2` ("Timiteo" route, 6 embedded points t01..t06). Member WPs already on E80 from Test 2 (SS10.10 satisfied).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.3" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=C482-CB9E-D14E-67B2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10210" | Out-Null
Start-Sleep 8
```

**Pass:** ProgressDialog 'Paste' STARTED + FINISHED. `/api/db` routes contains `c482cb9ed14e67b2` named "Timiteo" with `num_wpts=6`. Member WP UUIDs match the t01..t06 from Test 2. FSH state unchanged. Record `[HUB_RT] = c482cb9ed14e67b2`.

---

#### Test 4 -- GUARD: Paste FSH Track -> E80 silently skipped

Uses [FSH_TestTrack] = `A24E-672E-FE06-0A80` ("Track2-006"). `_pasteAllToE80` skips type='track' at line 1011-1014 with debug log; no ERROR sentinel fires.

```powershell
$tk_before_e80 = @((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).tracks.PSObject.Properties).Count
$tk_before_fsh = @((curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json).tracks.PSObject.Properties).Count

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.4" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=A24E-672E-FE06-0A80&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 5

$tk_after_e80 = @((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).tracks.PSObject.Properties).Count
$tk_after_fsh = @((curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json).tracks.PSObject.Properties).Count
Write-Host "Tracks before: E80=$tk_before_e80 FSH=$tk_before_fsh; after: E80=$tk_after_e80 FSH=$tk_after_fsh"
```

**Pass:** E80 tracks count unchanged (zero before, zero after). FSH tracks count unchanged. Log contains `_pasteAllToE80: skipping track 'Track2-006'` (or similar). ProgressDialog STARTED + FINISHED (empty work). No ERROR sentinel.

**Note:** If E80 already had tracks from a track module run, the count assertion remains "unchanged"; only the cross-spoke item is what must NOT appear.

---

### Section B -- E80->FSH PASTE (UUID-preserving): same-UUID round-trip

These tests fire same-UUID PASTE from E80 to FSH where the FSH side already has the record. PASS criterion: paste succeeds, in-place update or coherent skip, no name-collision sentinel (UUIDs match).

#### Test 5 -- Paste E80 WP -> FSH (same UUID)

Source: [HUB_WP] on E80 (`80b2c48a5400d3ae`). Destination: FSH where `80B2-C48A-5400-D3AE` already exists.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.5" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=80b2c48a5400d3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** NO ProgressDialog (FSH-side write is synchronous). `/api/fsh` waypoints still contains `80B2-C48A-5400-D3AE` named "Waypoint 25". Total FSH waypoint count unchanged. No ERROR sentinel (UUIDs match, no name-collision fire). Log may show in-place-update message or harmless duplicate-skip warning -- both PASS.

**Probe note:** if FAIL with name-collision ERROR despite matching UUIDs, that is the **open observation from FSH alpha** -- the UUID-conflict precedence bug fires here.

---

#### Test 6 -- Paste E80 Group -> FSH (same UUID)

Source: [HUB_GR] on E80 (`c482cba0d14e67b2`).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.6" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=c482cba0d14e67b2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** NO ProgressDialog. `/api/fsh` groups contains `C482-CBA0-D14E-67B2` with 6 embedded wpts (unchanged). No new group record created. No ERROR sentinel.

---

#### Test 7 -- Paste E80 Route -> FSH (same UUID)

Source: [HUB_RT] on E80 (`c482cb9ed14e67b2`).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.7" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=c482cb9ed14e67b2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** NO ProgressDialog. `/api/fsh` routes contains `C482-CB9E-D14E-67B2` with 6 points (unchanged). No new route. No ERROR sentinel.

---

### Section C -- Cross-spoke PASTE_NEW (fresh UUID)

#### Test 8 -- Paste-New E80 WP -> FSH (fresh FSH UUID)

Source: [HUB_WP] on E80 (`80b2c48a5400d3ae`, "Waypoint 25"). PASTE_NEW mints a fresh FSH UUID; FSH ends up with two records both named "Waypoint 25" (one original `80B2-C48A-5400-D3AE`, one fresh).

```powershell
$fsh_wp_before = @((curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json).waypoints.PSObject.Properties).Count

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.8" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=80b2c48a5400d3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 2

$fsh_wp_after = @((curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json).waypoints.PSObject.Properties).Count
Write-Host "FSH WPs before=$fsh_wp_before after=$fsh_wp_after (expect +1)"
```

**Pass:** NO ProgressDialog. FSH waypoint count increased by exactly 1. Two records named "Waypoint 25" on FSH (one with `80B2-C48A-5400-D3AE`, one with a fresh UUID). Record `[HUB_FRESH_FSH_WP]` = the new FSH UUID (look up via name match).

**Probe note:** if FAIL with `ERROR - name 'Waypoint 25' already exists on FSH`, that flags name-uniqueness firing on PASTE_NEW (which it should not -- PASTE_NEW always creates fresh; name dup is normal in FSH for fresh-UUID records *unless* the FSH deconflict policy says otherwise. Document actual behavior.)

---

#### Test 9 -- Paste-New FSH WP -> E80 (fresh navMate UUID)

Source: [FSH_IsolatedWP2] = `83B2-167D-3F00-ED99` ("Waypoint 10"). PASTE_NEW mints a fresh navMate-form UUID; E80 gets a new WP named "Waypoint 10".

```powershell
$e80_wp_before = @((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).waypoints.PSObject.Properties).Count

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.9" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=83B2-167D-3F00-ED99&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 6

$e80_wp_after = @((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).waypoints.PSObject.Properties).Count
Write-Host "E80 WPs before=$e80_wp_before after=$e80_wp_after (expect +1)"
```

**Pass:** ProgressDialog 'Paste New' STARTED + FINISHED. E80 waypoint count +1. New record named "Waypoint 10" with fresh navMate UUID (NOT `83b2167d3f00ed99`). FSH unchanged. Record `[HUB_FRESH_E80_WP]` = the new E80 UUID.

**Probe note:** verify the fresh UUID's byte 1 is in the navMate-assigned family (0x4e), not B2 (E80-assigned). The clipboard seam mints the UUID; E80 accepts it via PASTE_NEW.

---

#### Test 10 -- Paste-New E80 Group -> FSH (fresh group UUID + fresh members)

Source: [HUB_GR] on E80 (`c482cba0d14e67b2`, "Timiteo"). PASTE_NEW mints fresh group UUID and fresh member UUIDs on FSH.

```powershell
$fsh_gr_before = @((curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json).groups.PSObject.Properties).Count

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.10" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=c482cba0d14e67b2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 3

$fsh_gr_after = @((curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json).groups.PSObject.Properties).Count
Write-Host "FSH groups before=$fsh_gr_before after=$fsh_gr_after (expect +1)"
```

**Pass:** NO ProgressDialog. FSH group count +1. New group named "Timiteo" (or deconflicted variant -- FSH enforces name uniqueness per `_deconflictFSHName`) with 6 embedded fresh-UUID members. Record the new group's FSH UUID.

**Probe note:** if FSH `_deconflictFSHName` renames "Timiteo" -> "Timiteo (2)" or similar, document it. PASS regardless.

---

#### Test 11 -- Paste-New FSH Route -> E80 (fresh route UUID; members reused)

Source: [FSH_TestRoute] = `C482-CB9E-D14E-67B2` ("Timiteo" route, 6 points). Member WPs t01..t06 already on E80 (from Test 2). PASTE_NEW mints fresh route UUID; member WPs reused by reference (no fresh copies).

```powershell
$e80_rt_before = @((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).routes.PSObject.Properties).Count
$e80_wp_before2 = @((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).waypoints.PSObject.Properties).Count

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.11" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=C482-CB9E-D14E-67B2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10211" | Out-Null
Start-Sleep 8

$e80_rt_after = @((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).routes.PSObject.Properties).Count
$e80_wp_after2 = @((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).waypoints.PSObject.Properties).Count
Write-Host "E80 routes before=$e80_rt_before after=$e80_rt_after (expect +1); WPs before=$e80_wp_before2 after=$e80_wp_after2 (expect unchanged)"
```

**Pass:** ProgressDialog 'Paste New' STARTED + FINISHED. E80 routes count +1, WP count unchanged. New route named "Timiteo" (or deconflicted) with 6 points referencing the existing t01..t06 UUIDs. Record `[HUB_FRESH_E80_RT]` = new route UUID.

---

### Section D -- Cross-spoke CUT/PASTE

Critical: source-side cleanup dispatch. The analog of the navOpsDB cut-dispatch bug from FSH alpha. CUT from E80 must trigger `_cutE80Waypoint/Group/Route` (async, ProgressDialog); CUT from FSH must trigger `_cutFSHWaypoint/Group/Route` (synchronous, no ProgressDialog).

#### Test 12 -- Cut E80 WP, Paste to FSH

Cut [HUB_FRESH_E80_WP] (the fresh-UUID "Waypoint 10" on E80 from hub.9). E80-side cleanup renders ProgressDialog. FSH ends up with a record at the fresh navMate UUID (NOT at the original FSH UUID).

Resolve the fresh UUID at runtime from `/api/db`:

```powershell
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$fresh_wp = $db.waypoints.PSObject.Properties | Where-Object { $_.Value.name -eq 'Waypoint 10' } | Select-Object -First 1
$HUB_FRESH_E80_WP = $fresh_wp.Name
Write-Host "Cutting E80 WP: $HUB_FRESH_E80_WP"

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.12" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$HUB_FRESH_E80_WP&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 6
```

**Pass:** ProgressDialog (for E80-side delete cleanup) STARTED + FINISHED. `/api/db` waypoints no longer contains `$HUB_FRESH_E80_WP`. `/api/fsh` waypoints gains a record at navMate-form `$HUB_FRESH_E80_WP` converted to FSH-form (via `dbToFsh`).

**Bug probe:** if FAIL with E80-side WP still present after the paste, the cross-spoke CUT cleanup dispatch is broken (analog of the navOpsDB bug -- `_cutE80*` may be misrouted to a wrong helper).

---

#### Test 13 -- Cut FSH WP, Paste to E80

Cut [FSH_IsolatedWP3] = `83B2-167D-3F00-37D9` ("Waypoint 14"). FSH-side cleanup synchronous. E80-side write renders ProgressDialog.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.13" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=83B2-167D-3F00-37D9&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 6
```

**Pass:** ProgressDialog (for E80-side write) STARTED + FINISHED. `/api/fsh` waypoints no longer contains `83B2-167D-3F00-37D9`. `/api/db` waypoints gains `83b2167d3f00 37d9` named "Waypoint 14".

---

#### Test 14 -- Cut E80 Group, Paste to FSH

Cut [HUB_GR] (Timiteo, `c482cba0d14e67b2`) from E80. Group + 6 members migrate. E80 cleanup ProgressDialog. NOTE: the original "Timiteo" group on FSH (`C482-CBA0-D14E-67B2`) already exists -- this CUT/PASTE attempt against an already-present same-UUID destination may behave as in-place update + E80 cleanup, OR may collide if name+UUID semantics differ from Section B.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.14" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=c482cba0d14e67b2&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 10
```

**Pass:** ProgressDialog (E80 group delete) STARTED + FINISHED. `/api/db` no longer contains group `c482cba0d14e67b2` and its 6 members (or members may persist as ungrouped depending on cut semantics -- document actual behavior). `/api/fsh` groups still contains `C482-CBA0-D14E-67B2` with 6 wpts.

**Probe note:** Cross-spoke CUT for a destination-already-present group is a coverage gap until tested. The expected behavior is "E80 source cleaned up; FSH destination already has the data so no real write." Document actual outcome.

---

#### Test 15 -- Cut FSH Group, Paste to E80

Cut [FSH_GroupNoRoute] = `C482-CB97-D14E-67B2` ("test" group, 79 members, none in route). FSH-side cleanup synchronous; E80 receives 79 new WPs + 1 group via ProgressDialog. This is a stress test for the FSH->E80 group cut path.

```powershell
$e80_wp_before15 = @((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).waypoints.PSObject.Properties).Count

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.15" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=C482-CB97-D14E-67B2&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 30   # 79 WPs + 1 group takes significant E80 time

$e80_wp_after15 = @((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).waypoints.PSObject.Properties).Count
Write-Host "E80 WPs before=$e80_wp_before15 after=$e80_wp_after15 (expect +79)"
```

**Pass:** ProgressDialog (E80 group write) STARTED + FINISHED (may take 20-30s for 79 WPs). `/api/fsh` groups no longer contains `C482-CB97-D14E-67B2`. `/api/db` groups gains `c482cb97d14e67b2` named "test" with `num_uuids=79`. All 79 member WPs in `/api/db` waypoints. FSH waypoints count unchanged (members were embedded, not in `/api/fsh.waypoints`).

**Probe note:** if Wait-NavCmdFinished times out at default 10s, increase to 30000ms for this test specifically. The teensyBoat / WPMGR pipeline serializes WP creation.

---

### Section E -- Cross-spoke PUSH

Update existing destination record. Uses already-on-destination targets (`_pushToFSH` / `_pushToE80` warn+skip when missing).

#### Test 16 -- Push E80 WP -> FSH (cmd 10251)

Source: [HUB_WP] on E80 (`80b2c48a5400d3ae`). Destination: FSH record `80B2-C48A-5400-D3AE` (still present from baseline).

The push must use `cmd=10251` (`CTX_CMD_PUSH_FSH`). For E80 panel + cmd 10251, `_doPush` enters the panel=e80 branch and routes to `_pushToFSH`. The right-click target must be a node on the FSH panel (the destination). For PUSH commands, the right_click_node is the destination spoke node, but since cmd 10251 routes directly to `_pushToFSH` regardless of right_click, we use any FSH node here.

```powershell
# Capture pre-push name to detect change
$fsh_before = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$wp_name_before = $fsh_before.waypoints.'80B2-C48A-5400-D3AE'.name

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.16" | Out-Null
# Select on E80 panel; cmd 10251 = PUSH TO FSH
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=80b2c48a5400d3ae&right_click=80b2c48a5400d3ae&cmd=10251" | Out-Null
Start-Sleep 2

$fsh_after = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$wp_name_after = $fsh_after.waypoints.'80B2-C48A-5400-D3AE'.name
Write-Host "FSH WP name before=$wp_name_before after=$wp_name_after"
```

**Pass:** NO ProgressDialog. FSH waypoint `80B2-C48A-5400-D3AE` still present with name "Waypoint 25" (touched but value-equal -- E80 source has same canonical fields). No `ERROR -` or "not on FSH -- skipping" warning. Log shows `PUSH TO FSH (e80) FINISHED`.

---

#### Test 17 -- Push FSH WP -> E80 (cmd 10252)

Source: FSH `80B2-C48A-5400-D3AE`. Destination: E80 `80b2c48a5400d3ae` (present from Test 1).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.17" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=80B2-C48A-5400-D3AE&right_click=80B2-C48A-5400-D3AE&cmd=10252" | Out-Null
Start-Sleep 6
```

**Pass:** ProgressDialog 'Push To E80' STARTED + FINISHED. `/api/db` waypoint `80b2c48a5400d3ae` still present with name "Waypoint 25". No new record created. No ERROR.

---

#### Test 18 -- Push E80 Group -> FSH (multi-WP update)

Source: E80 group `c482cba0d14e67b2` (still present after Test 14 cut/paste? -- if cut removed it from E80, re-establish via FSH->E80 first). NOTE: depends on Test 14's actual outcome. If E80 no longer has the group, skip this test and document.

```powershell
# Verify precondition: group still on E80
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$grp_present = [bool]($db.groups.PSObject.Properties | Where-Object { $_.Name -eq 'c482cba0d14e67b2' })

if (-not $grp_present)
{
    Write-Host "hub.18: precondition not met -- group absent from E80 (Test 14 removed it); re-establish before continuing"
    # Re-establish via FSH -> E80 paste
    curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=C482-CBA0-D14E-67B2&cmd=10200" | Out-Null
    Start-Sleep 1
    curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
    Start-Sleep 10
}

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.18" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=c482cba0d14e67b2&right_click=c482cba0d14e67b2&cmd=10251" | Out-Null
Start-Sleep 3
```

**Pass:** NO ProgressDialog. FSH group `C482-CBA0-D14E-67B2` still present with 6 wpts. No new group. Log shows `PUSH TO FSH (e80) FINISHED`.

---

#### Test 19 -- Push FSH Route -> E80

Source: FSH route `C482-CB9E-D14E-67B2`. Destination: E80 route `c482cb9ed14e67b2` (still present from Test 3).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.19" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=C482-CB9E-D14E-67B2&right_click=C482-CB9E-D14E-67B2&cmd=10252" | Out-Null
Start-Sleep 8
```

**Pass:** ProgressDialog 'Push To E80' STARTED + FINISHED. `/api/db` route `c482cb9ed14e67b2` still present with `num_wpts=6`. No new route. No ERROR.

---

### Section F -- Round-trip identity

#### Test 20 -- E80->FSH->E80 WP round-trip

Use [HUB_FRESH_E80_WP] from hub.9 (the fresh "Waypoint 10" on E80 with navMate-assigned UUID; FSH does not have this UUID natively). Hop 1: E80->FSH PASTE (lands at fresh UUID on FSH). Hop 2: FSH->E80 PASTE_NEW (lands as second fresh UUID on E80, distinct from source). Compare fields.

```powershell
# Resolve source UUID (fresh "Waypoint 10" from hub.9 -- may have been cut in hub.12)
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$src = $db.waypoints.PSObject.Properties | Where-Object { $_.Value.name -eq 'Waypoint 10' } | Select-Object -First 1
if (-not $src)
{
    Write-Host "hub.20: re-establishing 'Waypoint 10' on E80 via FSH paste-new"
    curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=83B2-167D-3F00-ED99&cmd=10200" | Out-Null
    Start-Sleep 1
    curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
    Start-Sleep 6
    $db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
    $src = $db.waypoints.PSObject.Properties | Where-Object { $_.Value.name -eq 'Waypoint 10' } | Select-Object -First 1
}
$src_uuid    = $src.Name
$src_name    = $src.Value.name
$src_lat     = $src.Value.lat
$src_lon     = $src.Value.lon

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.20" | Out-Null

# Hop 1: E80 -> FSH (same UUID)
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$src_uuid&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2

# Hop 2: FSH -> E80 PASTE_NEW (fresh UUID)
$fsh_uuid_hop1 = (dbToFsh $src_uuid)
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=$fsh_uuid_hop1&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 6

# Find new E80 record (second "Waypoint 10" with different UUID from $src_uuid)
$db_after = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$candidates = $db_after.waypoints.PSObject.Properties | Where-Object { $_.Value.name -eq 'Waypoint 10' -and $_.Name -ne $src_uuid }
$dst = $candidates | Select-Object -First 1
$dst_lat = $dst.Value.lat
$dst_lon = $dst.Value.lon
$lat_match = ([math]::Abs($src_lat - $dst_lat) -lt 0.0001)
$lon_match = ([math]::Abs($src_lon - $dst_lon) -lt 0.0001)
Write-Host "Round-trip lat: $src_lat -> $dst_lat (match=$lat_match); lon: $src_lon -> $dst_lon (match=$lon_match)"
```

**Pass:** Two ProgressDialog cycles (Hop 1 had none -- FSH-side; Hop 2 has one -- E80-side PASTE_NEW). lat/lon match within 1e-4. Source and destination UUIDs differ. Name preserved. Source still on E80 (PASTE_NEW didn't consume it).

---

#### Test 21 -- FSH->E80->FSH Group round-trip with members in route

Use [FSH_GroupInRoute] = `C482-CBA0-D14E-67B2` ("Timiteo", 6 members). Hop 1 FSH->E80 already done (Test 2); skip and validate. Hop 2: E80->FSH PASTE_NEW. Members reused if already on FSH.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.21" | Out-Null
# Hop 2: E80 -> FSH PASTE_NEW
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=c482cba0d14e67b2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 3

$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$timiteo_count = @($f.groups.PSObject.Properties | Where-Object { $_.Value.name -like 'Timiteo*' }).Count
Write-Host "FSH groups matching 'Timiteo*' count=$timiteo_count (expect >= 2 from earlier tests + this one)"
```

**Pass:** NO ProgressDialog. FSH gains a new "Timiteo*" group (deconflicted name). Member WPs reused from existing FSH WPs (no count change in FSH waypoints if all members already there). No ERROR.

---

### Section G -- Multi-select cross-spoke

#### Test 22 -- Multi-select 2 E80 WPs, Paste to FSH

Two WPs on E80; select both with comma-separated select; paste to FSH.

```powershell
# Find two arbitrary E80 WPs (anything from accumulated state)
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$wps = @($db.waypoints.PSObject.Properties) | Select-Object -First 2
$u1 = $wps[0].Name
$u2 = $wps[1].Name
Write-Host "Multi-selecting E80 WPs: $u1, $u2"

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.22" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$u1,$u2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2

$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$u1_fsh = (dbToFsh $u1)
$u2_fsh = (dbToFsh $u2)
$present_1 = [bool]$f.waypoints.$u1_fsh
$present_2 = [bool]$f.waypoints.$u2_fsh
Write-Host "FSH has $u1_fsh = $present_1; $u2_fsh = $present_2"
```

**Pass:** NO ProgressDialog. Both UUIDs present on FSH (either pre-existing or newly inserted). No ERROR. No name-collision sentinel (UUIDs match).

---

#### Test 23 -- Multi-select FSH Group + Route, Paste to E80

Heterogeneous types. Per-type dispatch in `_pasteAllToE80` must process group before route (route's member-existence check requires group members already pasted).

Use [FSH_GroupInRoute] + [FSH_TestRoute]. Both share members t01..t06 so the route's members are satisfied by the group's paste (if not already on E80).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.23" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=C482-CBA0-D14E-67B2,C482-CB9E-D14E-67B2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 12   # group + route on E80
```

**Pass:** ProgressDialog STARTED + FINISHED. `/api/db` groups contains `c482cba0d14e67b2` (already present from Test 2; no-op) and routes contains `c482cb9ed14e67b2` (already present from Test 3; no-op). No ERROR sentinel about member-WP-missing. No type-ordering bug visible.

**Probe note:** if this fires `ERROR - route has missing member WPs`, the per-type dispatch did not process the group before the route. That is a real bug.

---

### Section H -- Cross-spoke guards

#### Test 24 -- GUARD: Name collision destination-side

Setup: ensure E80 has a WP named "Waypoint 25" with a different UUID than the FSH "Waypoint 25". The FSH has `80B2-C48A-5400-D3AE` named "Waypoint 25". E80 may have it at the same UUID (from Test 1). For a collision test we need a *different* UUID on E80 with the SAME name.

Create one via PASTE_NEW from FSH:

```powershell
# Establish a fresh-UUID "Waypoint 25" on E80 (distinct from 80b2c48a5400d3ae)
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=80B2-C48A-5400-D3AE&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 6

$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$candidates = $db.waypoints.PSObject.Properties | Where-Object { $_.Value.name -eq 'Waypoint 25' -and $_.Name -ne '80b2c48a5400d3ae' }
$E80_FRESH_WP25 = ($candidates | Select-Object -First 1).Name
Write-Host "Fresh E80 'Waypoint 25' UUID: $E80_FRESH_WP25"

# Now attempt to paste E80's fresh-UUID 'Waypoint 25' to FSH -- name collides (FSH already has 'Waypoint 25' at a different UUID)
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.24" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_FRESH_WP25&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2

$log = curl.exe -s "http://localhost:9883/api/log?since=mark"
$collided = $log -match "name 'Waypoint 25' already exists" -or $log -match "name-collision" -or $log -match "name conflict"
Write-Host "Collision sentinel observed = $collided"
```

**Pass:** NO ProgressDialog (guard fires pre-write). FSH state unchanged (no new record at the E80 fresh UUID's FSH-form). Log contains a name-collision ERROR sentinel referencing "Waypoint 25". Neither side mutated.

**Probe note:** if the paste succeeds (creates a fresh-UUID FSH record with name "Waypoint 25" alongside the original), then FSH's `_deconflictFSHName` engaged in PASTE -- that would be a different bug (PASTE should not silently deconflict; PASTE_NEW does).

---

#### Test 25 -- UUID-conflict in-place-update probe

Paste E80 [HUB_WP] (`80b2c48a5400d3ae`, "Waypoint 25") -> FSH where same UUID + same name exists. Expect in-place update PASS. Probes the FSH-alpha-noted possibility of name-uniqueness firing before UUID-match.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.25" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=80b2c48a5400d3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2

$log = curl.exe -s "http://localhost:9883/api/log?since=mark"
$has_error = $log -match "ERROR -"
$has_name_collision = $log -match "name.*already exists"
Write-Host "ERROR sentinel: $has_error; Name-collision sentinel: $has_name_collision"
```

**Pass:** NO ProgressDialog. NO ERROR sentinel. NO name-collision sentinel. FSH `80B2-C48A-5400-D3AE` still present (touched but identical).

**Bug probe:** if name-collision fires here, the **open observation from FSH alpha** is confirmed -- UUID-match precedence is wrong.

---

#### Test 26 -- GUARD: Intra-clipboard name collision

Hard-abort when multi-select contains two same-named WPs. Establish two same-named WPs on E80 first (PASTE_NEW two copies of [FSH_IsolatedWP1]).

```powershell
# Create two "Waypoint 25" fresh-UUID records on E80
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=80B2-C48A-5400-D3AE&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 6

curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=80B2-C48A-5400-D3AE&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 6

# Find two same-named E80 WPs (any pair with name = 'Waypoint 25')
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$pair = @($db.waypoints.PSObject.Properties | Where-Object { $_.Value.name -eq 'Waypoint 25' } | Select-Object -First 2)
$p1 = $pair[0].Name
$p2 = $pair[1].Name
Write-Host "Multi-selecting same-named E80 WPs: $p1, $p2"

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.26" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$p1,$p2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2

$log = curl.exe -s "http://localhost:9883/api/log?since=mark"
$intra_collision = $log -match "intra-clipboard" -or $log -match "duplicate name" -or $log -match "two items with name"
Write-Host "Intra-clipboard collision sentinel: $intra_collision"
```

**Pass:** NO ProgressDialog. Hard-abort ERROR sentinel referencing intra-clipboard name collision. FSH state unchanged (no fresh records inserted).

---

#### Test 27 -- GUARD: Descendant-of-clipboard

Cross-spoke route paste at one of its own member-WP nodes. Use [FSH_TestRoute] (`C482-CB9E-D14E-67B2`) copied; paste at one of its members (e.g. t01 = `C482-CB98-D14E-67B2`).

Wait -- pasting at a node on the SAME panel where the clipboard came FROM is a same-panel descendant. For cross-spoke, the route is on the FSH source and the destination would need to be the E80 panel where some member of the FSH route also lives. The route's t01..t06 are on E80 (from Test 2). Right-click target on E80 = t01 (`d44e40468d000d96`? -- need to verify the cross-spoke UUID).

Actually the FSH route's t01 has FSH UUID `C482-CB98-D14E-67B2`. Its navMate-form is `c482cb98d14e67b2`. After Test 2 (FSH->E80 paste of Timiteo group), E80 has the member at that UUID.

```powershell
# Copy FSH route; paste at E80 t01 (which is a descendant of the route)
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.27" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=C482-CB9E-D14E-67B2&cmd=10200" | Out-Null
Start-Sleep 1
# Right-click target = E80 t01 (member of the route in clipboard)
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=c482cb98d14e67b2&right_click=c482cb98d14e67b2&cmd=10210" | Out-Null
Start-Sleep 2

$log = curl.exe -s "http://localhost:9883/api/log?since=mark"
$descendant_block = $log -match "descendant" -or $log -match "cannot paste.*into.*clipboard" -or $log -match "ancestor"
Write-Host "Descendant guard sentinel: $descendant_block"
```

**Pass:** NO ProgressDialog. Descendant-block ERROR sentinel in log. E80 state unchanged.

**Probe note:** cross-spoke descendant detection is a subtle case -- the clipboard's items are FSH-form UUIDs internally; the destination tree's node is an E80-form UUID. `_destIsDescendantOfClipboard` must do the conversion. Verify the guard fires.

---

#### Test 28 -- Route paste cross-spoke with missing member WPs

Force a route with members missing on destination. Use a FSH route whose members do NOT live on E80. The Michel_Agua route is the easiest (10 members under Michel_Agua group, none on E80 yet).

[FSH_GroupAguaRoute] = `C782-7BB6-7A46-4722` ("Michel_Agua" group). The Agua route lives at a separate UUID -- need to look it up. From uuid_index.md lookups table: `Agua route` = `d64e8c7e4400a186` (DB-side). But that's the *DB* Agua route, not the FSH one. The FSH Agua route's FSH UUID isn't in the index; derive at runtime.

Simpler: pick a FSH route by listing them; find one whose member UUIDs aren't on E80.

```powershell
$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$e80_uuids = @{}
foreach ($p in $db.waypoints.PSObject.Properties) { $e80_uuids[$p.Name] = 1 }

$missing_route = $null
foreach ($rp in $f.routes.PSObject.Properties)
{
    $rt = $rp.Value
    $missing = 0
    foreach ($wpt in $rt.wpts)
    {
        $nav_form = (fshToDb $wpt.uuid)
        if (-not $e80_uuids[$nav_form]) { $missing = 1; break }
    }
    if ($missing) { $missing_route = $rp.Name; break }
}
Write-Host "Route with missing members: $missing_route"

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+hub.28" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=$missing_route&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10210" | Out-Null
Start-Sleep 12

$db_after = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$route_navform = (fshToDb $missing_route)
$route_present = [bool]$db_after.routes.$route_navform
Write-Host "Route '$missing_route' on E80 after paste: $route_present"

$log = curl.exe -s "http://localhost:9883/api/log?since=mark"
$miss_sentinel = $log -match "missing" -or $log -match "not found on E80"
Write-Host "Missing-member sentinel: $miss_sentinel"
```

**Pass:** Either (a) route absent from E80 + missing-member ERROR sentinel (hard-reject) OR (b) route present on E80 with members pulled along (auto-pull). Document the actual behavior. ProgressDialog STARTED + FINISHED regardless. No catastrophic failure.

**Probe note:** SS10.10 normally suppresses this in the UI menu. The `/api/test` bypass exposes the underlying `_pasteRouteToE80` behavior. If it silently creates a route with dangling refs, that is a bug.

---

End of hub module runbook.

## Module Status

After alpha-debug pass clean:
- Update `apps/navMate/test/master_plan.md` -- hub status "Stub" -> "Solid"
- Update `apps/navMate/docs/testing.md` -- drop "(stub)" suffix
- Update memory `navops_phase4_testplan_refactor` with hub completion + any bugs fixed
