# navMate — Closed Bugs

Archaeological record. Entries here are for historical reference —
tracing what changed, when, and why.

---

### [Editor Save did not re-render visible items on Leaflet map]

**Was:** Saving changes in the winDatabase editor (color, name, lat/lon, etc.)
did not update the Leaflet map — the stale rendered feature remained.

**Fix (2026-05-06):** Four lines added to `_onSave` in winDatabase.pm before
`disconnectDB` and `$this->refresh()`: if the saved item is an 'object' type
and is currently in `%rendered_uuids`, pull the stale feature from Leaflet
(`_pullFromLeaflet`) then push a fresh one from DB (`_pushObjToLeaflet`).
Items not currently rendered are unaffected.

---

### [Tree expand button broken by visibility checkbox image list]

**Was:** wxTreeCtrl expand buttons (+/-) were unreliable after adding
visibility checkbox images. Some folders would not expand on click, with
zero visual feedback — inconsistent across items at the same level.

**Root cause:** Using `SetImageList` on a Windows native TreeCtrl activates
a different Win32 TreeView rendering mode (hot-tracking enabled, item layout
shifted), making the expand button hit area unreliable. This is a native
Win32 behavior, not a wxWidgets bug.

**Fix (2026-05-06):** Switched to `SetStateImageList` + `SetItemState` /
`GetItemState` / `wxTREE_HITTEST_ONITEMSTATEICON` throughout winDatabase.pm.
State images occupy a dedicated slot between the expand button and the normal
icon with their own hit-test zone — the correct wxWidgets mechanism for
per-item checkboxes. Expand buttons solid; no hot-tracking side effects.

---

### [Show/Hide on Map disconnected from visibility scheme]

**Was:** `_onShowMap` and `_onHideMap` in winDatabase.pm were standalone
implementations disconnected from the persistent visibility checkbox scheme.
They did not write to the DB or sync checkbox states.

**Fix (2026-05-06):** Replaced with `_onShowHideMap($this, 1/0)` wrappers.
New `_onShowHideMap` does a batch visibility set: writes `visible` to DB,
updates tree checkbox states, pushes/pulls Leaflet, syncs editor checkbox.
New `_analyzeShowHideSelection` classifies the tree selection into Case 1
collections (no selected descendants — treat as deliberate target, apply
`setCollectionVisibleRecursive`), Case 2 collections (at least one selected
descendant — skip the branch, recompute checkbox state as derived), and leaf
nodes. New `_hasSelectedDescendant` walks the tree widget recursively for
the classifier. Dead code `_renderCollection` and `_renderObject` (prior
toggle-render path) removed.

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
