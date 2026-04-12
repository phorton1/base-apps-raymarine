# FILESYS — CF Card Filesystem Protocol

**[Home](../../docs/readme.md)** --
**[NET](readme.md)** --
**[RAYNET](RAYNET.md)** --
**[RAYDP](RAYDP.md)** --
**[WPMGR](WPMGR.md)** --
**[TRACK](TRACK.md)** --
**FILESYS** --
**[DBNAV](DBNAV.md)** --
**[shark](shark.md)** --
**[Cables](ethernet_cables.md)**

**FILESYS** provides read access to the CF card filesystem on the E80. It operates
over UDP on port **2049**, service_id **5**. All known operations are read-only
in practice — see the critical note below about ARCHIVE.FSH.

Func(5) is advertised by RAYDP over multicast on 224.0.0.1:5800 as the following bytes

    RAYDP --> 00000000 37a681b2 05000000 01001e00 01081100 c2261ee0 010a0000 36f1000a 01080000 01

Which is parsed as

- len(37) type(0) id(37a681b2) func(5) x(01001e00,01081100)
- mcast_ip(224.30.38.194) mcast_port(2561)
- ip(10.0.241.54) port(2049) flags(1)

Thus, RAYDP presents a multicast ip:port 224.30.38.194:2561 for func(5).
The purpose of this multicast port has not been established.

RAYDP presents a second, non-multicast ip:port 10.0.241.54:**2049** for func(5).
10.0.241.54 is the E80's IP address in the test network. This address for
func(5) accepts UDP requests for CF card filesystem access,
and is referred to as the **FILESYS port**.

To use this protocol, the client sets up a UDP listener on a known port,
and then makes UDP requests to the FILESYS port. FILESYS will then send
responses to the listner port.


## Protocol Common Headers and Replies

This protocol supports the following known commands:

| Cmd | Constant        | Description                                      |
| --- | --------------- | ------------------------------------------------ |
| 00  | CMD_DIR         | Directory listing                                |
| 01  | CMD_GET_SIZE    | File size (FILES only; fails on directories)     |
| 02  | CMD_GET_FILE    | File contents                                    |
| 03  | CMD_UNKNOWN3    | Never produced a response                        |
| 04  | CMD_GET_ATTR    | Size + byte attributes (fails on root directory) |
| 05  | CMD_FILE_EXISTS | Returns success if file exists, error otherwise  |
| 06  | CMD_GET_SIZE2   | Same as CMD_GET_SIZE without the extra word(0)   |
| 07  | CMD_LOCK        | Increments the advisory lock counter             |
| 08  | CMD_UNLOCK      | Decrements the advisory lock counter             |
| 09  | CMD_CARD_ID     | Returns a card identification string             |

Multi-byte values in all observed RAYNET packets are encoded as
little endian, as shown in the byte stream examples below.

*Note: It is likely these command request and reply structures are used
in other RAYNET protocols.*

Note that a single request, ie a File Content Request, can result in MANY
packets being returned to the listener port.


### Common Request Headers

All FILESYS Requests share a common header structure differing
only by the leading command byte.  Here's an example of a
File Size Request (command #1)

    ccrrffff ssssssss pppp
    02010500 12300000 0048 ...

- c = 02 - the command byte is one of the known commands
- r = 01 - the request/reply byte is 1, indicating a request
- f = 0500 - the FILESYS func(5)
- s = 12300000 - an arbitray unique sequence number
- p = 0048 - the listener port number


### Port Encoding

All requests sent to FILESYS include the listener's port number.

The listener port for RNS, observed in captured traffic, is 18432,
which shows up as 0048 in the hex byte streams. This is the
little endian representation of the uint16 18432.

The shark implementation uses port 18433, which shows up
in the hex streams as 0148.


### CMD_CARD_ID Request/Reply (command 09)

CMD_CARD_ID returns a string that identifies the CF card currently in the E80.
The string is card-specific and semi-persistent.

    FILESYS <-- 09010500 12300000 0048
    FILESYS --> 09000500 12300000 88130000 01001400 20202020
                30303134 39313046 30364436 32303632 0f270c

The reply contains a human-readable ASCII string starting at byte 20
(with 4 leading spaces):

    "0014910F06D62062"  — RAY_DATA CF card
    "0014802A08W79223"  — Caribbean Navionics CF card

CMD_CARD_ID has never been observed to fail with a well-formed packet.


### General Success Reply (failure detection)

For other commands, FILESYS will reply with the same
initial 8 bytes, but will follow that with a recognizable
**Success Signature** of 0000400.  Here's an example of
the headers for a succesful File Size (command #1) Request
and Reply

    FILESYS <-- 01010500 12300000 0048 .... more bytes
    FILESYS --> 01000500 12300000 00000400 ... more bytes

Any reply that matches the first 8 bytes of the Reply,
but that then does not match the Success Signature is
considered an error.  The implementation reports the
error as "operation failed" and shows the bytes following the
sequence number.  Here's an example of a failed Directory File
Size Request and Reply:

    FILESYS <-- 00010500 0d000000 0048 .. more bytes
    FILESYS --> 00000500 0d000000 01050480 01000100 0000

Since 01050480 does not match the Success Signature 00000400,
the error is reported as "01050480010001000000" and
the operation is considered terminated.



## Command Specifics


### Directory Request/Reply (command #0)

Here is an example Directory Request for the \junk_data folder:


    FILE_SYS <-- 00010500 03000000 00480b00 5c6a756e 6b5f6461 746100                 ..
                                       ^word(length)

The request is the Common Request Header, followed by a word for the
length of the path '\junk_data' plus one for the null terminator,
which is 0b00 in this case, followed by the ascii string '\junk_data'
which starts with the byte 0x5c, followed at the end by a null
terminator.

The reply below clearly has the Success Signature 00000400,
followed by (probably) a word(num_packets)=1, a word(packet_num)=1,
and the word 0600 which is unknown at this time, followed by a
stream of directory entries starting at the first length word.

Each entry consist of s word(length), followed by length bytes
ascii character for the name,followed by a 1 byte FAT bit flag.

                                            + first length word
                                            v        v first FAT bit flag
    00000500 03000000 00000400 01000100 06000200 2e001002 002e2e10 0e005445   ..............................TE
    53545f44 41544131 2e545854 200e0054 4553545f 44415441 322e5458 54201400   ST_DATA1.TXT ..TEST_DATA2.TXT ..
    54455354 5f444154 415f494d 41474531 2e4a5047 20140054 4553545f 44415441   TEST_DATA_IMAGE1.JPG ..TEST_DATA
    5f494d41 4745322e 4a504720                                                _IMAGE2.JPG

When parsed, this packet results in

    flag(0x10) DIR      len(2)  .
    flag(0x10) DIR      len(2)  ..
    flag(0x20) FILE     len(14) TEST_DATA1.TXT
    flag(0x20) FILE     len(14) TEST_DATA2.TXT
    flag(0x20) FILE     len(20) TEST_DATA_IMAGE1.JPG
    flag(0x20) FILE     len(20) TEST_DATA_IMAGE2.JPG

The FAT flags are, bitwise, as follows:

    FAT_READ_ONLY   = 0x01
    FAT_HIDDEN      = 0x02
    FAT_SYSTEM      = 0x04
    FAT_VOLUME_ID   = 0x08
    FAT_DIRECTORY   = 0x10
    FAT_FILE        = 0x20




### FileSize Request/Reply (command #1)

A FileSize Request is used to query the size of a file on the CF card.
The request structure follows the Common Request Header, followed by a
an empty word(0), then followed by the word(length) and a null-terminated
ASCII string representing the file path.

Example request for `\junk_data\TEST_DATA1.TXT`:

                                      v extra dword(0)
    FILESYS <-- 01010500 04000000 00480000 1a005c6a 756e6b5f 64617461 5c544553 545f4441 5441312e 54585400
                                           ^word(length=26, including the null)

- The length word (0f00) indicates the number of bytes in the path string including the null terminator.
- The path string is encoded in ASCII and null-terminated.

Example reply:

    FILESYS --> 01000500 04000000 00000400 2c010000

- The reply matches the first 8 bytes of the request, with the request/reply byte set to 00.
- The Success Signature 00000400 confirms the operation succeeded.
- The final dword (2c010000) is the little-endian representation of the file size: 0x0000012c = 300 bytes.


### FileContents Request/Reply (command #2)

A FileContents Request retrieves the actual contents of a file.

The request includes an additional dword(0) followed by a **maximum file size**
parameter before the path. The value `9a9d0100` seen in RNS captures is RNS's
own maximum file size limit (not a protocol key or magic value). The shark
implementation uses `ffffff01` (32MB / 0x01ffffff).

Example request for `\junk_data\test_data_image1.jpg`:

    FILESYS <-- 02010500 01000000 00480000 00009a9d 01002000 5c6a756e 6b5f6461 74615c74 ... 6a706700
                                      ^        ^        ^ length word (includes null terminator)
                                      |        +---- max file size (RNS uses 0x019d9a00; shark uses 0x01ffffff)
                                      +--- additional dword(0)

- Command byte is 02 for FileContents.
- Sequence number is arbitrary and must match in the reply.
- Listener port is encoded as before.

The reply consists of one or more packets, each containing a portion of the file. Each packet begins with:

                              nnnnpppp bbbb
    02000500 0500000 00000400 23000000 0004 .... content bytes follow

- The Success Signature 00000400 confirms the packet is valid.
- nnnn is a word for the number of packets (0x23 = 35 packets)
- pppp is a word for the packet number (0000 for the 1st reply packet)
- bbbb is the bytes of content in this packe

All packets except the end one will have bbbb=0004, which is 0x0400, which is 1K bytes.
The last packet will be packet number 0x22 (34 decimal), and may have less than 0x0400 bytes in it

Here is an example showing the first few, and last few packets headers of the jpeg file

                                                            content
    packet(0)  02000500 01000000 00000400 23000000 0004     ffd8 ffe00010 4a464946 00010101
    packet(1)  02000500 01000000 00000400 23000100 0004     028a 28a0028a 28a0028a 28a0028a
    packet(2)  02000500 01000000 00000400 23000200 0004     028a 28a0028a 28a0028a 28a0028a
    ....
    packet(32) 02000500 01000000 00000400 23002000 0004     1450 01451450 01451450 01451450
    packet(33) 02000500 01000000 00000400 23002100 0004     8a28 a0028a28 a0028a28 a0028a28
    packet(34) 02000500 01000000 00000400 23002200 0202     8a28 a0028a28 a0028a28 a0028a28

The last packet has 0x202 == 514 bytes in, and so the total file size is 35330 bytes

If the file is not found or the request fails, the reply will not contain the Success Signature and should be treated as an error.


## Advisory Locking (CMD_LOCK / CMD_UNLOCK)

FILESYS implements an advisory locking scheme via CMD_LOCK (07) and CMD_UNLOCK (08):

- Call CMD_UNLOCK first. If it returns an error, no lock is held — you are free to
  call CMD_LOCK (which always succeeds).
- CMD_UNLOCK succeeds as many times as CMD_LOCK was called, then returns an error.
- Whether LOCK actually prevents the E80 from writing to the CF card is unknown.

## Listener Ports

FILESYS replies are sent to the listener port encoded in each request:

| Port  | Constant       | User                          |
| ----- | -------------- | ----------------------------- |
| 18432 | FILE_RNS       | RNS's listener port           |
| 18433 | MY_FILE        | shark's listener port         |

These ports are not advertised by RAYDP — they are empirical values observed
in RNS traffic (18432) and chosen for the shark implementation (18433).

## Critical Note: ARCHIVE.FSH

Once CMD_GET_FILE is used to retrieve `\Archive\ARCHIVE.FSH`, the E80 cannot
subsequently save to ARCHIVE.FSH while it remains connected. Additionally,
the E80 only writes ARCHIVE.FSH changes to the physical CF card when the card
is physically removed. These behaviors make FILESYS read-only in practice for
the FSH file, even though no write commands have been found.

Note that malformed packets will crash the E80 and will likely crash RNS as well.

## Implementation State

All 10 commands are identified. Commands 0x00–0x02 and 0x09 are confirmed working.
CMD_UNKNOWN3 (0x03) was never observed to produce a response. Write-like operations
(create, delete, modify) have not been observed from RNS and are not implemented.

---

**Next:** [DBNAV](DBNAV.md)



