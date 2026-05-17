# Phase 4 -- FSH Test Coverage + Runbook Sectional Independence

Sketch-level initial draft. Will be fleshed out before this phase begins, informed by what Phase 3 actually delivers (winFSH wiring shape, real operations exercised, ProgressDialog story for synchronous FSH I/O). Part of the navOps rework -- see `_navOps_rework_plan.md`. Transient doc.

---

## Phase Goal

Two bundled deliverables on the existing UI-integration runbook (`apps/navMate/docs/notes/navOps_testplan_runbook.md`):

1. **Add Section 6 (FSH)** -- bring FSH coverage to parity with E80 on the UI surface, exercising the winFSH context menu and `navOpsFSH` end-to-end with a real `.fsh` archive open.
2. **Restructure the runbook for strict sectional independence** -- each section reverts and sets itself up from baseline so it can run standalone OR as part of a full cycle. Section 1 collapses to "mark start time." UUID table chosen so the reverted baseline supports every section's pre-state without requiring earlier sections to have run.

These deliverables are bundled in a single phase because they are mutually enabling. The sectional-independence work is what makes iterative FSH-section runs cheap, which is what makes Phase 4's FSH work iteratively debuggable against Phase 3's wiring. Without independence, every FSH-section run drags the whole UI cycle; with independence, "please run Section 6 FSH" is a one-tool-call operation.

(An earlier draft of this plan referenced Phase 5 -- a panel-free bifurcated testplan -- as the next-phase home for non-UI testing. Phase 5 was retired 2026-05-17 along with its supporting infrastructure; Phase 4 is now the rework's terminal phase.)

---

## Activities (sketch)

**Add Section 6 (FSH) to the existing UI runbook.** Mirror the shape of Sections 2-5: per-test marks, `[Name]` selection keys, expected outcomes verified via `/api/nmdb` for canonical state and via whatever FSH-state introspection Phase 3 added. Cover at minimum the FSH enrichment flow (the driving use case for the rework); other in-scope operations follow from what Phase 3 actually wired.

**Restructure runbook for sectional independence.** Each section grows a small "Section N setup" preamble that asserts/establishes its pre-state from baseline. The current per-section dependencies (Section 3 needs `[TestRoute]` in `[DST]` per Test 2.11, etc.) get rewritten as either baseline-anchored selections or explicit per-section setup steps. Section 1 collapses to "write start time, mark log." Sections become commutative: "run Section 6" works without Section 2-5 having run.

**Redesign the UUID table for baseline-relative anchoring.** Today some tests anchor on UUIDs whose meaningful position in the DB only obtains after prior sections have mutated. The table needs an audit + reassignment so the chosen anchors are all valid against the reverted baseline DB regardless of what prior sections did or didn't do.

**Iterative FSH debugging loop.** With Section 6 in place and independence working, run just Section 6 against winFSH; surface bugs in Phase 3's wiring; fix; re-run Section 6 alone. Repeat until clean. This is the value the bundling unlocks.

**Closing beat -- full-cycle regression run.** Once Section 6 passes standalone and the independence work is done, run the entire runbook end-to-end one time as final validation that nothing regressed and that the full-cycle path still works.

---

## Phase Completion Criteria

1. Section 6 (FSH) exists in `apps/navMate/docs/notes/navOps_testplan_runbook.md` covering each operation winFSH supports.
2. Every section in the runbook runs standalone against the reverted baseline DB. Order-dependency between sections is eliminated.
3. Section 1 has been reduced to start-time + mark.
4. UUID table audited and reassigned where needed for baseline-relative anchoring.
5. A full-cycle run (all sections in order) passes clean, with `last_testrun.md` written per the runbook's existing format.
6. This phase doc updated with what was actually built and what FSH coverage looks like in practice.

---

## Open Questions

- ProgressDialog behavior for synchronous FSH I/O -- does Section 6 verify dialog auto-FINISHED criteria the way Sections 3-4 do, or is the criterion different for synchronous spoke operations? Phase 3's UX shakeout informs this.
- Sectional-independence cost on Section 2 specifically -- Section 2 mutates the DB heavily, then Sections 3-5 (today) depend on those mutations. The audit + rewrite for Section 2 is likely the bulk of the independence work. Worth scoping the actual touched-test count before committing.
- Per-section "setup preamble" shape: is it embedded inline in each section, or factored into reusable snippets (e.g. "Run Section 1 reset, then optionally clear E80, then load FSH archive if running Section 6")?
- For Section 6 specifically: how is the FSH archive loaded -- manual UI step before the section, or an `op=open_fsh_file` test-mode helper added to `/api/test`?
- Which FSH archive(s) are the standard fixtures for Section 6?

---

## Documentation Feedback (this phase)

- `apps/navMate/docs/notes/navOps_testplan_runbook.md` -- significantly extended: Section 6 added, sectional-independence restructure throughout, Section 1 collapsed, UUID table audited.
- `apps/navMate/docs/notes/navOps_testplan.md` -- updated to reflect Section 6 coverage and the sectional-independence model.
- `apps/navMate/docs/notes/winFSH_design.md` -- any final reconciliation between design intent and what Section 6 exercises.
- `apps/navMate/docs/notes/design_vision.md` -- reflect FSH spoke fully landed; mark rework complete.
