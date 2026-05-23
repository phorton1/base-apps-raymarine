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

## Purpose

winMultiEditor is a modal multi-item editor for changing shared properties
across multiple selected items in a tree window (winDatabase, winFSH).
The canonical case is setting the `color` of N waypoints, routes, or
tracks in a single operation.  It is intended for enrichment passes
(e.g. coloring a voyage's imported tracks) and routine database
maintenance.

## Scope

- Implemented for winDatabase and winFSH.  A winE80 counterpart is
  deferred -- the live E80 spoke has different write semantics
  (round-trip protocol with progress dialog) that do not fit the
  synchronous commit model used here.
- Real top-level objects only: waypoints, routes, tracks.
- Route points (the WP-under-route tree nodes) are excluded.
- Container nodes (branches, groups) themselves are excluded as edit
  targets.  Selecting a container does not implicitly include its
  contents -- selection is literal.

## Architecture: per-spoke descriptor

The dialog is data-source agnostic.  Each caller passes a descriptor
that supplies fetch/commit closures and capability flags:

    {
        fetch       => sub { my ($items) = @_; ... },
        commit      => sub { my ($items, \%changes) = @_; return \@touched_uuids },
        color_row   => 'abgr' | 'palette_index',
        has_wp_type => 0 | 1,
        has_sym     => 0 | 1,
        comment_max => undef | int,    # hard-reject if dirty value exceeds
    }

- `winDatabase` builds an `abgr` descriptor with `has_wp_type=1`,
  `has_sym=1` (schema 12.0), no comment limit.  Commit writes via
  `Pub::Database::update_record` inside a single SQLite transaction.
- `winFSH` builds a `palette_index` descriptor with `has_wp_type=0`,
  `has_sym=1`, `comment_max=$FSH_MAX_COMMENT` (31).  Commit mutates
  records in `$navFSH::fsh_db` in place, then the caller invokes
  `navFSH::markDirty()` once after the dialog returns.

The two color editors are intentionally distinct: `abgr` uses an ABGR
string end-to-end with a Custom entry plus Pick... button;
`palette_index` uses an integer index end-to-end with only the named
palette and a read-only swatch.  No translation between modes ever
runs.  ABGR never appears in any FSH-context UI.

## Trigger

Right-click context menu, item `Multi Edit...`, shown only when the
selection contains N >= 2 eligible items.  For N = 1 (or N = 0) the
existing single-item edit path applies and no `Multi Edit` entry
appears.

## Editable Fields

| Field    | Waypoint | Route | Track | DB  | FSH |
|----------|----------|-------|-------|-----|-----|
| color    | yes      | yes   | yes   | yes | yes |
| comment  | yes      | yes   | yes (DB only) | yes | yes (no track-comment field on FSH wire) |
| wp_type  | yes      | -     | -     | yes | -   |
| sym      | yes      | -     | -     | yes | yes |

Excluded from multi-edit: `name`, `lat`, `lon`, `ts_start`, `ts_end`,
`ts_source`, `point_count`, point data, `source`, `position`, parent
collection.

`wp_type` is a navMate-only concept: an INTEGER enum over 9 values
(`@WP_TYPE_NAMES`: nav / route_pt / sounding / label / hazard /
shipwreck / fish / diving / poi). E80 and FSH wire records have no
equivalent field; at the spoke boundary `wp_type` is derived from
`sym` via the current mapping (`navDB::wpTypeForSym`).

`sym` is the E80 wire-protocol symbol index (0..35, indexing into
`@E80_SYMS` in `NET/a_utils.pm`). Present on DB / FSH / E80 records.

`tracks` on the FSH wire have no `comment` field, but `tracks.comment`
exists in the DB (schema 12.0) and can be multi-edited via the DB
descriptor. The dialog's comment row applies to whichever items in the
selection have a comment-capable record (excluding FSH tracks).

The layout shows only the rows that apply to the current selection
(top-down, no gaps).  Within a row, controls pack left-to-right with
no holes for absent sub-controls -- e.g. the FSH color row has no
Pick... button and the scope tag slides left into the freed space.

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

### Color, wp_type, sym (enumerated)

These fields have no meaningful empty state.  A merely "changed"
control implies commit; an unchanged control implies no change.

The `(multi N)` state is visually distinct from any real value:

- **color (abgr)**: greyed swatch + the `(multi)` entry preselected
  at the top of a dropdown that also offers the named palette and a
  `Custom` entry.  `Pick...` opens a full color picker and commits
  whatever the user chooses as an ABGR string.
- **color (palette_index)**: same dropdown but with only the named
  palette -- no `Custom`, no `Pick...`, no ABGR ever exposed.  The
  swatch is a read-only paint computed from the selected index for
  visual feedback.
- **wp_type / sym**: a synthetic `(multi)` entry preselected at the
  top of the dropdown, distinct from any real enum value.  Selecting
  any real value commits it; leaving the dropdown on `(multi)`
  writes nothing. `sym` is a `Wx::BitmapComboBox` (via
  `nmResources::makeSymComboBox`) with icons from
  `apps/navMate/sym_catalog/clean*.png`; the dialog uses
  `EVT_COMBOBOX` for the dirty-tracking binding.

### Conservative per-item forward-map (DB descriptor)

When the user changed `wp_type` in the dialog and **did not** touch
`sym`, the DB descriptor's `commit` runs a per-item conservative
forward-map: each item's pre-edit snapshot is checked with
`navDB::isMapped(old_wp_type, old_sym)`; **mapped** items get
`sym` auto-updated in their dirty set to the new mapped default;
**off-map** (hand-set) items keep their existing sym. This mirrors the
single-editor's live forward-map but runs per item at commit time
rather than live in the UI. If both `wp_type` and `sym` were dirty,
the user's explicit choices on both win and no auto-update fires.

### Comment validation (hard reject)

If `descriptor->{comment_max}` is set and the dirty comment value
exceeds it, `OK` opens an error message box and does not commit --
the dialog stays open so the user can shorten the field.  The
TextCtrl is also constructed with `SetMaxLength(comment_max)` as a
soft guard.

## Commit Plumbing

The dialog itself owns no persistence logic.  After `OK`, it
assembles a sparse `%changes` hash containing only fields the user
actually edited and hands it to `descriptor->{commit}` which is
responsible for the per-spoke write.

For winDatabase, commit uses `Pub::Database::update_record` inside a
single SQLite transaction:

    $dbh->update_record(
        $table,
        \%dirty_fields,
        'uuid',
        $obj_uuid,
        1);     # subset mode -- only defined keys are written

In subset mode, any field whose value is `undef` is skipped (not
written as NULL).  All per-row calls run inside one
BEGIN/COMMIT transaction so the batch is atomic from the user's
perspective.  On any exception the transaction rolls back and commit
returns an empty touched list.

`navDB.pm`'s existing `updateWaypoint` / `updateRoute` /
`updateTrack` wrappers are positional full-row writes and are NOT
used by the multi-editor; the sparse `update_record` call replaces
them.

For winFSH, commit mutates the in-memory records of `$navFSH::fsh_db`
directly (color/comment/sym scalars on the existing shared hashes)
and returns the list of touched UUIDs.  After the dialog returns,
the caller (`winFSH::_onMultiEdit`) rerenders any touched-and-visible
items via the standard `removeRenderFeatures('fsh',[...])` +
`addRenderFeatures([...])` pattern and calls `navFSH::markDirty()`
once at the end -- the file is not written through until the user's
next Save File.

## Out of Scope

- winE80 multi-edit counterpart (deferred).
- Lat/lon multi-edits -- positional per-item, no plausible multi-edit use.
- Name multi-edits -- names are identity-bearing.
- Container (branch/group) multi-edits.
- Recursive expansion of container selections.
- Cross-collection moves or reparenting (a different operation).
