# hub Module -- Plan

E80<->FSH cross-spoke operations routed through navMate. The hub module covers operations whose source and destination are different non-DB spokes; the canonical clipboard at the hub mediates without a direct E80<->FSH adapter. This is the test surface that exercises the hub-and-spoke architecture's namesake property.

For shared philosophy and status definitions, see [`../master_plan.md`](../master_plan.md). For shared toolbox, see [`../master_runbook.md`](../master_runbook.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md). For execution, see [`runbook.md`](runbook.md).

---

## Module Scope

| Family | Direction(s) | Notes |
|--------|------|-------|
| Cross-spoke PASTE (UUID-preserving) | FSH->E80, E80->FSH | Track ops covered in tracks/ module (writer-session protocol enabled DB/FSH->E80 paste 2026-05-27). |
| Cross-spoke PASTE_NEW (fresh UUID) | both directions | Fresh UUIDs minted at clipboard seam by `_pasteNewAllTo<Spoke>`. |
| Cross-spoke CUT/PASTE | both directions | Source-side deletion after destination success via `_cut<Spoke>*` helpers in `_doPaste`. |
| Cross-spoke PUSH | E80->FSH (cmd 10251 `CTX_CMD_PUSH_FSH`), FSH->E80 (cmd 10252 `CTX_CMD_PUSH_E80`) | Lossy-preflight skipped: E80<->FSH share name/comment limits + color palette. Missing-destination = warn+skip (no degrade to PASTE). |
| Round-trip identity | E80->FSH->E80, FSH->E80->FSH | Verifies field preservation across two cross-spoke hops. |
| Multi-select cross-spoke | both directions | Single-source-panel multi-select (clipboard is panel-scoped per `_snapshotNodes`); heterogeneous types in same paste. |
| Cross-spoke guards | both directions | Name collision destination-side, UUID-conflict precedence, descendant-of-clipboard, intra-clipboard collision. |

The module exercises Phase 3B (cross-spoke) wiring that landed in `_pasteAllToFSH` (accepts `cb->{source} eq 'e80'`), `_pasteAllToE80` (accepts `cb->{source} eq 'fsh'`), `_pushToFSH` / `_pushToE80` (cross-spoke push), and the dedicated `CTX_CMD_PUSH_E80` / `CTX_CMD_PUSH_FSH` menu items.

## ProgressDialog Expectations

Every test states explicit ProgressDialog expectation in its pass criteria. A spurious render OR a missing required render is a FAIL.

| Operation | ProgressDialog renders? |
|-----------|------------------------|
| FSH->E80 PASTE / PASTE_NEW | YES (E80-side write) |
| FSH->E80 CUT/PASTE | YES (E80-side write); FSH cleanup silent |
| FSH->E80 PUSH (cmd 10252) | YES (E80-side write) |
| E80->FSH PASTE / PASTE_NEW | NO (FSH-side write synchronous) |
| E80->FSH CUT/PASTE | YES (E80-side source cleanup) |
| E80->FSH PUSH (cmd 10251) | NO (FSH-side write synchronous) |

## Baseline

Minimal -- no E80 content. Section A's first tests populate E80 organically.

1. `git -C C:/dat/Rhapsody checkout -- navMate.db`
2. `op=refresh`
3. `op=suppress&val=1`
4. `op=clear_e80` + ProgressDialog wait
5. `op=load_fsh&path=C:/base/apps/raymarine/apps/navMate/test/_fixtures/test.fsh`
6. `cmd=mark+hub+module+reset`

After setup: `/api/db` empty; `/api/nmdb` reverted DB; `/api/fsh` test fixture (50 WPs / 4 groups / 3 routes / 123 tracks). hub.1 fires from this clean state.

## Pre-flight Rules Invoked (selected)

- **SS6.x** -- positional insert semantics, ancestor-wins
- **SS9 / SS10.5** -- DB-cut destination guards (not directly hit; hub flows are E80<->FSH cuts)
- **SS10.2** -- intra-clipboard name collision (hard-abort)
- **SS10.10** -- route paste suppressed when member WPs missing at destination spoke; test bypasses via `/api/test` so the underlying behavior is exercised
- **SS12.x** -- route-waypoint UUID preservation through PASTE_NEW
- **Cross-spoke lossy-preflight**: `e80<->fsh` direction is symmetric (identical name/comment limits + palette) -- no lossy warning fires.

Full pre-flight semantic catalog lives in the legacy `apps/navMate/docs/notes/navOps_testplan.md`.

## Test Inventory

Two-section structure per master_runbook's Test Organization Convention: positives first (`hub.<N>`), guards second (`hub.G<N>`).  Within positives, tests retain their cross-spoke sub-section organization (Section A through G) because state-dependent sequencing matters; the section labels are documentation, not separate test counters.

### Positive Tests

| Test    | What it verifies | Cross-spoke flow |
|---------|------------------|------------------|
| hub.1   | Paste FSH WP -> E80 (UUID preserved; ProgressDialog) | A: FSH -> E80 PASTE |
| hub.2   | Paste FSH Group -> E80 (group + embedded members; ProgressDialog) | A: FSH -> E80 PASTE |
| hub.3   | Paste FSH Route -> E80 (members present from hub.2; ProgressDialog) | A: FSH -> E80 PASTE |
| hub.5   | Paste E80 WP -> FSH (same UUID; in-place update or coherent skip) | B: E80 -> FSH PASTE (same-UUID round-trip) |
| hub.6   | Paste E80 Group -> FSH (same UUID; idempotent) | B |
| hub.7   | Paste E80 Route -> FSH (same UUID; idempotent) | B |
| hub.8   | Paste-New E80 WP -> FSH (fresh FSH UUID; new record alongside existing same-name) | C: PASTE_NEW |
| hub.9   | Paste-New FSH WP -> E80 (fresh navMate UUID; ProgressDialog) | C |
| hub.10  | Paste-New E80 Group -> FSH (fresh group UUID + fresh member UUIDs) | C |
| hub.11  | Paste-New FSH Route -> E80 (fresh route UUID; member WPs reused when already on E80; ProgressDialog) | C |
| hub.12  | Cut E80 WP, Paste to FSH (E80-side gone + ProgressDialog for cleanup; FSH-side present) | D: CUT/PASTE |
| hub.13  | Cut FSH WP, Paste to E80 (FSH-side gone synchronously; E80-side present + ProgressDialog) | D |
| hub.14  | Cut E80 Group, Paste to FSH (group + members migrate; E80 cleanup ProgressDialog) | D |
| hub.15  | Cut FSH Group, Paste to E80 (group + members migrate; E80 write ProgressDialog) | D |
| hub.16  | Push E80 WP -> FSH (cmd 10251; existing FSH record updated; no ProgressDialog) | E: PUSH |
| hub.17  | Push FSH WP -> E80 (cmd 10252; existing E80 record updated; ProgressDialog) | E |
| hub.18  | Push E80 Group -> FSH (multi-WP update; no ProgressDialog) | E |
| hub.19  | Push FSH Route -> E80 (ProgressDialog) | E |
| hub.20  | E80->FSH->E80 WP round-trip (sym, name, comment, lat/lon preserved; depth/temp on FSH default-init) | F: round-trip identity |
| hub.21  | FSH->E80->FSH Group round-trip with members in route | F |
| hub.22  | Multi-select 2 E80 WPs, Paste to FSH (both UUIDs preserved; no per-item progress confusion) | G: multi-select |
| hub.25  | UUID-conflict in-place-update: paste with same UUID + same name = in-place update.  Probes the open observation from FSH alpha about name-uniqueness firing before UUID-match check. | (positive of the in-place-update path) |
| hub.28  | Route paste cross-spoke with missing member WPs (SS10.10 bypassed via /api/test); destination state unmodified or partial-create with skipped-WPs warning. | (edge case, positive of the partial-create path) |

Note: hub Tests 4 / 4b retired 2026-05-29 -- FSH track-paste-to-E80 moved to the `tracks/` module (writer-session protocol enabled DB/FSH->E80 paste; tracks/ owns the coverage).

### Guard Tests

Renamed from previous numbers; old-number cross-reference kept inline.

| Test   | What it verifies | (was) |
|--------|------------------|-------|
| hub.G1 | Multi-select FSH Group + Route, Paste to E80 -- D6 spoke content-vs-destination predicate rejects the route component at `header:groups`. | hub.23 |
| hub.G2 | Name collision destination-side: same name + different UUID on dest = hard-abort with name-collision sentinel.  Neither side mutated, no in-place merge attempted. | hub.24 |
| hub.G3 | Intra-clipboard name collision: multi-select with two same-named WPs (hard abort). | hub.26 |
| hub.G4 | Descendant-of-clipboard: cross-spoke route paste at one of its own member-WP nodes (SS10.7). | hub.27 |

## Intra-module Sequencing

Tests within this module build state on E80 progressively from an empty start. Internal sequencing is intentional; independence is at the module boundary only.

Key sequencing decisions:

- Section A uses FSH->E80 PASTE to put content on E80 -- the seeding is the testing.
- Section B then round-trips that content back to FSH (same-UUID idempotent path).
- Section C's PASTE_NEW creates fresh-UUID records on both sides; doesn't depend on Section A/B but exercises a distinct path.
- Section D's CUT tests use items that are still on both sides (Section A landed them on E80; they pre-exist on FSH).
- Section E's PUSH targets records that exist on both sides.
- Section F's round-trip tests use Section C's fresh-UUID records (or create dedicated ones) to avoid no-op same-UUID round-trips.
- Section G/H run last; multi-select uses accumulated state, guards run on whatever state exists.

## Likely Gaps & Bugs to Probe

The hub conception deliberately probes these surfaces:

1. **Cross-spoke CUT cleanup dispatch (Section D)**: analog of the navOpsDB cut-dispatch bug from FSH alpha. Symptoms: source-side item still present after CUT, or wrong-spoke cleanup helper invoked.

2. **UUID-conflict precedence (hub.25 + implicit in Section B)**: FSH-alpha-noted possibility that same-UUID PASTE-WP may hit name-uniqueness guard before UUID-match in-place-update check.

3. **PASTE_NEW UUID byte 1 semantics (Section C)**: cross-spoke PASTE_NEW should mint navMate-form UUIDs (byte1 in the 0x4e family) at the clipboard seam; verify no spoke-specific byte-1 collisions.

4. **PUSH cmd_id symmetric wiring (Section E)**: cmd 10251 from E80 panel, cmd 10252 from FSH panel; verify lossy-preflight is skipped and missing-destination warn+skip behavior fires correctly.

5. **Refresh side-effects (every test)**: `_refresh<Spoke>` invoked from each paste handler. Verify destination panel re-renders accurately via `/api/db` and `/api/fsh`.

6. **Multi-select mixed types (hub.23)**: spoke D6 predicate rejects mixed-type clipboards on spoke destinations because no single destination accepts all member types (group + route share no common spoke destination). The per-type dispatch ordering in `_pasteAllToE80` / `_pasteAllToFSH` is unreachable for cross-spoke mixed clipboards but remains relevant for the wp+group special case (ancestor-wins absorption keeps that path live).

7. **ProgressDialog absence accuracy**: E80->FSH PASTE has no E80-side write -- ProgressDialog should NOT render. A spurious render flags a bug in either the dispatcher (opening a dialog for a no-op spoke) or in cleanup ordering.

## Notes

- **FSH dashed-uppercase UUIDs**: the `select=` parameter for `panel=fsh` uses FSH-native dashed-uppercase form verbatim. Cross-checks between `/api/db` (E80, navMate no-dash lower) and `/api/fsh` (dashed upper) require textual conversion -- helpers in the runbook.
- **Mixed-source clipboards**: not testable -- `_snapshotNodes` is panel-scoped, so a single COPY action can only snapshot from one source spoke. Multi-select "cross-spoke" tests use single-source-panel multi-select pasted to the OTHER panel.
- **Round-trip vs same-UUID PASTE**: Section B's "round-trip" is a degenerate case (same UUID is back where it started). The round-trip identity test in Section F (hub.20) uses fresh content to verify field preservation across two real hops.
- **No new fixture content**: existing `_fixtures/test.fsh` + reverted `navMate.db` are sufficient. No setup-derived UUIDs need pre-registration -- the runbook derives them from `/api/db` and `/api/fsh` after each operation.
- **Anti-patterns to avoid**: no `NOT_RUN (precondition met)` -- tests use ensure-pattern; no brittle find-without-seeding; coverage drawn from all four solid modules' patterns, not just one.
