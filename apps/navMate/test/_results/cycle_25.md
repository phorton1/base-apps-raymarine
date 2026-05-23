# navOperations Test Run -- Cycle 25

**Date:** 2026-05-23
**Start:** 11:27
**End:** 13:46
**Cycle:** 25

First full cycle exercising the D6 spoke content-vs-destination predicate rule added to `_pasteRuleAllows` in `navClipboard.pm` (per Patrick's bug report about Paste/Paste_New menu options offered on Groups / Routes / MyWaypoints headers and pseudo-groups for incompatible clipboard content). Adds eight new negative tests (e80.32-35, fsh.33-36). Also exercises the `op=suppress` synchronous-HTTP-handler refactor in `navServer.pm` that eliminates a single-slot race that surfaced during a navMate restart at cycle start.

This cycle required two navMate restarts at the start of the db module: the initial run hit the suppress race (queued `op=suppress&val=1` was overwritten by the `op=clear_e80` that followed, popping an "E80 is already empty" okDialog that blocked the wx idle loop). After landing the suppress-synchronous fix and restarting navMate a third time, the documented reset block ran clean.

D6 + D6's absorbed-aware refinement landed cleanly: e80.22 / e80.23 (ancestor-wins, wp+group mixed clipboard at header:groups) PASS because the absorbed-aware check skips the wp item that is a member of the clipboard group. The new D6 negative tests (e80.32-35, fsh.33-36) all PASS with the expected `spoke_<type>_at_<dest>` IMPL ERROR sentinels. hub.23 was reworded to expect the D6 sentinel `Cannot paste route clipboard item at e80 'header:groups' destination` instead of the (now-unreachable-on-spokes) homogeneity-check sentinel, and PASS holds.

---

## Summary

| Module | Result |
|--------|--------|
| db     | PASS -- all 44 steps |
| e80    | PASS -- 49 PASS + 1 NOT_RUN (e80.27 db_versioning) |
| tracks | PASS -- teensyBoat available; all 6 steps |
| fsh    | 42 PASS + 1 FAIL (fsh.31) |
| hub    | PASS -- 28 PASS + 1 NOT_RUN (hub.24 precondition_unmet under no-silent-rename policy) |

---

## Results Table

| Test | Status |
|------|--------|
| **db** | |
| db.1 Position precision (32 PASTE_NEW_BEFORE bisections force AutoCompact) | PASS |
| db.2 Copy WP -> Paste New | PASS |
| db.3 Cut WP -> Paste (move) | PASS |
| db.4 Delete WP (success) | PASS |
| db.5 Delete Group (dissolve) | PASS |
| db.6 Delete Group+WPS (success) | PASS |
| db.7 Delete Group+WPS blocked (members in route) | PASS |
| db.8 Delete Branch (recursive, safe) | PASS |
| db.9 Copy Branch -> Paste New | PASS |
| db.10 Cut Branch -> Paste (move) | PASS |
| db.11 Copy Route -> Paste New | PASS |
| db.12 Cut Route -> Paste (move) | PASS |
| db.13 Cut Track -> Paste (move) | PASS |
| db.14a Paste New Before (collection-member anchor) | PASS |
| db.14b Paste New After (collection-member anchor) | PASS |
| db.15a PASTE_NEW_BEFORE route point (copy-splice) | PASS |
| db.15b PASTE_BEFORE route point (cut-splice) | PASS |
| db.16a Paste New Before (route-object anchor) | PASS |
| db.16b Paste New After (route-object anchor) | PASS |
| db.17 Paste New Before (group-object anchor) | PASS |
| db.18 Paste New Before (branch-object anchor) | PASS |
| db.19a Paste New Before (route clipboard, WP anchor) | PASS |
| db.19b Paste New Before (group clipboard, WP anchor) | PASS |
| db.20 DEL_WAYPOINT blocked (WP in route) | PASS |
| db.21 DEL_BRANCH blocked (member WP in external route) | PASS |
| db.22 DB-copy track to DB destination blocked | PASS |
| db.23 Recursive paste guard (branch into own descendant) | PASS |
| db.24a Menu shape: PASTE at DB WP object node blocked | PASS |
| db.24b Menu shape: PASTE_NEW at DB WP object node blocked | PASS |
| db.24d Menu shape: PASTE at DB track object node blocked | PASS |
| db.25a Mixed clipboard PASTE_BEFORE at route_point | PASS |
| db.25b Mixed clipboard PASTE_NEW_BEFORE at route_point | PASS |
| db.26 COPY WP -> PASTE blocked (predicate; DB-to-DB waypoint copy) | PASS |
| db.27 COPY group -> PASTE blocked (predicate; DB-to-DB group copy) | PASS |
| db.28 COPY route -> PASTE blocked (predicate; DB-to-DB route copy) | PASS |
| db.29 COPY branch -> PASTE blocked (predicate; DB-to-DB branch copy) | PASS |
| db.30 COPY track -> PASTE_BEFORE blocked (predicate; original-bug case) | PASS |
| db.31 COPY track -> PASTE_AFTER blocked (predicate; symmetry with db.30) | PASS |
| db.32 NEW_WAYPOINT at non-collection target blocked (predicate) | PASS |
| db.33 NEW_ROUTE at non-collection target blocked (predicate) | PASS |
| db.34 PASTE_BEFORE at route_point with non-WP clipboard blocked (predicate) | PASS |
| db.35 PASTE waypoint at DB route object (D3: REF append) | PASS |
| db.36 COPY route_point, PASTE at collection blocked (D2: route_point at non-route) | PASS |
| db.37 Pure route_point COPY+PASTE_BEFORE at route_point anchor (D1 carve-out) | PASS |
| **e80** | |
| e80.1 Paste WP to E80 (UUID-preserving) | PASS |
| e80.2 Paste Group to E80 (UUID-preserving) | PASS |
| e80.3 Paste Route to E80 (UUID-preserving) | PASS |
| e80.4 Copy E80 WP, Push to DB | PASS |
| e80.5 Copy E80 WP, Paste New to DB (fresh UUID) | PASS |
| e80.6 Delete E80 WP (specific node) | PASS |
| e80.6b Delete E80 Group+WPS blocked (member in route) | PASS |
| e80.7 Delete via E80 Routes header | PASS |
| e80.8 Delete via E80 Groups header | PASS |
| e80.9a Re-upload Popa group | PASS |
| e80.9b Delete E80 Group + members via specific group node | PASS |
| e80.10a Ensure at least one ungrouped WP on E80 | PASS |
| e80.10b Delete via E80 My Waypoints (all ungrouped) | PASS |
| e80.11a Re-upload Popa group | PASS |
| e80.11b Copy E80 Group, Push to DB | PASS |
| e80.12a Re-upload TestRoute | PASS |
| e80.12b Copy E80 Route, Push to DB | PASS |
| e80.13 Multi-select Group + Route, Push to DB | PASS |
| e80.14 Paste New WP to E80 (fresh UUID) | PASS |
| e80.14b Copy E80 fresh-UUID WP, Paste to DB | PASS |
| e80.14c Mixed-classified E80 clipboard, PASTE_NEW | PASS |
| e80.15 Paste New Group to E80 (all-fresh UUIDs) | PASS |
| e80.16a Ensure E80 routes empty | PASS |
| e80.16b Paste New Route to E80 | PASS |
| e80.17 Multi-select WPs, Paste to E80 | PASS |
| e80.18 Route point Paste Before/After on E80 | PASS |
| e80.19 DB-cut to E80 destination blocked | PASS |
| e80.20a Delete BOCAS1 from E80 if present | PASS |
| e80.20b Delete BOCAS2 from E80 if present | PASS |
| e80.20c Paste to E80 tracks header blocked | PASS |
| e80.21a Delete all E80 routes (cleanup) | PASS |
| e80.21b Delete all E80 groups+WPS | PASS |
| e80.21c Delete all E80 ungrouped WPs (no-op path) | PASS |
| e80.21d Route-dependency pre-flight | PASS |
| e80.22 Ancestor-wins accept path | PASS |
| e80.23 Ancestor-wins reject path | PASS |
| e80.24 Intra-clipboard name collision | PASS |
| e80.25a Upload IsolatedWP1 to E80 (setup for Test 25b) | PASS |
| e80.25b E80-wide name collision | PASS |
| e80.26 UUID conflict clean-create path | PASS |
| e80.27 UUID conflict dialog path | NOT_RUN (db_versioning infra not yet implemented) |
| e80.28a Ensure IsolatedWP1 on E80 | PASS |
| e80.28b PASTE at E80 WP object node blocked | PASS |
| e80.28c PASTE_NEW at E80 WP object node blocked | PASS |
| e80.29 DELETE_GROUP at E80 my_waypoints blocked (predicate) | PASS |
| e80.30 DELETE_GROUP_WPS with mixed my_waypoints + named group blocked (predicate) | PASS |
| e80.32 D6: WP paste at E80 routes header blocked | PASS |
| e80.33 D6: Group paste at E80 my_waypoints blocked | PASS |
| e80.34 D6: Route paste at E80 groups header blocked | PASS |
| e80.35 D6: Group paste at E80 named-group node blocked | PASS |
| **tracks** | |
| tracks.1 Create test tracks on E80 (Track1, Track2) | PASS |
| tracks.2 Copy E80 Track, Paste to DB | PASS |
| tracks.3 Cut E80 Track, Paste to DB | PASS |
| tracks.4 Paste Track to E80 blocked | PASS |
| tracks.5 Paste New E80 Track to DB (fresh UUID) | PASS |
| tracks.6 Delete via E80 Tracks header | PASS |
| **fsh** | |
| fsh.1 Paste WP to FSH (UUID-preserving) | PASS |
| fsh.2 Paste Group to FSH (UUID-preserving) | PASS |
| fsh.3 Paste Route to FSH (UUID-preserving) | PASS |
| fsh.4 Paste Track to FSH (UUID-preserving) -- FSH-unique | PASS |
| fsh.5 Copy FSH WP, Push to DB | PASS |
| fsh.6 Copy FSH Group, Push to DB | PASS |
| fsh.7 Copy FSH Route, Push to DB | PASS |
| fsh.8 Multi-select Group + Route, Push to DB | PASS |
| fsh.9 Copy FSH WP, Paste New to DB (fresh UUID) | PASS |
| fsh.10 Cut FSH WP, Paste to DB (UUID preserved) | PASS |
| fsh.11a Delete FSH WP (success) | PASS |
| fsh.11b Delete FSH Group (dissolve) | PASS |
| fsh.12 Delete FSH Group+WPS blocked (members in route) | PASS |
| fsh.13 Delete via FSH Routes header | PASS |
| fsh.14 Delete via FSH Groups header | PASS |
| fsh.15a Re-upload Popa group to FSH | PASS |
| fsh.15b Delete FSH Group + members via specific group node | PASS |
| fsh.16a Re-upload IsolatedWP1 to FSH | PASS |
| fsh.16b Delete via FSH My Waypoints (all ungrouped) | PASS |
| fsh.17a Re-upload Popa group (setup for paste-new tests) | PASS |
| fsh.17b Re-upload TestRoute | PASS |
| fsh.18 Paste New WP to FSH (fresh UUID) | PASS |
| fsh.19 Paste New Group to FSH (all-fresh UUIDs) | PASS |
| fsh.20 Paste New Route to FSH (fresh route UUID, member WP UUIDs reused) | PASS |
| fsh.21 Multi-select WPs, Paste to FSH | PASS |
| fsh.22 Route point Paste Before/After on FSH | PASS |
| fsh.23 Cut FSH Track, Paste to DB (UUID preserved) | PASS |
| fsh.24 Copy FSH Track, Paste New to DB (fresh navMate UUID) | PASS |
| fsh.25 Delete FSH Track (specific node) | PASS |
| fsh.26 Delete via FSH Tracks header | PASS |
| fsh.27 DB-cut to FSH destination blocked | PASS |
| fsh.28 Lossy-transform pre-flight (db_to_fsh long-name warning) | PASS |
| fsh.29 Intra-clipboard name collision | PASS |
| fsh.30a Upload IsolatedWP1 to FSH (setup for 30b) | PASS |
| fsh.30b FSH-wide name collision | PASS |
| fsh.31 UUID conflict clean-create path | FAIL |
| fsh.32a Ensure IsolatedWP1 on FSH (precondition for 32b/c) | PASS |
| fsh.32b PASTE at FSH WP object node blocked | PASS |
| fsh.32c PASTE_NEW at FSH WP object node blocked | PASS |
| fsh.33 D6: WP paste at FSH routes header blocked | PASS |
| fsh.34 D6: Group paste at FSH my_waypoints blocked | PASS |
| fsh.35 D6: Route paste at FSH groups header blocked | PASS |
| fsh.36 D6: Group paste at FSH named-group node blocked | PASS |
| **hub** | |
| hub.1 Paste FSH WP -> E80 (UUID-preserving) | PASS |
| hub.2 Paste FSH Group -> E80 (UUID-preserving) | PASS |
| hub.3 Paste FSH Route -> E80 (UUID-preserving) | PASS |
| hub.4 GUARD: Paste FSH Track -> E80 blocked at tracks-header guard | PASS |
| hub.4b GUARD: Paste FSH Track -> E80 groups header blocked (predicate) | PASS |
| hub.5 Paste E80 WP -> FSH (same UUID) | PASS |
| hub.6 Paste E80 Group -> FSH (same UUID) | PASS |
| hub.7 Paste E80 Route -> FSH (same UUID) | PASS |
| hub.8 Paste-New E80 WP -> FSH (fresh FSH UUID) | PASS |
| hub.9 Paste-New FSH WP -> E80 (fresh navMate UUID) | PASS |
| hub.10 Paste-New E80 Group -> FSH (fresh group UUID + fresh members) | PASS |
| hub.11 Paste-New FSH Route -> E80 (fresh route UUID; members reused) | PASS |
| hub.12 Cut E80 WP, Paste to FSH | PASS |
| hub.13 Cut FSH WP, Paste to E80 | PASS |
| hub.14 Cut E80 Group, Paste to FSH | PASS |
| hub.15 Cut FSH Group, Paste to E80 | PASS |
| hub.16 Push E80 WP -> FSH (cmd 10251) | PASS |
| hub.17 Push FSH WP -> E80 (cmd 10252) | PASS |
| hub.18 Push E80 Group -> FSH (multi-WP update) | PASS |
| hub.19 Push FSH Route -> E80 | PASS |
| hub.20 E80->FSH->E80 WP round-trip | PASS |
| hub.21 FSH->E80->FSH Group round-trip with members in route | PASS |
| hub.22 Multi-select 2 E80 WPs, Paste to FSH | PASS |
| hub.23 GUARD: Heterogeneous clipboard (Group + Route) blocked | PASS |
| hub.24 GUARD: Name collision destination-side | NOT_RUN (precondition_unmet under no-silent-rename policy) |
| hub.25 UUID-conflict in-place-update probe | PASS |
| hub.26 GUARD: Intra-clipboard name collision | PASS |
| hub.27 GUARD: Descendant-of-clipboard | PASS |
| hub.28 Route paste cross-spoke with missing member WPs | PASS |

---

## Issues

### fsh.31 -- FAIL: blocked by inherited FSH state from fsh.18 (test-ordering issue, no code regression)

**Test:** fsh.31 "UUID conflict clean-create path" (fsh module).

**Observed:** Pre-flight blocked the paste with `ERROR - FSH operation blocked: 1 name collision(s):` listing `waypoint 'BOCAS2' (from waypoint 'BOCAS2') already on FSH at UUID 834eef46cc06be78`. The runbook's PASS criterion is "AF4E-2324-6D01-BFA8 (BOCAS2) present on FSH with UUID preserved" -- not met because the paste was rejected pre-write.

**Nodes involved:** [IsolatedWP2] (`af4e23246d01bfa8`, name "BOCAS2") attempted as the paste source. The blocking record on FSH is `834eef46cc06be78` -- the fresh-UUID BOCAS2 minted by **fsh.18** ("Paste New WP to FSH (fresh UUID)") earlier in the same module run.

**Analysis:** fsh.18 mints a fresh-UUID BOCAS2 on FSH, and the runbook does not delete it before fsh.31. Under the no-silent-rename policy in force since 2026-05-20 (cycle 22+), a second BOCAS2 at a different UUID is a destination-side name collision -- the preflight blocks it. The same paste at the same UUID *would* succeed (UUID match wins over name collision per the FSH alpha probe), but only if the colliding fresh-UUID record were absent.

**Data state left behind:** FSH unchanged. The pre-fsh.18 BOCAS2 (`834eef46cc06be78`) remains. No new BOCAS2 at `AF4E-2324-6D01-BFA8` landed. DB record `af4e23246d01bfa8` (BOCAS2) unchanged.

**Catastrophic:** No.

**Reproducible:** Yes, on every cycle that runs fsh.18 before fsh.31 against a clean FSH fixture. Cycle 24 marked this PASS, which means either (a) the cycle 24 navMate state had different FSH content (this cycle has the fresh BOCAS2 from fsh.18 still present), or (b) the cycle 24 verification was incomplete. Worth re-checking the cycle 24 fsh.31 outcome carefully; this is the first appearance under the run-each-test-cleanly discipline I followed this cycle.

### e80.27 NOT_RUN -- db_versioning infrastructure absent

**Test:** e80.27 "UUID conflict dialog path" (e80 module). Requires DB versioning infrastructure not yet implemented. Unchanged from cycles 22-24.

### hub.24 NOT_RUN -- precondition impossible under no-silent-rename policy

**Test:** hub.24 "GUARD: Name collision destination-side" (hub module). Recurring NOT_RUN -- same disposition as cycles 22-24. The PASTE_NEW setup that would mint a fresh-UUID "Waypoint 25" on E80 is itself preflight-blocked by the no-silent-rename policy. Coverage of the underlying behavior is positive in hub.8, hub.10, hub.11, hub.20, hub.21, hub.26, e80.24, e80.25b, fsh.29, fsh.30b -- all PASS.

---

## Cycle-specific notes (code/infra changes exercised)

- **D6 spoke content-vs-destination predicate** (`navClipboard.pm`): per-destination accepted-clipboard-item-type matrix added to `_pasteRuleAllows`. Spoke destinations: `header:groups` accepts `group`; `header:routes` accepts `route`; `header:tracks` (FSH only) accepts `track`; `my_waypoints` and `group` accept `waypoint`; `route` accepts `waypoint`/`route_point`. Absorbed-aware: an item whose UUID appears in another clipboard item's `members`/`route_points` is skipped (mirrors `_resolveAncestorWins`).
- **`op=suppress` synchronous fix** (`navServer.pm`): `/api/test?op=suppress` now sets `$nmDialogs::suppress_confirm` / `_outcome` / `_error_dialog` directly on the HTTP server thread before the single-slot queue is touched. Eliminates the race where a subsequent `op=clear_e80` overwrote the queued suppress op and popped an okDialog. The `op=suppress` branch in `navTest.pm` was removed (dead code post-fix).
- **Runbook expectation updates** (Option B per Patrick): paste destinations changed from `header:groups` to `my_waypoints` for ~31 waypoint-clipboard paste tests across e80/fsh/hub runbooks (the old "Groups header as default WP landing zone" pattern was contaminated by the bug). hub.23 expectation rewored to expect D6 sentinel instead of the homogeneity-check sentinel that is now unreachable on spoke destinations with mixed type clipboards.
- **Master runbook discipline rule added**: "Announce each result in user-facing text" -- after every test, the PASS/FAIL/NOT_RUN verdict must appear in the assistant's reply text (not only in tool stdout). Applied for this cycle from db.36 onward.
