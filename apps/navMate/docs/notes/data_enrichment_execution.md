# Data Enrichment Execution Log

Operational results from executing the strategy in data_enrichment_plan.md.
Each phase records what was run, what was found, and what decisions were made.


## Phase 0 -- Inventory (completed 2026-05-12)

Scripts:
  C:\base_data\temp\raymarine\_phase0_db_inventory.pl
  C:\base_data\temp\raymarine\_phase0_fsh_inventory.pl

Both run via Windows Perl (C:\Perl\bin\perl.exe). FSH script sets
$Pub::Utils::debug_level = -1 and redirects stderr to suppress Win32 console
color calls that corrupt the Claude Code TUI.


### navMate DB -- track_points (86,138 rows)

- ts:       100% NULL -- every track needs timestamp backfill from GPS archive
- depth_cm: 100% zero -- every track needs depth backfill from FSH
- temp_k:   100% zero -- every track needs temp backfill from FSH


### navMate DB -- waypoints (686 rows)

- created_ts: all present, none NULL; but many are hand-derived from naming
  conventions rather than device-recorded. 00:00:00 time = hand-made date.
  Device timestamps from FSH or .gdb should replace these where a match exists.
- depth_cm: 136 have values, 550 missing
- temp_k:   all 686 missing


### FSH working.fsh -- 8 tracks

- PERLAS    (999 pts)  mta=0306-0111-C1DA-D10F  trk=80B2-C48A-5A00-56DF  dep=0%   tmp=100%
  transducer not connected during Perlas leg
- PERLAS2   (641 pts)  mta=0306-0111-C1DA-D30F  trk=80B2-C48A-5A00-57DF  dep=0%   tmp=100%
  same -- transducer not connected
- SAN BLAS 1(617 pts)  mta=80B2-C48A-2900-3575  trk=80B2-C48A-5A00-58DF  dep=86%  tmp=100%
  partial depth; sentinel (0,0) points at segment boundaries
- TOBOBE   (1000 pts)  mta=80B2-C48A-3C00-81B6  trk=80B2-C48A-5A00-59DF  dep=100% tmp=100%
- BOCAS1   (1000 pts)  mta=80B2-C48A-3D00-79ED  trk=80B2-C48A-5A00-5ADF  dep=100% tmp=100%
- SAN BLAS 3(1000 pts) mta=80B2-C48A-4100-9463  trk=80B2-C48A-5A00-5BDF  dep=100% tmp=100%
- BOCAS2   (1000 pts)  mta=80B2-C48A-4400-194F  trk=80B2-C48A-5A00-5CDF  dep=100% tmp=100%
- Track 2  (1000 pts)  mta=80B2-C48A-4E00-85D9  trk=80B2-C48A-5A00-5DDF  dep=100% tmp=100%

TOBOBE through Track 2 all hit the 1000-point segment cap -- still recording
when truncated. trk_uuids are sequential (5A00-56DF .. 5A00-5DDF).
Bounding boxes omitted -- run the script for current values.


### FSH working.fsh -- 50 waypoints

- All 50 have full datetime (2012-2016, Bocas era)
- 24 have real depth readings; 26 show suspected sentinel value (-1)
- 24 have real temp_k readings; 26 show suspected sentinel value (65535)
- Sentinel values UNVERIFIED -- see strategy doc for caveat


## Phase 1 -- New Imports (completed 2026-05-12)

Script: apps/navMate/_import_cat32_before_mandala.pl

Created top-level collection "Before Mandala" (position 9.0, after MandalaLogs).

Imported 2 tracks from California/2005-10-08-Cat32ToMissionBay.gdb via
C:/base_data/temp/raymarine/_cat32.gpx (gpsbabel conversion):

- 2005-10-08-Cat32SanDiegoBayToMissionBay  493 pts  no timestamps (geometry only)
  Garmin named this track 08-OCT-05; outbound leg; no ACTIVE LOG counterpart.
- 2005-10-09-Cat32MissionBayToSanDiegoBay  500 pts  all timestamps proximity-matched
  Garmin named this track 09-OCT-05; inbound leg; timestamps matched from ACTIVE LOG
  (8513 pts, same trip) using 0.0005 deg threshold; all 500 points matched.
  ts_start=1128888553  ts_end=1128912810  (2005-10-09 UTC)

ACTIVE LOG and ACTIVE LOG 001 tracks not imported (used as timestamp donor only).
Tracks colored green and committed by Patrick.
