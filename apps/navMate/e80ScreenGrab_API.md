# e80ScreenGrab -- Screen Capture API

[e80ScreenGrab](e80ScreenGrab.pm) is a navMate-side Perl library that captures
an E80 chartplotter's **live display** over the unit's diagnostic network
channel and hands it back as a PNG file or an in-memory true-color image. It
exposes a single synchronous capture, in three forms -- write a PNG
(`grabE80Screen`), return the pixels in memory (`grabE80ScreenImage`), and
encode an in-memory image to PNG bytes (`encodeE80Png`) -- each driving a live
E80 by IP address.

This document is the client-facing API: how to call the library, the contract
of the in-memory image, the progress object, and the behavior guarantees. It
does not cover the wire-protocol internals or the device-side capture mechanism.

## What it captures

A single capture is the **complete composited screen** -- every visible display
layer (chart / raster, instrument panels, UI chrome, and video) flattened into
one true-color image, exactly as it appears on the unit's panel at the instant
of capture. The unit's screen is 640 x 480; a capture is a faithful 640 x 480
true-color snapshot of what is on the glass.

The capture is **read-only**: it never modifies the unit, writes no
configuration, and does not reboot. It is the screen-side analogue of
[e80Config](e80Config_API.md)'s `save`.

## Requirements

- Perl with `IO::Socket::INET`, `Compress::Zlib`, and the `Pub::Utils` module
  (the library imports `display`, `error`, `warning`, and `my_mkdir` from it).
  `threads` / `threads::shared` are needed only if you pass a shared `$progress`
  hash (below).
- IP reachability to the E80.
- The target E80 must expose the **bulk screen-capture diagnostic service**
  (added by the project's mod002 firmware build). Pointed at a unit without it,
  the capture fails cleanly (returns false / `undef`).
- No inbound reply port or host-firewall rule is required: unlike the UDP
  configuration channel, a capture rides a single outbound TCP connection.

## Loading and calling

The library **exports** its three entry points (`grabE80Screen`,
`grabE80ScreenImage`, `encodeE80Png`) via `Exporter`, so `use e80ScreenGrab;`
imports them into the caller's namespace -- call them unqualified:

```perl
use lib '/path/to/cleanroom';
use e80ScreenGrab;

# Simplest form: capture the unit at $ip straight to a PNG file.
my $ok = grabE80Screen('10.0.240.83', 'C:/grabs/screen.png');

# In-memory form: get the pixels to hand to another encoder, a wx bitmap, etc.
my $image = grabE80ScreenImage('10.0.240.83');
# ... feed $image->{pixels} (rgb24) to your own GD/Imager for a JPG, display it,
#     or diff two captures. Then, if you want PNG bytes without a temp file:
my $png_bytes = encodeE80Png($image);
```

All three entry points are **synchronous and blocking**. A capture typically
completes in well under a second, up to roughly 1.5 s on a busy unit, and is
bounded by internal timeouts so a powered-off or rebooting unit fails rather
than hanging. The call momentarily blocks its thread; run it in a worker thread
if the caller needs to keep a UI responsive while reading progress from another
thread (below).

## API

### grabE80Screen($ip, $png_path [, $progress]) -> 1 | 0

Captures the live screen of the unit at `$ip` and writes it as a PNG to
`$png_path`. Read-only -- does **not** modify the unit. Returns 1 on success, 0
on failure (reason via `error()` and, if a `$progress` is supplied, in
`$progress->{error}`).

Path handling:

- If `$png_path` does not already end in `.png` (case-insensitive), `.png` is
  appended.
- Any missing parent directories are created (`Pub::Utils::my_mkdir`).
- An existing file at the path is **overwritten**.

### grabE80ScreenImage($ip [, $progress]) -> $image | undef

Captures the live screen and returns it as an in-memory true-color **`$image`**
(structure below) instead of writing a file. Read-only. Use it to hand the
pixels to another encoder (for example, a JPG via GD or Imager), display them in
a wx bitmap, or diff two captures. Returns `undef` on failure.

### encodeE80Png($image) -> $png_bytes | undef

Encodes an `$image` (as returned by `grabE80ScreenImage`) into a PNG byte string
in memory, without touching the filesystem. Pure and local -- it performs **no**
device access. Useful to deliver a PNG over a socket or into a `wxBitmap`
without a temp file. Returns `undef` on malformed input.

(`grabE80Screen($ip, $path)` is exactly `grabE80ScreenImage($ip)` followed by
`encodeE80Png` and a file write -- the three entry points are the same pipeline
exposed at three useful seams.)

## The $image structure

The in-memory image returned by `grabE80ScreenImage` and consumed by
`encodeE80Png`. It is format-agnostic raw pixels plus dimensions -- it carries
no device-specific detail:

| Field | Type | Meaning |
|-------|------|---------|
| `width` | integer | image width in pixels (the unit's screen width, 640) |
| `height` | integer | image height in pixels (480) |
| `format` | string | pixel layout; currently always `'rgb24'` |
| `pixels` | string | exactly `width * height * 3` bytes (the pixel data) |

`'rgb24'` layout: three bytes per pixel in **R, G, B** order, row-major,
top-to-bottom, with **no** row padding and no alpha. Row `y` begins at byte
offset `y * width * 3`; pixel `(x, y)` is the three bytes at
`(y * width + x) * 3`. So a full-frame compare is a single string comparison of
`pixels`, and a region is a `substr`.

`format` is an explicit field so a future variant (for example `rgba32`, or a
24-bit panel mode) can be added without breaking callers; treat any value other
than the ones you handle as unsupported rather than assuming `'rgb24'`.

## The progress object

A capture is brief, so `$progress` is **optional**. When supplied it follows the
same contract as [e80Config](e80Config_API.md): a `threads::shared` hash the
caller creates and the library **only mutates** (it never replaces the hash).
Pass it to drive a progress / cancel UI from another thread, or simply to read
the failure reason after a false return.

| Field | Written by | Meaning |
|-------|------------|---------|
| `active` | caller | set to 1; the capture is running |
| `total` | library | total work units |
| `done` | library | work units completed so far |
| `label` | library | current phase text (e.g. `"Receiving frame"`) |
| `cancelled` | caller | set to 1 to request cancellation |
| `error` | library | failure reason (set when the call returns false) |

Initialize it before the call (same shape as e80Config):

```perl
my $progress = &threads::shared::share({});
$progress->{active}    = 1;
$progress->{total}     = 0;
$progress->{done}      = 0;
$progress->{cancelled} = 0;
$progress->{error}     = '';
$progress->{label}     = '';
```

Because a capture is a single brief operation, progress is coarse (connect ->
receive -> done) rather than fine-grained. Cancellation is honored up to the
point the bulk transfer begins; once underway the transfer runs to completion
(it is sub-second). On cancel the call returns false with `error` =
`"cancelled"`.

## Behavior and guarantees

- **Read-only.** A capture never writes to the unit and never reboots it. It is
  safe to call repeatedly against a live, in-use unit.
- **Faithful composite.** The returned image is the unit's display layers
  composited in hardware z-order exactly as scanned out to the panel -- chart,
  instrument panels, chrome, and video -- flattened to true color. Pixels that
  are transparent on the panel (color-keyed) resolve to the layer beneath, as
  they do on the glass.
- **Internally consistent (tear-free).** Each capture is taken from a single
  on-device atomic snapshot, so the image is consistent across the whole frame
  -- free of the tearing and roll artifacts that a multi-request capture can
  exhibit on a changing screen.
- **Bounded.** The call is timeout-bounded; a powered-off, unreachable, or
  rebooting unit fails (false / `undef`) rather than hanging the caller.

## Known limitations

- **Fixed output format.** Captures are 8-bit-per-channel true color
  (`'rgb24'`), no alpha. Alpha or a wider panel mode would be a future `format`.
- **On-screen layers only.** The capture reflects what is composited to the
  panel; display surfaces that are not currently enabled / on screen are not
  included.
- **Firmware dependency.** Requires the bulk screen-capture diagnostic service
  on the target (the mod002 firmware build); a stock unit cannot be captured.
