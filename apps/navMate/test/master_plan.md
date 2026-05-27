# navOps Test Suite -- Master Plan

Shared design doc for the navOps modular test suite. Every module's `plan.md` references this document for definitions, philosophy, and conventions that don't change between modules.

For execution-level toolbox, helpers, and the cycle results format, see [`master_runbook.md`](master_runbook.md). For the UUID lookup registry, see [`uuid_index.md`](uuid_index.md).

---

## Purpose

The navOps test suite verifies the cross-transport behavior of navMate's hub-and-spoke architecture. Tests live in `apps/navMate/test/`, organized by transport spoke (db, e80, tracks, fsh) plus a coordination module (hub). Each module exercises one transport surface with all its positive paths (operations expected to succeed) and negative paths (guards expected to block).

The suite is documentation, not code. Tests are specified as exact curl commands plus pass/fail criteria, executed manually or by Claude. There is no pytest, no JUnit, no automated harness -- the runbook IS the harness; the operator reads results from logs and `/api/db` / `/api/nmdb` introspection.

---

## Modules

Modules are ordered consistently throughout the suite (overview docs, folder listings, full-cycle orchestrator):

| Order | Module | Bound by | Status |
|-------|--------|----------|--------|
| 1     | db     | DB-internal ops + DB-only guards | Solid |
| 2     | e80    | DB <-> E80 cross-panel ops + DB-E80 guards | Solid |
| 3     | tracks | E80 <-> DB / FSH -> E80 tracks (teensyBoat + writer-session protocol; owns all E80 track ops) | Solid |
| 4     | fsh    | DB <-> FSH cross-panel ops + DB-FSH guards (incl. FSH track writes) | Solid |
| 5     | hub    | Three-panel ops routed through navMate | Solid |

First clean all-PASS full cycle landed 2026-05-17 (cycle 20). All 141 attempted tests passed; the 2 NOT_RUNs in e80 are by design (`e80.27 db_versioning` infrastructure absent, `e80.28a` precondition-met no-op).

---

## Independence

Every module runs from its own baseline. No module depends on any other module having run. Module baselines are established by an explicit setup block, typically:

- revert `navMate.db` to git baseline
- `op=refresh` to load the reverted DB
- `op=suppress&val=1` to bypass confirmation dialogs
- `op=clear_e80` to empty the E80
- optionally, `load_fsh=_fixtures/test.fsh` to populate the FSH side

The cost of reset between modules is on the order of seconds. The benefit -- no ordering coupling, modules debuggable in isolation, no inter-module state leakage -- justifies the cost absolutely.

---

## Fixtures

Two fixture artifacts back the test suite:

- **`navMate.db`** -- the real `C:/dat/Rhapsody/navMate.db`, reverted to git baseline at the start of each module. The DB is **parasitized** -- tests use existing shapes (Bocas, Popa, Michelle, etc.) because they happen to be the right size and structure, not because they were built for testing. DB changes require re-deriving DB UUIDs in `uuid_index.md`.
- **`_fixtures/test.fsh`** -- a frozen FSH archive, dedicated to testing. Originally a copy of `FSH/test/working_oldE80.fsh` (already promoted to navMate, with stable 16-hex UUIDs). The fixture is modified deliberately when tests need new shapes, not as a side effect of other work.

The asymmetry is intentional: maintaining a parallel test-specific DB is too expensive (schema-evolution overhead), while a dedicated test FSH is cheap and isolates FSH-side tests from real-world DB drift.

---

## UUID Index

`uuid_index.md` is a lookup registry: `[Name] -> UUID` plus source annotation. Modules reference `[Names]`; UUIDs live only in the registry. Two species of entry:

- **Static baseline** -- present in either `navMate.db` or `_fixtures/test.fsh`; UUID is a constant. `source=db` or `source=fsh:_fixtures/test.fsh`.
- **Setup-derived** -- produced by a module's setup step (teensyBoat track creation, fresh-UUID PASTE_NEW, etc.); UUID assigned at runtime. `source=setup:<operation>`.

The registry is one-way at runtime: modules consume entries, never write to it. The registry grows at design time: when a new test or module needs a baseline shape, register it first, reference it second.

---

## Test Status

Every test step ends with one of five statuses, recorded in cycle results:

| Status      | Meaning |
|-------------|---------|
| PASS        | All pass criteria met without intervention. |
| FAIL        | One or more pass criteria not met. Includes: blocked operation that should have succeeded, data corruption, ProgressDialog did not auto-FINISH (even if close_dialog rescued the cycle), catastrophic. |
| PARTIAL     | Some sub-steps passed, others did not. |
| PASSED_BUT  | All of the step's own pass criteria met, but with notable non-fatal caveats (unexpected non-violating warning, etc.). NOT used when a primary criterion was violated and the cycle was rescued -- that's FAIL. |
| NOT_RUN     | Structurally non-runnable. Either prereq-blocked (e.g. `NOT_RUN (db_versioning)`) or environment-blocked (e.g. `NOT_RUN (teensyBoat unavailable)`). |

---

## Cycle Discipline

The following rules govern every cycle, single-module or full:

- **No deltas.** A cycle is independent. Do not compare to prior cycles, do not "expect this to pass because it passed before."
- **No research, no fix suggestions.** When a test fails, record the observation and context. Do not investigate root cause, do not propose code changes, do not infer "probably the X module is buggy." Issues capture what happened, with enough reproduction context to support later research as a separate activity.
- **Run to completion.** Continue past non-catastrophic failures. A FAIL on one test does not stop the cycle; subsequent steps run anyway.
- **Catastrophic only stops.** A catastrophic failure (close_dialog itself fails, navMate process unresponsive, HTTP server unreachable mid-cycle, etc.) stops the cycle. Beep `[console]::beep(800,200)` and surface the state.
- **Per-test evaluation.** One test per tool call. Each test is judged on its own outcome, not the outcome of related tests. Never PASSED_BUT a test by citing another test's clean pass.
- **Verify before recording FAIL.** Re-run a failing test from a clean baseline before recording FAIL. False-FAILs cost subsequent sessions; verification cost is one minute.

---

## Cycle Results

A completed full cycle writes its results to `_results/cycle_NN.md`, where N is auto-incremented from the highest existing `cycle_NN.md`. The file format is specified in `master_runbook.md`. Single-module runs produce no result artifact (they're interactive, the operator reads output live).

Existing cycle records (`last_testrun14.md` through `last_testrun18.md` in `apps/navMate/docs/private/`, and `last_testrun.md` for Cycle 19 in `apps/navMate/docs/notes/`) remain as historical artifacts. The new numbering begins at cycle 20 in `_results/`.

---

## Module Composition (provenance)

The first four modules were ported from a single monolithic runbook (`apps/navMate/docs/notes/navOps_testplan_runbook.md`) that ran cleanly through Cycle 19 (2026-05-17 morning). The mapping:

| New module | Source content |
|------------|---------------|
| db         | Section 2 (2.0 -- 2.18b) + DB-only guards (5.1, 5.2, 5.5, 5.9, 5.14a-d, 5.16a-b) |
| e80        | Section 3 (3.1 -- 3.18) + DB-E80 guards (5.3, 5.4c, 5.6d, 5.7, 5.8, 5.10, 5.11b, 5.12, 5.15b-c) |
| tracks     | Section 4 (4.0 -- 4.5) |
| fsh        | New -- developed and stabilized over 2026-05-17 |
| hub        | New -- developed and stabilized over 2026-05-17 (cycle 20 was its first full-cycle appearance) |

Cross-section state-shuffle steps from the legacy runbook (e.g. 2.11 moving [TestRoute] to [DST]; 3.9a/3.11a/3.12a/3.16a re-uploads after intra-section deletes; 5.4a/5.4b pre-cleanup) disappear with per-module reset. They become module setup operations or vanish entirely -- they were never tests in the first place; they were inter-section housekeeping masquerading as tests.

---

## Cross-References

- Toolbox, reset primitives, helpers, results file format: [`master_runbook.md`](master_runbook.md)
- UUID lookup: [`uuid_index.md`](uuid_index.md)
- Full-cycle orchestrator design: [`full_cycle_plan.md`](full_cycle_plan.md)
- Full-cycle orchestrator execution: [`full_cycle_runbook.md`](full_cycle_runbook.md)
- Per-module design: `<module>/plan.md`
- Per-module execution: `<module>/runbook.md`
- Outward-facing overview: [`../docs/testing.md`](../docs/testing.md)
