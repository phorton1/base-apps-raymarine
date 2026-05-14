# Reconciliation UX -- Concept

Speculative design notes for a navMate-native UI to drive the per-.gdb
(and later per-FSH) reconciliation workflow currently being executed
manually via the temp Perl script `build_michelle_analysis.pl` and the
markdown tables in `michelle_analysis.md`.

Not committed to building; captured here so the thinking survives the
conversation that produced it (2026-05-14).

---

## Motivation

The per-.gdb reconciliation has data-application characteristics that
the markdown-doc approach is straining to express:

- per-track decisions (one row per test track)
- checkbox semantics (pending / done / failed)
- editable comment cells
- visual cues for "needs attention" vs "skip"
- crash-tolerance across navMate restarts

The script + markdown workflow does the work but with the human as the
state machine.  A UI would promote the human out of that loop while
keeping the curatorial decisions human-owned.

---

## Shape

- **"Incoming staging" becomes a first-class navMate concept.**  The
  `test` branch convention used in the current iteration generalizes
  into a recognized collection type with explicit semantics:
  transient lifetime, source-gdb (or source-fsh) provenance, retired
  after the iteration commits.
- **The matcher / classifier moves into navMate proper.**  The current
  temp script's logic (same-npts pairing, lat/lon median+max-dev
  filter, label classification: `match` / `match+lat_shift` / `exact`
  / `npts_but_miss` / `exact_name_match` / `new` / `missing` /
  `duplicate`) becomes a navMate module callable from the UI.
- **A Reconciliation pane (modeless window).**  Slots in alongside the
  planned `winFSH` and `winTreeBase` widgets; uses the same
  wxPerl / Pub::WX patterns.  Three tables analogous to the current
  markdown:
  - test branch: the **actionable** checkbox table -- one row per
    incoming track, one disposition decision per row.
  - existing tables (MiscBocas, Michelle, and any other destinations):
    **reactive read-only mirrors** that re-render as test-side
    decisions resolve.
- **"Do Changes"** button (deliberately not "Commit" -- that implies
  git).  Stream-processes applied decisions: apply, mark done,
  persist, next.  Checkboxes flip from `pending` to `done` (or
  `failed`) per row as their action lands.

---

## State persistence

Per-test-track decision records persisted to a JSON file (one file per
iteration, lives in `$temp_dir` or similar):

```
{
  "<test_track_uuid>": {
    "decision":   "rename_existing" | "add_as_new" | "none",
    "target_uuid": "<existing track uuid for renames; sub-branch uuid for new>",
    "comment":    "<authored text or empty>",
    "status":     "pending" | "done" | "failed",
    "error":      "<message when status=failed>"
  },
  ...
}
```

Keeping `status` orthogonal to `decision` means a mid-batch crash
doesn't lose decisions; failed actions can be retried without
re-deciding.  The JSON file is the recovery surface across navMate
restarts.

---

## Exceptions to strict 1:1 (test track -> one disposition)

- **Duplicate clusters in existing**: one test decision drives
  multiple existing-side outcomes (pick survivor, delete deletees,
  rename survivor per the **match+lat_shift** policy).  Checkbox
  stays on the test row, but a sub-control on that row picks which
  existing-side member is the survivor.  Ideally a separate dedup
  pre-pass (see `dedup_design.md`) makes this unnecessary by
  resolving internal duplicates before any reconciliation pass.
- **"Add as new" tracks**: need a target sub-branch in the
  destination tree.  Test-row checkbox alone doesn't carry that;
  an extra picker is needed.  The planned `winTreeBase` widget is
  the natural way to expose a browsable destination structure.
  Timeline-organized destination trees auto-resolve most placements
  (dt-named tracks land where their date says), but curated
  sub-branches (e.g. `many_trips_to_michelles` as a "routine
  trips, don't clutter the main timeline" grouping) remain
  editorial decisions.

---

## Things a UI cannot do

The reconciliation has a curatorial spine that resists algorithmic
capture:

- **Notability calls** -- which trips deserve the main timeline vs
  which collapse into a "routine repeat" sub-branch.  A rule like
  "all Marina<->Michelle trips collapse" would miss the dinghy-flipped
  day, the brother-emergency day, etc.
- **Sub-branch grouping decisions** -- which cohort a set of trips
  belongs to is editorial, not derivable.
- **Comment authoring** -- the geographic detail in
  `zap_to_little_island_tobobe` ("passes the little island near
  Tobobe") is human knowledge that the tool can store but not
  invent.

A UI *supports* these (move-to-sub-branch action, tagging system for
notable trips, an inline comment editor) but cannot *make* them.
That's the right division of labor; the algorithm surfaces
candidates, the human decides.

---

## Cost / volume threshold

- One .gdb iteration: manual + script wins on cost.
- Several .gdb iterations (~4-5+): a UI starts paying off.  The
  current GPS archive inventory has ~11 candidate .gdb files (see
  `gps_archive_analysis` project memory); if all are processed,
  the UI amortizes.
- FSH-side enrichment work (Stream B in `data_enrichment_plan.md`)
  has structurally similar shape; the same UI would handle it.

---

## Soft cost worth naming

Manual passes surface quirks fresh.  In the current iteration,
working manually surfaced:

- the +3.30e-05 deg lat shift across all Population-B pairs
- the 500-pt handheld-export cap
- the `c=circa` cohort-date convention
- the descriptive-lowercase-names-as-comment-workaround insight

Once codified into a tool, you stop seeing the data with the same
attention.  The tool would faithfully do what it was told, including
last-iteration's assumptions if they have stopped being true.  Not
a blocker, but a real consideration in the build-vs-not-build
decision.

---

## Cross-references

- `michelle_fixups.md` -- the per-iteration framing this UI would
  implement (now somewhat obsolete as a plan doc; useful as historical
  context).
- `michelle_analysis.md` -- the per-track decision tables this UI
  would present interactively.
- `dedup_design.md` -- the prior-pass that should land before this
  reconciliation UI (so reconciliation never has to handle internal
  duplicates).
- `data_enrichment_plan.md` -- the four-phase plan this work sits
  within (overlaps Phase 1, upstream of Phase 3).
- `winFSH_design.md` -- the FSH browser, sibling concept; could share
  the planned `winTreeBase` widget.
- `schema_provenance_columns` (project memory) -- the schema work
  that should land before this UI as well, so per-track records
  carry source/created_at/modified_at metadata.
