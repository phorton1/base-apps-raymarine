# navMate — Closed Bugs

Archaeological record. Entries here are for historical reference —
tracing what changed, when, and why.

---

### [Route MOD_ITEM race]

**Was:** When a user changed a route's color on the E80 UI, navMate
intermittently failed to update winE80. The MODIFY ROUTE packet arrived
via b_sock but handleEvent was not reliably called. Adding any stdout-locking
debug output (warning() or display()) would suppress the race — classic
Heisenbug. The fault was upstream of handleEvent in the sockThread receive
and dispatch path.

**Root cause:** Missing memory barrier between b_sock.pm TCP receive loop
and d_WPMGR.pm command thread. Without a lock, the thread scheduler could
reorder reads/writes across the shared queue, causing the consumer to miss
queued items.

**Fix (2026-05-04):** Added `queue_lock` (shared hash) to d_WPMGR.pm
`init()`; `lock($queue_lock)` in `queueWPMGRCommand()` after pre-flight
check; narrow lock block in `commandThread()` released before
`handleCommand()`. The lock provides the memory barrier that forces
queue-state visibility across threads.

**Confirmed fixed (2026-05-05):** Changed Agua route color to blue on
E80 UI; `enquing mod(...)` appeared in log; E80 DB color index = 3
(BLUE) correct.

---

### [ProgressDialog singleton orphan]

**Was:** `_pasteAllToE80` opened a ProgressDialog for groups and then
another for routes in rapid succession. `ProgressDialog::new()` overwrote
`$_active` with the second dialog, orphaning the first. The orphaned dialog
had no completion path and remained on screen indefinitely. E80 operations
completed correctly — only the dialog was stuck.

**Fix (2026-05-05):** `ProgressDialog::new()` now returns `undef` if
`$_active` is already defined (singleton guard). `_openE80Progress` returns
`undef` if the dialog is refused; all callers return early on `!$progress`.
`_pasteAllToE80` and `doPaste` now open ONE shared ProgressDialog spanning
the entire operation.

---

### [D-CT-DB to E80 paste guard missing]

**Was:** A cut from the DB (D-CT-DB) could be pasted to E80. This is wrong:
the DB is the authoritative repository; all uploads to E80 are copies, never
cuts. The `canPaste` guard blocked it at the UI layer but `doPaste` had no
handler-level sentinel to catch it if reached via nmTest.

**Fix (2026-05-04):** Added explicit guard at the top of the E80 branch in
`doPaste` (nmOps.pm) — fires IMPLEMENTATION ERROR warning and returns if
`$cb->{cut} && source eq 'database'`. Confirmed §5.4 PASS Cycle 5.

---

### [_pasteAllToE80 stale pending names]

**Was:** When pasting multiple items to E80 in one pass, items queued earlier
in the pass were not yet in `$wpmgr->{waypoints}` when later items were
processed (WPMGR thread had not consumed them yet). Route-phase processing
re-queued the same WPs → E80 rejected on UUID collision.

**Fix (2026-05-04):** Added shared `%pending_names` in nmOps.pm to track
names queued during the current pass. Pre-check before queuing each item;
treat already-pending items as `no_change`.
