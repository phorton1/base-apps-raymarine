# navMate - E80Config

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)** --
**[navOperations](navOperations.md)** --
**[Spoke Contract](navOps_spoke_contract.md)** --
**[KML Specification](kml_specification.md)** --
**[GE Notes](ge_notes.md)** --
**[Testing](testing.md)** --
**[winFSH](winFSH.md)** --
**[winMultiEditor](winMultiEditor.md)** --
**E80Config**

Folders: **[Raymarine](../../../docs/readme.md)** --
**[NET](../../../NET/docs/readme.md)** --
**[FSH](../../../FSH/docs/readme.md)** --
**[CSV](../../../CSV/docs/readme.md)** --
**[shark](../../../apps/shark/docs/shark.md)** --
**[navMate](readme.md)**

## Purpose

E80Config adds **save**, **restore**, and **clear** of an E80 chartplotter's
display configuration to navMate. A configuration -- the page-set layout, the
instrument panelsets, and the per-window panel selectors that together make up
an E80 screen -- is captured to, and restored from, a navMate-managed folder.

The on-device work is performed by the **e80Config** library; this document
covers the navMate-side user interface and implementation that wrap it. navMate
is the mariner's primary user-level surface for the E80, so configuration
management belongs here alongside the waypoint, route, and track operations,
even though it is device maintenance rather than navigation-data management.

## The Configuration abstraction

A **configuration is a folder**, treated by navMate as an opaque single unit.
The folder holds several files -- the page-set blocks, the panelset bodies, the
per-window selectors, and a manifest -- but navMate neither parses nor assembles
them; that is the library's contract. The folder is the currency of every
operation. The folder's internal format is documented in the library API (see
[The e80Config library](#the-e80config-library) below).

### Identifying a configuration folder

Two tiers, used at different moments:

- **Practical** -- the presence of the manifest, `e80Config.json`. A successful
  save writes it **last**, so its presence marks a *complete* configuration; an
  interrupted save leaves the data files but no manifest.
- **Formal** -- that same `e80Config.json` parses and is valid: its `tool` field
  is `e80Config` and its `format_version` is supported.

The two tiers share one file: practical is "the manifest exists," formal is "the
manifest is well-formed and ours." The only gap between them is a present-but-corrupt
manifest.

Validation runs **on the action**, not during folder selection -- the folder
dialog is a plain `wxDirDialog` and does not filter what it shows.

### Folder rules

- **Restore** requires **formal** validation of the source folder. An invalid
  folder is refused.
- **Save** requires an **empty** destination:
  - An empty (or newly created) folder proceeds.
  - A non-empty folder that is **not** a configuration is refused outright.
  - A non-empty folder that **is** a configuration (formal validation) may be
    overwritten only after a strong confirmation, after which **navMate clears
    the folder** before invoking the save.

  The empty rule is load-bearing: save writes a *variable* set of files, so any
  stale file left from a previous, different capture would survive and leave the
  folder inconsistent with its own manifest -- corrupting the unit. Clearing
  before save guarantees the folder matches what the manifest describes.

## User Interface

### Menu

The three operations live under the existing **E80** menu, set off by a
separator:

| Command constant             | Action                  |
|------------------------------|-------------------------|
| `$COMMAND_SAVE_E80_CONFIG`    | Save Configuration      |
| `$COMMAND_RESTORE_E80_CONFIG` | Restore Configuration   |
| `$COMMAND_CLEAR_E80_CONFIG`   | Clear Configuration     |

The items are enabled only when at least one E80 is reachable (see Device
selection); with none present they are greyed. Enable state is recomputed when
the E80 menu is opened.

### Device selection

The target E80 is chosen from the units advertising the RAYDP **FILESYS**
service. Every E80 on the LAN advertises FILESYS -- only some advertise other
services -- so it is the reliable basis for discovery, the same source
`winFILESYS` uses.

- **0 units** -- the menu items are disabled.
- **1 unit** -- that unit is used directly; no chooser is shown.
- **2 or more** -- a chooser (modeled on `winFILESYS`) selects the target.

A unit's identity is its colloquial name from `%KNOWN_SERVER_IPS`
(`NET/a_defs.pm`), looked up by IP; a unit not in that table is identified by
its RAYDP id in parentheses.

### Folder selection

Configurations are kept in a library folder -- by convention
`/dat/Rhapsody/E80Configs`, under the same git control as the navMate database.
That folder is the starting location for the directory dialog (a plain
`wxDirDialog`), remembered as a session preference; the user may navigate
elsewhere. Save chooses or creates a destination folder; Restore chooses a
source folder; Clear uses no folder.

### Operation flow (interactive)

1. Determine the FILESYS units (drives menu enable).
2. Select the target -- automatic for one unit, chooser for several.
3. Folder dialog (Save and Restore only).
4. Validation and confirmation:
   - **Save** -- empty destination proceeds; non-empty non-configuration is
     refused; non-empty configuration requires a strong overwrite confirmation,
     after which navMate clears it before saving.
   - **Restore** -- the source folder is formally validated; an invalid folder
     is refused.
   - **Clear** -- a destructive-action confirmation, since it resets the unit
     and reboots it.
5. The operation runs on a worker thread behind a progress dialog.
6. On success, a confirmation dialog is shown.

### Progress and completion

All three run behind a `Pub::WX::ProgressDialog` driven by the library's shared
progress object. The dialog shows the current phase and a bar that only advances.
Clear and restore apply their changes and trigger a **single reboot as the final
step, returning immediately** -- the library does not wait for the unit to come
back, and does not auto-dismiss the boot disclaimer; the user presses OK on the
unit by hand. So the progress dialog completes promptly while the unit reboots in
the background. The **Cancel** button requests cancellation, which the library
honors at its checkpoints (once the reboot has been triggered the operation is
essentially done).

On failure or cancellation the dialog itself shows the terminal message. On
success a separate confirmation dialog is shown.

### Confirmation messages

On success a confirmation reports the operation, the configuration, and the
unit(s):

| Operation | Message                                                         |
|-----------|-----------------------------------------------------------------|
| Save      | `Configuration '<folder>' (<source-id>) saved to <folder-path>` |
| Restore   | `Configuration '<folder>' (<source-id>) restored to <target-id>`|
| Clear     | `Configuration cleared on <target-id>`                          |

`<folder>` is the configuration's folder name and `<folder-path>` its full path.
`<source-id>` and `<target-id>` are device identities in the colloquial-or-RAYDP
form above. For save, the source is the live unit captured from. For restore,
the source is the unit recorded in the configuration's manifest, which may
differ from the target when restoring a configuration across units.

(The save trailing path, the omission of the raw IP from the identity, and the
menu order are provisional and easily adjusted.)

### Dialog suppression

All E80Config dialogs -- the overwrite and clear confirmations and the success
confirmation -- honor `$nmDialogs::suppress_confirm`. When suppression is set
(as it is for headless operation), the dialogs are not shown and the equivalent
text is logged; the success message is returned in the HTTP response instead.

## navMate Implementation

### Loading the library

navMate loads the library with `use e80Config;`, which exports
`saveE80Config`, `clearE80Config`, and `restoreE80Config`. Each is synchronous,
blocking, and self-contained: it opens its own UDP diagnostic session to the
unit and returns 1 on success or 0 on failure (the reason left on the progress
object). The module is Wx-agnostic and shares only its progress object.

### Worker thread and progress object

Because the library is blocking (each call reads and/or writes the whole gestalt
over UDP) and Wx-agnostic, each operation runs on a **dedicated worker thread** while the main
thread services the progress dialog. The split is clean: the main thread owns
all Wx; the worker owns the UDP socket (created and closed within the worker);
the shared progress object is the only channel between them.

The progress object is created by
`Pub::WX::ProgressDialog::newProgressData($total, 1)` -- the `workers = 1` form.
Completion is then signaled by the worker (`workers` reaching 0 when the call
returns), not by `done` reaching `total`. This matters because the library
grows its total as it discovers work; tying completion to the worker avoids
closing the dialog early when `done` momentarily meets a not-yet-grown `total`.

A single wrapper opens the dialog and spawns the worker:

- guard against a second concurrent dialog (`Pub::WX::ProgressDialog::isActive`);
- create the progress object (`workers = 1`), set `active = 1`;
- open the `ProgressDialog` (with a Cancel button);
- spawn a detached worker that calls the entry point and, on return, sets
  `workers = 0`.

On failure the library has already set the `error` field, which the dialog turns
into its terminal state; on success `workers = 0` lets the dialog close cleanly.

### Success-confirmation timing

The success is known on the worker thread, but the confirmation dialog must run
on the **main** thread -- and must not be raised from inside the progress
dialog's idle handler, where a modal can block the idle loop. The message is
therefore composed up front on the main thread (folder, source, and target are
all known before the worker starts), and a one-shot main-thread check raises it
only after the progress dialog has fully closed and only when the operation
finished without error or cancellation.

### Device naming

Device identity is resolved by IP through `%KNOWN_SERVER_IPS` in
`NET/a_defs.pm`; an unknown IP falls back to the unit's RAYDP id, shown in
parentheses.

### Two entry paths, one core

The same operation core is reached two ways:

- **Interactively**, the menu path gathers the target IP and folder through the
  device and directory dialogs.
- **Headlessly**, an HTTP endpoint supplies the IP and folder directly.

The headless path forces suppression (no modal can block the server thread) and
is intended for ad-hoc and scripted operation. This feature carries **no
automated test plan**; all testing is manual or ad-hoc, driven through the menu
or the endpoint.

### HTTP endpoint

A new endpoint is added to `navServer.pm`'s dispatch chain:

    /api/e80config?op=save|restore|clear&ip=<addr>&folder=<path>

(`folder` is omitted for `clear`). It returns
`{ ok: 1, message: '<the success message>' }` on success or
`{ error: '<reason>' }` on failure. The `op=suppress` mechanism already in
`/api/test` is the model for forcing dialog suppression.

## The e80Config library

The on-device work -- capturing, clearing, and restoring the three
configuration layers over the E80's diagnostic channel -- is performed entirely
by the e80Config library. navMate treats its three entry points as opaque and
depends on neither the wire protocol nor the folder's internal byte layout.

- Module: [e80Config.pm](../e80Config.pm)
- Client API, folder format, manifest schema, progress contract, and known
  limitations: [e80Config_API.md](../e80Config_API.md)

The library is firmware-version-specific and self-contained; this document is
the navMate layer above it.
