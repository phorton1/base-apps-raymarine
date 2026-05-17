# hub Module -- Plan (STUB)

**Status: STUB.** This module's content is not yet defined. It is filled in when the first three-panel (hub-and-spoke) operations are wired end-to-end -- after the fsh module is solid.

For shared philosophy and status definitions, see [`../master_plan.md`](../master_plan.md). For shared toolbox, see [`../master_runbook.md`](../master_runbook.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md). For execution, see [`runbook.md`](runbook.md).

---

## Intended Scope

The hub module exercises navOps operations whose source and destination span DIFFERENT non-DB transports, with navMate (the hub) coordinating the multi-hop flow. These are the operations that cannot be reduced to a single spoke pair -- the test surface that gives the hub-and-spoke architecture its name.

Anticipated three-panel flows:

- **E80 -> navMate -> FSH** -- COPY from E80 panel, PASTE / PASTE_NEW to FSH panel. The data passes through navMate's clipboard but neither the source nor the destination is the DB.
- **FSH -> navMate -> E80** -- the reverse direction. Track is the obvious exclusion (FSH track data does not transfer to E80; tracks can only be created on E80).
- **Cross-spoke multi-select** -- e.g. some E80 items + some FSH items in the same COPY operation; PASTE_NEW to DB or to a third panel.
- **Hub-mediated guards** -- guards that fire because the route goes through navMate (e.g. UUID conflict detection when the same UUID lives on multiple spokes).

## Baseline (intended)

Likely the same as fsh module's baseline plus E80-side population done by the module's own setup tests (mirror of e80 module's Tests 1/2/3 -- paste WP/group/route to E80 -- to get baseline content on E80 before any cross-spoke operation).

## Current Stub Behavior

All tests in this module currently record as `NOT_RUN (stub)`. The runbook contains placeholder test slots only.

## Open Design Questions

- Multi-spoke clipboard semantics -- what does it mean to COPY both an E80 group and a FSH waypoint in a single clipboard? Is the resulting clipboard `class=mixed` (E80 + FSH) different from the E80-internal `class=mixed` (push-classified + paste-classified) tested in the e80 module?
- Which spokes' guards fire for cross-spoke operations -- the source-side, destination-side, or both?
- Round-trip identity -- does E80 -> FSH -> E80 round-trip preserve all fields, or are some lossy?
- Ordering -- if a multi-spoke COPY has 3 items (E80 group, FSH route, DB waypoint), in what order does PASTE_NEW process them?

These questions are answered when the first hub flow is implemented, not before.
