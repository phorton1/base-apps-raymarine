# Phase 5 -- FSH Test Coverage (Completion Criterion)

Sketch-level initial draft. Will be fleshed out before this phase begins, informed by what Phases 1-4 actually delivered. Part of the navOps rework -- see `_navOps_rework_plan.md`. Transient doc.

**This phase is the completion criterion for the whole rework, not a deferred follow-on.** The rework is not finished until Phase 5's tests are developed AND run.

---

## Phase Goal

Bring FSH coverage to parity with E80 across both test surfaces and the FSH hub-spoke branch:

- **navOps-layer FSH tests:** lossy-transform fidelity (translate-in, translate-out round-trips), identity reconciliation (FSH dashed-upper <-> navMate no-dash), enrich vs PASTE_NEW semantics, lossy-policy contract (what gets dropped, what gets truncated, what gets preserved).
- **UI-integration FSH tests:** winFSH panel, context-menu enumeration (matches navOps-layer `available()`), tree refresh after operations, ProgressDialog behavior for FSH ops (synchronous spoke -- the dialog's role is different here than for E80).

---

## Activities (sketch)

**Author navOps-layer FSH test entries** covering each operation winFSH supports. Synthesize FSH contexts, dispatch enrich / PASTE_NEW / etc., assert canonical state changes (via `/api/nmdb`) and per-spoke state changes (via whatever FSH-state introspection Phase 3 added).

**Author UI-integration FSH test entries** that mirror the navOps-layer entries, going through the winFSH panel. Will require the wx panel open during runs; uses the existing `panel=...` dispatch mechanism extended in Phase 3 to handle `panel=fsh`.

**Run both sets of entries** on the bifurcated testplan from Phase 4. This is the moment the rework's completion criterion is met.

**Update the official testplan runbook(s)** with the new entries and any per-branch precondition refinements that surfaced.

---

## Completion Criteria (Rework-Wide)

This phase's completion is the rework's completion. ALL of:

1. navOps-layer FSH tests developed and *run*; pass.
2. UI-integration FSH tests developed and *run*; pass.
3. All three branches' tests run on both surfaces (where applicable).
4. Official docs current.
5. All `_*.md` plan docs (including this one) reviewed for deletion.

---

## Open Questions

- How does the FSH hub-spoke branch's ProgressDialog story work? Synchronous spoke means very different dialog behavior than E80; may not need any dialog at all for FSH operations.
- What's the seed FSH archive for testing? `working_oldE80.fsh` is a candidate; may want a smaller dedicated test archive.
- Does this phase include any *intra-FSH* operations beyond crossing the hub -- active-flag manipulation, archive-internal reorganization, deleted-item handling? Some of these are in `winFSH_design.md` but may not all be in-scope for the initial rework.
- Does the navOps-layer FSH testing need a no-hardware variant (FSH is file-I/O, so no hardware required at all -- but archives may still need to exist on disk)?

---

## Documentation Feedback (this phase)

- `apps/navMate/docs/notes/navOps_testplan.md` -- final updates with FSH entries.
- `apps/navMate/docs/notes/navOps_testplan_runbook.md` (and any per-surface variants from Phase 4) -- final updates with FSH entries.
- `apps/navMate/docs/notes/winFSH_design.md` -- any final reconciliation between design intent and implemented behavior.
- `apps/navMate/docs/notes/design_vision.md` -- mark the rework complete; update the architectural narrative to reflect the landed state.
