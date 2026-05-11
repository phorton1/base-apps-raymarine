# WPMGR - Waypoint, Route, and Group Management

**[NET](readme.md)** --
**[RAYNET](RAYNET.md)** --
**[RAYDP](RAYDP.md)** --
**WPMGR** --
**[TRACK](TRACK.md)** --
**[FILESYS](FILESYS.md)** --
**[DBNAV](DBNAV.md)** --
**[Cables](ethernet_cables.md)**

Folders: **[Raymarine](../../docs/readme.md)** --
**NET** --
**[FSH](../../FSH/docs/readme.md)** --
**[CSV](../../CSV/docs/readme.md)** --
**[shark](../../apps/shark/docs/shark.md)** --
**[navMate](../../apps/navMate/docs/readme.md)**

**WPMGR** is the Waypoint Manager service - the protocol for reading and writing
Waypoints, Routes, and Groups on the E80. It is the most fully reverse-engineered
and implemented service in this codebase.

WPMGR is func(15) as advertised by RAYDP. That is 0x00f0 as a word.
The func is represented in hex streams as `0f00` and is seen throughout all messages.

The communication takes place via a TCP connection established by the
client to the WPMGR (2052) port on the MFD (E80).

## Message Structure Overview

The data structures involved in the communications between WPMGR
and a client are complicated.  Each blast between them can consist
of multiple *messages* in a single, or two *packets*.

### Little Endian

Bytes are presented in the order they appear in the TCP packets.
Representations are **little endian**, which can lead to confusion
when also discussing the *values* of words, dwords, quad words, and so on.

For example, if a hex stream looks like this

	1000 1234 12345678

And say that "the stream consists of a length word, a command word,
and a data dword", the ACTUAL uint16 and uint32 values in hex notation
would be:

- 0x0010 = 16 decimal
- 0x3412
- 0x78563412

Working with these hex digit streams requires facility with reading
little endian numbers.

This presentation tends to obfuscate the underlying structure:
the most significant bytes - which carry the most significant
information - appear at the end of each word or dword. This
document does not present C struct equivalents; nonetheless,
understanding this endian convention is important when reading
the communication structures.


### Terminology

The word **packet** is reserved for internet protocol packets.

A **message** is a length delimited record that has

- a **length word** that specifies the length of the message
- a **command word** that specifies the content and semantics of the message
- the WPMGR *func word* **0f00** following the **command word**
- usually a **dword seq_num** that tags a *reply* to a *request*
- possible **data** that follows

The *command word* will be discussed in more detail, but,
terminologically, within the command word is **the command**
which is the low order nibble of the command word.

- A **request** is a series of one or more *messages*
  sent from the client to WPMGR. The E80 is typically
  observed to receive these as two TCP segments.
- A **reply** is a series of one or more messages
  sent from WPMGR to the client in response to a request.
  The E80 is typically observed to send replies as two TCP segments.
- An **event** is one or more messages sent from WPMGR to the
  client without a preceding request. Events are typically
  observed as a single TCP segment; several may arrive in
  rapid succession.

Here is an example request sent from the client to WPMGR

	WPMGR <-- 1000
	WPMGR <-- 02020f00 01000000 00000000 00000000

In this example

- the *length* is 1000 == 0x0010 == 16 bytes
- the *command word* is 0202
- the *func word* is **always 0F00** == 0x00f0 == 15,
  the WPMGR function
- the *seq_num* is 01000000 = 0x00000001== 1
- the *data* is 00000000 00000000


### Series of Messages

WPMGR messages are framed as `<length><body>` pairs within a TCP stream,
as described in [RAYNET](RAYNET.md). The E80 is typically observed to send
the leading length word as the first TCP segment and subsequent messages
in a second segment - but message extraction cannot rely on this; each
length word determines where the next boundary lies within the accumulated
stream buffer.

Here is a *reply* from WPMGR to RNS, observed as two TCP segments, that
consists of four messages. The start of each message is labelled with a >.

	WPMGR --> >0c00
	WPMGR -->  06000f00  24000000  00000400 >14000002  0f002400  0000db82  99b8f567  e68e0100
	            0000>3e00 01020f00  24000000  32000000  1a438d05  88f100cf  7cce9b06  fa8c8bc5
	            00000000  00000000  00000000  02ffffff  ffffffea  86000086  4f000200  00000000
	            5770>1000 02020f00  24000000  db8299b8  f567e68e

The length of the first packet is 2 bytes and the second packet is 116 bytes.

	message(0) len(0c00=8)   func(0f00) command(0600) data= 00000400
	message(1) len(1400=24)  func(0f00) command(0002) data= db8299b8 f567e68e 01000000
	message(2) len(3e00=108) func(0f00) command(0102) data= 32000000 1a438d05 88f100cf 7cce9b06 fa8c8bc5...
	message(3) len(1000=16)  func(0f00) command(0202) data= db8299b8 f567e68e

#### Inner and Outer Messages

As mentioned above, the E80 will blast out a series of messages typically in two packets,
and often RNS sends a series of more than one message in a similar two packet blast.

Messages that open a blast are termed **Outer** messages;
those contained within the blast are **Inner** messages.



### Statefulness and Modality

These messages are **stateful**: an entire series of messages may be sent in
a single two-packet blast, or each message may be sent in separate two-packet
blasts, with the same result either way.

A *request* is distinguished from a single *message*: it is only after the
reception of *certain sequences of messages* that the E80 will reply, and
replies are virtually always sent in a blast of two packets, the first
containing a length word and the second containing one or more messages.

Within the parsing of a single *request*, the E80 builds up and maintains
state as it parses messages before replying.

The protocol also exhibits **modality** - a higher level of statefulness
in which the semantics of a request depend on what previous requests
have been sent.

For instance, a message that can be sent alone as a request is
the **get dictionary** message (command word=0202):

	1000 0202 0f00 {seq_num} 00000000 00000000

This same command is sent to the E80 to retrieve the entire list (dictionary)
of the uuids for the Waypoints, Routes, or Groups on the E80, depending on
the previous **set context** message(s) that the E80 received, which set
the context to **Waypoints** or **Routes** or **Groups**.

Once the correct context is established, this message may be sent
repeatedly and the E80 will reply with the same type of dictionary reply. The above long long example reply above,is a
*get dictionary reply* and always consists of four messages.



## Command Word

The **command word**, when viewed in hex stream format, looks like this

	WCXY

where *typically* the semantics are:

- W = **what** nibble, the context, which appears to be enumerated
  - 0x0 == Waypoints (appears to always be implied)
  - 0x4 == Routes
  - 0x8 == Groups
  - 0xb == Database?
- C = the **command** nibble appears to be an enumerated value
- XY = **request/reply** byte for lack of a better term.
  - X is always zero
  - Y is always 0,1, or 2, where:
	- Y == 0 means **reply**   (or "info", as it is also sent for events)
	- Y == 1 means **request**
	- Y == 2 means **either**

In hex format this would be 0xXYWC, with the *command* nibble
coming last, after the *what* context nibble.

### The What (Context) nibble

There is a definite correlation that 0x4 means "Routes" and 0x08 means "Groups".

0x0 meaning "Waypoints" seems to be "implied" to some degree, indicating that
perhaps the whole purport of WPMGR is to be a **Waypoint Manager** and that
either we are specifically talking about waypoints (0) or *additionally*
talking about Routes and Groups, both of which contain waypoints.

The only other value observed is 0xb, used only in a few "monadic"
requests of length(4) that do not even have sequence numbers (though their
replies may).  These requests do not always return replies, but when they
do, they appear to return data containing a number that increments each
time it is called, which might be used by a multi-threaded client to
check if another thread has made changes that the current thread is
not aware of.


### Request/Reply byte

This might better be called the *status* byte, or the *direction* byte.
The following are empirical observations:

Note, once again, that when the E80 replies, or when RNS sends requests
to the E80, there are may or may not *inner* messages, but there is **always
an outer message**.

The outer message appears to indicate whether a blast is a
request or a reply.  The following generalizations regarding
the Request/Reply byte have been observed:

- All messages in requests are ether XY==1 or XY==2
- All messages in replies (and events) are either XY==0 or XY==2
- Outer level requests always have either XY=1 or XY=2
- Outer level replies (and events) have XY==0


### The Command Byte

That just leaves the all important command byte, and the specific structure
of the data associated with each command byte, to discuss.

This is the thorny issue.

The semantics are surmised from watching conversations between RNS and the
E80 and/or by probing the E80 by sending things to it and seeing what comes
back.

This characterization is rough, incomplete, and inaccurate,
difficult to come up with, and difficult to maintain.

The following is the raw discovery-era analysis of the command byte semantics.
The formalized constants derived from this analysis are in `e_wp_defs.pm` and
are listed at the end of this section.

The following rough semantics have been applied to the observed
command bytes.

These are all command nibbles observed, with rough interpretations.  Remember that the protocol is stateful
and the meanings of these might change depending on the state.


WC0D

	Z = Direction
		0 = REPLY		shows What Command {type} REPLY 	does not show Command(CONTEXT)=0
		1 = USE			shows USE What Command				sets {ref} to What
		2 = APPLY		shows APPLY {ref} Command 			sets {type} to Command

		- reply comes AFTER, where as USE/APPLY come before rest

	W = What
		0 = Waypoint, shows {ref} on APPLY
		4 = Route
		8 = Group
		B = Database; sets {ref}='DATABASE' and {type}='DATA'

	C = Command
		0 = CONTEXT
		1 = BUFFER
		2 = LIST
		3 = ITEM				by uuid
		4 = EXISTS				by uuid returns
		6 = DATA				reply only
		7 = CREATE
		8 = UUID
		9 = 9VERB

		A = AVERB
		B = BVERB
		C = FIND				by name
		D = DVERB
		E = UUID
		F = FVERB


Commands 7, c, and d are observed when creating a waypoint in
RNS that gets sent to the E80.

The formalized constants from `e_wp_defs.pm` express this as:

	0xDWC
		D = direction-ish (RECV=0, SEND=1, INFO=2)
		W = WHAT context (WAYPOINT=0x0, ROUTE=0x4, GROUP=0x8, DATABASE=0xb)
		C = CMD nibble (CONTEXT=0, BUFFER=1, LIST=2, ITEM=3, EXIST=4,
		                EVENT=5, DATA=6, MODIFY=7, UUID=8, NUMBER=9,
		                AVERB=a, BVERB=b, FIND=c, COUNT=d, EVERB=e, FVERB=f)

Note that CMD_MODIFY (0x7) is used for both create and modify operations - the
distinction is in the sequence of messages that precede it, not in the command byte
itself.


## Known Working Operations

The following operations are confirmed implemented in `d_WPMGR.pm` and `e_wp_api.pm`:

**do_query** - retrieves all Waypoints, Routes, and Groups:
calls query_one for each WHAT type in sequence.

**get_item(uuid)** - retrieves a single item by UUID:
sends a single CMD_ITEM message and receives the item record.

**create_item(type, data)** - creates a new item:
1. CMD_FIND by name - confirms the name does not already exist
2. CMD_ITEM by UUID - confirms the UUID does not already exist
3. CMD_MODIFY + CMD_CONTEXT + CMD_BUFFER + CMD_LIST sequence

**modify_item(uuid, data)** - modifies an existing item:
1. CMD_EXIST by UUID - required first; fails if item does not exist
2. CMD_DATA + CMD_CONTEXT + CMD_BUFFER + CMD_LIST sequence

**delete_item(uuid)** - deletes an item:
sends a single CMD_UUID message (despite the name, CMD_UUID means "delete").

**Events (CMD_EVENT / CMD_MODIFY)** - unsolicited notifications from E80:
- CMD_EVENT: `dword(evt_flag)` - 0 = start of event series, 1 = end
- CMD_MODIFY in event context: `uuid + mod_bits` (0=new, 1=deleted, 2=changed)

## dict_buffer Parameter

When setting up a query context (CMD_BUFFER), the leading word of the buffer
specifies the maximum reply size. The current implementation uses `ffff0000...`
(max 64K). RNS used smaller values (0x1027 for waypoints, 0x9600 for routes,
0x6400 for groups) - these are just RNS's own optimization choices, not
protocol requirements.

## Group and Route Membership Operations

Operations involving group membership and route waypoint assignment are partially
implemented. See `d_WPMGR.pm` for current state - the header comments in that
file may not reflect the current implementation. This area is flagged for
empirical validation with the live program.

## Field Length Limits

The E80 hardware imposes hard limits on the length of name and comment fields
for all WPMGR object types (waypoints, groups, routes). Exceeding these limits
causes silent data loss on the device - the E80 accepts the create/modify
request without error but truncates or discards the excess characters.

| Field   | Max length | Applies to                    |
| ------- | ---------- | ----------------------------- |
| name    | 15 chars   | waypoints, groups, routes     |
| comment | 31 chars   | waypoints, groups, routes     |

These limits are defined as `$E80_MAX_NAME` and `$E80_MAX_COMMENT` in `a_defs.pm`
and are enforced as hard errors in `e_wp_api.pm`: `createWaypoint`, `modifyWaypoint`,
`createGroup`, `modifyGroup`, `createRoute`, and `modifyRoute` all reject inputs
that exceed these limits with an `error()` call before touching the wire.

The navMate database deliberately does **not** enforce these limits - long names
(e.g. `2024-06-15-BocasToPanama`) are valid DB records. The mapping to the 15-char
E80 limit is a transport-layer concern handled at the navOperations layer.

## Implementation Notes

**Socket lifecycle:** It is inadvisable to close and re-open a TCP socket to
a running E80 from within the Perl thread. Attempting to do so does not work
reliably and typically requires quitting the program or clearing Windows socket
state (e.g. toggling unrelated Wi-Fi, rebooting). If the E80 goes down, the
thread detects a TCP send failure and will successfully close and re-open the
socket once the E80 reboots or reconnects. Implemented services use
`EXIT_ON_CLOSE=0` for exactly this reason.

**Stream-based parser:** WPMGR messages are extracted from the TCP stream by a
persistent accumulator in `b_sock.pm`. Each complete message is dispatched to
`e_WPMGR.pm` via `dispatchRecvMsg()` independently. Per-transaction state lives
in `$this->{tx}` on the parser object and survives across multiple `recv()` calls.
`resetTransaction()` clears this state at connection establishment and at the start
of each new request (detected by `DIRECTION_SEND`). This design correctly handles
large multi-message replies - such as deleting a route with many waypoints - where
the E80's reply spans multiple TCP segments.

## Early Discovery Notes

The raw command discovery table from early analysis (predating the `e_wp_defs.pm`
constants) is preserved in
[`NET/docs/notes/wpmgr_command_discovery.md`](notes/wpmgr_command_discovery.md).
Command names there differ from the current code constants.

---

**Next:** [TRACK](TRACK.md)

