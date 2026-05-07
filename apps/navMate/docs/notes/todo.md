# navMate Todo

[name] identifiers cross-reference open_bugs.md, design_vision.md, or docs/
where those hold canonical context. Items without a canonical home carry their
own context here.

---

## Next


### [Rework operations system]
The design phase is in progress — `nmOperations.md` to document the new scheme in
full.  Patrick doing manual edit. 

1. **Decide module structure** —  nmClipboard.pm fields and
   query interface; which ops inline vs. dispatch; nmOps.pm, nmOpsDB.m
   and nmOpsE80 pm implementing machinery. E80 always protected by progress
   dialogs.
2. Feature Implementation
3. **Write nmOps_testplan.md** — fresh test plan replacing
   context_menu_testplan.md. Pre-flight failure paths are first-class test
   cases; Paste Before/After tests added; `[concept notion]` identifiers as
   shorthand; versioning test section is placeholder only.
4. **Finish nmOperations api for automatic testing** -  Things like
   extend nmDialogs.pm `$suppress_confirm`** to cover error/warning dialogs
   (not just confirm dialogs), so pre-flight failure paths are fully testable.
   Any other claude http apis needed for for feature testing.
5. **write new runbook** - write the runbook for claude to test, similar
   to previous runbook, including handling or $progress dialogs, completely
   informed api usage, no flailing, which runs last_testrun.md
6. **iterate through testplan** - alpha run(0) ... stop on each issue and
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


### [winDatabase reordering UX]
Add reorder capability to winDatabase for items in the navMate database.
Scope is narrow: navMate DB reordering only — no E80 sync or visibility
tie-in. Schema 10.0 added `position REAL` to collections, waypoints, routes,
and tracks; the storage foundation is in place. UI implementation needed.
See `[item ordering UI]` in design_vision.md for design context.

### [WPMGR post-delete GET_ITEM error fix]
Known fix — see open_bugs.md. One-liner in the GET_ITEM/waitReply failure
path for 'mod_item' commands.


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
