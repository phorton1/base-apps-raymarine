# navMate - Open Bugs

Active bugs with context, symptoms, and observations.
Where a bug appears in the test plan, last_testrun.md holds the reproduction
context - entries here provide the additional detail that doesn't belong there.


---

### [wx thread freeze]

**Symptom:** navMate wx UI becomes completely unresponsive - window cannot
be brought to front, clicks do nothing, tree does not expand. Console thread
and HTTP threads remain alive; `/api/log` and the `db` command still work.

**Workaround:** Restart navMate. No data loss observed.

**What is known:**
- First observed well before 2026-05-04; recurred multiple times across sessions.
- Not reproducible on demand.
- Previously always occurred while E80 was connected and active (sending events).
- Also observed 2026-05-06 during visibility checkbox toggling with NO E80
  connected - triggering `_pullCollectionFromLeaflet` on a large collection.
  This widens the known trigger conditions beyond E80 activity.
- Candidates: shared-variable deadlock under lock contention, Perl GC
  interaction with wx, or a downstream effect of a threading race. The
  queue_lock race was fixed 2026-05-04 - unclear whether that was the
  root cause or unrelated.
- Key diagnostic data when it occurs: last log entry before wx went silent,
  and whether any WPMGR commands were in flight at the time.

**Inter-process symptom (2026-05-06, visibility context):** The frozen wxApp
was unblocked by pressing Return in a *separate, unrelated* cmd.exe window
(the Claude Code session - completely independent process, no shared console,
no IPC with navMate). This is not understood. The same phenomenon was
observed twice in the same session. Patrick has a dim memory of seeing
this cross-window unblocking behavior in other wxPerl apps with HTTP server
threads, suggesting it may be a general property of how Perl thread locks
interact with the Windows message pump or console subsystem - not specific
to navMate's code. No root cause identified.

**Post-freeze console-charset corruption (2026-05-17, hub-alpha context):**
When navMate is frozen and Patrick presses Ctrl-C in its cmd.exe window to
force termination, the exit path runs through `NET/b_serial.pm:70` ("ctrl-C
pressed ...") and `NET/b_serial.pm:114` ("EXITING PROGRAM from serial
thread()"). navMate exits, but the cmd.exe terminal is left with its
character set in **line-drawing / special-character mode** - all subsequent
output renders as box-drawing or APL symbols, including the shell prompt
itself. Example: `C:\base\apps\raymarine\apps\navMate>` displays as
`C:\␉▒⎽␊\▒⎻⎻⎽\⎼▒≤└▒⎼␋┼␊\▒⎻⎻⎽\┼▒┴M▒├␊>`. Recovery requires closing and
reopening the cmd.exe window.

Mechanism: this is the classic **DEC Special Graphics Character Set**
designated to G0 - a sticky VT terminal state, NOT a codepage switch
(`chcp 437` won't fix it). The terminal received either an `ESC ( 0`
designation sequence (0x1B 0x28 0x30) or a bare SHIFT-OUT byte (0x0E) with
G1 already pre-loaded with Special Graphics (Windows Terminal does this
by default). The mapping is identifiable - e.g. `s`(0x73)->⎽, `e`(0x65)->␊,
`r`(0x72)->⎼, `i`(0x69)->␋, `a`(0x61)->▒, `l`(0x6c)->┌, `p`(0x70)->⎻,
`m`(0x6d)->└, `b`(0x62)->␉, `f`(0x66)->°, `v`(0x76)->┴, `y`(0x79)->≤,
`_`(0x5f)->blank.

**Suspicion ("serial" smell):** the first two log lines that contained
mangled bytes both reference `NET/b_serial.pm`, and the Ctrl-C exit handler
itself lives in that module. The b_serial implementation in navMate is
derived from `NET/b_serial.pm` and inherits its shared-memory plumbing.
Patrick recalls a long-standing Perl `threads::shared` gotcha: **you cannot
change the type of a shared scalar by assignment** - e.g. assigning `''`
(or `0`) to a shared hashref does NOT clear or replace the hash, and the
ensuing type mismatch under GC in a multi-thread context can produce
random memory corruption including stray bytes being emitted to the
console. The correct idiom is `shared_clone({})` or `undef` (and `undef`
only when the slot's type is allowed to be undef). If b_serial's Ctrl-C
handler is doing any `$shared_var = ''` assignments on hash/array shared
slots during teardown, that could explain both the charset escape leak AND
why the corruption appears specifically on this exit path. Worth grepping
`NET/b_serial.pm` for shared-scalar assignments to non-matching types as
the first diagnostic step.

**Status:** Unresolved. TOP PRIORITY when next reproducible.

---

### [GET_CUR2 bad points]

**Symptom:** `ERROR - track(uuid) bad points(0) != expected(N)` in
e_TRACK.pm:137. Fires after each EVENT(0) during live track recording -
once on the STOP event, once on the subsequent TRACK_CHANGED event.
MTA reports N expected points but the point buffer comes back empty.

**Non-fatal:** Track lifecycle (start/stop/name/save) works correctly.
Track appears in the saved list and in /api/db. Do not treat these ERRORs
as test cycle failures.

**What is known:**
- Also observed: `OUT OF BAND seq(N) expected(0)` in b_sock during live
  recording - unsolicited TRACK_CHANGED events arriving between commanded ops.
- Hypothesis: GET_CUR2 ("get current track") follows a slightly different
  wire format than GET_TRACK (saved tracks). The `expect_trk`/`buffer_complete`
  triggering logic in `e_TRACK::parsePiece` was written for GET_TRACK and
  may not handle the GET_CUR2 MTA->TRK sequence correctly - treating the
  buffer as terminal too early or not accumulating points.
- Where to look: `e_TRACK.pm` `parsePiece` for the `buffer` piece in
  GET_CUR2 context; `d_TRACK.pm` around line 137.
- Before fixing: increase `$dbg_track` to capture the raw parse flow and
  identify exactly where points are lost.



### [WPMGR post-delete GET_ITEM error]

**Symptom:** Spurious ERROR logged after group-related deletes.
Simple (non-group) waypoint deletes are clean - no bug there.

**What is known:**
- Group-related delete sequence: MOD_ITEM fires with mod_bits(0002) BEFORE
  DEL_ITEM runs, triggering a GET_ITEM while the item is still in E80 memory.
  DEL_ITEM then removes the item. The queued GET_ITEM executes, item is gone,
  E80 returns success=0 -> ERROR logged.
- A naive fix was attempted and reverted: skipping GET_ITEM for UUIDs not
  in local memory breaks waypoint CREATE - the create path relies on a
  mod_bits(0000) MODIFY event triggering GET_ITEM to store the new item
  in memory. (Non-waypoints get an explicit `get_item` call; waypoints do not.)
- The right fix is narrow: in the GET_ITEM/waitReply failure path, when the
  triggering command was 'mod_item' and E80 returns "not found", log WARNING
  instead of ERROR. This keeps the create path intact.

---

### [navops 5.6 dangling ProgressDialog]

**Symptom:** Test 5.6a (DELETE_ROUTE via E80 routes header) sometimes leaves a
ProgressDialog that does not reach FINISHED within the expected window. If 5.6b
fires before it completes, 5.6b queues behind it and the E80 is not cleared.
All Section 5 tests from 5.6c onward become NOT_RUN.

**Occurred:** Cycles 13 and 14.

**Open questions:**
1. Is the dialog genuinely stuck (dialog_state: active), or does it finish fast
   and FINISHED was simply missed between the sleep and the log read?
2. Does navMate queue or reject E80 commands dispatched while a dialog is active?
3. Does close_dialog rescue a slow (not hung) dialog, or only a truly frozen one?

**How to handle in test cycle:** Before running 5.6b, check dialog_state explicitly
and use `close_dialog` command if active. Hard stop if close_dialog does not resolve.

**Root cause:** Unknown. May be race between dialog completion and log poll timing,
or a navMate bug in the route-delete path for header-node case.

