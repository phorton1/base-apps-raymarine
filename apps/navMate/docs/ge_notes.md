# navMate — Google Earth Notes

**[Raymarine](../../../docs/readme.md)** --
**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)** --
**[Context Menu](context_menu.md)** --
**[KML Specification](kml_specification.md)** --
**GE Notes**

## Role of Google Earth

The Leaflet canvas is navMate's primary geographic visualization surface. Google Earth
remains useful as an editing and archival canvas: a way to view, annotate, and organize
the navMate geographic dataset against GE's satellite imagery, then re-import the
changes into navMate.

## Round-Trip Workflow

1. **Export from navMate** — File → Export KML produces `navMate.kml`, containing all
   navMate data under a single `<Folder name="navMate">` inside a `<Document>` wrapper.

2. **Open in GE** — GE loads the file into Temporary Places as a Document node
   containing the navMate Folder.

3. **Edit in GE** — make changes within the navMate Folder (see Safe and Unsafe
   Operations below).

4. **Re-export from GE** — right-click the **navMate Folder** (not the Document
   wrapper) → Save Place As → `navMate.kml`. Always export the Folder, not the Document.

5. **Re-import into navMate** — File → Import KML reconciles the KML against the
   existing database using embedded `nm_uuid` tags. New objects are created; existing
   objects are updated.

6. **Version management** — before replacing the active navMate Folder in GE My Places,
   rename the old one (e.g., append the date) so it can be restored if needed.

## Safe Operations in GE

The following operations within the navMate GE Folder produce results navMate can
correctly reconcile on re-import:

- **Edit an existing item's name** — `nm_uuid` identifies it; the name update
  propagates on re-import
- **Move an existing waypoint's pin** — coordinate update propagates via UUID match
- **Edit a color or style** — color update propagates
- **Create new Placemarks or Folders** anywhere within the navMate hierarchy — items
  without `nm_uuid` are treated as new objects and receive fresh UUIDs on re-import
- **Reorder waypoints within a route Folder** — re-import reads order from KML sequence

## Unsafe Operations in GE

| Operation | Why unsafe |
|-----------|-----------|
| **Copy or duplicate any item** | The duplicate carries the original's `nm_uuid`. Re-import detects the duplicate UUID as a normalization error and skips the second occurrence. |
| **Delete any item** | Re-import is additive; GE deletions are silently ignored. The DB record survives untouched. |
| **Edit track LineString geometry** | Track point geometry is authoritative in the navMate DB. On re-import of an existing track, point coordinates are not replaced from the KML. See Track Editing below. |
| **Move route-member waypoints out of their route Folder** | Breaks the route structure on re-import. |
| **Move items between folders without intent** | Changes the owning collection on re-import — the new parent Folder's UUID becomes the object's collection. |

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
track paths in GE will not survive re-import — existing track point coordinates
are not replaced from the KML.

Track geometry editing (trim, split, join) is planned as a navMate application
feature and will be implemented in the navMate UI, not through GE.

---

**Back:** [KML Specification](kml_specification.md)
