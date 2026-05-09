# TRACK - Track Management Protocol

**[Home](../../docs/readme.md)** --
**[NET](readme.md)** --
**[RAYNET](RAYNET.md)** --
**[RAYDP](RAYDP.md)** --
**[WPMGR](WPMGR.md)** --
**TRACK** --
**[FILESYS](FILESYS.md)** --
**[DBNAV](DBNAV.md)** --
**[shark](../../apps/shark/docs/shark.md)** --
**[navMate](../../apps/navMate/docs/readme.md)** --
**[Cables](ethernet_cables.md)**

**TRACK** is the service for managing GPS tracks recorded by the E80. It operates
over TCP on port **2053**, service_id **19** (0x13, shown as `1300` in hex streams).
TRACK is fully implemented in `d_TRACK.pm`.

Unlike WPMGR, tracks cannot be created programmatically - they can only be started
and stopped on the E80 itself. The TRACK protocol provides control over the
Current Track (start, stop, name, save, discard) and retrieval of saved tracks.

## Command Table

The client sends request commands; the E80 replies. Commands 0x12 and above cause
the E80 to close the TCP connection.

| Hex  | Name          | Params             | Notes                                          |
| ---- | ------------- | ------------------ | ---------------------------------------------- |
| 0x00 | GET_NTH       | seq, nth           | Get Nth point of the Current Track             |
| 0x01 | SET_NAME      | seq, name16        | Set Current Track name (any time, even before START) |
| 0x02 | GET_CUR2      | seq                | Get Current Track MTA + all points             |
| 0x03 | GET_CUR       | seq                | Get Current Track MTA only                     |
| 0x04 | SAVE          | (none)             | Save Current Track (no seq)                    |
| 0x05 | GET_TRACK     | seq, uuid          | Get a saved track by UUID                      |
| 0x06 | GET_MTA       | seq, uuid          | Get track metadata (MTA) by UUID               |
| 0x07 | ERASE_TRACK   | seq, uuid          | Delete a saved track (must be saved, not current) |
| 0x08 | RENAME        | seq, uuid, name16  | Rename a saved track                           |
| 0x09 | START         | (none)             | Start recording the Current Track (no seq)     |
| 0x0a | STOP          | (none)             | Stop recording the Current Track (no seq)      |
| 0x0b | DISCARD       | (none)             | Delete unsaved stopped Current Track (no seq)  |
| 0x0c | GET_DICT      | seq                | Get UUID index of all saved tracks             |
| 0x0d | GET_STATE     | seq                | Returns whether the E80 is currently recording |
| 0x0e | USELESS_E     | -                  | Returns EVENT byte=6; no practical use found   |
| 0x0f | NOREPLY_F     | -                  | Never produced a reply                         |
| 0x10 | BUMP_NAME     | seq, name16        | Increments the default track name counter      |
| 0x11 | NO_REPLY_11   | -                  | Never produced a reply                         |

Commands 0x12 and higher cause the E80 to close the TCP connection (FIN).

## Reply Codes

The E80 sends these reply codes back to the client:

| Hex  | Name     | Payload                | Notes                                         |
| ---- | -------- | ---------------------- | --------------------------------------------- |
| 0x00 | CONTEXT  | seq, success, is_point | Header for GET_NTH reply                      |
| 0x01 | BUFFER   | seq, success           | Header for Current Track MTA reply            |
| 0x02 | END      | seq, success           | Header for full Current Track reply           |
| 0x03 | CURRENT  | seq, success           | Reply to SAVE                                 |
| 0x04 | TRACK    | seq, success           | Header for GET_TRACK reply                    |
| 0x05 | MTA      | seq, success           | Header for GET_MTA reply                      |
| 0x06 | ERASED   | seq, success           | Reply to ERASE_TRACK                          |
| 0x07 | DICT     | seq, success, is_dict  | Header for GET_DICT reply                     |
| 0x08 | STATE    | seq, stopable          | Reply to GET_STATE; stopable=1 if recording   |
| 0x0a | EVENT    | byte                   | No seq; unsolicited track recording event     |
| 0x0b | CHANGED  | uuid, byte             | No seq; a saved track was added/changed/deleted |
| 0x0d | NAMED    | seq, success           | Confirms SET_NAME                             |
| 0x0e | RENAMED  | seq, success           | Confirms RENAME                               |

## EVENT Byte (reply 0x0a)

The EVENT byte is a bitmask sent unsolicited when the Current Track changes:

| Bit | Meaning                                              |
| --- | ---------------------------------------------------- |
| 0   | Point added to Current Track - re-fetch Current Track |
| 1   | New Current Track UUID - remove old UUID from cache  |
| 2   | Current Track changed - re-fetch Current Track       |
| 4   | Current Track modified - re-fetch Current Track      |

START generates EVENT bits 1 and 3. STOP generates EVENT bits 0 and 2.

## CHANGED Byte (reply 0x0b)

The CHANGED reply is sent unsolicited when a saved track is added, modified, or deleted:

| Value | Meaning                                         |
| ----- | ----------------------------------------------- |
| 0     | New track added - queue GET_TRACK for this UUID |
| 1     | Track changed - queue GET_TRACK for this UUID   |
| 2     | Track deleted - remove from local cache         |

## GET_DICT Reply Sequence

GET_DICT retrieves the UUID index of all saved tracks:

```
recv  DICT     seq, success
info  CONTEXT  uuid(0000)    context_bits=0x19
info  BUFFER   <dict data>
info  END      uuid(0000)
```

The dict data contains: number_of_tracks(dword) followed by that many 8-byte UUIDs.

## GET_TRACK Reply Sequence

GET_TRACK retrieves a complete saved track (MTA + points):

```
recv  TRACK    seq, success
info  CONTEXT  mta_uuid     context_bits=0x12
info  BUFFER   <mta data>
info  END      track_uuid   (is_track=1 set on END)
info  CONTEXT  trk_uuid     context_bits=0x11
info  BUFFER   <track points>
```

The MTA (metadata) and track point structures are shared with the FSH file format -
see `FSH/docs/readme.md` and `FSH/fshBlocks.pm` for field definitions.

## Important: GET_STATE Before GET_CUR2

GET_STATE must be called before GET_CUR2. GET_STATE returns `stopable=1` if the
E80 is currently recording a track. If the E80 is not recording (stopable=0),
calling GET_CUR2 may not produce a meaningful result.

## Known Limitations

These limitations are inherent to the TRACK protocol as observed:

- Tracks cannot be created programmatically - only started and stopped on the E80
- Track color cannot be set via TRACK protocol (color is set at recording time by E80)
- Track points cannot be modified
- ERASE_TRACK and RENAME operate on saved tracks only - not the Current Track

## Implementation Notes

**Stream-based parser:** Like WPMGR, TRACK uses the stream-based message model
implemented in `b_sock.pm`. Each TCP message is dispatched to `e_TRACK.pm` via
`dispatchRecvMsg()` independently. Per-transaction state lives in `$this->{tx}`.

The multi-buffer terminal condition for GET_TRACK and GET_CUR2 is handled via a
`buffer_complete` flag on the parser object. It is set by `parsePiece('buffer')`
when the `is_track` context is active, and checked in `parseMessage` after all
pieces are parsed. The `expect_trk` flag distinguishes GET_TRACK (saved track,
two-buffer MTA+TRK sequence) from GET_MTA (single-buffer response).

**Known issue - GET_CUR2 returns 0 points:** When GET_CUR2 is triggered by a
STOP or TRACK_CHANGED event, the MTA reports the correct point count but the
track point buffer comes back empty. The `buffer_complete` / `expect_trk` logic
in `e_TRACK.pm` does not yet correctly handle the GET_CUR2 wire sequence. The
track lifecycle (start/stop/name/save) works correctly; only the live
current-track point-readback is affected.

## Early Discovery Notes

Annotated hex captures from the discovery of the GET_DICT command and the MTA
structure parsing session are preserved in
[`NET/docs/notes/track_protocol_notes.md`](notes/track_protocol_notes.md).

---

**Next:** [FILESYS](FILESYS.md)
