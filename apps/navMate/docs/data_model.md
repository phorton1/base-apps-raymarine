# navMate — Data Model

**[Raymarine](../../../docs/readme.md)** --
**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**Data Model**

*This page is a stub. The data model will be developed once the RAYNET protocol
layer is production-complete in shark and the sync semantics are fully understood
empirically.*

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

UUID generation strategy for navMate-created objects is an open design question.
The E80 uses a structured 8-byte UUID format (device fingerprint + counter); navMate
must use a distinct byte pattern to avoid collisions with E80-native objects.

See `uuid_structure.md` in the project memory for current empirical findings.

## Sync Model

At startup (and on demand), navMate reconciles its local UUID set against the connected
device's UUID set:

- Objects navMate has that the device does not → candidates for push
- Objects the device has that navMate does not → candidates for pull
- UUID collisions with differing content → conflicts requiring resolution policy

Conflict resolution policy is an **open design question**. RNS's approach (user-visible
per-item "send to network" flags) is documented as a reference anti-pattern.

## Data Migration

The initial population of navMate's SQLite store comes from three source segments:

1. **Voyage records** — Rhapsody and Mandala logs from phorton.com's `map_index`
   files, joined against matching KML geometry. Fully structured; migration is
   automatable. Includes dates, leg identity, and passage context.

2. **Recent material** — current active area data from Navigation.kml and similar
   GE exports. Tractable KML parsing.

3. **Messy middle** — organically accumulated tracks between the end of the voyage
   narrative and the current active material. No structure, no consistent naming;
   requires manual triage. Approached last.

---
