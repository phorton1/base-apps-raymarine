# navMate OpenCPN Plugin -- Design Notes

Thought-experiment notes for a future navMate spoke to OpenCPN, implemented
as a C++ OpenCPN plugin communicating with the existing navMate HTTP server.
Not scheduled.  Recorded here because the conversation produced concrete
answers to specific questions and a clear articulation of the value
proposition; both deserve to outlive the conversation.

Companion to `design_vision.md` (where this lives as a one-line entry under
deferred feature concepts) and `navops_hub_and_spoke` memory (which already
names winOpenCPN as a future spoke).


---

## Vision

A three-piece system:

- **navMate** -- canonical data hub.  Holds the rich representation, the
  group hierarchy, the provenance columns, the extended fields no other
  device understands.
- **OpenCPN** -- chart-rendering and user-interaction frontend.  Brings
  S-57 / ENC / raster charts, AIS, real-time GPS, and a well-developed
  navigation UI that navMate does not attempt to duplicate.
- **E80** -- on-boat plotter.  The actual chartplotter at the helm,
  reached over Ethernet via the RAYNET protocol stack in `apps/raymarine/NET/`.

The plugin is the bridge that lets navMate-managed objects live inside
OpenCPN's UI, and lets user edits in OpenCPN flow back through navMate
to the E80 (and to the FSH archive, and to anywhere else navMate has
spokes).

Reframed: this is not "another GPX sync plugin."  It is "navMate gets a
real chart engine, and OpenCPN gets a software-only Ethernet path to a
class of chartplotter that no other plugin reaches."

GPX file transport is explicitly **out of scope** for the plugin design.
navMate may grow general GPX import/export the way it has GDB and KML
import/export, but that capability lives in navMate proper, not in the
plugin.  The plugin path is what is interesting here.


---

## Unique Value

Stated carefully (not "the first" or "the only," but a real differentiator):

A software + Ethernet only path between OpenCPN and legacy Raymarine
E-Series chartplotters.  The current alternatives available to an E80
owner who wants to integrate OpenCPN are:

1. Run OpenCPN fully standalone and copy waypoints/routes by hand.
2. Buy hardware bridges (Actisense, Digital Yacht) to get NMEA data
   off the boat network -- which delivers instrument data but does
   **not** provide bidirectional waypoint/route/track sync, because
   the E80 does not expose WP management over NMEA.
3. Replace the E80 with a modern unit (expensive; requires rewiring).

The plugin would be the only option that requires no new hardware and
delivers true bidirectional object sync.

The moat is **not** the plugin itself -- anyone can write an OpenCPN
plugin.  The moat is the multi-year RAYNET reverse-engineering work
under `apps/raymarine/NET/`, which has no public OSS equivalent.
Raymarine never documented the E-Series Ethernet protocol.  The plugin
is the user-facing artifact that makes that work actionable for
non-developers.

The user demographic is small and shrinking (E-Series production ended
years ago) but stranded: people whose plotters still work do not replace
them.  For that group, the alternative to this plugin is no solution.

Cultural fit with OpenCPN's anti-vendor-lock-in posture is good.  Most
OpenCPN plugins consume NMEA broadcasts from proprietary systems; this
one would reach into the data-management layer of a proprietary system
the vendor has abandoned.  The protocol writeup alone carries community
value; the plugin makes it usable.


---

## Architectural Posture

navMate is the hub-of-record.  OpenCPN is a spoke.  The spoke is allowed
to be a lossy projection of the hub.  The hub never forgets what the
spoke does not carry.

This is the same hub-and-spoke pattern documented in `navops_hub_and_spoke`
memory and in the navOperations work in progress.  The OpenCPN spoke
follows the same contract as the E80 and FSH spokes: project rich navMate
records into the spoke's narrower model on push; reconcile spoke-side
changes back into the hub on pull.

Implication: the OpenCPN spoke does not need to carry navMate's full
attribute set.  It carries the OpenCPN-shaped slice (name, position,
icon, color, route membership, points) and lets navMate retain the rest
(provenance, companion_uuid, db_version vs e80_version, group hierarchy).


---

## Questions Answered

### Identity: what UUID model does OpenCPN use?

**Fact.**  OpenCPN uses standard RFC 4122 GUIDs -- 36 characters, dashed,
lowercase, 128 bits.  Stored in GPX as `<opencpn:guid>` extension elements.
Through the plugin API, the GUID is the primary addressing key for
add/update/delete operations on waypoints, routes, and tracks.

The `*Ex` family of plugin functions (`AddSingleWaypointEx`,
`DeleteSingleWaypointEx`, `UpdateSingleWaypointEx`, `AddPlugInRouteEx`,
`UpdatePlugInRoute`) all use GUID as the handle.  Plugins **can supply
their own GUID** at create time; if empty, OpenCPN generates one.

### Round-trip: will UUIDs survive each path through navMate?

| Direction                  | Behavior                                                   |
|----------------------------|------------------------------------------------------------|
| navMate -> OpenCPN via plugin    | **Clean.**  Plugin supplies GUID; OpenCPN preserves it. |
| OpenCPN -> navMate via plugin    | **Clean iff navMate UUID column is wide enough.**       |
| navMate <-> E80                  | Already works (E80 UUID is 8 bytes; navMate is 8 bytes).|
| ocpn -> navMate -> ocpn          | Clean if navMate widened to 128 bits.                   |
| ocpn -> navMate -> E80 -> back   | Clean **through the hub** -- E80 does not need to carry  the OpenCPN GUID; navMate retains it in the hub record. |

### Width mismatch: 64 vs 128 bits

**Fact.**  navMate UUID is 8 bytes / 64 bits.  E80 UUID is 8 bytes / 64
bits (deliberately matched).  OpenCPN GUID is 16 bytes / 128 bits.

**Derived.**  An OpenCPN-originated GUID does not fit losslessly in
navMate's current 64-bit UUID field.  Three responses:

1. **Widen navMate to 128 bits.**  Honest.  Schema change to the hub
   identity type.
2. **Mapping table in the OpenCPN spoke.**  Schema stays put; spoke
   carries per-object `(navmate_uuid <-> opencpn_guid)` mapping.
3. **Accept one-way identity.**  navMate-originated objects round-trip;
   OpenCPN-originated ones get a fresh navMate UUID on ingest.

Option 1 is the design target.  It scales without per-spoke state and
matches the existing byte-1 producer convention (`B2` = E80, `82` = RNS,
`4E` = navMate, `46` = FSH-originated) extended to a 128-bit layout
where E80 8-byte UUIDs embed losslessly in the low half and a navMate
namespace prefix occupies the high half.

### Cost of widening navMate to 128 bits

navMate stores UUIDs as `TEXT` in SQLite (confirmed in `navDB.pm`
schema).  SQLite TEXT is dynamic-length, so the column type does not
change going from 16-char to 32-char UUIDs.  Migration is purely a
content rewrite.

The migration fits the existing `openDB` version-walker pattern in
`navDB.pm` (lines ~206-340): one new `if ($stored eq '11.3')` block
that applies the same deterministic prefix transform to every
uuid-bearing column in every table.  Because the transform is uniform,
foreign-key references stay aligned automatically -- no ordering, no
temporary mapping table, no two-phase rename.  `$SCHEMA_VERSION` in
`n_defs.pm` bumps to `12.0` (integer-part = breaking change per the
comment at line 67-69).

Outside the migration, code rewrites are required at:

- `n_utils.pm:makeUUID` and `makeFSHUUID` -- produce 32-char strings
  while preserving the producer-byte convention at a designated offset.
- `navFSH.pm:fshToNavUUID` / `navToFSHUUID` -- pad FSH's fixed 8-byte
  UUIDs into the low half of the new 128-bit form.
- Anywhere that hardcodes `H16`, `pack/unpack` of 8-byte UUIDs, or
  length-16 string assumptions.

Non-DB persistent artifacts holding navMate UUIDs also need handling:

- `navMate.json` visibility file in `$temp_dir`.
- Any KML files previously exported with embedded navMate UUIDs.

These either get a one-shot rewrite or are treated as version-tagged
and reformatted on read.

### Tracks: are they bidirectional via the plugin?

**Fact.**  Yes.  `AddPlugInTrack` and `DeletePlugInTrack` exist in the
plugin API.  Tracks round-trip both ways through the plugin.

But `PlugIn_Track` has only `m_NameString`, `m_StartString`,
`m_EndString`, `m_GUID`, and `pWaypointList`.  No description, no
extension hook, no metadata slot.  At the in-memory plugin API surface
there is nowhere to attach `companion_uuid` or other navMate-only
fields.

**Resolution.**  navMate keeps them.  The hub record retains
`companion_uuid`, provenance fields, db_version/e80_version, etc.
When the user edits the track in OpenCPN and the change flows back,
navMate looks up its hub record by GUID and re-applies the spoke-side
edit to the rich record, leaving extended fields untouched.

This is the same pattern as E80 -- E80 stores name/points but not
provenance; provenance lives in the navMate hub record.

### Extended data: can custom metadata round-trip through OpenCPN?

**Fact.**  At the in-memory plugin API level: no.  The class fields are
fixed.  `PlugIn_Waypoint` has `m_MarkDescription` and a hyperlink list
that could be abused; `PlugIn_Track` has nothing usable.

**Inferred (not verified by reading OpenCPN source).**  GPX file-level
custom-namespace extensions (`<navmate:companion_uuid>...`) are likely
**not** preserved on OpenCPN re-export -- OpenCPN appears to parse what
it knows into its in-memory model and re-serialize from that model,
dropping unknown namespaces.  This matters only if a GPX file path is
ever added; for the plugin path it is moot.

**Architectural answer.**  Extended data does not need to round-trip
through OpenCPN -- it needs to round-trip through navMate.  As long
as the hub record persists with extended fields attached, the OpenCPN
spoke can be lossy without losing data.


---

## Tradeoffs

### Plugin path vs file path

| Aspect            | Plugin path                | GPX file path (excluded)        |
|-------------------|----------------------------|----------------------------------|
| Identity          | Clean (GUID is primary key)| GUID discarded on import         |
| Live sync         | Possible                   | One-shot transfer only           |
| Extended metadata | Per-field class limits     | Possibly via namespace; uncertain|
| Code burden       | C++ plugin to maintain     | Trivial; just file IO            |
| Coolness factor   | High                       | Low                              |

Plugin path is the design target precisely because the file path
gives up the things that make the project interesting.

### 128-bit widening vs mapping table

Widening:
- (+) No per-spoke state, no mapping table to keep consistent.
- (+) Producer-byte convention extends naturally.
- (+) Future spokes with wide identity (anything using RFC 4122) fit.
- (-) Breaking schema change; bumps to 12.0; touches every UUID-handling
      code path.

Mapping table:
- (+) navMate keeps its 64-bit UUIDs; no schema change.
- (-) New failure mode: lost mapping = lost identity.
- (-) Spoke-local state to maintain, back up, recover.
- (-) Does not generalize to future wide-identity spokes.

Widening is the more honest design choice.

### C++ plugin maintenance burden

OpenCPN plugin API is not static.  The `*Ex` function family is newer
than the original API; OpenCPN 5.14 introduced API 1.21.  A plugin
maintained against a moving upstream is real ongoing cost: rebuild
against new SDK versions, handle deprecations, repackage for
distribution channels.

The HTTP server in navMate (`navServer.pm`, port 9883) is already
the right abstraction boundary -- the plugin would be a thin C++ HTTP
client + an OpenCPN event listener.  This minimizes the plugin's
surface area against OpenCPN's API and keeps most of the logic on the
Perl side where it belongs.


---

## Open Questions

Not settled in this design session.  Each is a gating question for
whether and how the plugin would actually work.

1. **Change-event subscription.**  When the user creates / edits /
   deletes an object in OpenCPN's UI, does the plugin receive a
   callback, or does it have to poll `GetWaypointGUIDArray` /
   `GetRouteGUIDArray` / `GetTrackGUIDArray` and diff?  `SetPluginMessage`
   is broadcast but does not obviously deliver edit events.  This is
   the gating question for *live* two-way sync.

2. **Field-level read-back from user edits.**  For each navMate-managed
   attribute on each object type, does the plugin API expose enough to
   detect what the user changed?  Particularly: color, icon, comment,
   route membership, visibility, free-standing-vs-route-only status.
   FS#2803 already flagged that isolated-vs-route is not exposed; there
   may be other gaps.

3. **Plugin API version churn.**  Stability of the `*Ex` family across
   OpenCPN 5.14 and forward.  Backward-compat strategy if the API
   changes between releases.

4. **Hierarchy projection.**  OpenCPN does not have navMate's nested
   group concept.  Routes and tracks are flat; waypoints have an optional
   flat "layer" concept (read-only collections loaded from a GPX file).
   Projecting navMate's nested groups is one-way lossy.  Reconciling
   OpenCPN-originated waypoints back into navMate requires a bucketing
   policy (e.g. "orphans go to a `[OpenCPN]` group").  This is a hub
   contract question, not specific to OpenCPN -- any flat-model spoke
   raises the same issue.

5. **Convergent first-creation.**  An object created independently on
   both E80 and OpenCPN, neither side aware of navMate, that navMate
   later ingests from both spokes.  Arrives as two distinct hub records.
   Merging is fuzzy name+lat/lon reconciliation, identical to the
   problem already present at the E80 spoke.  UUID width does not help.

6. **Unknown-namespace preservation in OpenCPN GPX writer.**  Only
   relevant if a GPX file path is ever added.  Reading the
   `NavObjectCollection` GPX writer in the OpenCPN source would
   settle it.


---

## Status

Thought experiment, 2026-05-17.  Not committed, not scheduled.

What this doc records is what would need to be true and what would
need to be built; not a decision to build it.  The schema-widening
question in particular is hard-gated by `feedback_schema_guard` memory
and would require explicit confirmation before any code change.
