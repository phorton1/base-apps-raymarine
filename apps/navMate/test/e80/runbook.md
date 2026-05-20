# e80 Module -- Runbook

Execution-layer steps for the e80 module. For shared toolbox, helpers, and conventions, see [`../master_runbook.md`](../master_runbook.md). For module scope and test inventory, see [`plan.md`](plan.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md).

---

## Baseline Setup

Run before any test. Skip if the orchestrator (`../full_cycle_runbook.md`) just performed the same setup.

```powershell
git -C C:/dat/Rhapsody checkout -- navMate.db
curl.exe -s "http://localhost:9883/api/test?op=refresh" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+e80+module+reset" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=clear_e80" | Out-Null
Start-Sleep 5
# Verify /api/db empty: waypoints=0, groups=0, routes=0, tracks=0
```

After every E80 step verify ProgressDialog FINISHED in the log; see `../master_runbook.md` for the pattern.

---

## Module Tests

### Test 1 -- Paste WP to E80 (UUID-preserving)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.1" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 6
```

**Pass:** `/api/db` waypoints contains `ce4e43181f01b3ae` named "BOCAS1"; ProgressDialog 'Paste' STARTED + FINISHED in log; no `WARNING: enquing mod` in unexpected place (the one that appears IS expected here, known-quiet for E80 ops). Record `[E80_WP] = ce4e43181f01b3ae`.

---

### Test 2 -- Paste Group to E80 (UUID-preserving)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.2" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 10
```

**Pass:** `/api/db` groups contains `244e8e100800400a` named "Popa" with `num_uuids=11`. All 11 member WPs present in `/api/db` waypoints with their DB UUIDs preserved. Record `[E80_GR] = 244e8e100800400a`.

---

### Test 3 -- Paste Route to E80 (UUID-preserving)

Member WPs must already be on E80 (Test 2 put them there; SS10.10 pre-flight verifies).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.3" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10210" | Out-Null
Start-Sleep 6
```

**Pass:** `/api/db` routes contains `f34efdd6070022e8` named "Popa" with `num_wpts=11` (or `12` if `db` module ran first and left the db Test 15a duplicate Popa0 in place; this module starts from a reset so `11` is expected). Record `[E80_RT] = f34efdd6070022e8`.

---

### Test 4 -- Copy E80 WP, Push to DB

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.4" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10250" | Out-Null
Start-Sleep 3
```

**Pass:** [IsolatedWP1] DB record's `collection_uuid` still = `2b4e3308ca00cf66` (push does NOT change collection); PUSH STARTED/FINISHED; no errors.

---

### Test 5 -- Copy E80 WP, Paste New to DB (fresh UUID)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.5" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
Start-Sleep 3
```

**Pass:** new "BOCAS1" record in [DST] with fresh navMate UUID (NOT `ce4e43181f01b3ae`). PASTE NEW STARTED/FINISHED.

---

### Test 6 -- Delete E80 WP (specific node)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.6" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=ce4e43181f01b3ae&right_click=ce4e43181f01b3ae&cmd=10220" | Out-Null
Start-Sleep 5
```

**Pass:** `/api/db` waypoints no longer contains `ce4e43181f01b3ae`. DELETE WAYPOINT STARTED/FINISHED. No ProgressDialog expected for single-WP delete (fast operation, see master_runbook ProgressDialog Pattern).

---

### Test 6b -- Delete E80 Group+WPS blocked (member in route)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.6b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=244e8e100800400a&right_click=244e8e100800400a&cmd=10222" | Out-Null
Start-Sleep 3
```

**Pass:** `ERROR - Cannot delete group 'Popa' and its waypoints: one or more members are used in a route.`; no IMPL ERROR; no ProgressDialog STARTED; group + 11 members + route still in `/api/db`.

---

### Test 7 -- Delete via E80 Routes header

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.7" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10223" | Out-Null
Start-Sleep 8
```

**Pass:** `/api/db` routes empty; group + 11 member WPs preserved. ProgressDialog 'Delete Route' STARTED + FINISHED.

---

### Test 8 -- Delete via E80 Groups header

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.8" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10222" | Out-Null
Start-Sleep 10
```

**Pass:** `/api/db` groups empty; all member WPs deleted. ProgressDialog 'Delete Groups + Waypoints' STARTED + FINISHED.

---

### Test 9a -- Re-upload Popa group

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.9a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 10
```

**Pass:** Popa group + 11 members present on E80.

---

### Test 9b -- Delete E80 Group + members via specific group node

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.9b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=244e8e100800400a&right_click=244e8e100800400a&cmd=10222" | Out-Null
Start-Sleep 8
```

**Pass:** group `244e8e100800400a` absent from `/api/db`; all 11 members absent. ProgressDialog FINISHED.

---

### Test 10a -- Ensure at least one ungrouped WP on E80 (precondition for 10b)

If [IsolatedWP1] is already on E80, the precondition holds and this is a PASS without firing anything. If absent, upload it and confirm it landed.

```powershell
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$present = $db.waypoints.PSObject.Properties | Where-Object { $_.Name -eq 'ce4e43181f01b3ae' }
if (-not $present)
{
    curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.10a" | Out-Null
    curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
    Start-Sleep 1
    curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
    Start-Sleep 5
}
```

**Pass:** at least one ungrouped WP on E80 after this step, whether by upload or already present. **Fail:** still no ungrouped WP.

---

### Test 10b -- Delete via E80 My Waypoints (all ungrouped)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.10b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=my_waypoints&right_click=my_waypoints&cmd=10222" | Out-Null
Start-Sleep 5
```

**Pass:** all ungrouped WPs deleted; named groups (none currently) unaffected.

---

### Test 11a -- Re-upload Popa group

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.11a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 10
```

**Pass:** Popa group + 11 members on E80.

---

### Test 11b -- Copy E80 Group, Push to DB

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.11b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=244e8e100800400a&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10250" | Out-Null
Start-Sleep 5
```

**Pass:** Popa group name + 11 member WPs updated in DB. `collection_uuid` of Popa group unchanged (push does NOT move records). PUSH STARTED/FINISHED.

---

### Test 12a -- Re-upload TestRoute (if absent)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.12a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10210" | Out-Null
Start-Sleep 6
```

**Pass:** [TestRoute] on E80.

---

### Test 12b -- Copy E80 Route, Push to DB

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.12b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10250" | Out-Null
Start-Sleep 5
```

**Pass:** [TestRoute] name + route_waypoints updated in DB. Member WP UUIDs preserved; no new WP records. PUSH STARTED/FINISHED.

---

### Test 13 -- Multi-select Group + Route, Push to DB

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.13" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=244e8e100800400a,f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10250" | Out-Null
Start-Sleep 5
```

**Pass:** log shows `_doCopy: e80 2 item(s)`; both UUIDs preserved; PUSH STARTED/FINISHED; no errors.

---

### Test 14 -- Paste New WP to E80 (fresh UUID)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.14" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=af4e23246d01bfa8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 5
```

**Pass:** new "BOCAS2" on E80 with fresh navMate UUID (NOT `af4e23246d01bfa8`). Note `[E80_FRESH_WP]` = the new UUID from `/api/db`.

---

### Test 14b -- Copy E80 fresh-UUID WP, Paste to DB

```powershell
# Substitute the actual [E80_FRESH_WP] UUID from Test 14 below
$E80_FRESH_WP = "<fresh-uuid-from-Test-14>"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.14b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_FRESH_WP&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 4
```

**Pass:** new "BOCAS2" record in [DST] with UUID = `[E80_FRESH_WP]` (preserved into DB). PASTE STARTED/FINISHED.

---

### Test 14c -- Mixed-classified E80 clipboard, PASTE_NEW

Setup: PASTE_NEW [IsolatedWP1] from DB to E80 to create a second fresh-UUID WP (paste-classified -- UUID not in DB).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.14c+setup" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 5
# Identify [E80_FRESH_WP2] = the BOCAS1 fresh-UUID from /api/db (not ce4e43181f01b3ae)
```

Now COPY both:
- `[E80_FRESH_WP]` (push-classified -- in DB after Test 14b)
- `[E80_FRESH_WP2]` (paste-classified -- NOT in DB)

```powershell
$E80_FRESH_WP  = "<from-Test-14>"
$E80_FRESH_WP2 = "<from-Test-14c-setup>"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.14c" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_FRESH_WP,$E80_FRESH_WP2&cmd=10200" | Out-Null
Start-Sleep 2
# PASTE_NEW is the only collection option for mixed clipboard
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.14c+paste" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
Start-Sleep 4
```

**Pass:** COPY logs `_doCopy: e80 2 item(s)`; PASTE NEW STARTED/FINISHED; no IMPL ERROR; two new BOCAS1/BOCAS2 records with fresh UUIDs land in [DST].

---

### Test 15 -- Paste New Group to E80 (all-fresh UUIDs)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.15" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eaf5a8c00e922&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 10
```

**Pass:** new "Timiteo" group on E80 with fresh UUID (NOT `1a4eaf5a8c00e922`); 6 members each with fresh UUIDs.

---

### Test 16a -- Ensure E80 routes empty (precondition for 16b's fresh-UUID paste)

If `/api/db` routes is already empty, the precondition holds and this is a PASS without firing anything. Otherwise delete-all-routes and confirm.

```powershell
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$count = @($db.routes.PSObject.Properties).Count
if ($count -gt 0)
{
    curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.16a" | Out-Null
    curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10223" | Out-Null
    Start-Sleep 6
}
```

**Pass:** `/api/db` routes empty after this step, whether by delete-all or already empty. **Fail:** routes still present.

---

### Test 16b -- Paste New Route to E80

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.16b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10211" | Out-Null
Start-Sleep 10
```

**Pass:** new "Popa" route on E80 with fresh UUID (NOT `f34efdd6070022e8`); member WPs referenced by their existing UUIDs (no new WP records). Note `[E80_RT_FRESH]` = the new route's UUID.

---

### Test 17 -- Multi-select WPs, Paste to E80

Pre-cleanup: delete any fresh-UUID BOCAS1/BOCAS2 left on E80 from Tests 14 / 14c.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.17+pre-cleanup" | Out-Null
# For each fresh-UUID BOCAS1/BOCAS2 in /api/db waypoints, fire DELETE_WAYPOINT:
# curl ".../api/test?panel=e80&select=<fresh-uuid>&right_click=<fresh-uuid>&cmd=10220"
# (wait between each)
```

Then:

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.17" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae,af4e23246d01bfa8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 6
```

**Pass:** log shows `_doCopy: database 2 item(s)`; both [IsolatedWP1] and [IsolatedWP2] on E80 with their DB UUIDs preserved.

---

### Test 18 -- Route point Paste Before/After on E80

Requires the fresh-UUID route from Test 16b. Identify it by querying `/api/db` routes for a "Popa" route not equal to `f34efdd6070022e8`.

Known shape: the fresh route inherits the 12-WP sequence with Popa0 duplicated (if db module ran earlier; from a clean e80-module-only run the route has 11 WPs, no duplicate). The test assumes intra-cycle independence -- when this module runs alone, the route is 11 WPs without duplicate, and Popa0 / Popa2 / Popa3 are each unique.

Use these stable IDs (Popa1, Popa2, Popa3 unique in either case):

- `[E80_RP1]` = `454e11a80b002884` (Popa2)
- `[E80_RP2]` = `8d4e68fa0a0073ee` (Popa1)
- `[E80_RP3]` = `384e30760c00e63e` (Popa3)

```powershell
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$E80_RT_FRESH = ($db.routes.PSObject.Properties | Where-Object { $_.Value.name -match "Popa" -and $_.Name -ne "f34efdd6070022e8" }).Name
$E80_RP1 = "454e11a80b002884"
$E80_RP3 = "384e30760c00e63e"

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.18" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=rp:${E80_RT_FRESH}:${E80_RP1}&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=rp:${E80_RT_FRESH}:${E80_RP3}&right_click=rp:${E80_RT_FRESH}:${E80_RP3}&cmd=10212" | Out-Null
Start-Sleep 6
```

**Pass:** route's WP count increases by 1; [E80_RP1] inserted into the route at the position immediately before [E80_RP3]. ProgressDialog 'Paste Route Points' STARTED + FINISHED.

---

### Test 19 -- DB-cut to E80 destination blocked

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.19" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** `ERROR - Cannot paste a database Cut to E80`; [IsolatedWP1] still in DB at its original `collection_uuid` (cut clipboard not consumed).

---

### Test 20a -- Delete BOCAS1 from E80 if present

```powershell
# Check /api/db for ce4e43181f01b3ae; if absent, NOT_RUN
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.20a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=ce4e43181f01b3ae&right_click=ce4e43181f01b3ae&cmd=10220" | Out-Null
Start-Sleep 4
```

**Pass:** `ce4e43181f01b3ae` absent from `/api/db`. Skip / NOT_RUN if BOCAS1 not on E80.

---

### Test 20b -- Delete BOCAS2 from E80 if present

BOCAS2 on E80 may be `af4e23246d01bfa8` (if Test 17 pasted) or a fresh UUID. Find any BOCAS2-named WP and delete each.

```powershell
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$bocas2 = $db.waypoints.PSObject.Properties | Where-Object { $_.Value.name -eq "BOCAS2" }
foreach ($wp in $bocas2) {
    curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.20b" | Out-Null
    curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$($wp.Name)&right_click=$($wp.Name)&cmd=10220" | Out-Null
    Start-Sleep 3
}
```

**Pass:** no WP named "BOCAS2" remains on E80. Skip / NOT_RUN if none was present.

---

### Test 20c -- Paste to E80 tracks header blocked

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.20c" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** `ERROR - Cannot paste to E80 tracks header -- tracks are read-only`; E80 unchanged.

---

### Test 21a -- Delete all E80 routes (cleanup before Test 21d)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.21a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10223" | Out-Null
Start-Sleep 10
# HARD STOP: confirm ProgressDialog FINISHED before proceeding (see master_runbook ProgressDialog Pattern)
```

**Pass:** `/api/db` routes empty; ProgressDialog FINISHED.

---

### Test 21b -- Delete all E80 groups+WPS

Prerequisite: Test 21a's ProgressDialog confirmed FINISHED.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.21b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10222" | Out-Null
Start-Sleep 15
```

**Pass:** `/api/db` groups empty + all member WPs deleted; ProgressDialog FINISHED.

---

### Test 21c -- Delete all E80 ungrouped WPs (no-op path)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.21c" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=my_waypoints&right_click=my_waypoints&cmd=10222" | Out-Null
Start-Sleep 5
```

**Pass:** `/api/db` returns empty E80 (waypoints/groups/routes/tracks all 0). With 0 ungrouped WPs the `my_waypoints` node is still selectable; DELETE_GROUP_WPS dispatches, hits the empty-members guard, logs `WARNING: My Waypoints is empty.`, and returns cleanly under `suppress=1`. DELETE GROUP+WPS STARTED and FINISHED both present. No ProgressDialog. No modal. No IMPL ERROR. Counts as PASS.

---

### Test 21d -- Route-dependency pre-flight

Prerequisite: E80 is empty (verify before firing).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.21d" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** `ERROR - Route 'Popa': member waypoint(s) not on E80 and not in clipboard: <UUIDs>`; `/api/db` routes empty.

---

### Test 22 -- Ancestor-wins accept path

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.22" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eaf5a8c00e922,d44e40468d000d96&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 8
```

**Pass:** Timiteo group on E80 with fresh UUID + 6 member WPs (fresh UUIDs); t01 (`d44e40468d000d96`) NOT a separate ungrouped WP. Check membership via the GROUP's `uuids` array, not the WP record's nonexistent `group_uuid`.

---

### Test 23 -- Ancestor-wins reject path

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.23" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1&outcome=reject" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eaf5a8c00e922,d44e40468d000d96&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 4
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1&outcome=accept" | Out-Null
```

**Pass:** PASTE NEW (e80) STARTED then FINISHED immediately (no ProgressDialog between them); no ERROR or IMPL ERROR; E80 state unchanged from Test 22's end state.

---

### Test 24 -- Intra-clipboard name collision

Need two DB WPs with the same name. Find via `/api/nmdb` group-by-name (e.g. WPs named "10" -- multiple exist).

```powershell
$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$dups = $nmdb.waypoints | Group-Object name | Where-Object { $_.Count -ge 2 } | Select-Object -First 1
$WP_A = $dups.Group[0].uuid
$WP_B = $dups.Group[1].uuid

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.24" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$WP_A,$WP_B&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 4
```

**Pass:** `ERROR - Clipboard contains duplicate waypoint name '<name>' -- aborting`; no WP named `<name>` lands on E80.

---

### Test 25a -- Upload IsolatedWP1 to E80 (setup for Test 25b)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.25a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 5
```

**Pass:** [IsolatedWP1] on E80.

---

### Test 25b -- E80-wide name collision

Find any DB WP named "BOCAS1" with a UUID different from `ce4e43181f01b3ae`.

```powershell
$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$SameNameWP = ($nmdb.waypoints | Where-Object { $_.name -eq "BOCAS1" -and $_.uuid -ne "ce4e43181f01b3ae" } | Select-Object -First 1).uuid

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.25b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$SameNameWP&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 4
```

**Pass:** `ERROR - E80 already has a waypoint named 'BOCAS1' -- aborting`; only one "BOCAS1" on E80 (the original from Test 25a).

---

### Test 26 -- UUID conflict clean-create path

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.26" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=af4e23246d01bfa8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 5
```

**Pass:** [IsolatedWP2] on E80 with UUID `af4e23246d01bfa8` preserved; only standard Paste ProgressDialog (no conflict-resolution dialog) appears.

---

### Test 27 -- UUID conflict dialog path

**NOT_RUN (db_versioning)** -- requires DB versioning infrastructure that does not yet exist.

---

### Test 28a -- Ensure IsolatedWP1 on E80 (precondition for 28b/c)

If [IsolatedWP1] is already on E80, the precondition holds and this is a PASS without firing anything. If absent, upload it and confirm it landed.

```powershell
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$present = $db.waypoints.PSObject.Properties | Where-Object { $_.Name -eq 'ce4e43181f01b3ae' }
if (-not $present)
{
    curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.28a" | Out-Null
    curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
    Start-Sleep 1
    curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
    Start-Sleep 5
}
```

**Pass:** [IsolatedWP1] is on E80 after this step, whether the upload was needed or the WP was already present from a prior step. **Fail:** WP still absent (upload attempted but did not land).

---

### Test 28b -- PASTE at E80 WP object node blocked

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.28b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=ce4e43181f01b3ae&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=ce4e43181f01b3ae&right_click=ce4e43181f01b3ae&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** `ERROR - Cannot paste at an individual E80 waypoint node -- pick a header or group`; E80 unchanged. (Distinct guard at `navOps.pm` for WP-object-node paste, fires before the descendant check.)

---

### Test 28c -- PASTE_NEW at E80 WP object node blocked

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+e80.28c" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=ce4e43181f01b3ae&right_click=ce4e43181f01b3ae&cmd=10211" | Out-Null
Start-Sleep 3
```

**Pass:** same ERROR (same WP-object-node guard); E80 unchanged.

---

End of e80 module tests.
