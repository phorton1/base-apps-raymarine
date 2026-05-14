# Duplicate Resolution -- Design Notes

Speculative design for a navMate-native duplicate-resolution pass that
runs **before** any cross-source reconciliation (gdb or FSH).

Not committed to building; captured here so the rationale survives the
conversation that produced it (2026-05-14).

---

## Motivation

The `michelle_fixups` iteration surfaced internal duplicates within
the existing `Michelle/many_trips_to_michelles` sub-branch (see
`michelle_analysis.md` for the inventory):

- 24 tracks all literally named `michelles`
- Several share point counts (44, 53, 64, 80, 184 appear more than
  once)
- At least one confirmed true duplicate: two npts=80 entries
  (`1f4edb62` and `d64e871c`) both match
  `test/2011-10-17-Michelles2BocasMarina` with the same +3.30e-05 deg
  lat-shift signature, max per-point deviation ~1e-6 deg.

That contradicts the working assumption that existing branches contain
no duplicates.  Without addressing it, every future cross-source
reconciliation re-encounters the same internal-duplicates problem.
Cleaner to resolve once.

---

## Why a separate pass

Internal-consistency cleanup and cross-source reconciliation are
different problems:

- **Dedup** is about the existing data being self-consistent.  No
  external input.
- **Reconciliation** is about merging an external input (a `.gdb`,
  later an `.fsh`) into an existing data set assumed self-consistent.

Mixing them complicates both.  Dedup as a prior pass means
reconciliation never has to think about "did I match the right
duplicate?" -- by invariant, there's only one of anything in
existing.

---

## Technique

Same matching primitive as cross-branch reconciliation, applied
**within** a single sub-collection rather than across branches:

- Same `npts` (exact)
- Median lat / lon offset within rounding noise (|median| ~0)
- Max per-point deviation from the median offset within ~5e-6 deg
  (well below GPS noise; absorbs 6-digit rounding)

Sub-branch internal pairwise comparison; clusters of mutually-matching
tracks are duplicates.

### Same-route caveat

Do **not** apply the dedup primitive blindly within sub-branches
known to be same-route cohorts.  `many_trips_to_michelles` is the
prototype: 24 legitimate recordings of the same physical
Marina<->Michelle path.  Those tracks share starts, ends, and a
significant fraction of their middle, so any loosened matching
threshold would produce confident-looking but spurious clusters.

Within same-route cohorts, only the **strict** primitive applies
(exact npts + lat/lon median ~0 + max_dev within 1e-6 deg).  Looser
fits inside such a cohort are different trips, not duplicates.

For non-same-route sub-branches, the same primitive but with the
slightly more generous max_dev threshold (~5e-6 deg) catches
legitimate duplicates that may have small numerical drift.

---

## Generous-matching extension (deferred)

The exact-npts requirement misses duplicates where some upstream
process resampled or cropped one of the copies.  A generous algorithm
(resample-the-denser-side to the lower-density side, then apply the
existing lat/lon filter; or Frechet / Hausdorff distance) would catch
these.  Same gating rules apply: never blindly inside a same-route
cohort.

Not needed for the initial dedup pass -- the existing-data duplicates
observed so far are exact-npts matches.  Generous matching belongs in
a follow-up.

---

## UI shape

- Per-sub-branch scan; surface clusters of suspected duplicates as a
  navMate Reconciliation-pane-like view (or a dedicated dedup pane,
  same wxPerl / Pub::WX patterns).
- Per cluster: user picks survivor, or marks "actually distinct,
  not duplicates" (false positive rejection).
- Survivor inherits comment / color / any per-track metadata from
  whichever cluster member had the most detail.
- Deletees removed.
- Same JSON-backed state pattern as `reconciliation_ux_concept.md`:
  per-cluster decision record, status pending/done/failed,
  crash-tolerant.

---

## Ordering relative to other deferred work

- Dedup runs **before** any further .gdb or FSH reconciliation
  iterations beyond the one currently in flight
  (`2010-09-16-RhapsodyWithMichelle.gdb`).
- Dedup runs **after** the schema-provenance-columns work (see project
  memory `schema_provenance_columns`).  That schema change adds
  `source` / `created_at` / `modified_at` to all WGRT tables; the
  survivor records produced by dedup need `modified_at` to record
  the dedupe event.
- The temporal reorganization of `MiscBocas` / `Michelle` (mentioned
  in `michelle_fixups.md` as a prerequisite to mass reconciliation)
  is a separate human-driven activity that runs alongside dedup,
  not strictly before or after.

---

## Cross-references

- `michelle_analysis.md` -- the inventory that surfaced the dupes;
  the **duplicate** label in the `relations` column flags the only
  currently-confirmed case.
- `michelle_fixups.md` -- the broader iteration framing that
  noticed the dupes existed.
- `reconciliation_ux_concept.md` -- the per-.gdb workflow that
  benefits from a clean dedup pre-pass.
- `schema_provenance_columns` (project memory) -- the schema work
  that precedes dedup.
- `data_enrichment_plan.md` -- broader plan context.
