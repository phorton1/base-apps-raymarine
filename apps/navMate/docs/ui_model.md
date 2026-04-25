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

- Checking a collection checks all descendants
- Unchecking a collection unchecks all descendants
- A collection shows partial state when some but not all descendants are checked

**Collection labels** — derived from content counts, not from a declared type:
`"Name (N track/tracks)"`, `"Name (N waypoint/waypoints)"`, `"Name (N route/routes)"`,
`"Name (N folder/folders)"`, or a combined count for mixed-content collections.

**Visibility** — the checked state drives what appears on the Leaflet canvas.
An unchecked collection hides all of its content regardless of depth.

**Working set membership** — tree nodes may carry a secondary indicator (distinct
from the visibility checkbox) showing whether items belong to the current working
set. The exact visual treatment is open.

## Leaflet Canvas

The Leaflet canvas is the primary geographic surface. It renders:

- **Waypoints** — rendering depends on `wp_type`:
  - `nav`: hollow colored circle; color from `waypoints.color` (hex); name in click-detail panel
  - `label`: text div at coordinate; no circle; the name is the label text
  - `sounding`: depth number at coordinate; red when depth is critical (depth_cm < ~200 cm / 6 ft)
- **Routes** — dashed, thicker polyline connecting ordered waypoints; waypoint positions
  shown as small markers along the line; visually distinct from tracks
- **Tracks** — solid colored polyline; color from `tracks.color`

What is rendered is controlled by the collection tree checkbox state. Collections
themselves are not rendered. For performance, tracks belonging to the currently
selected or visible collection are rendered rather than all tracks globally.

**Click-to-select** — clicking a waypoint, route, or track opens a persistent detail
panel showing the object's full record. Hover tooltips (name on mouseover) are also
present but are secondary. The detail panel does not require a hover; it persists
until a new item is clicked or the panel is dismissed.

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
result: a set of selected WRT UUIDs.

- **Individual click** — selects a single waypoint, route, or track
- **Rectangle drag** — selects all visible WRT objects within the drawn bounds
- **Lasso** — selects all visible WRT objects within a drawn polygon
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
