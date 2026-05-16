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

**Operation bracketing -- two coexisting synchronization primitives.**

The existing ProgressDialog step-count sync is preserved unchanged. The dialog (defined as `Pub::WX::ProgressDialog` inside `Pub/WX/Dialogs.pm:178`) emits structured log lines `===== ProgressDialog 'TITLE' STARTED =====` (line 279) and `===== ProgressDialog 'TITLE' FINISHED =====` (line 292). Services in `d_WPMGR.pm`, `d_TRACK.pm`, and `e_wp_api.pm` mutate a shared progress hash (`$progress->{total}`, `$progress->{done}`, `$progress->{label}`, `$progress->{error}`, `$progress->{cancelled}`, `$progress->{workers}`) created by `Pub::WX::ProgressDialog::newProgressData` (`Pub/WX/Dialogs.pm:209`). The dialog polls the hash to render. No method dispatch; communication is shared-hash mutation. This proves a *service-correctness* property: did the service emit the right number of step-count mutations in the right shape. A hung dialog is a real bug signal, not a UI artifact.

A new NET-layer quiescence detector is added inside `d_WPMGR` and `d_TRACK` as a second, independent sync primitive. It tracks `last_send_ts` and `last_event_ts` at the `handleCommand` and `handleEvent` entry points; emits `BRACKET_START <intent>` / `BRACKET_FINISH <intent>` log lines for each `$API` command (INNER bracket), where intent is a free-form per-command string. Quiescence interval T = 1 second starting value. This proves a *transport-completion* property: did the spoke actually fall idle. `navOps` code emits a parallel OUTER bracket per context-menu operation (one level of nesting; no inner-inner); outer brackets close when all child inner brackets have closed plus quiescence. Different consumer: the panel-free navOps-layer test surface, which subscribes to outer brackets and treats `$API`-level activity as opaque.

The two primitives cross-check each other. Disagreement is signal: if quiescence closes but step-count is incomplete, the service under-emitted; if step-count completes but events are still firing, the dialog's expectation was wrong. **A hung ProgressDialog is never auto-dismissed by quiescence** -- that would mask exactly the step-count bugs the dialog exists to catch.

**Test architecture -- two surfaces multiplied by three per-spoke branches.**

Surfaces:
- **navOps-layer (logic).** Tests panel-free: synthesized contexts dispatched directly to navOps; assertions on canonical state changes, identity reconciliation, lossy-transform fidelity. Consumes the quiescence sync primitive (no dialog).
- **UI-integration.** The existing testplan runbook (`apps/navMate/docs/notes/navOps_testplan_runbook.md`): real wx tree widgets, real context-menu dispatch, real ProgressDialog rendering. Tests the plumbing between user action and navOps logic. Consumes the dialog's step-count sync primitive via the existing shared progress hash.

Per-spoke branches:
- **DB intra-hub.** Tests pure navMate canonical operations; no spoke crossings; no hardware; no panels. Function-call latency. The speed win that the rework unlocks.
- **E80 hub-spoke.** Tests hub<->E80 crossings AND intra-E80 operations. Requires E80 hardware.
- **FSH hub-spoke.** Tests hub<->FSH crossings AND intra-FSH operations. Requires an FSH archive open.

No fourth "composition" category. By hub-and-spoke discipline, cross-spoke operations are composed pipelines through the hub. A DB->E80 paste is properly tested as hub-side correctness (DB branch) + E80-side write correctness (E80 branch).

---

## Continuous Documentation Feedback

Every phase touches or writes persistent working documents and is responsible for feeding its learnings back into the highest-level official navMate docs as the phase lands (architecture docs in `apps/navMate/docs/`, testplan runbook, design notes in `apps/navMate/docs/notes/`, etc.). Documentation updates are NOT deferred to a hypothetical final "update docs" phase -- by the time you arrive at such a phase the earlier phases' nuances have faded.

Each phase's definition implicitly includes "update affected official docs to reflect this phase's reality." Phase docs list which official docs each phase expects to update.

Plan and phase docs (`_*.md`, transient) are the working surface for the rework itself. Official docs are the long-term archaeological record and must remain accurate as the rework proceeds.

---

## Phase Outline

### Pre-Phase 1 -- Planning Preparation (complete)

Inventory of current navOps state: module contents and function inventories for `navOps.pm` / `navOpsE80.pm` / `navOpsDB.pm` / `navClipboard.pm`; the `$progress` mutation path through `d_WPMGR` / `d_TRACK` / `e_wp_api`; the existing `Pub::WX::ProgressDialog` bracketing emission; `navTest.pm`'s panel-resolution chain; `winFSH.pm`'s current state including its context-menu stub at `winFSH.pm:946`; the FSH parsing module landscape (`apps/raymarine/FSH/*.pm`).

The inventory's findings ground Phase 1's "Current State" section and informed the loose initial drafts of Phases 2-5. Inventory is not its own implementation phase.

### Phase 1 -- navObjectsRefactoring + NET-Layer Bracketing

See `_phase1_navObjectsRefactoring_plan.md`.

Add selection-context synthesis from test code so `_snapshotNodes` can be exercised without a wx panel (the downstream snapshot/menu-item/dispatch path is already data-layer-clean: `_snapshotNodes` takes a panel-kind string label and data hashes; `get*MenuItems` are pure functions in `navClipboard.pm`). Expose `/api/navops/...` entry points for navOps-layer testing. Add debounced quiescence bracketing in `d_WPMGR` / `d_TRACK` at `handleCommand` / `handleEvent` sites. Add a `TestProgress` parallel consumer of the shared progress hash. Change the existing testplan only where mechanically necessary.

### Phase 2 -- Regression + Factoring Proof

See `_phase2_regressionProof_plan.md`.

Prove Phase 1's factoring is real. Existing testplan runbook runs unchanged (regression guardrail). New no-window / no-dialog cycle exercises Phase 1's navOps-layer entry points and passes. Eyeball comparison of dialog log lines versus `TestProgress` events catches drift between the two sync primitives.

### Phase 3 -- winFSH Wiring + Rudimentary UX

See `_phase3_winFSH_plan.md`.

Replace `winFSH.pm`'s context menu stub at `winFSH.pm:946` (currently just Show/Hide Map) with the full `get*MenuItems` pattern. Implement `navOpsFSH.pm` using the factored abstractions established in Phase 1. Rudimentary real-world UX testing -- the second-implementation validation of the spoke contract.

### Phase 4 -- Testplan Bifurcation

See `_phase4_testplanBifurcation_plan.md`.

Pull a navOps-layer test surface out of the existing testplan runbook. Partition along the per-spoke axis (DB intra-hub, E80 hub-spoke, FSH hub-spoke) with per-branch preconditions segregated.

### Phase 5 -- FSH Test Coverage (Completion Criterion)

See `_phase5_fshTestCoverage_plan.md`.

Develop AND RUN entries for navOpsFSH on the navOps-layer testplan, and for winFSH on the UI-integration testplan, bringing FSH coverage to parity with E80 across both surfaces.

**Phase 5 is not deferred. It is the completion criterion for the rework.** The major implementation milestone is reached only when all tests, including FSH on both surfaces, have been developed and run.

---

## Completion Criterion (Rework as a Whole)

The rework is complete when ALL of the following hold:

1. All five phases have landed.
2. Each phase doc has been updated to reflect what was actually built (deviations from initial sketch documented inline).
3. Official navMate documentation (architecture docs, testplan runbook, design notes) is current with what each phase delivered.
4. The bifurcated testplan exists and has been *run* against all three branches (DB intra-hub, E80 hub-spoke, FSH hub-spoke) on both surfaces (navOps-layer and UI-integration).
5. The transient `_*.md` plan documents (this file and the phase files) are reviewed for deletion.

---

## Cross-References

- `apps/navMate/docs/notes/navOps_testplan.md` -- existing navOps testplan, baseline for Phase 4 bifurcation.
- `apps/navMate/docs/notes/navOps_testplan_runbook.md` -- existing testplan runbook; evolves through Phases 2 and 4.
- `apps/navMate/docs/notes/winFSH_design.md` -- existing winFSH design notes; informs Phase 3.
- `apps/navMate/docs/notes/design_vision.md` -- high-level architecture vision; receives doc-feedback updates as phases land.
- `apps/navMate/docs/navOperations.md` -- official navOperations doc; receives doc-feedback updates.
