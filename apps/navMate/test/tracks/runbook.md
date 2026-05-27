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

### Test 1 -- Create two test tracks on E80 (E80Track1, E80Track2)

Two separate recordings.  Each gets its own fresh E80 uuid -- the second exists to give tracks.4 a fresh uuid for the CUT+PASTE record-creating positive, since tracks.2/3 contaminate the first track's uuid in DB.

#### tracks.1a -- record E80Track1

```powershell
curl.exe -s "http://localhost:9881/api/command?cmd=AP%3D0" | Out-Null   # autopilot off
Start-Sleep 1
curl.exe -s "http://localhost:9881/api/command?cmd=H%3D90" | Out-Null   # heading East
Start-Sleep 1
curl.exe -s "http://localhost:9881/api/command?cmd=S%3D50" | Out-Null   # 50 knots
Start-Sleep 2

# Verify motion
$seq = (curl.exe -s "http://localhost:9881/api/log?tail=1" | ConvertFrom-Json).seq
curl.exe -s "http://localhost:9881/api/command?cmd=SIM" | Out-Null
Start-Sleep 2
curl.exe -s "http://localhost:9881/api/log?since=$seq" | ConvertFrom-Json |
    Select-Object -Expand lines | Where-Object { $_.text -match "^SIM" } | ForEach-Object { $_.text }

# Mark log and start recording the first track
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.1+E80Track1+record" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=t+start"
```

Drive a 3-leg triangle (~30s) as a background task, wait for `ALL_LEGS_DONE`:

```bash
echo "L1-start" && sleep 10 && curl.exe -s "http://localhost:9881/api/command?cmd=H%3D210" > /dev/null && \
echo "L2-start" && sleep 10 && curl.exe -s "http://localhost:9881/api/command?cmd=H%3D330" > /dev/null && \
echo "L3-start" && sleep 10 && echo "ALL_LEGS_DONE"
```

Then stop, name as E80Track1, save:

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=t+stop"
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/command?cmd=t+name+E80Track1"
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/command?cmd=t+save"
Start-Sleep 4
curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json |
    Select-Object -Expand lines | Where-Object { $_.text -match "got track" } | ForEach-Object { $_.text }
```

#### tracks.1b -- record E80Track2

Second recording, different geometry so the two tracks are distinguishable.  Each `t+save` produces a new E80 uuid; record both before any DB interaction so neither uuid is contaminated by paste.

```powershell
curl.exe -s "http://localhost:9881/api/command?cmd=H%3D45" | Out-Null     # heading NE
Start-Sleep 1
curl.exe -s "http://localhost:9881/api/command?cmd=S%3D50" | Out-Null
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.1+E80Track2+record" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=t+start"
```

Two-leg short triangle (~20s):

```bash
echo "L1-start" && sleep 10 && curl.exe -s "http://localhost:9881/api/command?cmd=H%3D225" > /dev/null && \
echo "L2-start" && sleep 10 && echo "ALL_LEGS_DONE"
```

Stop, name, save:

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=t+stop"
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/command?cmd=t+name+E80Track2"
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/command?cmd=t+save"
Start-Sleep 4

# Park simulator
curl.exe -s "http://localhost:9881/api/command?cmd=S%3D0"

# Capture both uuids
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$db.tracks.PSObject.Properties | ForEach-Object { "$($_.Name) -> $($_.Value.name)" }
```

**NEVER use `STOP`** -- that halts the simulator entirely; `S=0` (URL-encoded `S%3D0`) zeroes speed only.

Note `[E80_TK1]` and `[E80_TK2]` from `/api/db` tracks (the two tracks present after both saves).

**Pass:** `/api/db` tracks contains exactly 2 tracks named "E80Track1" and "E80Track2"; both UUIDs have byte 1 = `B2` (E80-assigned).  Track-record protocol warnings are documented known-quiet (see `../master_runbook.md`).

---

### Test 2 -- Copy E80Track1, Paste to DB

```powershell
$E80_TK1 = "<from-tracks.1a>"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.2" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TK1&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 5
```

**Pass:** E80Track1 appears in `/api/nmdb` tracks with UUID = `$E80_TK1` (preserved); E80Track1 still on E80; PASTE STARTED/FINISHED.

---

### Test 3 -- Copy E80Track1, Paste New to DB (fresh UUID)

```powershell
$E80_TK1 = "<from-tracks.1a>"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.3" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TK1&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
Start-Sleep 5
```

**Pass:** new E80Track1 record in `/api/nmdb` tracks with a fresh navMate UUID (byte 1 = `0x4e`, NOT `$E80_TK1`); E80Track1 still on E80 (COPY not CUT); DB now has 2 records for the recorded track.

---

### Test 4 -- Cut E80Track2, Paste to DB

Uses `[E80_TK2]` from tracks.1b -- a fresh E80 uuid that is NOT yet in the DB.  This isolates the CUT+PASTE record-creating positive from the uuid-collision case (where the source uuid is already in DB; see tracks.G3).

```powershell
$E80_TK2 = "<from-tracks.1b>"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.4" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TK2&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 6
```

**Pass:** E80Track2 absent from `/api/db` (E80-side erased by CUT); `/api/nmdb` tracks contains a new row at UUID = `$E80_TK2` named "E80Track2" (preserved E80 uuid; record creation); log shows `queueTRACKCommand(...) extra(erase)` for `$E80_TK2`.  PASTE STARTED/FINISHED.  End state: E80 still has E80Track1 (unchanged), DB has 3 rows total (E80Track1@`$E80_TK1`, E80Track1@fresh-navMate, E80Track2@`$E80_TK2`).

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

Uses `[DB_TRACK_MULTI_B/C] = 664e93a624018e26`, `694e27fe26016702` ("BOCAS1-002/003", 74+55 pts).  Two-track batch; `[DB_TRACK_MULTI_A]` (BOCAS1-001) is excluded because tracks.5 already pasted it to E80, and `_pasteAllToE80` rejects a batch that contains any uuid already present on E80 (with `use PASTE_NEW instead` sentinel).  Multi-select is a single call with comma-separated uuids (`navTest.pm` line 11 documents this form; chaining N single-select calls each REPLACES the prior selection, so only the last reaches PASTE -- that's a runbook bug, not a code bug).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.6" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=664e93a624018e26,694e27fe26016702&cmd=10200" | Out-Null
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 20

@((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).tracks.PSObject.Properties).Count
```

**Pass:** `/api/db` tracks now contains BOCAS1-002@`664e93a624018e26` and BOCAS1-003@`694e27fe26016702` alongside the BOCAS1-001@`8a4e3c4a2201fac2` from tracks.5 (E80 count goes 1 -> 3 plus E80Track1 from Section 1 = 4 total).  Both new tracks have mta_uuid preserved from DB.  PASTE STARTED/FINISHED + ProgressDialog STARTED/FINISHED.

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
curl.exe -s "http://localhost:9883/api/test?panel=database&select=8a4e3c4a2201fac2,664e93a624018e26,694e27fe26016702&cmd=10200" | Out-Null
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10211" | Out-Null
Start-Sleep 25
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

Source uuids: any three E80 uuids that are NOT yet in DB.  The uuid-collision preflight added 2026-05-29 rejects record-creating spoke->DB paste at an already-existing uuid (use PUSH for that), so this positive test must pick uncontaminated source uuids.  The fresh-navMate-uuid tracks from tracks.7/.8 fit (byte 1 = `4e` and DB has no row at those uuids).

```powershell
$nmdb_uuids = @{}
$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$nmdb_uuids[$_] = 1 foreach (@($nmdb.tracks | ForEach-Object { $_.uuid }))
$db    = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$fresh = @($db.tracks.PSObject.Properties | Where-Object { -not $nmdb_uuids[$_.Name] } | ForEach-Object { $_.Name })
"E80 uuids NOT in DB: $($fresh -join ', ')"
$picked = $fresh | Select-Object -First 3
"Picked: $($picked -join ', ')"

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.11" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$($picked -join ',')&cmd=10200" | Out-Null
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 15
```

**Pass:** `/api/nmdb` tracks now contains rows at all three picked uuids (preserved through PASTE); E80 unchanged (COPY not CUT); PASTE STARTED/FINISHED.  If `$fresh` has fewer than 3 elements at runtime, the test records NOT_RUN (state setup precondition unmet).

---

### Test 12 -- Multi-CUT from E80 -> PASTE to DB

Same uuid-collision constraint as tracks.11 -- pick E80 uuids that are NOT yet in DB.  After tracks.11 those fresh uuids ARE now in DB (tracks.11 pasted them), so this test re-derives the set fresh.

```powershell
$nmdb_uuids = @{}
$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$nmdb_uuids[$_] = 1 foreach (@($nmdb.tracks | ForEach-Object { $_.uuid }))
$db    = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$fresh = @($db.tracks.PSObject.Properties | Where-Object { -not $nmdb_uuids[$_.Name] } | ForEach-Object { $_.Name })
"E80 uuids NOT in DB: $($fresh -join ', ')"
$picked = $fresh | Select-Object -First 2
"Picked: $($picked -join ', ')"

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.12" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$($picked -join ',')&cmd=10201" | Out-Null
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 15
```

**Pass:** E80 tracks count decreased by 2 (the CUT items removed); `/api/nmdb` tracks contains new rows at the 2 picked uuids (record creation, preserved E80 uuid); CUT STARTED/FINISHED + PASTE STARTED/FINISHED; log shows `extra(erase)` for both picked uuids.  If `$fresh` has fewer than 2 elements at runtime, the test records NOT_RUN.

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

# Log should show both lossy-warn lines (emitted by lossyTransformWarning
# before the suppress short-circuit; the test-visible prefix is "lossyTransformWarning:").
curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json |
    Select-Object -Expand lines |
    Where-Object { $_.text -match "lossyTransformWarning:" } |
    ForEach-Object { $_.text }
```

**Pass:** log contains TWO `lossyTransformWarning:` lines -- one with `1 item(s) will have names truncated to 15 characters` and one with `1 item(s) have colors that cannot round-trip to the destination and will be approximated`; lossy-warn dialog auto-accepts under suppress=1; track lands on E80 with name "2006-01-11-Sand" (15 chars); E80 track color is a palette index 0..5; PASTE STARTED/FINISHED.  If only one of the two lossy lines fires, that's a regression in `_preflightLossyTransform`.

---

### Test G3 -- uuid-collision preflight on spoke -> DB record-creating paste

Verifies the 2026-05-29 preflight rule: PASTE of a clipboard item whose uuid already exists in the corresponding DB table is rejected with a sentinel naming the rule.  PASTE_NEW is the alternative (fresh-uuid record creation); PUSH is the alternative for "sync into existing-uuid DB row".  Tracks here; the same rule fires for waypoints/groups/routes.

Setup: ensure E80 has a track at a uuid that also exists in DB.  After tracks.5's PASTE, `8a4e3c4a2201fac2` is present on BOTH E80 and DB (preserved-uuid PASTE).  After tracks.13's DELETE TRACK at the tracks-header, E80 is empty; re-establish the shared uuid first.

```powershell
# Setup: PASTE BOCAS1-001 to E80 so the uuid lives on both sides.
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.G3+setup" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=8a4e3c4a2201fac2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 8

# Verify setup
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
"E80 has BOCAS1-001@8a4e3c4a2201fac2: $($db.tracks.'8a4e3c4a2201fac2'.name)"

# Now the actual guard: COPY from E80, PASTE to DB at the same uuid.
$nmdb_before = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$count_before = @($nmdb_before.tracks).Count

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.G3" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=8a4e3c4a2201fac2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 5

$nmdb_after = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$count_after = @($nmdb_after.tracks).Count
"nmdb tracks: before=$count_before after=$count_after"

# Log should show the preflight rejection sentinel
curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json |
    Select-Object -Expand lines |
    Where-Object { $_.text -match "Paste rejected|already exist in the database" } |
    ForEach-Object { $_.text }
```

**Pass:** log contains the preflight sentinel `Paste rejected: 1 item(s) already exist in the database at the same uuid.` (with the PUSH/PASTE_NEW guidance line); nmdb tracks count unchanged (no SQL INSERT attempted, so no `UNIQUE constraint failed: tracks.uuid` either); PASTE STARTED line present but FINISHED also present (the predicate returns early; no progress dialog opens for the data side).

---

End of tracks module tests.
