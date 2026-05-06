# navMate — Open Bugs

Active bugs with context, symptoms, and observations.
Where a bug appears in the test plan, last_testrun.md holds the reproduction
context — entries here provide the additional detail that doesn't belong there.

---

### [Cut path leaves item visible on Leaflet map]

**Symptom:** Cutting a waypoint (or other item) via the context menu removes
it from the navMate DB but leaves the rendered feature visible on the Leaflet
map until the next full reload.

**What is known:**
- Delete paths were fixed (2026-05-06) by routing through
  `_refreshDatabaseWithDelete` which calls `onObjectsDeleted` →
  `removeRenderFeatures`. Cut paths were intentionally left out of that fix.
- Same root cause as the delete bug: cut calls `_refreshDatabase()` which
  reloads the tree but does nothing to Leaflet or `%rendered_uuids`.
- Fix is straightforward: cut paths need to collect UUIDs and call
  `_refreshDatabaseWithDelete` the same way delete paths now do.
- Affected: `_cutDatabaseWaypoint` and any other cut paths in nmOpsDB.pm.

---

### [wx thread freeze]

**Symptom:** navMate wx UI becomes completely unresponsive — window cannot
be brought to front, clicks do nothing, tree does not expand. Console thread
and HTTP threads remain alive; `/api/log` and the `db` command still work.

**Workaround:** Restart navMate. No data loss observed.

**What is known:**
- First observed well before 2026-05-04; recurred multiple times across sessions.
- Not reproducible on demand.
- Previously always occurred while E80 was connected and active (sending events).
- Also observed 2026-05-06 during visibility checkbox toggling with NO E80
  connected — triggering `_pullCollectionFromLeaflet` on a large collection.
  This widens the known trigger conditions beyond E80 activity.
- Candidates: shared-variable deadlock under lock contention, Perl GC
  interaction with wx, or a downstream effect of a threading race. The
  queue_lock race was fixed 2026-05-04 — unclear whether that was the
  root cause or unrelated.
- Key diagnostic data when it occurs: last log entry before wx went silent,
  and whether any WPMGR commands were in flight at the time.

**Inter-process symptom (2026-05-06, visibility context):** The frozen wxApp
was unblocked by pressing Return in a *separate, unrelated* cmd.exe window
(the Claude Code session — completely independent process, no shared console,
no IPC with navMate). This is not understood. The same phenomenon was
observed twice in the same session. Patrick has a dim memory of seeing
this cross-window unblocking behavior in other wxPerl apps with HTTP server
threads, suggesting it may be a general property of how Perl thread locks
interact with the Windows message pump or console subsystem — not specific
to navMate's code. No root cause identified.

**Status:** Unresolved. TOP PRIORITY when next reproducible.

---

### [GET_CUR2 bad points]

**Symptom:** `ERROR - track(uuid) bad points(0) != expected(N)` in
e_TRACK.pm:137. Fires after each EVENT(0) during live track recording —
once on the STOP event, once on the subsequent TRACK_CHANGED event.
MTA reports N expected points but the point buffer comes back empty.

**Non-fatal:** Track lifecycle (start/stop/name/save) works correctly.
Track appears in the saved list and in /api/db. Do not treat these ERRORs
as test cycle failures.

**What is known:**
- Also observed: `OUT OF BAND seq(N) expected(0)` in b_sock during live
  recording — unsolicited TRACK_CHANGED events arriving between commanded ops.
- Hypothesis: GET_CUR2 ("get current track") follows a slightly different
  wire format than GET_TRACK (saved tracks). The `expect_trk`/`buffer_complete`
  triggering logic in `e_TRACK::parsePiece` was written for GET_TRACK and
  may not handle the GET_CUR2 MTA→TRK sequence correctly — treating the
  buffer as terminal too early or not accumulating points.
- Where to look: `e_TRACK.pm` `parsePiece` for the `buffer` piece in
  GET_CUR2 context; `d_TRACK.pm` around line 137.
- Before fixing: increase `$dbg_track` to capture the raw parse flow and
  identify exactly where points are lost.

---

### [WPMGR post-delete GET_ITEM error]

**Symptom:** Spurious ERROR logged after group-related deletes.
Simple (non-group) waypoint deletes are clean — no bug there.

**What is known:**
- Group-related delete sequence: MOD_ITEM fires with mod_bits(0002) BEFORE
  DEL_ITEM runs, triggering a GET_ITEM while the item is still in E80 memory.
  DEL_ITEM then removes the item. The queued GET_ITEM executes, item is gone,
  E80 returns success=0 → ERROR logged.
- A naive fix was attempted and reverted: skipping GET_ITEM for UUIDs not
  in local memory breaks waypoint CREATE — the create path relies on a
  mod_bits(0000) MODIFY event triggering GET_ITEM to store the new item
  in memory. (Non-waypoints get an explicit `get_item` call; waypoints do not.)
- The right fix is narrow: in the GET_ITEM/waitReply failure path, when the
  triggering command was 'mod_item' and E80 returns "not found", log WARNING
  instead of ERROR. This keeps the create path intact.

---

### [_copyAll E80 normalization]

**Symptom:** Latent crash — not yet triggered. No current test exercises
COPY-ALL from the E80 panel.

**What is known:**
- `_copyAll` in nmOps.pm pushes raw `$wps->{$uuid}` data for group members,
  route members, and ungrouped WPs without calling `_e80WpClipData()`.
- E80 in-memory waypoints store lat/lon as 1e7 scaled integers.
  `_e80WpClipData()` converts these to decimal degrees. Without that call,
  the clipboard contains raw 1e7 integers.
- Any subsequent paste calls `latLonToNorthEast()` expecting decimal degrees
  → `log()` of a negative number → crash.
- `_copyWaypoint`, `_copyGroup`, and `_copyRoute` were all fixed to use
  `_e80WpClipData()`. `_copyAll` was missed.
- Fix: wrap all three `$wps->{$uuid}` data references in `_e80WpClipData(...)`
  at the three call sites in `_copyAll` (group members line ~878, route
  members line ~890, ungrouped line ~899).
