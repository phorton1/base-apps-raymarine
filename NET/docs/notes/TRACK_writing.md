# TRACK writing -- protocol specification

A transient one-track-per-session TCP protocol for uploading a
complete track to the E80 TRACK service. Uses the existing service
port (advertised via RAYDP), the existing message envelope format,
and the existing reader-side wire formats for MTA, TRACK_HEADER,
and TRACK_PT. One TCP session uploads exactly one track.

The writer-side `$DIRECTION_INFO` commands at command-nibbles 0/1/2
mirror the existing reader-side `$DIRECTION_RECV`
`$TRACK_REPLY_CONTEXT/BUFFER/END` naming at the same nibbles. The
writer uses one new `$DIRECTION_SEND` command (RECORD) and observes
one new `$DIRECTION_RECV` reply (SAVED).

---

## Constants

```perl
# Constants specific to Track Writing mode
our $TRACK_CMD_RECORD     = 0x11;   # open / close writer session
our $TRACK_INFO_CONTEXT   = 0x00;   # opens a body group
our $TRACK_INFO_BUFFER    = 0x01;   # the body
our $TRACK_INFO_END       = 0x02;   # closes the body group
our $TRACK_REPLY_SAVED    = 0x0f;   # auto-save acknowledgment
```

---

## Rules

In the same form as the existing `%TRACK_PARSE_RULES`:

```perl
# Rules specific to Track writing mode
$DIRECTION_SEND | $TRACK_CMD_RECORD     => { pieces => ['seq', 'zero4'],                terminal => 0 },
$DIRECTION_INFO | $TRACK_INFO_CONTEXT   => { pieces => ['seq', 'uuid', 'context_bits'], terminal => 0 },
$DIRECTION_INFO | $TRACK_INFO_BUFFER    => { pieces => ['seq', 'buffer'],               terminal => 0 },
$DIRECTION_INFO | $TRACK_INFO_END       => { pieces => ['seq', 'uuid'],                 terminal => 0 },
$DIRECTION_RECV | $TRACK_REPLY_SAVED    => { pieces => ['seq', 'success'],              terminal => 1 },
```

These mirror the reader-side `%TRACK_PARSE_RULES` for the same
three INFO commands: every INFO frame carries a leading `'seq'`,
and the `'buffer'` piece encompasses its standard `biglen +
content` wire form.

Piece notes:

- `'seq'` (u32) is the standard envelope correlation token. The
  writer chooses it for `$TRACK_CMD_RECORD`, and the same value
  carries through every INFO frame for the rest of the session
  (matching the WPMGR convention). The server echoes RECORD's
  seq back in the `'seq'` piece of `$TRACK_REPLY_SAVED`. The seq
  value on INFO frames is not validated by the server, but
  including it (rather than zero) keeps the wire consistent with
  the reader-side body group convention.
- `'uuid'` (8 bytes) is the track's identifying UUID. The same
  value is used in all three INFO messages of a body group; the
  CONTEXT-side value is what becomes the saved track's UUID.
- `'context_bits'` (u32) -- writer-side semantics not established;
  send 0.
- `'buffer'` follows the standard RAYNET buffer wire form:
  `u32 biglen` followed by `biglen` bytes of content. The content
  is interpreted by the server based on which body group is in
  progress (see "Wire sequence" below).
- `'success'` (u32) is `0x00040000` on confirmed save; any other
  value is a failure.
- `'zero4'` is 4 bytes of zeros.
---

## Wire sequence

```
1. Open TCP to the advertised TRACK service.

2. Send $TRACK_CMD_RECORD
   No reply.

3. Send the MTA as one body group:
     a. $TRACK_INFO_CONTEXT  { uuid: track UUID }
     b. $TRACK_INFO_BUFFER   { buffer: 57-byte MTA record per $MTA_REC_SPECS }
     c. $TRACK_INFO_END      { uuid: track UUID }
   No reply.

4. Send the points: 
   If the batch exceeds the reader-side single-message size limit, the writer splits it
   across multiple buffer messages within the same body group.
     a. $TRACK_INFO_CONTEXT  { uuid: track UUID }
     b. $TRACK_INFO_BUFFER   { buffer:
            $TRACK_HEADER_SPECS  with  a, batch_cnt, b=0
            followed by batch_cnt records of $TRACK_PT_SPECS }
     c. $TRACK_INFO_END      { uuid: track UUID }
   No reply.

5. After the server has received exactly cnt1 points, it auto-saves
   and emits:
     $TRACK_REPLY_SAVED  { seq: echoes step 2's seq,
                           success: 0x00040000 on success }

6. Close TCP.
```

### Batch field semantics

When a body group's `buffer` is a point batch, the leading
`$TRACK_HEADER_SPECS` fields have these writer-side meanings:

- `a` (u32): starting index into the server-side point buffer for
  the points in THIS batch. The server writes the i-th point of
  the batch at buffer position `(a + i) * 14`. For a single-batch
  upload, `a = 0`.
- `cnt` (u16): number of points in this batch. The server reads
  exactly `cnt` consecutive `$TRACK_PT_SPECS` records from the
  buffer after the header.
- `b` (u16): no writer-side meaning; set to 0.


So, the protocol supports splitting the points across multiple
body groups. Each batch is a separate CONTEXT/BUFFER/END body
group as in step 4 above. Across batches:

- `a` of each subsequent batch must equal `a + cnt` of the
  previous batch (no gaps, no overlap, monotonically increasing).
- The sum of all batches' `cnt` values must equal `cnt1`.

The auto-save fires when the cumulative point count reaches
`cnt1`, regardless of how many body groups it took to get there.


### Abort

At any time after step 2, sending another `$TRACK_CMD_RECORD`
(payload ignored) discards the in-progress track and closes the
TCP connection. No reply.

---

## MTA writer-side notes

The 57-byte MTA record uses the existing `$MTA_REC_SPECS` layout
in `b_records.pm`. The writer should set:

```
k1_1    = 0x01    # writer is uploading a saved track. The 0x00
                  # value sometimes observed on the reader side is
                  # for in-process recordings on the E80 itself
                  # and is not appropriate here.

cnt1    = the exact number of points the writer will deliver
cnt2    = cnt1    # an internal redundancy
k2_0    = 0

u1      = 0       # the 0xEF value sometimes observed on the reader
                  # side is "not recording yet" and is not
                  # appropriate here.
```

All other fields (`length`, the start/end anchor lat/lon
encodings, `color`, `name`) follow `$MTA_REC_SPECS`. The writer
needs the inverse of the reader-side `northEastToLatLon`: a
`latLonToNorthEast` helper using the same scale factor.

---

## Operational contract

- **`cnt1` is binding.** The auto-save fires when and only when
  the server's running point count equals `cnt1`. Send too few:
  the save never fires; the upload hangs. Send too many: behavior
  past the cnt1-th point is undefined.

- **TCP close discards.** No partial save, no resume. If the
  connection drops before the SAVED reply -- client, network, or
  otherwise -- the in-progress track is lost.

- **Close after SAVED.** The SAVED reply is end-of-session. Do
  not send further commands on the same connection. Another track
  requires a new TCP session.

- **Client-side reply timeout.** The protocol does not specify a
  server-side timeout. The writer SHOULD impose its own (e.g., 10
  seconds after the final `$TRACK_INFO_END`); on timeout, close
  TCP and treat the upload as failed.

## Device limits

These are properties of the E80 itself, independent of the writer
protocol:

- **Maximum 10 saved tracks.** The E80's saved-track database holds at
  most 10 tracks (E-Series Reference Manual: "1,200 waypoints, 150
  routes and 10 tracks"). With 10 already present, the upload's
  auto-save cannot allocate an 11th and the write fails. Treat any
  `SAVED` `success` value other than `0x00040000`, or a reply timeout,
  as a failed save, and surface "track storage full" rather than a
  generic error. Free a slot first -- delete a track on the device, or
  archive to a CompactFlash card. (The on-device recording track is
  separate from these 10.)

- **Maximum 1000 points per track.** A `CTrack` is a fixed 1000-point
  buffer; set `cnt1` no greater than 1000. On the device side the
  recorder rings (overwrites oldest) beyond 1000; for an upload, keep
  the delivered point count within 1000.

- **Segment breaks are sentinel points.** Within a track the E80
  encodes a segment break as a single point with all fields all-ones
  (north = east = 0xFFFFFFFF, temp = depth = 0xFFFF), which decodes to
  approximately lat 0 / lon 0. To upload a multi-segment track, insert
  one such sentinel point between legs and count it in `cnt1` like any
  other point. (Encoding confirmed from the recorder side; the writer
  round-trip of a sentinel has not yet been verified on hardware.)
