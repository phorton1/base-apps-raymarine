# navMate - Testing

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)** --
**[navOperations](navOperations.md)** --
**[Spoke Contract](navOps_spoke_contract.md)** --
**[KML Specification](kml_specification.md)** --
**[GE Notes](ge_notes.md)** --
**Testing**

Folders: **[Raymarine](../../../docs/readme.md)** --
**[NET](../../../NET/docs/readme.md)** --
**[FSH](../../../FSH/docs/readme.md)** --
**[CSV](../../../CSV/docs/readme.md)** --
**[shark](../../../apps/shark/docs/shark.md)** --
**navMate**

---

Official overview of the navOps test suite. Forward-pointing index; the substantive content lives in `../test/`.

## What is the navOps test suite

The navOps test suite verifies the cross-transport (hub-and-spoke) behavior of navMate. Tests live in `apps/navMate/test/`, organized by transport surface:

- **db** -- DB-internal operations (copy/cut/paste/delete inside the database) + DB-only guards
- **e80** -- DB <-> E80 cross-panel operations + DB-E80 guards
- **tracks** -- E80 -> DB track download (requires teensyBoat)
- **fsh** -- DB <-> FSH cross-panel operations + DB-FSH guards (stub; filled as winFSH operations land)
- **hub** -- Three-panel operations routed through navMate (stub; filled as multi-spoke flows land)

Each module runs from its own baseline (revert DB + clear E80 + optional FSH load), independent of any other module. A full-cycle orchestrator composes all modules in order and writes an archived results file.

The suite is documentation, not code. Tests are specified as exact curl commands plus pass/fail criteria, executed manually or by Claude. There is no pytest, no JUnit, no automated harness -- the runbook IS the harness; the operator reads results from logs and `/api/db` / `/api/nmdb` introspection.

## Where to start

| Document | Purpose |
|----------|---------|
| [test/master_plan.md](../test/master_plan.md) | Shared philosophy, status definitions, cycle discipline |
| [test/master_runbook.md](../test/master_runbook.md) | Shared toolbox, reset primitives, helpers, results file format |
| [test/uuid_index.md](../test/uuid_index.md) | `[Name] -> UUID` lookup registry |
| [test/full_cycle_plan.md](../test/full_cycle_plan.md) | Full-cycle orchestrator design |
| [test/full_cycle_runbook.md](../test/full_cycle_runbook.md) | Full-cycle orchestrator execution |

## Modules

| Module | Design | Execution |
|--------|--------|-----------|
| db     | [test/db/plan.md](../test/db/plan.md)     | [test/db/runbook.md](../test/db/runbook.md) |
| e80    | [test/e80/plan.md](../test/e80/plan.md)   | [test/e80/runbook.md](../test/e80/runbook.md) |
| tracks | [test/tracks/plan.md](../test/tracks/plan.md) | [test/tracks/runbook.md](../test/tracks/runbook.md) |
| fsh    | [test/fsh/plan.md](../test/fsh/plan.md)   | [test/fsh/runbook.md](../test/fsh/runbook.md) (stub) |
| hub    | [test/hub/plan.md](../test/hub/plan.md)   | [test/hub/runbook.md](../test/hub/runbook.md) (stub) |

## Resources

| Resource | Purpose |
|----------|---------|
| `test/_fixtures/test.fsh` | Frozen FSH archive, test-owned; copied from `FSH/test/working_oldE80.fsh` |
| `test/_results/cycle_NN.md` | Archived full-cycle results, one per completed cycle |

The leading underscore on `_fixtures/` and `_results/` (and any future global resources folder) visually distinguishes them from module folders (`db/`, `e80/`, `tracks/`, `fsh/`, `hub/`).

## Running tests

### Single module (development / iteration)

Open the module's runbook (e.g. `test/db/runbook.md`), execute its baseline setup, then its tests in order. Single-module runs are interactive and produce no archival artifact.

### Test identifiers

Inside a module's book, tests are numbered locally as `Test 1`, `Test 14a`, etc. -- short and unambiguous within that file. In the cycle results table and in conversation, tests are prefixed with the module name and a dot: `db.1`, `e80.14b`, `tracks.3`. Mark tags in curl URLs put the literal `Test` before the qualified identifier: `mark+Test+db.24b` becomes log tag `Test db.24b`. Use `<module>.<N>` whenever the context spans modules; use plain `Test N` inside a single module's book.

### Full cycle (regression)

Open `test/full_cycle_runbook.md`. The orchestrator runs every module in order with inter-module reset, then writes `test/_results/cycle_NN.md` on completion. Cycle number auto-increments from the highest existing `cycle_NN.md`.

## Historical cycles

Pre-refactor cycles are preserved as:

- Cycles 14-18: `apps/navMate/docs/private/last_testrun14.md` ... `last_testrun18.md`
- Cycle 19: `apps/navMate/docs/notes/last_testrun.md`

The new structure starts at cycle 20 in `test/_results/cycle_20.md`.
