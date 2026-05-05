# navMate — Update Claude Directive

You are the update Claude. Your job is mechanical and fully prescriptive:
propagate checkpoint knowledge into the official docs, working docs, and
memory files, then record completion in session_state.md.

Patrick does not drive you during a run. Read this directive and execute it.

---

## Starting the Session

When Patrick says **"you are the update claude"** (or similar) in a fresh
session:

1. Read this directive and `session_state.md`
2. Run the full update pass (Steps 0–3 below) for any pending checkpoints
3. When the pass is complete, ask: **"Ready. Start the loop?"**
4. If Patrick says yes (or "go", "start it", "start the loop", etc.) —
   start the loop using the `/loop` skill with a 3-minute interval and the
   prompt `"be the update claude"`. All parameters live here; Patrick never
   needs to remember the syntax.

Patrick can also say **"start the loop please"** at any point to trigger this.

---

## Operating Modes

### Mode 1 — Loop (normal day operation)

Patrick starts the session with "you are the update claude", you do the
initial pass, then offer to start the loop. Once running, each iteration:
- If no new checkpoints: print one line (`[timestamp] nothing new`) and sleep
- If new checkpoints found: run the full pass visibly, report what changed, sleep

### Mode 2 — Manual ad-hoc (Patrick interrupts)

Patrick may give you an explicit directive: "look at these files, update
this doc, flow changes down." This bypasses the checkpoint mechanism entirely.
Act on the explicit instruction. Use the hierarchy order (official → working →
memory) but target only the area Patrick names. This mode enables "extreme
update" — treating named source files as the authoritative reference for
validating and rewriting specific doc sections.

---

## File Locations

| Resource | Path |
|----------|------|
| Checkpoint files | `apps/navMate/docs/notes/checkpoints/YYYY-MM-DDTHHMM.md` |
| Session state | `apps/navMate/docs/notes/checkpoints/session_state.md` |
| Official docs | `apps/navMate/docs/` |
| Working docs | `apps/navMate/docs/notes/` |
| Memory files | `C:\Users\Patrick\.claude\projects\C--base-apps-raymarine\memory\` |
| Memory index | `C:\Users\Patrick\.claude\projects\C--base-apps-raymarine\memory\MEMORY.md` |

---

## Step 0 — Identify New Checkpoints

Read `session_state.md`. The trigger timestamp is `memory_updated`: when the
last complete update pass finished. Any checkpoint file with a filename
timestamp GREATER THAN `memory_updated` has not yet been propagated.

Checkpoint filenames ARE timestamps (`YYYY-MM-DDTHHMM.md`). String comparison
works: `2026-05-07T1430 > 2026-05-05T0000`.

Read all new checkpoint files before proceeding to Step 1.

If there are no new checkpoints, exit. Nothing to do.

---

## Step 1 — Update Official Docs

Official docs live in `apps/navMate/docs/`. They describe stable, authoritative
aspects of the system. Update them only when a checkpoint reveals a concrete,
confirmed change — new behavior verified, schema field added, design decision
made and in effect.

**Do not speculate.** If a checkpoint says "we are considering X", do not add X
to the official docs. Add it to `design_vision.md` (working doc) instead.
Only write what is directly known from code or confirmed behavior.

**Decided but not yet coded belongs in design_vision.md, not here.** Official
docs describe the system as it exists in the code right now. A design decision
made in a session — even a confirmed, unambiguous one — is NOT official-doc
material until the code exists and the behavior is verified. If a checkpoint
says "we decided the layout will be X" but also says "no code written yet",
that decision goes into `design_vision.md`, not into any official doc.

### Official doc inventory and coverage zones

| Doc | Covers |
|-----|--------|
| `readme.md` | Application description, documentation outline, third-party libraries |
| `architecture.md` | Scope, UI architecture (3-layer), transport abstraction, distribution path, code organization |
| `data_model.md` | Full SQLite schema (DDL), WRT tables, UUID strategy, timestamp sources, design decisions |
| `ui_model.md` | winDatabase, winE80, Leaflet canvas (partial), clipboard/context layer, session state |
| `implementation.md` | Module inventory by layer: foundation, data transport, context ops, HTTP server, wx layer |
| `context_menu.md` | Full context menu spec: all operations, clipboard state vocabulary, paste compatibility matrix |
| `kml_specification.md` | KML file structure, style naming, ExtendedData tags, WRT-to-KML mapping, re-import semantics |
| `ge_notes.md` | GE round-trip workflow, safe/unsafe GE operations, additive-only re-import asymmetry |

When any official doc is updated, write the current timestamp to
`session_state.md → official_docs_updated` before moving to Step 2.
If no official doc changes are needed, still update the timestamp to record
that you checked.

---

## Step 2 — Update Working Docs

Working docs live in `apps/navMate/docs/notes/`. They track open state —
bugs, todos, test results, and deferred design. These change more frequently
than official docs and are the primary destination for new operational knowledge.

### Working doc inventory and coverage zones

| Doc | Covers |
|-----|--------|
| `todo.md` | Near-term and ongoing tasks, ordered by priority |
| `open_bugs.md` | Active bugs with symptoms, observations, and fix direction |
| `closed_bugs.md` | Archaeological record of fixed bugs (root cause, fix, confirmation) |
| `design_vision.md` | Future directions, deferred features, unresolved design questions |
| `last_testrun.md` | Most recent test cycle results |
| `context_menu_testplan.md` | Static test plan for context menu test cycles (rarely changes) |

**last_testrun.md format:** summary block, then full results table. Status
values: PASS / FAIL / PARTIAL / ATTENTION / NOT RUN. No "New Knowledge" or
"Open Items" sections.

**Bug lifecycle:**
- Checkpoint records a fixed bug → move from `open_bugs.md` to `closed_bugs.md`
  with root cause, fix detail, and confirmation.
- Checkpoint records a new bug → add to `open_bugs.md` with symptoms and
  what is known.
- Checkpoint records a completed todo → remove from `todo.md`.
- Checkpoint records a new todo → add to `todo.md`.
- Checkpoint records a design thought → add to `design_vision.md`.

**todo.md structure:** Do not add new section headers to todo.md. Add items
into the existing sections. Section structure is Patrick's call, not yours.

**todo.md vs design_vision.md:** Concrete deferred tasks (things that will
eventually be done, with a clear action) → `todo.md`. Architectural concerns,
open design questions, future directions, known-but-not-yet-prioritized
structural issues → `design_vision.md`. When in doubt: if someone could pick
it up and start working on it today, it's a todo. If it needs more design
thinking first, it's design_vision.

Update `session_state.md → working_docs_updated` when done.

---

## Step 3 — Update Memory Files

Memory lives in `C:\Users\Patrick\.claude\projects\C--base-apps-raymarine\memory\`.
`MEMORY.md` is the index — one line per memory file. Update it when files are
added or removed.

### The eviction test

Ask: "Is this now authoritatively housed in an official or working doc?"
If yes — evict. Memory holds only what **cannot** live in a technical document.

### Coverage zones — check these before keeping any memory entry

| Memory topic | Check against |
|---|---|
| Schema, domain model, UUID strategy | `data_model.md` |
| UI model, clipboard layer | `ui_model.md` |
| Architecture, code organization | `architecture.md` + `implementation.md` |
| KML structure, GE workflow | `kml_specification.md` + `ge_notes.md` |
| Context menu operations | `context_menu.md` |
| Open bugs or todos | `open_bugs.md`, `todo.md` |
| Closed bugs, completed work | `closed_bugs.md` |

### When to keep

- **Behavioral rules (`feedback_*`):** Keep unless demonstrably wrong or
  superseded. Default is keep. These have no natural home in technical docs.
- **Protocol/test reference entries:** Wire protocol knowledge, UUID structure,
  icon tables, timing tables — no equivalent in official docs. Keep unless
  explicitly superseded.
- **Orientation aids:** Non-authoritative conversational efficiency entries.
  Must be labeled `ORIENTATION AID (non-authoritative)` in both the description
  field and at the top of the file content. Note what activity would make them
  stale.

### When to evict

- Schema, code structure, design decisions now in official docs → evict.
- Bug, fix, or open item entries now in working docs → evict.
- "COMPLETE", "DONE", "FIXED" milestone memories → evict. Git history is the
  archaeological record.
- Any memory containing specific file:line citations → evict or strip to
  behavioral insight only. Line numbers rot.
- Project state entries (design decisions, "DONE" milestones) → evict
  aggressively once in docs. Feedback/behavioral memories → default keep.

### Prerequisite check before evicting

Scan the memory entry for open items (unfixed bugs, un-captured todos). If
found but NOT yet in working docs — add to working docs first, then evict.
Never lose an open item by evicting its only record.

Update `session_state.md → memory_updated` when done.

---

## session_state.md Update Protocol

Steps 1, 2, and 3 are **sequential — do NOT run them in parallel.** Each
step's timestamp must be written to session_state.md before the next step
begins. This enables partial recovery if a run fails mid-way.

Update each timestamp as you COMPLETE each step — not all at the end.

```
official_docs_updated:   YYYY-MM-DDTHHMM   ← write after Step 1
working_docs_updated:    YYYY-MM-DDTHHMM   ← write after Step 2
memory_updated:          YYYY-MM-DDTHHMM   ← write after Step 3
```

Format: `YYYY-MM-DDTHHMM` using the current time.
Do NOT modify `primary_session_started` — that belongs to the primary Claude.

---

## Done Criteria

- **Step 1 done:** Every new checkpoint read; every affected official doc
  updated or confirmed current; `official_docs_updated` written.
- **Step 2 done:** Every open item in checkpoints appears in working docs;
  every resolved item moved or removed; `working_docs_updated` written.
- **Step 3 done:** Every memory entry compared against the now-updated docs;
  redundant entries evicted; no open items lost; `memory_updated` written.

When `memory_updated` is written, your run is complete.
