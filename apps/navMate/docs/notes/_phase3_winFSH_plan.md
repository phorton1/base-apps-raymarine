# Phase 3 -- winFSH Wiring + Rudimentary UX

Sketch-level initial draft. Will be fleshed out before this phase begins, informed by what Phases 1 and 2 actually delivered. Part of the navOps rework -- see `_navOps_rework_plan.md`. Transient doc.

---

## Phase Goal

Build `navOpsFSH.pm` using the abstractions established in Phase 1. Replace `winFSH.pm`'s context menu stub with the full `get*MenuItems` pattern. Do rudimentary real-world UX testing.

This is the **second-implementation validation** of the spoke contract (rule-of-three-with-two: the abstraction that survives two implementations is the right one). If writing `navOpsFSH` requires special cases that mirror what `navOpsE80` already does, that is a signal that Phase 1's factoring needs another pass before proceeding to Phase 4.

The FSH spoke is also the first synchronous spoke, which exercises the bracket primitive's composition story on the easy case (its bracket is `return from function`).

---

## Current State Notes (from pre-Phase 1 inventory)

- `winFSH.pm` exists and is largely wired (`apps/navMate/winFSH.pm`, ~1000 lines, inherits from `winTreeBase`). Full tree population (`_buildGroups`, `_buildRoutes`, `_buildTracks`), tree selection, map visibility integration, save handler.
- **Context menu stub at `winFSH.pm:946`** -- currently just `Show on Map` / `Hide on Map`. Phase 3 replaces this with a real menu via the `get*MenuItems` pattern.
- `navFSH.pm` exists (`apps/navMate/navFSH.pm`) with `loadFSH` / `saveFSH` / `convertToNavMate` / `getFSHDb` / `getFilename`. The existing FSH-to-navMate path goes through `convertToNavMate`; `navOpsFSH` will likely build on or replace this.
- FSH parsing modules are comprehensive: `apps/raymarine/FSH/fshFile.pm`, `fshBlocks.pm`, `fshUtils.pm`, `fshConvert.pm`, `kmlToFSH.pm`, `genKML.pm`, `genGPX.pm`. `navOpsFSH` builds on these.

---

## Activities (sketch)

**Implement `navOpsFSH.pm`** using the spoke contract Phase 1 formalizes: translate-in, translate-out, identity-normalize (FSH dashed-uppercase UUIDs <-> navMate no-dash format), lossy-policy declaration (what FSH preserves, what it drops, what it carries that navMate's canonical model does or does not capture).

**Wire up winFSH context menu.** Replace `_buildContextMenu` at `winFSH.pm:946` with calls to the `get*MenuItems` family in `navClipboard.pm` (add `panel=fsh` cases inside those functions). The UI-integration layer follows `navOpsFSH`'s logic.

**Implement at least one operation end-to-end.** FSH-to-navMate enrichment of an existing waypoint -- the driving use case for the entire rework. Other operations (FSH-to-navMate PASTE_NEW import, navMate-to-FSH export, intra-FSH manipulation) may be in-scope or deferred depending on Phase 1 and Phase 2 outcomes.

**Rudimentary real-world UX testing.** Open a real `.fsh` archive in winFSH. Try the enrichment flow against a real navMate database (e.g. `Rhapsody.gdb` or the working test DB). Verify outcomes in navMate canonical state via `/api/nmdb`.

---

## Second-Implementation Validation Signals

If any of the following arise during `navOpsFSH` implementation, Phase 1 needs another pass before Phase 4:

- A field or behavior is needed in navOps that does not exist or is silently E80-specific.
- The lossy-policy mechanism cannot express FSH's lossy-transform needs.
- The identity-normalization seam is insufficient for FSH's dashed-uppercase UUID format.
- The bracket primitive does not compose cleanly for synchronous file I/O.
- The context-object shape from Phase 1 needs FSH-specific fields.
- The `get*MenuItems` pattern needs structural change to accept `panel=fsh` rather than just additive cases.

Recording these signals as they arise (rather than working around them silently) is the value of this phase.

---

## Phase Completion Criteria

- `navOpsFSH.pm` exists, implements the spoke contract, passes rudimentary manual UX tests.
- winFSH has context-menu support for the operations enabled in this phase (at minimum: FSH-to-navMate enrichment).
- Architecture / spoke-contract docs (whichever Phase 1 produced) reflect what `navOpsFSH` actually requires.
- Phase 3 doc updated with what was built and any second-implementation signals encountered.

---

## Open Questions

- Which operations are in-scope for Phase 3 versus deferred to later phases? FSH-to-navMate enrichment is required; FSH-from-navMate export, intra-FSH manipulation, and other directions may not all be in-scope here.
- Real-world UX testing target: which `.fsh` archive (existing `apps/raymarine/FSH/test/working_oldE80.fsh`? a smaller dedicated test archive?) and which navMate collection?
- Does Phase 3's UX testing include any pre-flight checks or duplicate-detection? (Pre-flight + duplicate-detection were deferred from the navops_truncation_policy resolution; they belong somewhere in navOps but may be after this phase.)
- ProgressDialog behavior for FSH operations: synchronous I/O does not need the same step-count rendering E80 does; what does the dialog actually do for FSH ops, or does it stay out of the way entirely?
- How does `convertToNavMate` in `navFSH.pm` relate to `navOpsFSH` -- replaced, wrapped, or kept as a lower-level utility?

---

## Documentation Feedback (this phase)

- `apps/navMate/docs/notes/winFSH_design.md` -- update with what was actually built versus the prior design notes.
- `apps/navMate/docs/notes/design_vision.md` -- reflect FSH spoke landing.
- Whichever official spoke-contract doc Phase 1 produced -- update to reflect any contract changes triggered by the second-implementation work.
