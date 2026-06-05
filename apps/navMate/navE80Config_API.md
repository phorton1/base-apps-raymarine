# navE80Config -- Configuration Backup / Restore API

[navE80Config](navE80Config.pm) is a navMate-side Perl library that backs up and
restores an E80 chartplotter's display **configuration gestalt** -- the complete
set of user-visible layout and panel settings -- over the unit's diagnostic
network channel. It exposes three synchronous operations -- **save**, **clear**,
and **restore** -- each driving a live E80 by IP address and reporting progress
through a caller-supplied shared hash.

This document is the client-facing API: how to call the library, the contract of
the progress object, the on-disk backup format, and the manifest schema. It does
not cover the wire-protocol internals.

## What it captures: the three configuration layers

A complete E80 screen configuration is three independent layers, and a faithful
backup needs all three:

1. **Page sets** -- the five top-level screen layouts (Navigation, Situational
   Awareness, Boat Systems, Fishing, Custom): which application occupies which
   window on each page, and which page set is currently active. Held as one
   consolidated file on the unit.
2. **Panelsets** -- the instrument-panel definitions for the Data, Engine, and
   CDI applications: the cell grid of each panel and what each cell displays. Held
   as keyed records.
3. **Per-window selectors** -- for each instrument window, the one-byte index
   choosing which panel that window currently shows.

All three are required to reproduce a screen: page sets written without the
selectors come up with every instrument window defaulted.

## Requirements

- Perl with `threads`, `threads::shared`, `IO::Socket::INET`, and the `Pub::Utils`
  module (the library imports `display`, `error`, `warning`, and `my_mkdir` from
  it).
- IP reachability to the E80.
- The host must be able to receive the unit's UDP replies on the library's reply
  port; if a host firewall is present, that inbound port must be permitted.
- For **restore**, the target unit's keyed store must have settled (its own
  records present). In practice, wait a minute or two after a factory reset before
  restoring.

## Loading and calling

The library **exports** its three entry points (`saveE80Config`, `clearE80Config`,
`restoreE80Config`) via `Exporter`, so `use navE80Config;` imports them into the
caller's namespace -- call them unqualified:

```perl
use lib '/path/to/cleanroom';
use navE80Config;

my $ok = saveE80Config($ip, $folder, $progress);
```

All three entry points are **synchronous and blocking**. `clear` and `restore`
take tens of seconds -- they read the unit, apply the changes, and reboot it. They
return as soon as the reboot is triggered; they do not wait for the unit to come
back. Run the call in a worker thread if the caller needs to keep a UI responsive
while reading progress from another thread (below).

## API

### saveE80Config($ip, $folder, $progress) -> 1 | 0

Read-only. Captures the full gestalt off the live unit at `$ip` into the directory
`$folder` (created if absent). Does **not** modify the unit. Returns 1 on success,
0 on failure (reason in `$progress->{error}`).

### clearE80Config($ip, $progress) -> 1 | 0

Resets the unit's display configuration to factory defaults and reboots it so the
result is visible:

- restores the factory-default page sets,
- deletes the unit's instrument panelsets (the applications re-create defaults at
  boot),
- resets every per-window selector to the default panel,
- reboots the unit so the reset takes effect (the unit comes up showing its boot
  disclaimer, which you dismiss by hand).

Returns 1/0. (Takes no `$folder` -- `clear` needs no backup.)

### restoreE80Config($ip, $folder, $progress) -> 1 | 0

Restores a previously saved gestalt folder onto the unit at `$ip`: it first clears
the unit, then overlays the saved page sets, panelsets, and selectors, then does a
**single** reboot so the unit adopts everything at once. Panelsets are written at
automatically-chosen safe keys -- the source unit's keys are never reused. Returns
1/0.

All writes take effect at the unit's next boot; `clear` and `restore` perform that
boot for you. Restore creates any missing slot directories and files on the unit, so
all three layers -- page sets, panelsets, and per-window selectors -- are reproduced
in a single reboot.

## The progress object

Every entry point takes a `$progress` -- a `threads::shared` hash the caller
creates and the library **only mutates** (it never replaces the hash). This is the
same contract a wx progress dialog would provide: the caller initializes it and
reads it (typically from another thread) to drive a progress bar, while the
library writes to it as work proceeds.

| Field       | Written by | Meaning |
|-------------|------------|---------|
| `active`    | caller     | set to 1; the operation is running |
| `total`     | library    | total work units; **grows** as the library discovers more to do |
| `done`      | library    | work units completed so far |
| `label`     | library    | current phase text (e.g. `"Reading page sets"`) |
| `cancelled` | caller     | set to 1 to request cancellation; the library checks it and aborts cleanly |
| `error`     | library    | failure reason (set when an entry point returns 0) |

Initialize it before the call:

```perl
my $progress = &threads::shared::share({});
$progress->{active}    = 1;
$progress->{total}     = 0;
$progress->{done}      = 0;
$progress->{cancelled} = 0;
$progress->{error}     = '';
$progress->{label}     = '';
```

**Progress semantics.** The library seeds `total` with the static work it knows up
front, then **increases `total`** once it has enumerated the unit, and increments
`done` per unit of work. A bar computed as `done / total` therefore only ever
moves forward (it never freezes while a phase runs, and never jumps backward). To
cancel, set `$progress->{cancelled} = 1`; the library aborts at the next
checkpoint and returns 0 with `error` = `"cancelled"`.

## The backup folder format

A saved gestalt is a flat directory of small text files plus a JSON manifest.
Every data file is a **single line of lowercase hexadecimal** encoding the raw
bytes (no whitespace, no `0x` prefix).

| File | Layer | Contents |
|------|-------|----------|
| `e80Config.json` | -- | the index / metadata (schema below) |
| `pageset0.txt` .. `pageset4.txt` | 1 | the five 600-byte page-set blocks, in order |
| `pagesets.meta.hex` | 1 | the bytes around the blocks (the header with the active-set index, plus any tail) |
| `panelset_<class>.txt` | 2 | one instrument panelset, body only; `<class>` is `data`, `engine`, `cdi`, or `unknown` |
| `pageset<ps>_page<pg>_window<win>.txt` | 3 | one 1-byte per-window selector |

Notes:

- If a unit holds more than one panelset of the same class, the extras are
  suffixed `panelset_<class>_2.txt`, `_3.txt`, and so on.
- The page-set layer round-trips as the original consolidated file:
  `pagesets.meta.hex` (head) + `pageset0..4.txt` + `pagesets.meta.hex` (tail).
- File names carry no device identity; the only identity (owner id, machine name)
  lives in the manifest.

## e80Config.json schema

JSON. The top-level object:

| Field | Type | Meaning |
|-------|------|---------|
| `tool` | string | always `"navE80Config"` |
| `format_version` | integer | currently `1` |
| `machine_name` | string | friendly unit name if known, else `""` |
| `owner_id` | string | the unit's 8-hex-digit owner id (e.g. `"b280ad37"`) |
| `device_ip` | string | the IP the backup was taken from |
| `captured` | string | ISO-8601 UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`) |
| `page_sets` | array | one entry per page set (below) |
| `panelsets` | array | one entry per captured panelset (below) |
| `selectors` | array | one entry per captured per-window selector (below) |

`page_sets[]`:

| Field | Type | Meaning |
|-------|------|---------|
| `index` | integer | 0..4 (0 = Navigation .. 4 = Custom) |
| `name` | string | the page-set name as stored on the unit |
| `id` | integer | the page-set id field |

`panelsets[]`:

| Field | Type | Meaning |
|-------|------|---------|
| `class` | string | `data` / `engine` / `cdi` / `unknown` |
| `file` | string | the `panelset_*.txt` file holding the body |
| `type` | string | the high 16 bits of the source record key, hex (e.g. `"0x0042"`) |
| `key3` | string | the low 16 bits of the source record key, hex |
| `len` | integer | record body length, in bytes |

`selectors[]`:

| Field | Type | Meaning |
|-------|------|---------|
| `pageset` | integer | page-set index |
| `page` | integer | page index within the page set |
| `window` | integer | window index within the page |
| `value` | integer | the selected panel index |
| `file` | string | the selector file |

Example (values illustrative):

```json
{
  "tool": "navE80Config",
  "format_version": 1,
  "machine_name": "E80-2",
  "owner_id": "b280ad37",
  "device_ip": "10.0.240.83",
  "captured": "2026-06-04T20:33:51Z",
  "page_sets": [
    { "index": 0, "name": "Navigation", "id": 0 },
    { "index": 1, "name": "Situational Awareness", "id": 1 },
    { "index": 2, "name": "Boat Systems", "id": 2 },
    { "index": 3, "name": "Fishing", "id": 3 },
    { "index": 4, "name": "Custom", "id": 4 }
  ],
  "panelsets": [
    { "class": "data", "file": "panelset_data.txt",
      "type": "0x0042", "key3": "0x999e", "len": 1864 }
  ],
  "selectors": [
    { "pageset": 4, "page": 2, "window": 1, "value": 4,
      "file": "pageset4_page2_window1.txt" }
  ]
}
```

The `type` / `key3` recorded for a panelset are informational only -- they are the
key the record happened to occupy on the source unit. On restore the library
allocates fresh, safe keys on the target; it does not reuse these.

## Behavior and guarantees

- **Writes apply at boot.** The E80 reads its configuration once, at startup, so a
  change takes effect on the next power cycle. `clear` and `restore` perform that
  reboot for you; `save` never reboots. After the reboot the unit comes up showing
  its boot disclaimer, which you dismiss by hand.
- **Config-idempotent.** Running `clear` twice lands the same factory state;
  restoring the same folder twice lands the same configuration. (The underlying
  storage is append-and-supersede, so each run consumes new internal keys, but the
  resulting configuration is identical.)
- **Cross-unit.** A panelset is device-agnostic; restoring a folder captured on
  one unit onto another reproduces the panels (the library re-keys them under the
  target unit's owner). The page-set layer is likewise generic.

## Known limitations

- **Save can over-capture panelsets.** A healthy unit may hold more panelset
  records than the user's own customizations, because applications mint default
  panelsets as their windows are first shown. `save` records all of them; on
  `restore` they are all written and the unit adopts the appropriate one per class.
