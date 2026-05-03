# navMate — Context Menu Test Plan

Test cases for the context menu feature. For the test machinery (endpoint, params,
node key format, CTX_CMD constants) and the reset procedure, see context_menu.md §7.

**NEW-* commands are excluded from automation.** NEW_WAYPOINT (10510), NEW_GROUP (10520),
NEW_ROUTE (10530), and NEW_BRANCH (10550) all open name-input dialogs that block the
test machinery.  Any test that requires creating a new object must be run manually via
the UI.


## 1. Initialize to known state

Follow context_menu.md §7.2 in full before running any tests:
1. Git-revert `C:/dat/Rhapsody/navMate.db` to the committed test baseline; reload DB.
2. Clear the E80 (no waypoints, groups, routes, or tracks).
3. Mark the log; set `suppress=1`.

Get node UUIDs for use in the tests below:
```
curl -s "http://localhost:9883/api/nmdb"
```


## 2. Database tests (no E80 required)

These tests run entirely within the database panel. The E80 need not be connected.

Replace `WP_UUID`, `GR_UUID`, `BR_UUID`, `RT_UUID`, `TK_UUID` with real UUIDs
from `/api/nmdb`. `DST_UUID` is the UUID of any collection node used as a paste target.

---

### 2.1 Copy WP → Paste New to collection (D-WP1 → D-CP-WP → Paste New)

```
curl -s "http://localhost:9883/api/test?panel=database&select=WP_UUID&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=DST_UUID&right_click=DST_UUID&cmd=10301"
```

Expected: new waypoint with fresh navMate UUID appears in DST collection; source WP unchanged.
Verify: `/api/nmdb` shows the new row.

---

### 2.2 Cut WP → Paste to collection (D-CT-WP → move)

```
curl -s "http://localhost:9883/api/test?panel=database&select=WP_UUID&cmd=10110"
curl -s "http://localhost:9883/api/test?panel=database&select=DST_UUID&right_click=DST_UUID&cmd=10300"
```

Expected: same UUID now has `collection_uuid = DST_UUID`; original collection loses the WP.

---

### 2.3 Delete WP (D-WP1 → DEL-WP)

```
curl -s "http://localhost:9883/api/test?panel=database&select=WP_UUID&right_click=WP_UUID&cmd=10410"
```

Expected: waypoint row removed. Verify: UUID absent from `/api/nmdb`.

---

### 2.4 Delete group shell — blocked by non-empty group (D-GR1 → DEL-GR)

```
curl -s "http://localhost:9883/api/test?panel=database&select=GR_UUID&right_click=GR_UUID&cmd=10420"
```

Use a group that has members. Expected: command blocked; warning in log; group and
members unchanged.  The success path (delete empty group shell) requires creating an
empty group via the UI (NEW-GR dialog) and is tested manually.

---

### 2.5 Delete group + all members (D-GR1 → DEL-GR+WPS)

```
curl -s "http://localhost:9883/api/test?panel=database&select=GR_UUID&right_click=GR_UUID&cmd=10421"
```

Use a group whose members are NOT referenced in any route.
Expected: collection row and all member WPs deleted.
Blocked variant: use a group whose members ARE in a route — warning in log; no change.

---

### 2.6 Delete branch — MANUAL ONLY

DEL-BR requires an empty branch.  Creating an empty branch requires the NEW-BR dialog,
which blocks the test machinery.  Test this path manually via the UI.

---

### 2.7 Copy branch → COPY_ALL (D-BR → clipboard=all)

```
curl -s "http://localhost:9883/api/test?panel=database&select=BR_UUID&cmd=10099"
```

Expected: clipboard set to `intent=all, source=database`. Status bar shows `[DB] all (N)`.
Do not attempt Paste after this — see context_bugs.md: paste-all-not-implemented.

---

### 2.8 Cut route → Paste to collection (D-CT-RT → move)

```
curl -s "http://localhost:9883/api/test?panel=database&select=RT_UUID&cmd=10130"
curl -s "http://localhost:9883/api/test?panel=database&select=DST_UUID&right_click=DST_UUID&cmd=10300"
```

Expected: route record's `collection_uuid` updated to DST; same UUID retained.

---

### 2.9 Copy route → Paste New to collection (D-CP-RT → fresh UUIDs)

```
curl -s "http://localhost:9883/api/test?panel=database&select=RT_UUID&cmd=10030"
curl -s "http://localhost:9883/api/test?panel=database&select=DST_UUID&right_click=DST_UUID&cmd=10301"
```

Expected: new route with fresh UUID; each member WP also gets a fresh UUID.

---

### 2.10 Cut track → Paste to collection (D-CT-TK → move)

```
curl -s "http://localhost:9883/api/test?panel=database&select=TK_UUID&cmd=10140"
curl -s "http://localhost:9883/api/test?panel=database&select=DST_UUID&right_click=DST_UUID&cmd=10300"
```

Expected: track's `collection_uuid` updated to DST.

---


## 3. E80 tests

The E80 must be connected and empty at the start (§1 above). These tests build
up E80 state progressively, so run them in order within a test cycle.

### 3.0 Populate E80 with test data

Before any E80 test, upload a waypoint, a group, and a route from the DB.

**Upload a single waypoint to E80 My Waypoints:**
```
curl -s "http://localhost:9883/api/test?panel=database&select=WP_UUID&cmd=10011"
curl -s "http://localhost:9883/api/test?panel=e80&select=my_waypoints&right_click=my_waypoints&cmd=10300"
```

**Upload a group (group shell + its members) to E80:**
```
curl -s "http://localhost:9883/api/test?panel=database&select=GR_UUID&cmd=10020"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10300"
```

**Upload a route to E80:**
```
curl -s "http://localhost:9883/api/test?panel=database&select=RT_UUID&cmd=10030"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10300"
```

Verify via `/api/db` or the winE80 tree that items appear before proceeding.
Note the E80-assigned UUIDs from `/api/db` — use them as `E80_WP_UUID`, `E80_GR_UUID`,
`E80_RT_UUID` in the tests below.

---

### 3.1 Copy E80 WP → Paste to DB (E-CP-WP → download, UUID-preserving)

```
curl -s "http://localhost:9883/api/test?panel=e80&select=E80_WP_UUID&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=DST_UUID&right_click=DST_UUID&cmd=10300"
```

Expected: WP inserted or updated in DB with E80's UUID.

---

### 3.2 Copy E80 WP → Paste New to DB (E-CP-WP → download, fresh UUID)

```
curl -s "http://localhost:9883/api/test?panel=e80&select=E80_WP_UUID&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=database&select=DST_UUID&right_click=DST_UUID&cmd=10301"
```

Expected: new WP with fresh navMate UUID (byte 1 = 0x82) inserted in DST.

---

### 3.3 Delete E80 waypoint (E-WP1 → DEL-WP)

```
curl -s "http://localhost:9883/api/test?panel=e80&select=E80_WP_UUID&right_click=E80_WP_UUID&cmd=10410"
```

Expected: DELETE_ITEM sent to E80; WP disappears from winE80 tree after refresh.

---

### 3.4 Delete E80 group + members (E-GR1 → DEL-GR+WPS)

```
curl -s "http://localhost:9883/api/test?panel=e80&select=E80_GR_UUID&right_click=E80_GR_UUID&cmd=10421"
```

Expected: DELETE_ITEM for group and each member WP sent to E80.

---

### 3.5 Copy E80 group → Paste to DB (E-CP-GR → download group)

```
curl -s "http://localhost:9883/api/test?panel=e80&select=E80_GR_UUID&cmd=10020"
curl -s "http://localhost:9883/api/test?panel=database&select=DST_UUID&right_click=DST_UUID&cmd=10300"
```

Expected: group collection and member WPs inserted or updated in DB.

---

### 3.6 Copy E80 route → Paste to DB (E-CP-RT → download route)

```
curl -s "http://localhost:9883/api/test?panel=e80&select=E80_RT_UUID&cmd=10030"
curl -s "http://localhost:9883/api/test?panel=database&select=DST_UUID&right_click=DST_UUID&cmd=10300"
```

Expected: route record and member WPs inserted or updated in DB.

---


## 4. E80 track tests (requires teensyBoat session)

Tracks on the E80 cannot be uploaded from the database — they must be recorded live
by driving the boat. This section therefore requires a separate teensyBoat session
before any tests can run.

### 4.0 Prerequisite — create test tracks on E80

Patrick runs teensyBoat (port 9881). Claude drives the boat using `boat_driving_guide.md`
to produce one or two short test tracks on the E80. Confirm tracks appear in the
winE80 Tracks section before proceeding.

Note the E80-assigned track UUIDs from `/api/db` and use them as `E80_TK_UUID` below.

---

### 4.1 Copy E80 track → Paste to DB (E-CP-TK → download)

```
curl -s "http://localhost:9883/api/test?panel=e80&select=E80_TK_UUID&cmd=10040"
curl -s "http://localhost:9883/api/test?panel=database&select=DST_UUID&right_click=DST_UUID&cmd=10300"
```

Expected: track record and track_points inserted in DB under DST collection.
Verify: `/api/nmdb` shows the track; point count matches what E80 reported.

---

### 4.2 Cut E80 track → Paste to DB (E-CT-TK → download + erase from E80)

```
curl -s "http://localhost:9883/api/test?panel=e80&select=E80_TK_UUID&cmd=10140"
curl -s "http://localhost:9883/api/test?panel=database&select=DST_UUID&right_click=DST_UUID&cmd=10300"
```

Expected: track inserted in DB; TRACK_CMD_ERASE sent to E80; track disappears from
winE80 Tracks after refresh. This is the end-to-end verification of the erase path.
If it works: add `e80-track-erase` to context_bugs.md Closed.
If not: add a real bug entry with the observed failure.

---

### 4.3 Guard — Paste track TO E80 blocked (tracks read-only on E80)

Does not require live tracks — any TK clipboard state suffices. Copy a track from DB:
```
curl -s "http://localhost:9883/api/test?panel=database&select=TK_UUID&cmd=10040"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10300"
```

Expected: paste rejected (track target on E80 is read-only); E80 unchanged.

---

### 4.4 Guard — Paste New blocked for E80 track clipboard (E-CP-TK → Paste New)

```
curl -s "http://localhost:9883/api/test?panel=e80&select=E80_TK_UUID&cmd=10040"
curl -s "http://localhost:9883/api/test?panel=database&select=DST_UUID&right_click=DST_UUID&cmd=10301"
```

Expected: Paste New rejected for track intent (tracks have no fresh-UUID duplicate path).

---


## 5. Guard / negative tests

These verify that blocked operations do not silently succeed.
Note: `/api/test` fires the command ID unconditionally — the menu-level `canPaste`
check is bypassed. Verify by reading the log, not by absence of menu items.

---

### 5.1 DEL-WP blocked when WP is referenced in a route

Put a WP in a route in the DB. Attempt delete:
```
curl -s "http://localhost:9883/api/test?panel=database&select=WP_IN_ROUTE_UUID&right_click=WP_IN_ROUTE_UUID&cmd=10410"
```

Expected: warning in log (waypoint in route — delete blocked); DB unchanged.

---

### 5.2 Paste blocked — D-CP-TK to database destination

Copy a database track, then attempt Paste (not Paste New):
```
curl -s "http://localhost:9883/api/test?panel=database&select=TK_UUID&cmd=10040"
curl -s "http://localhost:9883/api/test?panel=database&select=DST_UUID&right_click=DST_UUID&cmd=10300"
```

Expected: paste rejected in log (intent=track, source=database, cut=0); DB unchanged.

---

### 5.3 Paste blocked — any clipboard → E80 header/tracks destination

Copy any WP from DB, then attempt Paste to the E80 tracks header:
```
curl -s "http://localhost:9883/api/test?panel=database&select=WP_UUID&cmd=10010"
curl -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10300"
```

Expected: paste rejected (target is read-only tracks header); E80 unchanged.
