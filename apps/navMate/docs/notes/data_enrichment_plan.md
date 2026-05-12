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
  track_points:  depth_cm, temp_k (both present in BLK_TRK point records)
  waypoints:     created_ts (from BLK_WPT time+date fields)
                 depth_cm   (sounding waypoints)
                 temp_k

Track point timestamps are NOT present in FSH. BLK_TRK has no per-point ts.
BLK_MTA has no track-level timestamps either. The code comments confirm this:
"Odd that nothing on a track has a date-time".

FSH sentinel values (UNVERIFIED): depth=-1 (int32) and temp_k=65535 (uint16)
appear to mean "no reading" -- inferred from logical impossibility (negative
depth, 655K temperature) and 0xFFFF fill pattern. The zero lat/lon sentinel
for track points IS confirmed by code. The waypoint depth/temp sentinels have
not been cross-checked against known waypoints or source documentation. Treat
as suspected until verified.

### Stream B -- GPS Archive (.gdb files, C:/dat/Tracks)

Garmin GPS device files covering 2005-2011. Analyzed by a separate Claude session
using gpsbabel + C:\base_data\temp\raymarine\_scan_tracks.pl.

Columns GPS archive can populate:
  track_points:  ts
  tracks:        ts_start, ts_end
  waypoints:     created_ts (where a waypoint matches a track start/end point,
                 the GPS track's internal timestamp is the right source even if
                 no explicit .gdb waypoint record corresponds to it)

Waypoint timestamp quality note: many navMate waypoint created_ts values were
hand-derived from naming conventions rather than recorded by a device. A
00:00:00 time component is the clearest signal of a hand-made date. Device-
originated timestamps from FSH or .gdb are more accurate and should replace
hand-made ones wherever a proximity match exists. Name fields are not changed.

## Dual Path enrichment

Something inherent, but not explicitly noted previously is that these tracks
also drive many Mandala and Rhapsody Logs Waypoints that correspond to the
beginning and end of tracks in those respective sections, and which likely
do not carry detailed (to the second) date time stamps that might be in
either, or both enrichment strems.

When possible these should be de-conflicted and applied.


## phorton.com parallelism

Deferred but important is that the /var/www/phorton.com repo contains gpx and kml files,
as well as the structure of the Mandala and Rhapsody Logs, and Sailing experiences
before Mandala, and wants to grow to add potentially more pages regarding things that
happened on Rhapsody after arriving in Bocas, as well as being updated, eventually
to using the googleMaps (Google Cloud) API key used in /base/apps/raymarine/apps/navMate's
leaflet.


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

California/2010-07-27-MandalaLogs.gpx is byte-for-byte identical to California/2010-07-27-MandalaLogs.gdb -- use the .gdb.


## File-by-File Disposition

California/2005-10-08-Cat32ToMissionBay.gdb (2005-10-09, 4 tracks)
  Definitively pre-Mandala. Clean new import into a new top-level collection
  Before_Mandala. No existing navMate tracks to conflict with.

California/2005-11-28-BoatToOceanside.gdb (filename date = GPS download date 2005-11-28)
  Mandala-era (post-purchase). phorton.com records this as a single trip starting
  2005-11-24; navMate has it as two tracks dated 11-25 and 11-26 (outbound and
  return legs, San Diego to Oceanside). Routes and waypoints present in .gdb;
  already represented in navMate -- evaluate at comparison time whether they add
  anything not already captured.
  ACTION: timestamp backfill against existing navMate tracks.

California/2006-02-25-IslasDeCoronado.gdb (2006-02-25/26, 2 tracks)
  Mandala-era. Mandala was listed for sale 2006-10-17 and sold before Rhapsody was
  purchased, so this date (Feb 2006) is unambiguously within the Mandala period.
  Corresponds to navMate MandalaLogs 2006-02-25-SanDiego2CoronadaoIslands track.
  ACTION: timestamp backfill only.

California/2006-06-15-CaliforniaCoastTracks.gdb (2006-06-15 to 2006-08-11, 36 tracks, 34610 pts)
  Same date range as MandalaLogs but 2x the track points. Likely MandalaLogs is
  a proper subset (information was lost somewhere). Do NOT import blindly.
  ACTION: comparison pass first -- identify tracks absent from navMate entirely
  vs. denser versions of already-imported tracks.

California/2010-07-27-MandalaLogs.gdb (2006-06-15 to 2006-08-11, 49 tracks, 10533 timed pts)
  Already in navMate but arrived via GE->KML with timestamps stripped.
  ACTION: timestamp backfill only -- match GPX trackpoints to existing
  track_points rows by lat/lon proximity, write ts. No geometry changes.

California/2007-09-15-CatalinaWithSteveRaw.gdb (2007-09-17/19, 8 tracks)
  Already in navMate as the three tracks in Rhapsody Logs Part1 - Before Trip
  (that section contains exactly these three tracks and no others).
  ACTION: timestamp backfill only against those three navMate tracks.

2007-10-29-RhapsodyToCentralAmerica.gdb (2007-10-29 to 2009-01-17, 180 tracks, 113236 pts)
  Entire southbound voyage, fully timestamped. Highest priority file.
  ACTION: comparison pass against Rhapsody folder -- identify (a) tracks already
  present with/without timestamps, (b) tracks entirely absent.
  Outcome: mix of timestamp backfill and new imports.

2009-06-16-RhapsodyNextSteps.gdb (2009-09-26, 20 tracks, 1272 pts)
  Sparse. Overlap with navMate unknown. Lower priority; handle after main
  Rhapsody file is resolved.

2010-09-16-RhapsodyWithMichelle.gdb (2010-09-19 to 2011-11-28, 83 tracks, 10545 pts)
  Panama/Central America era. navMate has Michelle outer folder; overlap unknown.
  Same approach: comparison pass before writing.

Sounding/2011-10-26-RawSoundings.gdb (2011-10-26, 4 tracks, 76 waypoints)
  Represented in navMate Michelle folder but likely with NULL ts.
  ACTIONS: (a) backfill trackpoint ts; (b) check .gdb for waypoint timestamps
  and backfill those too.

Sounding/2011-11-05-BahiaEscondidoRaw.gdb (2011-11-05, 3 tracks, 63 waypoints)
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

The navMate oldE80 segmented tracks serve as a *guide* for locating sub-sequences
within the FSH: match the oldE80 segment's points into the FSH point array by
lat/lon, identify start/end indices, extract as a new authoritative track with
depth/temp from the FSH. The oldE80 folder itself is not imported.


## Four-Phase Work Plan

### Phase 0 -- Inventory (before any writes)

Produce a navMate DB inventory: for each track, count track_points with ts=NULL,
or timestamps and waypoints that do not carry to the second accuracy, as well as those with
depth_cm=0, temp_k=0. This establishes the full enrichment scope and targets.

Produce an FSH inventory: for each of the 8 FSH tracks, report name, UUID pair, point count,
depth/temp coverage percentage, bounding box, approximate time span (inferred from surrounding
Data_Fixup context, since FSH tracks have no timestamps). Also report total BLK_WPT count and
field coverage (created_ts, depth_cm, temp_k) across all waypoints in the file.

### Phase 1 -- New Imports (no existing navMate counterpart)

- California/2005-10-08-Cat32ToMissionBay.gdb
  - Definitively pre-Mandala; clean import into new Before_Mandala collection

### Phase 2 -- oldE80 Resolution (see docs/private/Data_Fixup.md)

This phase covers all new tracks and waypoints sourced from working_oldE80.fsh that have
no existing navMate counterpart and require manual curation before automated tooling can
be applied. The specific items -- track segments to extract, waypoints to import or
associate with routes, and destination collections -- are enumerated in
docs/private/Data_Fixup.md.

Two categories of work:
- Track segments: extract sub-sequences from FSH tracks into new authoritative navMate
  tracks, carrying depth_cm and temp_k from the source
- Waypoints: import or resolve FSH waypoints not yet in navMate, including those
  that imply new routes

### Phase 3 -- Enrichment of Existing Authoritative Tracks

Timestamp backfill (Stream B):
- California/2005-11-28-BoatToOceanside.gdb against MandalaLogs
- California/2006-02-25-IslasDeCoronado.gdb against MandalaLogs
- California/2010-07-27-MandalaLogs.gdb against MandalaLogs folder
- California/2007-09-15-CatalinaWithSteveRaw.gdb against Rhapsody Logs Part1 - Before Trip
- 2007-10-29-RhapsodyToCentralAmerica.gdb against Rhapsody folder
  - comparison pass first to distinguish backfill vs. new import
- 2009-06-16-RhapsodyNextSteps.gdb -- lower priority; handle after main Rhapsody file
- 2010-09-16-RhapsodyWithMichelle.gdb against Michelle folder
  - comparison pass first
- Sounding/2011-10-26-RawSoundings.gdb against Michelle/Soundings
- Sounding/2011-11-05-BahiaEscondidoRaw.gdb against Michelle/Soundings

Depth/temp backfill (Stream A):
- FSH tracks against authoritative counterparts in RhapsodyLogs and other folders
  that share the same voyages
- FSH waypoints: enrich existing navMate waypoints with created_ts, depth_cm, and
  temp_k from matching FSH BLK_WPT records (proximity match on lat/lon)


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
   For a given .gdb file, classify each GPS track relative to existing navMate
   tracks as: same-track, overlapping, intersecting, contained, or absent.
   Naive point-proximity is insufficient -- geographic overlap is necessary but
   not sufficient (e.g. outbound and inbound legs of the same trip share entry/exit
   channel points but are different tracks).
   Algorithm: exhaustive sliding-window comparison -- every window of N consecutive
   points in the candidate track is tested against the navMate track. The result is
   the best-scoring alignment of any sub-sequence of one track against any sub-sequence
   of the other, scored by match density and matched length. This correctly handles the
   common case of many tracks sharing a departure channel or anchorage approach but
   diverging to different destinations -- the shared segment is identified and
   characterized without penalizing the non-overlapping tails.
   Bounding box is a pre-filter only; the sliding window is the classification step.

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


## Key Decisions and Open Strategy Questions

Proximity matching -- two distinct tiers (confirmed against Cat32/ACTIVE LOG data 2026-05-12):
  Near proximity (0.0005 deg, ~55m): same general location; used for compressed/filtered
  track matching where the donor is a denser recording of the same trip. All 500 points
  of the Garmin-compressed 09-OCT-05 track matched within this threshold against the
  8513-point ACTIVE LOG from the same trip.
  Exact match (0.00005 deg, ~5.5m): same physical point; accounts for encoding and
  rounding differences between devices recording the same location.
  Enrichment passes that span different devices or different resolution recordings use
  the near proximity threshold. Passes that assert identity (e.g. waypoint enrichment)
  use the exact match threshold. Flag unmatched points for manual review; do not fail.

Geometry authority -- splits by object type:
  Waypoints: geometry is authoritative; enrich ts/depth/temp by exact match only.
  Tracks: geometry source is a deliberate per-track decision. We may find that one
  source (e.g. handheld GPS with denser sampling) produces better geometry than
  another (e.g. E80), and may wholesale replace a track's points or swap segments.
  This is resolved at inspection time, not decided in advance.

Source priority:
  Timestamps -> GPS archive (.gdb), for both track_points and waypoints.
  Depth/temp -> FSH, for both track_points and waypoints.
  Geometry -> deliberate per-track choice at execution time (see above).

Filename dates are not track dates: .gdb filenames often encode the GPS download
  date, not when the device was recording. Track dates embedded in navMate and
  phorton.com narrative are independent sources and may not agree with the filename.
  navMate track timestamps (once backfilled) are authoritative for actual recording
  dates; filename dates are treated as approximate provenance only.

Before_Mandala: new top-level branch collection in navMate hierarchy.

MandalaLogs vs CaliforniaCoastTracks: comparison pass required before any
  CaliforniaCoast import. MandalaLogs timestamp backfill is independent and
  can proceed without resolving the CaliforniaCoast overlap.




