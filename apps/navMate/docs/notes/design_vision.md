# navMate Design Vision

Future directions, deferred feature concepts, and architectural thinking.
Items here are not necessarily scheduled. They range from passing thought
to worked-out design, and can be promoted to todo.md when the time is right.


### [waypoint carrying route pasting]

The design currrently disallows pasting a route in which the referenced
waypoints do not exist.  It is an interesting idea to populate the destination
with any waypoints that are missing by uuid, but also complicated with regards
to determine where to place the waypoints within either heiarchy.  Additionally
on the E80 it is a distinctly two step process.

### [item ordering UI]

Drag/Drop UI for reordering items in winDatabase based on implmented
navOperations operators.


### [winE80 / Leaflet integration cluster]

A cluster of related future work around displaying E80-native items in the
Leaflet map with matching editor and visibility UI. These items are
interdependent - treat as one design session, not five separate tasks:

1. **Separate Leaflet layer for E80 items** - a Leaflet mode or layer set
   that shows the winE80 database (E80-native items) distinctly from
   navMate DB items.

2. **Non-persistent visibility checkboxes on E80 items** - similar to the
   winDatabase visibility UI, but for E80 items; session-only, not stored
   to the navMate DB.

3. **Editors for E80 items** - similar to the editors in winDatabase,
   applied to the E80 item set.



### [Leaflet zoom declutter]

Wire `map.on('zoomend', rerender)` and add per-type zoom minimums inside
`renderAll` in map.js. At low zoom levels, hide label/sounding/WP-name
features that create clutter at voyage scale.

Suggested thresholds (to be tuned against the Bocas dataset):
- `wp_type === 'label'` (folder-title labels): only above zoom ~10
- `wp_type === 'sounding'` (depth numbers): only above zoom ~12
- WP names: only above zoom ~11
- Route point names: only above zoom ~11

GE does real-time collision-based decluttering; this is a simpler zoom-gate
that approximates the same result without that complexity.


### [navMate preferences dialog]

- navMate DB location
- keybindings to command functions (a whole concept of its own)


### [Progress-dialog accuracy / E80 quiescence detection]

The wxProgressDialog currently displayed around long-running E80 operations only
*partially* brackets the real ethernet/E80 behavior, and the larger the operation,
the worse the misalignment gets. This is observable on essentially every multiple-item
E80 command, not just one outlier.

**hub.15 (cycle 20) as a clean example.** Cutting the 79-member "test" group from
FSH and pasting it to the E80 produced a UX shape roughly like:

1. Progress dialog appears.
2. *Nothing visibly happens* for several seconds. Internally many things are queued
   (waypoint mods, GET_ITEMs) and the FSH outline tree redraws ~60 times.
3. The dialog bar then moves fairly smoothly through ~60 operations. The window is
   apparently frozen during this -- no responsiveness, no incremental UI feedback
   other than the bar.
4. The dialog closes.
5. *Another ~60 GET_ITEMs* happen with the dialog already gone -- 10-12 seconds of
   "post-completion" service traffic before the E80 actually settles.

So the dialog brackets, very roughly, the *middle* of the real operation -- it misses
both the preparation/queuing front-end and the get-item / service-cascade tail. A
smart user knows not to re-enter a command while the system is still flailing, but
nothing in the code currently *prevents* re-entry once the dialog has closed.

This is the same gap that originally motivated the NET bracketing concept
(navOpsBracket + a_bracket -- removed 2026-05-17 with the panel-free test surface).
The test infrastructure didn't end up needing it, so the brackets came out -- but the
underlying UX problem the brackets were a candidate solution for still exists.

It also affects Claude's pacing in test runs and live work. Claude tends to gate on
the navOps op-boundary marker (`===== <op> (<panel>) FINISHED =====`) or the
ProgressDialog FINISHED marker, neither of which means "the E80 has actually stopped
receiving and reacting." In cycle 20 specifically, hub.16's verification started
while hub.15's E80 tail was still draining -- it didn't matter for the test result
in that case, but it's not robust and reveals the same modeling gap.

**Why this is hard.** "The dialog finished" is a sharp event; "the device is
quiescent" is an inferred condition from a *lack* of events for some interval. The
two semantics don't compose neatly. The bracket idea handles this by tracking the
last send and last event timestamps in `d_WPMGR` / `d_TRACK` and declaring quiescence
after `$QUIESCENCE_T` seconds of silence -- which is exactly the right primitive.

**Sketch of what a real fix could look like (no commitment yet):**

- Reinstate the NET-side quiescence primitive (`a_bracket.pm`-style, but only the
  inner half -- service-level last-send / last-event tracking), without the panel-free
  HTTP test surface that originally rode along with it. That layer was the part worth
  keeping.
- Extend the ProgressDialog lifecycle: it doesn't dismiss on "navOps op finished" --
  it dismisses on "navOps op finished AND service quiescent for $QUIESCENCE_T".
- During that extended window, UI-lock the affected panel(s) -- right-click menu
  greyed out, no new ops accepted -- to programmatically enforce what a smart user
  is already doing manually.
- Add a `/api/quiescent` endpoint Claude (and the testplan) can poll instead of, or
  in addition to, the dialog FINISHED marker. Claude pacing becomes correct by
  construction.
- The "preparation" front-end gap (the ~60 tree redraws before the bar moves) is a
  different problem -- probably about doing the snapshot / deconflict / buffer-build
  on the wx idle thread instead of inline, or splitting the progress dialog into
  "preparing... / transmitting... / settling..." phases.

**Refinement -- per-service quiescence isn't uniform.**

A second pass on the primitive: "quiescence = no events for N seconds" breaks the
moment a service is in a continuous-flow mode. Live track recording and an active
autopilot session both emit out-of-band events steadily. So the primitive isn't
one-size-fits-all per service.

- **WPMGR is largely clean.** It only emits MODIFY / GET_ITEM responses in reaction
  to commands (ours OR a user touching the E80 device). No heartbeat, no position
  stream, no continuous traffic. A naive "no `d_WPMGR` events for N seconds" check
  is robust during recording AND AP, because those services don't cross-talk into
  WPMGR. The hub.15 cascade is entirely WPMGR. A WPMGR-only quiescence primitive
  handles every test-cycle case and most paste/cut/push UX cases.
- **TRACK is the dirty one.** During recording, `d_TRACK::handleEvent` is the
  recipient of continuous point-add events; during AP, of XTE / route-progress
  updates. Naive "no events" never goes true. Two handles:
    1. **Category filter** -- service marks each event coarsely as `COMMAND_RESPONSE`
       vs `CONTINUOUS_FLOW`; quiescence considers only the former. ~5-10 lines per
       service to tag events, plus the accessor. No correlation IDs needed.
    2. **Recording/AP-aware suppression** -- service exposes `isRecording()` /
       `isAPActive()`; quiescence consumer skips TRACK when either is true.
       Simpler but lossier (you can't bracket a TRACK op *while* recording, but
       you probably shouldn't anyway).
- **WPMGR's only real edge case is the device-user race.** If a user fiddles with
  the E80 chartplotter during a navMate operation, MODIFY events arrive that aren't
  command-cascade. A correlation ID would distinguish; without it, the quiescence
  detector treats them as in-cascade and waits an extra second or two. Almost
  certainly acceptable.

**Pragmatic shape, in order of cost:**

- **v1 (cheap)** -- WPMGR-only quiescence accessor; the ~50-line primitive. Don't
  touch TRACK. Document "if you're recording a track, don't expect the dialog to
  bracket TRACK ops cleanly." Alone, this fixes hub.15-shaped problems and roughly
  80% of multi-item paste/cut UX.
- **v2 (medium)** -- Add the category filter to TRACK. `getQuiescent()` becomes
  meaningful for both services. Track recording is no longer an exclusion zone
  for the dialog.
- **v3 (heavy)** -- Bring back operation-correlation IDs to handle the device-user
  race, AP-during-paste, and any other "ambient event was incorrectly attributed
  to my operation" case. This is the load-bearing piece of the original bracket
  cathedral, and the most expensive. Probably never worth it unless a specific
  failure mode forces the question.

v1 alone likely captures most of the felt-pain. v2 is a clean follow-up if it
ever bites. v3 is conjectural.

Deferred. Not ready to open this can of worms yet -- documenting that the can exists,
that the bracket-system removal solved a different (testing-layer) problem while
leaving this user-facing one open, and that the v1 entry point is small and
self-contained when the time comes.


### [local GEBCO depth server]

**Status:** The Leaflet bathymetric overlay using the GEBCO WMS is in
place (initial commit `f7fc69b`), including the live depth-at-cursor
readout with per-point HTTP fetch + caching.  This entry remains valid
as a future direction -- replacing the third-party WMS dependency with
a self-hosted depth server for speed and offline operation.

Replace the current dependency on `wms.gebco.net` for the
"live depth at cursor" readout in the Leaflet view with a small local
HTTP endpoint backed by a GEBCO grid file kept on disk.

**Motivation.**  Live cursor depth via WMS `GetFeatureInfo` is functional
but laggy (one transatlantic round-trip per query, debounced) and depends
on a free third-party service we shouldn't lean on for production use.
A local server makes the readout effectively instant and lets navMate run
fully offline for depth lookups.

**Asset already in place.**
`C:/dat/Tracks/GEBCO_2026.zip` -- the unzipped grid is a single NetCDF4
(HDF5) file, ~7 GB, `int16` elevation in meters, 43200 rows x 86400 cols,
WGS84, pixel-centre registered, 15 arc-second spacing (~460 m/cell at the
equator).  The data inside the file is effectively uncompressed and
contiguous.

**Path.**

1.  Unzip `GEBCO_2026.zip` into `C:/dat/Tracks/GEBCO_2026/` (or wherever)
    when the work actually begins.
2.  One-time convert the `.nc` to a flat little-endian `int16` binary
    (~7.46 GB, ~1 MB smaller than the `.nc` because the HDF5 wrapper is
    dropped).  No new Perl modules needed -- use `h5dump --binary=LE` from
    the standalone HDF Group download, or any one-off tool that can read
    NetCDF4.
3.  Add a `/api/gebco?lat=X&lon=Y` endpoint to navMate's HTTP server.
    Cell lookup is `row = floor((lat + 90) * 240)`,
    `col = floor((lon + 180) * 240)`,
    `offset = (row * 86400 + col) * 2`.  `sysopen` + `sysseek` + `sysread`
    on the flat binary; `unpack('s<', ...)` to a signed 16-bit metres value.
    The OS page cache handles repeat queries to the same region for free.
4.  Point the Leaflet frontend at `/api/gebco` instead of `wms.gebco.net`
    and drop the in-browser cache (it becomes redundant when the local
    server is already microseconds-per-query).
5.  The GEBCO WMS base layer for *visual* bathymetry overlay can stay as
    today -- they only run the network when the user actively switches the
    base layer to GEBCO.  The local server is purely for the point-query
    readout.

**Vintage rollover.**  GEBCO publishes a new grid roughly yearly.  The
filename carries the vintage (`GEBCO_2026.bin`, `GEBCO_2027.bin`, ...).
The server config points at whichever vintage is current; older vintages
can coexist on disk for comparison or be deleted.  Re-converting takes
minutes; re-downloading takes ~1-2 hours.

**Attribution.**  Public domain, but a credit line should appear with the
depth readout: *"GEBCO Compilation Group (2026) GEBCO 2026 Grid"*.  Drop
it into the existing `#nm-depth` element or the Leaflet attribution
corner.

**TID grid (optional, deferred).**  GEBCO also publishes a single-byte-per-cell
"Type Identifier" grid that flags which cells are real soundings vs.
interpolated/satellite-derived.  Could be served at `/api/gebco/tid` from
a parallel ~3.7 GB binary.  Useful when judging whether a track-vs-grid
discrepancy indicates a real anomaly or just thin upstream data; not
needed for the first cut.


