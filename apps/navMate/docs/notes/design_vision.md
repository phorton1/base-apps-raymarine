# navMate Design Vision

Future directions, deferred feature concepts, and architectural thinking.
Items here are not necessarily scheduled. They range from passing thought
to worked-out design, and can be promoted to todo.md when the time is right.

---

## UI / winDatabase / winE80


### [item ordering UI]

UIs for reordering items in winDatabase — primarily route waypoints (where
order is navigationally meaningful) and branch contents (purely organizational).

For route waypoints: the detail pane already shows the ordered list. Up/Down
buttons there are the minimal implementation and don't require making routes
expandable in the tree. Drag-and-drop in the tree is the better long-term
model but requires routes to become expandable nodes first.

For branch ordering: E80 has no concept of ordered folders, so this is
navMate-only. Lower priority than route ordering.

If routes become expandable tree nodes, drag-to-reorder and per-waypoint
operations (delete, copy, edit) all become naturally available.


### [winE80 / Leaflet integration cluster]

A cluster of related future work around displaying E80-native items in the
Leaflet map with matching editor and visibility UI. These items are
interdependent — treat as one design session, not five separate tasks:

1. **Separate Leaflet layer for E80 items** — a Leaflet mode or layer set
   that shows the winE80 database (E80-native items) distinctly from
   navMate DB items.

2. **Non-persistent visibility checkboxes on E80 items** — similar to the
   winDatabase visibility UI, but for E80 items; session-only, not stored
   to the navMate DB.

3. **Editors for E80 items** — similar to the editors in winDatabase,
   applied to the E80 item set.

4. **Versioning / color synchronization** — keeping navMate DB versions
   and E80 versions in sync, including the color model, across both views.

5. **nmOps / context_menu entanglement** — all of the above is entangled
   with the nmOps/context_menu scheme. Must be resolved as part of the
   cluster, not independently.

All items deferred. When ready, treat as one design session.


### [winDatabase multi-editor]

Batch-edit capability for the winDatabase editor when multiple items are
selected. No code yet — design only. Entangled with [Rework operations
system]; hold for that design session. The context-menu shortcut approach
("Set Color...", "Set Comment..." actions) remains the lower-complexity
alternative worth considering first.

**Use cases:** change color, comment, or wp_type across a multi-selection.
Name and lat/lon deliberately excluded — no useful batch semantic.

**Key design decisions from inventory multi-editor (reference impl):**
- Mixed-value state: placeholder text "(Multiple Values)" in text fields —
  not a color discriminator. Blank/gray is insufficient.
- Changed indicator: field background color shows which fields have been
  touched and will be written on save.
- Only touched fields are written — the core contract. Requires per-field
  dirty tracking separate from the global editor dirty flag.
- `Pub::Database::update_record` accepts sparse input hashes, so the DB
  layer will not stomp untouched fields.

**Open question — color swatch:** "(Multiple Values)" placeholder text
doesn't translate to a color swatch. Hatched/striped swatch? Disabled
swatch + adjacent text label? "Pick..." button still active? No decision yet.


### [context menu simplification]

The context menu implementation spans nmOps.pm, nmOpsDB.pm, nmOpsE80.pm,
and nmClipboard.pm. Two areas that add significant test surface without
proportional practical value in current use:

- **Paste-New**: creates fresh UUIDs at destination. Useful but less
  frequently needed than UUID-preserving Paste. Could be deferred or
  hidden behind an advanced option without impacting daily workflows.
- **D-ALL variants** (D-CP-ALL, D-CT-ALL): copy/cut entire branch contents.
  Rarely triggered in practice. The canPaste/canPasteNew logic for these
  paths is intricate and has produced subtle bugs across multiple cycles.

Not proposing to remove — they are implemented and tested. But any further
complexity additions to the context menu should be weighed against the
existing surface area and test burden.


## Leaflet / Map

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



### [Leaflet working set]

A distinct visual overlay layer on the Leaflet map for a "current working
set" — items gathered for a specific operation such as a trip push to E80.
Separate from the active visibility layer driven by tree checkboxes.

Workflow: check tree to populate active layer → draw selection (click,
rectangle, lasso) → add to working set → inspect working set layer →
push to E80.

Requires a gather-by-type mode that selects across hierarchy levels, unlike
the current same-level multi-select. Uses the same UUID machinery as
copy/paste but driven by spatial selection rather than tree selection.

Not yet started.


## Architecture

### [E80 sync / versioning system]

`db_version`, `e80_version`, and `kml_version` columns are in schema 9.0 on
`waypoints`, `routes`, and `tracks` (not on `collections` or `route_waypoints`).
Columns carry correct defaults; increment logic is not yet wired.

**db_version** — bumped on every navMate edit (UPDATE of any non-`visible` field).
Starts at 1 on INSERT.

**e80_version** — NULL = never synced. Set to `db_version` at time of a successful
upload or download. Version numbers are not stored on the E80 hardware. At connect
time, `e80_version` is initialized from a token encoded in the E80 `comment` field
(encoding TBD — pending E80 character-set and comment-length-limit verification).
A waypoint arriving from the E80 with no token has `e80_version = 0`. When
`e80_version < db_version` the object has been locally edited since last sync;
when `e80_version > db_version` the E80 has a newer version — detectable via
MODIFY events live, or via comment-token mismatch at startup (magenta display state).

**kml_version** — NULL = never exported via versioned KML. Set to `db_version`
at time of export.

**Transport columns in core tables** — a deliberate choice. The alternative
junction table `sync_state(object_uuid, transport, db_version_at_sync)` was
rejected in favor of simplicity given the small, slow-moving transport list.

**Visibility** — the `visible` column is NOT a versioned field. Toggling
visibility does not bump `db_version`.

**Wiring deferred** — all increment logic belongs in a dedicated session when
the sync feature is ready to implement. See `[db_version increment wiring]` in todo.md.

