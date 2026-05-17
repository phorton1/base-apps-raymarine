# navOps Test Suite -- Full Cycle Plan

Design doc for the full-cycle orchestrator. For execution, see [`full_cycle_runbook.md`](full_cycle_runbook.md). For module philosophy, see [`master_plan.md`](master_plan.md). For shared toolbox, see [`master_runbook.md`](master_runbook.md).

---

## Purpose

A full cycle runs every module in canonical order against a clean baseline, captures unified results, and writes `_results/cycle_NN.md` on completion. It is the regression test for the entire navOps surface in a single invocation.

A **single-module run** is for development and iteration: fast feedback, no archival artifact. A **full cycle** is the formal record: numbered, archived, comparable to any prior cycle.

---

## Module Order

1. db
2. e80
3. tracks
4. fsh (stub)
5. hub (stub)

Order is preserved everywhere -- this doc, the runbook, the cycle results file. It mirrors the natural complexity progression: single-transport (db) -> cross-panel (e80, tracks) -> FSH spoke (fsh) -> three-panel orchestration (hub).

---

## Inter-Module Reset

Between modules, the orchestrator performs the following sequence (identical to each module's own baseline setup):

1. `git checkout -- navMate.db` on `C:/dat/Rhapsody`
2. `op=refresh` (load reverted DB into navMate)
3. `op=suppress&val=1`
4. `op=clear_e80` (with ProgressDialog wait)
5. `op=load_fsh&path=<abs-path-to-_fixtures/test.fsh>` IF the next module needs FSH (path is absolute; see `master_runbook.md` for the exact endpoint)
6. `cmd=mark+<module>+reset` to scope subsequent log reads

Running the same setup from the orchestrator vs. the module directly produces the same starting state. Modules' own runbooks therefore work in either context.

---

## Cycle Numbering

The orchestrator picks the next cycle number at startup:

```
N = max(parse_cycle_NN(f) for f in _results/cycle_*.md) + 1
```

If `_results/` is empty (first cycle in new structure), N starts at 20 (continuing the legacy `last_testrun18.md` series from `apps/navMate/docs/private/`).

---

## Result Accumulation

Each module records its results as the cycle runs. The orchestrator carries forward a per-module result structure:

```
module_results: {
  db:     { status: PASS, tests: [{name, status, notes}, ...] }
  e80:    { ... }
  tracks: { ... }
  fsh:    { status: NOT_RUN (stub), tests: [...] }
  hub:    { status: NOT_RUN (stub), tests: [...] }
}
```

## Test Identifier Convention

Inside each module's `runbook.md` and `plan.md`, tests are numbered locally (`Test 1`, `Test 14a`). The cycle results table and any cross-module conversation (e.g. "rerun db.24b") prefix the module name with a dot: `db.1`, `e80.14b`, `tracks.3`. Mark tags in curl URLs use the same module-qualified identifier behind the literal `Test`: `mark+Test+db.24b` decodes to log tag `Test db.24b`. Module-local plain `Test N` is for within-book unambiguity; `<mod>.N` (and `Test <mod>.<N>` in logs) is for everything that crosses modules.

On cycle completion the orchestrator renders `cycle_NN.md` from this structure using the format spec in [`master_runbook.md`](master_runbook.md#cycle-results-file-format).

---

## Catastrophic Stop

A catastrophic failure within a module (close_dialog itself fails, navMate process unresponsive, HTTP server unreachable mid-cycle, etc.) stops the cycle. The orchestrator:

1. Records the catastrophic state in the current module's results
2. Marks all subsequent modules as `NOT_RUN (catastrophic prior failure)`
3. Writes a partial `cycle_NN.md` documenting completed modules and the catastrophic state
4. Beeps `[console]::beep(800,200)` and stops

Non-catastrophic FAILs do NOT stop the cycle. The module records the FAIL and continues; the inter-module reset still runs cleanly between modules.

---

## Issues Section

The cycle results' Issues section is the union of every module's FAIL / PARTIAL / PASSED_BUT items from THIS cycle. Per `master_plan.md` cycle discipline: no deltas, no inference, no causation -- observations and reproduction context only.

---

## What the Orchestrator Does Not Do

- Does not modify navMate code, configuration, or test fixtures
- Does not retry failed tests automatically (re-running a flaky test is an operator decision; verify-before-FAIL is per-test, not per-cycle)
- Does not compare to prior cycle results
- Does not write any artifact other than `_results/cycle_NN.md` and the start-time helper file
- Does not push to git or modify version-controlled files
