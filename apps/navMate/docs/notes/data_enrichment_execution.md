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


## Phase 2 -- oldE80 Resolution

### MichelleToKuna gap fill (completed 2026-05-12)

Imported one track from 2010-09-16-RhapsodyWithMichelle.gdb using the new
ImportGPS (gdb,gpx) context menu command in winDatabase.

Procedure:
- ImportGPS into a temporary top-level "test" collection
- Opened a second database window (new winDatabase multi-instance feature) and
  used copy + paste-new to place the track into Michelle/MichelleToKuna between
  2011-07-20-DinghyExploration and 2011-07-23-ToPorvenirAndChichime
- Deleted the temporary "test" collection

Source track name 2011-07-21-ToHollandaiseViaMiriadiadup carried through
unchanged -- no rename required.

Committed in c754060 along with the multi-instance database window feature and
the navOps paste-new-after self-anchor fix.


### RonAzul round-trip gap fill (completed 2026-05-13)

Imported two tracks from 2010-09-16-RhapsodyWithMichelle.gdb using the same
procedure as the MichelleToKuna gap fill:

- 2011-04-23-Michelles2KenVonnes
- 2011-04-24-KenVonnes2MichellesViaDolphinBay

ImportGPS into a temporary top-level "test" collection, then second-window
copy + paste-new into Michelle/RonAzul. Source track names carried through
unchanged. Temporary "test" collection deleted. DB committed by Patrick.


### BeforeKuna restructure and Andy's Island track (in progress 2026-05-13)

Follow-up to the RonAzul fix above: the BOCAS1-005/006 Data_Fixup line also
covered a Michelle/Andy's Island/Ken-and-Vaughn round trip. The Andy's Island
leg was missed in the previous pass.

Imported one track from 2010-09-16-RhapsodyWithMichelle.gdb:
- 2011-02-22-Michelles2DolphinBay2BocasAnchorage

Restructured Michelle to add a new "BeforeKuna" sub-collection, then moved the
existing RonAzul under it. Final layout: Michelle/BeforeKuna/RonAzul, with the
new track also under Michelle/BeforeKuna.

Procedure (records the navOps path actually taken, including workarounds):
- Created BeforeKuna via right-click new-branch on Michelle (lands at first
  child position)
- Repositioned it via cut + paste-after on Soundings (paste-before on RonAzul
  was attempted first but produced no visible change -- see bugs below)
- Cut RonAzul and paste (not paste-new) into the empty BeforeKuna -- succeeded
- ImportGPS the .gdb track into a temporary top-level "test" collection
- Copy + paste-new from test into BeforeKuna (which already contained
  RonAzul at this point) -- track landed at end of BeforeKuna rather than
  at the top as intended (see bugs below)
- Attempt to reposition via cut + paste-before on RonAzul (same parent) --
  no visible change (see bugs below)

Current state is "relatively happy but not ideal": the track is in BeforeKuna
but ordered after RonAzul rather than before it. Not yet committed.

Observed navOps bugs during this session (not analyzed; logged for separate
triage):
- paste-before on a sibling appears to do nothing in at least two cases:
  newly-created branch -> paste-before sibling, and intra-parent track
  reposition via cut + paste-before
- paste-new into a non-empty collection places the new item at the end
  rather than at the top (first child position) as the design specifies
