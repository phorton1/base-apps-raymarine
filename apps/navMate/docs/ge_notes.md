# navMate - Google Earth Notes

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)** --
**[navOperations](navOperations.md)** --
**[KML Specification](kml_specification.md)** --
**GE Notes**

Folders: **[Raymarine](../../../docs/readme.md)** --
**[NET](../../../NET/docs/readme.md)** --
**[FSH](../../../FSH/docs/readme.md)** --
**[CSV](../../../CSV/docs/readme.md)** --
**[shark](../../../apps/shark/docs/shark.md)** --
**navMate**

## Role of Google Earth

The Leaflet canvas is navMate's primary geographic visualization surface. Google Earth
remains useful as an editing and archival canvas: a way to view, annotate, and organize
the navMate geographic dataset against GE's satellite imagery, then re-import the
changes into navMate.

## Round-Trip Workflow

1. **Export from navMate** - Database -> Export KML produces `navMate.kml`, containing all
   navMate data under a single `<Folder name="navMate">` inside a `<Document>` wrapper.

2. **Open in GE** - GE loads the file into Temporary Places as a Document node
   containing the navMate Folder.

3. **Edit in GE** - make changes within the navMate Folder (see Safe and Unsafe
   Operations below).

4. **Re-export from GE** - right-click the **navMate Folder** (not the Document
   wrapper) -> Save Place As -> `navMate.kml`. Always export the Folder, not the Document.

5. **Re-import into navMate** - File -> Import KML reconciles the KML against the
   existing database using embedded `nm_uuid` tags. New objects are created; existing
   objects are updated.

6. **Version management** - before replacing the active navMate Folder in GE My Places,
   rename the old one (e.g., append the date) so it can be restored if needed.

## Subtree Round-Trip via Right-Click

`winDatabase` also offers per-node KML operations through the tree's right-click
menu. These complement the full-DB Database menu commands and use the same
`navKML.pm` machinery and re-import semantics.

- **Export KML** is available on any non-root node (branch, group, waypoint, route,
  track, or route-point) and writes a KML file containing just that node and its
  descendants. The output has no outer `<Folder name="navMate">` envelope; the
  subtree's own top-level element sits directly under `<Document>`. This keeps
  round-trip mirror-clean - re-importing the same file under a target branch
  reproduces the source structure exactly, with no double-nesting.

- **Import KML** is available on branch collections only (not groups, not leaf
  objects) and imports the file's contents under the right-clicked branch. UUID
  reconciliation, additive semantics, and the safe/unsafe operation rules below
  all apply identically to subtree import.

Subtree files are useful for sharing a single voyage log, distributing a route
proposal, or backing up a working branch without exporting unrelated data. See
the [KML Specification](kml_specification.md) for the two structural variants.

## Safe Operations in GE

The following operations within the navMate GE Folder produce results navMate can
correctly reconcile on re-import:

- **Edit an existing item's name** - `nm_uuid` identifies it; the name update
  propagates on re-import
- **Move an existing waypoint's pin** - coordinate update propagates via UUID match
- **Edit a color or style** - color update propagates
- **Create new Placemarks or Folders** anywhere within the navMate hierarchy - items
  without `nm_uuid` are treated as new objects and receive fresh UUIDs on re-import
- **Reorder waypoints within a route Folder** - re-import reads order from KML sequence

## Unsafe Operations in GE

| Operation | Why unsafe |
|-----------|-----------|
| **Copy or duplicate any item** | The duplicate carries the original's `nm_uuid`. Re-import detects the duplicate UUID as a normalization error and skips the second occurrence. |
| **Delete any item** | Re-import is additive; GE deletions are silently ignored. The DB record survives untouched. |
| **Edit track LineString geometry** | Track point geometry is authoritative in the navMate DB. On re-import of an existing track, point coordinates are not replaced from the KML. See Track Editing below. |
| **Move route-member waypoints out of their route Folder** | Breaks the route structure on re-import. |
| **Move items between folders without intent** | Changes the owning collection on re-import - the new parent Folder's UUID becomes the object's collection. |

## The Additive Asymmetry

Re-import is **additive, not a sync**. It never deletes. This asymmetry has one
practical consequence:

**Deletions must flow from navMate outward via re-export. They cannot originate in GE.**

If an object is deleted from the navMate GE Folder and the file is re-imported,
the DB record remains. The next re-export restores the object to GE.

## Track Editing

GE allows editing LineString geometry (track paths) through its geometry editor.
This is **not part of the navMate/GE workflow**. Track geometry is authoritative
in the navMate DB, sourced from hardware (E80 TRACK protocol or CF card). Editing
track paths in GE will not survive re-import - existing track point coordinates
are not replaced from the KML.

Track geometry editing (trim, split, join) is planned as a navMate application
feature and will be implemented in the navMate UI, not through GE.

---

**Next:** [Home](readme.md)
