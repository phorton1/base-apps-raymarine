# Phase 2 -- Regression + Factoring Proof

Sketch-level initial draft. Will be fleshed out before this phase begins, informed by what Phase 1 actually delivered. Part of the navOps rework -- see `_navOps_rework_plan.md`. Transient doc; deleted on rework completion.

---

## Phase Goal

Prove that Phase 1's factoring is real. Three independent proofs:

1. The existing UI-integration testplan runs unchanged and produces identical results (regression guardrail).
2. A new no-window / no-dialog cycle exercises the navOps-layer entry points exposed in Phase 1 and produces correct results.
3. The two synchronization primitives -- `ProgressDialog` step-count and NET-layer quiescence -- agree on a representative operation.

---

## Activities (sketch)

**Run the existing testplan runbook unchanged.** No code changes beyond Phase 1's mechanically-necessary path adjustments. Verify identical pass against `apps/navMate/docs/notes/navOps_testplan_runbook.md`. Any deviation is a regression and blocks Phase 3.

**Author a parallel "navOps-layer cycle" script.** Hits the navOps-layer entry points (whatever endpoint shapes Phase 1 resolved) for the same logical operations the existing runbook covers, but with no window open and no `ProgressDialog`. Verifies the same state outcomes the UI runbook verifies (via `/api/nmdb` and similar introspection). Coverage scope (full equivalent or representative subset) is an open question for this phase.

**Drift check between sync primitives.** Pick one representative operation -- a single waypoint paste from DB to E80, for example. Capture:

- The `ProgressDialog`'s log lines (`===== ProgressDialog 'TITLE' STARTED =====`, ticks via `display(...)`, `===== ProgressDialog 'TITLE' FINISHED =====`).
- The `TestProgress` sink's accumulated events for the same operation.
- The `BRACKET_START <intent>` / `BRACKET_FINISH <intent>` log lines (both inner-per-`$API`-command and outer-per-navOps-operation).

They should describe the same activity at compatible granularity. Any difference -- events one consumer sees that the other doesn't -- is signal worth investigating.

---

## Phase Completion Criteria

- Existing testplan: passes identical to baseline.
- navOps-layer cycle: passes.
- Drift check: no surprises, or surprises are explained and the explanations recorded in this doc.
- Phase 2 doc updated with what was actually run and learned.

---

## Open Questions

- What exactly does the navOps-layer cycle cover -- whole runbook equivalent, or a representative subset selected for breadth?
- What format do `TestProgress` events take, and how are they captured (endpoint? log lines? both)?
- Does the drift check generalize beyond one representative operation, or is one-time spot-check enough?
- Does Phase 2 include any per-branch (DB / E80 / FSH) partitioning, or does that all wait for Phase 4?

---

## Documentation Feedback (this phase)

- `apps/navMate/docs/notes/navOps_testplan_runbook.md` -- note the existence of the parallel navOps-layer cycle and how to invoke it. Full bifurcation comes in Phase 4; Phase 2's update is an additive note.
