# navOperations Test Run -- Cycle 20

**Date:** 2026-05-17
**Start:** 17:53
**End:** 18:54
**Cycle:** 20

First full-cycle run after the modular suite (db / e80 / tracks / fsh / hub) reached alpha-complete. Clean pass: zero FAILs, zero PARTIALs, zero PASSED_BUTs. Two NOT_RUNs in e80 are by design (db_versioning infrastructure absent; precondition-met no-op).

---

## Summary

| Module | Result |
|--------|--------|
| db     | PASS -- all 33 steps |
| e80    | PASS -- 41 PASS + 2 NOT_RUN (by design) |
| tracks | PASS -- teensyBoat available; all 6 steps |
| fsh    | PASS -- all 33 steps |
| hub    | PASS -- all 28 steps |

---

## Results Table

| Test | Status |
|------|--------|
| **db** | |
| Test 1 -- Position precision (32 PASTE_NEW_BEFORE bisections force AutoCompact) | PASS |
| Test 2 -- Copy WP -> Paste New | PASS |
| Test 3 -- Cut WP -> Paste (move) | PASS |
| Test 4 -- Delete WP (success) | PASS |
| Test 5 -- Delete Group (dissolve) | PASS |
| Test 6 -- Delete Group+WPS (success) | PASS |
| Test 7 -- Delete Group+WPS blocked (members in route) | PASS |
| Test 8 -- Delete Branch (recursive, safe) | PASS |
| Test 9 -- Copy Branch -> Paste New | PASS |
| Test 10 -- Cut Branch -> Paste (move) | PASS |
| Test 11 -- Copy Route -> Paste New | PASS |
| Test 12 -- Cut Route -> Paste (move) | PASS |
| Test 13 -- Cut Track -> Paste (move) | PASS |
| Test 14a -- Paste New Before (collection-member anchor) | PASS |
| Test 14b -- Paste New After (collection-member anchor) | PASS |
| Test 15a -- PASTE_NEW_BEFORE route point (copy-splice) | PASS |
| Test 15b -- PASTE_BEFORE route point (cut-splice) | PASS |
| Test 16a -- Paste New Before (route-object anchor) | PASS |
| Test 16b -- Paste New After (route-object anchor) | PASS |
| Test 17 -- Paste New Before (group-object anchor) | PASS |
| Test 18 -- Paste New Before (branch-object anchor) | PASS |
| Test 19a -- Paste New Before (route clipboard, WP anchor) | PASS |
| Test 19b -- Paste New Before (group clipboard, WP anchor) | PASS |
| Test 20 -- DEL_WAYPOINT blocked (WP in route) | PASS |
| Test 21 -- DEL_BRANCH blocked (member WP in external route) | PASS |
| Test 22 -- DB-copy track to DB destination blocked | PASS |
| Test 23 -- Recursive paste guard (branch into own descendant) | PASS |
| Test 24a -- Menu shape: PASTE at DB WP object node blocked | PASS |
| Test 24b -- Menu shape: PASTE_NEW at DB WP object node blocked | PASS |
| Test 24c -- Menu shape: PASTE at DB route object node blocked | PASS |
| Test 24d -- Menu shape: PASTE at DB track object node blocked | PASS |
| Test 25a -- Mixed clipboard PASTE_BEFORE at route_point | PASS |
| Test 25b -- Mixed clipboard PASTE_NEW_BEFORE at route_point | PASS |
| **e80** | |
| Test 1 -- Paste WP to E80 (UUID-preserving) | PASS |
| Test 2 -- Paste Group to E80 (UUID-preserving) | PASS |
| Test 3 -- Paste Route to E80 (UUID-preserving) | PASS |
| Test 4 -- Copy E80 WP, Push to DB | PASS |
| Test 5 -- Copy E80 WP, Paste New to DB (fresh UUID) | PASS |
| Test 6 -- Delete E80 WP (specific node) | PASS |
| Test 6b -- Delete E80 Group+WPS blocked (member in route) | PASS |
| Test 7 -- Delete via E80 Routes header | PASS |
| Test 8 -- Delete via E80 Groups header | PASS |
| Test 9a -- Re-upload Popa group | PASS |
| Test 9b -- Delete E80 Group + members via specific group node | PASS |
| Test 10a -- Re-upload IsolatedWP1 (if absent) | PASS |
| Test 10b -- Delete via E80 My Waypoints (all ungrouped) | PASS |
| Test 11a -- Re-upload Popa group | PASS |
| Test 11b -- Copy E80 Group, Push to DB | PASS |
| Test 12a -- Re-upload TestRoute (if absent) | PASS |
| Test 12b -- Copy E80 Route, Push to DB | PASS |
| Test 13 -- Multi-select Group + Route, Push to DB | PASS |
| Test 14 -- Paste New WP to E80 (fresh UUID) | PASS |
| Test 14b -- Copy E80 fresh-UUID WP, Paste to DB | PASS |
| Test 14c -- Mixed-classified E80 clipboard, PASTE_NEW | PASS |
| Test 15 -- Paste New Group to E80 (all-fresh UUIDs) | PASS |
| Test 16a -- Delete all E80 routes (if same-named present) | PASS |
| Test 16b -- Paste New Route to E80 | PASS |
| Test 17 -- Multi-select WPs, Paste to E80 | PASS |
| Test 18 -- Route point Paste Before/After on E80 | PASS |
| Test 19 -- DB-cut to E80 destination blocked | PASS |
| Test 20a -- Delete BOCAS1 from E80 if present | PASS |
| Test 20b -- Delete BOCAS2 from E80 if present | PASS |
| Test 20c -- Paste to E80 tracks header blocked | PASS |
| Test 21a -- Delete all E80 routes (cleanup before Test 21d) | PASS |
| Test 21b -- Delete all E80 groups+WPS | PASS |
| Test 21c -- Delete all E80 ungrouped WPs (no-op path) | PASS |
| Test 21d -- Route-dependency pre-flight | PASS |
| Test 22 -- Ancestor-wins accept path | PASS |
| Test 23 -- Ancestor-wins reject path | PASS |
| Test 24 -- Intra-clipboard name collision | PASS |
| Test 25a -- Upload IsolatedWP1 to E80 (setup for Test 25b) | PASS |
| Test 25b -- E80-wide name collision | PASS |
| Test 26 -- UUID conflict clean-create path | PASS |
| Test 27 -- UUID conflict dialog path | NOT_RUN (db_versioning) |
| Test 28a -- Upload IsolatedWP1 to E80 if absent | NOT_RUN (precondition met) |
| Test 28b -- PASTE at E80 WP object node blocked | PASS |
| Test 28c -- PASTE_NEW at E80 WP object node blocked | PASS |
| **tracks** | |
| Test 1 -- Create test tracks on E80 (Track1, Track2) | PASS |
| Test 2 -- Copy E80 Track, Paste to DB | PASS |
| Test 3 -- Cut E80 Track, Paste to DB | PASS |
| Test 4 -- Paste Track to E80 blocked | PASS |
| Test 5 -- Paste New E80 Track to DB (fresh UUID) | PASS |
| Test 6 -- Delete via E80 Tracks header | PASS |
| **fsh** | |
| Test 1 -- Paste WP to FSH (UUID-preserving) | PASS |
| Test 2 -- Paste Group to FSH (UUID-preserving) | PASS |
| Test 3 -- Paste Route to FSH (UUID-preserving) | PASS |
| Test 4 -- Paste Track to FSH (UUID-preserving) -- FSH-unique | PASS |
| Test 5 -- Copy FSH WP, Push to DB | PASS |
| Test 6 -- Copy FSH Group, Push to DB | PASS |
| Test 7 -- Copy FSH Route, Push to DB | PASS |
| Test 8 -- Multi-select Group + Route, Push to DB | PASS |
| Test 9 -- Copy FSH WP, Paste New to DB (fresh UUID) | PASS |
| Test 10 -- Cut FSH WP, Paste to DB (UUID preserved) | PASS |
| Test 11a -- Delete FSH WP (success) | PASS |
| Test 11b -- Delete FSH Group (dissolve) | PASS |
| Test 12 -- Delete FSH Group+WPS blocked (members in route) | PASS |
| Test 13 -- Delete via FSH Routes header | PASS |
| Test 14 -- Delete via FSH Groups header | PASS |
| Test 15a -- Re-upload Popa group to FSH | PASS |
| Test 15b -- Delete FSH Group + members via specific group node | PASS |
| Test 16a -- Re-upload IsolatedWP1 to FSH | PASS |
| Test 16b -- Delete via FSH My Waypoints (all ungrouped) | PASS |
| Test 17a -- Re-upload Popa group (setup for paste-new tests) | PASS |
| Test 17b -- Re-upload TestRoute | PASS |
| Test 18 -- Paste New WP to FSH (fresh UUID) | PASS |
| Test 19 -- Paste New Group to FSH (all-fresh UUIDs) | PASS |
| Test 20 -- Paste New Route to FSH (fresh route UUID, member WP UUIDs reused) | PASS |
| Test 21 -- Multi-select WPs, Paste to FSH | PASS |
| Test 22 -- Route point Paste Before/After on FSH | PASS |
| Test 23 -- Cut FSH Track, Paste to DB (UUID preserved) | PASS |
| Test 24 -- Copy FSH Track, Paste New to DB (fresh navMate UUID) | PASS |
| Test 25 -- Delete FSH Track (specific node) | PASS |
| Test 26 -- Delete via FSH Tracks header | PASS |
| Test 27 -- DB-cut to FSH destination blocked | PASS |
| Test 28 -- Lossy-transform pre-flight (db_to_fsh long-name warning) | PASS |
| Test 29 -- Intra-clipboard name collision | PASS |
| Test 30a -- Upload IsolatedWP1 to FSH (setup for 30b) | PASS |
| Test 30b -- FSH-wide name collision | PASS |
| Test 31 -- UUID conflict clean-create path | PASS |
| Test 32a -- Ensure IsolatedWP1 on FSH (precondition for 32b/c) | PASS |
| Test 32b -- PASTE at FSH WP object node blocked | PASS |
| Test 32c -- PASTE_NEW at FSH WP object node blocked | PASS |
| **hub** | |
| Test 1 -- Paste FSH WP -> E80 (UUID-preserving) | PASS |
| Test 2 -- Paste FSH Group -> E80 (UUID-preserving) | PASS |
| Test 3 -- Paste FSH Route -> E80 (UUID-preserving) | PASS |
| Test 4 -- GUARD: Paste FSH Track -> E80 blocked at tracks-header guard | PASS |
| Test 5 -- Paste E80 WP -> FSH (same UUID) | PASS |
| Test 6 -- Paste E80 Group -> FSH (same UUID) | PASS |
| Test 7 -- Paste E80 Route -> FSH (same UUID) | PASS |
| Test 8 -- Paste-New E80 WP -> FSH (fresh FSH UUID) | PASS |
| Test 9 -- Paste-New FSH WP -> E80 (fresh navMate UUID) | PASS |
| Test 10 -- Paste-New E80 Group -> FSH (fresh group UUID + fresh members) | PASS |
| Test 11 -- Paste-New FSH Route -> E80 (fresh route UUID; members reused) | PASS |
| Test 12 -- Cut E80 WP, Paste to FSH | PASS |
| Test 13 -- Cut FSH WP, Paste to E80 | PASS |
| Test 14 -- Cut E80 Group, Paste to FSH | PASS |
| Test 15 -- Cut FSH Group, Paste to E80 | PASS |
| Test 16 -- Push E80 WP -> FSH (cmd 10251) | PASS |
| Test 17 -- Push FSH WP -> E80 (cmd 10252) | PASS |
| Test 18 -- Push E80 Group -> FSH (multi-WP update) | PASS |
| Test 19 -- Push FSH Route -> E80 | PASS |
| Test 20 -- E80->FSH->E80 WP round-trip | PASS |
| Test 21 -- FSH->E80->FSH Group round-trip with members in route | PASS |
| Test 22 -- Multi-select 2 E80 WPs, Paste to FSH | PASS |
| Test 23 -- GUARD: Heterogeneous clipboard (Group + Route) blocked | PASS |
| Test 24 -- GUARD: Name collision destination-side | PASS |
| Test 25 -- UUID-conflict in-place-update probe | PASS |
| Test 26 -- GUARD: Intra-clipboard name collision | PASS |
| Test 27 -- GUARD: Descendant-of-clipboard | PASS |
| Test 28 -- Route paste cross-spoke with missing member WPs | PASS |

---

## Issues

none
