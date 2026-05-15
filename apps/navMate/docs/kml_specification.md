# navMate - KML Specification

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)** --
**[navOperations](navOperations.md)** --
**KML Specification** --
**[GE Notes](ge_notes.md)**

Folders: **[Raymarine](../../../docs/readme.md)** --
**[NET](../../../NET/docs/readme.md)** --
**[FSH](../../../FSH/docs/readme.md)** --
**[CSV](../../../CSV/docs/readme.md)** --
**[shark](../../../apps/shark/docs/shark.md)** --
**navMate**

## Overview

navMate uses KML as a bidirectional transport between navMate's SQLite database and
Google Earth. This document specifies the KML structure navMate produces on export
and recognizes on import. The implementation is `navKML.pm`.

The one-time historical migration from `navMate.kml` to the initial navMate database
is handled separately by `navOneTimeImport.pm` and is not described here. See
[GE Notes](ge_notes.md) for the Google Earth workflow.

## File Structure

navMate produces two structural variants of the same KML schema. Both are valid
GE-renderable KML and use identical styles, ExtendedData tags, and object encodings.
They differ only in whether the content is wrapped in an outer `<Folder name="navMate">`.

### Whole-DB export - `exportKML($path)`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2" ...>
<Document>
  <name>navMate.kml</name>
  <Style id="nm1_track_ff0000ff">...</Style>
  ...
  <Folder>
    <name>navMate</name>
    ...content - all root collections...
  </Folder>
</Document>
</kml>
```

The single outer `<Folder name="navMate">` is the importable unit. When loading the
file in GE, this Folder can be dragged into My Places independently of the Document
wrapper.

### Subtree export - `exportKMLSubtree($path, $root_uuid)`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2" ...>
<Document>
  <name>navMate.kml</name>
  <Style id="nm1_track_ff0000ff">...</Style>
  ...
  ...content - the subtree's own top-level element...
</Document>
</kml>
```

The subtree's own top-level element (a collection `<Folder>`, a route `<Folder>`, a
track `<Placemark>`, or a waypoint `<Placemark>`) sits directly under `<Document>`.
There is no outer `<Folder name="navMate">` wrapper: it would duplicate the subtree's
own top-level Folder on re-import and produce double-nested collections. `$root_uuid`
may identify a collection (branch or group), waypoint, route, or track; the type is
auto-detected via the navDB `getCollection` / `getWaypoint` / `getRoute` / `getTrack`
lookup chain.

`<Style>` definitions are valid only inside `<Document>`, not inside `<Folder>`, so
they appear in the same position in both variants.

## Style Naming

Style IDs follow the pattern:

```
nm{V}_{type}_{color}
```

- `V` - `$KML_STYLE_VERSION`, a small integer constant in `navKML.pm`; incremented on
  any change to style structure, element attributes, or icon URLs
- `type` - one of: `track`, `route`, `nav`, `nav_sm`, `label`
- `color` - the 8-character `aabbggrr` hex string from the DB

Example: `nm1_track_ff0000ff` - version-1 style for a red track.

Embedding the version in the style ID ensures that if two versions of the navMate
Folder coexist in GE simultaneously, GE cannot misapply a style from one version
to placemarks in the other. Increment `$KML_STYLE_VERSION` on any change to the
style generation chain.

## Style Templates

| Type | Style content | Use |
|------|--------------|-----|
| `track` | `<LineStyle color width=2>` + `<PolyStyle fill=0>` | Track LineString |
| `route` | `<LineStyle color width=10>` + `<PolyStyle fill=0>` | Route display LineString |
| `nav` | `<IconStyle color scale=0.8 icon=wht-blank.png>` + `<LabelStyle color scale=0.7>` | Standalone nav waypoint |
| `nav_sm` | `<IconStyle color scale=0.6 icon=wht-blank.png>` + `<LabelStyle color scale=0.7>` | Route-member waypoint |
| `label` | `<IconStyle><Icon/></IconStyle>` + `<LabelStyle color scale=0.8>` | Label and sounding waypoints |

Sounding waypoints use the `label` template. Color is computed from `depth_cm` at
export time and is not stored in the DB: red (`ff0000ff`) when `depth_cm < 200`
(~6 ft), white (`ffffffff`) otherwise.

Only `wht-blank.png` is used as an icon image. Other GE icon URLs found in the source
`navMate.kml` are not reproduced on export.

## Color Encoding

Colors are stored in the navMate database as `TEXT` in KML/GE native `aabbggrr`
format (alpha-blue-green-red, 8 hex chars). This is GE's byte order - not `#aarrggbb`.
The stored value is used directly in KML `<color>` elements with no conversion.

At the E80 transport boundary, `_abgrToRouteColor(color)` converts to the nearest
E80 color index 0-5.

## ExtendedData Tags

All exported features carry navMate metadata in `<ExtendedData>`:

| Tag | Present on | Meaning |
|-----|-----------|---------|
| `nm_uuid` | all features | navMate UUID of the object |
| `nm_type` | all features | Object type (see table below) |
| `nm_ref` | route-member waypoints only | `1` = route-waypoint reference, not the canonical instance |

`nm_type` values:

| Value | Object |
|-------|--------|
| `collection` | Branch collection (general organizer) |
| `group` | Group collection (waypoint-only; maps to E80 WPMGR group on upload) |
| `waypoint` | Waypoint |
| `route` | Route (carried on the containing Folder, not a Placemark) |
| `track` | Track |

## Object Mapping

### Collections -> Folders

Each navMate collection maps to a KML `<Folder>`. The collection hierarchy maps
directly to the Folder nesting hierarchy.

```xml
<Folder>
  <name>Collection Name</name>
  <ExtendedData>
    <Data name="nm_uuid"><value>4e01...</value></Data>
    <Data name="nm_type"><value>collection</value></Data>
  </ExtendedData>
  ...child Folders and Placemarks...
</Folder>
```

### Waypoints -> Point Placemarks

```xml
<Placemark>
  <name>Waypoint Name</name>
  <styleUrl>#nm1_nav_ffffffff</styleUrl>
  <ExtendedData>
    <Data name="nm_uuid"><value>4e01...</value></Data>
    <Data name="nm_type"><value>waypoint</value></Data>
  </ExtendedData>
  <Point>
    <coordinates>lon,lat,0</coordinates>
  </Point>
</Placemark>
```

### Routes -> Folders

Routes are represented as Folders so GE displays both the route line and the
individual waypoint pins simultaneously. A route Folder is **not** a collection:
`nm_type=route` on the Folder distinguishes it from a collection Folder. On
re-import, a Folder with `nm_type=route` is treated as a route object and is
not recursed into as a collection.

```xml
<Folder>
  <name>Route Name</name>
  <ExtendedData>
    <Data name="nm_uuid"><value>4e01...</value></Data>
    <Data name="nm_type"><value>route</value></Data>
  </ExtendedData>

  <!-- Display LineString - generated from ordered route_waypoints; not stored in DB -->
  <Placemark>
    <name>Route Name</name>
    <styleUrl>#nm1_route_ff0000ff</styleUrl>
    <LineString>
      <tessellate>1</tessellate>
      <coordinates>lon,lat,0 lon,lat,0 ...</coordinates>
    </LineString>
  </Placemark>

  <!-- Route waypoint references, in route_waypoints.position order -->
  <Placemark>
    <name>Waypoint Name</name>
    <styleUrl>#nm1_nav_sm_ffffffff</styleUrl>
    <ExtendedData>
      <Data name="nm_uuid"><value>4e01waypoint...</value></Data>
      <Data name="nm_ref"><value>1</value></Data>
    </ExtendedData>
    <Point><coordinates>lon,lat,0</coordinates></Point>
  </Placemark>
  ...
</Folder>
```

Route waypoint references carry `nm_ref=1`. The same waypoint UUID appears twice in
the KML: once as a canonical Point Placemark in its owning collection, and once as
a route-member reference inside the route Folder. The reference is used to rebuild
`route_waypoints` on re-import; it does not create a second waypoint record.

Route geometry (the LineString) is generated from ordered `route_waypoints` at export
time. It is not stored in the DB. On re-import of an existing route, the LineString
coordinates are not used; the ordered waypoint references rebuild the geometry.

### Tracks -> LineString Placemarks

```xml
<Placemark>
  <name>Track Name</name>
  <styleUrl>#nm1_track_ff6666ff</styleUrl>
  <ExtendedData>
    <Data name="nm_uuid"><value>4e01...</value></Data>
    <Data name="nm_type"><value>track</value></Data>
  </ExtendedData>
  <LineString>
    <tessellate>1</tessellate>
    <coordinates>lon,lat,0 lon,lat,0 ...</coordinates>
  </LineString>
</Placemark>
```

## Re-import Semantics

### UUID matching

On re-import, `nm_uuid` is the primary identity key:

| Condition | Action |
|-----------|--------|
| `nm_uuid` in DB, no `nm_ref` | Update name, color, parent collection from KML |
| `nm_uuid` in DB, `nm_ref=1` | Append to `route_waypoints`; do not create or update waypoint record |
| `nm_uuid` absent from DB | Create new record with fresh UUID |
| Same `nm_uuid` twice, neither has `nm_ref` | Normalization error - flag and skip second occurrence |

### Track geometry on re-import

Track point geometry is authoritative in the navMate DB, sourced from E80 TRACK
protocol or CF card. On re-import of a track with a matching `nm_uuid`, only `name`
and `color` are updated; the KML coordinate string does not replace stored track points.

### Re-import is additive

Re-import adds new objects and updates existing ones. It does not delete. Objects
present in the DB but absent from the KML file are left untouched. To delete an
object, use navMate's delete operations, then re-export. See [GE Notes](ge_notes.md).

### Subtree import

`importKMLSubtree($path, $target_uuid)` imports the KML's top-level Folders and
Placemarks as direct children of the collection identified by `$target_uuid`, which
must be a branch collection. UUID matching, route-resolution ordering, and additive
semantics are otherwise identical to `importKML($path)`.

A whole-DB-exported KML imported via either entry point is unwrapped: the importer
recognizes the outer `<Folder name="navMate">` and recurses into its contents rather
than creating a `navMate`-named collection.

---

**Next:** [GE Notes](ge_notes.md)
