# Data Enrichment Plan

This document captures the plan for enriching the navMate database with historical
GPS and FSH data. It is both a design reference and a runbook for future Claude
sessions picking up this work.

Companion document: `docs/private/Data_Fixup.md` -- specific track/waypoint
resolution items identified from the oldE80 data.


## Framing

The navMate `oldE80` collection folder is vestigial and will be retired after this
work is complete. It was created by running fshConvert on ARCHIVE2.FSH to produce
KML, then importing that KML into navMate. The KML round-trip was lossy: it dropped
timestamps, depth, and temperature from all track points, and timestamps, depth, and
temperature from all waypoints.

The FSH file itself (`FSH/test/working_oldE80.fsh`, committed as a baseline) is
the primary source for oldE80 data -- richer than the navMate oldE80 folder in
every dimension.

All other navMate collections (RhapsodyLogs, MandalaLogs, Michelle, MiscBocas,
Navigation, etc.) are authoritative. They represent years of curated work and are
not to be structurally altered by this effort. The goal is enrichment of existing
authoritative records and clean import of genuinely missing material.


## Two Enrichment Streams

These two streams write to entirely different columns in `track_points`, so they
are fully independent and can run in any order without conflict.

### Stream A -- FSH (ARCHIVE2 / working_oldE80.fsh)

The FSH file contains 8 raw E80-recorded tracks (unsegmented, with sentinel
points), plus waypoints with full field data.

Columns FSH can populate:
  track_points:  depth_cm, temp_k
  waypoints:     created_ts (from BLK_WPT time+date fields)
                 depth_cm   (sounding waypoints)
                 temp_k     (schema 11.2, to be added)

Track point timestamps are NOT present in FSH. BLK_TRK has no per-point ts.
BLK_MTA has no track-level timestamps either. The code comments confirm this:
"Odd that nothing on a track has a date-time".

### Stream B -- GPS Archive (.gdb files, C:/dat/Tracks)

Garmin GPS device files covering 2005-2011. Analyzed by a separate Claude session
using gpsbabel + C:\base_data\temp\raymarine\_scan_tracks.pl.

Columns GPS archive can populate:
  track_points:  ts
  tracks:        ts_start, ts_end


## GPS Archive File Inventory

File                                              Trks  TrkPts  Times   Date Range
2007-10-29-RhapsodyToCentralAmerica.gdb           180  149011  113236  2007-10-29 -- 2009-01-17
2009-06-16-RhapsodyNextSteps.gdb                   20    7837    1272  2009-09-26
2010-09-16-RhapsodyWithMichelle.gdb                83   20159   10545  2010-09-19 -- 2011-11-28
California/2005-10-08-Cat32ToMissionBay.gdb          4    9510    8517  2005-10-09
California/2005-11-28-BoatToOceanside.gdb            3   10999    9999  2005-11-26
California/2006-02-25-IslasDeCoronado.gdb            2    9559    9059  2006-02-25 -- 2006-02-26
California/2006-06-15-CaliforniaCoastTracks.gdb     36   34610   34110  2006-06-15 -- 2006-08-11
California/2007-09-15-CatalinaWithSteveRaw.gdb       8    3262    1762  2007-09-17 -- 2007-09-19
California/2010-07-27-MandalaLogs.gdb               49   15770   10533  2006-06-15 -- 2006-08-11
Sounding/2011-10-26-RawSoundings.gdb                 4     888     444  2011-10-26  (76 waypoints)
Sounding/2011-11-05-BahiaEscondidoRaw.gdb            3    1537    1037  2011-11-05  (63 waypoints)

MandalaLogs.gpx is byte-for-byte identical to MandalaLogs.gdb -- use the .gdb.


## File-by-File Disposition

Cat32ToMissionBay.gdb (2005-10-09, 4 tracks)
  Definitively pre-Mandala. Clean new import into a new top-level collection
  Before_Mandala. No existing navMate tracks to conflict with.

BoatToOceanside.gdb (2005-11-26, 3 tracks, + 2 routes, 27 rtepts, 26 wpts)
  Also pre-Mandala. Import into Before_Mandala. Routes and waypoints may be
  worth importing too -- evaluate at import time.

IslasDeCoronado.gdb (2006-02-25/26, 2 tracks)
  Date is ambiguous. Either Before_Mandala or early Mandala depending on purchase
  date. DECISION NEEDED: Patrick to confirm Mandala purchase date before assigning.

CaliforniaCoastTracks.gdb (2006-06-15 to 2006-08-11, 36 tracks, 34610 pts)
  Same date range as MandalaLogs but 2x the track points. Likely MandalaLogs is
  a proper subset (information was lost somewhere). Do NOT import blindly.
  ACTION: comparison pass first -- identify tracks absent from navMate entirely
  vs. denser versions of already-imported tracks.

MandalaLogs.gdb (2006-06-15 to 2006-08-11, 49 tracks, 10533 timed pts)
  Already in navMate but arrived via GE->KML with timestamps stripped.
  ACTION: timestamp backfill only -- match GPX trackpoints to existing
  track_points rows by lat/lon proximity, write ts. No geometry changes.

CatalinaWithSteveRaw.gdb (2007-09-17/19, 8 tracks)
  One month before Rhapsody departed San Diego (Oct 2007). May be absent from
  RhapsodyToCentralAmerica.gdb.
  ACTION: check whether RhapsodyToCentralAmerica covers Sep 2007 Catalina area.
  If not, clean import into Rhapsody folder.

RhapsodyToCentralAmerica.gdb (2007-10-29 to 2009-01-17, 180 tracks, 113236 pts)
  Entire southbound voyage, fully timestamped. Highest priority file.
  ACTION: comparison pass against Rhapsody folder -- identify (a) tracks already
  present with/without timestamps, (b) tracks entirely absent.
  Outcome: mix of timestamp backfill and new imports.

RhapsodyNextSteps.gdb (2009-09-26, 20 tracks, 1272 pts)
  Sparse. Overlap with navMate unknown. Lower priority; handle after main
  Rhapsody file is resolved.

RhapsodyWithMichelle.gdb (2010-09-19 to 2011-11-28, 83 tracks, 10545 pts)
  Panama/Central America era. navMate has Michelle outer folder; overlap unknown.
  Same approach: comparison pass before writing.

RawSoundings.gdb (2011-10-26, 4 tracks, 76 waypoints)
  Represented in navMate Michelle folder but likely with NULL ts.
  ACTIONS: (a) backfill trackpoint ts; (b) check .gdb for waypoint timestamps
  and backfill those too.

BahiaEscondidoRaw.gdb (2011-11-05, 3 tracks, 63 waypoints)
  Same situation as RawSoundings. Handle together.


## FSH-Specific Work (Stream A)

The 8 FSH tracks correspond to the 8 named groups in Data_Fixup.md:
  PERLAS, PERLAS2, SAN BLAS 1, TOBOBE, BOCAS1, SAN BLAS 3, BOCAS2, Track2

PERLAS, PERLAS2, SAN BLAS 1 are known to duplicate RhapsodyLogs tracks. Those
authoritative tracks exist in navMate without depth/temp -- they are prime
candidates for FSH depth/temp enrichment.

Enrichment approach: for each authoritative track_points row, find the nearest
FSH track point by lat/lon proximity and copy depth_cm/temp_k where the FSH
point has non-zero values. The segment-to-FSH-track mapping is implicit in the
oldE80 track name prefix (e.g. BOCAS1-005 -> BOCAS1 FSH track).

Missing pieces from Data_Fixup.md (to be sourced from FSH, not navMate oldE80):
  SAN BLAS 3-004 and SAN BLAS 3-005 -> Michelle-MichellToKuna
  BOCAS1-005 and BOCAS1-006 -> Michelle area
  BOCAS1-019 .. 021 -> MiscBocas
  Tracks2-*** -> new /Database/PuntaNisporo
  TOBOBE 014-017 -> Bastimentos area
  TOBOBE 004 -> Anchorage track

The navMate oldE80 segmented tracks serve as a *guide* for locating sub-sequences
within the FSH: match the oldE80 segment's points into the FSH point array by
lat/lon, identify start/end indices, extract as a new authoritative track with
depth/temp from the FSH. The oldE80 folder itself is not imported.


## Three-Phase Work Plan

### Phase 0 -- Inventory (before any writes)

Produce a navMate DB inventory: for each track, count track_points with ts=NULL,
depth_cm=0, temp_k=0. This establishes the full enrichment scope and targets.

Produce an FSH inventory: for each of the 8 FSH tracks, report name, UUID pair,
point count, depth/temp coverage percentage, bounding box, approximate time span
(inferred from surrounding Data_Fixup context, since FSH tracks have no timestamps).

### Phase 1 -- New Imports (no existing navMate counterpart)

- Before_Mandala collection: Cat32ToMissionBay + BoatToOceanside (IslasDeCoronado pending)
- CatalinaWithSteveRaw: pending overlap check against RhapsodyToCentralAmerica
- FSH missing pieces: segments from BOCAS1, SAN BLAS 3, TOBOBE, Tracks2 identified
  in Data_Fixup.md, extracted from FSH with depth/temp intact

### Phase 2 -- Enrichment of Existing Authoritative Tracks

- ts backfill: MandalaLogs from .gdb; RhapsodyToCentralAmerica against Rhapsody
  folder; Soundings; RhapsodyWithMichelle against Michelle folder
- depth_cm / temp_k backfill: FSH tracks against authoritative counterparts in
  RhapsodyLogs and other folders that share the same voyages


## Tooling Design

All tools are standalone Perl scripts opening navMate.db directly via DBI.
navOneTimeImport.pm is retired as a model -- it is all-or-nothing and not
suitable for surgical enrichment.

Tools to build:

1. FSH inventory script
   Read working_oldE80.fsh, report per-track: name, mta_uuid, trk_uuid,
   point count, depth coverage %, temp coverage %, lat/lon bounding box.

2. navMate DB inventory query
   Per-track report of NULL ts, zero depth_cm, zero temp_k in track_points.

3. GPS-to-navMate comparison script
   For a given .gdb file, list which tracks overlap existing navMate tracks
   by bounding box / point proximity, and which are entirely absent.

4. Timestamp backfill script (Stream B)
   GPSBabel converts .gdb to GPX in memory. For each GPX trackpoint, find
   nearest navMate track_point by lat/lon proximity (threshold: 0.0002 deg,
   ~20m). Write ts where matched; log unmatched points. No geometry changes.

5. FSH depth/temp backfill script (Stream A)
   For each authoritative track, identify the corresponding FSH track by
   name/bounding box. For each track_point, find nearest FSH point by lat/lon.
   Write depth_cm and temp_k where FSH has non-zero values. Log unmatched.

6. New track import script
   Insert collection (if new), track, and track_points rows. For FSH-sourced
   imports: carry depth_cm and temp_k from the start. For GPS-sourced imports:
   carry ts from the start.

7. FSH segment extract tool
   Given an FSH track and a start/end point index range (derived by matching
   an oldE80 segment's points into the FSH array), extract a sub-sequence and
   insert as a new authoritative track with depth/temp.


## Key Decisions

Proximity threshold: 0.0002 degrees (~20m) for all lat/lon matching.
  Points from different devices on the same vessel covering the same leg will
  be well within this. Flag zero-match points for manual review; do not fail.

Keep authoritative geometry: never replace lat/lon in existing track_points.
  Enrichment writes only to ts, depth_cm, temp_k.

Source priority (no conflict since different columns):
  Timestamps -> GPS archive (.gdb) always
  Depth/temp -> FSH always

Before_Mandala: new top-level branch collection in navMate hierarchy.

MandalaLogs vs CaliforniaCoastTracks: comparison pass required before any
  CaliforniaCoast import. MandalaLogs timestamp backfill is independent and
  can proceed without resolving the CaliforniaCoast overlap.


## Open Questions (need Patrick input)

- Mandala purchase date: needed to decide IslasDeCoronado collection placement
- CatalinaWithSteveRaw: does RhapsodyToCentralAmerica cover Sep 2007 Catalina?
  (check via gpsbabel + bounding box comparison)
- BoatToOceanside routes/waypoints: import them or tracks only?
- FSH waypoint timestamps: which authoritative waypoints correspond to FSH
  BLK_WPT records by lat/lon? (requires waypoint proximity matching pass)


## Schema Prerequisites

Schema 11.2 adds temp_k INTEGER DEFAULT NULL to the waypoints table.
This must be in place before any FSH waypoint enrichment can be written.
The schema change is being implemented as a separate step immediately preceding
this enrichment work.
