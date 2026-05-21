# navOps Paste Rule Restructure — Working Plan

**Status:** plan written 2026-05-21; implementation pending; NOT YET COMMITTED.

**Trigger:** cycle 24 test run regression at db.25a. The stage-2 predicate
`_pasteRuleAllows` in `navClipboard.pm:288-309` (`db_to_db_${type}_copy`)
is over-broad: it rejects ALL DB→DB non-cut non-fresh paste of waypoint/
group/route/branch/track items regardless of destination, but the executor
only conflicts on UUID uniqueness when creating a new INDEPENDENT RECORD.
When the destination is a `route_point` anchor (or a route object, on
spokes), the executor's action is REF-only (a new `route_waypoints` row
referencing the existing wp_uuid) — no uniqueness violation, fully legal.

**Patrick's directive:** fix completely and correctly. No half-fixes that
leave parallel cases lurking. AND don't break anything else. The only
explicit deferral is the long-standing "DB groups should demote to branches
when non-homogeneous" gap, which is NOT in scope here.

---

## Audit summary

### Reference vs record (fundamental distinction)

- **Waypoints, groups, routes, branches, tracks** are independent records.
  Each has a UUID-unique row in its own DB table. UUID-preserving paste of
  these in DB→DB direction is **always illegal** (would violate uniqueness).
- **Route_points** are references — rows in `route_waypoints` carrying a
  `wp_uuid` that points at an existing waypoints row. There is NO uniqueness
  constraint on wp_uuid; a route can reference the same waypoint twice,
  and multiple routes can share the same wp. UUID-"preserving" splice of
  route_points is **always legal** (REF only).

The rule needs to ask: "does this paste create an independent record, or a
reference?" The answer depends on (clipboard item type × destination type).

### Per-panel destination classification (relevant cells)

**DB destination:**

| Destination | Clipboard item | Action |
|---|---|---|
| collection (root/branch/group) PASTE | waypoint | PRESERVE → DB→DB UUID conflict (illegal); spoke→DB legal |
| collection PASTE | group/route/branch | PRESERVE → DB→DB UUID conflict (illegal); spoke→DB legal |
| collection PASTE | track | DB→DB blocked by `implementationError("DB-to-DB track copy")`; spoke→DB legal |
| collection PASTE_NEW (any) | any | MINT |
| collection PASTE_BEFORE/AFTER | waypoint | PRESERVE → blocked by predicate; same UUID-conflict risk as PASTE |
| collection PASTE_BEFORE/AFTER | group/route/branch | PRESERVE / MOVE (cut path) |
| collection PASTE_BEFORE/AFTER | route_point | (Currently lumped with waypoint at navOpsDB.pm:925-948 — latent bug; route_point has no meaning at collection anchor.) |
| route_point anchor PASTE_BEFORE/AFTER | waypoint or route_point | **REF only** — inserts row in route_waypoints. `_pasteOneWaypointToDB` may insert wp record if not in DB, but if WP exists at same UUID returns `'no_change'`. No UUID conflict. |
| route_point anchor PASTE_NEW_BEFORE/AFTER | waypoint or route_point | **Still REF only** — fresh flag does NOT mint a new waypoint at route_point anchor. See navOpsDB.pm:1185-1193. |
| route object | any | Currently GUARDED with "object is not a collection". E80/FSH support paste here as REF append; DB does not. **Design asymmetry.** |
| waypoint/track object | any | GUARDED "object not a collection" |

**E80 destination:**

| Destination | Clipboard item | Action |
|---|---|---|
| header:groups / header:routes / my_waypoints / group PASTE | waypoint | PRESERVE / UPDATE |
| header:groups etc PASTE | group | PRESERVE / UPDATE (group + member WPs) |
| header:routes / route obj PASTE | route | PRESERVE / UPDATE |
| route object PASTE | waypoint | REF append (`_pasteAllToE80`:980-1011) — requires WP already on E80 |
| header:tracks | any track | GUARDED `implementationError("paste to E80 tracks header not supported")` |
| header:tracks or non-tracks-header with track item | track | Silent skip at `_pasteAllToE80`:1046-1049 (now caught by `tracks_to_e80_paste` rule) |
| route_point anchor PASTE_BEFORE/AFTER | waypoint/route_point | REF (and PRESERVE/UPDATE for the wp record if missing) |
| route_point anchor PASTE_NEW_BEFORE/AFTER | waypoint/route_point | MINT new wp + REF |
| waypoint object | any | GUARDED `implementationError("paste at individual E80 waypoint node not supported")` |
| root / track object / track_group / other unhandled | any | No explicit guard; undefined behavior |

**FSH destination:** mirrors E80 but **tracks ARE writable**. Route object
PASTE waypoint = append to route.wpts (REF, with embedded record snapshot).

### Cross-spoke and DB↔spoke UUID semantics

- DB↔spoke UUID-preserving PASTE is LEGAL (DB and spoke records can share
  UUIDs; that IS the hub-and-spoke model).
- Spoke↔spoke UUID-preserving PASTE is LEGAL (E80 and FSH conceptually share
  "the same waypoint" at the same UUID, with FSH dashed-uppercase ↔ nav
  no-dash conversion at the seam).
- DB→DB UUID-preserving PASTE for record-creating destinations is **the
  only category that always violates uniqueness**.

### Reconciliation against current `_pasteRuleAllows`

Walking each rule in `navClipboard.pm:182-312`:

1. `db_cut_to_spoke` — correct
2. `e80_tracks_header_paste` — correct
3. `e80_individual_wp_paste` — correct
4. `tracks_to_e80_paste` — correct (closes silent no-op gap)
5. `root_branch_before_after` — correct
6. `db_paste_non_collection` — correct (but see D3 below — need to allow route object too)
7. `route_point_paste_non_wp` — correct
8. `db_to_db_${type}_copy` — **OVER-BROAD**. Cells incorrectly blocked:
   - DB→DB waypoint at route_point anchor (REF only)
   - DB→DB route_point at route_point anchor (REF only)

---

## D1–D5 spec

### D1 — Restructure the over-broad DB→DB rule

In `navClipboard.pm:288-309`, replace the blanket loop so cell-by-cell
checking respects record-vs-reference:

```
if (panel=db && source=db && !fresh && !cut_flag) {
    foreach item:
        t = item.type
        if (t in {waypoint, route_point}):
            if (right_click_node.type == 'route_point'): continue  # REF, legal
            if (t == 'route_point' && right_click_node.type IN {route, route_point}): continue  # REF append at route object, see D3
            reject "db_to_db_${t}_copy"
        elif (t in {group, route, branch}): reject "db_to_db_${t}_copy"
        elif (t == 'track'): reject "db_to_db_track_copy"
}
```

Note: by the end of D3 the route-object case below also gets carved out.

### D2 — Reject route_point clipboard items at non-route destinations

A route_point is meaningful only inside a route. Add predicate rule
covering all three panels:

```
if (item.type == 'route_point' && right_click_node.type NOT IN {route, route_point}):
    reject "route_point_at_non_route" with impl_error
```

This is destination-symmetric: a route_point can only land at a route
object (REF append) or a route_point anchor (REF splice).

This also closes the latent bug at `navOpsDB.pm:925-948` where route_point
items at a collection anchor get lumped with waypoints and call
`_pasteOneWaypointToDB`. Once the predicate rejects, the executor never
reaches that branch with a route_point.

### D3 — Add DB executor support for PASTE / PASTE_NEW at route object

E80 (`navOpsE80.pm:980-1011`) and FSH (`navOpsFSH.pm:702-722`) both
support paste at a route object: waypoint/route_point items appended as
REF. DB rejects with "paste target type 'object' is not a collection".

Add a route-object destination branch to `_pasteDB` (before the
"Standard paste into a collection" check at `navOpsDB.pm:1257-1263`):

- Detect right_click_node.type == 'object' && obj_type == 'route'.
- For each waypoint or route_point item, call `appendRouteWaypoint` at
  end-of-sequence using item.uuid.
- For waypoint items, ensure the wp record exists in the route's
  containing collection — call `_pasteOneWaypointToDB` first if needed.

Update `_getPasteMenuItemsRaw` so DB route objects are listed as valid
PASTE / PASTE_NEW destinations (mirroring how spoke routes are at
`navClipboard.pm:685`). Update `db_paste_non_collection` rule
(`navClipboard.pm:266-271`) so route-object is no longer rejected; only
waypoint and track object destinations remain rejected.

### D4 — Reject E80/FSH paste at unsupported destination types

`_pasteAllToE80` is called for non-route destinations but only handles
header:*/my_waypoints/group well. Add a positive-list predicate:

```
if (panel == 'e80') {
    allowed = {header:groups, header:routes, my_waypoints, group, route, route_point}
    if (right_click_node.type NOT in allowed): reject "e80_invalid_paste_dest" impl_error
}
if (panel == 'fsh') {
    allowed = {header:groups, header:routes, header:tracks, my_waypoints, group, route, route_point, track_group}
    if (right_click_node.type NOT in allowed): reject "fsh_invalid_paste_dest" impl_error
}
```

The existing `e80_individual_wp_paste` and `e80_tracks_header_paste`
rules become subsumed (or stay as specific-sentinel variants — implementer's
choice; both work as long as user-facing text doesn't regress on the
tests that already match those sentinels).

### D5 — Extend SS10.10 to standalone route_point items at spokes

`_routeMembersMissingAtSpoke` (`navOps.pm:244-287`) and `_doPaste`'s
route-dependency check (`navOps.pm:900-1000`) currently only walk
**routes in the clipboard**. A standalone route_point clipboard item with
its referenced wp_uuid missing from the destination spoke is equally
unresolvable.

Extend both functions to walk standalone route_point items as well:
their wp_uuid must be present on the destination spoke (or be satisfied
by another waypoint in the same clipboard).

For DB destination, keep the existing behavior (SS10.10 is order-
independent there — wp may arrive in the same batch).

---

## Testplan / runbook updates

### db module

- **db.25a** — restore cycle-23 pass criteria: "PASTE BEFORE STARTED/
  FINISHED; no IMPL ERROR; route_waypoints count increased by exactly the
  clipboard item count (12 → 15)". Verify runbook hasn't been altered to
  expect a sentinel; revert if so.
- **db.25b** — verify pass criteria still match.
- **NEW (db.35 or next available)** — PASTE waypoint at DB route object
  (D3 positive). Expected: REF append; route_waypoints count grows by 1;
  no new waypoints row.
- **NEW (db.36)** — COPY route_point, PASTE_BEFORE at DB collection
  anchor. Expected: IMPL ERROR sentinel (D2 rejection). No state mutation.
- **NEW (db.37)** — Pure-route_point DB COPY+PASTE_BEFORE at route_point
  anchor (D1 positive, no waypoint riding along). Fills test coverage hole.
- **db.30 / db.31** (stage 2's track PASTE_BEFORE/AFTER) — re-confirm
  IMPL ERROR sentinels still fire.

### e80 module

- **NEW (e80.31)** — PASTE at unsupported E80 destination (e.g., track
  object node). Expected: IMPL ERROR sentinel (D4).
- **Verify** existing e80 tests against the consolidated predicate.

### fsh module

- **NEW (fsh.33)** — paste at unsupported FSH destination, OR route_point
  to non-route destination (D2 + D4 coverage on FSH).

### hub module

- **NEW (hub.29)** — cross-spoke REF append: FSH waypoint to E80 route
  object, or similar. Verify D3 / spoke parity holds.

### plan.md updates

For each module that gains tests, update the corresponding plan.md
inventory entries with the new test names.

---

## Files expected to change

| File | Why |
|---|---|
| `apps/navMate/navClipboard.pm` | D1 restructure; D2 new rule; D3 menu + non-collection allowance; D4 positive-list predicate |
| `apps/navMate/navOpsDB.pm` | D3 route-object paste executor branch |
| `apps/navMate/navOps.pm` | D5 standalone-route_point in SS10.10 walks |
| `apps/navMate/test/db/runbook.md` | db.25a restore + new tests (D2, D3, D5 coverage) |
| `apps/navMate/test/db/plan.md` | Inventory new tests |
| `apps/navMate/test/e80/runbook.md` + `plan.md` | D4 negative + route-object positive tests |
| `apps/navMate/test/fsh/runbook.md` + `plan.md` | D2 / D4 coverage |
| `apps/navMate/test/hub/runbook.md` + `plan.md` | D3 cross-spoke positive (optional) |

---

## Deferred (explicit, single item)

**DB group homogeneity demotion** — a DB group that ends up containing
non-waypoint items should logically demote to a branch. Currently the
executor treats group and branch as equally mutable. Acknowledged
long-standing gap, NOT in scope.

---

## Cycle 24 state when this plan was written

- cycle 24 was running, db module reached db.25a which regressed.
- db.1 through db.24d had all PASSed (cycle 24 runtime, with the stage-2
  predicates active).
- Cycle was STOPPED at db.25a per Patrick's stop-on-first-discrepancy
  instruction.
- A `cycle_24.md` results file does not exist yet (cycle was not completed).
- The cycle 23 results in `apps/navMate/test/_results/cycle_23.md` reflect
  the all-PASS baseline (db.25a included).

## Verification after implementation

1. Re-run full cycle (will be cycle 24 since 24 was aborted, or cycle 25
   if a partial cycle_24.md results file is written first — TBD).
2. All cycle-23 PASS tests reproduce PASS.
3. Stage-2 negative tests (db.30/31/34, e80.29/30, hub.4b) still trigger
   their sentinels.
4. New tests from this work pass:
   - db.25a: PASS again (12→15 route_waypoints, no IMPL ERROR)
   - D2 new test: IMPL ERROR for route_point at non-route anchor
   - D3 new test: REF append to DB route object succeeds
   - D5: standalone route_point with missing wp blocks at spoke

## Process notes

- Patrick will NOT commit during this work.
- I (Claude) do BOTH the implementation AND the test cycle.
- After /compact, my conversation context shrinks. This file is the
  durable reference. Read it cold to resume.
- Durable memory entries (separate from this transient doc):
  - `navops_ref_vs_record.md` — reference vs record fundamental
  - `feedback_navops_fix_philosophy.md` — fix-completely directive
  - `navops_db_group_homogeneity_deferral.md` — the one allowed deferral
