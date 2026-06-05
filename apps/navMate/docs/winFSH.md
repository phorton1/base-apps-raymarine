# navMate - winFSH

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
**winFSH** --
**[winMultiEditor](winMultiEditor.md)** --
**[E80Config](e80_config.md)**

Folders: **[Raymarine](../../../docs/readme.md)** --
**[NET](../../../NET/docs/readme.md)** --
**[FSH](../../../FSH/docs/readme.md)** --
**[CSV](../../../CSV/docs/readme.md)** --
**[shark](../../../apps/shark/docs/shark.md)** --
**[navMate](readme.md)**

## Purpose

The winFSH window is the navMate UI for browsing an FSH archive file
(`ARCHIVE.FSH`).  It is a sibling to winDatabase (the navMate SQLite
store) and winE80 (the live E80 unit), and it shares the winTreeBase
base class with winE80.

The data layer below winFSH is `navFSH.pm`, which loads an FSH file
into an in-memory `$fsh_db` (UUID-keyed hashes for waypoints, groups,
routes, and tracks).  Mutations from the right-click context menu land
in `$fsh_db` in memory; the `.fsh` file on disk is touched only when
the user explicitly invokes `Save FSH`.  This mirrors the
DB-with-revert mental model and avoids rewriting a multi-GB archive on
every edit.

## FSH Archive Format - Key Properties

`ARCHIVE.FSH` is an append-only binary archive.  Saves mark old blocks
deleted (`active = 0x0000`) and append new blocks (`active = 0x4000`).
The file is designed to grow to at least 2.2 GB and preserve the
complete revision history of every WGRT object across the entire life
of a vessel -- every waypoint edit, every route change, every track
segment, all with original timestamps.

Raymarine never surfaced this capability in the E80 UI.  The E80 only
ever shows the current (active) block for each UUID.  navMate/winFSH
is positioned to be the first tool to expose this history to users.

The `$ACTIVE_BLOCKS_ONLY` flag in `FSH/fshFile.pm` (line 33) controls
whether deleted blocks are passed through the decode pipeline.
Flipping it to 0 is sufficient to enable historical access -- the
infrastructure already exists.  Each decoded WGRT record carries an
`active` field (1 = active, 0 = deleted) propagated from the block
header.

## Track Segmentation

Tracks loaded from FSH may contain embedded sentinel points (latitude
matching `/^-0\.00/`) that mark segment boundaries within a single
`mta_uuid` track.  Sentinels stay in the `points` array as loaded;
segmentation happens at render and match time, not at load time.

The `TRACKNAME-NNN` naming convention is canonical for segment
identifiers (matching genKML conventions and the matcher pipeline)
wherever a segment needs its own identity.

## Deleted Items - Design Concepts

These describe the planned mechanism for exposing the FSH archive's
deleted-block history through winFSH.  Not yet wired into winFSH; the
genKML path described below is already in place.

### Loading

`navFSH::loadFSH` would accept an `$include_deleted` flag.  When set,
fshFile is loaded with `ACTIVE_BLOCKS_ONLY = 0`, passing all blocks
(active and deleted) through the existing decode pipeline unchanged.

A winFSH menu item or checkbox "Show deleted items" would trigger a
reload with the flag set and rebuild the tree.

### Versioned UUID keys

The `fsh_db` hash keys are plain strings.  When a UUID appears in
multiple blocks (one active, one or more deleted revisions), the keys
must be disambiguated.  Proposed convention:

- Active item: bare UUID key (unchanged from current load behavior)
- Deleted revisions: UUID-0001, UUID-0002, ... assigned in file order
  (earlier block in file = lower revision number = earlier in time)

This mirrors the TRACKNAME-NNN segment convention.

Version suffix assignment must happen during block iteration, before
the UUID-keyed hash is built, since block order carries the temporal
sequence.

### Parallel Deleted tree structure

Active items occupy the existing tree folders (Groups, Routes,
Tracks).  Deleted items appear in parallel folders:

    Groups/
      GroupA  (active)
      Deleted/
        GroupA-0001  (older revision)
    Routes/
      ...
      Deleted/
        ...
    Tracks/
      ...
      Deleted/
        ...

Waypoints are not surfaced as a separate top-level folder in winFSH --
they appear either under their parent group or under "My Waypoints".
This applies equally to deleted waypoints: a deleted group revision
carries its own waypoint list as it existed at that revision.

### Group + waypoint versioning

A deleted group and its member waypoints are a unit.  Versioning
applies to the whole subtree together:

- The group gets key UUID-0001
- Its member waypoints also get versioned keys
- The waypoint `group_uuid` back-pointer is updated to match the
  versioned group key

Without this re-linking, member waypoints would be orphaned or
incorrectly parented to the active group.

"My Waypoints" in the deleted view contains standalone waypoints that
had no group membership at the time they were deleted -- distinct from
waypoints that became ungrouped when a group around them was deleted.

## genKML Deleted-Item Rendering

`FSH/genKML.pm` splits each WGRT type into active and deleted arrays.
Active items render with the standard styles; deleted items render in
a `Deleted/` sub-folder within each type folder, using gray styles
(`ff808080` in KML `AABBGGRR` format):

    s_track_del
    s_route_del
    s_waypoint_del
    s_group_del

This is a no-op when `ACTIVE_BLOCKS_ONLY = 1` (the current default)
since the deleted arrays will always be empty.  Flipping the flag and
running against `FSH/test/ARCHIVE.FSH` exercises the deleted rendering
path.

## winFSH vs winE80 - Shared Base

winE80 and winFSH share substantial structure: ImageList/checkbox
setup, `_makeCheckBitmap`, `_applyXxxVisibility`, `_buildXxxFeature`,
tree state helpers (capture/restore of expanded, selected, and
first-visible items), and editor scaffolding.  The shared code lives
in `winTreeBase.pm`; winE80 and winFSH each declare
`use base 'winTreeBase'` and supply per-source abstract methods.

A polymorphic base that also encompasses winDatabase is a separate,
larger discussion.  winDatabase has its own data layer (SQLite via
`navDB.pm`) and per-row mutation semantics that do not currently map
to the winE80/winFSH model.
