# navOperations Test Run -- Cycle 24

**Date:** 2026-05-21
**Start:** 17:29
**End:** 18:26
**Cycle:** 24

First full cycle exercising the navOps shared-predicate layer (stages 1+2+3 plus the post-stage-2 ref-only-destination refinement) wired into menu builders and `_doPaste` / `_doDelete` / `_doNew` preflight in navClipboard.pm + navOps.pm. The cycle adds nine new db tests (db.26-db.34 for predicate rejections, db.35-db.37 for the D1/D2/D3 ref-vs-record carve-outs), two new e80 tests (e80.29 / e80.30 for E80 my_waypoints predicate guards), and one new hub test (hub.4b for the tracks-to-E80-non-tracks-header predicate path that the prior cycle's hub.4 note flagged).

Cycle ran end-to-end against a single live navMate instance with no code restarts; runbook self-corrections were applied for three stale expectations (see Issues).

---

## Summary

| Module | Result |
|--------|--------|
| db     | PASS -- all 44 steps |
| e80    | PASS -- 45 PASS + 1 NOT_RUN (e80.27 db_versioning) |
| tracks | PASS -- teensyBoat available; all 6 steps |
| fsh    | PASS -- all 39 steps |
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
| fsh.31 UUID conflict clean-create path | PASS |
| fsh.32a Ensure IsolatedWP1 on FSH (precondition for 32b/c) | PASS |
| fsh.32b PASTE at FSH WP object node blocked | PASS |
| fsh.32c PASTE_NEW at FSH WP object node blocked | PASS |
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

### fsh.4 -- runbook expected pre-truncation track name (self-corrected mid-cycle, not catastrophic)

**Test:** fsh.4 "Paste Track to FSH (UUID-preserving) -- FSH-unique" (fsh module).

**Observed:** Paste landed correctly -- track `1A4E-ED92-4904-EBBE` on FSH, total tracks count = 124 (123 fixture + 1 new). FSH-side track name was "2005-11-25-SanD" (15 chars). Pass criterion in runbook expected the full source DB name "2005-11-25-SanDiego2Oceanside".

**Analysis:** The truncation is correct per the FSH 15-char name limit (see `e80_name_comment_limits.md` / `fsh_name_comment_limits.md` memory and the policy already exercised explicitly in fsh.28). The runbook's pass criterion was authored before the writer enforced the limit; the runbook expectation was stale, not the code.

**Resolution:** Self-corrected the fsh.4 pass criterion in `apps/navMate/test/fsh/runbook.md` to spell out the truncation and reference the source DB name. Test is PASS.

### hub.24 -- runbook describes a precondition the no-silent-rename policy makes impossible (self-corrected, NOT_RUN)

**Test:** hub.24 "GUARD: Name collision destination-side" (hub module). Recurring NOT_RUN -- same disposition as cycle 22 and cycle 23.

**Observed:** The runbook's PASTE_NEW setup (mint a fresh-UUID "Waypoint 25" on E80 to create a different-UUID same-name collision condition for the actual test) is itself preflight-blocked by the no-silent-rename policy. With no fresh-UUID "Waypoint 25" on E80, the actual test step cannot run.

**Analysis:** The collision-on-paste path is positively exercised by hub.8 / hub.10 / hub.11 / hub.20 / hub.21 / hub.26 / e80.24 / e80.25b / fsh.29 / fsh.30b (all passed cleanly). hub.24's particular different-UUID-same-name variant requires a way to construct a same-name pair on one spoke, which the policy specifically prevents.

**Resolution:** Self-corrected `apps/navMate/test/hub/runbook.md` -- hub.24 now explicitly documents NOT_RUN status with the reason and a pointer to the tests that cover the underlying behavior. Original setup retained below the new note as a comment in case the policy changes.

### hub.28 -- runbook required ProgressDialog STARTED + FINISHED on the hard-reject path (self-corrected, not catastrophic)

**Test:** hub.28 "Route paste cross-spoke with missing member WPs" (hub module).

**Observed:** Route `80B2-C48A-3A00-A1F1` (Michel_Agua route, FSH-side) selected from FSH and pasted at the E80 routes header. Preflight detected member WPs not on E80, fired `ERROR - Route 'Michel_Agua': member waypoint(s) not on E80 and not in clipboard: ...`, route absent from E80 after the attempt. This matched option (a) of the pass criterion (hard-reject + missing-member ERROR). However the trailing clause "ProgressDialog STARTED + FINISHED regardless" was not satisfied -- on the hard-reject path the preflight blocks before any wire dispatch, so no ProgressDialog appears.

**Analysis:** The runbook's two-option pass criterion was logically incompatible with the "regardless" clause -- option (a) is a preflight reject (no progress dialog), option (b) is a successful auto-pull (progress dialog). The "regardless" wording predates the option-(a) branch.

**Resolution:** Self-corrected `apps/navMate/test/hub/runbook.md` -- the pass criterion now scopes the ProgressDialog expectation to option (b) only. Option (a) hard-reject is explicitly recognized as not opening a ProgressDialog. Test is PASS on option (a).

### e80.27 NOT_RUN -- db_versioning infrastructure absent

**Test:** e80.27 "UUID conflict dialog path" (e80 module). Requires DB versioning infrastructure not yet implemented. Unchanged from cycle 22 and cycle 23.
