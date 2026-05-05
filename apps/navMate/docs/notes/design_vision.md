# navMate Design Vision

Future directions, deferred feature concepts, and architectural thinking.
Items here are not necessarily scheduled. They range from passing thought
to worked-out design, and can be promoted to todo.md when the time is right.

---

## UI / winDatabase / winE80

### [generic window editors]

A property grid editor in the right pane of winDatabase, replacing the current
`color_panel` + read-only detail hybrid. Allows editing all non-structural DB
fields without a modal dialog. winE80 gets the same treatment eventually but is
out of scope for the current implementation pass.

**Layout (decided 2026-05-05, not yet coded):**
- Right pane becomes a vertical inner splitter
- Top pane: pure property grid — labeled rows; editable fields + static display for structural fields
- Bottom pane: existing read-only monospaced detail TextCtrl, unchanged
- Inner sash starts at 50% of right pane height; not persisted across invocations

**Editable fields by record type:**

| Type | Editable | Display-only (structural) |
|---|---|---|
| Collection | name, comment | node_type, uuid, collection_uuid |
| Waypoint | name, comment, lat, lon, wp_type, color, depth_cm | uuid, collection_uuid, created_ts, ts_source, source |
| Route | name, comment, color | uuid, collection_uuid |
| Route point | (no editor) | — |
| Track | name, color | uuid, collection_uuid, ts_start, ts_end, ts_source, point_count |

**Save trigger:** Explicit Save button.
- Disabled when clean (no changes since node selected or last save)
- Enabled when dirty (any field changed)
- Dirty state silently discarded on node focus change — no prompt
- On save: write changed fields to DB

Note: `sym` is excluded from the property grid (E80-specific, has no meaning in
navMate's data model). Whether to show it as a display-only field with a note is
TBD when coding starts.

**Still open — widget/control choices (needed before coding begins):**
- Property grid widget: `Wx::grid::Grid` vs scrolled panel of `FlexGridSizer` rows
- `wp_type` (enum: nav/label/sounding) — Choice control vs TextCtrl
- `color` (8-hex aabbggrr) — TextCtrl with validation (same pattern as existing `color_panel`)
- `lat`/`lon` — TextCtrl with decimal degree validation

**Deferred:** Could also surface new-object creation (new waypoint, new group).
Base class sharing between DB/E80 variants is a question for when E80 is tackled.


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


### [Show on Map combined zoom]

Multi-select Show on Map currently zooms to the last collection rendered
rather than the combined bounding box of all selected items.

Root cause: `_onShowMap` calls `addRenderFeatures` once per collection;
each call increments the server version; Leaflet zooms on each bump,
so only the final batch is covered.

Fix: accumulate all features across the loop, make a single
`addRenderFeatures(\@all_features)` call — one version bump, one zoom.
Requires `_renderCollection`/`_renderObject` to return feature lists
rather than calling `addRenderFeatures` internally.

Low priority. User can work around it.


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

### [schema migration strategy]

Once navMate.db is the authoritative data store, schema changes become a
serious problem. A major schema bump currently forces `resetDB()` + full
reimport from KML — destroying any data not in the KML source (hand-edited
waypoints, live E80 synced data, track imports, working sets, etc.).

Topics to work through when the next schema change arises:
- ALTER TABLE migrations vs. wipe-and-reimport — which changes are truly
  breaking vs. handleable with ALTER TABLE ADD COLUMN (nullable, default)?
- A migration runner keyed on `$SCHEMA_VERSION` in a_defs.pm.
- Backup strategy before any migration.
- Which data is "owned" by navMate vs. derivable from KML (only the latter
  can be safely re-imported without data loss).

