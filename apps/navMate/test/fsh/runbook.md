# fsh Module -- Runbook (STUB)

**Status: STUB.** All tests record as `NOT_RUN (stub)` until winFSH operations land and this runbook is filled in. See [`plan.md`](plan.md) for intended scope.

For shared toolbox, see [`../master_runbook.md`](../master_runbook.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md).

---

## Baseline Setup

```powershell
git -C C:/dat/Rhapsody checkout -- navMate.db
curl.exe -s "http://localhost:9883/api/test?op=refresh" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+fsh+module+reset" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=clear_e80" | Out-Null
Start-Sleep 5
curl.exe -s "http://localhost:9883/api/test?op=load_fsh&path=C:/base/apps/raymarine/apps/navMate/test/_fixtures/test.fsh" | Out-Null
Start-Sleep 3
# Verify "navTest: load_fsh done path=..." in log; winFSH pane should now be open with the fixture
```

The baseline setup IS implemented and runnable. The module's per-test content is still stub; all tests below record as `NOT_RUN (stub)` until the test surface is enumerated.

---

## Module Tests (placeholders)

### Test fsh.1 -- Upload WP from DB to FSH (TBD)

`NOT_RUN (stub)` -- requires winFSH PASTE wiring.

---

### Test fsh.2 -- Upload Group from DB to FSH (TBD)

`NOT_RUN (stub)` -- requires winFSH PASTE wiring.

---

### Test fsh.3 -- Upload Route from DB to FSH (TBD)

`NOT_RUN (stub)` -- requires winFSH PASTE wiring + member-WP pre-flight semantics for FSH.

---

### Test fsh.4 -- Download FSH WP to DB (TBD)

`NOT_RUN (stub)` -- requires winFSH COPY wiring.

---

### Test fsh.5 -- FSH-side header-node delete (TBD)

`NOT_RUN (stub)` -- requires winFSH delete wiring.

---

### Test fsh.G.* -- DB-FSH guards (TBD)

`NOT_RUN (stub)` -- pre-flight guards for DB <-> FSH paste paths. To be enumerated when the spoke is wired and the per-test guard surface is known.

---

End of fsh module stub.
