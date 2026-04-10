# WPMGR — Waypoint, Route, and Group Management

**[Home](../../docs/readme.md)** --
**[NET](readme.md)** --
**[RAYNET](RAYNET.md)** --
**[RAYSYS](RAYSYS.md)** --
**WPMGR** --
**[TRACK](TRACK.md)** --
**[FILESYS](FILESYS.md)** --
**[DBNAV](DBNAV.md)** --
**[shark](shark.md)** --
**[Cables](ethernet_cables.md)**

**WPMGR** is the Waypoint Manager service — the protocol for reading and writing
Waypoints, Routes, and Groups on the E80. It is the most fully reverse-engineered
and implemented service in this codebase.

WPMGR is func(15) as advertised by RAYSYS. That is 0x00f0 as a word.
The func is represented in hex streams as `0f00` and is seen throughout all messages.

The communication takes place via a TCP connection established by the
client to the WPMGR (2052) port on the MFD (E80).

## Message Structure Overview

The data structures involved in the communications between WPMGR
and a client are complicated.  Each blast between them can consist
of multiple *messages* in a single, or two *packets*.

### Little Endian

It should be noted that typically, within this document and the
implementation I view the bytes in the order in which they appear
in the TCP packets, and that, generally speaking the representations
are **little endian**, which can lead to confusion if one then also
talks about the *values* of words, dwords, quad words, and so on.

So, for example, if I show a hex stream that looks like this

	1000 1234 12345678

And say that "the stream consists of a length word, a command word,
and a data dword", the ACTUAL uint16 and uint32 values in hex notation
would be:

- 0x0010 = 16 decimal
- 0x3412
- 0x78563412

Because of the large amount of information I have had to look at
to glean these details from raw ethernet packets, I have become
fairly proficient at "reading" little endian numbers, when needed,
from the hex digit streams I usually use to display things.

However, this will tend to obstruficate the underlying structure
of the communications in that this means that typically the
most significant bytes, which tend to be the most significant
information, are shown (and usually discussed) as being at
the end of a given word or dword.   I am not presenting this,
yet, as a series of C data structures, especially as I am using
Perl in my implementation, but nonetheless, it is important
to understand the difference and the ramifications when discussing
communication structures.


### Terminology

The word **packet** is reserved for internet protocol packets.

A **message** is a length delimited record that has

- a **length word** that specifies the length of the message
- a **command word** that specifies the content and semantics of the message
- the WPMGR *func word* **0f00** following the **command word**
- usually a **dword seq_num** that tags a *reply* to a *request*
- possible **data** that follows

The *command word* will be discussed in more detail, but,
terminolgically, within the command word is **the command**
which is the low order nibble of the command word.

- A **request** is a series one or more *messages*
  sent from the client to WPMGR, always in two packets.
- A **reply** is a series of one or more messages
  sent from WPMGR to the client in response to a request,
  always in two packets.
- An **event** is a series of one ore more messages
  sent from WPMGR to the client, always sent in a
  single packet, though several events may happen
  in rapid succession.

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

As mentioned above, *requests* and *replies* are typically
sent in two packets.  The first packet will contain the length
of the first *message* within the command or replyy, and then
the remainder of the packet, whose length is known from TCP,
will conisted of additional dword(length)-message paris that
are parsed until the end of the packet.

Here is a *reply* from WPMGR to RNS, in two packets, that consists
of four messages. The start of each message is labelled with a >.

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

I refer to any message that I have observed starting a blast as an **Outer** message,
and any that are then contained within that blast as **Inner** messages as I have
learned to parse these blasts of messages.



### Statefulness and Modality

For what it is worth, it is evident that these messages are **stateful**, in
that I have observed that, when sending requests to the E80, I can either send
an entire (specific) series of messages in a single two packet blast, or I can
send each message in separate two packet blasts and get the exact same result.

However, I distinguish a *request* from sending a single *message* to the E80,
as it is only after the reception of *certain sequences of messages* that the
E80 will reply, and when it replies, it virtually always replies in a blast
of two packets, the first containing a length word and the second containing
one or more message.

So, therfore, certainly within the parsing of a single *request* to the E80,
it is building up, and maintaining a state as it parses the messages before
replying.

But even moreso, I believe that the protocol exhibits **modality**, a higher
level of statefulness, in which the semantics (meaning) of a request depends
on what previous requests, specifically, have been sent.

For instance, there is message that can be sent alone as a request,
the I call the **get dictionary** message (command word=0202) that looks
like this :

	1000 0202 0f00 {seq_num} 00000000 00000000

This same command is sent to the E80 to retrieve the entire list (dictionary)
of the uuids for the Waypoints, Routes, or Groups on the E80, depending on
the previous **set context** message(s) that the E80 received, which set
the context to **Waypoints** or **Routes** or **Groups**.

Once I have established the correct context, I can send this single message
over and over again, and each time the E80 will reply with the same "kind"
of a dictionary reply. The above long long example reply above,is a
*get dictionary reply* and always consists of four messages.



## Command Word

The **command word**, when viewed in hex stream format, looks like this

	WCXY

where *typically* the semantics seem to beL

- W = **what** nibble, the context, which I now believe is enumerated
  - 0x0 == Waypoints (appears to always be implied)
  - 0x4 == Routes
  - 0x8 == Groups
  - 0xb == Database?
- C = the **command** nibble appears to be an enumerated value
- XY = **request/reply** byte for lack of a better term.
  - X is always zero
  - Y is always 0,1, or 2, and I have inferred
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

The only other value I have seen is 0xb, which is only used in a few "monadic"
requests of length(4) that do not even have sequence numbers (though their
replies may).  These requests do not always retrurn replies, but when they
do, they *seem* to return data that contains a number that increments each
time it is called, which might then be used by a multi-threaded client to
to check if some other thread in his own process has done something while
he was not aware of it.


### Request/Reply byte

This might better be called the *status* byte, or the *direction* byte,
and all I can say right now is my empirical observations on it.

Note, once again, that when the E80 replies, or when RNS sends requests
to the E80, there are may or may not *inner* messages, but there is **always
an outer message**.

I sort of think the *outer message* indicates whether a blast is a
request or a reply.  What I can say is that I have characterized every
message I have seen and have the following generalizations regarding
the Request/Reply byte

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

At this time I have seen, and applied the following rough semantics,
to the following command bytes.

These are all the command nibbles I have seen and a very, very
rough interpretation.  Remember that the protocol is stateful
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


Of these, I have only seen 7, c, and d when creating a waypoint in
RNS that gets sent to the E80.

The formalized constants from `e_wp_defs.pm` express this as:

	0xDWC
		D = direction-ish (RECV=0, SEND=1, INFO=2)
		W = WHAT context (WAYPOINT=0x0, ROUTE=0x4, GROUP=0x8, DATABASE=0xb)
		C = CMD nibble (CONTEXT=0, BUFFER=1, LIST=2, ITEM=3, EXIST=4,
		                EVENT=5, DATA=6, MODIFY=7, UUID=8, NUMBER=9,
		                AVERB=a, BVERB=b, FIND=c, COUNT=d, EVERB=e, FVERB=f)

Note that CMD_MODIFY (0x7) is used for both create and modify operations — the
distinction is in the sequence of messages that precede it, not in the command byte
itself.


## Known Working Operations

The following operations are confirmed implemented in `d_WPMGR.pm` and `e_wp_api.pm`:

**do_query** — retrieves all Waypoints, Routes, and Groups:
calls query_one for each WHAT type in sequence.

**get_item(uuid)** — retrieves a single item by UUID:
sends a single CMD_ITEM message and receives the item record.

**create_item(type, data)** — creates a new item:
1. CMD_FIND by name — confirms the name does not already exist
2. CMD_ITEM by UUID — confirms the UUID does not already exist
3. CMD_MODIFY + CMD_CONTEXT + CMD_BUFFER + CMD_LIST sequence

**modify_item(uuid, data)** — modifies an existing item:
1. CMD_EXIST by UUID — required first; fails if item does not exist
2. CMD_DATA + CMD_CONTEXT + CMD_BUFFER + CMD_LIST sequence

**delete_item(uuid)** — deletes an item:
sends a single CMD_UUID message (despite the name, CMD_UUID means "delete").

**Events (CMD_EVENT / CMD_MODIFY)** — unsolicited notifications from E80:
- CMD_EVENT: `dword(evt_flag)` — 0 = start of event series, 1 = end
- CMD_MODIFY in event context: `uuid + mod_bits` (0=new, 1=deleted, 2=changed)

## dict_buffer Parameter

When setting up a query context (CMD_BUFFER), the leading word of the buffer
specifies the maximum reply size. The current implementation uses `ffff0000...`
(max 64K). RNS used smaller values (0x1027 for waypoints, 0x9600 for routes,
0x6400 for groups) — these are just RNS's own optimization choices, not
protocol requirements.

## Group and Route Membership Operations

Operations involving group membership and route waypoint assignment are partially
implemented. See `d_WPMGR.pm` for current state — the header comments in that
file may not reflect the current implementation. This area is flagged for
empirical validation with the live program.

## Implementation Notes

**Socket lifecycle:** It is inadvisable to close and re-open a TCP socket to
a running E80 from within the Perl thread. Attempting to do so does not work
reliably and typically requires quitting the program or clearing Windows socket
state (e.g. toggling unrelated Wi-Fi, rebooting). If the E80 goes down, the
thread detects a TCP send failure and will successfully close and re-open the
socket once the E80 reboots or reconnects. Implemented services use
`EXIT_ON_CLOSE=0` for exactly this reason.

## Early Discovery Notes

The raw command discovery table from early analysis (predating the `e_wp_defs.pm`
constants) is preserved in
[`NET/docs/notes/wpmgr_command_discovery.md`](notes/wpmgr_command_discovery.md).
Command names there differ from the current code constants.

---

**Next:** [TRACK](TRACK.md)

