# Track Writing -- navMate Implementation Plan

**Status:** transient working doc (`_` prefix). Authored 2026-05-28 after
the design discussion that followed the live-protocol confirmation on
2026-05-27. Deleted (or promoted) once the work is landed.

## Comprehensive Audit and Coherent Edit Plan (2026-05-28 revision)

The initial 2026-05-28 implementation attempt landed partial fixes
but missed multiple gates because it didn't do a systematic
inventory first.  This section enumerates **every** touchpoint that
encodes the old "tracks-readonly-on-E80" assumption, the state of
prior changes, the remaining required changes, and the test-plan
ramifications.  It is the load-bearing reference for the coherent
edit pass below.

### Inventory: code touchpoints (NET/, apps/navMate/)

| # | File | Location | Old behavior | State |
|---|------|----------|--------------|-------|
|  1 | `NET/b_records.pm` | end of file | parsers only, no encoders | DONE -- buildMTA/buildTRKHeader/buildTRKPoint/buildTRKBatch added |
|  2 | `NET/d_TRACK.pm` | line 90 | `$TRACK_SERVICE_ID` was `my`, unexported | DONE -- now `our`, exported |
|  3 | `NET/d_TRACK_writer.pm` | (new file) | did not exist | DONE -- writer module created |
|  4 | `NET/d_TRACK.pm` | rule table | no SEND\|RECORD or RECV\|SAVED rule | DONE earlier (2026-05-27 commit) |
|  5 | `NET/e_TRACK.pm` | parseMessage | expect_trk did not include RECORD | DONE earlier (2026-05-27 commit) |
|  6 | `apps/navMate/navClipboard.pm` | `_pasteRuleAllows` line 225-231 | rejected E80 tracks-header dest | DONE -- removed |
|  7 | `apps/navMate/navClipboard.pm` | `_pasteRuleAllows` line 241-259 | rejected tracks at any E80 dest | DONE -- replaced with non-tracks-header guard only |
|  8 | `apps/navMate/navClipboard.pm` | `_getPasteMenuItemsRaw` line 901 | early-return for tracks header | DONE -- removed |
|  9 | `apps/navMate/navClipboard.pm` | `_getPasteMenuItemsRaw` line 910 | `is_collection` excluded tracks-header | DONE -- relaxed to all headers |
| 10 | `apps/navMate/navClipboard.pm` | `_e80NodesAllInDB` | rejected track type | DONE -- accepts track via getTrack |
| 11 | `apps/navMate/navClipboard.pm` | (new function) | no fine-grained track preflight | DONE -- `_pasteTracksToE80Allows` added |
| 12 | `apps/navMate/navOpsE80.pm` | `_pasteAllToE80` | track skipped silently | DONE -- routes to `_pasteTrackToE80` |
| 13 | `apps/navMate/navOpsE80.pm` | `_pasteNewAllToE80` | track skipped silently | DONE -- routes to `_pasteNewTrackToE80` |
| 14 | `apps/navMate/navOpsE80.pm` | `_pushToE80` | no track branch | DONE -- added track branch |
| 15 | `apps/navMate/navOpsE80.pm` | (new helpers) | -- | DONE -- `_writeTrackToE80`, `_pasteTrackToE80`, `_pasteNewTrackToE80`, `_normalizeTrackPointForWire`, `_trackItemPoints`, `_buildMtaRecForItem` |
| 16 | `apps/navMate/navOpsE80.pm` | `_normalizeTrackPointForWire` | only read `depth`, not `depth_cm` | DONE -- now reads either |
| 17 | `apps/navMate/navOpsE80.pm` | `_pasteE80` line 1772-1777 | SS10.8 GATE -- implementationError "paste to E80 tracks header not supported" | DONE -- removed; tracks-header passes through to `_pasteAllToE80` / `_pasteNewAllToE80`; pasting at an individual track node still errors with use-tracks-header message |
| 18 | `apps/navMate/navOpsDB.pm` | `_pushFromE80` line 1551 | track type silently skipped | DONE -- track branch added (name/color/companion_uuid sync) |
| 19 | `apps/navMate/navClipboard.pm` | `_dbNodesAllInE80` line 1109+ | track type falls into `else { return 0 }` (silent reject) | DONE -- accepts track via lazy `navOps::_track()->{tracks}{$uuid}` lookup |
| 20 | `apps/navMate/navClipboard.pm` | `_fshNodesAllInE80` line 1216+ | rejected track type explicitly | DONE -- accepts track via lazy `navOps::_track()->{tracks}{$uuid}` lookup |
| 21 | `apps/navMate/navClipboard.pm` | `_dbNodesAllInFSH` line 1141+ | track type falls into `else { return 0 }` | LEAVE -- FSH-writes tracks already work; DB→FSH track push out of scope for this work |
| 22 | `apps/navMate/navClipboard.pm` | `_fshNodesAllInDB` line 1079+ | rejects track type | LEAVE -- FSH→DB track copy is out of scope |
| 23 | `apps/navMate/navClipboard.pm` | `_e80NodesAllInFSH` line 1174+ | (need to verify) | TODO -- verify; if rejects, decide scope (E80→FSH track push could be enabled but is a parallel feature) |
| 24 | `apps/navMate/navOps.pm` | `_doPush` line 1431+ | branches by panel + cmd_id | LEAVE -- branches already exist for all directions; track support enabled by predicate fixes #19/#20 |
| 25 | `apps/navMate/navOps.pm` | homogeneity check line 1117 | rejects mixed batches | LEAVE -- pure-track batch has 1 type, passes |
| 26 | `apps/navMate/navOps.pm` | `_pasteRuleAllows` call site (line 889 in `_doPaste`) | -- | LEAVE -- now allows tracks per #6/#7 |
| 27 | `apps/navMate/navOps.pm` | `getPushMenuItems` track exclusion line 910 | excludes track_group | LEAVE -- track_group is FSH visual artifact, not relevant |
| 28 | `apps/navMate/navOpsDB.pm` | DB-to-DB track copy line 727, 1002 | `implementationError "DB-to-DB track copy ... not implemented"` | LEAVE -- DB-to-DB track copy is a separate feature, not in scope |
| 29 | `apps/navMate/navClipboard.pm` | `_pasteRuleAllows` D1 line 420-440 | rejects DB-to-DB track non-fresh copy | LEAVE -- consistent with #28 |

### Inventory: doc touchpoints (apps/navMate/docs/)

| # | File | Location | Old text | State |
|---|------|----------|----------|-------|
| D1 | `docs/ui_model.md` | line 355 | "tracks header ... read-only ... TRACK service offers no upload or delete path" | DONE earlier -- updated to "pending navOps wiring" wording |
| D2 | `docs/navOperations.md` | line 385-388 | "Tracks (DB to E80) cannot be sent" | DONE earlier -- updated |
| D3 | `docs/navOperations.md` | line 436 | mentioned `e80_tracks_header_paste` sentinel | DONE -- replaced with `tracks_to_non_tracks_header_e80` |
| D4 | `docs/navOperations.md` | line 450 | example "Cannot paste to E80 tracks header" | DONE -- replaced with current sentinel example |
| D5 | `docs/navOperations.md` | line 534 | `db_to_db_track_copy` example | LEAVE -- still valid |
| D6 | `docs/navOperations.md` | line 705 | "no paste accepted; tracks are read-only" | DONE -- rewritten to reflect new flow |
| D7 | `docs/navOperations.md` | line 1041 | "DB track copy not supported" | LEAVE -- DB-to-DB still not supported |
| D8 | `docs/navOperations.md` | line 1423 | "E80-to-DB pushes: route and track color-mismatch" | LEAVE -- accurate as-is |
| D9 | `docs/data_model.md` | (track section) | "wiring pending" qualifier | LEAVE -- still applies until full test verification; can drop later |
| D10 | `docs/testing.md` | line 34 | "current navOps blocks paste-to-E80-tracks" | DONE -- rewritten to reflect implementation complete |

### Inventory: test-plan touchpoints (apps/navMate/test/)

| # | File | Location | Old expectation | State |
|---|------|----------|-----------------|-------|
| T1 | `test/e80/plan.md` | line 42 | SS10.8 = paste to E80 tracks header blocked | DONE -- SS10.8 redefined as success path |
| T2 | `test/e80/plan.md` | line 120 | test 20c expects SS10.8 block | DONE -- test 20c rewritten as PASTE success |
| T3 | `test/e80/runbook.md` | line 495 | "Cannot paste to E80 tracks header" assertion | DONE -- assertion replaced with SAVED-ack expectation |
| T4 | `test/tracks/plan.md` | line 3 | "Track-paste-to-E80 is blocked" | DONE -- intro rewritten |
| T5 | `test/tracks/plan.md` | line 33 | SS10.8 listed | DONE -- redefined |
| T6 | `test/tracks/plan.md` | line 42 | test 4 expects PASTE blocked | DONE -- replaced with Test 4 (PASTE success), Test 4b (PASTE_NEW), Test 4c (non-tracks-header guard) |
| T7 | `test/tracks/runbook.md` | line 134 | same | DONE -- rewritten as new flow scenarios |
| T8 | `test/hub/plan.md` | line 13 | "Track only via FSH->E80 ... E80 read-only" | DONE -- rewritten |
| T9 | `test/hub/plan.md` | line 35 | "FSH->E80 paste-track (skipped)" | DONE -- replaced with writer-session ProgressDialog expectation |
| T10 | `test/hub/plan.md` | line 73 | hub.4b expects `tracks_to_e80_paste` rule | DONE -- updated to `tracks_to_non_tracks_header_e80` |
| T11 | `test/hub/runbook.md` | lines 141, 158, 160, 166, 183 | E80-tracks-header guard expectations | DONE -- Test 4 rewritten as success; Test 4b updated to new sentinel |
| T12 | `test/db/plan.md` | line 57 | DB-to-DB track copy "silently skipped" | LEAVE -- DB-to-DB track copy still not implemented; behavior unchanged |
| T13 | `test/db/runbook.md` | line 460, 626, 640 | DB-to-DB track copy not-implemented assertions | LEAVE -- still valid |
| T14 | `test/_results/cycle_25.md`, `test/_results/last_testrun*.md`, `docs/private/last_testrun*.md` | snapshots | historical | LEAVE |
| T15 | `test/tracks/runbook.md` | Test 6 (new) | -- | DONE -- Test 6 added for PUSH E80 -> DB sync of name/color |

### Per-Patrick directive: test plan updates ARE in scope this time

The 2026-05-28 first attempt scoped them out per "the testplan can
be modified thereafter."  That deferral was a mistake -- updating
the test plan in lockstep is part of "comprehensive."

### Coherent edit pass (ordered)

To execute against the muddied code:

1. **Remove the `_pasteE80` SS10.8 gate** (#17).  This is the
   current functional blocker; the user reports no menu paste item
   appears, but in fact the menu items DO appear after the earlier
   fixes -- they just hit the SS10.8 guard at runtime.  Need to
   verify both: (a) menu items render, (b) clicking them no longer
   hits the SS10.8 guard.
2. **Fix the cross-spoke push predicates** (#19, #20).  Specifically
   `_dbNodesAllInE80` and `_fshNodesAllInE80` need to accept track
   type by consulting `$wpmgr` extended with track-state, or by
   accepting a separate `$track` peer.  Choose the minimal-signature
   path: pass `$track` alongside `$wpmgr` in the peers hash (already
   structured for this in `buildContextMenu` line 116 via
   `_wpmgr() / _fshDb()`; just add `track => _track()`).
3. **Verify `_e80NodesAllInFSH`** (#23) -- this is the E80→FSH
   track push path.  Out of immediate scope unless we want
   bidirectional spoke push for tracks.  Leave for now but document.
4. **Update all docs** (D3, D4, D6, D9, D10).  Coherent wording:
   tracks are now full members of the E80 paste/push contract
   except that DB-to-DB track copy remains unimplemented.
5. **Update test plan and runbooks** (T1-T11, T15).  Replace each
   old assertion with the corresponding new-flow assertion.  Add a
   new positive PASTE-track scenario.
6. **Verify with grep** that no stale references remain to
   `tracks_to_e80_paste`, `e80_tracks_header_paste`,
   "tracks are read-only" (in the contexts that should no longer
   apply), or SS10.8-as-blocked.

### What does NOT need to change

Listed under "LEAVE" rows above.  Specifically:
- DB-to-DB track copy remains unimplemented (#21, #22, #28, #29, T12, T13)
- E80→FSH and FSH→DB track push paths remain rejected (out of
  scope; bidirectional spoke-track flows are a separate feature)
- `track_group` (FSH visual artifact) handling unchanged
- Homogeneity check unchanged (pure-track batch passes)

### Final implementation status (post-audit pass)

All TODO items in the audit table above are now DONE except those
explicitly marked LEAVE (out of scope: DB-to-DB track copy, E80->FSH
push, FSH->DB push, historical snapshot docs).

The functional state ready for testing:

- Encoders work (Phase 1)
- Writer module works (Phase 2; harness validates the wire protocol)
- Predicate layer fully wired (Phase 3 + #19 + #20)
- Executor layer fully wired (Phase 4 + #17 SS10.8 guard removed)
- PASTE_NEW dialog works (Phase 5a)
- Doc updates complete (D1-D8, D10; D9 left until test verification)
- Test plan updated (T1-T11, T15 done; T12-T14 left as still-valid)

A test cycle is the appropriate next step to empirically verify
the menu, paste, push, and dialog flows end-to-end.

## Scope

This plan covers the full vertical to land **DB -> E80 track upload** as
a navOps-visible operation:

- Encoders in `NET/b_records.pm`
- New writer class `NET/d_TRACK_writer.pm`
- Preflight rules in `apps/navMate/navClipboard.pm`
- Execute layer in `apps/navMate/navOpsE80.pm`
- UI / context-menu wiring including PASTE_NEW pattern and confirmation
  dialog

**Also in scope (same plan, same patch series):**

- PUSH-tracks (E80 -> DB) -- a small parallel to PASTE-tracks; the
  dirty-detection predicate we agreed on is what gates its menu, and
  there's no reason to ship the PASTE direction without the PUSH
  direction. Phase 4 covers both.
- FSH -> E80 cross-spoke tracks -- routes through the hub in-memory
  per the `navops_hub_and_spoke` memory; reuses the `d_TRACK_writer`
  primitive for the outbound leg. Phase 4 covers the hub-layer
  hookup.

**Out of scope** (to follow once this is in):

- Formal test plan additions under `apps/navMate/test/tracks/`
  (modifiable thereafter per Patrick)
- Modify-existing-track-on-E80 -- empirically confirmed unsupported by
  the transport (E80 returns `success=0x80040f07` on duplicate UUID).
  Not a thing to design.

## Captured Decisions

Pulled forward from the 2026-05-27/28 design conversation.

### Transport / protocol

- **Single rule table**, no separate writer-rule table.
  `NET/d_TRACK.pm::%TRACK_PARSE_RULES` is now explicitly dual-role
  (reader-side queries + writer-side uploads); landed 2026-05-27.
- **One UUID matters on the writer side** -- the MTA-CONTEXT UUID
  becomes the saved track's identity. E80 unconditionally mints its
  own `trk_uuid` for the points-CONTEXT regardless of what we send;
  the writer's points-CONTEXT UUID is decorative.
- **Chunk ceiling = 498 bytes** per BUFFER body, by analogy with the
  WPMGR ceiling. At 14 bytes/point and an 8-byte TRACK_HEADER, this
  is ~35 points per body group. Empirical large-track testing is a
  testplan follow-up.
- **Failure semantics:** any `success != 0x00040000` in the SAVED
  reply is a transport-layer failure. Empirically observed values
  include `0x80040f07` (duplicate UUID). The writer treats any
  non-success status as terminal failure and surfaces the raw hex.
- **Inter-frame timing:** no required pause between frames; no
  inter-frame delays in production. The harness's 1s delays were
  pure crash-isolation diagnostics and are dropped. Each message is
  sent via its own `b_sock::sendPacket` call (the existing pattern
  for `d_TRACK`/`d_WPMGR`): one frame per syscall, no concatenation
  within a body group. This gives per-message log lines in the
  monitor, lets Nagle / kernel buffering coalesce at the TCP layer
  if it chooses, and preserves discrete `e_TRACK::parseMessage`
  trace lines for each frame.

### navOps semantics

- **DB unchanged by PASTE / PASTE_NEW.** Only PUSH (E80 -> DB) modifies
  the DB row. PASTE writes to E80; the DB row stays as-is.
- **PASTE preflight rules for tracks:**
  - `name` length <= 15 (E80 transport limit, `$E80_MAX_NAME`)
  - point count > 0
  - `color` in 0..5
  - mta_uuid not already present on the E80-db cache
  - **no** name-uniqueness check (empirically verified: E80 allows
    duplicate-named tracks; differs from WPMGR objects)
- **PASTE_NEW** is the alternative when any track in a selected batch
  has an mta_uuid that collides with E80. Behavior:
  - PASTE_NEW always mints a **fresh navMate UUID for every track in
    the batch**, not just the colliding ones. Semantic is uniform:
    "fresh identity for everything."
  - The DB row is unchanged; the fresh UUID exists only on the E80
    side as the saved-track identity.
- **Menu state machine:**
  - No collision: PASTE enabled, PASTE_NEW visible-but-disabled.
  - Any collision: PASTE disabled, PASTE_NEW enabled.
  - PASTE_NEW invocation pops a confirmation dialog (see below).
- **Confirmation dialog wording** (Patrick's text, adopted verbatim):

  > Are you SURE you want to PASTE_NEW these track(s)? The need for
  > this is highly unusual and creating new tracks on the UUID might
  > not be your intention. Caution is suggested. This operation will
  > write (n) new tracks, (m) of which have existing UUIDs on the E80.

- **PUSH-tracks dirty predicate** = `(name, color)` diff only.
  `trk_uuid` is transport metadata, synced as a side-effect when PUSH
  fires but **not** part of the diff that enables the menu item.
- **Failure policy:** halt on any preflight or runtime failure. Report
  done-vs-pending counts; no skip-and-continue. Human operator
  resolves.

### Module placement

- **Encoders in `NET/b_records.pm`** (symmetric with the existing
  `parseMTA`, `parseTRK`, `parsePoint`).
- **Writer class in `NET/d_TRACK_writer.pm`** -- new module, sibling
  of `d_TRACK.pm`. Subclass of `b_sock` for symmetric monitoring
  through the existing sniffer dispatch.
- **No changes to `d_TRACK.pm`** beyond what already landed.
- **No changes to `e_TRACK.pm`** beyond what already landed.

## Phase 1 -- Encoders in `NET/b_records.pm`

New functions, all pure (no I/O), symmetric to the existing parsers:

```
encodeMTA($rec, $cnt)         -> 57-byte string
encodeTRKHeader($a, $cnt)     -> 8-byte string  (b=0 per spec)
encodeTRKPoint($pt)           -> 14-byte string
encodeTRKBatch($a, \@points)  -> encodeTRKHeader . join('', map encodeTRKPoint, @points)
```

Notes:

- `encodeMTA` takes `$cnt` as a second argument so that the binding
  invariant `cnt1 == actual_point_count` is structural -- the caller
  passes `scalar @points` and there's no opportunity to drift. The
  near-crash on 2026-05-27 happened because the harness pulled
  `$rec->{cnt1}` from a JSON field name that didn't exist; eliminate
  that whole class of bug by removing the lookup.
- `encodeMTA` sets the writer-side invariants from `TRACK_writing.md`:
  `k1_1 = 0x01`, `u1 = 0`, `k2_0 = 0`, `cnt2 = $cnt`.
- Coordinate encoding for new-from-DB tracks uses `latLonToNorthEast`
  (already in `a_utils.pm`, inverse of `northEastToLatLon`). For
  E80-originated tracks where north/east are already stored as int32,
  the encoder reads them directly without re-projecting.
- All packs are little-endian explicit (`v`, `V`, `l`, `s`) -- match
  what `parseMTA` and `parseTRK` consume.
- Each encoder asserts its output length and `fatal`s if wrong, same
  pattern as the harness.

No new external dependencies. Existing `MTA_REC_SPECS`,
`TRACK_HEADER_SPECS`, `TRACK_PT_SPECS` arrays in `b_records.pm` are
the source of truth for field offsets and types.

## Phase 2 -- `NET/d_TRACK_writer.pm`

New class. One instance = one writer session = one TCP connection =
one track upload.

### Public API

```perl
my $writer = apps::raymarine::NET::d_TRACK_writer->new(
    ip       => '10.0.166.121',
    port     => 2053,
    mta_rec  => $rec,           # hash; passed verbatim to encodeMTA
    points   => \@points,       # arrayref of point hashes
    uuid     => $mta_uuid_hex,  # the MTA-CONTEXT UUID (16-hex string)
    progress => $progress,      # shared hash; see Phase 4
);

my $ok = $writer->run();        # blocking; returns 1 on success, 0 on failure
my $err = $writer->{error};     # human-readable failure description
```

### Internals

- Extends `b_sock` with `proto => tcp`, `auto_connect => 1`,
  `auto_populate => 0`.
- `parser_class => 'apps::raymarine::NET::e_TRACK'`. The
  reader-side parser handles the SAVED reply (and any in-bound
  observations) via the dual-role rule table already landed.
- On construction, computes the body-group sequence:
  - 1 RECORD frame (seq = writer-chosen correlation token; conventional
    choice: `time() & 0xffffffff` or a process-local counter)
  - 3 frames for the MTA body group (CONTEXT/BUFFER/END)
  - 3*N frames for the points (N body groups, N = ceil(points / 35))
  - across batches: each batch's `a` field = previous batch's `a + cnt`
- Sends each frame via its own `sendPacket()` call (decision locked
  above). No coalescing within a body group, no inter-frame delays.
- After the last frame, awaits the SAVED reply on a shared variable
  the parser pokes via the standard `e_TRACK::parseMessage` -> reply
  emission path. Times out at 10s after the final frame.
- Terminates: closes the TCP socket and tears down the sockThread.
- Returns success / failure. The session is single-use; for the next
  track, instantiate a new `d_TRACK_writer`.

### Progress hooks

The writer pokes the shared `$progress` hash at body-group boundaries:

- After RECORD sent: `label = "Connecting"`, no done increment
- After MTA body group sent: `label = "MTA sent"`, `done++` in inner counter
- After each points body group: `label = "Points $i/$N"`, `done++` per body group
- After SAVED received: `label = "Saved"`, `done++` once more

The inner-counter convention matches the existing `d_TRACK` $progress
pattern (workers / total / done / label).

### Monitoring / colors

Inherits from `a_mon.pm:331-336`'s existing `$SPORT_TRACK` registration:
parser_class = e_TRACK, in_color = CYAN, out_color = BLUE. The transient
writer socket gets the same colors automatically because it points at
the same E80 port. No `a_mon.pm` changes needed.

## Phase 3 -- Preflight in `apps/navMate/navClipboard.pm`

Extend the silent predicates (`_pasteRuleAllows` / `_pushRuleAllows` /
the equivalents for track context) to know about tracks. Per the
`navops_predicate_layer` pattern, predicates are pure functions
consulted by both the menu builder and the executor.

### `_pasteTracksAllows($items)`

Returns one of:

- `'paste'`         -- all items pass all rules; PASTE enabled
- `'paste_new'`     -- any item has UUID collision; PASTE disabled,
                       PASTE_NEW enabled
- `'reject:<msg>'`  -- any item fails a non-UUID rule (name too long,
                       no points, bad color, etc.); both disabled

Rules applied per item (halt on first failure across the batch -- if
ANY item fails a hard rule, the whole batch is `reject`):

1. `name` length <= `$E80_MAX_NAME` (15 chars). Reject otherwise.
2. point count > 0. Reject otherwise.
3. `color` in 0..5. Reject otherwise.
4. `mta_uuid` not in the E80-db cache. If any item violates,
   downgrade `'paste'` to `'paste_new'`. Does NOT reject the batch.

### `_pasteNewTracksAllows($items)`

Returns `'paste_new'` whenever `_pasteTracksAllows` would return either
`'paste'` or `'paste_new'`. The semantic: PASTE_NEW is *always*
available when PASTE could be available, but UI logic only surfaces
PASTE_NEW (with confirmation) when PASTE is unavailable due to
collision.

### `_pushTracksAllows($items)`

PUSH is E80 -> DB; the predicate gates the menu item on E80 track
nodes and verifies before execution. Returns one of:

- `'push'`         -- all items have a DB counterpart and a real
                      `(name, color)` diff vs the DB row
- `'reject:<msg>'` -- any item has no DB counterpart (defensive,
                      since menu visibility should already imply
                      DB-side existence) OR no diff (defensive,
                      since menu enablement should already imply
                      dirty)

Rules per item (halt batch on any reject):

1. `mta_uuid` present in DB. Reject otherwise.
2. `(name, color)` differ from the DB row. Reject otherwise.

Note: `trk_uuid` is **not** part of the diff (transport metadata,
synced as side effect when PUSH fires).

### Integration with `n_utils.pm` `emit_as`

Reject results flow through `error()` / `implementationError()`
unchanged. The new code adds no novel error paths -- it composes on
the existing predicate-layer scaffolding.

## Phase 4 -- Execute layer in `apps/navMate/navOpsE80.pm`

New methods, parallel to the existing waypoint/route/group execute
methods.

### `pasteTracks($items, $progress)`

```
1. Run _pasteTracksAllows; abort if 'reject'.
2. If predicate returned 'paste_new', refuse (call sites should never
   reach pasteTracks for a collision batch; they should route through
   pasteNewTracks instead).
3. $progress->{total} = scalar @$items, done = 0.
4. For each $item:
     - $progress->{label} = $item->{name}.
     - Construct an mta_rec hash from the DB row.
     - Instantiate d_TRACK_writer with $item's mta_uuid.
     - $writer->run().
     - On failure: stop; set $progress->{error} = $writer->{error};
       leave $progress->{done} at whatever count succeeded.
     - On success: $progress->{done}++.
5. After all items: $progress->{label} = 'done'.
```

### `pasteNewTracks($items, $progress)`

Identical to `pasteTracks` except:

- Skips the UUID-collision check (collision is the trigger for
  invoking this method, not a blocker).
- Mints a fresh navMate UUID per item before constructing the
  `d_TRACK_writer`. Uses `navDB::newUUID($dbh)` for consistency with
  the existing pattern (which is what `_newNavUUID` wraps).

### `pushTracks($items, $progress)` -- E80 -> DB

First-class deliverable in this plan; the predicate above defines its
enabling condition.

```
1. Run _pushTracksAllows; abort if 'reject'.
2. $progress->{total} = scalar @$items, done = 0.
3. For each $item:
     - $progress->{label} = $item->{name}.
     - Locate DB row by mta_uuid.
     - Copy all transport-relevant fields from E80-db row to DB row:
       name, color, trk_uuid, plus anything else the schema carries
       that the E80 can authoritatively report. Points are immutable
       on E80, so points are not part of the copy.
     - On DB error: stop; $progress->{error} = message; halt batch.
     - On success: $progress->{done}++.
4. After all items: $progress->{label} = 'done'.
```

### Hub-layer cross-spoke: FSH -> E80 tracks

Per `navops_hub_and_spoke` memory, cross-spoke is composed in-memory
through the hub form (no transient DB row required). For tracks, the
new pieces in this plan are:

- A small translator that maps an FSH-db track entry to the hub form
  (the DB-row-shaped hash that `pasteTracks` expects in its `$item`
  list). Most fields are direct copies; UUID format normalization is
  needed (FSH stores dashed-uppercase, hub uses 16-char no-dash
  lowercase -- see `uuid_formats` memory).
- A hookup in whatever hub-layer routing module already handles
  cross-spoke operations for other object types (waypoints / routes /
  groups). The hookup adds the track case: select tracks in FSH
  panel, drop on E80 tracks header, route through hub-form translator
  to `pasteTracks` (or `pasteNewTracks` if any FSH UUID collides
  with E80; the PASTE-vs-PASTE_NEW predicate applies unchanged).

The `d_TRACK_writer` primitive is unchanged. The cross-spoke layer
does not call into NET directly; it composes navMate-side operations.

## Phase 5 -- UI / context-menu wiring

### Tree node enablement

In whatever menu builder gates the E80 panel's `tracks` header and
individual `track` nodes (current state per `ui_model.md`: read-only),
add the PASTE / PASTE_NEW items:

- PASTE on tracks header (drop target for batch paste from DB clipboard)
- PASTE_NEW on tracks header (same target; enabled per predicate)
- (PUSH on individual track nodes -- follow-up for the push direction)

The PASTE / PASTE_NEW visibility-and-enabled state is driven by
`_pasteTracksAllows($clipboard_items)`:

| Predicate result | PASTE          | PASTE_NEW       |
|------------------|----------------|-----------------|
| `paste`          | enabled        | visible+disabled |
| `paste_new`      | visible+disabled | enabled       |
| `reject:<msg>`   | visible+disabled | visible+disabled |

(A reject batch may also surface a tooltip with the first reject
reason; existing menu pattern.)

### Confirmation dialog for PASTE_NEW

A new modal dialog before `pasteNewTracks` runs, text exactly as
captured in Decisions above. Two buttons:

- **Cancel** (default): close dialog, no action.
- **PASTE_NEW**: close dialog, proceed.

Dialog should be styled in line with existing confirmation dialogs
(navMate's standard modal pattern).

### Progress dialog

Standard `ProgressDialog` integration, reusing the existing pattern
used by other E80 operations. `$progress->{total}` is the outer
track count; inner per-body-group ticks can update the label only
(no need for a separate inner-progress bar unless we want one for
giant tracks).

## Test Surface

After this plan lands, the following becomes testable manually
through the navMate UI:

1. **Single track PASTE** -- DB-side select one track, paste to E80
   tracks header. Track appears on E80; navMate auto-refresh picks
   it up.
2. **Multi-track PASTE** -- DB-side select N tracks, paste. All N
   appear on E80.
3. **PASTE with mid-batch failure** -- contrive a name >15 chars in
   one of the batch items; preflight rejects the entire batch.
4. **PASTE_NEW path** -- batch includes one previously-pasted track
   (UUID already on E80). Menu shows PASTE disabled, PASTE_NEW
   enabled. Click triggers dialog; confirm; all tracks (including
   the non-colliding ones) get fresh UUIDs and write successfully.
5. **PASTE_NEW dialog cancel** -- click PASTE_NEW, see dialog,
   cancel. No write occurs.
6. **Large track PASTE** -- a track with >35 points exercises the
   multi-batch body-group path.
7. **PUSH-tracks** -- change a color on E80 (or rename a track on
   E80 via its menu), observe PUSH becomes enabled for that track on
   the navMate side, invoke push, observe DB row updated. Confirm
   `trk_uuid` is silently synced as a side effect (DB row's
   `trk_uuid` now matches E80's).
8. **Cross-spoke FSH -> E80** -- with an FSH archive loaded and the
   E80 connected, select FSH tracks, drop onto E80 tracks header.
   Tracks appear on E80 with their FSH-source UUIDs (or fresh UUIDs
   if PASTE_NEW path triggered by collision). DB rows are NOT
   created -- the route is FSH -> hub-in-memory -> E80.

Formal `apps/navMate/test/tracks/` runbook updates are a follow-up.

## Risks / Open Items

None blocking the plan. Notes for the future:

- The `0x80040f07` failure status from `success != $SUCCESS_SIG` is
  empirically known to mean "UUID already exists." Other failure
  codes may surface as we use the protocol more (e.g., a too-large
  track might produce a different code). The writer should log the
  raw hex on any non-success status so we can build a vocabulary
  over time. Lives in memory if anywhere; **NOT** in
  `TRACK_writing.md` (spec is sacrosanct).
- The dual-role rule-table approach relies on the parser's existing
  `expect_trk` -> `is_track` -> `buffer_complete` state machine.
  Adding RECORD to `expect_trk` (done 2026-05-27) is the only
  modification. If future changes to the reader-side flow alter this
  state machine, the writer's correctness depends on the writer
  scenario continuing to compose cleanly. Worth a comment in
  `e_TRACK.pm::parseMessage` (already added).
- The harness `NET/docs/notes/example_write_track_bocas.pl` is the
  reference implementation for the wire-level behavior. The
  production `d_TRACK_writer.pm` should produce byte-identical wire
  output for the same input; the harness can serve as a regression
  reference if anything looks off.

## Implementation Sequence

Suggested commit / PR cadence:

1. Phase 1 (encoders) -- standalone, can be tested via a unit-style
   script that calls them on the BOCAS1-001 fixture and compares
   byte-for-byte to the known-good wire output.
2. Phase 2 (d_TRACK_writer) -- depends on Phase 1. Verified by a
   minimal test driver that mimics the harness but uses the new
   class instead of inline code. End-to-end smoke: write a fresh
   track to E80, observe SAVED, observe auto-pickup in navMate.
3. Phase 3 (preflight) -- standalone; doesn't yet drive any UI.
   Tested by calling `_pasteTracksAllows` / `_pushTracksAllows` on
   hand-constructed item lists.
4. Phase 4 (execute layer) -- depends on Phases 2 and 3. Tested by
   calling `pasteTracks` / `pushTracks` from a test driver with
   `$progress` mocked. The hub-layer FSH -> E80 hookup lands here
   alongside the direct DB -> E80 path.
5. Phase 5 (UI / menu wiring) -- depends on Phase 4. This is the
   "user can do it" milestone, covering both PASTE/PASTE_NEW on the
   E80 tracks header AND PUSH on individual E80 track nodes AND the
   FSH -> E80 cross-spoke drop gesture.

Phases 1+2 are entirely in `NET/`; Phases 3-5 are entirely in
`apps/navMate/`. The two halves can be reviewed and possibly merged
separately if useful.
