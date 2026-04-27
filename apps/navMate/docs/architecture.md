# navMate — Architecture

**[Raymarine](../../../docs/readme.md)** --
**[Home](readme.md)** --
**Architecture** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)**

## Primary Statement

**navMate is a lifelong, device-independent nautical knowledge management system.
[RAYNET](../../../NET/docs/RAYNET.md)/E80 is the first transport. The knowledge base, data model, and UI are the
product. Everything else is a boundary adapter.**

## Scope

Chartplotters — Raymarine, Garmin, Simrad, Furuno, and OpenCPN alike — are
operationally scoped. They model the world as a mariner sees it from one boat, in
one region, on one passage. Their WRGT management surfaces are appropriate for dozens
of objects, not thousands. UUID-based management, limited organizational depth, no
concept of a multi-year voyage history spanning multiple oceans.

navMate operates at a fundamentally different scale and time horizon:

- **Where the vessel has been** — a complete voyage record, with temporal metadata,
  leg identity, and passage context, going back as far as records exist.
- **Where the vessel is now** — current area management, active routes, local waypoints.
- **Where the vessel might go** — forward planning, return passages, hypothetical routes.

This scope is not a feature added to a chartplotter companion app. It is the reason
navMate exists as an independent application.

## Who navMate Is For

The problem navMate solves is universal among mariners, regardless of how many boats
they own or how many miles they log.

A **recreational boater** who has cruised the same waters for twenty years has
accumulated something genuinely valuable: which anchorages are quiet in a north swell,
which channel markers are unreliable, which fuel dock has the best approach, where
the locals go that the charts don't show. That knowledge typically lives on one
chartplotter — or in their head — and is at risk every time they upgrade the device,
change boats, or simply fail to back up. navMate is where that knowledge lives
permanently, independent of any device.

A **liveaboard or long-distance cruiser** accumulates knowledge across years and
oceans. A complete voyage record — with dates, leg identity, anchorages, hazards, and
passage context — is irreplaceable. No chartplotter holds it all, and no chartplotter
was designed to. navMate holds the full record; any connected device gets the portion
relevant to where the boat is now.

A **delivery captain** steps onto dozens of boats a year, each with a different
chartplotter, none of which persist their knowledge. The problem is the same as the
recreational boater's, but compressed and repeated constantly across a career. navMate
travels with the captain, not with the boat. Step aboard with a regional scope loaded,
navigate with whatever chartplotter is installed, and pull back everything new learned
before handing the boat to its owner.

In every case, the same underlying need: **navigation knowledge that outlasts any
single boat or device, organized well enough to remain useful over a lifetime.**

## Relationship to Chartplotters and OpenCPN

Chartplotters — Raymarine E80/E120, Garmin, Simrad, Furuno, and software equivalents
like OpenCPN — are the traditional and probable continued surfaces through which most
navigation knowledge is originally created. They are also the go-to interface while
underway: when the boat is moving, the mariner is at the helm watching the chartplotter,
not at a laptop. A new anchorage discovered, a hazard noted, a waypoint dropped in the
moment — that knowledge enters the world through the chartplotter, not through navMate.

This makes the device relationship fundamentally **bidirectional**:

- **Before a passage** — navMate pushes a **working set** to the device: a named,
  user-curated subset of waypoints, routes, and tracks appropriate to the planned
  area. The working set is assembled in navMate and scoped from the full encyclopedic
  store down to what is immediately useful on the chartplotter.

- **During a passage** — the chartplotter is the primary interface. navMate is
  not involved in real-time navigation. The device accumulates whatever the mariner
  adds or modifies underway.

- **After a passage** — navMate pulls from the device, absorbing everything new:
  waypoints added at anchor, tracks recorded, routes modified in the field. That
  field knowledge is reconciled into navMate's permanent store, enriched with any
  metadata navMate can supply (dates, leg context, passage identity), and becomes
  part of the lifelong record.

This cycle — push a scope, navigate, pull the results — is the core operational
pattern navMate is built around. It is why sync is a first-class architectural
concern, not an afterthought.

Chartplotters are also **constrained** as management surfaces — appropriate for dozens
of objects in the current region, not thousands accumulated over a lifetime. navMate
makes those limitations visible and manageable: the full encyclopedic record lives
in navMate; what the device can hold gets scoped and pushed. What the device learns
gets pulled back and preserved.

The relationship to E80, OpenCPN, Garmin, and any future device is the same in kind:
a bidirectional boundary adapter, with navMate's own data model and UI unconstrained
by any device's limitations.

## UI Architecture — Three Simultaneous Layers

navMate runs three UI surfaces simultaneously, each suited to different tasks:

1. **Console window** — command/response and debug interface, always present.
   Power-user access and development debugging surface. Pattern established in [shark](../../shark/docs/shark.md).

2. **wx panels** — native OS widgets: list boxes, status displays, quick controls.
   Better than a browser for anything requiring immediate local response. wx is not
   the geographic surface.

3. **Leaflet** — the primary geographic canvas. Renders waypoints, routes, and tracks
   spatially. The wx application hosts a local HTTP server; Leaflet runs in a browser
   window alongside. This replaces Google Earth's visualization role.

These are not alternatives — all three run concurrently within the same process.

## Transport Abstraction

The [RAYNET](../../../NET/docs/RAYNET.md) protocol implementation ([NET/](../../../NET/docs/readme.md) — a standalone Perl library used by both
[shark](../../shark/docs/shark.md) and navMate) is the first transport layer. It is linked directly into the
navMate process — not a daemon, not a socket service.

navMate's core (knowledge base, UI, data model) is transport-agnostic. The transport
abstraction layer sits between the core and any connected device or file format.
RAYNET/E80 is the first implementation behind that interface. Future implementations
— OpenCPN's plugin API, NMEA 2000, other chartplotter protocols — plug in behind
the same interface without affecting the core.

**Transports are session-level, not permanent.** navMate operates fully with no
transport active — browsing, editing, and organizing the local database requires
no connection to anything. A transport is activated deliberately by the user for
a specific purpose: sync with this E80, import from this KML file, export for this
FSH archive. The 90% case — automatically syncing with a known E80 on network
connection — is a user preference layered on top of this model, not an architectural
assumption.

Transport types differ in their session model:

- **Live transports** (RAYNET/E80, future chartplotter protocols) — maintain an
  active connection; support UUID-set reconciliation and event-driven sync.
- **File transports** (KML, FSH) — activated per operation (open/export dialog);
  no persistent connection; no UUID-set reconciliation.

The hard-won RAYNET knowledge (UUID semantics, [WPMGR](../../../NET/docs/WPMGR.md) wire protocol, sync patterns,
E80 behavioral quirks) informs the design of that abstraction rather than defining it.

## Local-First Data Model

SQLite is the authoritative store. The E80 is not authoritative. No connected device
is authoritative. navMate maintains its own independent local state; sync is a
first-class operation, not an afterthought.

At sync time, navMate and a connected device present two divergent UUID sets. The sync
layer classifies each UUID as push-needed, pull-needed, or conflicted, and resolves
accordingly. This is fundamentally different from treating the E80 as a master to cache.

See [Data Model](data_model.md) for schema detail.

## Google Earth

Google Earth was the accidental archive for many years — not because it was suited
to the task but because nothing better existed. The Leaflet canvas replaces GE as
navMate's primary geographic visualization surface.

KML survives in two roles:

**Import** — the initial population of navMate's database comes from GE's
`My Places.kml` export. This is a one-time migration from GE to navMate, not an
ongoing relationship.

**Export** — navMate can produce a reorganized, deduplicated KML that supersedes
the original `My Places.kml` as a clean GE archive. This export is a first-class
deliverable: it represents the same lifelong geographic knowledge in a better-organized
form, and retains value even independent of the full navMate application. KML export
is not an afterthought; it is a peer use case alongside the Leaflet UI.

## Distribution Path

navMate is designed to travel a defined arc:

1. **Source** — run from cmd.exe Perl source; developer workflow.
2. **Public repo** — documentation and architecture publishable before any installer.
3. **Windows installer** — packaged for other E80/E120 owners; no Perl required.
4. **OpenCPN plugin** — a C++ plugin connecting to navMate's transport layer via local
   socket, giving OpenCPN users E80 access through navMate. Substantially later;
   architecture remains open to it without committing to build it.

The Windows installer capability uses the same Perl packaging infrastructure
established across Patrick's other deployable applications.

## Code Organization

navMate source modules are divided into two naming zones.

**Lower layers** use alphabetic prefixes with underscore-delimited lowercase names
(`a_defs.pm`, `c_db.pm`, etc.). The prefix encodes layer position — a lower letter
means a lower layer, and no module may import from a higher-prefixed module. The
namespace is assigned sparsely (initial assignments: `a_`, `c_`, `f_`, `j_`) to
leave gaps for future layer insertion without renaming.

**Application layer** modules use camelCase (`nmSession.pm`, `winMain.pm`, etc.).
These are above `navMate.pm` and carry wx dependencies. No strict ordering within
this zone.

| File | Zone | Status | Role |
|------|------|--------|------|
| `a_defs.pm` | lower | built | constants, type vocabulary |
| `a_utils.pm` | lower | built | $data_dir/$temp_dir setup, UUID generation |
| `c_db.pm` | lower | built | SQLite schema, raw CRUD, promoteWaypointOnlyBranches |
| `f_kml.pm` | lower | planned | production KML import/export with round-trip UUID |
| `f_wrgt.pm` | lower | planned | WRGT business logic, collection operations |
| `j_transport.pm` | lower | planned | NET adapter, session-level transport |
| `navMate.pm` | boundary | built | wx init, main loop |
| `nmServer.pm` | app | built | embedded HTTP server (port 9883); Leaflet bridge; GeoJSON + navMate query API; extends NET/h_server.pm |
| `nmUpload.pm` | app | built | upload collection to E80 via WPMGR (waypoints, routes, groups) |
| `nmSession.pm` | app | planned | session state (viewport, tree, working set) |
| `s_serial.pm` | app | built (temp) | serial port interface; temporary location — belongs in NET layer |
| `winMain.pm` | app | built | main frame, menu dispatch |
| `winBrowser.pm` | app | built | collection tree + detail panel (SplitterWindow); upload context menu |
| `w_frame.pm` | app | built | wx frame/panel base utilities |
| `w_resources.pm` | app | built | wx resource constants (IDs, menus, context menus) |

**`migrate/`** — one-time import scripts (KML pipeline, phorton.com enrichment).
Version-controlled but not production modules. Currently: `_import_kml.pm` (imports
`C:/junk/My Places.kml` into SQLite), `_enrich_phorton.pm`.

**`_site/`** — Leaflet applet HTML/JS, served by `nmServer.pm`'s embedded HTTP
server. Not a Perl layer.

---

**Next:** [Data Model](data_model.md) — [UI Model](ui_model.md) — [Implementation](implementation.md)
