# navMate Design Vision

Future directions, deferred feature concepts, and architectural thinking.
Items here are not necessarily scheduled. They range from passing thought
to worked-out design, and can be promoted to todo.md when the time is right.

---

## UI / winDatabase / winE80


### [item ordering UI]

Drag/Drop UI for reordering items in winDatabase based on implmented
nmOperations operators.


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

