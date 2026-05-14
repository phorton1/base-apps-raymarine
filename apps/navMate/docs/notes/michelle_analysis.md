# Michelle Analysis -- Per-Track Inventory

**Status 2026-05-14: paused** mid-iteration.  See
`michelle_fixups.md` "Status / Resume Point" for the resume context.
The `action` column is populated; the `comment` column on the
existing-side tables is awaiting human authoring for the
`**rename** to test name; comment = old name` rows.

Three tables, one per branch.  Companion to `michelle_fixups.md`.
What's currently known about every track, with relation labels derived
from exact-npts pairing plus the lat/lon match filter.

Relation labels used in the tables:

- **match** -- clean lat/lon agreement (Population A, ~0 offset, 2010 era)
- **match+lat_shift** -- clean agreement with the +3.30e-05 deg lat offset (Population B, 2011 era)
- **exact** -- byte-identical pair (manual copies)
- **npts_but_miss** -- same name and same npts but lat/lon-filter disagrees
- **exact_name_match** -- same name across branches but npts differs; flagged because the lat/lon filter cannot pair them pointwise. Carries a device qualifier: "(likely hh, no useful info)" on the test side -- handheld-GPS recording from the source .gdb with no per-point ts or other transferable data; "(likely E80)" on the existing side -- boat plotter recording.
- **new** -- test track with no pair-label in any existing branch
- **missing** -- existing track with no pair-label in test
- **duplicate** -- confirmed duplicate of another existing track in the same sub-branch

A track may carry more than one relation via different pairings; the
relations column lists each.  `uuid8` is the first 8 hex chars of the
track uuid, sufficient for unambiguous reference within this scope.

The **action** column records the per-track decision derived from the
relations.  The actionable verb is **bolded**; non-actionable `none`
entries are unbolded with a parenthetical reason.  Direction is strictly
**test -> existing**: the test branch is discarded after this iteration,
so actions on the test side are mostly `none` (the work happens on the
existing side); the test-side bolded actions are limited to:

- **add as new** -- test-side orphan; promote into the appropriate
  existing branch under the planned temporal reorganization.
- **rename existing** -- this test track's dt-formatted name is used
  to rename its matched existing-side counterpart (see the relations
  column for the target).

Existing-side bolded actions:

- **rename** to test name; comment = old name -- Population-B match
  with an info-bearing old name; set `tracks.name` to the test track's
  dt-formatted name (in the relations column) and set `tracks.comment`
  to text that captures the old name's information.  Each comment is
  authored manually -- see the `comment` column.
- **rename** to test name; drop generic old name -- Population-B match
  where the old name is generic (literally "michelles" in
  `many_trips_to_michelles`); rename and discard.  No comment.
- **dedupe** within sub-branch -- existing-side duplicate; the cluster
  partners are listed in the relations column.

The **comment** column on the MiscBocas and Michelle tables is left
blank by the script.  For rows whose action calls for a comment, fill
this column manually with the desired `tracks.comment` text (typically
based on or derived from the existing track's current name).  For all
other rows, leave blank.

## test branch (83 tracks; flat)

| # | name | uuid8 | npts | ts_class | relations | action |
|---|---|---|---|---|---|---|
| 1 | 2010-09-16-BocasMarina2Michelles | 874eb634 | 500 | no_ts | **match** <-> Michelle/Before Sumwood Channel/Tracks/2010-09-16-BocasMarina2Michelles [414e758c] | none (existing has matching record) |
| 2 | 2010-09-18-Michelles2CayaAgua | c94e6828 | 289 | no_ts | **match** <-> Michelle/Before Sumwood Channel/Tracks/2010-09-18-Michelles2CayaAgua [1b4ede58] | none (existing has matching record) |
| 3 | 2010-09-20-CayaAgua2BocasAnchorage | 364e39d4 | 3635 | valid(span=108994s) | **match** <-> Michelle/Before Sumwood Channel/Tracks/2010-09-20-CayaAgua2BocasAnchorage [524e935e] | none (existing has matching record) |
| 4 | 2010-09-20-CayaAgua2BocasAnchorageRaw | 704ec2b8 | 416 | valid(span=12450s) | **new** | **add as new** (preserves Raw + valid ts) |
| 5 | 2010-10-03-BocasMarina2Michelles | aa4eb06a | 94 | no_ts | **match** <-> Michelle/Before Sumwood Channel/Tracks/2010-10-03-BocasMarina2Michelles [394ec994] | none (existing has matching record) |
| 6 | 2010-10-12-Michelles2BocasAnchorage | a04e70c2 | 99 | no_ts | **match** <-> Michelle/Before Sumwood Channel/Tracks/2010-10-12-Michelles2BocasAnchorage [204ed616] | none (existing has matching record) |
| 7 | 2010-10-16-BocasMarina2StarfishBeach | d54e7e96 | 329 | no_ts | **match** <-> Michelle/Before Sumwood Channel/Tracks/2010-10-16-BocasMarina2StarfishBeach [024e296e] | none (existing has matching record) |
| 8 | 2010-10-17-StarfishBeach2Michelles | df4ec8e0 | 573 | no_ts | **match** <-> Michelle/Before Sumwood Channel/Tracks/2010-10-17-StarfishBeach2Michelles [764e860a] | none (existing has matching record) |
| 9 | 2010-10-23-Michelles2RedFrog | a44e067e | 246 | no_ts | **match** <-> Michelle/Before Sumwood Channel/Tracks/2010-10-23-Michelles2RedFrog [7f4ea810] | none (existing has matching record) |
| 10 | 2010-10-24-RedFrog2BocasAnchorage | aa4e6878 | 69 | no_ts | **match** <-> Michelle/Before Sumwood Channel/Tracks/2010-10-24-RedFrog2BocasAnchorage [024eb910] | none (existing has matching record) |
| 11 | 2010-10-25-BocasAnchorage2Zapatillas | 214e3cd8 | 285 | no_ts | **match** <-> Michelle/Before Sumwood Channel/Tracks/2010-10-25-BocasAnchorage2Zapatillas [584ec83e] | none (existing has matching record) |
| 12 | 2010-10-27-Zapatillas2BahiaAzul | 634eee10 | 86 | no_ts | **match** <-> Michelle/Before Sumwood Channel/Tracks/2010-10-27-Zapatillas2BahiaAzul [b34e0e5c] | none (existing has matching record) |
| 13 | 2010-10-28-BahiaAzul2BahiaAzulEnsenada | 9c4e1696 | 22 | no_ts | **match** <-> Michelle/Before Sumwood Channel/Tracks/2010-10-28-BahiaAzul2BahiaAzulEnsenada [cf4ecb66] | none (existing has matching record) |
| 14 | 2010-10-29-BahiaAzul2BocasMarina | a64e2f34 | 500 | no_ts | **match** <-> Michelle/Before Sumwood Channel/Tracks/2010-10-29-BahiaAzul2BocasMarina [0a4e5310] | none (existing has matching record) |
| 15 | 2010-10-29-BahiaAzul2BocasMarinaRaw | 4c4ea726 | 3160 | valid(span=94773s) | **match** <-> Michelle/Before Sumwood Channel/Tracks/2010-10-29-BahiaAzul2BocasMarinaRaw [034ec272] | none (existing has matching record) |
| 16 | 2011-02-02-SumwoodChannel2Michelles | 264e6a4e | 157 | no_ts | **match** <-> Michelle/First Summwood Channel/2011-02-02-SumwoodChannel2Michelles [8d4e236e] | none (existing has matching record) |
| 17 | 2011-02-08-Michelles2Bocas | 554ea340 | 433 | no_ts | **match** <-> Michelle/First Summwood Channel/2011-02-08-Michelles2Bocas [004e0016] | none (existing has matching record) |
| 18 | 2011-02-08-Michelles2BocasRaw | ec4eb36e | 587 | valid(span=17580s) | **new** | **add as new** (preserves Raw + valid ts) |
| 19 | 2011-02-08-Michelles2Marina | ee4ee504 | 59 | artifact(1322460452) | **new** | **add as new** |
| 20 | 2011-02-18-Marina2StoneSoupParty | e04e5568 | 69 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [0f4e667c] | **rename existing** |
| 21 | 2011-02-22-Michelles2DolphinBay2BocasAnchorage | b54ea2ae | 123 | artifact(1322460452) | **match+lat_shift** <-> Michelle/Misc/michelles_to_andys_island [7c4eb754] | **rename existing** |
| 22 | 2011-02-24-BocasAnchorageToBocasMarina | 7b4eb740 | 14 | artifact(1322460452) | **match+lat_shift** <-> MiscBocas/to_south_anchorage [1a4e070c] | **rename existing** |
| 23 | 2011-03-01-BocasMarinaToMichelles(dinghy flipped) | b34e6964 | 75 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [334e58ca] | **rename existing** |
| 24 | 2011-03-05-DaysailWithBob1 | a34e2850 | 55 | artifact(1322460452) | **new** | **add as new** |
| 25 | 2011-03-05-DaysailWithBob2 | 114eba76 | 19 | artifact(1322460452) | **new** | **add as new** |
| 26 | 2011-03-06-MichellesToZapatillas | 104e640c | 46 | artifact(1322460452) | **match+lat_shift** <-> Michelle/AguaAndTobobe c 2011-03-06/michelle_agua_to_zap [dc4e4bd6] | **rename existing** |
| 27 | 2011-03-07-ZapatillasToIslaBoa | 4e4e81a4 | 86 | artifact(1322460452) | **match+lat_shift** <-> Michelle/AguaAndTobobe c 2011-03-06/zap_to_little_island_tobobe [014eab34] | **rename existing** |
| 28 | 2011-03-08-IslaBoaTobobe | a54e48f4 | 20 | artifact(1322460452) | **match+lat_shift** <-> Michelle/AguaAndTobobe c 2011-03-06/little_island_to_tobobe [cd4ebc1e] | **rename existing** |
| 29 | 2011-03-09-TobobeToMichelles | d64e9fb8 | 90 | artifact(1322460452) | **match+lat_shift** <-> Michelle/AguaAndTobobe c 2011-03-06/tobobe_to_michelles [444e069a] | **rename existing** |
| 30 | 2011-03-17-MichellesToMarina | 494ec482 | 60 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [034efe6e] | **rename existing** |
| 31 | 2011-03-26-Marina2BastiamentosBoatRaces | 814e94fe | 23 | artifact(1322460452) | **match+lat_shift** <-> MiscBocas/to basti [c54efe82] | **rename existing** |
| 32 | 2011-03-27-BastiamentosRaces2Michelles | 384ef894 | 63 | artifact(1322460452) | **new** | **add as new** |
| 33 | 2011-03-29-Michelles2BocasAnchorage | ab4e13e8 | 57 | artifact(1322460452) | **new** | **add as new** |
| 34 | 2011-03-30-BocasAnchorage2BocasMarina | 454ebd46 | 49 | artifact(1322460452) | **match+lat_shift** <-> MiscBocas/to south anchorage [5a4e42e8] | **rename existing** |
| 35 | 2011-04-14-BocasMarina2Michelles | 9b4e0c88 | 35 | artifact(1322460452) | **new** | **add as new** |
| 36 | 2011-04-15-Michelles2BocasMarina | b14e7c9a | 77 | artifact(1322460452) | **new** | **add as new** |
| 37 | 2011-04-17-BocasMarina2Michelles | a04eb5fe | 74 | artifact(1322460452) | **new** | **add as new** |
| 38 | 2011-04-18-Michelles2BocasMarina | c14e9bfc | 55 | artifact(1322460452) | **new** | **add as new** |
| 39 | 2011-04-21-BocasMarina2Michelles (brother emergenc | 404e5ba8 | 52 | artifact(1322460452) | **new** | **add as new** |
| 40 | 2011-04-23-Michelles2KenVonnes | 7a4ed9f0 | 51 | artifact(1322460452) | **exact** <-> Michelle/RonAzul/2011-04-23-Michelles2KenVonnes [d94e9fc6] | none (manual copy done 2026-05-13) |
| 41 | 2011-04-24-KenVonnes2MichellesViaDolphinBay | 864e602a | 75 | artifact(1322460452) | **exact** <-> Michelle/RonAzul/2011-04-24-KenVonnes2MichellesViaDolphinBay [864e259c] | none (manual copy done 2026-05-13) |
| 42 | 2011-04-26-BocasAnchorage2BocasMarina | 234ed4ee | 17 | artifact(1322460452) | **match+lat_shift** <-> MiscBocas/to south anchorage [3f4eba5a] | **rename existing** |
| 43 | 2011-04-26-Michelles2BocasAnchorage (w/Blayne) | d64e210a | 53 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [584ee2ce] | **rename existing** |
| 44 | 2011-05-01-BocasMarina2Michelles | f14efae0 | 66 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [904e5dc0] | **rename existing** |
| 45 | 2011-05-02-Michelles2BocasMarina | 004e4a14 | 64 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [c04e4ca8] | **rename existing** |
| 46 | 2011-05-05-BocasMarina2Michelles | 714e071a | 47 | artifact(1322460452) | **new** | **add as new** |
| 47 | 2011-05-06-Michelles2BocasMarina (with Isreal) | 644ed820 | 48 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [814e7fb8] | **rename existing** |
| 48 | 2011-06-11-BocasMarina2Michelles | 704e9760 | 51 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [734e3648] | **rename existing** |
| 49 | 2011-06-17-Michelles2BocasMarina | 724ea790 | 64 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [804ecdac] | **rename existing** |
| 50 | 2011-06-18-BocasMarina2Zapatillas | 9e4edec8 | 56 | artifact(1322460452) | **new** | **add as new** |
| 51 | 2011-06-19-Zapatillas2Michelles | 4f4e130e | 53 | artifact(1322460452) | **new** | **add as new** |
| 52 | 2011-07-04-TripBegins-IslaBoa4thOfJuly | 0d4eb7f6 | 441 | no_ts | **exact_name_match** (likely hh, no useful info) <-> Michelle/MichellToKuna 2011-07/Tracks/2011-07-04-TripBegins-IslaBoa4thOfJuly [6d4e09bc] | none (existing has E80 recording) |
| 53 | 2011-07-06-ToPortobello | 594efbd6 | 500 | no_ts | **exact_name_match** (likely hh, no useful info) <-> Michelle/MichellToKuna 2011-07/Tracks/2011-07-06-ToPortobello [c14e1760] | none (existing has E80 recording) |
| 54 | 2011-07-08-ToPorvenir | 3e4eeeac | 369 | no_ts | **exact_name_match** (likely hh, no useful info) <-> Michelle/MichellToKuna 2011-07/Tracks/2011-07-08-ToPorvenir [734e2f86] | none (existing has E80 recording) |
| 55 | 2011-07-09-ToEastLemonAnchorage | b94eb52c | 350 | no_ts | **exact_name_match** (likely hh, no useful info) <-> Michelle/MichellToKuna 2011-07/Tracks/2011-07-09-ToEastLemonAnchorage [944e1f40] | none (existing has E80 recording) |
| 56 | 2011-07-10-ToCocoBanderas | 714e2b08 | 439 | no_ts | **exact_name_match** (likely hh, no useful info) <-> Michelle/MichellToKuna 2011-07/Tracks/2011-07-10-ToCocoBanderas [484ea55a] | none (existing has E80 recording) |
| 57 | 2011-07-11-ToAriadupRatones | 2a4ed93a | 500 | no_ts | **exact_name_match** (likely hh, no useful info) <-> Michelle/MichellToKuna 2011-07/Tracks/2011-07-11-ToAriadupRatones [274eef08] | none (existing has E80 recording) |
| 58 | 2011-07-13-ToSnugHarbor | 024e1776 | 258 | no_ts | **exact_name_match** (likely hh, no useful info) <-> Michelle/MichellToKuna 2011-07/Tracks/2011-07-13-ToSnugHarbor [7c4ec802] | none (existing has E80 recording) |
| 59 | 2011-07-16a-ToRioPlayonChico | e64e25fa | 333 | no_ts | **exact_name_match** (likely hh, no useful info) <-> Michelle/MichellToKuna 2011-07/Tracks/2011-07-16a-ToRioPlayonChico [244e9282] | none (existing has E80 recording) |
| 60 | 2011-07-16b-DinghyExploration | 5b4ec4b6 | 441 | no_ts | **exact_name_match** (likely hh, no useful info) <-> Michelle/MichellToKuna 2011-07/Tracks/2011-07-16b-DinghyExploration [274e8ade] | none (existing has E80 recording) |
| 61 | 2011-07-16c-ToIgnatioTupile | 514e4568 | 113 | no_ts | **exact_name_match** (likely hh, no useful info) <-> Michelle/MichellToKuna 2011-07/Tracks/2011-07-16c-ToIgnatioTupile [b64e8d72] | none (existing has E80 recording) |
| 62 | 2011-07-20-DinghyExploration | fa4e95ee | 360 | no_ts | **exact_name_match** (likely hh, no useful info) <-> Michelle/MichellToKuna 2011-07/Tracks/2011-07-20-DinghyExploration [354e4ce2] | none (existing has E80 recording) |
| 63 | 2011-07-21-ToHollandaiseViaMiriadiadup | 7b4ef49a | 481 | no_ts | **exact** <-> Michelle/MichellToKuna 2011-07/Tracks/2011-07-21-ToHollandaiseViaMiriadiadup [de4e4e16] | none (manual copy done 2026-05-13) |
| 64 | 2011-07-23-ToPorvenirAndChichime | 234ec134 | 459 | no_ts | **exact_name_match** (likely hh, no useful info) <-> Michelle/MichellToKuna 2011-07/Tracks/2011-07-23-ToPorvenirAndChichime [bf4e8ce2] | none (existing has E80 recording) |
| 65 | 2011-07-24-ToPortobello | 694e7a12 | 388 | no_ts | **exact_name_match** (likely hh, no useful info) <-> Michelle/MichellToKuna 2011-07/Tracks/2011-07-24-ToPortobello [904ed2d6] | none (existing has E80 recording) |
| 66 | 2011-07-26-ToLomaPartida | 224e4f88 | 500 | no_ts | **exact_name_match** (likely hh, no useful info) <-> Michelle/MichellToKuna 2011-07/Tracks/2011-07-26-ToLomaPartida [b54ec420] | none (existing has E80 recording) |
| 67 | 2011-07-30-Michelles2BocasMarina | ef4ee3c4 | 52 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [234e133a] | **rename existing** |
| 68 | 2011-07-31-BocasMarina2Michelles | e84e21a0 | 71 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [7f4e11e0] | **rename existing** |
| 69 | 2011-08-05-Michelles2BocasMarina | 3b4e3a34 | 53 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [504e0e06] | **rename existing** |
| 70 | 2011-08-07-BocasMarina2Michelles | 1a4e7582 | 52 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [e74e01a6] | **rename existing** |
| 71 | 2011-08-12-Michelles2BocasMarina | 064ed640 | 60 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [234e896a] | **rename existing** |
| 72 | 2011-08-14-BocasMarina2Michelles | 9b4e5b5a | 56 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [fd4e197a] | **rename existing** |
| 73 | 2011-08-27-BocasMarina2Michelles | ab4e73c6 | 53 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [1f4e2d54] | **rename existing** |
| 74 | 2011-08-27-Michelles2BocasMarina | 9b4e1676 | 78 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [294e96ee] | **rename existing** |
| 75 | 2011-09-13-Michelles2BocasMarina | b14e93e2 | 57 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [d74e57a0] | **rename existing** |
| 76 | 2011-09-14-BocasMarina2Michelles | b04e31de | 1 | artifact(1322460452) | **new** | none (bad data: 1-point track) |
| 77 | 2011-09-19-Michelles2BocasMarina | 214e65f0 | 53 | artifact(1322460452) | **new** | **add as new** |
| 78 | 2011-10-16-BocasMarina2Michelles | 8c4eb676 | 58 | artifact(1322460452) | **new** | **add as new** |
| 79 | 2011-10-17-Michelles2BocasMarina | 284edefc | 80 | artifact(1322460452) | **match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [1f4edb62]<br>**match+lat_shift** <-> Michelle/many_trips_to_michelles/michelles [d64e871c] | **rename existing** |
| 80 | 2011-10-21-BocasMarina2Michelles | 9b4e1318 | 62 | artifact(1322460452) | **new** | **add as new** |
| 81 | 2011-10-22-BahiaEscondido2Michelles | 854e03ce | 30 | artifact(1322460452) | **match+lat_shift** <-> MiscBocas/bahia_escondido [344e189a] | **rename existing** |
| 82 | 2011-10-22-Michelles2BahiaEscondido1 | 3c4e859e | 74 | artifact(1322460452) | **match+lat_shift** <-> Michelle/Misc/michelles-bahia_escondido [ec4e6afc] | **rename existing** |
| 83 | 2011-10-22-Michelles2BahiaEscondido2 | 904ed258 | 11 | artifact(1322460452) | **match+lat_shift** <-> MiscBocas/bahia_escondido [224edc0a] | **rename existing** |

## MiscBocas branch (9 tracks; flat)

| # | name | uuid8 | npts | ts_class | relations | action | comment |
|---|---|---|---|---|---|---|---|
| 1 | bahia_escondido | 224edc0a | 11 | no_ts | **match+lat_shift** <-> test/2011-10-22-Michelles2BahiaEscondido2 [904ed258] | **rename** to test name; comment = old name | |
| 2 | bahia_escondido | 344e189a | 30 | no_ts | **match+lat_shift** <-> test/2011-10-22-BahiaEscondido2Michelles [854e03ce] | **rename** to test name; comment = old name | |
| 3 | to basti | c54efe82 | 23 | no_ts | **match+lat_shift** <-> test/2011-03-26-Marina2BastiamentosBoatRaces [814e94fe] | **rename** to test name; comment = old name | |
| 4 | to crawl_key | 304e4e1c | 16 | no_ts | **missing** | none (no test counterpart; out of scope for this pass) | |
| 5 | to south anchorage | 3f4eba5a | 17 | no_ts | **match+lat_shift** <-> test/2011-04-26-BocasAnchorage2BocasMarina [234ed4ee] | **rename** to test name; comment = old name | |
| 6 | to south anchorage | 5a4e42e8 | 49 | no_ts | **match+lat_shift** <-> test/2011-03-30-BocasAnchorage2BocasMarina [454ebd46] | **rename** to test name; comment = old name | |
| 7 | to_south_anchorage | 1a4e070c | 14 | no_ts | **match+lat_shift** <-> test/2011-02-24-BocasAnchorageToBocasMarina [7b4eb740] | **rename** to test name; comment = old name | |
| 8 | zap_thru_agua_cut | 334ea54c | 36 | no_ts | **missing** | none (no test counterpart; out of scope for this pass) | |
| 9 | zap_thru_crawl_key | 394ebef2 | 25 | no_ts | **missing** | none (no test counterpart; out of scope for this pass) | |

## Michelle branch (66 tracks; flattened from tree)

| # | sub-collection / name | uuid8 | npts | ts_class | relations | action | comment |
|---|---|---|---|---|---|---|---|
| 1 | [AguaAndTobobe c 2011-03-06] little_island_to_tobobe | cd4ebc1e | 20 | no_ts | **match+lat_shift** <-> test/2011-03-08-IslaBoaTobobe [a54e48f4] | **rename** to test name; comment = old name | |
| 2 | [AguaAndTobobe c 2011-03-06] michelle_agua_to_zap | dc4e4bd6 | 46 | no_ts | **match+lat_shift** <-> test/2011-03-06-MichellesToZapatillas [104e640c] | **rename** to test name; comment = old name | |
| 3 | [AguaAndTobobe c 2011-03-06] tobobe_to_michelles | 444e069a | 90 | no_ts | **match+lat_shift** <-> test/2011-03-09-TobobeToMichelles [d64e9fb8] | **rename** to test name; comment = old name | |
| 4 | [AguaAndTobobe c 2011-03-06] zap_to_little_island_tobobe | 014eab34 | 86 | no_ts | **match+lat_shift** <-> test/2011-03-07-ZapatillasToIslaBoa [4e4e81a4] | **rename** to test name; comment = old name | |
| 5 | [Before Sumwood Channel/Tracks] 2010-09-16-BocasMarina2Michelles | 414e758c | 500 | no_ts | **match** <-> test/2010-09-16-BocasMarina2Michelles [874eb634] | none (names already match, position canonical) | |
| 6 | [Before Sumwood Channel/Tracks] 2010-09-18-Michelles2CayaAgua | 1b4ede58 | 289 | no_ts | **match** <-> test/2010-09-18-Michelles2CayaAgua [c94e6828] | none (names already match, position canonical) | |
| 7 | [Before Sumwood Channel/Tracks] 2010-09-20-CayaAgua2BocasAnchorage | 524e935e | 3635 | no_ts | **match** <-> test/2010-09-20-CayaAgua2BocasAnchorage [364e39d4] | none (names already match, position canonical) | |
| 8 | [Before Sumwood Channel/Tracks] 2010-10-03-BocasMarina2Michelles | 394ec994 | 94 | no_ts | **match** <-> test/2010-10-03-BocasMarina2Michelles [aa4eb06a] | none (names already match, position canonical) | |
| 9 | [Before Sumwood Channel/Tracks] 2010-10-12-Michelles2BocasAnchorage | 204ed616 | 99 | no_ts | **match** <-> test/2010-10-12-Michelles2BocasAnchorage [a04e70c2] | none (names already match, position canonical) | |
| 10 | [Before Sumwood Channel/Tracks] 2010-10-16-BocasMarina2StarfishBeach | 024e296e | 329 | no_ts | **match** <-> test/2010-10-16-BocasMarina2StarfishBeach [d54e7e96] | none (names already match, position canonical) | |
| 11 | [Before Sumwood Channel/Tracks] 2010-10-17-StarfishBeach2Michelles | 764e860a | 573 | no_ts | **match** <-> test/2010-10-17-StarfishBeach2Michelles [df4ec8e0] | none (names already match, position canonical) | |
| 12 | [Before Sumwood Channel/Tracks] 2010-10-23-Michelles2RedFrog | 7f4ea810 | 246 | no_ts | **match** <-> test/2010-10-23-Michelles2RedFrog [a44e067e] | none (names already match, position canonical) | |
| 13 | [Before Sumwood Channel/Tracks] 2010-10-24-RedFrog2BocasAnchorage | 024eb910 | 69 | no_ts | **match** <-> test/2010-10-24-RedFrog2BocasAnchorage [aa4e6878] | none (names already match, position canonical) | |
| 14 | [Before Sumwood Channel/Tracks] 2010-10-25-BocasAnchorage2Zapatillas | 584ec83e | 285 | no_ts | **match** <-> test/2010-10-25-BocasAnchorage2Zapatillas [214e3cd8] | none (names already match, position canonical) | |
| 15 | [Before Sumwood Channel/Tracks] 2010-10-27-Zapatillas2BahiaAzul | b34e0e5c | 86 | no_ts | **match** <-> test/2010-10-27-Zapatillas2BahiaAzul [634eee10] | none (names already match, position canonical) | |
| 16 | [Before Sumwood Channel/Tracks] 2010-10-28-BahiaAzul2BahiaAzulEnsenada | cf4ecb66 | 22 | no_ts | **match** <-> test/2010-10-28-BahiaAzul2BahiaAzulEnsenada [9c4e1696] | none (names already match, position canonical) | |
| 17 | [Before Sumwood Channel/Tracks] 2010-10-29-BahiaAzul2BocasMarina | 0a4e5310 | 500 | no_ts | **match** <-> test/2010-10-29-BahiaAzul2BocasMarina [a64e2f34] | none (names already match, position canonical) | |
| 18 | [Before Sumwood Channel/Tracks] 2010-10-29-BahiaAzul2BocasMarinaRaw | 034ec272 | 3160 | no_ts | **match** <-> test/2010-10-29-BahiaAzul2BocasMarinaRaw [4c4ea726] | none (names already match, position canonical) | |
| 19 | [First Summwood Channel] 2011-02-02-SumwoodChannel2Michelles | 8d4e236e | 157 | no_ts | **match** <-> test/2011-02-02-SumwoodChannel2Michelles [264e6a4e] | none (names already match, position canonical) | |
| 20 | [First Summwood Channel] 2011-02-08-Michelles2Bocas | 004e0016 | 433 | no_ts | **match** <-> test/2011-02-08-Michelles2Bocas [554ea340] | none (names already match, position canonical) | |
| 21 | [MichellToKuna 2011-07/Tracks] 2011-07-04-TripBegins-IslaBoa4thOfJuly | 6d4e09bc | 422 | no_ts | **exact_name_match** (likely E80) <-> test/2011-07-04-TripBegins-IslaBoa4thOfJuly [0d4eb7f6] | none (existing is canonical E80 recording) | |
| 22 | [MichellToKuna 2011-07/Tracks] 2011-07-06-ToPortobello | c14e1760 | 471 | no_ts | **exact_name_match** (likely E80) <-> test/2011-07-06-ToPortobello [594efbd6] | none (existing is canonical E80 recording) | |
| 23 | [MichellToKuna 2011-07/Tracks] 2011-07-08-ToPorvenir | 734e2f86 | 345 | no_ts | **exact_name_match** (likely E80) <-> test/2011-07-08-ToPorvenir [3e4eeeac] | none (existing is canonical E80 recording) | |
| 24 | [MichellToKuna 2011-07/Tracks] 2011-07-09-ToEastLemonAnchorage | 944e1f40 | 174 | no_ts | **exact_name_match** (likely E80) <-> test/2011-07-09-ToEastLemonAnchorage [b94eb52c] | none (existing is canonical E80 recording) | |
| 25 | [MichellToKuna 2011-07/Tracks] 2011-07-10-ToCocoBanderas | 484ea55a | 366 | no_ts | **exact_name_match** (likely E80) <-> test/2011-07-10-ToCocoBanderas [714e2b08] | none (existing is canonical E80 recording) | |
| 26 | [MichellToKuna 2011-07/Tracks] 2011-07-11-ToAriadupRatones | 274eef08 | 168 | no_ts | **exact_name_match** (likely E80) <-> test/2011-07-11-ToAriadupRatones [2a4ed93a] | none (existing is canonical E80 recording) | |
| 27 | [MichellToKuna 2011-07/Tracks] 2011-07-13-ToSnugHarbor | 7c4ec802 | 161 | no_ts | **exact_name_match** (likely E80) <-> test/2011-07-13-ToSnugHarbor [024e1776] | none (existing is canonical E80 recording) | |
| 28 | [MichellToKuna 2011-07/Tracks] 2011-07-16a-ToRioPlayonChico | 244e9282 | 134 | no_ts | **exact_name_match** (likely E80) <-> test/2011-07-16a-ToRioPlayonChico [e64e25fa] | none (existing is canonical E80 recording) | |
| 29 | [MichellToKuna 2011-07/Tracks] 2011-07-16b-DinghyExploration | 274e8ade | 121 | no_ts | **exact_name_match** (likely E80) <-> test/2011-07-16b-DinghyExploration [5b4ec4b6] | none (existing is canonical E80 recording) | |
| 30 | [MichellToKuna 2011-07/Tracks] 2011-07-16c-ToIgnatioTupile | b64e8d72 | 92 | no_ts | **exact_name_match** (likely E80) <-> test/2011-07-16c-ToIgnatioTupile [514e4568] | none (existing is canonical E80 recording) | |
| 31 | [MichellToKuna 2011-07/Tracks] 2011-07-20-DinghyExploration | 354e4ce2 | 237 | no_ts | **exact_name_match** (likely E80) <-> test/2011-07-20-DinghyExploration [fa4e95ee] | none (existing is canonical E80 recording) | |
| 32 | [MichellToKuna 2011-07/Tracks] 2011-07-21-ToHollandaiseViaMiriadiadup | de4e4e16 | 481 | no_ts | **exact** <-> test/2011-07-21-ToHollandaiseViaMiriadiadup [7b4ef49a] | none (manual copy 2026-05-13) | |
| 33 | [MichellToKuna 2011-07/Tracks] 2011-07-23-ToPorvenirAndChichime | bf4e8ce2 | 381 | no_ts | **exact_name_match** (likely E80) <-> test/2011-07-23-ToPorvenirAndChichime [234ec134] | none (existing is canonical E80 recording) | |
| 34 | [MichellToKuna 2011-07/Tracks] 2011-07-24-ToPortobello | 904ed2d6 | 359 | no_ts | **exact_name_match** (likely E80) <-> test/2011-07-24-ToPortobello [694e7a12] | none (existing is canonical E80 recording) | |
| 35 | [MichellToKuna 2011-07/Tracks] 2011-07-26-ToLomaPartida | b54ec420 | 481 | no_ts | **exact_name_match** (likely E80) <-> test/2011-07-26-ToLomaPartida [224e4f88] | none (existing is canonical E80 recording) | |
| 36 | [Misc] michelles-bahia_escondido | ec4e6afc | 74 | no_ts | **match+lat_shift** <-> test/2011-10-22-Michelles2BahiaEscondido1 [3c4e859e] | **rename** to test name; comment = old name | |
| 37 | [Misc] michelles_to_andys_island | 7c4eb754 | 123 | no_ts | **match+lat_shift** <-> test/2011-02-22-Michelles2DolphinBay2BocasAnchorage [b54ea2ae] | **rename** to test name; comment = old name | |
| 38 | [Misc] michelles_to_popa | 814edca6 | 61 | no_ts | **missing** | none (no test counterpart; out of scope for this pass) | |
| 39 | [Misc] part_michelles_to_popa | e94ee3dc | 24 | no_ts | **missing** | none (no test counterpart; out of scope for this pass) | |
| 40 | [RonAzul] 2011-04-23-Michelles2KenVonnes | d94e9fc6 | 51 | artifact(1322460452) | **exact** <-> test/2011-04-23-Michelles2KenVonnes [7a4ed9f0] | none (manual copy 2026-05-13) | |
| 41 | [RonAzul] 2011-04-24-KenVonnes2MichellesViaDolphinBay | 864e259c | 75 | artifact(1322460452) | **exact** <-> test/2011-04-24-KenVonnes2MichellesViaDolphinBay [864e602a] | none (manual copy 2026-05-13) | |
| 42 | [Soundings] 2011-10-26-SoundingExplorations | f84e92f0 | 444 | no_ts | **missing** | none (no test counterpart; out of scope for this pass) | |
| 43 | [many_trips_to_michelles] michelles | 804ecdac | 64 | no_ts | **match+lat_shift** <-> test/2011-06-17-Michelles2BocasMarina [724ea790] | **rename** to test name; drop generic old name | |
| 44 | [many_trips_to_michelles] michelles | 294e96ee | 78 | no_ts | **match+lat_shift** <-> test/2011-08-27-Michelles2BocasMarina [9b4e1676] | **rename** to test name; drop generic old name | |
| 45 | [many_trips_to_michelles] michelles | 7f4e11e0 | 71 | no_ts | **match+lat_shift** <-> test/2011-07-31-BocasMarina2Michelles [e84e21a0] | **rename** to test name; drop generic old name | |
| 46 | [many_trips_to_michelles] michelles | 234e133a | 52 | no_ts | **match+lat_shift** <-> test/2011-07-30-Michelles2BocasMarina [ef4ee3c4] | **rename** to test name; drop generic old name | |
| 47 | [many_trips_to_michelles] michelles | 814e7fb8 | 48 | no_ts | **match+lat_shift** <-> test/2011-05-06-Michelles2BocasMarina (with Isreal) [644ed820] | **rename** to test name; drop generic old name | |
| 48 | [many_trips_to_michelles] michelles | d74e57a0 | 57 | no_ts | **match+lat_shift** <-> test/2011-09-13-Michelles2BocasMarina [b14e93e2] | **rename** to test name; drop generic old name | |
| 49 | [many_trips_to_michelles] michelles | c04e4ca8 | 64 | no_ts | **match+lat_shift** <-> test/2011-05-02-Michelles2BocasMarina [004e4a14] | **rename** to test name; drop generic old name | |
| 50 | [many_trips_to_michelles] michelles | e74e01a6 | 52 | no_ts | **match+lat_shift** <-> test/2011-08-07-BocasMarina2Michelles [1a4e7582] | **rename** to test name; drop generic old name | |
| 51 | [many_trips_to_michelles] michelles | 1f4edb62 | 80 | no_ts | **match+lat_shift** <-> test/2011-10-17-Michelles2BocasMarina [284edefc]<br>**duplicate** of d64e871c | **dedupe** within sub-branch; survivor: **rename** to test name; drop generic old name | |
| 52 | [many_trips_to_michelles] michelles | 334e58ca | 75 | no_ts | **match+lat_shift** <-> test/2011-03-01-BocasMarinaToMichelles(dinghy flipped) [b34e6964] | **rename** to test name; drop generic old name | |
| 53 | [many_trips_to_michelles] michelles | 034efe6e | 60 | no_ts | **match+lat_shift** <-> test/2011-03-17-MichellesToMarina [494ec482] | **rename** to test name; drop generic old name | |
| 54 | [many_trips_to_michelles] michelles | 1f4e2d54 | 53 | no_ts | **match+lat_shift** <-> test/2011-08-27-BocasMarina2Michelles [ab4e73c6] | **rename** to test name; drop generic old name | |
| 55 | [many_trips_to_michelles] michelles | 0f4e667c | 69 | no_ts | **match+lat_shift** <-> test/2011-02-18-Marina2StoneSoupParty [e04e5568] | **rename** to test name; drop generic old name | |
| 56 | [many_trips_to_michelles] michelles | d64e871c | 80 | no_ts | **match+lat_shift** <-> test/2011-10-17-Michelles2BocasMarina [284edefc]<br>**duplicate** of 1f4edb62 | **dedupe** within sub-branch; survivor: **rename** to test name; drop generic old name | |
| 57 | [many_trips_to_michelles] michelles | 144edb26 | 44 | no_ts | **missing** | none (no test counterpart; out of scope for this pass) | |
| 58 | [many_trips_to_michelles] michelles | d44ed0a4 | 44 | no_ts | **missing** | none (no test counterpart; out of scope for this pass) | |
| 59 | [many_trips_to_michelles] michelles | 584ee2ce | 53 | no_ts | **match+lat_shift** <-> test/2011-04-26-Michelles2BocasAnchorage (w/Blayne) [d64e210a] | **rename** to test name; drop generic old name | |
| 60 | [many_trips_to_michelles] michelles | 3c4ede78 | 184 | no_ts | **missing** | none (no test counterpart; out of scope for this pass) | |
| 61 | [many_trips_to_michelles] michelles | a24e3c16 | 184 | no_ts | **missing** | none (no test counterpart; out of scope for this pass) | |
| 62 | [many_trips_to_michelles] michelles | 904e5dc0 | 66 | no_ts | **match+lat_shift** <-> test/2011-05-01-BocasMarina2Michelles [f14efae0] | **rename** to test name; drop generic old name | |
| 63 | [many_trips_to_michelles] michelles | 734e3648 | 51 | no_ts | **match+lat_shift** <-> test/2011-06-11-BocasMarina2Michelles [704e9760] | **rename** to test name; drop generic old name | |
| 64 | [many_trips_to_michelles] michelles | 234e896a | 60 | no_ts | **match+lat_shift** <-> test/2011-08-12-Michelles2BocasMarina [064ed640] | **rename** to test name; drop generic old name | |
| 65 | [many_trips_to_michelles] michelles | fd4e197a | 56 | no_ts | **match+lat_shift** <-> test/2011-08-14-BocasMarina2Michelles [9b4e5b5a] | **rename** to test name; drop generic old name | |
| 66 | [many_trips_to_michelles] michelles | 504e0e06 | 53 | no_ts | **match+lat_shift** <-> test/2011-08-05-Michelles2BocasMarina [3b4e3a34] | **rename** to test name; drop generic old name | |

## Cross-branch finding -- MichellToKuna 2011-07 mirrors test 2011-07-04..2011-07-26

The 15 tracks under `Michelle/MichellToKuna 2011-07/Tracks` form a
**1:1 byte-identical name match** with the 15 test-branch tracks dated
`2011-07-04-TripBegins-IslaBoa4thOfJuly` through `2011-07-26-ToLomaPartida`
inclusive.  They are the same physical trips recorded by two devices: the
test side is the handheld-GPS recording (from the source `.gdb`), the
MichellToKuna side is the E80 plotter's recording.  Different sample rate
and compression on each side; the lat/lon filter therefore can't pair
them by point.

Side-by-side npts:

| date / name | test npts | MichellToKuna npts | diff |
|---|---|---|---|
| 2011-07-04-TripBegins-IslaBoa4thOfJuly | 441 | 422 | -19 |
| 2011-07-06-ToPortobello | 500 | 471 | -29 |
| 2011-07-08-ToPorvenir | 369 | 345 | -24 |
| 2011-07-09-ToEastLemonAnchorage | 350 | 174 | -176 |
| 2011-07-10-ToCocoBanderas | 439 | 366 | -73 |
| 2011-07-11-ToAriadupRatones | 500 | 168 | -332 |
| 2011-07-13-ToSnugHarbor | 258 | 161 | -97 |
| 2011-07-16a-ToRioPlayonChico | 333 | 134 | -199 |
| 2011-07-16b-DinghyExploration | 441 | 121 | -320 |
| 2011-07-16c-ToIgnatioTupile | 113 | 92 | -21 |
| 2011-07-20-DinghyExploration | 360 | 237 | -123 |
| 2011-07-21-ToHollandaiseViaMiriadiadup | 481 | 481 | 0 (manual copy) |
| 2011-07-23-ToPorvenirAndChichime | 459 | 381 | -78 |
| 2011-07-24-ToPortobello | 388 | 359 | -29 |
| 2011-07-26-ToLomaPartida | 500 | 481 | -19 |

In the tables above each side is labeled `**missing**` and `**new**`
respectively, because exact-npts matching cannot pair them.  This
section is the cross-reference that ties them together.

Notes:
- Test-side npts at exactly 500 (07-06, 07-11, 07-26) reflects the
  handheld GPS's compressed-export cap; a separate "raw" export path
  exists without the cap (the Raw tracks at 416, 3160, 587 pts).
- The single 0-diff (07-21) is the 2026-05-13 manual copy from test
  into MichellToKuna; the MichellToKuna entry for that trip is
  currently a handheld recording, not an E80 recording.
