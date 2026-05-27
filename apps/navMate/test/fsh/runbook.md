# fsh Module -- Runbook

Execution-layer steps for the fsh module. For shared toolbox, see [`../master_runbook.md`](../master_runbook.md). For module scope and test inventory, see [`plan.md`](plan.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md).

FSH is **synchronous**: operations mutate `$navFSH::fsh_db` in-memory and complete in a single wx idle tick. There is no ProgressDialog to wait for. Test sleeps are 1-2s typical (3s when a step might trigger refresh side-effects).

UUIDs: FSH-native form is dashed-uppercase (`CE4E-4318-1F01-B3AE`). The `select=` parameter for `panel=fsh` uses this form verbatim. The DB panel and `/api/nmdb` use lowercase-no-dash form (`ce4e43181f01b3ae`). Conversion is purely textual: insert `-` every 4 chars and uppercase (db -> fsh), or strip `-` and lowercase (fsh -> db).

---

## Baseline Setup

Order matters: `op=suppress&val=1` MUST precede `op=load_fsh`. The in-memory FSH may be dirty (Patrick's interactive session or a prior module test run); loading on a dirty FSH raises a `discard / save / save-as / cancel` confirm dialog. With suppress enabled the dialog auto-handles as DISCARD; without it, the dialog blocks the wx idle loop and the test sequence hangs. See `../master_runbook.md` *Suppress ordering*.

```powershell
git -C C:/dat/Rhapsody checkout -- navMate.db
curl.exe -s "http://localhost:9883/api/test?op=refresh" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+fsh+module+reset" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=clear_e80" | Out-Null
Start-Sleep 5
curl.exe -s "http://localhost:9883/api/test?op=load_fsh&path=C:/base/apps/raymarine/apps/navMate/test/_fixtures/test.fsh" | Out-Null
Start-Sleep 3

# Verify baseline
$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$wp_n = @($f.waypoints.PSObject.Properties).Count
$gr_n = @($f.groups.PSObject.Properties).Count
$rt_n = @($f.routes.PSObject.Properties).Count
$tk_n = @($f.tracks.PSObject.Properties).Count
Write-Host "FSH baseline: wp=$wp_n gr=$gr_n rt=$rt_n tk=$tk_n (expect 50 4 3 123)"
```

## UUID Conversion Helpers

Drop these near the top of any session that runs FSH tests:

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

---

## Positive Tests

### Test 1 -- Paste WP to FSH (UUID-preserving)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.1" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/fsh` waypoints contains `CE4E-4318-1F01-B3AE` named "BOCAS1"; no `ERROR -` or `IMPLEMENTATION ERROR` in `/api/log?since=mark`. Record `[FSH_WP]` = `CE4E-4318-1F01-B3AE`.

---

### Test 2 -- Paste Group to FSH (UUID-preserving)

Uses [GroupInRoute] = Popa (`244e8e100800400a`, 11 members). FSH does not have a Popa group at baseline (4 fixture groups: Michel_Agua, Michel_Sumwood, test, Timiteo).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.2" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/fsh` groups contains `244E-8E10-0800-400A` named "Popa" with 11 embedded `wpts`. Record `[FSH_GR]` = `244E-8E10-0800-400A`.

---

### Test 3 -- Paste Route to FSH (UUID-preserving)

Members must already be on FSH (test 2 placed them; preflight checks).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.3" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/fsh` routes contains `F34E-FDD6-0700-22E8` named "Popa" with 11 embedded `wpts`. Record `[FSH_RT]` = `F34E-FDD6-0700-22E8`.

---

### Test 4 -- Paste Track to FSH (UUID-preserving) -- FSH-unique

E80 blocks paste-to-tracks; FSH allows. Uses [TestTrack] (`1a4eed924904ebbe`).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.4" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eed924904ebbe&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/fsh` tracks contains `1A4E-ED92-4904-EBBE` named "2005-11-25-SanD" (truncated to FSH 15-char name limit; source DB name "2005-11-25-SanDiego2Oceanside"); no ERROR sentinel. Total FSH tracks = 124 (123 fixture + 1 new). Record `[FSH_TK]` = `1A4E-ED92-4904-EBBE`.

---

### Test 5 -- Copy FSH WP, Push to DB

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.5" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=CE4E-4318-1F01-B3AE&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10250" | Out-Null
Start-Sleep 2
```

**Pass:** PUSH STARTED/FINISHED in log; `/api/nmdb` waypoint `ce4e43181f01b3ae` still has `collection_uuid=2b4e3308ca00cf66` (push does NOT move records); no ERROR.

---

### Test 6 -- Copy FSH Group, Push to DB

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.6" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=244E-8E10-0800-400A&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10250" | Out-Null
Start-Sleep 3
```

**Pass:** PUSH STARTED/FINISHED; `/api/nmdb` Popa group `244e8e100800400a` `parent_uuid` unchanged; 11 members still present; no ERROR.

---

### Test 7 -- Copy FSH Route, Push to DB

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.7" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=F34E-FDD6-0700-22E8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10250" | Out-Null
Start-Sleep 3
```

**Pass:** PUSH STARTED/FINISHED; Popa route `f34efdd6070022e8` in `/api/nmdb` has 11 route_waypoints; member `wp_uuid` values preserved.

---

### Test 8 -- Multi-select Group + Route, Push to DB

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.8" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=244E-8E10-0800-400A,F34E-FDD6-0700-22E8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10250" | Out-Null
Start-Sleep 3
```

**Pass:** log shows `_doCopy: fsh 2 item(s)`; PUSH STARTED/FINISHED; both UUIDs preserved in `/api/nmdb`; no ERROR.

---

### Test 9 -- Copy FSH WP, Paste New to DB (fresh UUID)

Uses [FSH_IsolatedWP1] = `80B2-C48A-5400-D3AE` ("Waypoint 25") from the fixture.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.9" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=80B2-C48A-5400-D3AE&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
Start-Sleep 2
```

**Pass:** new "Waypoint 25" in `/api/nmdb` waypoints under `collection_uuid=6f4e72ceae0264de` with a FRESH UUID (NOT `80b2c48a5400d3ae`); byte 1 = `0x4e` (navMate-assigned); FSH-side `80B2-C48A-5400-D3AE` still present.

---

### Test 10 -- Cut FSH WP, Paste to DB (UUID preserved)

Uses [FSH_IsolatedWP2] = `83B2-167D-3F00-ED99` ("Waypoint 10").

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.10" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=83B2-167D-3F00-ED99&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/nmdb` waypoint `83b2167d3f00ed99` under `collection_uuid=6f4e72ceae0264de` (UUID preserved); FSH-side `83B2-167D-3F00-ED99` absent from `/api/fsh` waypoints.

---

### Test 11a -- Delete FSH WP (success)

Uses [FSH_IsolatedWP3] = `83B2-167D-3F00-37D9` ("Waypoint 14"). Top-level, no route ref.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.11a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=83B2-167D-3F00-37D9&right_click=83B2-167D-3F00-37D9&cmd=10220" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/fsh` waypoints does NOT contain `83B2-167D-3F00-37D9`; DELETE WAYPOINT STARTED/FINISHED; no ERROR.

---

### Test 11b -- Delete FSH Group (dissolve)

Dissolve cmd=10221 (DELETE_GROUP without WPS). The group shell is removed; embedded member wpts migrate to top-level `my_waypoints` (the implicit FSH ungrouped pool, mirrored as `/api/fsh.waypoints`). Route references to those WP UUIDs are unaffected because FSH routes embed their own wpt records (separate from the group's embedded records). Parallels db.5.

Uses [FSH_GroupAguaRoute] = `C782-7BB6-7A46-4722` (Michel_Agua, 10 members). All 10 are also embedded in the Michel_Agua route -- dissolving the GROUP does NOT touch the route.

```powershell
# Pre-snapshot
$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$pre_wp_n  = @($f.waypoints.PSObject.Properties).Count
$pre_grp   = $f.groups.'C782-7BB6-7A46-4722'
$pre_grp_n = if ($pre_grp) { @($pre_grp.wpts).Count } else { 0 }
$pre_rt    = $f.routes.'80B2-C48A-3A00-A1F1'
$pre_rt_n  = if ($pre_rt) { @($pre_rt.wpts).Count } else { 0 }
$members   = if ($pre_grp) { @($pre_grp.wpts | ForEach-Object { $_.uuid }) } else { @() }

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.11b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=C782-7BB6-7A46-4722&right_click=C782-7BB6-7A46-4722&cmd=10221" | Out-Null
Start-Sleep 2

# Post-state verification
$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$grp_present  = [bool]$f.groups.'C782-7BB6-7A46-4722'
$post_wp_n    = @($f.waypoints.PSObject.Properties).Count
$post_rt      = $f.routes.'80B2-C48A-3A00-A1F1'
$post_rt_n    = if ($post_rt) { @($post_rt.wpts).Count } else { 0 }
$migrated     = @($members | Where-Object { $f.waypoints.$_ })
Write-Host "Group shell present (expect False): $grp_present"
Write-Host "my_waypoints count: $pre_wp_n -> $post_wp_n (expect +$pre_grp_n)"
Write-Host "Members migrated to my_waypoints: $($migrated.Count) of $pre_grp_n"
Write-Host "Michel_Agua route wpts: $pre_rt_n -> $post_rt_n (expect unchanged)"
```

**Pass:** group shell `C782-7BB6-7A46-4722` absent from `/api/fsh.groups`; all 10 former members now keyed in `/api/fsh.waypoints` (top-level / my_waypoints); the Michel_Agua route's wpt count unchanged; no ERROR.

**Fail:** group still present, OR fewer than 10 members migrated, OR the route lost wpts (would indicate dissolve incorrectly cascaded to routes), OR an IMPLEMENTATION ERROR fired.

---

### Test 13 -- Delete via FSH Routes header

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.13" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10223" | Out-Null
Start-Sleep 3
```

**Pass:** `/api/fsh` routes is empty `{}`; groups + their embedded members still present; no ERROR.

---

### Test 14 -- Delete via FSH Groups header

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.14" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10222" | Out-Null
Start-Sleep 4
```

**Pass:** `/api/fsh` groups is empty `{}`; all 5 groups (4 fixture + Popa from test 2) and their embedded members gone; top-level isolated WPs preserved; tracks unchanged.

---

### Test 15a -- Re-upload Popa group to FSH

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.15a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** Popa group `244E-8E10-0800-400A` on FSH with 11 embedded members.

---

### Test 15b -- Delete FSH Group + members via specific group node

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.15b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=244E-8E10-0800-400A&right_click=244E-8E10-0800-400A&cmd=10222" | Out-Null
Start-Sleep 2
```

**Pass:** group `244E-8E10-0800-400A` absent from `/api/fsh`; all 11 members absent (members were embedded; gone with the group); no ERROR.

---

### Test 16a -- Re-upload IsolatedWP1 to FSH

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.16a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `CE4E-4318-1F01-B3AE` present in `/api/fsh` waypoints.

---

### Test 16b -- Delete via FSH My Waypoints (all ungrouped)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.16b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10222" | Out-Null
Start-Sleep 3
```

**Pass:** `/api/fsh` waypoints is empty `{}` (or near-empty -- the 50 fixture WPs + the one we re-uploaded in 16a, minus any consumed by earlier tests, should all be gone); no ERROR.

---

### Test 17a -- Re-upload Popa group (setup for paste-new tests)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.17a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** Popa group on FSH with 11 members.

---

### Test 17b -- Re-upload TestRoute

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.17b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** Popa route on FSH with 11 wpts.

---

### Test 18 -- Paste New WP to FSH (fresh UUID)

Uses [IsolatedWP2] from DB (`af4e23246d01bfa8`, BOCAS2).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.18" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=af4e23246d01bfa8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10211" | Out-Null
Start-Sleep 2
```

**Pass:** new "BOCAS2" on `/api/fsh` waypoints with a FRESH FSH UUID (NOT `AF4E-2324-6D01-BFA8`); DB record `af4e23246d01bfa8` unchanged.

---

### Test 19 -- Paste New Group to FSH (all-fresh UUIDs)

Uses [TestGroup] = Timiteo (`1a4eaf5a8c00e922`, 6 members) from DB. The FSH fixture's Timiteo (`C482-CBA0-D14E-67B2`) was removed in test 14; this PASTE_NEW creates a fresh-UUID Timiteo on FSH.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.19" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eaf5a8c00e922&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 3
```

**Pass:** new Timiteo group on FSH with a fresh FSH UUID (NOT `1A4E-AF5A-8C00-E922` and NOT `C482-CBA0-D14E-67B2`); 6 members each with fresh FSH UUIDs.

---

### Test 20 -- Paste New Route to FSH (fresh route UUID, member WP UUIDs reused)

Pre-cleanup: delete the existing Popa route on FSH if present (test 17b's upload) so the paste-new produces a distinct fresh route.

```powershell
# Pre-cleanup
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.20+precleanup" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10223" | Out-Null
Start-Sleep 3

# Actual test
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.20" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10211" | Out-Null
Start-Sleep 2
```

**Pass:** new "Popa" route on FSH with FRESH route UUID (NOT `F34E-FDD6-0700-22E8`); 11 embedded wpts; member WP UUIDs reused from existing FSH-side Popa group members (i.e. they match `244E-8E10-0800-400A` group members, not fresh).

---

### Test 21 -- Multi-select WPs, Paste to FSH

Uses [IsolatedWP1] + [IsolatedWP3] from DB. Pre-cleanup: ensure neither is on FSH (test 16b cleared my_waypoints).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.21" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae,994e0f7ef900baa4&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** log shows `_doCopy: database 2 item(s)`; both `CE4E-4318-1F01-B3AE` and `994E-0F7E-F900-BAA4` on `/api/fsh` waypoints with UUIDs preserved.

---

### Test 22 -- Route point Paste Before/After on FSH

Identify the fresh-UUID Popa route from test 20.

```powershell
$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$FSH_RT_FRESH = ($f.routes.PSObject.Properties | Where-Object { $_.Value.name -eq "Popa" -and $_.Name -ne "F34E-FDD6-0700-22E8" } | Select-Object -First 1).Name
$rt = $f.routes.$FSH_RT_FRESH
$RP1 = $rt.wpts[0].uuid
$RP3 = $rt.wpts[2].uuid

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.22" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=rp:${FSH_RT_FRESH}:${RP1}&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=rp:${FSH_RT_FRESH}:${RP3}&right_click=rp:${FSH_RT_FRESH}:${RP3}&cmd=10212" | Out-Null
Start-Sleep 2
```

**Pass:** route's wpts count increases by 1; PASTE BEFORE STARTED/FINISHED; the RP1 wp_uuid now appears between the position previously occupied by RP3 and its predecessor.

---

### Test 23 -- Cut FSH Track, Paste to DB (UUID preserved)

Uses [FSH_TestTrack] = `A24E-672E-FE06-0A80` (Track2-006). Note: test 4 added a 124th track (the DB-imported 1A4E-ED92...), but tests 17a/17b/etc shouldn't have consumed tracks. Track headers haven't been touched yet.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.23" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=A24E-672E-FE06-0A80&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/nmdb` tracks contains `a24e672efe060a80` (FSH UUID converted to DB form); FSH `A24E-672E-FE06-0A80` absent from `/api/fsh`; no ERROR.

---

### Test 24 -- Copy FSH Track, Paste New to DB (fresh navMate UUID)

Uses [FSH_TestTrack2] -- pick a different track. Use `7F4E-B4C6-9607-CF02` ("BOCAS2-010").

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.24" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=7F4E-B4C6-9607-CF02&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
Start-Sleep 2
```

**Pass:** new track in `/api/nmdb` tracks with FRESH navMate UUID (NOT `7f4eb4c69607cf02`); FSH-side `7F4E-B4C6-9607-CF02` still present.

---

### Test 25 -- Delete FSH Track (specific node)

Use `634E-295C-1E07-D5F0` (SANBLAS3-002).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.25" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=634E-295C-1E07-D5F0&right_click=634E-295C-1E07-D5F0&cmd=10225" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/fsh` tracks does NOT contain `634E-295C-1E07-D5F0`; DELETE TRACK STARTED/FINISHED; no ERROR.

---

### Test 26 -- Delete via FSH Tracks header

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.26" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Atracks&right_click=header%3Atracks&cmd=10225" | Out-Null
Start-Sleep 5
```

**Pass:** `/api/fsh` tracks is empty `{}`; DELETE TRACK STARTED/FINISHED; no ERROR.

---

### Test 28 -- Lossy-transform pre-flight (db_to_fsh long-name warning)

Setup: find or create a DB WP whose name length > 15 chars. Find a candidate via `/api/nmdb`.

```powershell
$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$long = $nmdb.waypoints | Where-Object { $_.name.Length -gt 15 } | Select-Object -First 1
if (-not $long) { Write-Host "NOT_RUN: no DB WP with name > 15 chars"; return }
$LongWP = $long.uuid
Write-Host "LongWP $LongWP name='$($long.name)' length=$($long.name.Length)"

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.28" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$LongWP&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `WARNING:` line in log naming the truncation (e.g. `WARNING: navOps: name truncated for FSH ...` or analogous); PASTE proceeds to completion (lossy-transform is a warning, not a block); FSH-side WP has name truncated to 15 chars.

---

### Test 30a -- Upload IsolatedWP1 to FSH (setup for 30b)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.30a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `CE4E-4318-1F01-B3AE` (BOCAS1) on FSH.

---

### Test 31 -- UUID conflict clean-create path

Pre-cleanup: delete any pre-existing BOCAS2 records on FSH (test 18 may have left a fresh-UUID BOCAS2) so the paste-with-preserved-UUID lands without name collision.

```powershell
# Pre-cleanup: delete any FSH-side BOCAS2 records
$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$bocas2s = @($f.waypoints.PSObject.Properties | Where-Object { $_.Value.name -eq "BOCAS2" })
foreach ($b in $bocas2s) {
    curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.31+precleanup" | Out-Null
    curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=$($b.Name)&right_click=$($b.Name)&cmd=10220" | Out-Null
    Start-Sleep 1
}

# Actual test
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.31" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=af4e23246d01bfa8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `AF4E-2324-6D01-BFA8` (BOCAS2) on FSH with UUID preserved; no conflict-resolution dialog text in log (clean-create path -- no UUID conflict because BOCAS2's FSH UUID didn't exist on FSH yet).

---

### Test 32a -- Ensure IsolatedWP1 on FSH (precondition for 32b/c)

Asserts that `CE4E-4318-1F01-B3AE` is on FSH. If already present (e.g., from a prior test), PASS. If absent, paste it; PASS if the paste lands, FAIL if it doesn't.

```powershell
$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
if (-not ($f.waypoints.PSObject.Properties.Name -contains "CE4E-4318-1F01-B3AE"))
{
    curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.32a" | Out-Null
    curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
    Start-Sleep 1
    curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
    Start-Sleep 2
    $f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
}
```

**Pass:** `CE4E-4318-1F01-B3AE` on FSH after the step, regardless of whether the paste was needed or skipped. **Fail:** WP still absent (paste failed).

---

## Guard Tests

### Test G1 -- Delete FSH Group+WPS blocked (members in route) [was fsh.12]

Uses [FSH_GroupInRoute] = Timiteo `C482-CBA0-D14E-67B2` (6 members, all in Timiteo route).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G1" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=C482-CBA0-D14E-67B2&right_click=C482-CBA0-D14E-67B2&cmd=10222" | Out-Null
Start-Sleep 2
```

**Pass:** `ERROR - Cannot delete FSH group 'Timiteo' and its waypoints: one or more members are referenced by routes. Use Delete Group to dissolve without deleting members, or remove from routes first.`; no IMPL ERROR; Timiteo group + 6 members + Timiteo route still in `/api/fsh`.

---

### Test G2 -- DB-cut to FSH destination blocked [was fsh.27]

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G2" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `ERROR - Cannot paste a database Cut to FSH` (or analogous sentinel); `/api/nmdb` waypoint `ce4e43181f01b3ae` still has its original `collection_uuid` (cut clipboard not consumed).

---

### Test G3 -- Intra-clipboard name collision [was fsh.29]

Find two DB WPs with the same name.

```powershell
$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$dups = $nmdb.waypoints | Group-Object name | Where-Object { $_.Count -ge 2 } | Select-Object -First 1
$WP_A = $dups.Group[0].uuid
$WP_B = $dups.Group[1].uuid

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G3" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$WP_A,$WP_B&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10211" | Out-Null
Start-Sleep 2
```

**Pass:** ERROR sentinel `FSH operation blocked: N name collision(s):` with an `intra-clipboard waypoint name '<name>'` entry naming the colliding source items, followed by `Per policy, navMate does not auto-rename.  Resolve in the database and retry.`; no IMPL ERROR; no WP named `<name>` lands on FSH.

---

### Test G4 -- FSH-wide name collision [was fsh.30b]

Precondition: a second BOCAS1 must exist in DB with UUID != `ce4e43181f01b3ae`. The fixture DB has only one BOCAS1, so the precondition is established by PASTE_NEW of [IsolatedWP1] into [DST] (mints a fresh-UUID BOCAS1 in DB). If the precondition already holds (a prior test created a second BOCAS1), no setup is needed.

```powershell
# Ensure a second BOCAS1 exists in DB (precondition)
$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$second = $nmdb.waypoints | Where-Object { $_.name -eq "BOCAS1" -and $_.uuid -ne "ce4e43181f01b3ae" } | Select-Object -First 1
if (-not $second)
{
    curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G4+precond" | Out-Null
    curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
    Start-Sleep 1
    curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
    Start-Sleep 2
    $nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
    $second = $nmdb.waypoints | Where-Object { $_.name -eq "BOCAS1" -and $_.uuid -ne "ce4e43181f01b3ae" } | Select-Object -First 1
    if (-not $second) { Write-Host "fsh.30b FAIL: could not establish precondition (no second BOCAS1)"; return }
}
$SameNameWP = $second.uuid

# Actual test: paste the second BOCAS1 to FSH; expect name-collision sentinel
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G4" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$SameNameWP&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** ERROR sentinel `FSH operation blocked: 1 name collision(s):` with a `waypoint 'BOCAS1' (from waypoint 'BOCAS1') already on FSH at UUID <existing>` entry, followed by `Per policy, navMate does not auto-rename.  Resolve in the database and retry.`; no IMPL ERROR; only one BOCAS1 on FSH (`CE4E-4318-1F01-B3AE`, the original from fsh.30a). **Fail:** precondition could not be established, OR the sentinel did not fire, OR a second BOCAS1 landed on FSH.

---

### Test G5 -- PASTE at FSH WP object node blocked [was fsh.32b]

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G5" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=CE4E-4318-1F01-B3AE&right_click=CE4E-4318-1F01-B3AE&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: paste at FSH destination type 'waypoint' not supported` (D4 positive-list rejection); FSH unchanged.

---

### Test G6 -- PASTE_NEW at FSH WP object node blocked [was fsh.32c]

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G6" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=CE4E-4318-1F01-B3AE&right_click=CE4E-4318-1F01-B3AE&cmd=10211" | Out-Null
Start-Sleep 2
```

**Pass:** same D4 IMPL ERROR sentinel; FSH unchanged.

---

### Test G7 -- D6: WP paste at FSH routes header blocked [was fsh.33]

D6 (spoke content-vs-destination) rejects waypoint clipboard items at the FSH routes header -- only route items are accepted at `header:routes`.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G7" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: Cannot paste waypoint clipboard item at fsh 'header:routes' destination`; FSH unchanged.

---

### Test G8 -- D6: Group paste at FSH my_waypoints blocked [was fsh.34]

D6 rejects group clipboard items at the FSH my_waypoints pseudo-group -- only waypoint items are accepted there. Spokes do not support nested groups.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G8" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: Cannot paste group clipboard item at fsh 'my_waypoints' destination`; FSH unchanged.

---

### Test G9 -- D6: Route paste at FSH groups header blocked [was fsh.35]

D6 rejects route clipboard items at the FSH groups header -- only group items are accepted at `header:groups`.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G9" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: Cannot paste route clipboard item at fsh 'header:groups' destination`; FSH unchanged.

---

### Test G10 -- D6: Group paste at FSH named-group node blocked [was fsh.36]

D6 rejects group clipboard items at a named-group destination -- only waypoint items are accepted at a group node. Spokes do not support nested groups.

Uses DB Popa group (`244e8e100800400a`) as the clipboard group and [FSH_GroupInRoute] = `C482-CBA0-D14E-67B2` (Timiteo group, fixture-present) as the destination node.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G10" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=C482-CBA0-D14E-67B2&right_click=C482-CBA0-D14E-67B2&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: Cannot paste group clipboard item at fsh 'group' destination`; FSH unchanged.

---

### Test G11 -- Intra-batch post-truncation WP collision on FSH destination [was fsh.37]

Parallels e80.36 -- the same post-truncation comparison in `_collectNameConflicts` runs for `panel='fsh'` destinations (FSH shares the 15-char name limit with E80 per `fsh_name_comment_limits`).  Two DB WPs `BajaCalifornia~1` (`7b4e6d421403dc72`) and `BajaCalifornia~2` (`044e7e7017030a9e`) have distinct full names but both truncate to `BajaCalifornia~` (15 chars).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G11" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=7b4e6d421403dc72&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=044e7e7017030a9e&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** preflight aborts with collision sentinel mentioning the post-truncation form `BajaCalifornia~`; FSH waypoints count unchanged; NO write to in-memory `$navFSH::fsh_db`.

---

End of fsh module tests.
