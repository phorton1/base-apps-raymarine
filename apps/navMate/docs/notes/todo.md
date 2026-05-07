# navMate Todo

[name] identifiers cross-reference open_bugs.md, design_vision.md, or docs/
where those hold canonical context. Items without a canonical home carry their
own context here.

---

## Next


### [Rework operations system]

`nmOperations.md` to document the new scheme in full has been written.
**Write nmOps_testplan.md** -- DONE. Written to docs/notes/nmOps_testplan.md.
The implementation phase is in progress —


1. Feature Implementation in progress
 **Finish nmOperations HTTP api for automated testing** -- concrete changes
   required before nmOps_testplan.md can be fully executed. See also nmOps_testplan.md
   §Infrastructure (suppress mechanism) and §5 (PREREQUISITE markers).
   - **$suppress_outcome control** -- extend `/api/test?op=suppress` with an
     `outcome=accept|reject` parameter. When `outcome=reject`, suppressed two-outcome
     dialogs take the reject/abort path instead of the default accept/proceed. Required
     by testplan §5.8 (ancestor-wins abort), §5.13 (UUID conflict abort). Without this,
     those tests hang waiting for user input. Affects: nmDialogs.pm ($suppress_outcome
     shared var), nmTest.pm HTTP handler, and each two-outcome dialog call site:
       - Ancestor-wins confirmation (SS6.2): accept=proceed, reject=abort paste
       - UUID conflict choice (SS10.10): accept=skip+continue, reject=abort all
       - E80 DEL-WP route-ref warning (SS8.2): accept=proceed+remove refs, reject=abort
   - **Route point key in nmTest.pm tree walker** -- confirm `rp:ROUTE_UUID:WP_UUID`
     resolves correctly in the programmatic tree walker. Required by §2.14 and §3.16.
   - **PASTE_BEFORE/AFTER dispatch** -- confirm CTX_CMD 10302-10305 are handled by
     nmTest.pm dispatch and routed to nmOps.pm. These constants have no predecessor in
     the old context_menu system and may not yet be wired in nmTest.pm.
   - **Ancestor-wins dialog through suppress** -- the new SS6.2 confirmation dialog must
     route through $suppress_confirm so that suppress=1 auto-accepts without blocking.
     Without this, any paste with ancestor-wins resolution hangs (testplan §5.7).
   - **UUID conflict dialog through suppress** -- SS10.10 conflict choice dialog must
     route through $suppress_confirm. Without this, E80 paste conflict paths hang.
   - **E80 Tracks header Delete** -- verify SS8.2 right-click header:tracks Delete is
     implemented (new capability; not in old context_menu design). Required by §3.8.
   - **showError modal suppress** -- `Pub::Utils::error()` calls
     `$app_frame->showError($use_frame, "Error: ".$msg)` which produces a blocking
     modal wx dialog. This dialog is NOT in the current $suppress_confirm chain. Any
     error() call from NET protocol handlers, c_db.pm, or any other module during a
     test step will halt the test run with an undismissable modal -- even if the error
     is non-catastrophic and the ring buffer already shows the message. Fix: add a
     shared variable (e.g. $suppress_error_dialog in nmDialogs.pm, alongside
     $suppress_confirm) and check it in the navMate app frame's showError override.
     When suppressed, skip the modal but keep the ring buffer log entry so Claude can
     still see the error. Wire to the existing suppress HTTP endpoint: op=suppress&val=1
     sets both $suppress_confirm and $suppress_error_dialog together (they should always
     travel as a pair during automated testing). The distinction from $suppress_confirm:
     this covers the Pub::WX::Frame error path; $suppress_confirm covers navMate-level
     dialogs.
2. **write new runbook** - write the runbook for claude to test, similar
   to previous runbook, including handling or $progress dialogs, completely
   informed api usage, no flailing, which writes last_testrun.md at a cycle completion.
3. **iterate through testplan** - alpha run(0) ... stop on each issue and
   resolve inline - no last_test run developed.  beta runs(n) - iterate
   on full-cycle basis, resolving issues.  digression_teet(0) - run completly
   with all passes, no issues, no code gaps.





## Soon



### [db_version increment wiring]
See design_vision: [E80 sync / versioning system].

### [synchronization color scheme]
Between winDatabase and winE80 highlight common "same" items in bold blue,
"older items" in bold magenta, and newer items in "bold green" via inter-window
analaysis. See design_vision: [E80 sync / versioning system].

### [synchronization operations]
Implement "sync->E80" and "sync<-DB" menu commands to synchronize
out of date items in one-step directional manner.
See design_vision: [E80 sync / versioning system].


### [INSERT position assignment]
INSERT functions do not yet assign `position` for new items -- they land at 0
and sort to the top. Functions to update: `insertCollection`,
`insertCollectionUUID`, `insertWaypoint`, `insertRoute`, `insertTrack`.
Pattern: `SELECT COALESCE(MAX(position), 0) + 1 FROM <table> WHERE <scope>=?`

### [Second $db_def default discrepancy]
A second field default in c_db.pm `$db_def` differs from what the database
actually holds. Not yet identified. Resolve in favor of the database (same
as the wp_type fix).

### [winDatabase reordering UX]
Add reorder capability to winDatabase for items in the navMate database.
Scope is narrow: navMate DB reordering only -- no E80 sync or visibility
tie-in. Schema 10.0 added `position REAL` to collections, waypoints, routes,
and tracks; the storage foundation is in place. UI implementation needed.
See `[item ordering UI]` in design_vision.md for design context.

### [WPMGR post-delete GET_ITEM error fix]
Known fix — see open_bugs.md. One-liner in the GET_ITEM/waitReply failure
path for 'mod_item' commands.

### [E80 tree display sort order]
Confirm and implement E80 tree display ordering in winE80 tree population.
The E80 does not support persistent positional ordering for these collections;
sort is display-layer only:
- Groups folder children: by Group Name, with My Waypoints floated to top
- Routes folder children: by Route Name
- Tracks folder children: by Track Name
- Waypoints within a Group: by Waypoint Name
Sub-sort rule: names ending in a digit sequence sort numerically on the digit
suffix, not lexically (e.g. "WP2" < "WP10" < "WP20").



---

## Then

### [Item 11 cut timing]
Design decision: currently a DB waypoint is deleted at cut time, not deferred
until paste succeeds. If the paste never happens (blocked, error, or user
abandons the clipboard), the WP is permanently gone from DB — a data-loss risk.

Options:
- **A** — Defer DB deletion to paste-success. Clipboard stores a "pending
  delete" flag. Safest; requires refactoring the CUT path in nmOpsDB.pm.
- **B** — Disallow D-CT-DB in the UI menu. Force user to delete explicitly
  only after confirming paste succeeded.
- **C** — Accept and document: cut = delete, paste = re-create. User
  responsibility to not abandon a cut clipboard.

Affects: nmOpsDB.pm (`_cutDatabaseWaypoint`), nmOps.pm (doCut).

---

## Ongoing

### [Doc hierarchy pruning]
After the nmOps scheme redesign is complete, a severe pruning pass is
needed: context_menu.md, context_menu_testplan.md, last_testrun.md,
and large portions of the runbook, implementation.md, and architecture.md
will need to be rewritten or retired. Primary Claude must explicitly
authorize this pass — do not begin until instructed.

### [oldE80 archaeology]
Patrick-managed. Full checklist in `docs/notes/oldE80-Fixup.md`.
