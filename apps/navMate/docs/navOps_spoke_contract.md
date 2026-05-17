# navMate -- navOps Spoke Contract

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)** --
**[navOperations](navOperations.md)** --
**Spoke Contract** --
**[KML Specification](kml_specification.md)** --
**[GE Notes](ge_notes.md)**

Folders: **[Raymarine](../../../docs/readme.md)** --
**[NET](../../../NET/docs/readme.md)** --
**[FSH](../../../FSH/docs/readme.md)** --
**[CSV](../../../CSV/docs/readme.md)** --
**[shark](../../../apps/shark/docs/shark.md)** --
**navMate**

## Overview

navOperations is an n-point **hub-and-spoke** system. The navMate canonical model
(SQLite WGRT schema, see [Data Model](data_model.md)) is the hub -- the richest
representation. Every other transport is a **spoke** -- a lossy projection of
the hub.

This document defines what a spoke module must provide to participate in
navOperations: the data-flow seam where transport-specific encodings cross over
to the canonical clipboard form, the dispatch contract for context-menu
operations, and the synchronization primitives the spoke participates in.

Two spokes exist as of Phase 3A:

| Spoke | File | Source state | Sync model |
|---|---|---|---|
| E80  | `apps/navMate/navOpsE80.pm` | live WPMGR + TRACK service hashes (`apps/raymarine/NET/d_WPMGR.pm`, `d_TRACK.pm`) | asynchronous -- NET events, `$progress` shared hash, inner brackets via `apps/raymarine/NET/a_bracket.pm` |
| FSH  | `apps/navMate/navOpsFSH.pm` | in-memory `$navFSH::fsh_db` loaded from an `.fsh` archive on disk | synchronous -- direct hash mutation, no inner brackets, file save explicit via `Save FSH` menu |

Phase 3B will add E80<->FSH cross-spoke operations as composed pipelines
through the hub. No bespoke direct adapter is permitted: when a direct spoke-
to-spoke shortcut looks tempting, the answer is "widen the hub," not "carve a
side-channel."

The hub itself has its own module set: `navOpsDB.pm` plus DB-side helpers
in `navDB.pm`. The hub is not formally "a spoke," but for `_doDelete` /
`_doPaste` / `_doNew` / `_doPush` dispatch purposes the DB panel routes
through the same dispatch chain.

## The Clipboard Contract

All clipboard items live in canonical form:

- **UUIDs** are 16-char lowercase hex with no dashes (navMate's storage form
  in `navDB`). FSH's dashed-uppercase form (`B2C4-3C00-81B6-XXXX`), E80's
  binary form, and any future spoke's encoding all normalize at the snapshot
  seam.
- **Lat/lon** are decimal degrees. E80's 1e7-scaled signed integers and any
  other spoke's encoding normalize at the snapshot seam.
- **Names and comments** are canonical strings. FSH's Z16-padded form is
  stripped to canonical at the read seam (in `fshBlocks.pm`); written back
  through `_truncForFSH` / `_truncForE80` at the write seam.
- **Field set** is the rich union of all spoke fields: name, comment, lat, lon,
  sym, depth (cm), temp_k (K x 100), date (days since epoch), time (sec since
  midnight), color, route_points / members lists.

The snapshot seam is `_snapshotE80Node` / `_snapshotFSHNode` / `_snapshotDBNode`
in `navOps.pm`. All three convert from spoke-specific storage to clipboard
canonical form. The inverse direction (clipboard -> spoke storage) happens
at the boundary of each spoke's paste/push handlers, using `navToFSHUUID`,
`navToE80wpmgr-format-conversion`, etc.

## What a Spoke Module Provides

A spoke module is a Perl file in `apps/navMate/` continuing `package navOps`.
It implements the following functions and exposes the listed integration
points elsewhere.

### Snapshot and identity normalization

- `_snapshot<Spoke>Node($db_or_service, $node)` (lives in `navOps.pm` next
  to the other snapshot helpers, NOT in the spoke module). Converts a wx tree-
  node descriptor into clipboard-canonical form. Responsible for:
  - UUID format conversion (spoke -> navMate no-dash lower)
  - Lat/lon conversion (spoke scale -> decimal degrees)
  - Member / route_point list materialization with recursive UUID conversion
  - Header expansion (`header` and FSH's `track_group` rollup into individual
    items the same way `_snapshotE80Node`'s header expansion works)
### Dispatch handlers (in the spoke module)

Per-operation handlers paralleling `navOpsE80.pm`:

| Handler family | Subs |
|---|---|
| Delete dispatcher + helpers | `_delete<Spoke>`, `_delete<Spoke>Waypoints`, `_delete<Spoke>Groups`, `_delete<Spoke>GroupsAndWPs`, `_delete<Spoke>Routes`, `_delete<Spoke>Tracks`, `_remove<Spoke>RoutePoint` |
| New handlers | `_new<Spoke>Waypoint`, `_new<Spoke>Group`, `_new<Spoke>Route` |
| Paste dispatcher + helpers | `_paste<Spoke>`, `_pasteAllTo<Spoke>`, `_pasteNewAllTo<Spoke>`, `_pasteBeforeAfter<Spoke>` (+ per-type granular helpers) |
| Push handlers | `_pushTo<Spoke>` (DB -> spoke), `_pushFrom<Spoke>` (spoke -> DB) |
| Cut helpers | `_cut<Spoke>Waypoint`, `_cut<Spoke>Group`, `_cut<Spoke>Route` (consumed by the paste handlers when the clipboard `cut_flag` is set) |
| Spoke helpers | `_<spoke>WPGroup`, `_<spoke>WPRoutes`, `_deconflict<Spoke>Name`, `_truncFor<Spoke>`, `_refresh<Spoke>` (latter lives in `navOps.pm` to avoid circular deps; the spoke just calls it) |

The spoke module's package declaration is `package navOps;` so all handlers
are reachable as `navOps::_delete<Spoke>(...)` from the central dispatcher
in `navOps.pm`.

### Field-length limits and uniqueness

Each spoke declares (or imports) its field-length limits and enforces them
at the boundary using a `_truncFor<Spoke>` helper that truncates with
`warning(...)`. Both E80 and FSH happen to use the same limits today
(name <= 15, comment <= 31; FSH's are declared locally in `fshUtils.pm`
as `$FSH_MAX_NAME` / `$FSH_MAX_COMMENT`, numerically equal to
`$E80_MAX_NAME` / `$E80_MAX_COMMENT` from `apps/raymarine/NET/a_defs.pm`).

Spokes also enforce per-type name uniqueness within the spoke's namespace
via `_deconflict<Spoke>Name`. The DB spoke does NOT enforce uniqueness --
multiple navMate items of the same type may share a name (distinguished by
UUID).

### Lossy-transform pre-flight

`_preflightLossyTransform($items, $direction)` in `navOps.pm` runs before
any cross-panel operation that could lose data. Directions supported as of
Phase 3A:

| Direction | What it checks |
|---|---|
| `db_to_e80` | name > 15, comment > 31, route color not in E80 palette |
| `e80_to_db` | route/track color mismatch against existing DB record |
| `db_to_fsh` | same as `db_to_e80` (FSH inherits identical limits + palette) |
| `fsh_to_db` | same as `e80_to_db` (FSH color is also a palette index) |

New spokes that introduce different constraints (e.g. winOpenCPN with no
character-length limits but with strict GPX schema) would add additional
direction strings.

### Spoke-wide name and uuid-presence sets

`_spokeNameAndUUIDSets($panel)` in `navOps.pm` returns `(\%wp_names,
\%grp_names, \%rte_names, \%have_uuid)` for the spoke. Used by paste
pre-flight Step 8 (spoke-wide name collision) and by the route-paste-
member-WP-exception logic. New spokes extend `_spokeNameAndUUIDSets` with
a fresh `elsif ($panel eq '<spoke>')` branch.

## Synchronous vs Asynchronous Spokes

Spokes vary in whether their mutations are immediate or queued through
the NET layer:

- **Asynchronous spokes** (E80) queue commands through `d_WPMGR` /
  `d_TRACK` services and rely on a `Pub::WX::ProgressDialog` polling a
  shared `$progress` hash to track the NEW_ITEM / GET_ITEM / MOD_ITEM
  cascade.  Operations may take seconds to complete.
- **Synchronous spokes** (FSH) mutate the in-memory data structure
  directly and return.  No ProgressDialog renders; operations complete
  within a single wx idle tick.

A future spoke (e.g. a USB sync with its own event stream) declares
its own progress-handling story consistent with whichever model fits.

## Adding a New Spoke

The mechanical checklist:

1. Author `apps/navMate/navOps<Spoke>.pm` continuing `package navOps`. Mirror
   the structure of `navOpsE80.pm` or `navOpsFSH.pm` depending on whether the
   spoke is async or sync.
2. Add `require navOps<Spoke>;` near the top of `navOps.pm`.
3. Add an arm to `_snapshotNodes`, `_doDelete`, `_doPaste`, `_doNew`,
   `_doPush`, `_spokeNameAndUUIDSets`, `_routeMembersMissingAtSpoke`,
   and `_destIsDescendantOfClipboard` in `navOps.pm`.
4. Add `panel='<spoke>'` cases to the `get*MenuItems` family in
   `navClipboard.pm`. For most spokes (E80 / FSH shape) these are additive
   alongside the existing cases; structurally different spokes (e.g. a flat
   key-value spoke) may need new menu shapes.
5. Add lossy-transform directions `db_to_<spoke>` and `<spoke>_to_db` to
   `_preflightLossyTransform` -- typically by adding the spoke to the
   spoke-set predicate at the top of that function.
6. Add `_refresh<Spoke>` helper to `navOps.pm` that calls the spoke's
   browser pane refresh.
7. Wire the spoke's wx browser pane (e.g. `winSpoke.pm`) to navOps: import
   `navClipboard`, import `navOps qw(buildContextMenu onContextMenuCommand)`,
   add `EVT_MENU_RANGE($this, 10200, 10299, \&_onNmOpsCmd)`, rewrite the
   right-click handler to call `buildContextMenu('<spoke>', ...)`, and add
   `_onNmOpsCmd` calling `onContextMenuCommand($cmd_id, '<spoke>', ...)`.

## Cross-References

- [navOperations](navOperations.md) -- full vocabulary, pre-flight rules,
  command semantics. The spoke contract is the mechanism that implements
  those rules across multiple transports.
- [UI Model](ui_model.md) -- the wx panel structure that spokes plug into
  via their browser pane (`winE80.pm`, `winFSH.pm`).
- [Implementation](implementation.md) -- module-level inventory; spoke modules
  are listed there.
- `apps/raymarine/FSH/docs/readme.md` -- FSH binary format and parsing layer
  the FSH spoke builds on.
- `apps/raymarine/NET/docs/readme.md` -- NET protocol services the E80 spoke
  builds on.
