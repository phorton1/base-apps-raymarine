# navMate - winMultiEditor

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)** --
**[navOperations](navOperations.md)** --
**[Spoke Contract](navOps_spoke_contract.md)** --
**[KML Specification](kml_specification.md)** --
**[GE Notes](ge_notes.md)** --
**[Testing](testing.md)** --
**[winFSH](winFSH.md)** --
**winMultiEditor**

Folders: **[Raymarine](../../../docs/readme.md)** --
**[NET](../../../NET/docs/readme.md)** --
**[FSH](../../../FSH/docs/readme.md)** --
**[CSV](../../../CSV/docs/readme.md)** --
**[shark](../../../apps/shark/docs/shark.md)** --
**[navMate](readme.md)**

> Design doc.  Not yet implemented.

## Purpose

winMultiEditor is a modal batch editor for changing shared properties
across multiple selected items in winDatabase.  The canonical case is
setting the `color` of N waypoints, routes, or tracks in a single
operation.  It is intended for enrichment passes (e.g. coloring a
voyage's imported tracks) and routine database maintenance.

## Scope

- winDatabase only in the initial release.  Counterparts for winFSH
  and winE80 are deferred -- those spokes have separate data layers
  (`$navFSH::fsh_db`, `$raydp`) that do not share `Pub::Database`
  update semantics with the navMate SQLite store.
- Real top-level objects only: waypoints, routes, tracks.
- Route points (the WP-under-route tree nodes) are excluded.
- Container nodes (branches, groups) themselves are excluded as edit
  targets.  Selecting a container does not implicitly include its
  contents -- selection is literal.

## Trigger

Right-click context menu, item `Batch Edit...`, shown only when the
selection contains N >= 2 eligible items.  For N = 1 (or N = 0) the
existing single-item edit path applies and no `Batch Edit` entry
appears.

## Editable Fields

| Field    | Waypoint | Route | Track |
|----------|----------|-------|-------|
| color    | yes      | yes   | yes   |
| comment  | yes      | yes   | -     |
| wp_type  | yes      | -     | -     |

Excluded from batch edit: `name`, `lat`, `lon`, `ts_start`, `ts_end`,
`ts_source`, `point_count`, point data, `source`, `position`, parent
collection.

The `sym` E80 symbol is intentionally not surfaced: the navMate
`waypoints` schema has no `sym` column.  `sym` is an E80/FSH boundary
concept and would belong to a winMultiEditor counterpart targeting
those spokes, not the navMate DB.

The `tracks` schema has no `comment` column either; comment is a
waypoint/route concern.  In a mixed-type selection that includes
tracks, the comment row's applies-to scope excludes the tracks.

In a mixed-type selection, fields with limited applicability
(`wp_type`, `comment`) appear in the dialog with their row scope
shown.  Only the rows applicable to a given item are written for that
item.

## Dialog Mechanics

A single modal dialog with `OK` and `Cancel`.  `OK` commits the entire
batch in one SQLite transaction; `Cancel` discards.  There is no
inline live-edit in the detail pane.

Each row in the dialog contains:

1. Field label.
2. The editing widget (color picker, dropdown, or text field).
3. A right-side scope tag -- either `(N items)` when the value is
   shared or `(multi N)` when the values differ across the applicable
   items.

The `(multi N)` sentinel describes the multi-value state of a field:
`N` is the count of items in the selection to which the field
applies, all of which will be touched if the user changes the
widget.  Example: with 4 waypoints + 2 routes selected and mixed
colors throughout, the color row reads `(multi 6)`; the `wp_type`
row reads `(multi 4)` because only the 4 waypoints participate.

## Per-field Widget Rules

### Comment (text)

The field placeholder text is literally `(multi N)` when comments
differ.  Three commit semantics:

- Untouched placeholder -> no change to any item.
- Placeholder deleted, field left empty -> commit empty string to
  all applicable items.
- New text typed -> commit that text to all applicable items.

The right-side tag mirrors the placeholder for visual consistency:
`(multi N)` while differing, `(N items)` once the user has committed
to a new value or accepted a shared starting value.

### Color, wp_type (enumerated)

These fields have no meaningful empty state.  A merely "changed"
control implies commit; an unchanged control implies no change.

The `(multi N)` state must be visually distinct from any real value:

- **color**: a greyed/hatched/empty swatch.  Cannot be a real grey
  swatch, since picking grey is a legitimate user choice.  Picking
  any real color commits it.
- **wp_type**: a synthetic `(multi)` entry preselected at the top of
  the dropdown, distinct from any real enum value AND from the
  existing `Custom` entry on the color dropdown (which is a real
  selectable value, not the multi-state).  Selecting any real value
  commits it; leaving the dropdown on `(multi)` writes nothing.

## Update Plumbing

The per-row write uses `Pub::Database::update_record`:

    $dbh->update_record(
        $table,
        \%dirty_fields,
        'uuid',
        $obj_uuid,
        1);     # subset mode -- only defined keys are written

In subset mode, any field whose value is `undef` is skipped (not
written as NULL).  The dialog assembles `%dirty_fields` from only the
fields the user actually changed, then calls `update_record` once per
target row.  All per-row calls run inside a single SQLite transaction
so the batch is atomic from the user's perspective.

`navDB.pm`'s existing `updateWaypoint` / `updateRoute` / `updateTrack`
wrappers are positional full-row writes and are NOT used by the
multi-editor; the sparse `update_record` call replaces them.

## Out of Scope

- winFSH and winE80 multi-edit counterparts (deferred).
- Lat/lon batch edits -- positional per-item, no plausible batch use.
- Name batch edits -- names are identity-bearing.
- Container (branch/group) batch edits.
- Recursive expansion of container selections.
- Cross-collection moves or reparenting (a different operation).
