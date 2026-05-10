# navMate Todo

[name] identifiers cross-reference open_bugs.md, design_vision.md, or docs/
where those hold canonical context. Items without a canonical home carry their
own context here.

---

## Next

### [testplan cleanup] - there are a number (all) of the routes in the current
database that carry non-exact mappings to colors on the E80.  There are other
issues as well, most predominantly the possibility that the particular items
selected in the uuid map in the runbook might incur truncation warnings if used.

Before the next testrun not only do the continued existence of the uuid/items
need to be confirmed, but any that might trigger name uniqueness traps that
didnt occur need to be prevented from unintentionally being used in the runbook.

To the degree that the testplan is intended as a destructive test to the database
(i.e. a revert must be done before using the actual database after a test run),
the issue is actually to make sure that the test running claude (the runbook)
knows how to deal with the abort/continue warnings and continue in spite of them.

Apart from that, and not, per-se, to be driven by the runbook, these routes in
the current database corrected so they have exact two way color mappings.



### [db_version increment wiring]

`db_version`, `e80_version`, and `kml_version` columns are in schema 9.0 on
`waypoints`, `routes`, and `tracks` (not on `collections` or `route_waypoints`).
Columns carry correct defaults; increment logic is not yet wired.

**db_version** - bumped on every navMate edit (UPDATE). Starts at 1 on INSERT.

**e80_version** - NULL = never synced. Set to `db_version` at time of a successful
upload or download. Version numbers are not stored on the E80 hardware. At connect
time, `e80_version` is initialized from a token encoded in the E80 `comment` field
(encoding TBD - pending E80 character-set and comment-length-limit verification).
A waypoint arriving from the E80 with no token has `e80_version = 0`. When
`e80_version < db_version` the object has been locally edited since last sync;
when `e80_version > db_version` the E80 has a newer version - detectable via
MODIFY events live, or via comment-token mismatch at startup (magenta display state).

**kml_version** - NULL = never exported via versioned KML. Set to `db_version`
at time of export.

**Transport columns in core tables** - a deliberate choice. The alternative
junction table `sync_state(object_uuid, transport, db_version_at_sync)` was
rejected in favor of simplicity given the small, slow-moving transport list.

**Wiring deferred** - all increment logic belongs in a dedicated session when
the sync feature is ready to implement. See `[db_version increment wiring]` in todo.md.


### [synchronization color scheme]
Between winDatabase and winE80 highlight common "same" items in bold blue,
"older items" in bold magenta, and newer items in "bold green" via inter-window
analaysis.

### [synchronization operations]
Implement "sync->E80" and "sync<-DB" menu commands to synchronize
out of date items in one-step directional manner.  These may be very
similar but subtly different to the degree that any uuids showing up
on the E80 should probably be considered "new" items, colored appropriately
and downloaded to the database on a synch operation.




## Soon

### [sort database collecton context menu command]
I would like the ability to sort the immediate children of at least a single selected
collection (branch or group). The simplest visision is a collection of terminal "objects"
that would be sorted by their name.  The sort is essentially lexical but for two objects
that have the same prefix but only end in digits different, the digits would be sub-sorted
numerically. My vision is not so clear when the children of the colllection also includes
other collections.  On the one hand, the same sort criteria could be used and so collections
would normally end up inter-mixed with terminal objects in the resultant ordering. On
the other hand, it might be nice to have something like the way windows explorer puts
collections at the top, and then terminal objects after them.   Possibly if, upon executing
the sort command, the system detected a collection in the children, it could then provide
a UI to allow the user to specify the sort criteria in that one case.

The other insteresting idea is to allow sorting of an explicit non-sparse range selection
of items within a single parent ... sorting them in place as a group.  I could see that
being handy, though the ui for the collection first would hardly seem to make sense in
that case.



### [INSERT position assignment]
INSERT functions do not yet assign `position` for new items -- they land at 0
and sort to the top. Functions to update: `insertCollection`,
`insertCollectionUUID`, `insertWaypoint`, `insertRoute`, `insertTrack`.
Pattern: `SELECT COALESCE(MAX(position), 0) + 1 FROM <table> WHERE <scope>=?`


### [winDatabase reordering UX]
Add reorder capability to winDatabase for items in the navMate database.
Scope is narrow: navMate DB reordering only -- no E80 sync or visibility
tie-in. Schema 10.0 added `position REAL` to collections, waypoints, routes,
and tracks; the storage foundation is in place. UI implementation needed.
See `[item ordering UI]` in design_vision.md for design context.

### [WPMGR post-delete GET_ITEM error fix]
Known fix - see open_bugs.md. One-liner in the GET_ITEM/waitReply failure
path for 'mod_item' commands.




---

## Later


### [Item 11 cut timing]
Design decision: currently a DB waypoint is deleted at cut time, not deferred
until paste succeeds. If the paste never happens (blocked, error, or user
abandons the clipboard), the WP is permanently gone from DB - a data-loss risk.

Options:
- **A** - Defer DB deletion to paste-success. Clipboard stores a "pending
  delete" flag. Safest; requires refactoring the CUT path in navOpsDB.pm.
- **B** - Disallow D-CT-DB in the UI menu. Force user to delete explicitly
  only after confirming paste succeeded.
- **C** - Accept and document: cut = delete, paste = re-create. User
  responsibility to not abandon a cut clipboard.

Affects: navOpsDB.pm (`_cutDatabaseWaypoint`), navOps.pm (doCut).

### [wp_type semantics after operations]
The `wp_type` field (sounding / label / nav) was assigned by the original
oneTimeImport and reflects the source character of each waypoint. Open design
question: does wp_type stay stable across operations, or should it shift?

Specific concern: if a waypoint is used as a route point it is hard to imagine
a sounding or label playing that role - nav seems like the only sensible
route-point type. But it is unclear whether wp_type should be coerced on paste
into a route, or left alone and treated as display metadata only.

A second angle: wp_type may interact with the navOperations scheme in ways not
yet designed - e.g. filtering what can be pasted where, or affecting how items
are rendered in the tree. No decision yet; capture here before the question
gets lost. Resolve before any work that touches wp_type assignment at paste time.

---

## Ongoing

### [Doc hierarchy pruning]
After the navOps scheme redesign is complete, a severe pruning pass is
needed: context_menu.md, context_menu_testplan.md, last_testrun.md,
and large portions of the runbook, implementation.md, and architecture.md
will need to be rewritten or retired. Primary Claude must explicitly
authorize this pass - do not begin until instructed.

### [oldE80 archaeology]
Patrick-managed. Full checklist in `docs/notes/oldE80-Fixup.md`.
