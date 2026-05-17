# Phase 4 -- navOps Testplan Modular Refactor

Plan document. Transient doc (leading underscore). Part of the navOps rework -- see `_navOps_rework_plan.md`.

**Supersedes** `_phase4_fshTestCoverage_plan.md`. That earlier draft bundled "add FSH section" with "make sections independent" but kept everything inside the single monolithic runbook. This plan replaces that approach with a full modular refactor into `apps/navMate/test/`, on the grounds that the modularization work is the same regardless of where it lives and a folder layout pays back permanently in maintainability, independence semantics, and result archival.

---

## Phase Goal

Refactor the current monolithic `navOps_testplan.md` / `navOps_testplan_runbook.md` pair (in `docs/notes/`) into a modular test suite at `apps/navMate/test/`. Modules are bounded by transport spoke (db, e80, tracks, fsh) plus a coordination module (hub). Each module is independently runnable from a known baseline. A full-cycle orchestrator composes all modules in order and serializes results to `test/_results/cycle_NN.md`. Common protocol, conventions, and a UUID lookup registry live as shared header files referenced by every module.

The current testplan is feature-complete and passing (Cycle 19, 2026-05-17). The refactor introduces no new tests at first; it reshapes the existing ones. FSH and hub modules ship as stubs to be filled in as their underlying behavior is implemented and exercised.

---

## Architectural Decisions (settled in conversation 2026-05-17)

1. **Modular by transport surface.** Modules are db, e80, tracks, fsh, hub -- in that order, preserved everywhere (overview doc, folder listing, full-cycle order).

2. **Per-module reset to known state.** Every module's baseline is established by an explicit setup block (revert DB + clear E80 + optional `load_fsh=_fixtures/test.fsh`). No inter-module state dependencies. Reset cost is seconds; the benefit -- module independence and no ordering coupling -- justifies it absolutely.

3. **Each module is a `plan.md` + `runbook.md` pair.** plan describes design intent and expected behavior; runbook is execution-level (mark + curl + verify). Same pattern that exists today, applied per module.

4. **Shared headers, three of them.** Two prose/protocol docs and one lookup table:
   - `master_plan.md` -- the philosophy: what makes a test cycle valid, no-deltas / no-research / no-fix-suggestions rules, run-to-completion convention, issues-section format.
   - `master_runbook.md` -- the toolbox: HTTP endpoints, reset primitives (`revert`, `clear_e80`, `refresh`, `suppress`, `load_fsh`), mark tagging, log reader, ProgressDialog wait, status definitions (PASS / FAIL / PARTIAL / PASSED_BUT / NOT_RUN), known-quiet warnings table.
   - `uuid_index.md` -- the `[Name] -> UUID` registry, with each entry declaring its source (`source=db` for git-baseline DB UUIDs, `source=fsh:_fixtures/test.fsh` for FSH-fixture UUIDs). Lookup table, not prose; meant to be referenced not read.

5. **FSH fixture is test-owned.** `test/_fixtures/test.fsh` is a frozen copy of the current `FSH/test/working_oldE80.fsh` (already promoted to navMate, UUIDs in navMate's 16-hex form). The fixture is modified deliberately when tests need new shapes -- not as a side effect of unrelated working changes. The asymmetry vs. the DB is intentional: DB is parasitized (we use Bocas/Popa/etc. because they happen to be shaped right); FSH is purpose-built for tests.

6. **Full-cycle orchestrator.** `full_cycle_plan.md` + `full_cycle_runbook.md` at `test/` root. Runs modules in order, performs the inter-module reset between each, writes start time, writes results to `test/_results/cycle_NN.md` on completion. Cycle number auto-increments from highest existing `cycle_NN.md` in `test/_results/`. Single-module runs produce no result artifact (they're interactive).

7. **Guards collapse into their natural module.** Today's Section 5 splits two ways:
   - Single-transport guards (current 5.1, 5.2, 5.5, 5.9, 5.14a-d, 5.16a-b) -- pure DB rule enforcement -- fold into the **db module** as negative-path tests.
   - Cross-transport guards (current 5.3, 5.4c, 5.6d, 5.7, 5.8, 5.10, 5.11b, 5.12, 5.15b-c) -- DB-to-E80 policy enforcement -- fold into the **e80 module** as negative-path tests.
   No standalone "guards" module. Every guard is the negative-path variant of an operation that the module already covers on the positive path.

8. **Hub module is the genuinely new test territory.** Three-panel operations that route *through* navMate as the hub -- E80 <-> navMate <-> FSH or FSH <-> navMate <-> E80 -- where the test cannot reduce to a single spoke pair. Mirrors the code architecture (navOpsDB / navOpsE80 / navOpsFSH as spokes, navOps as hub).

9. **`docs/testing.md` is the outward-facing official document.** Lives in `docs/` (not `notes/`, not `private/`). Header + forward-references into `../test/`. Names the modules, links to each module's plan + runbook, links to the master docs and uuid_index, summarizes the full-cycle model. The first thing a reader (human or future Claude) encounters when asking "how is navOps tested?".

---

## Folder Layout

```
apps/navMate/
  docs/
    testing.md                ← official outward-facing overview
  test/
    master_plan.md            ← shared philosophy
    master_runbook.md         ← shared toolbox + reset primitives + conventions
    uuid_index.md             ← [Name] -> UUID registry (lookup, not prose)
    full_cycle_plan.md        ← orchestrator design
    full_cycle_runbook.md     ← orchestrator execution + results write
    _fixtures/
      test.fsh                ← frozen FSH fixture (from working_oldE80.fsh)
    _results/
      cycle_NN.md             ← one per completed full cycle (numbered, archived)
    db/
      plan.md
      runbook.md
    e80/
      plan.md
      runbook.md
    tracks/
      plan.md
      runbook.md
    fsh/
      plan.md                 ← stub
      runbook.md              ← stub
    hub/
      plan.md                 ← stub
      runbook.md              ← stub
```

---

## Module Composition (current sections -> new modules)

| New module | Current sections folded in |
|------------|---------------------------|
| db         | Section 2 (all of 2.0 -- 2.18b) + DB-only guards (5.1, 5.2, 5.5, 5.9, 5.14a-d, 5.16a-b) |
| e80        | Section 3 (all of 3.1 -- 3.18) + DB<->E80 guards (5.3, 5.4c, 5.6d, 5.7, 5.8, 5.10, 5.11b, 5.12, 5.15b-c) |
| tracks     | Section 4 (all of 4.0 -- 4.5) |
| fsh        | NEW -- stub for now; filled in as winFSH operations land |
| hub        | NEW -- stub for now; defines three-panel ops (E80 <-> navMate <-> FSH and reverse) |

Cross-section state-shuffle steps disappear with per-module reset. Specifically the following current steps stop being tests and become baseline setup operations or stop existing altogether:

- 2.11 (move [TestRoute] to [DST]) -- not a test; vanishes
- 2.12 (move [TestTrack] to [DST]) -- not a test; vanishes
- 3.9a / 3.11a / 3.12a / 3.16a (re-upload to E80 after intra-section deletes) -- become setup steps within e80 module
- 5.4a / 5.4b (pre-cleanup BOCAS1/BOCAS2 from E80) -- become setup steps within e80 module
- 3.10a (re-upload IsolatedWP1 conditional) -- becomes setup or vanishes

Net result: the module test counts are smaller than the current section test counts because the cross-section housekeeping disappears. Coverage is unchanged -- those steps were never tests in the first place; they were setup masquerading as tests.

---

## UUID Index Model

Each entry in `uuid_index.md` declares:
- `[Name]` -- the human-readable token referenced by modules
- `uuid` -- the actual UUID (for static entries) or `dynamic` (for setup-derived)
- `source` -- `db` for git-baseline DB entries, `fsh:_fixtures/test.fsh` for FSH-fixture entries, `setup:create_track(...)` or similar for setup-derived entries
- `notes` -- role, which modules use it, any caveats

**Static-baseline entries** (DB and FSH) are constants -- the UUID is fixed once the source artifact is fixed. DB changes require re-deriving DB entries; FSH fixture is frozen so its entries are stable indefinitely.

**Setup-derived entries** exist for items created during module setup whose UUIDs are assigned at run time (E80-assigned track UUIDs from teensyBoat-recorded tracks, fresh-UUID PASTE_NEW results that subsequent tests reference, etc.). Their `source` field describes the setup operation that produces them.

The registry is one-way at runtime: modules consume from it, never write to it. The registry grows at design time -- when a new test or module needs a baseline entry, the registry is updated first, then the test references the new `[Name]`.

---

## Implementation Phasing

**Phase A: Foundation.** Build the shared infrastructure before any module is written.
1. Create `apps/navMate/test/` folder (manual; per filesystem-safety rule, requires explicit go-ahead).
2. Copy `FSH/test/working_oldE80.fsh` to `test/_fixtures/test.fsh` (frozen fixture).
3. Write `master_plan.md` -- philosophy, principles, status definitions.
4. Write `master_runbook.md` -- HTTP endpoints, reset primitives, mark tagging, log reader, ProgressDialog wait, known-quiet warnings, test execution rules.
5. Write `uuid_index.md` -- port the current static UUID table; tag each entry with `source`.
6. Write `full_cycle_plan.md` and `full_cycle_runbook.md` -- the orchestrator.
7. Write `docs/testing.md` -- official overview, forward-links to everything in `test/`.

**Phase B: Solid modules.** Port the modules that have known content (the test cycle just ran clean).
8. Write `test/db/plan.md` + `test/db/runbook.md` -- current Section 2 + DB-only guards.
9. Write `test/e80/plan.md` + `test/e80/runbook.md` -- current Section 3 + DB<->E80 guards.
10. Write `test/tracks/plan.md` + `test/tracks/runbook.md` -- current Section 4.

**Phase C: Stubs.** Skeletons for the modules whose content is not yet known.
11. Write `test/fsh/plan.md` + `test/fsh/runbook.md` -- baseline declaration + placeholder test list referencing FSH fixture, marked TBD pending Phase 3 winFSH operations.
12. Write `test/hub/plan.md` + `test/hub/runbook.md` -- baseline declaration + placeholder three-panel operation list, marked TBD pending FSH module.

**Phase D: Validation.**
13. Run db module standalone. Confirm PASS from its own baseline.
14. Run e80 module standalone. Confirm PASS.
15. Run tracks module standalone. Confirm PASS.
16. Run full cycle via `full_cycle_runbook.md`. Confirm PASS overall, confirm `test/_results/cycle_20.md` is written and matches expectations.

**Phase E: Retirement and memory updates.**
17. After 2-3 clean full cycles, retire `docs/notes/navOps_testplan.md` and `navOps_testplan_runbook.md` (move to `docs/private/legacy/` or delete -- Patrick decides).
18. Update memory entries:
    - `navOps_testplan_runbook` memory -> repoint to `test/master_runbook.md` + module runbooks
    - `feedback_lastrun_location` memory -> repoint to `test/_results/cycle_NN.md`, full-cycle-only write rule
    - `feedback_testrun_starttime` memory -> repoint to whatever `full_cycle_runbook.md` prescribes (likely unchanged location)

Phases A-C are pure documentation work; Phase D requires the live system. Phase E follows clean Phase D.

---

## Open Items / Deferred Decisions

- **Cycle number bootstrap.** New cycles start at 20 (continuing from current 19). Existing `last_testrun14/15/17/18.md` in `docs/private/` stay where they are as historical artifacts; not migrated.
- **Exact toolbox content in `master_runbook.md`.** The current runbook's PowerShell helpers (`Wait-NavCmdFinished`, `Mark-Phase`) move into `master_runbook.md` as reusable definitions. Test 2.0's batched-script exception note also moves there.
- **FSH load primitive details.** RESOLVED 2026-05-17: `/api/test?op=load_fsh&path=<absolute-path>` is wired in `navTest.pm`. Takes an absolute filesystem path; calls `navFSH::loadFSH`; opens or refreshes the winFSH pane. Log markers `navTest: load_fsh done path=<path>` / `WARNING: navTest: load_fsh failed for <path>`.
- **fsh and hub module content.** Out of scope for this plan beyond writing the stubs. Real content arrives as the underlying operations are implemented and exercised.

---

## Completion Criteria

1. `apps/navMate/test/` folder exists with the structure above.
2. `docs/testing.md` exists as the outward-facing overview.
3. Three shared headers exist and are complete: `master_plan.md`, `master_runbook.md`, `uuid_index.md`.
4. Full-cycle orchestrator pair exists: `full_cycle_plan.md`, `full_cycle_runbook.md`.
5. FSH fixture exists at `test/_fixtures/test.fsh` (frozen).
6. db, e80, tracks modules ported -- each runs standalone PASS against its own baseline.
7. fsh, hub modules stubbed -- skeleton exists, content TBD.
8. Full cycle via `full_cycle_runbook.md` runs clean; produces `test/_results/cycle_20.md`.
9. Memory entries updated to point at new locations.
10. Legacy testplan + runbook retired after 2-3 clean full cycles.

---

## What This Plan Does Not Do

- Does not write any FSH-side tests beyond stub placeholders. FSH module content is owned by the eventual fsh module fill-in work, downstream of Phase 3's winFSH operations landing.
- Does not write any hub-module tests beyond stub placeholders. Hub content is owned by whoever first wires a three-panel operation end-to-end.
- Does not change the underlying navOps code. Refactor is documentation-only; the behavior under test is unchanged.
- Does not introduce a test-specific database. Real navMate.db continues to serve as the DB-side fixture; the asymmetry vs. FSH (which gets a dedicated fixture) is intentional and accepted.
