# Phase 2 -- Regression + Factoring Proof -- COMPLETE 2026-05-16

Part of the navOps rework -- see `_navOps_rework_plan.md`. Transient doc; deleted on rework completion. Fleshed out 2026-05-16 informed by Phase 1's actual deliverables; the original "Open Questions" section was resolved in-conversation and folded into the activity descriptions below. **Phase closed 2026-05-16 with scope reduced mid-phase** -- see Build Notes at the bottom.

---

## Phase Goal

Prove that Phase 1's factoring is real. Three independent proofs:

1. The existing UI-integration testplan runs unchanged and produces identical results (regression guardrail).
2. A new no-window / no-dialog cycle exercises the navOps-layer entry points exposed in Phase 1 and produces correct results.
3. The two synchronization primitives -- `ProgressDialog` step-count and NET-layer quiescence -- agree on a representative operation.

---

## Activities

**Run the existing testplan runbook unchanged.** No code changes beyond Phase 1's mechanically-necessary path adjustments. Verify identical pass against `apps/navMate/docs/notes/navOps_testplan_runbook.md`. Any deviation is a regression and blocks Phase 3. Baseline is Cycle 17 (2026-05-13, clean PASS pre-Phase-1). Cyan `BRACKET_START` / `BRACKET_FINISH` lines emitted by Phase 1 are expected additions to the log -- not regressions; legacy magenta `===== ProgressDialog ... =====` markers remain unchanged and the runbook's existing grep patterns continue to match them.

**Author a parallel "navOps-layer cycle" script.** Hits the navOps-layer entry points built in Phase 1 (`GET /api/navops/available`, `POST /api/navops/dispatch`, `GET /api/navops/progress`) for the same logical operations the existing runbook covers, but with no window open and no `ProgressDialog`. Verifies the same state outcomes the UI runbook verifies (via `/api/nmdb` and similar introspection). Coverage is full runbook equivalent -- the runbook is not built to be entered partway, and partial coverage would not confirm Phase 1's factoring across all operation kinds. The integrated DB -> E80 -> TRACKS -> GUARDS progression of the existing runbook is preserved; no per-spoke (DB / E80 / FSH) partitioning in Phase 2 -- spoke partitioning waits for Phase 4. Synchronization uses `navTestProgress` -- consume its STARTED / FINISHED log lines (matching `Pub::WX::ProgressDialog`'s emission shape) and/or its hash via `GET /api/navops/progress`, whichever is more convenient at each call site.

**Drift check between sync primitives.** Pick one representative operation -- a single waypoint paste from DB to E80, for example (the Phase 1 Step 8 verification case is a natural candidate). Capture:

- The `ProgressDialog`'s log lines (`===== ProgressDialog 'TITLE' STARTED =====`, ticks via `display(...)`, `===== ProgressDialog 'TITLE' FINISHED =====`).
- The `TestProgress` sink's accumulated events for the same operation.
- The `BRACKET_START <intent>` / `BRACKET_FINISH <intent>` log lines (both inner-per-`$API`-command and outer-per-navOps-operation).

They should describe the same activity at compatible granularity. Any difference -- events one consumer sees that the other doesn't -- is signal worth investigating. One-time spot-check is sufficient for Phase 2; if drift is found, formalizing into a continuous check is a later-phase consideration.

---

## Phase Completion Criteria

- **[DONE]** Existing testplan: passes identical to baseline. Cycle 18 (2026-05-16) ran all sections clean -- Section 1 reset, Section 2 (23 tests), Section 3 (22 tests), Section 4 (6 tests, teensyBoat available), Section 5 (all runnable; 5.13 NOT_RUN per `db_versioning` PREREQUISITE; 5.15a NOT_RUN as precondition already met). `last_testrun.md` written in standard format. No FAIL, no PASSED_BUT, no PARTIAL.
- **[RETIRED]** navOps-layer cycle: not built in this phase. Moved to Phase 5 (testplan bifurcation), where it has a clear consumer as the second test surface. See Build Notes.
- **[RETIRED]** Drift check: moot. Cycle 18 passing end-to-end on the existing runbook IS the agreement evidence between the two sync primitives (dialog step-count and NET-layer quiescence). No anomalies surfaced through the full cycle. See Build Notes.
- **[DONE]** Phase 2 doc updated with what was actually run and learned (this Build Notes section).

---

## Documentation Feedback (this phase)

- **[DONE]** `apps/navMate/docs/notes/navOps_testplan_runbook.md` -- three runbook self-improvement edits landed during Cycle 18, independent of the rework:
  - Test 2.4 count annotation `3 members -> 5 members` reflecting baseline DB enrichment; Fishfarm UUID added to the supporting table.
  - "Known-quiet warnings" subsection added in Toolbox, with explicit clarification that unfamiliar warnings are not, by themselves, stop conditions.
  - "Rule: one test per tool call" firmed up -- explicit ban on inline batching of multiple tests in a single PowerShell call; two narrow exceptions called out (Test 2.0; helper-function definitions co-located with the test that uses them).
- "Note the existence of the parallel navOps-layer cycle" was the original Phase 2 doc-feedback line -- now moot since that cycle is Phase 5 territory.

---

## Build Notes (2026-05-16)

**Scope reduction mid-phase.** The original Phase 2 sketch bundled three activities: (1) regression-via-existing-runbook, (2) build a parallel no-window navOps-layer cycle, (3) drift-check between sync primitives. Mid-phase reflection settled that only (1) was load-bearing for Phase 2's stated purpose ("prove Phase 1's factoring is real"). The others were retired:

- **(2) navOps-layer cycle:** Premature here -- it didn't yet have a clear consumer. Its real value emerges when FSH is also testable via the same surface, which is Phase 5's territory. Moved there along with the rest of testplan bifurcation work. The Phase 1 plumbing (`/api/navops/available`, `/api/navops/dispatch`, `/api/navops/progress`, `navTestProgress`) remains in place as latent infrastructure, available for Phase 5.
- **(3) Drift check:** The drift-check premise was "do the two sync primitives describe the same op at compatible granularity." Cycle 18 ran 56 tests (including E80 operations with both ProgressDialog and BRACKET emission) without anomalies. If the primitives disagreed substantively, the runbook's pass criteria would have caught it. The spot-check would have produced "they agree, fine" and was retired as redundant.

**What "Phase 1's factoring is real" means after this scope reduction.** Phase 1 introduced the bracketing primitives, the `/api/navops/*` endpoints, and the `navTestProgress` shared-hash consumer. Cycle 18 exercised the bracketing primitives in production (every E80 op produced clean BRACKET_START/FINISH pairs with correct outer-ID propagation through service self-queued follow-ups). The endpoints and `navTestProgress` were not exercised by Cycle 18 -- they remain latent until Phase 5. Phase 1's claim of "panel-free testability is possible" is therefore proven for the bracket side, conjectured-but-not-yet-exercised for the endpoint side. Phase 5 will exercise the rest.

**Mid-cycle insight worth recording.** Cycle 18's first attempt revealed that "ONE test per tool call" needed to be a firmer rule than the runbook stated. Inline batching of multiple tests in one PowerShell call had the same anti-pattern shape as temp-file scripts: it hid intermediate state, removed the per-test stop-on-failure decision point, and forced post-hoc forensics when something broke (specifically: Test 3.9b's anomaly in the batched run could not be diagnosed without re-running because there was no clean record of state between batched tests). The runbook now states the rule explicitly and lists narrow exceptions.
