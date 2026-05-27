# tracks Module -- Runbook

Execution-layer steps for the tracks module.  For shared toolbox see [`../master_runbook.md`](../master_runbook.md); for module scope and test inventory see [`plan.md`](plan.md); for UUID lookup see [`../uuid_index.md`](../uuid_index.md).

---

## Baseline Setup + Pre-Check

```powershell
git -C C:/dat/Rhapsody checkout -- navMate.db
curl.exe -s "http://localhost:9883/api/test?op=refresh" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+tracks+module+reset" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=clear_e80" | Out-Null
Start-Sleep 5
curl.exe -s "http://localhost:9883/api/test?op=load_fsh&path=C:/base/apps/raymarine/apps/navMate/test/_fixtures/test.fsh" | Out-Null
Start-Sleep 2

# teensyBoat pre-check
$tb = try { curl.exe -s "http://localhost:9881/api/command?cmd=SIM" | ConvertFrom-Json } catch { $null }
if (-not ($tb -and $tb.ok)) {
    "teensyBoat NOT available -- module records as NOT_RUN (teensyBoat unavailable)"
    return
}
"teensyBoat is running -- proceed"
```

If teensyBoat is unavailable, mark all tracks tests `NOT_RUN (teensyBoat unavailable)` and stop the module.

---

## Positive Tests

### Test 1 -- Create test track on E80 (E80Track)

Configure the simulator and start recording:

```powershell
curl.exe -s "http://localhost:9881/api/command?cmd=AP%3D0" | Out-Null   # autopilot off
Start-Sleep 1
curl.exe -s "http://localhost:9881/api/command?cmd=H%3D90" | Out-Null   # heading East
Start-Sleep 1
curl.exe -s "http://localhost:9881/api/command?cmd=S%3D50" | Out-Null   # 50 knots
Start-Sleep 2

# Verify motion (look for non-zero sog in SIM output)
$seq = (curl.exe -s "http://localhost:9881/api/log?tail=1" | ConvertFrom-Json).seq
curl.exe -s "http://localhost:9881/api/command?cmd=SIM" | Out-Null
Start-Sleep 2
curl.exe -s "http://localhost:9881/api/log?since=$seq" | ConvertFrom-Json |
    Select-Object -Expand lines | Where-Object { $_.text -match "^SIM" } | ForEach-Object { $_.text }

# Mark log and start recording
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.1+E80Track+record" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=t+start"
```

Drive a 3-leg triangle (~30s total) as a background task:

```bash
# Run via Bash run_in_background
echo "L1-start" && sleep 10 && curl.exe -s "http://localhost:9881/api/command?cmd=H%3D210" > /dev/null && \
echo "L2-start" && sleep 10 && curl.exe -s "http://localhost:9881/api/command?cmd=H%3D330" > /dev/null && \
echo "L3-start" && sleep 10 && echo "ALL_LEGS_DONE"
```

Wait for `ALL_LEGS_DONE` in the background output, then stop / name / save:

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=t+stop"
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/command?cmd=t+name+E80Track"
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/command?cmd=t+save"
Start-Sleep 4

# Verify save: look for "got track(<uuid>) = 'E80Track'" in log
curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json |
    Select-Object -Expand lines | Where-Object { $_.text -match "got track" } | ForEach-Object { $_.text }

# Park simulator
curl.exe -s "http://localhost:9881/api/command?cmd=S%3D0"
```

**NEVER use `STOP`** -- that halts the simulator entirely; `S=0` (URL-encoded `S%3D0`) zeroes speed only.

Note `[E80_TK]` from `/api/db` tracks (the only track present after save).

**Pass:** `/api/db` tracks contains exactly 1 track named "E80Track"; its UUID has byte 1 = `B2` (E80-assigned).  Track-record protocol warnings are documented known-quiet (see `../master_runbook.md`).

---

### Test 2 -- Copy E80 track, Paste to DB

```powershell
$E80_TK = "<from-tracks.1>"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.2" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TK&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 5
```

**Pass:** E80Track appears in `/api/nmdb` tracks with UUID = `$E80_TK` (preserved); E80Track still on E80; PASTE STARTED/FINISHED.

---

### Test 3 -- Copy E80 track, Paste New to DB (fresh UUID)

```powershell
$E80_TK = "<from-tracks.1>"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.3" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TK&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
Start-Sleep 5
```

**Pass:** new E80Track record in `/api/nmdb` tracks with a fresh navMate UUID (byte 1 = `0x4e`, NOT `$E80_TK`); E80Track still on E80 (COPY not CUT); DB now has 2 records for the recorded track.

---

### Test 4 -- Cut E80 track, Paste to DB

```powershell
$E80_TK = "<from-tracks.1>"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.4" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TK&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 6
```

**Pass:** E80Track absent from `/api/db` (E80-side erased); `/api/nmdb` tracks row at UUID = `$E80_TK` updated in place (same-UUID PASTE hits in-place-update); log shows `queueTRACKCommand(...) extra(erase)` line.  End state: E80 empty, DB has 2 records.

---

### Test 5 -- PASTE single DB track -> E80 tracks header

Uses `[DB_TRACK_SHORT] = 8a4e3c4a2201fac2` ("BOCAS1-001", 77 pts, palette-snap color).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.5" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=8a4e3c4a2201fac2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 8

$tk = (curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).tracks
@($tk.PSObject.Properties).Count
$tk."8a4e3c4a2201fac2".name
```

**Pass:** `/api/db` tracks count = 1; the new E80 track's mta_uuid = `8a4e3c4a2201fac2`; name = "BOCAS1-001".  Log shows `SUCCESS: track written and SAVED ack received` from `d_TRACK_writer`, then `TRACK_CHANGED` event and `got track(8a4e3c4a2201fac2) = 'BOCAS1-001'`.  PASTE STARTED/FINISHED.

---

### Test 6 -- PASTE multi DB tracks -> E80 tracks header

Uses `[DB_TRACK_MULTI_A/B/C] = 8a4e3c4a2201fac2`, `664e93a624018e26`, `694e27fe26016702` ("BOCAS1-001/002/003", 77+74+55 pts).  Multi-select by chaining `cmd=10200` calls (the clipboard accumulates) -- the helper below picks up the three children of `[DB_TRACKS_BRANCH]`.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.6" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=8a4e3c4a2201fac2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=664e93a624018e26&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=694e27fe26016702&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 20

@((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).tracks.PSObject.Properties).Count
```

**Pass:** `/api/db` tracks count includes the 3 new BOCAS1-001/002/003 records (plus tracks.5's BOCAS1-001 if same -- in-place update on the dup uuid; net count may be 3 or 4 depending on tracks.5's state at this point).  All three have mta_uuid preserved from DB.  PASTE STARTED/FINISHED.

---

### Test 7 -- PASTE_NEW single DB track -> E80 (fresh navMate UUID)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.7" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=8a4e3c4a2201fac2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10211" | Out-Null
Start-Sleep 8
```

**Pass:** new E80 track present with FRESH navMate UUID (byte 1 = `0x4e`, NOT `8a4e3c4a2201fac2`); name = "BOCAS1-001"; DB unchanged.  PASTE_NEW STARTED/FINISHED.  Note: under suppressed UX, the PASTE_NEW confirmation dialog is auto-accepted.

---

### Test 8 -- PASTE_NEW multi DB tracks -> E80

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.8" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=8a4e3c4a2201fac2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=664e93a624018e26&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=694e27fe26016702&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10211" | Out-Null
Start-Sleep 20
```

**Pass:** three new tracks on E80 with FRESH navMate UUIDs (all byte 1 = `0x4e`); names = "BOCAS1-001", "BOCAS1-002", "BOCAS1-003"; DB unchanged.

---

### Test 9 -- PASTE single FSH track -> E80 (cross-spoke)

Uses `[FSH_TRACK_BOCAS1_003] = 0E4E-0BEA-B407-584A` ("BOCAS1-003", 74 pts, color=0).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.9" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=0E4E-0BEA-B407-584A&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 8
```

**Pass:** new E80 track with mta_uuid converted from FSH form `0E4E-0BEA-B407-584A` to navMate form `0e4e0beab407584a` (preserved through fshToNavUUID); name = "BOCAS1-003"; FSH state unchanged; log shows TRACK_CHANGED event and SAVED ack.

---

### Test 10 -- PUSH E80 track -> DB (exercises natural color drift)

PUSH from E80 syncs name/color from the live E80 state to the existing DB row.  No out-of-band modify step is needed: tracks.5's PASTE of `[DB_TRACK_SHORT]` (`BOCAS1-001`) introduced a real diff because the DB color (`ffff6666`, non-palette) was snapped to the nearest E80 palette index at the wire seam.  PUSH back to DB therefore lands a different color than the DB row originally held -- this is the diff the test exercises.

Setup uses the track from tracks.5 (same UUID `8a4e3c4a2201fac2` on both sides).

```powershell
# Capture DB color BEFORE push -- should be ffff6666 (the original, non-palette)
$db_before = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$row_before = $db_before.tracks | Where-Object { $_.uuid -eq '8a4e3c4a2201fac2' }
$color_before = $row_before.color

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.10" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=8a4e3c4a2201fac2&right_click=8a4e3c4a2201fac2&cmd=10250" | Out-Null
Start-Sleep 5

# Capture DB color AFTER push -- should be a palette ABGR (one of the 6 exact values), not ffff6666
$db_after = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$row_after = $db_after.tracks | Where-Object { $_.uuid -eq '8a4e3c4a2201fac2' }
Write-Host "DB color: before=$color_before after=$($row_after.color)"
```

**Pass:** PUSH STARTED/FINISHED; DB row's `color` field changed from `ffff6666` to a palette-exact ABGR (one of `ff0000ff`, `ff00ff00`, `ffff0000`, `ff00ffff`, `ffff00ff`, `ff000000`); name unchanged ("BOCAS1-001" was already <= 15 chars); `modified_ts` updated.  Points NOT touched (immutable on E80).  Confirms the wire path runs AND that the diff actually syncs.

---

### Test 11 -- Multi-COPY from E80 -> PASTE to DB

```powershell
# Pick three E80 tracks to copy (e.g. tracks.6 / tracks.8 outputs)
$E80_TR1 = "<uuid from /api/db tracks>"
$E80_TR2 = "<uuid from /api/db tracks>"
$E80_TR3 = "<uuid from /api/db tracks>"

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.11" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TR1&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TR2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TR3&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 10
```

**Pass:** `/api/nmdb` tracks now contains rows at all three E80 UUIDs (preserved through PASTE); E80 unchanged; PASTE STARTED/FINISHED.

---

### Test 12 -- Multi-CUT from E80 -> PASTE to DB

```powershell
# Pick the remaining E80 tracks
$E80_TR1 = "<uuid>"
$E80_TR2 = "<uuid>"

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.12" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TR1&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TR2&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 10
```

**Pass:** E80 tracks count decreased by 2 (the cut tracks removed); DB rows at those UUIDs updated in place (in-place-update from PASTE on existing UUIDs); CUT/PASTE STARTED/FINISHED.

---

### Test 13 -- DELETE via E80 Tracks header

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.13" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10225" | Out-Null
Start-Sleep 8
```

**Pass:** `/api/db` tracks empty; DELETE TRACK STARTED/FINISHED; ProgressDialog auto-FINISHED.  See `clear_e80_progress_hang` open-bug memo if dialog hangs at 0/N.

---

---

## Guard Tests

### Test G1 -- PASTE track at non-tracks-header E80 destination

```powershell
# Setup: ensure at least one DB track is selected; ensure E80 has at least one
# non-tracks header to target (groups-header is universal).
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.G1" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=8a4e3c4a2201fac2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** the paste is rejected at preflight with a sentinel naming the D6 spoke content-vs-destination rule (track items only accepted at the E80 tracks header).  `/api/db` tracks count unchanged.  NO ProgressDialog (predicate fires pre-write).

---

### Test G2 -- Lossy-warn (name truncation + color drift) on track paste

Uses `[DB_TRACK_LONG_NONPALETTE] = 824e8a104b04c37c` ("2006-01-11-SanDiego2DanaPoint", 31 chars, 231 pts, color=`ffffff00` non-palette).

Under `suppress=1`, the lossy-warn dialog is auto-accepted.  This test verifies:
- The dialog fires with both `N item(s) will have names truncated to 15 characters` and `M item(s) have colors that cannot round-trip to the destination and will be approximated` lines.
- On accept (auto), `_truncForE80` truncates the name to "2006-01-11-Sand" at the wire seam.
- `abgrToE80Index(ffffff00)` snaps to the nearest palette index (likely 1=yellow).
- The track lands on E80 with the truncated name and the snapped color.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.G2" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=824e8a104b04c37c&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 15

# Log should show both lossy-warn lines
curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json |
    Select-Object -Expand lines |
    Where-Object { $_.text -match "truncated|cannot round-trip|approximated" } |
    ForEach-Object { $_.text }
```

**Pass:** log contains BOTH the `truncated_names` line and the `color_mismatch` line of `lossyTransformWarning`; lossy-warn dialog auto-accepts under suppress=1; track lands on E80 with name "2006-01-11-Sand" (15 chars); E80 track color is a palette index 0..5; PASTE STARTED/FINISHED.  If only one of the two lossy lines fires, that's a regression in `_preflightLossyTransform`.

---

End of tracks module tests.
