# Phase 1 -- navObjectsRefactoring + NET-Layer Bracketing

Part of the navOps rework. See `_navOps_rework_plan.md` for the overall structure and rules. This document is transient (`_` prefix); will be deleted when the rework is complete.

This phase doc starts detailed because Phase 1 is the next phase to be executed. Phases 2-5 start as sketches and are fleshed out before their respective execution sessions, informed by what earlier phases actually delivered.

---

## Phase Goal

Establish the data-layer separation and the second synchronization primitive that make the remainder of the rework possible. After this phase:

- navOps operations can be invoked, and their outcomes verified, without any wx window being open and without the `ProgressDialog` being involved.
- The existing `ProgressDialog` continues to function unchanged when present (regression guardrail).
- `d_WPMGR` and `d_TRACK` emit a NET-layer quiescence signal that bounds each asynchronous operation.
- The wx-panel coupling is reduced to its actual minimum: panels still synthesize selection sets from user interaction, but a parallel synthesis path exists for test contexts.

---

## Current State (from pre-Phase 1 inventory)

The current code is **already much closer to the target shape than initially assumed**. Three key facts shape the phase scope:

**1. The `get*MenuItems` family is already panel-agnostic.** `navClipboard.pm:157-422` defines `getNewMenuItems`, `getDeleteMenuItems`, `getCopyMenuItems`, `getCutMenuItems`, `getPasteMenuItems`, `getPushMenuItems`. Each takes a panel-kind string label (`'e80'` / `'database'`) and data-hash node descriptors; each returns an array of `{ id, label }` hashes. No wx, no panel object, no tree widget. They read only from `$clipboard` (module-level state) and the input arguments.

**2. `_snapshotNodes` and the snapshot helpers are panel-agnostic.** `navOps.pm:261-328` (`_snapshotNodes`), `:331+` (`_snapshotDBNode`), `:437+` (`_snapshotE80Node`). All take a panel-kind string label and data-hash nodes. They read from in-memory NET-side service state (`_wpmgr()`, `_track()`) and from the DB (`connectDB()`), NOT from any panel object. Ordering for header-level groupings comes from `sort keys %{$wpmgr->{groups}}` etc. -- already in the data layer.

**3. `$progress` is a shared hash, not a method-callable object.** `Pub::WX::ProgressDialog::newProgressData` (`Pub/WX/Dialogs.pm:209`) creates a shared hashref. Services in `d_WPMGR.pm`, `d_TRACK.pm`, and `e_wp_api.pm` mutate this hash directly. The dialog (`Pub::WX::ProgressDialog`, `Pub/WX/Dialogs.pm:178+`) polls the hash to render. No method dispatch.

**What IS wx-panel-coupled today:**

- The selection set entering `_snapshotNodes` is gathered by the wx panel from tree selection state.
- The right-click node entering `buildContextMenu` / dispatch is the wx tree node the user right-clicked.
- The test runner (`navTest.pm:101-108`) resolves `panel=database` / `panel=e80` to a wx pane via `findPane($WIN_DATABASE)` / `findPane($WIN_E80)` and warns/returns if no pane is open. All non-pure-ops dispatch requires a live wx tree.
- The `ProgressDialog` instance is constructed by navOps code (e.g. `navOpsE80.pm:126-131`, `nmFrame.pm:519`, `:551`, `:740-742`).
- `refresh()` after operations is panel-method-driven.

So the actual panel-coupling Phase 1 needs to break is **at the dispatch entry point and the selection-synthesis step**, not throughout navOps.

---

## Driving Principles

Decisions that govern all work in this phase. Specific actions in the Scope section follow from these.

- **Two-level bracketing.** OUTER bracket per navOps context-menu operation; INNER bracket per `$API` command in `d_WPMGR` / `d_TRACK`. One level of nesting; no inner-inner.
- **Quiescence interval T = 1 second** for both inner and outer detectors. Tunable per spoke; the cascade case (group / route follow-ups) sets the floor.
- **Single navOps dispatch entry point.** `dispatchNavOpsCommand($context, $cmd_id)` is invoked by both the wx EVT_MENU path (via `onContextMenuCommand`) and the HTTP path (via `/api/navops/dispatch`). The outer bracket lives inside this function.
- **Outer-bracket sensing in `navOpsBracket.pm`**, ticked from `nmFrame.pm:_onIdle` on the main wx thread. Same thread as `dispatchNavOpsCommand` and all existing pollers -- no race between open and tick.
- **Outer-quiescence close-time formula.** `close_time = max(outer_start_ts, last_send_ts and last_event_ts across services_touched)`. Outer closes when `now - close_time > T`. The `outer_start_ts` floor keeps the outer open for at least T after start regardless of whether any service was touched.
- **`services_touched` is static.** Passed by navOps at outer-start (knowable from the `cmd_id`). Dynamic per-service registration is not in scope; promote only if static lists become unmaintainable.
- **Cross-layer propagation via `$progress`.** navOps populates `$progress->{outer_intent}` and `$progress->{outer_id}` at outer-start; services read them when emitting inner brackets. No new parameter threading; `$progress` is already the cross-layer carrier.
- **Bracket intent is a free-form string.** Inner = `$API` command description (e.g. `create waypoint SomeWP`); outer = navOps operation description (e.g. `paste_group_to_e80 [GroupName]`).
- **Emission format**: `BRACKET_START <intent>` / `BRACKET_FINISH <intent>` via `display(...)`. Inner-bracket lines include `(outer=<id>)` for log-side correlation.
- **TestProgress emits STARTED / FINISHED log lines** matching `Pub::WX::ProgressDialog`'s emission (`Pub/WX/Dialogs.pm:279` / `:292`). Per-tick events are API-queryable; NOT logged.

---

## Scope

### In-Scope

**1. Selection-context synthesis.** Add a function (location TBD inside `navOps.pm` or a new sibling) that maps a panel-kind label plus `[Name]` / `rp:[Route]:[RP]` selection keys to a data-hash `@nodes` list by reading `_wpmgr()` (`navOps.pm:50`) / `_track()` (`:55`) / `connectDB()`. Mirrors what `navTest.pm:_walkSelect` (`:166`) does for wx trees but operates on the underlying service / DB state. Selection-key syntax reused verbatim from `navTest.pm:_getNodeKey` (`:145-156`). Output feeds `_snapshotNodes` (`navOps.pm:261`) and `buildContextMenu` (`navOps.pm:91`) unchanged.

**2. HTTP endpoints in `navServer.pm`**:

- `GET  /api/navops/available?panel=...&select=...&right_click=...` -- returns the merged `get*MenuItems` output for the synthesized context.
- `POST /api/navops/dispatch`, body `{ panel, select, right_click, cmd, suppress?, intent? }` -- invokes `dispatchNavOpsCommand`.
- `GET  /api/navops/progress?intent=...` -- returns the `TestProgress` hash contents for the named intent.

**3. New `navOpsBracket.pm` module.** State and tick management for outer brackets.

- `bracketOuterStart($intent, \@services_touched) -> $outer_id` -- registers a new outer bracket; emits `BRACKET_START <intent>`; returns a unique id.
- `bracketOuterTick()` -- iterates active outer brackets; closes any whose `now - close_time > T` is satisfied.
- `bracketOuterFinish($outer_id)` -- emits `BRACKET_FINISH <intent>`; removes from active set.
- State: `threads::shared` hash `{ outer_id => { intent, start_ts, services_touched, last_observed_activity } }`.

**4. Refactor `navOps.pm:onContextMenuCommand`.** Extract the `cmd_id` -> `_do*` switch into a new `dispatchNavOpsCommand($context, $cmd_id)`.

- `onContextMenuCommand` becomes a thin wx-side wrapper: synthesize `$context` from the tree + right-click state, call `dispatchNavOpsCommand`.
- `dispatchNavOpsCommand` body:
  1. Form outer intent: `_cmdLabel($cmd_id)` (existing at `navOps.pm:1134`) + selection summary.
  2. Determine `services_touched` from `$cmd_id` (lookup table; expressed alongside the `_cmdLabel` definitions).
  3. Open outer: `$outer_id = bracketOuterStart($intent, \@services_touched)`.
  4. Populate `$progress->{outer_intent} = $intent; $progress->{outer_id} = $outer_id;` -- create `$progress` if absent.
  5. Dispatch the `_do*` for `$cmd_id`.
  6. Outer closes asynchronously via `bracketOuterTick`; no explicit close call here.

**5. Inner-bracket detection in `d_WPMGR.pm` and `d_TRACK.pm`**:

- Add `last_send_ts` field; update at `queueWPMGRCommand` (`d_WPMGR.pm:110`) / `queueTRACKCommand` (`d_TRACK.pm:169`).
- Add `last_event_ts` field; update inside `handleEvent` (`d_WPMGR.pm:584`, `d_TRACK.pm:888`) and `handleCommand` (`d_WPMGR.pm:507`, `d_TRACK.pm:862`).
- For each `$API` command, emit `BRACKET_START <api-intent> (outer=<id>)` on initiation; emit `BRACKET_FINISH <api-intent> (outer=<id>)` when `now - max(last_send_ts, last_event_ts) > T`.
- `<api-intent>` formed from the API command name and its arguments (e.g. `create waypoint SomeWP`).
- `<id>` read from `$progress->{outer_id}` if present, else `none`.
- Inner-bracket close fires from the same `_onIdle` tick that drives outer detection (simplest), unless implementation finds a per-service timer cleaner -- decide during implementation.

**6. Wire `bracketOuterTick()` into `nmFrame.pm:_onIdle`** alongside `pollTestCommand`, `pollBrowserConnectEvent`, etc. (`nmFrame.pm:141+`).

**7. New `TestProgress` module** (location TBD; sibling to navOps modules):

- Constructor creates a `threads::shared` hash with the same key shape `Pub::WX::ProgressDialog::newProgressData` (`Pub/WX/Dialogs.pm:209`) produces: `{ total, done, label, error, cancelled, workers }`.
- Emits `===== TestProgress 'TITLE' STARTED =====` on construction; `===== TestProgress 'TITLE' FINISHED =====` on close. Matches `Pub/WX/Dialogs.pm:279` / `:292`.
- Accessors expose hash contents for `GET /api/navops/progress`.
- Used in lieu of `Pub::WX::ProgressDialog` when no wx UI is rendering. Services don't know the difference -- they mutate whatever hash they're handed via `$progress`.

**8. Existing testplan path adjustments** in `navTest.pm` and the runbook -- only where mechanically necessary (e.g. accommodating new dispatch routing). No semantic refactor.

### Out-of-Scope (deferred)

- Bifurcating the testplan into two surfaces and three branches (Phase 4).
- Building the FSH spoke (Phase 3).
- Authoring test entries for the new navOps-layer surface (Phases 2, 4, 5).
- Refactoring `_snapshotNodes`, `get*MenuItems`, the `_do*` family -- already panel-agnostic per Current State.
- Production-multi-client quiescence behavior (test-mode-safe is sufficient for this phase).
- Dynamic per-service registration into the outer bracket.
- Direct API observation of outer-bracket state (e.g. `GET /api/navops/bracket?intent=...`). Reconsider if Phase 2 finds it useful.

---

## Documentation Feedback (this phase)

Update on landing:

- `apps/navMate/docs/notes/design_vision.md` -- reflect the hub-and-spoke formalization and the two-sync-primitive model.
- `apps/navMate/docs/navOperations.md` -- update with the new entry points and the two-sync model; this is an official doc.
- `apps/navMate/docs/notes/navOps_testplan.md` -- minimally, only where text describes panel-required dispatch that no longer holds.
- A new official doc capturing the **navOps spoke contract** -- the abstraction `navOpsFSH` will implement in Phase 3. Location TBD (likely a new doc in `apps/navMate/docs/`).

---

## Risks

- **Hidden bracket-semantic shift.** If `TestProgress` captures events the `ProgressDialog` ignores (or vice versa), regression tests may pass while step-count contracts silently drift. Mitigation: Phase 2's eyeball comparison of dialog log lines versus `TestProgress` events for a representative operation.
- **Quiescence false-close.** T too short closes brackets while events are still trickling in. Mitigation: 1 s is the conservative starting value; tune down only when comparison with step-count sync shows no drift.
- **Test-mode-safe vs production.** Quiescence equals *our* op completing only when no other client touches the E80. Production with multiple clients sees closes on anyone's quiescence. The detector is safe to leave on in production but `BRACKET_FINISH`-as-"our op finished" interpretation is test-mode-only.
- **Selection-synthesis API friction.** If endpoints are awkward to write tests against, they won't get used. Reusing `[Name]` / `rp:[Route]:[RP]` from `navTest.pm` is the primary mitigation.

---

## Phase Completion Criteria

1. Selection-context synthesis function exists; produces a valid data-hash `@nodes` list from `[Name]` / `rp:[Route]:[RP]` keys plus panel kind, with no wx involvement.
2. `GET /api/navops/available` returns expected menu items for synthesized contexts.
3. `POST /api/navops/dispatch` invokes `dispatchNavOpsCommand` and reaches `_doCopy` / `_doCut` / `_doPaste` / `_doDelete` / `_doPush` / `_doNew` for the appropriate `cmd_id`s.
4. `dispatchNavOpsCommand` is the single entry point used by both `onContextMenuCommand` (wx) and `/api/navops/dispatch` (HTTP).
5. `navOpsBracket.pm` emits `BRACKET_START <intent>` / `BRACKET_FINISH <intent>` for each navOps context-menu operation; `bracketOuterTick` is wired into `nmFrame.pm:_onIdle`. T = 1 s.
6. `d_WPMGR` and `d_TRACK` emit `BRACKET_START <api-intent> (outer=<id>)` / `BRACKET_FINISH <api-intent> (outer=<id>)` for each `$API` command, with `outer_id` correctly propagated via `$progress`.
7. `TestProgress` module exists, emits STARTED / FINISHED log lines, exposes hash contents via `GET /api/navops/progress`, and substitutes for `Pub::WX::ProgressDialog` in panel-free invocations without service-side changes.
8. The existing testplan runbook still runs to completion with identical results (regression guardrail) -- formally proved in Phase 2 but checked locally during Phase 1 development.
9. Official docs listed in "Documentation Feedback" have been updated.
10. This phase doc has been updated to reflect what was actually built, with deviations from initial sketch documented inline.
