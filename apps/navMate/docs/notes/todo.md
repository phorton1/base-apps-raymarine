# navMate Todo

[name] identifiers cross-reference open_bugs.md, design_vision.md, or docs/
where those hold canonical context. Items without a canonical home carry their
own context here.

---

## Next

### [Update /api/nmdb response]
Update nmServer.pm queries behind /api/nmdb to return `visible` and versioning
columns (`db_version`, `e80_version`, `kml_version`) for waypoints, routes, and
tracks; return `visible` for collections. Update the test runbook column reference
table to match.

### [em dash encoding]
Systemic replace of UTF-8 em-dash encoding (`â€"`) with ASCII double-hyphen (`--`)
throughout all `.pm` files.

---

## Soon

### [Delete E88 Tracks]
There is no Delete Tracks command on the Tracks folder on the E80 but there is a Delete Track
command on the individual tracks.  There should be a Delete Tracks command in the context menu.

### [WPMGR post-delete GET_ITEM error fix]
Known fix — see open_bugs.md. One-liner in the GET_ITEM/waitReply failure
path for 'mod_item' commands.

### [db_version increment wiring]
Wire `db_version = db_version + 1` in `updateWaypoint`, `updateRoute`, track
UPDATE, `clearRouteWaypoints`, and `move*` functions. Columns exist in schema 9.0
with `DEFAULT 1`; increment logic not yet written. Part of the sync feature --
dedicate a full session to this when ready.

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

### [Color Test D full]
Default track color (index 5 = BLACK = ff000000) verified Cycle 6.
Full verification requires Patrick to assign non-default colors to tracks
via the E80 UI before copy-to-DB, then verify aabbggrr round-trip.
Track palette: 0=RED ff0000ff, 1=CYAN ff00ffff, 2=GREEN ff00ff00,
3=BLUE ffff0000, 4=MAGENTA ffff00ff, 5=BLACK ff000000.

### [smart update path]
Replace skip-if-exists logic with UUID-diff MOD_ITEM: when a UUID exists
on both sides, send a full record re-send. Policy: push = navMate wins,
pull = E80 wins. Step E remaining piece. Not yet implemented.

### [E80 name collision auto-rename]
E80 enforces name uniqueness at hardware level. NEW_ITEM returns success=0
(not FIN) when a WP with the same name already exists under any UUID.
Fix: in the E80 Paste New helpers (_pasteNewWaypointToE80, _pasteNewGroupToE80,
_pasteNewRouteToE80) and _pasteOneWaypointToE80, add a name-collision pre-check
before createWaypoint: scan $wpmgr->{waypoints} for any existing WP with the
same name; if found, append " (2)", " (3)" etc. until unique among existing WPs
and names queued in this pass. Log the rename at display level 0.

Affects: apps/navMate/nmOpsE80.pm

### [_copyAll E80 normalization]
Latent crash — see open_bugs.md. No current test exercises COPY-ALL from
the E80 panel so it is dormant, but real.

---

## Ongoing

### [oldE80 archaeology]
Patrick-managed. Full checklist in `docs/notes/oldE80-Fixup.md`.
