primary_session_started: 2026-05-08T1120
official_docs_updated:   2026-05-08T0804
working_docs_updated:    2026-05-08T0804
memory_updated:          2026-05-08T0804

checkpoint: 2026-05-07T1630
    nmOperations.md fully restructured (13 sections); pre-flight as central engine;
    vocabulary section; route-points-only E80 paste-before/after; versioning SS12.4;
    name collision steps; recursive paste check; all deferred language removed

checkpoint: 2026-05-07T1704
    nmOps runbook written; all UUIDs resolved from live /api/nmdb;
    navmate_db_structure.md UUIDs confirmed stale; [DST] changed (Navigation/test gone);
    [SafeBranch] changed to Before Sumwood Channel; §2.4/§2.5 Bocas conflict documented;
    alpha test run imminent

checkpoint: 2026-05-07T1800
    nmOps_testplan.md written (40+ tests, §2-§5); todo item #3 marked done; todo item #4
    expanded to 6 concrete API/code prerequisites; unified COPY/CUT constants documented;
    PASTE_BEFORE/AFTER as first-class tests; header-node deletes; suppress outcome gap identified

checkpoint: 2026-05-07T1830
    PRE-CLEAR: full implementation bootstrap; $suppress_error_dialog added to todo #4
    (showError modal via app frame override); 7 testability prerequisites enumerated;
    what exists vs. what to build; key invariants and behavioral rules summarized for next session

checkpoint: 2026-05-07T2000
    a_defs.pm done (20 CTX_CMD constants); nmClipboard.pm written; nmOps.pm fully spec'd
    in checkpoint; ready for next session to implement nmOps.pm

checkpoint: 2026-05-07T2130
    step 3 DONE: nmOps.pm written (buildContextMenu, onContextMenuCommand, full 7-step
    pre-flight in _doPaste, snapshot system for DB+E80, _doNew inline dialogs for
    branch/group, color helpers, _cmdLabel); nmOpsDB.pm and nmOpsE80.pm stubs written;
    next: step 4 nmOpsDB.pm

checkpoint: 2026-05-07T2200
    step 4 DONE: nmOpsDB.pm fully implemented (_deleteDB dispatch,
    _pasteDB+_pasteItemsToCollection recursive, _newDatabaseWaypoint/Route, conflict
    dialog, cut helpers); E80 cut stubs added to nmOpsE80.pm; next: step 5 nmOpsE80.pm

checkpoint: 2026-05-07T2330
    steps 8+9 DONE: winDatabase+winE80 wired to nmOps (EVT_MENU_RANGE, _onNmOpsCmd,
    buildContextMenu); showError fix: moved to w_frame, Pub::Utils made polymorphic;
    winMain rebased to w_frame

checkpoint: 2026-05-07T2345
    navMate running; tests 1+2 PASS (single WP, Popa group to E80);
    $dbg_e80_ops uninitialized bug found+fixed; ring buffer limitation noted
    (Perl STDERR not captured)

checkpoint: 2026-05-08T0015
    manual sanity tests 1-3 complete; test 3 PASS_BUT; two minor E80 groups-header
    delete bugs documented in open_bugs.md; Patrick pleased; ready for runbook + testplan

checkpoint: 2026-05-08T0804
    nmOps_testplan.md fully rewritten as human-readable prose (no curls, no [Name] tokens);
    CTX_CMD_ prefix dropped to bare names in both testplan and runbook; §2.4 clarified to
    use a different group than §2.5; navMate restart still pending before test cycle

checkpoint: 2026-05-08T0834
    docs done, temp cleanup done, global filesystem safety rules committed to memory;
    ready to run test cycle; navMate restart required first

checkpoint: 2026-05-08T0905
    test cycle run: §1 PASS, §2.1-§2.12 all PASS, §2.13 FAIL (no route_uuid on plain WP
    anchor); runbook cmd= numeric fix applied; nmOpsDB.pm fixed (collection-member
    PASTE_BEFORE/AFTER now uses anchor WP position + midpoint insertion);
    Patrick has pending questions; navMate needs restart before re-run

checkpoint: 2026-05-08T1009
    PRE-CLEAR: three design questions answered with code fixes; PASTE_BEFORE/AFTER fully
    generalized (any anchor/item type, cross-table neighbor query); route_point cut cleanup
    fixed (removeRoutePoint not _cutDatabaseWaypoint); PASTE/PASTE_NEW suppressed on
    terminal nodes; PASTE non-NEW suppressed on route_point anchor with mixed clipboard;
    todo.md updated; must restart navMate and run from §1

checkpoint: 2026-05-08T1120
    PRE-CLEAR mid-test-cycle: §1+§2 fully PASS (all 17 steps); §3.0-§3.4 PASS,
    §3.1 PASSED_BUT; two nmOpsDB.pm fixes (two-step route_waypoints shift; route_point
    PASTE_NEW reuses wp_uuid); E80 state: route only (f34efdd6070022e8); resume at §3.5

checkpoint: 2026-05-08T1300
    Cycle 7 test run COMPLETE: §1+§2 ALL PASS; §3 PARTIAL (3 FAIL: §3.11 homogeneity,
    §3.14 route PASTE_NEW collision, §3.15 seq collision; 2 NOT_RUN: §3.8 tracks,
    §3.16 no route WPs); §4 NOT_RUN (teensyBoat); §5 PARTIAL (4 FAIL: §5.1 Popa0 deleted,
    §5.4 tracks guard, §5.6 route dep check, §5.9 recursive guard); 6 bugs documented in
    last_testrun.md; no code changes; awaiting Patrick review and fix authorization

checkpoint: 2026-05-08T1430
    PRE-CLEAR: §3.0c/§5.6 fixes applied (nmOpsE80.pm _pasteRouteToE80 rewritten +
    SS10.10 handler check; _pasteNewRouteToE80 key fix; both count fixes; buildContextMenu
    SS10.10 menu guard); design_vision.md [waypoint carrying route pasting] noted;
    5 bugs remain; navMate restart required before Cycle 8

checkpoint: 2026-05-08T1439
    design review complete; SS1.6+SS1.7+SS7.4+SS10.1Step4 added/strengthened;
    SS10.2 renumbered; SS12.1/SS12.3/SS12.5-12.8 corrected; §3.11 ordering concept
    retired; _pasteRouteToE80 members->route_points bug identified

checkpoint: 2026-05-08T1600
    PRE-CLEAR: gap analysis complete (C1-C6, I1, G1-G3); SS12.1 ordering scoped to
    E80-source only in design doc; checkpoint written for impl pass;
    session_state.md reformatted to multi-line checkpoint entries

checkpoint: 2026-05-08T1730
    impl pass DONE: all 7 gaps fixed (C1-C6, I1); Step 4 route dependency check
    added to _doPaste; SS10.10 guard extended to PASTE_NEW; ordering sort added to
    _pasteItemsToCollection; route branches in DB+E80 no longer create WPs (SS1.6);
    step labels renumbered 5-8 in E80 block; navMate restart required; Cycle 8 next
