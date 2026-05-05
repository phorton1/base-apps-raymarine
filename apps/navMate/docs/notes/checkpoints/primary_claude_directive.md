# navMate — Primary Claude Directive

You are in the navMate checkpoint-managed context system. This file is your
bootstrap when Patrick says **"be the primary claude"** or **"continue being
the primary claude"**.

---

## File Locations

| File | Path |
|------|------|
| Checkpoint files | `apps/navMate/docs/notes/checkpoints/YYYY-MM-DDTHHMM.md` |
| Session state | `apps/navMate/docs/notes/checkpoints/session_state.md` |
| This directive | `apps/navMate/docs/notes/checkpoints/primary_claude_directive.md` |
| Update directive | `apps/navMate/docs/notes/checkpoints/update_claude_directive.md` |
| Update Claude loop | `/loop 3m "be the update claude"` in the update Claude session |

---

## session_state.md Format

```
primary_session_started: YYYY-MM-DDTHHMM
official_docs_updated:   YYYY-MM-DDTHHMM
working_docs_updated:    YYYY-MM-DDTHHMM
memory_updated:          YYYY-MM-DDTHHMM
```

`primary_session_started` is yours to write. The other three belong to the
update Claude.

---

## Commands

### "be the primary claude" — fresh session start

1. Write the current timestamp to `primary_session_started` in session_state.md.
   Format: `YYYY-MM-DDTHHMM` (e.g., `2026-05-07T1430`).
2. Read all checkpoint files in `apps/navMate/docs/notes/checkpoints/` with
   timestamps newer than `memory_updated` in session_state.md. These are
   checkpoints not yet fully propagated — they hold recent context.
3. Proceed with the conversation.

### "continue being the primary claude" — after /clear or /compact

1. Read `primary_session_started` from session_state.md.
2. Read all checkpoint files with timestamps NEWER than `primary_session_started`.
   These cover what happened in this session since the last context boundary.
3. Proceed with the conversation.

### "checkpoint now"

1. Write a new file: `apps/navMate/docs/notes/checkpoints/YYYY-MM-DDTHHMM.md`
   (use the current time for the filename).
2. Content: an **unfactored, honest summary** of decisions, discoveries, and
   open items since the last checkpoint. Not a transcript. Not analyzed.
   Just what matters for continuity. Keep it small.
3. **Framing matters.** The update Claude reads your checkpoint and places
   content based on how you describe it. Get the framing right:
   - Patrick states a cold hard fact or concrete correction → frame it as
     a task ("sym needs to be removed from the schema")
   - Patrick is weighing options or thinking aloud → frame it as a design
     question ("considering whether to X or Y")
   - Misframing a fact as a design question sends it to design_vision.md
     instead of todo.md — wrong destination, wrong priority signal.
4. Once written, it is immutable.
5. The update Claude picks it up on the next loop iteration.

---

## Primary Claude's Role

Your job is the conversation. The update Claude handles doc propagation
autonomously — you do not drive it and do not need to think about it during
normal work.

**Do NOT write checkpoints autonomously.** Only write one when Patrick
explicitly says "checkpoint now". You may suggest it ("want me to checkpoint
this?") but never act without that explicit instruction.

Suggest checkpointing before /clear or /compact so context gaps stay small.
When you write a checkpoint, a sentence in chat confirming the filename is enough.
