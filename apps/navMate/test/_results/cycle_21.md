# navOperations Test Run -- Cycle 21

**Date:** 2026-05-20
**Start:** 15:22
**End:** 17:07
**Cycle:** 21

---

## Summary

| Module | Result |
|--------|--------|
| db     | PASS -- all 33 steps |
| e80    | PASS -- 43 PASS + 1 NOT_RUN (e80.27 db_versioning) |
| tracks | PASS -- teensyBoat available; all 6 steps |
| fsh    | PASS -- all 39 steps |
| hub    | PASS -- 27 PASS + 1 NOT_RUN (hub.24 precondition_unmet) |

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
| db.24c Menu shape: PASTE at DB route object node blocked | PASS |
| db.24d Menu shape: PASTE at DB track object node blocked | PASS |
| db.25a Mixed clipboard PASTE_BEFORE at route_point | PASS |
| db.25b Mixed clipboard PASTE_NEW_BEFORE at route_point | PASS |
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
| e80.10a Re-upload IsolatedWP1 (if absent) | PASS |
| e80.10b Delete via E80 My Waypoints (all ungrouped) | PASS |
| e80.11a Re-upload Popa group | PASS |
| e80.11b Copy E80 Group, Push to DB | PASS |
| e80.12a Re-upload TestRoute (if absent) | PASS |
| e80.12b Copy E80 Route, Push to DB | PASS |
| e80.13 Multi-select Group + Route, Push to DB | PASS |
| e80.14 Paste New WP to E80 (fresh UUID) | PASS |
| e80.14b Copy E80 fresh-UUID WP, Paste to DB | PASS |
| e80.14c Mixed-classified E80 clipboard, PASTE_NEW | PASS |
| e80.15 Paste New Group to E80 (all-fresh UUIDs) | PASS |
| e80.16a Delete all E80 routes (if same-named present) | PASS |
| e80.16b Paste New Route to E80 | PASS |
| e80.17 Multi-select WPs, Paste to E80 | PASS |
| e80.18 Route point Paste Before/After on E80 | PASS |
| e80.19 DB-cut to E80 destination blocked | PASS |
| e80.20a Delete BOCAS1 from E80 if present | PASS |
| e80.20b Delete BOCAS2 from E80 if present | PASS |
| e80.20c Paste to E80 tracks header blocked | PASS |
| e80.21a Delete all E80 routes (cleanup before Test 21d) | PASS |
| e80.21b Delete all E80 groups+WPS | PASS |
| e80.21c Delete all E80 ungrouped WPs (no-op path) | PASS |
| e80.21d Route-dependency pre-flight | PASS |
| e80.22 Ancestor-wins accept path | PASS |
| e80.23 Ancestor-wins reject path | PASS |
| e80.24 Intra-clipboard name collision | PASS |
| e80.25a Upload IsolatedWP1 to E80 (setup for Test 25b) | PASS |
| e80.25b E80-wide name collision | PASS |
| e80.26 UUID conflict clean-create path | PASS |
| e80.27 UUID conflict dialog path | NOT_RUN (db_versioning) |
| e80.28a Ensure IsolatedWP1 on E80 (precondition for 28b/c) | PASS |
| e80.28b PASTE at E80 WP object node blocked | PASS |
| e80.28c PASTE_NEW at E80 WP object node blocked | PASS |
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
| hub.24 GUARD: Name collision destination-side | NOT_RUN (precondition_unmet) |
| hub.25 UUID-conflict in-place-update probe | PASS |
| hub.26 GUARD: Intra-clipboard name collision | PASS |
| hub.27 GUARD: Descendant-of-clipboard | PASS |
| hub.28 Route paste cross-spoke with missing member WPs | PASS |

---

## Issues

none
