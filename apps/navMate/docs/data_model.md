# navMate — Data Model

**[Raymarine](../../../docs/readme.md)** --
**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**Data Model** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)**

## Core Objects — WRGT

navMate manages four first-class navigation objects, collectively referred to as
**WRGT** (Waypoints, Routes, Groups, Tracks):

- **Waypoint** — a named geographic point with position, symbol, and optional metadata.
- **Group** — a named collection of waypoints; organizational container.
- **Route** — an ordered sequence of waypoints defining a planned path.
- **Track** — a recorded sequence of positions representing a path actually travelled;
  carries a date and is the primary historical record.

Routes are forward-looking planning artifacts. Tracks are historical voyage records.
The historical dataset is almost entirely Tracks and Waypoints — Routes were not used
historically and should not be assumed as the primary historical structure.

## Storage

SQLite is the authoritative store. All WRGT objects are persisted locally. The E80
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
intra-tick uniqueness. The full UUID structure is documented in `NET/docs/WPMGR.md`.

## Schema

navMate uses SQLite as its authoritative data store.

### collections

The collection tree is the organizational hierarchy for all WRGT objects. Every
WRGT exists in exactly one collection. Three node types structure the tree:

```sql
collections (
  uuid          TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  parent_uuid   TEXT REFERENCES collections(uuid),  -- NULL = root-level node
  node_type     TEXT NOT NULL,   -- 'branch', 'waypoints', 'routes', 'tracks'
  comment       TEXT DEFAULT ''
)
```

`'branch'` nodes contain only other collections and may appear at any depth.
The three leaf types contain only their corresponding WRGT objects and are always
terminal — a leaf node has no child collections.

Three default collections are created at installation and cannot be deleted:

| Name | node_type | Role |
|------|-----------|------|
| My Waypoints | `'waypoints'` | Default home for uncategorized waypoints |
| My Routes | `'routes'` | Default home for uncategorized routes |
| My Tracks | `'tracks'` | Default home for uncategorized tracks |

At the E80 transport boundary, `'waypoints'` leaf folders map to E80 WPMGR groups.
The "My Waypoints" default corresponds directly to the E80's own "My Waypoints" group.

### waypoints

```sql
waypoints (
  uuid              TEXT PRIMARY KEY,    -- navMate UUID (byte 1 = 0x4E)
  name              TEXT NOT NULL,
  comment           TEXT DEFAULT '',
  lat               REAL NOT NULL,       -- degrees WGS84
  lon               REAL NOT NULL,       -- degrees WGS84
  sym               INTEGER DEFAULT 0,   -- icon index 0-39; see NET/docs/WPMGR.md
  depth_cm          INTEGER DEFAULT 0,
  created_ts        INTEGER NOT NULL,    -- Unix epoch seconds; never NULL
  ts_source         TEXT NOT NULL,       -- see Timestamp Sources
  source_file       TEXT,                -- KML filename when sourced from KML
  source            TEXT,                -- 'kml', 'e80', 'user'
  collection_uuid   TEXT NOT NULL REFERENCES collections(uuid)
)
```

### routes

```sql
routes (
  uuid              TEXT PRIMARY KEY,
  name              TEXT NOT NULL,
  comment           TEXT DEFAULT '',
  color             INTEGER DEFAULT 0,
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
  color             INTEGER DEFAULT 0,
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

Working sets are named subsets of the WRGT database, curated for a specific
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

**The folder invariant.** Every waypoint, route, and track exists in exactly one
typed folder. This is navMate's own organizational principle — not inherited from
the E80, but chosen deliberately for manageability at scale. `collection_uuid` is
`NOT NULL` on all three WRGT tables. The E80's group concept maps cleanly to a
navMate `'waypoints'`-typed leaf folder; that alignment is a consequence of the
invariant, not its cause.

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

## KML as a Transport Layer

KML is an import/export format at the boundary between navMate and Google Earth.
GE serves as a secondary backup store (via KML export from navMate) and a tertiary
editing surface — objects created or modified in GE and re-exported flow back into
navMate through the standard import path. GE is not authoritative; navMate is.

**Round-trip identity.** navMate embeds its UUID in every exported KML object via
`<ExtendedData>`:

```xml
<ExtendedData>
  <Data name="navmate_uuid"><value>XX4E...</value></Data>
</ExtendedData>
```

On re-import, presence of `navmate_uuid` means update the existing object. Absence
triggers collision detection (name and coordinate proximity) or creation of a new object.

**KML import rules:**

- Names with a `~` suffix (e.g. `CatalinaIsland~`): visual overlays, not navigation
  waypoints — skip on import
- Route LineString Placemarks: skip; navMate generates geometry from ordered waypoint lists
- Track Placemarks where a Point co-locates at the track start with the same name:
  import the LineString, skip the Point
- Generic E80-default names (`Waypoint 2`, `Waypoint 3`): import with a source prefix
  (e.g. `[E80-0A] Waypoint 2`) to avoid collision with identically named objects
  from other sources
- Duplicate track names within a source file: import all; overlapping tracks of the
  same passage are the safety evidence base, not errors to deduplicate

## Sync Model

navMate operates fully — browse, edit, organize, build working sets — with no
transport active. The local SQLite database is always sufficient for local work.
A transport is an optional, user-activated session concern, not a permanent
connection navMate depends on.

When a live transport is active and the user initiates sync, navMate reconciles
its local UUID set against the transport's UUID set:

- Objects navMate has that the transport does not → candidates for push
- Objects the transport has that navMate does not → candidates for pull
- UUID collisions with differing content → conflicts requiring resolution policy

Different transport types have different sync models:

| Transport | Activation | Sync model |
|-----------|------------|------------|
| RAYNET/E80 | Live connection, user-initiated | UUID set reconciliation via WPMGR |
| KML/GE | File open or export dialog | Import with collision detection; export with UUID embedding |
| FSH file | File open or export dialog | Batch import; track export for manual E80 load |

UUID reconciliation applies only to live transports. File-based transports use
import/export operations — they do not maintain a UUID set to reconcile against.

WPMGR handles waypoints, routes, and groups bidirectionally over RAYNET. Track
downloads use the TRACK protocol and are one-directional (pull only) — that is a
property of the RAYNET transport layer, not of the schema.

Conflict resolution policy is an **open design question.** RNS's approach
(user-visible per-item "send to network" flags) is documented as a reference
anti-pattern in the protocol notes.

## Data Migration

The initial population of navMate's SQLite store comes from three source segments:

1. **Voyage records** — Rhapsody and Mandala KML log files, enriched with temporal
   metadata from phorton.com's `map_data/` index files. Those index files link track
   names and KML source files to voyage story pages, which carry dates. Import
   sequence: parse KML geometry → cross-reference track name and `source_file` against
   the `map_data/` index → if matched, back-fill `ts_start`/`ts_end` and set
   `ts_source = 'phorton'`; otherwise `ts_source = 'import'`. Where the HTML story
   pages themselves carry more precise date information, they are a secondary source
   for the same enrichment pass.

2. **Recent material** — current active area data from Navigation.kml and similar
   GE exports. Tractable KML parsing.

3. **Messy middle** — organically accumulated tracks between the end of the voyage
   narrative and the current active material. No structure, no consistent naming;
   requires manual triage. Approached last.

---
