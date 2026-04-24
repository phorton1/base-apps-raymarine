# navMate — UI Model

**[Raymarine](../../../docs/readme.md)** --
**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**UI Model** --
**[Implementation](implementation.md)**

## Overview

navMate runs three UI surfaces simultaneously within a single process. Each is
suited to a distinct class of task; they are not alternatives. The surfaces are
described architecturally in [Architecture](architecture.md); this document covers
the behavioral and interaction model.

## Collection Tree (wx panel)

The collection hierarchy is presented as a wx tree control. Each node carries a
checkbox with three states — checked, unchecked, and partial (some children
checked):

- Checking a branch node checks all descendants
- Unchecking a branch node unchecks all descendants
- A branch node shows partial state when some but not all descendants are checked

**Visibility** — the checked state of the tree drives what appears on the Leaflet
canvas. A checked `'waypoints'` leaf makes its waypoints visible; an unchecked
`'tracks'` branch hides all tracks under it regardless of depth.

**Working set membership** — tree nodes may carry a secondary indicator (distinct
from the visibility checkbox) showing whether items belong to the current working
set. The exact visual treatment is open.

## Leaflet Canvas

The Leaflet canvas is the primary geographic surface. It renders:

- **Waypoints** — as point markers (symbol determined by `sym` field)
- **Routes** — as polylines connecting their ordered waypoints
- **Tracks** — as polylines

What is rendered is controlled by the collection tree checkbox state and the map
viewport. Collections are not themselves rendered.

### Two Layers: Active and Working Set

The canvas operates two conceptually distinct layers simultaneously:

**Active layer** — everything currently visible, determined by the tree checkboxes
and the map viewport. The "what I am looking at" view.

**Working set layer** — the current working set rendered as a distinct overlay,
visually distinguished from the active layer (color, opacity, or outline treatment
TBD). Shows what will be pushed to the connected device.

Both layers are visible at the same time. The working set layer does not replace
the active layer; it annotates it.

### Selection Operations

The Leaflet canvas supports multiple selection modalities, all producing the same
result: a set of selected WRGT UUIDs.

- **Individual click** — selects a single waypoint, route, or track
- **Rectangle drag** — selects all visible WRGT objects within the drawn bounds
- **Lasso** — selects all visible WRGT objects within a drawn polygon
- **Multi-select** — modifier key extends the current selection

Selected items can then be added to the current working set, removed from it,
moved to a different collection, or operated on via context menu or toolbar.

### Typical Working Set Workflow

1. Browse the collection tree, check regions of interest → active layer populates
2. Draw a rectangle or lasso on the canvas → items are selected
3. "Add to working set" → selected items appear in the working set layer
4. Inspect the working set layer, remove individual items that don't belong
5. Push working set to E80 (RAYNET for waypoints/routes; FSH export for tracks)

## Session State

UI state that persists between navMate invocations is stored separately from the
main SQLite database:

- Which collection tree nodes are checked (visibility state)
- Which working set is currently active
- Last Leaflet viewport (center coordinates and zoom level)
- Panel layout and window geometry

This is ephemeral presentation state, not application data. It lives in a settings
file (format TBD: ini, JSON, or small companion SQLite) alongside the main
database.

---

**Next:** [Implementation](implementation.md)
