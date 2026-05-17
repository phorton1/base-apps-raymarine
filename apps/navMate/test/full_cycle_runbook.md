# navOps Test Suite -- Full Cycle Runbook

Execution layer for the full-cycle orchestrator. For design, see [`full_cycle_plan.md`](full_cycle_plan.md). For shared toolbox + helpers + cycle results format, see [`master_runbook.md`](master_runbook.md). For philosophy and status definitions, see [`master_plan.md`](master_plan.md).

---

## Prerequisites

Before starting:

- navMate is running and reachable at `http://localhost:9883`
- teensyBoat may or may not be running. The tracks module branches on this -- if absent, tracks records as `NOT_RUN (teensyBoat unavailable)` and the cycle continues.
- shark is not required for the full cycle (no module in the current suite depends on it).

---

## Step 0: Cycle Number + Start Time

Determine the next cycle number from existing results files:

```powershell
$results_dir = "C:\base\apps\raymarine\apps\navMate\test\_results"
$existing = Get-ChildItem "$results_dir\cycle_*.md" -ErrorAction SilentlyContinue
$nums = $existing | ForEach-Object { if ($_.Name -match 'cycle_(\d+)\.md') { [int]$matches[1] } }
$cycle_num = if ($nums) { ($nums | Measure-Object -Maximum).Maximum + 1 } else { 20 }
"Next cycle: $cycle_num"
```

Write start time to the helper file (survives context compaction):

```powershell
$start = (Get-Date -Format "yyyy-MM-dd HH:mm")
$start | Out-File -Encoding utf8 "C:\base_data\temp\raymarine\testrun_start.txt"
"Start time: $start"
```

---

## Step 1: db Module

Inter-module reset:

```powershell
git -C C:/dat/Rhapsody checkout -- navMate.db
curl.exe -s "http://localhost:9883/api/test?op=refresh" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+db+module+reset" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=clear_e80" | Out-Null
Start-Sleep 5
# Verify ProgressDialog FINISHED (see master_runbook.md ProgressDialog Pattern)
```

Run `test/db/runbook.md` from "Module Tests" onward. The runbook's own baseline-setup section is skipped here (the orchestrator just performed it). Record each test's status, identifying it in the cycle results as `db.<N>` (e.g. `db.1`, `db.24b`) per the Test Identifier Convention in `full_cycle_plan.md`. Collect FAIL / PARTIAL / PASSED_BUT items for the Issues section.

---

## Step 2: e80 Module

Inter-module reset (same as Step 1, with `mark+e80+module+reset`).

Run `test/e80/runbook.md` from Module Tests onward. Record results.

---

## Step 3: tracks Module

Inter-module reset.

Pre-check teensyBoat availability:

```powershell
$tb = try { curl.exe -s "http://localhost:9881/api/command?cmd=SIM" | ConvertFrom-Json } catch { $null }
if ($tb -and $tb.ok) { "teensyBoat is running -- proceed with tracks" }
else { "teensyBoat NOT available -- mark all tracks tests NOT_RUN and continue" }
```

If teensyBoat is not running, record the entire tracks module as `NOT_RUN (teensyBoat unavailable)` and continue to Step 4. Do not block the cycle.

If teensyBoat is running, run `test/tracks/runbook.md` from Module Tests onward.

---

## Step 4: fsh Module

Inter-module reset (same as Step 1 -- revert DB, refresh, **suppress=1**, mark, clear_e80, wait), then FSH load. `suppress=1` MUST precede `load_fsh` so the dirty-bit confirm dialog (if any) auto-discards; see `master_runbook.md` *Suppress ordering*.

```powershell
git -C C:/dat/Rhapsody checkout -- navMate.db
curl.exe -s "http://localhost:9883/api/test?op=refresh" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+fsh+module+reset" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=clear_e80" | Out-Null
Start-Sleep 5
curl.exe -s "http://localhost:9883/api/test?op=load_fsh&path=C:/base/apps/raymarine/apps/navMate/test/_fixtures/test.fsh" | Out-Null
Start-Sleep 3
# Verify "navTest: load_fsh done" in log
```

Run `test/fsh/runbook.md` from Module Tests onward. Record each test as `fsh.<N>` per the Test Identifier Convention.

---

## Step 5: hub Module (currently stub)

Inter-module reset plus FSH load (same as Step 4 -- hub flows generally require FSH side populated; same suppress-before-load_fsh ordering applies):

```powershell
git -C C:/dat/Rhapsody checkout -- navMate.db
curl.exe -s "http://localhost:9883/api/test?op=refresh" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+hub+module+reset" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=clear_e80" | Out-Null
Start-Sleep 5
curl.exe -s "http://localhost:9883/api/test?op=load_fsh&path=C:/base/apps/raymarine/apps/navMate/test/_fixtures/test.fsh" | Out-Null
Start-Sleep 3
```

Run `test/hub/runbook.md`. As stub, all `NOT_RUN (stub)`.

---

## Step 6: Write Results

End time:

```powershell
$end = (Get-Date -Format "yyyy-MM-dd HH:mm")
```

Render `_results/cycle_<N>.md` per the format spec in `master_runbook.md`:

- Title: `# navOperations Test Run -- Cycle <N>`
- Header: Date / Start / End / Cycle
- Summary: per-module result with step count
- Results table: every test from every module, in module order, with status
- Issues: every FAIL / PARTIAL / PASSED_BUT from this cycle, prose subsection each. `none` on a clean cycle.

Use the `Write` tool to create the file. Do NOT use shell redirect -- the line-endings convention applies (Write tool preserves correct EOLs).

---

## Catastrophic Handling

If a module catastrophically fails:

1. `[console]::beep(800,200)`
2. Record the catastrophic state in the current module's results
3. Mark all subsequent modules as `NOT_RUN (catastrophic prior failure)`
4. Render `cycle_<N>.md` with the partial state
5. Stop

A catastrophic failure is: `close_dialog` itself fails, navMate process unresponsive, HTTP server unreachable mid-cycle, or other state where continuing would produce false data.

---

## Single-Module Run (NOT a full cycle)

To run a single module standalone:

1. Perform that module's baseline setup (the module's runbook documents this)
2. Execute the module's tests
3. Read results live; produce NO `cycle_NN.md` -- single-module runs are interactive, not archival

Single-module runs do not consume cycle numbers. Only completed full cycles increment N.
