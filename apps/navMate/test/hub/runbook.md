# hub Module -- Runbook (STUB)

**Status: STUB.** All tests record as `NOT_RUN (stub)` until three-panel flows are wired and this runbook is filled in. See [`plan.md`](plan.md) for intended scope.

For shared toolbox, see [`../master_runbook.md`](../master_runbook.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md).

---

## Baseline Setup

Order matters: `op=suppress&val=1` MUST precede `op=load_fsh` -- the in-memory FSH may be dirty (from interactive work or a prior module run) and would otherwise raise a `discard/save/save-as/cancel` confirm dialog. Suppress auto-discards. See `../master_runbook.md` *Suppress ordering*.

```powershell
git -C C:/dat/Rhapsody checkout -- navMate.db
curl.exe -s "http://localhost:9883/api/test?op=refresh" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+hub+module+reset" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=clear_e80" | Out-Null
Start-Sleep 5
curl.exe -s "http://localhost:9883/api/test?op=load_fsh&path=C:/base/apps/raymarine/apps/navMate/test/_fixtures/test.fsh" | Out-Null
Start-Sleep 3

# Plus module-specific E80-side population (to be defined when tests are added)
```

The hub module depends on the fsh module being solid (FSH spoke wired) for real test content. The baseline IS runnable, but tests below record as `NOT_RUN (stub)` until the three-panel flow surface is wired.

---

## Module Tests (placeholders)

### Test hub.1 -- E80 -> FSH cross-spoke COPY/PASTE (TBD)

`NOT_RUN (stub)` -- requires both E80 and FSH spokes solid and the cross-spoke COPY/PASTE path wired.

---

### Test hub.2 -- FSH -> E80 cross-spoke COPY/PASTE (TBD)

`NOT_RUN (stub)` -- reverse direction of hub.1.

---

### Test hub.3 -- Multi-spoke COPY (E80 + FSH items in same clipboard) (TBD)

`NOT_RUN (stub)` -- exercises the multi-spoke clipboard semantics question (see plan.md Open Design Questions).

---

### Test hub.4 -- E80 -> FSH -> E80 round-trip identity (TBD)

`NOT_RUN (stub)` -- verifies round-trip preservation of fields through the hub. Lossy fields, if any, are identified during the test.

---

### Test hub.G.* -- Hub-mediated guards (TBD)

`NOT_RUN (stub)` -- guards that fire because the operation passes through navMate (e.g. multi-spoke UUID conflict, multi-spoke name collision). To be enumerated when the hub flow surface is known.

---

End of hub module stub.
