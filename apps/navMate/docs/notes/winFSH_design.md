# winFSH Design Notes

Design thinking, deferred features, and architectural notes for the winFSH
browser and the navFSH data layer.  Items here range from confirmed decisions
to floating design concepts not yet scheduled.


---

## FSH Archive Format - Key Properties

ARCHIVE.FSH is an append-only binary archive.  Saves mark old blocks deleted
(active field = 0x0000) and append new blocks (active = 0x4000).  The file is
designed to grow to at least 2.2 GB and preserve the complete revision history
of every WGRT object across the entire life of a vessel -- every waypoint edit,
every route change, every track segment, all with original timestamps.

Raymarine never surfaced this capability in the E80 UI.  The E80 only ever
shows the current (active) block for each UUID.  navMate/winFSH is positioned
to be the first tool to expose this history to users.

The `$ACTIVE_BLOCKS_ONLY` flag in `FSH/fshFile.pm` (line 33) controls whether
deleted blocks are passed through the decode pipeline.  Flipping it to 0 is
sufficient to enable historical access -- the infrastructure already exists.
Each decoded WGRT record carries an `active` field (1=active, 0=deleted)
propagated from the block header.


---

## Phase 1 - Completed (2026-05-11)

navFSH.pm loads an FSH file into an in-memory fsh_db (UUID-keyed hashes for
waypoints, groups, routes, tracks).  winFSH.pm displays the active WGRT tree
in a read-only splitter window.  Tracks with embedded sentinel points are split
into TRACKNAME-NNN segments at load time (matching genKML conventions).

Active-blocks-only is the current load behavior.  The deleted-items path
described below is Phase 2 work.


---

## Deleted Items - Design Concepts (not yet scheduled)

### Loading

`navFSH::loadFSH` would accept an `$include_deleted` flag.  When set, fshFile
is loaded with `ACTIVE_BLOCKS_ONLY=0`, passing all blocks (active and deleted)
through the existing decode pipeline unchanged.

A winFSH menu item or checkbox "Show deleted items" would trigger a reload with
the flag set and rebuild the tree.

### Versioned UUID keys

The fsh_db hash keys are plain strings.  When a UUID appears in multiple blocks
(one active, one or more deleted revisions), the keys must be disambiguated.
Proposed convention:

- Active item: bare UUID key (unchanged from Phase 1)
- Deleted revisions: UUID-0001, UUID-0002, ... assigned in file order
  (earlier block in file = lower revision number = earlier in time)

This mirrors the TRACKNAME-NNN segment convention already in use.

Version suffix assignment must happen during block iteration, before the
UUID-keyed hash is built, since block order carries the temporal sequence.

### Parallel Deleted tree structure in winFSH

Active items occupy the existing tree folders (Groups, Routes, Tracks).
Deleted items appear in parallel folders:

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

Waypoints are not surfaced as a separate top-level folder in winFSH -- they
appear either under their parent group or under "My Waypoints".  This applies
equally to deleted waypoints: a deleted group revision carries its own waypoint
list as it existed at that revision.

### Group + waypoint versioning

A deleted group and its member waypoints are a unit.  Versioning applies to the
whole subtree together:

- The group gets key UUID-0001
- Its member waypoints also get versioned keys
- The waypoint group_uuid back-pointer is updated to match the versioned group key

Without this re-linking, member waypoints would be orphaned or incorrectly
parented to the active group.

"My Waypoints" in the deleted view contains standalone waypoints that had no
group membership at the time they were deleted -- distinct from waypoints that
became ungrouped when a group around them was deleted.


---

## winTreeBase - Planned Refactor (deferred)

winE80 and winFSH share substantial structure: ImageList/checkbox setup,
_makeCheckBitmap, _applyXxxVisibility, _buildXxxFeature, tree state helpers,
and (eventually) editors.  A base class `winTreeBase` is the right home for
this shared code once both windows are stable.

**Implementation rule (enforced now):** When adding visibility/feature-builder
code to winFSH, use identical sub names, signatures, and patterns to winE80.
The eventual lift into winTreeBase must be mechanical -- no divergence that
would complicate the refactor.

**Scope:** winTreeBase covers winE80 and winFSH.  A polymorphic API that also
encompasses winDatabase is a separate, larger discussion deferred further.


---

## genKML - Deleted Item Support (completed 2026-05-11)

`FSH/genKML.pm` was updated to split each WGRT type into active and deleted
arrays.  Active items are rendered with existing styles.  Deleted items are
rendered in a `Deleted/` sub-folder within each type folder, using gray styles
(ff808080 in KML AABBGGRR format):

    s_track_del, s_route_del, s_waypoint_del, s_group_del

This is a no-op when `ACTIVE_BLOCKS_ONLY=1` (the current default) since the
deleted arrays will always be empty.  Flip the flag and run against
`FSH/test/ARCHIVE.FSH` to exercise the deleted rendering path.


---

## Future - FSH Enrichment of Existing navMate Objects

Distinct from the import path.  FSH records carry data that formal navMate
objects lack: original creation timestamps on waypoints (even from 2007),
measured depths, and temperature readings.

The enrichment operation would match FSH records to existing navMate objects
by UUID and update those specific fields -- not bulk-import raw FSH content.
This is a separate, surgical operation and should not be conflated with
PASTE_NEW import.


---

## Future - Curated Import via PASTE_NEW

Specific reconciled FSH objects (segments, waypoints) that belong in the
navMate database would be imported through the standard PASTE_NEW path with
UUID remapping.  This is the winFSH right-click import path planned for a
later phase.

UUID format normalization is required at the import boundary: FSH UUIDs are
16 uppercase hex chars with dashes (e.g. B2C4-3C00-81B6-XXXX); navMate DB
uses 16 lowercase hex chars no dashes.  fshUtils.pm strToUuid/uuidToStr are
the conversion points.
