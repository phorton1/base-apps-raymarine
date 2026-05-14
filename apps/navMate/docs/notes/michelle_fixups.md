# Michelle Fixups

Working notes from one iteration of "suck all the info out of the current source
.gdb file before moving to the next one."  The current source is
`C:\dat\Tracks\2010-09-16-RhapsodyWithMichelle.gdb`, which was imported into the
flat `test` branch of navMate.  This doc characterizes the relationship between
that test branch and the existing `MiscBocas` and `Michelle` branches, and
sketches the shape of a possible mass-reconciliation pass.

The doc is transient -- it covers one .gdb's worth of input.  Three tracks
(`2011-04-23-Michelles2KenVonnes`, `2011-04-24-KenVonnes2MichellesViaDolphinBay`,
`2011-07-21-ToHollandaiseViaMiriadiadup`) have already been manually copied from
test into Michelle/RonAzul and Michelle/MichellToKuna 2011-07/Tracks on
2026-05-13.  Those manual copies are the worked example of the pattern being
characterized for possible scaling.


## 1. Scope

In scope: comparison between `test` (flat, 83 tracks), `MiscBocas` (flat,
9 tracks), and `Michelle` (nested, 66 tracks across 19 sub-collections).

Not in scope: oldE80 archaeology, FSH enrichment, navOperations, schema changes.
No DB writes proposed.  Temporal reorganization of MiscBocas/Michelle is a
prerequisite to any mass reconciliation but is not specified here.

### Place in the broader fixup plan

This work is one iteration of the per-.gdb absorption pattern within the
broader plan in `data_enrichment_plan.md`.  Direction is strictly
**test -> existing**: matched test tracks are promoted into the
appropriate existing branch (replace / rename / link), and genuinely
new test tracks are added.  After this iteration the `test` branch and
its source `.gdb` are retired; the next iteration starts with a fresh
`.gdb` imported into `test`.

Relative to the four-phase framing in `data_enrichment_plan.md`, this
iteration overlaps Phase 1 (new imports) for the **new** tracks and
sits upstream of Phase 3 (depth/temperature enrichment of existing
authoritative tracks from E80 source) for everything else.  It does
not perform the Phase 3 enrichment itself.


## 2. Characterization Findings

### 2.1 Test branch -- three per-point ts regimes

83 tracks total; 80 non-Raw plus 3 Raw.

| group | count | description |
|---|---|---|
| valid (per-point ts varies) | 4 | 3 are "Raw"-suffixed; one is not (`2010-09-20-CayaAgua2BocasAnchorage`) |
| artifact (single constant ts) | 50 | every point and ts_start = `1322460452` (2011-11-28 06:07:32 UTC) |
| no per-point ts | 29 | mostly 2010 + mid-2011 (Kuna trip) |

"Raw" suffix is a sufficient (3/3) but not necessary predictor of valid
per-point timestamps in this branch.

### 2.2 The 1322460452 timestamp artifact

A single constant value, uniformly stamped on every point of every track in
the cohort and also on those tracks' `ts_start` field.  Decodes to
2011-11-28 06:07:32 UTC -- the date of a single bulk-conversion event.

| location | tracks stamped | points stamped |
|---|---|---|
| test (the artifact cohort) | 50 | 2747 |
| Michelle/RonAzul | 2 | 126 |
| total | 52 | 2873 |

2873 of 107,897 track_points (2.66%) carry this value.  The Michelle/RonAzul
two are exact-byte copies of their same-named test counterparts (manual
2026-05-13 copies).  The artifact is bounded and scrubbable.

### 2.3 Same-npts pairing across branches

Filter: same npts on both sides (test "Raw" tracks excluded from the test
side), then median lat/lon offset within 1e-3 deg AND max per-point deviation
from that median within 5e-6 deg.

| verdict | count |
|---|---|
| MATCH | 50 |
| MAYBE | 2 |
| MISS (different area, coincidental npts) | 38 |

The 50 MATCHes split into two clean sub-populations with different signatures:

**Population A -- 2010 / pre-Marina cohort.**  Tracks in
`Michelle/Before Sumwood Channel` and `Michelle/First Summwood Channel`.
Median offset within 3e-8 deg of zero; max per-point deviation ~5e-7 deg
(consistent with 6-decimal rounding only).  Both sides went through the same
precision floor -- no shift applied to either.  ~16 MATCHes.

**Population B -- 2011 cohort.**  Tracks in
`Michelle/many_trips_to_michelles`, `Michelle/AguaAndTobobe`, `Michelle/Misc`,
`Michelle/RonAzul`, and `MiscBocas`.  Median lat offset = **+3.30e-05 deg
(~3.7 m N), consistent to 3-4 sig figs across all members**.  Lon offset
zero within rounding.  Max per-point deviation ~1e-6 deg.  ~31 MATCHes.

The remaining 3 MATCHes are the three manual 2026-05-13 copies, byte-identical
on both sides.

The provenance of the +3.30e-05 deg lat shift is not yet known.  It is too
small to be a clean datum change and too uniform to be track-by-track GPS
error.  *Conjecture:* a constant correction was applied during one of the
2011-era import paths; the existing (GE-rounded) side did not receive it.

### 2.4 Michelle sub-branch profile

The `c` prefix in some sub-branch names (e.g. `AguaAndTobobe c 2011-03-06`)
abbreviates "circa" -- the date is an approximate trip-cohort date, not a
per-leg date.

| sub-collection | tracks | naming | per-point ts | match outcome |
|---|---|---|---|---|
| Before Sumwood Channel/Tracks | 14 | dt-named | no_ts | Pop A (2010 matches) |
| First Summwood Channel | 2 | dt-named | no_ts | Pop A |
| MichellToKuna 2011-07/Tracks | 15 | dt-named | no_ts | exact_name_match (E80 mirror of test 2011-07) |
| AguaAndTobobe c 2011-03-06 | 4 | lowercase | no_ts | Pop B matches |
| Misc | 4 | lowercase | no_ts | Pop B matches |
| many_trips_to_michelles | 24 | all "michelles" | no_ts | Pop B; suspected internal duplicates |
| RonAzul | 2 | dt-named | artifact(1322460452) | exact-byte (manual 2026-05-13) |
| Soundings | 1 | dt-named | no_ts | unmatched |

### 2.5 Internal duplication in Michelle/many_trips_to_michelles

24 tracks all literally named "michelles".  Several share point counts
(44, 53, 64, 80, 184 appear more than once).  At least one true duplicate
confirmed: two npts=80 entries both match `test/2011-10-17-Michelles2BocasMarina`
with the same +3.30e-05 deg lat offset signature.  Contradicts the working
assumption of no duplicates in existing branches; should be inspected before
reconciliation.

### 2.6 MichellToKuna 2011-07 -- confirmed E80 mirror of test 2011-07-04..2011-07-26

The 15 dt-named tracks in `Michelle/MichellToKuna 2011-07/Tracks` are a
**1:1 byte-identical name match with the test cohort 2011-07-04 through
2011-07-26** (15 tracks on each side).  This is the **exact_name_match**
case: test holds the handheld-GPS recordings, the existing branch holds
the E80 plotter recordings of the same trips.

Empirical support:
- 15-of-15 name correspondence, in date order, no gaps.
- Test side is consistently denser; npts differences range 19 to 332
  (handheld samples more frequently than E80; both sides also apply
  their own compression -- see 2.7).
- Only exact agreement is `2011-07-21-ToHollandaiseViaMiriadiadup`
  (481 pts on both sides), which is the 2026-05-13 manual copy from
  test.  The MichellToKuna entry for that trip is therefore currently
  a *handheld* recording, not an E80 recording -- if uniformly-E80
  contents is desired for the sub-branch, that one entry needs to be
  reverted or re-labeled.

`working.fsh` does not contain these trips in the segmented form
MichellToKuna holds; A8 (FSH cross-check) does not help this cohort.

This pattern likely repeats in other sub-branches that look like
E80-origin collections (the lowercase-named ones in particular) --
not yet verified by name correspondence.

### 2.7 Smaller observations

- `MiscBocas` has zero ts-artifact contamination -- all 9 tracks are `no_ts`.
- The top-level Michelle branch is named singular ("Michelle"), not plural;
  the plural "Michelles" appears only as a sub-branch of an unrelated tree.
- One test track (`2011-09-14-BocasMarina2Michelles`) has only 1 point;
  treat as bad data, no reconciliation needed.
- Lowercase descriptive track names in some Michelle sub-branches
  (e.g. `zap_to_little_island_tobobe` in `AguaAndTobobe`, `to_south_anchorage`
  in `MiscBocas`) are historical workarounds for the era before the
  `tracks` table had a `comment` field.  Geographic detail that would
  now belong in `comment` was compressed into the `name`.  The rename
  policy in 3.3 reclaims this: dt-formatted name in `name`, descriptive
  workaround text moved to `comment`.
- Test-side npts cap of 500 appears on three tracks in the 2011-07
  cohort (07-06, 07-11, 07-26).  This is the handheld GPS's
  compressed-export limit; a separate "raw" export pathway exists
  without the cap (e.g. the 3 Raw tracks at 416, 3160, 587 pts).
  Implication: test-side tracks at exactly 500 pts may be truncated
  relative to the underlying handheld recording; the E80-side npts
  is an independent compression and not constrained to the same cap.
- 3 `MiscBocas` tracks have npts-diff-1-or-2 closest test candidates
  (`to crawl_key`, `zap_thru_agua_cut`, `zap_thru_crawl_key`) -- likely
  subsampled siblings, not orphans.


## 3. Shape of Mass Reconciliation -- two-axis matrix

Two orthogonal axes:

- **Filter group** -- which cohort a given test track or existing track
  falls into, based on the characterization above
- **Action** -- what we do with it

### 3.1 Filter groups (relation labels)

| label | description | source / example |
|---|---|---|
| **match** | clean lat/lon agreement, ~0 offset (Population A) | test <-> Michelle 2010-era (`Before Sumwood Channel`) |
| **match+lat_shift** | clean agreement with +3.30e-05 deg lat offset (Population B); shift is below GPS noise for the era and is operationally insignificant | test <-> {Michelle 2011 sub-branches, MiscBocas} |
| **exact** | byte-identical pair | the three 2026-05-13 manual copies |
| **npts_but_miss** | same name + same npts, lat/lon-filter disagrees | none in current data |
| **exact_name_match** (likely hh) / (likely E80) | same name across branches, npts differs | the MichellToKuna 2011-07 cohort (handheld <-> E80) |
| near-npts candidate (no label yet) | npts diff 1-2 with same-area lat/lon | 3 MiscBocas tracks; probable Michelle near-misses |
| **new** | test track with no candidate in existing | enumerated in `michelle_analysis.md` |
| **missing** | existing track with no candidate in test | enumerated in `michelle_analysis.md` |
| **duplicate** | confirmed duplicate within an existing sub-branch | `Michelle/many_trips_to_michelles` |

### 3.2 Action vocabulary

| code | action |
|---|---|
| A1 | Replace existing with corrected test (apply +3.30e-05 deg if **match+lat_shift**) -- *deprecated for **match+lat_shift**; the shift is operationally insignificant. Kept for hypothetical future workflows that need sub-rounding precision.* |
| A2 | Rename existing using test's dt-formatted name: set `tracks.name` to the test track's dt-formatted name; if the old name carries geographic detail not in the test name, move that text to `tracks.comment`; if the old name is generic (e.g. literally "michelles"), drop it. |
| A3 | Keep both as parallel records, link them (multi-source same trip) |
| A4 | Merge point sets (only if alignment is reliable) |
| A5 | Add test track as new entry into existing tree |
| A6 | De-duplicate within existing (no test involvement) |
| A7 | Scrub the `1322460452` ts when writing to existing (and on the two `Michelle/RonAzul` records that already carry it) |
| A8 | Cross-check against `working.fsh` as a third independent recording |

### 3.3 Applicable actions per filter group

Illustrative, not prescriptive.  Each filter group is shown with the actions
that plausibly apply to it; for each action, the first line repeats the
action description and the indented second line is the per-group note.

**match** (Population A, ~0 offset)
test <-> Michelle 2010-era (e.g. `Before Sumwood Channel`)
- A2 Rename existing to test's dt-formatted name
  if the test name is dt-better than the existing name
- A8 Cross-check against `working.fsh`
  useful where FSH happens to contain the matching trip;
  applicability per-track, not blanket

**match+lat_shift** (Population B, +3.30e-05 deg lat offset)
test <-> {Michelle 2011 sub-branches, MiscBocas}

The ~3.7 m N lat shift is below typical marine/consumer GPS precision for
the era and is operationally insignificant.  Existing position wins by
default; no coordinate transform applied.  The test side contributes
*naming only* -- and after that, test gets discarded along with the rest
of the test branch.

- A2 Rename existing using test's dt-formatted name
  set `tracks.name` to the test name (the dt prefix reclaims the
  per-leg date that the sub-branch label preserves only as a circa
  cohort date, e.g. `AguaAndTobobe c 2011-03-06`).  If the existing
  name carries geographic detail the test name lacks (e.g.
  `zap_to_little_island_tobobe` vs `2011-03-07-ZapatillasToIslaBoa`),
  move that text to `tracks.comment`.  If the existing name is
  generic (e.g. the 24 "michelles" in `many_trips_to_michelles`),
  drop it.
- A8 Cross-check against `working.fsh`
  useful where FSH happens to contain the matching trip;
  applicability per-track, not blanket
- A1 Replace existing with corrected test
  not applicable here -- shift is below GPS noise; no transform needed.
- A7 Scrub the `1322460452` ts on write
  not applicable here -- only renames are written into existing, not
  point data; existing records in this group are already `no_ts`.

**exact** (byte-identical pair)
the three 2026-05-13 manual copies in Michelle/RonAzul and
Michelle/MichellToKuna 2011-07/Tracks
- already done; no further action

**npts_but_miss** (same name + same npts, lat/lon disagrees)
no cases observed in current data.  If they appear, the actions are:
- A3 Keep both as parallel records, linked
  likely the correct outcome -- treat as multi-source same trip
- A4 Merge point sets
  possibly, only if point-to-point alignment is reliable
- A8 Cross-check against `working.fsh`
  helpful only when the trip is actually in FSH

**near-npts candidate** (no label yet; npts diff 1-2, same-area lat/lon)
3 MiscBocas tracks; probable Michelle near-misses to be enumerated
- per-case inspection first to confirm same trip
- then A1, A2, or A3 as the inspection dictates
- A7 Scrub the `1322460452` ts on write
  only if the test side actually carries the stamp for this pair
- **Caveat: do not apply near-npts matching to same-route cohorts.**
  `Michelle/many_trips_to_michelles` contains 24 legitimate recordings
  of the same physical Marina<->Michelle route.  Relaxing the npts
  constraint there would produce confident-looking but spurious pairs.

**exact_name_match** (likely hh) <-> (likely E80) -- same name across
branches, npts differs (handheld vs E80 same trip)
MichellToKuna 2011-07 cohort (14 pairs, exhaustively enumerated in
`michelle_analysis.md`); the pattern may repeat in other sub-branches
that are E80-origin (the lowercase-named ones in particular).

**Outcome: no transfer required.**  The existing side already carries
the E80 recording (including its native depth/temp data).  The test
side has no per-point ts and no other data not already present in the
E80 recording -- confirmed for the MichellToKuna cohort 2026-05-14
(all 15 test tracks: `n_distinct_ts=0`, `ts_start=0`).  Existing is
canonical, test is discarded with the rest of the test branch.  Names
are already identical, so no rename either.

**Same-route caveat applies** for any future generous "same path"
algorithm that broadens this group: gate by name similarity, date
proximity, or explicit cohort boundary -- never blindly across
same-route cohorts like `Michelle/many_trips_to_michelles`.

- A8 Cross-check against `working.fsh`
  does not help this cohort -- FSH does not contain the MichellToKuna
  2011-07 trips, and FSH's internal track segmentation differs from
  the way these trips are organized in the existing Michelle branch
- A3 Keep both / A4 Merge
  not applicable -- test branch is being discarded and nothing in test
  is gainful to bring across.

**new** (test track with no exact-npts match in existing)
enumerated in `michelle_analysis.md`
- A5 Add test track as new entry under the planned temporal organization
  destination tree shape is the prerequisite work
- A7 Scrub the `1322460452` ts on write
  only if the test track is in the artifact cohort

**missing** (existing track with no exact-npts match in test)
3 MiscBocas tracks confirmed; Michelle-side enumerated in
`michelle_analysis.md`
- A6 De-duplicate within existing
  only if internal-duplicate scan finds a match
- A7 Scrub the `1322460452` ts in place
  applies to the two Michelle/RonAzul records that already carry it

**duplicate** (confirmed internal duplicate within an existing sub-branch)
e.g. `Michelle/many_trips_to_michelles` (24 same-named tracks, at least
one true duplicate confirmed)
- A6 De-duplicate within existing
  no test involvement; runs as part of temporal reorganization, not
  reconciliation

### 3.4 Notes on the matrix

- A7 (artifact-ts scrub) applies only on the existing records that
  already carry the stamp (the two `Michelle/RonAzul` tracks).  The
  test branch is throwaway and does not need its `ts` column corrected;
  the **match+lat_shift** writes are renames only, no point data
  transferred, so the artifact ts never reaches existing through them.
- A1 (and its "+3.30e-05 deg correction") is no longer a default action
  for **match+lat_shift** -- shift is below GPS noise for the era.
  Kept in the vocabulary only for hypothetical future workflows that
  require sub-rounding precision.
- A8 (`working.fsh` cross-check) is most valuable for the **npts_but_miss**
  group, where the canonical version would be genuinely uncertain --
  and only insofar as FSH actually contains the trip.  For
  **exact_name_match** it is moot (FSH doesn't carry that cohort) and
  the outcome is already decided (existing canonical, test discarded).
- The **new** and **missing** sets are enumerated in `michelle_analysis.md`
  rather than here.

### 3.5 Auxiliary process discipline (not in the matrix)

- **Rename history is captured via `tracks.comment`.**  When a dt-named
  test version supersedes an info-bearing existing name (e.g.
  `2011-02-24-BocasAnchorageToBocasMarina` replacing `to_south_anchorage`,
  or `2011-03-07-ZapatillasToIslaBoa` replacing
  `zap_to_little_island_tobobe`), the old name's geographic detail is
  moved into `tracks.comment` -- the proper home for it, absent in the
  earlier era when the workaround names were created.  Generic old names
  (the 24 literal "michelles" in `many_trips_to_michelles`) carry no
  detail and are dropped.
- **Record the source .gdb filename per surviving track.**  All test-branch
  tracks in this pass originate from
  `2010-09-16-RhapsodyWithMichelle.gdb`.  Storing that lineage lets future
  passes from other .gdb files reason about overlap and precedence.
- **Raw vs non-Raw policy.**  Of 4 valid-ts tracks in test, 3 are
  Raw-suffixed and 1 is not.  The Raw cohort is the data-rich (per-point
  ts) version; the non-Raw is the user-facing version.  Keeping both --
  e.g. in a parallel `Raw/` sub-collection -- preserves all data without
  complicating browsing.
- **Per-iteration archive of the test branch before emptying.**  An
  exported snapshot of the test branch (or a timestamped copy of
  `navMate.db`) preserves the audit trail across iterations.
- **Pre-flight DB snapshot.**  A file-copy backup of `navMate.db`
  immediately before each iteration's first write makes the whole pass
  reversible.  Cheap insurance under the schema-guard rule.


## 4. Open Questions

- ~~**Which Population B version is canonically "better" in real terms.**~~
  *Settled 2026-05-14*: the ~3.7 m N lat shift is below typical
  marine/consumer GPS precision for the era and is operationally
  insignificant.  Existing position is canonical; no coordinate
  transform is applied.  Test contributes naming only, then is
  discarded with the rest of the test branch.
- **A more generous "same path" matching algorithm -- with cohort gating.**
  Exact-npts plus lat/lon filter handles Populations A and B cleanly but
  misses the **exact_name_match** cases (handheld-vs-E80, different
  sample rate) and the 3 near-npts MiscBocas cases.  A generous
  algorithm would detect
  "same path, different sample placement" without requiring npts
  equality -- candidates: resample the higher-density side to the
  lower-density side and apply the existing lat/lon filter, or compute
  a Frechet / Hausdorff distance between point sets.  **The algorithm
  must be gated** -- by name similarity, date-window proximity, or
  explicit cohort boundary -- because applying it blindly across a
  same-route cohort (e.g. `Michelle/many_trips_to_michelles`, 24
  recordings of the same Marina<->Michelle path) would generate
  high-confidence false positives.  Algorithm choice, gating rules,
  and thresholds TBD.
- **`working.fsh` content scope.**  FSH contains internally-segmented
  tracks; many segments are unrelated to MiscBocas/Michelle, and at
  least the MichellToKuna 2011-07 trips are not represented in the
  segmented form the existing Michelle branch holds.  Concrete content
  overlap between FSH and the existing branches has not been enumerated;
  A8's per-track applicability cannot be predicted without that
  enumeration.
- **Temporal reorganization target shape** for MiscBocas/Michelle --
  not specified here; this doc characterizes the inputs, not the
  destination.
