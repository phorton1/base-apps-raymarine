# Phase 4 -- Testplan Bifurcation

Sketch-level initial draft. Will be fleshed out before this phase begins, informed by what Phases 1, 2, and 3 actually delivered. Part of the navOps rework -- see `_navOps_rework_plan.md`. Transient doc.

---

## Phase Goal

Split the existing testplan into two surfaces and three per-spoke branches:

- **Surfaces:** navOps-layer (panel-free) and UI-integration (the current panel-driven runbook). Each tests a different property of the system.
- **Branches:** DB intra-hub (fast, function-call latency), E80 hub-spoke (hub-crossing plus intra-E80), FSH hub-spoke (hub-crossing plus intra-FSH).

---

## Activities (sketch)

**Pull a navOps-layer test surface out of the existing runbook.** The navOps-layer cycle from Phase 2 is the seed; flesh it out to a real testplan with sections, named contexts, and assertions on `/api/navops/available` outputs as well as dispatch outcomes.

**Partition the navOps-layer tests by spoke:**

- **DB intra-hub branch.** Synthesize contexts, dispatch, verify navMate canonical state via `/api/nmdb`. No spoke I/O. Aim for sub-second-per-test latency.
- **E80 hub-spoke branch.** Hub-to-E80 crossings + intra-E80 operations (clear, reorganize). Requires E80 hardware; uses the new NET-layer quiescence bracket.
- **FSH hub-spoke branch.** Hub-to-FSH crossings + intra-FSH operations. Requires an FSH archive open.

**Keep the existing UI-integration runbook in place as the second surface.** Reorganize it lightly so its per-branch structure matches the navOps-layer's. Existing sections in `apps/navMate/docs/notes/navOps_testplan_runbook.md` likely already map to spoke branches with light retagging.

**Programmable preconditions.** Confirm `op=clear_e80` works from the new test entry points; add an equivalent `op=open_fsh_file` for FSH branch preconditions. DB revert remains manual per `[[feedback_git]]`.

---

## Phase Completion Criteria

- Two surfaces exist as runnable testplan branches.
- Three per-spoke branches exist within each surface (where applicable).
- DB intra-hub branch runs end-to-end with no hardware and no panels.
- E80 hub-spoke branches run end-to-end with E80 hardware.
- FSH hub-spoke branches are *defined* (full runs are Phase 5).
- The official testplan runbook(s) reflect the new structure.

---

## Open Questions

- Single runbook with branch markers, or one runbook per branch?
- How does the consistency contract between surfaces get tested -- the property that `get*MenuItems` output for a given context equals what the UI presents?
- DB revert manual step: should the runbook explicitly call this out as a precondition section per branch, or only for DB-touching branches?
- Does the navOps-layer surface get its own runbook doc (`apps/navMate/docs/notes/navOps_testplan_layer_runbook.md` or similar)?

---

## Documentation Feedback (this phase)

- `apps/navMate/docs/notes/navOps_testplan.md` -- updated to reflect the bifurcated structure.
- `apps/navMate/docs/notes/navOps_testplan_runbook.md` -- updated for per-branch organization; possibly split into per-surface runbooks.
- A new runbook for the navOps-layer surface, if that's the chosen shape.
