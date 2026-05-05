# navMate — Data Model

**[Raymarine](../../../docs/readme.md)** --
**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**Data Model** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)** --
**[Context Menu](context_menu.md)** --
**[KML Specification](kml_specification.md)** --
**[GE Notes](ge_notes.md)**

## Core Objects — WRT

navMate manages four first-class navigation objects, collectively referred to as
**WRTG** (Waypoints, Routes, Tracks, Groups):

- **Waypoint** — a named geographic point with position, type, and optional metadata.
- **Route** — an ordered sequence of waypoints defining a planned path.
- **Track** — a recorded sequence of positions representing a path actually travelled;
  the primary historical record.
- **Group** — a waypoint-only collection that maps one-to-one to an E80 WPMGR group
  on upload; the organizational unit for waypoint sets pushed to the chartplotter.

Routes are forward-looking planning artifacts. Tracks are historical voyage records.
The historical dataset is almost entirely Tracks and Waypoints — Routes were not used
historically and should not be assumed as the primary historical structure.

A group is a waypoint-only leaf collection stored with `node_type='group'` in the
collections table. Groups have no sub-collections, routes, or tracks — only direct
waypoints. On upload, each group maps one-to-one to an E80 WPMGR group. Group
membership is structural: a waypoint belongs to whichever group collection it resides
in, not via a separate association table.

## Storage

SQLite is the authoritative store. All WRT objects are persisted locally. The E80
and any other connected device are peers that navMate syncs with — not masters that
navMate caches.

navMate may carry metadata, organizational structure, and historical depth that has
no equivalent on any connected device. The schema is not constrained to what the E80
wire protocol can represent.

## Object Identity — UUIDs

All objects are identified by UUID. navMate is UUID-primary: name lookup is a
convenience layer, not the identity mechanism. E80 object names are not unique and
cannot serve as reliable identifiers across sync operations.

navMate-created UUIDs use byte 1 = `0x4E` (`N` for navMate), which does not collide
with E80-native UUIDs (byte 1 = `0xB2`) or RNS-created UUIDs (byte 1 = `0x82`).
Bytes 4–5 hold a persistent counter from navMate's SQLite store; bytes 6–7 provide
intra-tick uniqueness. The full UUID structure is documented in [WPMGR.md](../../../NET/docs/WPMGR.md).

## Schema

navMate uses SQLite as its authoritative data store. The schema version is tracked
in the `key_values` table and incremented on migrations.

### collections

The collection tree is the organizational hierarchy for all WRT objects. Every
WRT object exists in exactly one collection.

```sql
collections (
  uuid          TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  parent_uuid   TEXT REFERENCES collections(uuid),  -- NULL = root-level node
  node_type     TEXT NOT NULL DEFAULT 'branch',     -- 'branch' or 'group'
  comment       TEXT DEFAULT ''
)
```

Collections form the organizational hierarchy. Two `node_type` values are stored in
the DB:

| node_type | Meaning |
|-----------|---------|
| `'branch'` | General organizer — may hold any WRT objects and sub-collections |
| `'group'`  | Waypoint-only leaf collection — maps one-to-one to an E80 WPMGR group on upload |

A post-import pass (`promoteWaypointOnlyBranches`) promotes any `branch` that has
waypoints and no sub-collections, routes, or tracks to `node_type='group'`.
Mixed-content `branch` collections (waypoints alongside tracks or routes, for example)
remain `branch`. Every WRT object belongs to exactly one collection via a non-null
`collection_uuid` foreign key.

### waypoints

```sql
waypoints (
  uuid              TEXT PRIMARY KEY,    -- navMate UUID (byte 1 = 0x4E)
  name              TEXT NOT NULL,
  comment           TEXT DEFAULT '',
  lat               REAL NOT NULL,       -- degrees WGS84
  lon               REAL NOT NULL,       -- degrees WGS84
  sym               INTEGER DEFAULT 0,   -- E80 icon index 0-39; see NET/docs/WPMGR.md
  wp_type           TEXT NOT NULL DEFAULT 'nav',  -- see Waypoint Types
  color             TEXT DEFAULT NULL,   -- aabbggrr hex (GE byte order); NULL = type default
  depth_cm          INTEGER DEFAULT 0,   -- non-zero only for sounding waypoints
  created_ts        INTEGER NOT NULL,    -- Unix epoch seconds; never NULL
  ts_source         TEXT NOT NULL,       -- see Timestamp Sources
  source_file       TEXT,                -- originating KML path when sourced from KML
  source            TEXT,                -- 'kml', 'e80', 'user'
  collection_uuid   TEXT NOT NULL REFERENCES collections(uuid)
)
```

### Waypoint Types

`wp_type` determines how a waypoint is rendered and what its `name` field means:

| wp_type | Meaning | Rendering | name field |
|---------|---------|-----------|------------|
| `'nav'` | Navigation waypoint — anchorage, marina, landmark, track endpoint | Hollow colored circle; name in popup | Meaningful place name |
| `'label'` | Geographic text label — non-navigable area reference, scene annotation | Text at coordinate; no circle | Display text (may have `~` suffix or `~Date` suffix) |
| `'sounding'` | Depth measurement | Depth number at coordinate; red if `depth_cm < 200` (~6 ft) | Integer depth in feet |

Tilde (`~`) suffixes in `name` carry additional semantics for `label` waypoints
(see KML Import Rules below).

`depth_cm` is non-zero only for sounding waypoints. The name field holds the
original display string (the integer depth in feet); `depth_cm` holds the metric
conversion (feet × 30.48) for programmatic use.

`color` is the hex color resolved from the KML style at import time. For `nav`
waypoints the color encodes significance (green = anchorage, red = major hub,
yellow = notable, cyan = visited/secondary). For `sounding` waypoints color is
derived from depth (not stored separately). Null means use the type default.

### routes

```sql
routes (
  uuid              TEXT PRIMARY KEY,
  name              TEXT NOT NULL,
  comment           TEXT DEFAULT '',
  color             TEXT DEFAULT NULL,   -- aabbggrr hex (GE byte order)
  collection_uuid   TEXT NOT NULL REFERENCES collections(uuid)
)

route_waypoints (
  route_uuid    TEXT NOT NULL REFERENCES routes(uuid),
  wp_uuid       TEXT NOT NULL REFERENCES waypoints(uuid),
  position      INTEGER NOT NULL,    -- 1-based sequence
  PRIMARY KEY (route_uuid, position)
)
```

Waypoints in routes are first-class objects in the `waypoints` table —
independently queryable and reusable across multiple routes. Route geometry
(the connecting LineString) is generated on demand; it is not stored.

### tracks

```sql
tracks (
  uuid              TEXT PRIMARY KEY,
  name              TEXT NOT NULL,
  color             TEXT DEFAULT NULL,   -- aabbggrr hex (GE byte order)
  ts_start          INTEGER NOT NULL,    -- never NULL; may be import time if no source timestamp
  ts_end            INTEGER,
  ts_source         TEXT NOT NULL,       -- see Timestamp Sources
  point_count       INTEGER,
  source_file       TEXT,                -- KML filename when sourced from KML
  collection_uuid   TEXT NOT NULL REFERENCES collections(uuid)
)

track_points (
  track_uuid    TEXT NOT NULL REFERENCES tracks(uuid),
  position      INTEGER NOT NULL,
  lat           REAL NOT NULL,
  lon           REAL NOT NULL,
  depth_cm      INTEGER,             -- NULL when sourced from KML
  temp_k        INTEGER,             -- NULL when sourced from KML
  ts            INTEGER,             -- NULL when sourced from KML
  PRIMARY KEY (track_uuid, position)
)
```

`depth_cm`, `temp_k`, and `ts` in `track_points` are nullable by design. E80 TRACK
protocol downloads carry this data; KML imports do not. Both are valid; the schema
accommodates both without fabricating values.

### working sets

Working sets are named subsets of the WRT database, curated for a specific
operational context and used as the unit of push to a connected device.

```sql
working_sets (
  uuid          TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  comment       TEXT DEFAULT '',
  bbox_north    REAL,    -- derived from members; not prescriptive
  bbox_south    REAL,
  bbox_east     REAL,
  bbox_west     REAL
)

working_set_members (
  ws_uuid       TEXT NOT NULL REFERENCES working_sets(uuid),
  object_uuid   TEXT NOT NULL,
  object_type   TEXT NOT NULL,   -- 'waypoint', 'route', 'track'
  PRIMARY KEY (ws_uuid, object_uuid)
)
```

Working sets are populated interactively via the Leaflet canvas. The bounding box
is a derived summary of the members' geographic extent, computed on save and used
for UI purposes (zoom-to-set). It does not drive membership.

Tracks are full members of working sets. The E80 has no RAYNET path to receive
tracks; the FSH file transfer path handles this at push time. That asymmetry is
a transport-layer concern; the schema makes no distinction.

Working sets also serve as the unit for the working set layer of the Leaflet canvas —
showing what is staged for push as a distinct visual overlay.

### key_values

A general-purpose metadata table used to persist application-level values that
do not belong in the WRT or working set tables.

```sql
key_values (
  key    TEXT PRIMARY KEY,
  value  TEXT
)
```

Initial entries:

| key | Purpose |
|-----|---------|
| `schema_version` | Integer; incremented on schema migrations |
| `uuid_counter` | Integer; persistent counter for navMate UUID generation (bytes 4–5 of the UUID) |

The `uuid_counter` entry is incremented atomically within the same transaction as
each new object INSERT, ensuring the counter and the database objects it identifies
never diverge.

## Text Backup

`ExportToText` and `ImportFromText` (available in the Database menu) provide a
plain-text backup of the full database — one INSERT per row across all tables.
This is a general-purpose backup utility, independent of any KML or E80 transport.
ImportFromText calls `resetDB()` before importing to ensure a clean schema.

## Design Decisions

**lat/lon as REAL degrees — no northing/easting in the schema.** The 1e7 integer
scaling used in WPMGR wire packets, and the Mercator northing/easting values used
alongside them, are translation artifacts. They are computed at wire-encode time
inside the transport layer and never appear in the schema.

**Timestamps are never NULL.** `created_ts` on waypoints and `ts_start` on tracks
are always populated. When no GPS or source timestamp is available, the import
timestamp is used. `ts_source` records which case applies.

**Track unidirectionality is a transport concern, not a schema concern.** The E80's
TRACK protocol offers no upload path — tracks can only be pulled from the E80, not
pushed. That constraint belongs in the RAYNET transport layer. The schema stores
tracks without encoding assumptions about how they arrived.

**Route waypoints are first-class objects.** A waypoint that appears in a route
is stored once in `waypoints` and referenced by `route_waypoints.wp_uuid`. It is
not inlined as route geometry. The same waypoint can appear in multiple routes.

**The collection invariant.** Every waypoint, route, and track exists in exactly
one collection. `collection_uuid` is `NOT NULL` on all three WRT tables. Collections
are typed via `node_type`: `'branch'` for general organizer folders, `'group'` for
waypoint-only leaf collections that map to E80 WPMGR groups.

## Timestamp Sources

`ts_source` on both `waypoints` and `tracks` records the provenance and reliability
of the stored timestamp:

| ts_source | Meaning |
|-----------|---------|
| `'e80'` | From E80 TRACK or WPMGR protocol — GPS-derived, most reliable |
| `'kml_timespan'` | From KML `gx:TimeSpan` — track-level span, accurate |
| `'phorton'` | Enriched from phorton.com `map_data/` index — see Data Migration |
| `'import'` | No temporal information available; value is the import timestamp |

`ts_source = 'phorton'` is set once during the voyage log import pass and is
non-reversible — it records that the phorton.com enrichment has been applied.

GE-created objects (waypoints or tracks added interactively in Google Earth) carry
no timestamp in their KML export. These receive `ts_source = 'import'`.

## KML and GE

navMate uses KML as a bidirectional transport with Google Earth. The full KML
structure, round-trip semantics, and GE workflow are documented in
[KML Specification](kml_specification.md) and [GE Notes](ge_notes.md).

## Sync Model

navMate operates fully — browse, edit, organize, build working sets — with no
transport active. The local SQLite database is always sufficient for local work.
Transports are optional, user-activated concerns, not permanent connections
navMate depends on.

## Data Migration

The initial database was populated from a Google Earth export by `nmOneTimeImport.pm`.
The migration is substantially complete. `nmOneTimeImport.pm` is retained as a
fallback should subsequent changes to the original GE source data require re-import.

navMate is intended to be the primary UX for managing navigation data, but key
editing tooling — tree node ordering and generalized property editors — is not yet
built. Until that tooling exists, the GE/KML round-trip workflow remains a
practical editing path alongside the application. `nmKML.pm` handles all ongoing
KML import/export operations.

---
