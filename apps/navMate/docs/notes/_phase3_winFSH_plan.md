# Phase 3 -- winFSH Wiring + Rudimentary UX

> **REMOVAL NOTE 2026-05-17:** Bracket-system references throughout this document (the `servicesForCmd` discussion, the `BRACKET_START/FINISH` log markers, the "no inner brackets" architectural-choice subsection, the HTTP smoke-test verification items) describe infrastructure that was removed.  Phase 3A/3B FSH spoke implementation is otherwise current; only the bracket-coupling commentary is stale.  See `_navOps_rework_plan.md` for the post-removal architecture.

Part of the navOps rework -- see `_navOps_rework_plan.md`. Transient doc.

Phase 3 is split into two sub-phases sized for one claude-plan each. Phase 3 only marks COMPLETE when both 3A and 3B have landed.

- **Phase 3A** -- winFSH context-menu wiring + `navOpsFSH.pm` as the third spoke + DB<->FSH cross-panel operations + the long-deferred `navOps_spoke_contract.md`.
- **Phase 3B** -- E80<->FSH cross-panel operations, composed as pipelines through the navMate canonical hub (hub-and-spoke discipline; no bespoke direct adapter).

---

## Phase Goal (both 3A and 3B)

Build `navOpsFSH.pm` using the spoke abstraction Phase 1 formalized. Replace `winFSH.pm`'s context-menu stub with the full `get*MenuItems` pattern. Bring FSH onto navOperations as a first-class third spoke, with feature-complete intra-FSH and cross-panel operations. Testing is Phase 4 work.

This is the **second-implementation validation** of the spoke contract (rule-of-three-with-two: the abstraction that survives two implementations is the right one). If writing `navOpsFSH` requires special cases that mirror what `navOpsE80` already does, that is a signal Phase 1's factoring needs another pass before proceeding to Phase 4.

The FSH spoke is also the first synchronous spoke, which exercises the bracket primitive's composition story on the easy case (its bracket is "return from function"; `servicesForCmd` returns `[]` and the outer bracket closes on the first quiescence tick).

---

## Current State Notes (from pre-Phase 1 inventory)

- `winFSH.pm` exists and is largely wired (`apps/navMate/winFSH.pm`, ~1000 lines, inherits from `winTreeBase`). Full tree population (`_buildGroups`, `_buildRoutes`, `_buildTracks`), tree selection, map visibility integration, save handler.
- **Context menu stub at `winFSH.pm:946`** -- currently just `Show on Map` / `Hide on Map`. Phase 3A replaces this with a real menu via the `get*MenuItems` pattern.
- `navFSH.pm` exists (`apps/navMate/navFSH.pm`) with `loadFSH` / `saveFSH` / `convertToNavMate` / `getFSHDb` / `getFilename`. The existing FSH-to-navMate path through `convertToNavMate` is a lower-level utility; navOpsFSH does not replace it.
- FSH parsing modules are comprehensive: `apps/raymarine/FSH/fshFile.pm`, `fshBlocks.pm`, `fshUtils.pm`, `fshConvert.pm`, `kmlToFSH.pm`, `genKML.pm`, `genGPX.pm`. The FSH writer enforces name<=15 / comment<=31 (errors on oversize per [[fsh-name-comment-limits]]).

---

# Phase 3A -- winFSH Wiring + DB<->FSH

## Locked design decisions (from scope discussion, 2026-05-16)

| Decision | Choice |
|---|---|
| Phase 3A scope | Intra-FSH (Delete/Cut/Copy/New) + DB->FSH (Paste/PasteNew/Push) + FSH->DB (Paste/PasteNew/Push). E80<->FSH deferred to 3B. |
| FSH file save timing | Explicit user save. navOps mutations modify `$navFSH::fsh_db` in memory; the `.fsh` file is written only via the existing `Save FSH` menu command. |
| ProgressDialog for FSH | Skip entirely. Synchronous ops complete in one wx idle tick; emit only BRACKET_START/BRACKET_FINISH log lines. `servicesForCmd` returns `[]` for FSH-only ops so the outer bracket closes on the first quiescence tick. |
| navOps_spoke_contract.md | Write during this phase. Update `navOperations.md` and `design_vision.md` to cross-reference. |

## Activities

1. **Split the phase doc** (this rewrite).
2. **`navOpsFSH.pm` (new)** -- mirror navOpsE80.pm structure (continues package `navOps`, loaded via `require` from `navOps.pm`). All operations work synchronously on `$navFSH::fsh_db`; never write the `.fsh` file.
3. **`navClipboard.pm`** -- add `panel=fsh` cases to each `get*MenuItems` function. Refactor `getPushMenuItems` for three-panel reality.
4. **`navOps.pm`** -- add fsh branches at every panel-switch point (_snapshotNodes, _resolveContextNode, _doDelete, _doPaste, _doNew, _doPush, servicesForCmd, _preflightLossyTransform).
5. **`winFSH.pm`** -- replace context-menu stub at line 946; add EVT_MENU bindings; rewrite onTreeRightClick to collect multi-selection; add onContextMenuCommand method.
6. **`apps/navMate/docs/navOps_spoke_contract.md` (new)** -- the abstraction validated by second implementation.
7. **Doc updates** -- navOperations.md, design_vision.md, winFSH_design.md; nav headers across all `apps/navMate/docs/*.md`.

## Out of scope for Phase 3A (deferred to 3B or later)

- E80<->FSH cross-panel ops (Phase 3B).
- PASTE_NEW import path UUID remapping polish (separate design discussion per [[navfsh_strategic_direction]]).
- `convertToNavMate` disposition (the existing FSH track segmentation in `navFSH.pm` is left untouched; remains a lower-level utility).
- FSH testing in the runbook (Phase 4 work).
- `$ACTIVE_BLOCKS_ONLY` deleted-items support (orthogonal to navOps; per `winFSH_design.md`).

## Phase 3A Completion Criteria

(Status as of 2026-05-16: implementation landed; Patrick to perform Verification list from claude-plan to confirm end-to-end.)

1. **[DONE]** `navOpsFSH.pm` exists, implements the spoke contract, intra-FSH and DB<->FSH operations land in `$navFSH::fsh_db`.
2. **[DONE]** winFSH has full navOps context-menu support via `navOps::buildContextMenu('fsh', ...)`; right-click presents Delete/Copy/Cut/Paste/Push/New per node type. Show/Hide on Map preserved as winFSH-local appendage.
3. **[DONE]** `get*MenuItems` in `navClipboard.pm` accept `panel='fsh'` and produce correct menu items for FSH node types. `getPushMenuItems` refactored to take a peer-state hash `$peers = { wpmgr => ..., fsh_db => ... }`; DB panel can now offer both `Push to E80` and `Push to FSH`.
4. **[DONE]** navOps dispatch points (`_doDelete`/`_doPaste`/`_doNew`/`_doPush`/`_snapshotNodes`/`_resolveContextNode`) route fsh correctly. `_destIsDescendantOfClipboard` converts FSH UUIDs at the clipboard seam.
5. **[DONE]** UUID normalization seam documented in spoke contract; enforced via `fshToNavUUID`/`navToFSHUUID` helpers in `navFSH.pm`, called from `_snapshotFSHNode` (in) and every paste/push handler in `navOpsFSH.pm` (out). `_classifyE80Items` renamed to `_classifyAgainstDB` and called for both `e80`- and `fsh`-source clipboards.
6. **[DONE]** `_preflightLossyTransform` extended with `db_to_fsh` and `fsh_to_db` directions (same E80 constraints; FSH inherits identical name/comment limits and color palette).
7. **[DONE]** `apps/navMate/docs/navOps_spoke_contract.md` written; nav headers in all `apps/navMate/docs/*.md` updated to link it. `navOperations.md` mentions FSH as third spoke and links to spoke contract; `design_vision.md` hub-and-spoke section reflects FSH landed.
8. **[DONE]** `apps/navMate/docs/notes/winFSH_design.md` updated with the Phase 3A navOps wiring section.
9. **[VERIFY]** Save FSH round-trip (mutate via navOps, Save FSH, close, reload, verify changes persisted) -- mechanical verification by Patrick.
10. **[DONE]** This phase doc updated -- see Build Notes and Documented Limitations sections below.

---

## Phase 3A Build Notes (2026-05-16)

Implementation summary; what's in this section is durable post-Phase-3A truth supplementing the Activities and Completion Criteria above.

### Files

- **New:** `apps/navMate/navOpsFSH.pm` (~700 lines), `apps/navMate/docs/navOps_spoke_contract.md`.
- **Modified:** `apps/navMate/navOps.pm` (FSH branches at every panel-switch point; helper additions `_fshDb`, `_refreshFSH`, `_snapshotFSHNode`, `_fshWpClipData`, `_resolveFSHNodeByUUID/Name`, `_routeMembersMissingAtSpoke`, `_spokeNameAndUUIDSets`; `servicesForCmd` extended with `$panel`, `$clipboard_source`); `apps/navMate/navOpsDB.pm` (22-site replacement `$source eq 'e80'` -> `($source eq 'e80' || $source eq 'fsh')` so FSH-source clipboards reuse the same DB write path as E80-source); `apps/navMate/navClipboard.pm` (panel=fsh cases across all `get*MenuItems`; `getPushMenuItems` peer-state refactor; `_classifyE80Items` renamed to `_classifyAgainstDB` with FSH-source coverage); `apps/navMate/winFSH.pm` (navOps wiring: `use navOps`/`use navClipboard`, `EVT_MENU_RANGE(10200, 10299)`, rewritten `onTreeRightClick`/`_buildContextMenu`, new `_onNmOpsCmd`); `apps/navMate/navFSH.pm` (exported `fshToNavUUID` / `navToFSHUUID` helpers); `apps/navMate/n_defs.pm` (new `$CTX_CMD_PUSH_FSH = 10251`).
- **Doc updates:** `apps/navMate/docs/navOperations.md` (spoke contract link + FSH mention in module paragraph + `panel=fsh` in test entry points); `apps/navMate/docs/notes/design_vision.md` (FSH spoke landed in hub-and-spoke section + spoke contract link); `apps/navMate/docs/notes/winFSH_design.md` (Phase 3A wiring section); nav headers in all 8 `apps/navMate/docs/*.md` files (architecture, data_model, ge_notes, implementation, kml_specification, navOperations, readme, ui_model).

### Architectural choice: identity normalization at the snapshot seam

Clipboard items always carry navMate no-dash lowercase UUIDs. The conversion happens in exactly two places per spoke: `_snapshot<Spoke>Node` (in -> canonical) and the spoke's paste/push handlers (canonical -> out). This is the single design rule that lets `navOpsDB.pm`'s 22 `$source eq 'e80'` checks generalize to `($source eq 'e80' || $source eq 'fsh')` with no semantic surprises -- by the time items reach the DB write path, they look identical regardless of which spoke they came from.

### Architectural choice: getPushMenuItems peer-state refactor

The old signature `getPushMenuItems($panel, $wpmgr, @nodes)` baked in the two-panel assumption: the only "other side" was E80. With three panels, the DB panel can offer two distinct push directions (`Push to E80` and `Push to FSH`), and FSH panel adds a third (`Push to DB`). The new signature `getPushMenuItems($panel, $peers, @nodes)` where `$peers = { wpmgr => ..., fsh_db => ... }` accommodates this without coupling navClipboard.pm to specific spoke modules. `CTX_CMD_PUSH_FSH = 10251` disambiguates the two DB-panel push cmd IDs.

### Architectural choice: synchronous spoke means no inner brackets, no progress dialog

`servicesForCmd($cmd_id, $panel, $clipboard_source)` returns `[]` for FSH-only operations (FSH panel selection with no E80 involvement, or DB-panel `CTX_CMD_PUSH_FSH`). The outer bracket from `navOpsBracket.pm` therefore closes on the first quiescence tick after the synchronous mutation returns. No `Pub::WX::ProgressDialog` is opened for FSH ops -- the operation completes in one wx idle tick, so the dialog would just flash on and off.

The cross-check between dialog step-count and NET-layer quiescence (the design rationale for keeping both primitives in [navops_bracketing_via_quiescence]) is therefore degenerate for synchronous spokes: there's nothing to cross-check because there's no step-count sync. The OUTER bracket alone is the operation marker.

### Architectural choice: FSH group / route data shape requires per-handler embed logic

E80 groups carry `{uuids => [bare-WP-uuid-strings]}` referencing the global `$wpmgr->{waypoints}` hash. FSH groups carry `{wpts => [full embedded WP records]}` directly inside the group block -- the FSH binary format embeds member WP records inside the group block rather than referencing them. Same shape difference for routes.

This means FSH-spoke paste handlers `_pasteGroupToFSH`, `_pasteRouteToFSH`, `_pasteBeforeAfterFSH` must construct embedded WP records (not just append a UUID to a list). The helpers `_buildFSHWpRecord` and `_findFSHWPRecord` handle the construction and lookup. Routes that already exist in FSH get their `{wpts}` array reassigned wholesale (not spliced) because `threads::shared` arrays don't support splice -- the copy/splice/reassign idiom is used throughout (see [feedback_shared_arrays]).

### Save FSH timing

navOps mutations land in `$navFSH::fsh_db` in memory only. The `.fsh` file is never written by an op. The user persists by invoking the existing `Save FSH` menu command in winFSH (which calls `navFSH::saveFSH(...)`). Locked decision; rationale in the plan's "Locked design decisions" table.

---

## Phase 3A Documented Limitations

### DB->FSH track paste/push not supported

`_pasteTrackToFSH` logs a warning and skips. Constructing FSH `BLK_TRK`/`BLK_MTA` blocks from DB track points requires the segmentation and sentinel-insertion logic that `kmlToFSH.pm` uses (where sentinel points mark segment breaks). The full FSH track encoding is out of scope for Phase 3A. FSH->DB tracks DO work through `_pasteDB`'s existing track handling, which accepts the snapshot's `points` array directly.

### FSH-source timestamps not carried into DB via push

`_pushFromE80` (which `_pushFromFSH` delegates to) populates DB `created_ts` from `$wp->{created_ts} // $wp->{ts}`. FSH-source clipboard items carry `{date}` and `{time}` (days/seconds form) but no unified `ts` or `created_ts`. The push path therefore falls back to the existing DB record's `created_ts`, losing the FSH-provenanced timestamp.

This is the enrichment direction Patrick called out in [navfsh_strategic_direction] as a future surgical operation; Phase 3A treats it as out of scope. The path forward is either a `_pushFromFSH` that doesn't delegate (does its own DB update converting FSH date/time -> unix ts before update), or extending `_snapshotFSHNode` to synthesize `$wp->{ts}` from `$wp->{date}*86400 + $wp->{time}` before the snapshot leaves the spoke. The latter is cleaner; deferred so it can be designed alongside the enrichment UI rather than baked in here.

### ts_source not distinguished for FSH

DB rows imported from an FSH source get `ts_source = 'e80'` (because navOpsDB.pm now treats FSH-source identically to E80-source). Semantically correct (FSH is archived E80 data) but loses the visible-in-DB signal that the row came specifically from an FSH archive rather than a live E80. Adding `$TS_SOURCE_FSH = 'fsh'` and routing through it would be additive but is deferred.

### winFSH editor edits do NOT route through navOps

The editor panel in winFSH (Save button at line 109, `_onSave` handler at line 691) mutates `$fsh_db` directly without going through navOps. This means in-place WP/group/route edits don't emit BRACKET_START/FINISH log lines and don't participate in the spoke contract's clipboard semantics. The intent for Phase 3A was wiring the CONTEXT MENU (Copy/Cut/Paste/Delete/New/Push); editor edits remain on the existing direct-mutation path. A future phase could route them through `_pushToFSH`-style helpers for consistency.

### Tests deferred to Phase 4

Per the locked plan structure, Phase 3A is feature-complete with only testing remaining. Phase 4 adds an FSH section to the existing UI-integration runbook and restructures the runbook for strict sectional independence (so iterative FSH-section re-runs are useful for finding 3A regressions). Phase 5 builds the bifurcated navOps-layer testplan.

---

# Phase 3B -- E80<->FSH (sketch)

## Phase Goal

Extend `navOpsFSH.pm` and the navOps dispatch chain to support cross-panel operations between E80 and FSH spokes. These must be composed pipelines through the navMate canonical hub (E80->navMate->FSH and reverse) -- no bespoke direct adapter.

## Activities (sketch)

- **Cross-spoke pipeline composition.** Determine where the canonical hub representation lives during a composed E80<->FSH op. Two candidates:
  - Materialize through the DB (one navOps op performs E80->DB followed by DB->FSH); side-effect: DB grows by the transit objects.
  - Materialize through an in-memory canonical structure (clipboard items already carry this representation in their normalized form); zero DB side-effect; only the source and destination spokes mutate.
  The clipboard-snapshot path already produces canonical-form items at the snapshot seam. E80->FSH paste can likely run as: snapshot from E80 (already in canonical form), then `_pasteAllToFSH(items)`. Same direction the existing DB->FSH paste runs.
- **`_classifyE80Items` generalization** -- the source-presence classifier (paste/push/mixed) currently only checks DB. For E80-source clipboards pasted to FSH (and vice versa) the same classification semantics apply but against FSH-db. Generalize the function to accept a destination-checker callback.
- **`servicesForCmd` for E80<->FSH ops** -- needs to include `['wpmgr', 'track']` since the E80 side is touched, even if the destination is FSH-only.
- **UI -- both winE80 and winFSH** -- ensure context menus offer cross-panel Push when appropriate (E80 selection -> FSH peer presence; FSH selection -> E80 peer presence).

## Phase 3B Completion Criteria

(Status as of 2026-05-16: implementation landed; Patrick to perform Verification.)

1. **[DONE]** E80->FSH Paste/PasteNew works; route through `_doPaste` -> `_pasteFSH` -> `_pasteAllToFSH` / `_pasteNewAllToFSH` with `$cb->{source} eq 'e80'`. Clipboard items are already canonical when they reach FSH paste handlers (Phase 1 snapshot seam) so no E80-specific transform needed here.
2. **[DONE]** FSH->E80 Paste/PasteNew works; route through `_doPaste` -> `_pasteE80` -> `_pasteAllToE80` / `_pasteNewAllToE80` with `$cb->{source} eq 'fsh'`. WPMGR/TRACK accept the items' canonical nav-form UUIDs directly. ProgressDialog renders for the E80-side activity per the existing E80 paste path.
3. **[DONE]** E80->FSH Push works via new `CTX_CMD_PUSH_FSH` on E80 panel; FSH->E80 Push works via new `CTX_CMD_PUSH_E80` on FSH panel. Both reuse the existing `_pushToFSH` / `_pushToE80` handlers since clipboard items are canonical.
4. **[DONE]** Cross-spoke cut-paste cleanup works: E80->FSH cut deletes from E80 via `_cutE80*`; FSH->E80 cut deletes from FSH via `_cutFSH*`. Centralized in `_cutPasteCleanupWp` / `_cutPasteCleanupGroup` / `_cutPasteCleanupRoute` (in navOpsFSH.pm); navOpsE80.pm's inline 2-way ternaries refactored to call these helpers.
5. **[DONE]** Hub-and-spoke discipline preserved: no direct E80<->FSH adapters introduced. Cross-spoke ops are composed via the canonical clipboard form -- the snapshot seam produces canonical items from E80, and the FSH paste handlers consume canonical items (and vice versa). The hub representation is in-memory in the clipboard for these ops (no DB writes required).
6. **[DONE]** `servicesForCmd` refined: FSH-panel ops set `touches_e80=1` for `CTX_CMD_PUSH_E80` and for cut-paste of an E80-source clipboard (E80-side cleanup needs to be waited on).
7. **[DONE]** Phase 3B section of this doc updated with Build Notes (below). Overall Phase 3 marked COMPLETE in `_navOps_rework_plan.md`.


## Phase 3B Build Notes (2026-05-16)

### Files

- **Modified:** `apps/navMate/n_defs.pm` (new `$CTX_CMD_PUSH_E80 = 10252`); `apps/navMate/navClipboard.pm` (CTX_CMD_PUSH_E80 in ALL_PASTE_CMDS; `getPushMenuItems` extended with cross-spoke cases; new `_e80NodesAllInFSH` and `_fshNodesAllInE80` presence checks); `apps/navMate/navOps.pm` (`dispatchNavOpsCommand` recognizes CTX_CMD_PUSH_E80; `_doPush` cross-spoke push dispatch; `_cmdLabel` for PUSH TO E80; `servicesForCmd` refined for FSH-panel cross-spoke ops); `apps/navMate/navOpsFSH.pm` (new `_cutFSHWaypoint` / `_cutFSHGroup` / `_cutFSHRoute` / `_cutFSHTrack` helpers; `_cutPasteCleanupWp/Group/Route` three-way dispatchers; FSH paste handlers call cut-cleanup); `apps/navMate/navOpsE80.pm` (four inline `$cb->{source} eq 'database' ? : ` ternaries replaced with `_cutPasteCleanupWp/Group/Route` calls).

### Architectural choice: canonical clipboard IS the hub for cross-spoke ops

Phase 3B's central insight is that the in-memory hub representation already exists -- it's the clipboard. The snapshot seam from Phase 1 converts spoke-storage form -> canonical (UUIDs normalized, lat/lon decimal, names canonical). FSH spoke handlers consume canonical and convert to FSH-storage at their boundary. E80 spoke handlers consume canonical and accept it directly (since canonical and E80 internal forms are nearly identical -- nav-form UUIDs and 1e7 scaling at the WPMGR record level, but the WPMGR API accepts decimal-degree lat/lon).

The result: E80->FSH paste is just `_pasteAllToFSH(items)` with items snapshotted from E80. FSH->E80 paste is `_pasteAllToE80(items)` with items snapshotted from FSH. No new code paths, no bespoke adapter -- the existing handlers compose with the existing snapshot/paste pipeline.

This is the hub-and-spoke discipline working as designed. The temptation in a 2-point system would have been to write `_e80ToFSHCopy` and `_fshToE80Copy` direct adapters. Resisting that and going through the canonical form means N adapters total, not N^2.

### Architectural choice: cut-cleanup centralized in three dispatchers

The pre-3B `navOpsE80.pm` had four sites with inline `$cb->{source} eq 'database' ? _cutDatabase* : _cutE80*` ternaries. Each site needed a third arm for 'fsh'. Rather than touching all four with the same regex, `_cutPasteCleanupWp` / `_cutPasteCleanupGroup` / `_cutPasteCleanupRoute` (in navOpsFSH.pm, package navOps) encapsulate the dispatch. The four E80 sites became one-line calls; new FSH paste handlers also call the same helpers; future spokes add a new arm to the dispatcher in one place rather than touching every paste handler.

This is the kind of cleanup that becomes possible only after a second implementation reveals the duplication.

### Architectural choice: no lossy transform for spoke<->spoke

E80 and FSH have identical constraints: name<=15, comment<=31, color is a byte index in the 0-5 palette. An E80-source item paste-able to E80 is automatically paste-able to FSH (and vice versa) -- the field values already satisfy both spokes' limits. So `_doPaste` skips `_preflightLossyTransform` for non-database sources, and `_doPush` for E80<->FSH push skips it too.

A future asymmetric spoke (e.g. one with shorter limits, or with a different color palette) would change this: it would need a `spoke_to_spoke` direction in `_preflightLossyTransform` that performs the appropriate checks.


## Phase 3B Documented Limitations

### Cross-spoke route paste between E80 and FSH

Inherits the SS10.10 rule from Phase 3A: route paste requires the route's member WP UUIDs to be present at the destination spoke OR in the current clipboard. For E80->FSH route paste, if the route's member WPs aren't already in FSH and aren't in the clipboard alongside the route, the paste rejects with the existing pre-flight message. The user must paste the WPs first (or include them in a multi-item copy).

The `_routeMembersMissingAtSpoke` helper (in navOps.pm) handles this for both spokes.

### Tracks not portable cross-spoke

Pasting tracks E80->FSH or FSH->E80 is not supported in Phase 3B for the same reason as DB->FSH track paste in Phase 3A: the binary track encoding requires sentinel-segmented point arrays via `kmlToFSH.pm`-style logic, out of scope for the rework. FSH->DB tracks DO work via `_pasteDB`'s existing track handling. E80 tracks are read-only via WPMGR/TRACK so DB->E80 tracks also don't work.

### `_pasteWaypointToE80` UUID-preserving update is in-place edit, not move

For E80-source-E80-dest cut-paste of a WP that's already in E80 (UUID-preserving PASTE), the existing flow updates the existing record in place, then `_cutPasteCleanupWp` deletes it. Net effect can be a no-op or even data loss depending on group membership. This is a pre-existing E80->E80 cut-paste quirk -- not introduced by 3B. Documented for completeness.

### winE80's `_pushFromE80` ts_source handling unchanged

Same limitation noted in 3A: for FSH-source items pushed to DB via `_pushFromFSH` (which delegates to `_pushFromE80`), `created_ts` falls back to the existing DB record's value because clipboard items carry `date`/`time` rather than `created_ts`/`ts`. The FSH date/time data isn't transferred. The enrichment direction Patrick called out as future surgical work would address this.

---

## Second-Implementation Validation Signals (applies to both 3A and 3B)

If any of the following arise during navOpsFSH implementation, Phase 1 needs another pass before Phase 4:

- A field or behavior is needed in navOps that does not exist or is silently E80-specific.
- The lossy-policy mechanism cannot express FSH's lossy-transform needs.
- The identity-normalization seam is insufficient for FSH's dashed-uppercase UUID format.
- The bracket primitive does not compose cleanly for synchronous file I/O.
- The context-object shape from Phase 1 needs FSH-specific fields.
- The `get*MenuItems` pattern needs structural change to accept `panel=fsh` rather than just additive cases.

Recording these signals as they arise (rather than working around them silently) is the value of this phase.

---

## Documentation Feedback (whole Phase 3)

- `apps/navMate/docs/navOps_spoke_contract.md` -- new, landed in 3A.
- `apps/navMate/docs/navOperations.md` -- panel=fsh in test entry points; spoke contract link; third spoke in module paragraph.
- `apps/navMate/docs/notes/winFSH_design.md` -- context menu wired up; spoke contract referenced.
- `apps/navMate/docs/notes/design_vision.md` -- hub-and-spoke section reflects FSH landed.
- Nav headers in every `apps/navMate/docs/*.md` updated to include the spoke contract link per the navMate doc-header convention.
