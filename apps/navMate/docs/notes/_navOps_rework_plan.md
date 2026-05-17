# navOps Rework -- Overall Plan

**Transient working document.** Filename prefixed with `_` per the leading-underscore convention for plan/working docs with finite lifespans. This file and all referenced `_phaseN_*_plan.md` files will be deleted once the rework is complete.

**Structure-change rule.** If the overall plan structure changes -- phases renumbered, added, removed, renamed, merged, or split -- the corresponding phase doc filenames MUST be renamed in lockstep to match this document's phase outline. The plan doc and its phase docs are an atomic set; never let them drift. When restructuring: update this document's Phase Outline section first, then rename the phase files, then update cross-references in the phase docs themselves.

---

## Purpose

Top-level plan for a structurally significant rework of the navMate `navOperations` layer: `navOps.pm`, `navOpsE80.pm`, `navOpsDB.pm`, `navClipboard.pm`; the NET-layer services `d_WPMGR` and `d_TRACK`; the `Pub::WX::ProgressDialog` interaction; the `navTest.pm` dispatch chain; and the existing testplan infrastructure.

The rework formalizes a hub-and-spoke architecture that already exists implicitly in the codebase, adds a second transport spoke (FSH), introduces a NET-layer synchronization primitive complementary to the existing ProgressDialog step-count sync, and restructures the testplan to support both UI-integration and panel-free navOps-layer testing.

The work is large. It is broken into five phases preceded by a planning preparation step.

---

## Target End State

navOperations as a clean n-point hub-and-spoke architecture.

**Hub.** The navMate canonical model is the richest representation. Everything else is a lossy projection of it.

**Spokes.** Independent per-transport modules satisfying a common contract. `navOpsDB` (already exists; near-zero loss, the canonical-persistence spoke). `navOpsE80` (already exists; lossy in shape A -- name/comment length limits, byte-1 UUID constraint, asynchronous transport). `navOpsFSH` (new; lossy in shape B -- different UUID format, active-flag carrying, deleted-item concepts, synchronous file I/O).

Hub-and-spoke is a deliberately chosen sanity-saving limitation, not a structural necessity. Cross-spoke operations are composed pipelines routed through the hub; bespoke direct spoke-to-spoke adapters are forbidden. When a direct shortcut looks tempting because both spokes carry an attribute the hub does not represent, the answer is "widen the hub," not "carve a side-channel."

**Operation log markers.** navOps dispatches emit magenta `===== <op> (<panel>) STARTED =====` / `===== <op> (<panel>) FINISHED =====` lines around every context-menu operation, visible in the log via the testplan and monitoring tooling.  The existing `Pub::WX::ProgressDialog` continues to emit its own `===== ProgressDialog 'TITLE' STARTED / FINISHED =====` markers when a dialog renders for asynchronous spoke operations.

**Test architecture.** A single UI-integration test surface: the existing testplan runbook (`apps/navMate/docs/notes/navOps_testplan_runbook.md`), driving real wx tree widgets, real context-menu dispatch, and real ProgressDialog rendering. Phase 4 extends it with an FSH section and sectional independence. (An earlier draft of this plan called for a second panel-free test surface and the supporting bracket / `/api/navops/*` infrastructure; that was retired 2026-05-17 as superfluous -- see Phase Outline.)

---

## Continuous Documentation Feedback

Every phase touches or writes persistent working documents and is responsible for feeding its learnings back into the highest-level official navMate docs as the phase lands (architecture docs in `apps/navMate/docs/`, testplan runbook, design notes in `apps/navMate/docs/notes/`, etc.). Documentation updates are NOT deferred to a hypothetical final "update docs" phase -- by the time you arrive at such a phase the earlier phases' nuances have faded.

Each phase's definition implicitly includes "update affected official docs to reflect this phase's reality." Phase docs list which official docs each phase expects to update.

Plan and phase docs (`_*.md`, transient) are the working surface for the rework itself. Official docs are the long-term archaeological record and must remain accurate as the rework proceeds.

---

## Phase Outline

### Pre-Phase 1 -- Planning Preparation (complete)

Inventory of current navOps state: module contents and function inventories for `navOps.pm` / `navOpsE80.pm` / `navOpsDB.pm` / `navClipboard.pm`; the `$progress` mutation path through `d_WPMGR` / `d_TRACK` / `e_wp_api`; the existing `Pub::WX::ProgressDialog` bracketing emission; `navTest.pm`'s panel-resolution chain; `winFSH.pm`'s current state including its context-menu stub at `winFSH.pm:946`; the FSH parsing module landscape (`apps/raymarine/FSH/*.pm`).

The inventory's findings ground Phase 1's "Current State" section and informed the loose initial drafts of Phases 2-4. Inventory is not its own implementation phase.

### Phase 1 -- navObjectsRefactoring -- COMPLETE 2026-05-16

See `_phase1_navObjectsRefactoring_plan.md` for completion-criteria tick-offs and Build Notes.

Refactored navOps so the downstream snapshot/menu-item/dispatch path is data-layer-clean: `_snapshotNodes` takes a panel-kind string label and data hashes; `get*MenuItems` are pure functions in `navClipboard.pm`.  Phase 1 also added an HTTP-driven panel-free test surface (synthesizeContext + `/api/navops/*` endpoints) and a NET-layer bracket / quiescence detector to support a planned second test surface; those pieces were removed 2026-05-17 (see Phase 1 doc top banner).  Changed the existing testplan only where mechanically necessary (turned out to be zero changes; `onContextMenuCommand` signature was preserved through the refactor).

### Phase 2 -- Regression + Factoring Proof -- COMPLETE 2026-05-16

See `_phase2_regressionProof_plan.md` for what was actually delivered.

Scope reduced mid-phase: the regression guardrail (existing testplan runbook unchanged) was the load-bearing activity and shipped clean in Cycle 18. Two speculative activities originally sketched (panel-free no-window navOps-layer cycle; eyeball drift-check between dialog step-count sync and NET-layer quiescence) were retired.

### Phase 3 -- winFSH Wiring + Rudimentary UX -- COMPLETE 2026-05-16

See `_phase3_winFSH_plan.md` for both sub-phases' Build Notes and Documented Limitations.

- **Phase 3A** (landed) -- Replaced `winFSH.pm`'s context menu stub at `winFSH.pm:946` with the full `get*MenuItems` pattern. Implemented `navOpsFSH.pm` using the factored abstractions established in Phase 1. Intra-FSH and DB<->FSH cross-panel operations. Authored the long-deferred `navOps_spoke_contract.md`. The second-implementation validation of the spoke contract landed here.
- **Phase 3B** (landed) -- E80<->FSH cross-panel operations, composed as pipelines through the navMate canonical hub. Hub-and-spoke discipline preserved: no bespoke direct adapter; cross-spoke ops route through the existing snapshot/paste handlers because the canonical clipboard IS the hub for these in-memory ops. Centralized cut-cleanup dispatch in `_cutPasteCleanup*` helpers.

Phase 3 = feature-complete; testing is Phase 4 work.

### Phase 4 -- FSH Test Coverage + Runbook Sectional Independence

See `_phase4_fshTestCoverage_plan.md`.

Two bundled deliverables in a single phase, deliberately combined because they are mutually enabling:

1. Add **Section 6 (FSH)** to the existing UI-integration runbook (`apps/navMate/docs/notes/navOps_testplan_runbook.md`), bringing FSH coverage to parity with E80 on that surface.
2. **Restructure the existing runbook for strict sectional independence**: each section reverts and sets itself up from baseline so it can run standalone OR as part of a full cycle. Section 1 collapses to "mark start time." UUID table chosen so reverted baseline supports every section's pre-state. Sections no longer chain.

The independence work is what makes iterative FSH-testing useful -- you can re-run just Section 6 to prove/fix Phase 3's wiring without re-driving the rest of the cycle. Phase 4 closes with a clean full-cycle run as final regression.

### Phase 5 -- Retired 2026-05-17

Originally planned as "Testplan Bifurcation": a panel-free navOps-layer testplan consuming the latent `/api/navops/*` + `navTestProgress` infrastructure from Phase 1.  The supporting infrastructure was removed 2026-05-17 as superfluous; Phase 5 retired with it.  The single UI-integration test surface (Phase 4) is now the test surface.  See the `_phase5_testplanBifurcation_plan.md` deletion and the Phase 1 doc top banner for context.

---

## Completion Criterion (Rework as a Whole)

The rework is complete when ALL of the following hold:

1. Phases 1-4 have landed (Phase 5 retired 2026-05-17).
2. Each phase doc has been updated to reflect what was actually built (deviations from initial sketch documented inline).
3. Official navMate documentation (architecture docs, testplan runbook, design notes) is current with what each phase delivered.
4. The UI-integration runbook covers FSH (Section 6) and runs cleanly with strict sectional independence (Phase 4 deliverable).
5. The transient `_*.md` plan documents (this file and the phase files) are reviewed for deletion.

---

## Cross-References

- `apps/navMate/docs/notes/navOps_testplan.md` -- existing navOps testplan, baseline for Phase 4 bifurcation.
- `apps/navMate/docs/notes/navOps_testplan_runbook.md` -- existing testplan runbook; evolves through Phases 2 and 4.
- `apps/navMate/docs/notes/winFSH_design.md` -- existing winFSH design notes; informs Phase 3.
- `apps/navMate/docs/notes/design_vision.md` -- high-level architecture vision; receives doc-feedback updates as phases land.
- `apps/navMate/docs/navOperations.md` -- official navOperations doc; receives doc-feedback updates.
