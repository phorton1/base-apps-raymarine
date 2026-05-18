# tracks Module -- Runbook

Execution-layer steps for the tracks module. For shared toolbox, see [`../master_runbook.md`](../master_runbook.md). For module scope and test inventory, see [`plan.md`](plan.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md).

---

## Baseline Setup + Pre-Check

```powershell
git -C C:/dat/Rhapsody checkout -- navMate.db
curl.exe -s "http://localhost:9883/api/test?op=refresh" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+tracks+module+reset" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=clear_e80" | Out-Null
Start-Sleep 5

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

## Module Tests

### Test 1 -- Create test tracks on E80 (Track1, Track2)

Configure the simulator and start recording Track1:

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
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.1+track1+record" | Out-Null
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
curl.exe -s "http://localhost:9883/api/command?cmd=t+name+Track1"
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/command?cmd=t+save"
Start-Sleep 4

# Verify save: look for "got track(<uuid>) = 'Track1'" in log
curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json |
    Select-Object -Expand lines | Where-Object { $_.text -match "got track" } | ForEach-Object { $_.text }
```

Repeat the full sequence for Track2 (new mark, new leg triangle, stop / name+Track2 / save). After both saves, park the simulator:

```powershell
curl.exe -s "http://localhost:9881/api/command?cmd=S%3D0"
```

**NEVER use `STOP`** -- that halts the simulator entirely; `S=0` (URL-encoded `S%3D0`) zeroes speed only.

Note `[E80_TK1]` and `[E80_TK2]` from `/api/db` tracks (in save order).

**Pass:** `/api/db` tracks contains exactly 2 tracks with names "Track1" and "Track2"; both UUIDs have byte 1 = `B2` (E80-assigned -- e.g. UUID `81b266af4000df98` has byte 1 = `b2`, i.e. characters at string positions 2-3 of the lowercase no-dash hex form; byte 0 is positions 0-1). The track-record protocol warnings are documented known-quiet (see `../master_runbook.md`).

---

### Test 2 -- Copy E80 Track, Paste to DB

```powershell
$E80_TK1 = "<from-Test-1>"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.2" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TK1&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 5
```

**Pass:** Track1 appears in `/api/nmdb` tracks with UUID = `$E80_TK1` (preserved); Track1 still on E80; PASTE STARTED/FINISHED.

---

### Test 3 -- Cut E80 Track, Paste to DB

```powershell
$E80_TK2 = "<from-Test-1>"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.3" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TK2&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 6
```

**Pass:** Track2 in `/api/nmdb` tracks with UUID = `$E80_TK2` (preserved); Track2 absent from `/api/db` (E80 erased); log shows `queueTRACKCommand(...) extra(erase)` line.

---

### Test 4 -- Paste Track to E80 blocked

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.4" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eed924904ebbe&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** `ERROR - Cannot paste to E80 tracks header -- tracks are read-only`; E80 tracks count unchanged from Test 3's end state (Track1 still present).

---

### Test 5 -- Paste New E80 Track to DB (fresh UUID)

```powershell
$E80_TK1 = "<from-Test-1>"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.5" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TK1&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
Start-Sleep 5
```

**Pass:** new Track1 record in `/api/nmdb` tracks with a fresh navMate UUID (NOT `$E80_TK1`); Track1 still on E80 (COPY not CUT).

---

### Test 6 -- Delete via E80 Tracks header

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.6" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10225" | Out-Null
Start-Sleep 8
```

**Pass:** `/api/db` tracks empty; DELETE TRACK STARTED/FINISHED.

---

End of tracks module tests.
