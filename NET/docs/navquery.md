# NAVQRY

NAVQRY is func(15) as advertised by RAYDP. That is 0x00f0 as a word.
The func is represented in hex streams as 0f00 and is seen all over the place

The communication takes place via a TCP connection established by the
client to the NAVQRY (2052) port on the MFD (E80).


### Connection Implementation Details

From within my running Perl thread, it is inadvisable for the client to
try to close the open socket to a running E80.  I don't know if its a
Windows, Perl, or E80 thing, but attempting to close and re-open a socket to
a running E80 does not work, and usually results in the need to
quit the program and/or do something fairly dramatic to Windows to
clear all open sockets (i.e. turn unrelated Wifi off and back on, reboot etc).

However, if the E80 goes down, the thread detects a subsequent TCP Send
failure, and will successfully close the socket and re-open it upon
the E80 being re-booted or reconnected.


## Message Structure Overview

The data structures involved in the communications between NAVQRY
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
- the NAVQRY *func word* **0f00** following the **command word**
- usually a **dword seq_num** that tags a *reply* to a *request*
- possible **data** that follows

The *command word* will be discussed in more detail, but,
terminolgically, within the command word is **the command**
which is the low order nibble of the command word.

- A **request** is a series one or more *messages*
  sent from the client to NAVQRY, always in two packets.
- A **reply** is a series of one or more messages
  sent from NAVQRY to the client in response to a request,
  always in two packets.
- An **event** is a series of one ore more messages
  sent from NAVQRY to the client, always sent in a
  single packet, though several events may happen
  in rapid succession.

Here is an example request sent from the client to NAVQRY

	NAVQRY <-- 1000
	NAVQRY <-- 02020f00 01000000 00000000 00000000

In this example

- the *length* is 1000 == 0x0010 == 16 bytes
- the *command word* is 0202
- the *func word* is **always 0F00** == 0x00f0 == 15,
  the NAVQRY function
- the *seq_num* is 01000000 = 0x00000001== 1
- the *data* is 00000000 00000000


### Series of Messages

As mentioned above, *requests* and *replies* are typically
sent in two packets.  The first packet will contain the length
of the first *message* within the command or replyy, and then
the remainder of the packet, whose length is known from TCP,
will conisted of additional dword(length)-message paris that
are parsed until the end of the packet.

Here is a *reply* from NAVQRY to RNS, in two packets, that consists
of four messages. The start of each message is labelled with a >.

	NAVQRY --> >0c00
	NAVQRY -->  06000f00  24000000  00000400 >14000002  0f002400  0000db82  99b8f567  e68e0100
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
perhaps the whole purport of NAVQRY is to be a **Waypoint Manager** and that
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
		E = DELETE
		F = FVERB


Of these, I have only seen 7, c, and d when creating a waypoint in
RNS that gets sent to the E80.

I'm beginning to think it is best to think of these in 0x notation as whole things

	0xDWC
		D = direction-ish, 0=reply, 1=command, 2=embedded or additional
		W = what, 0=waypoint, 4=route, 8=group, b=database
		C = command nibble that depends semantically on D


-------------------------------------------------------------------------------
# OLD
-------------------------------------------------------------------------------

## ALL COMMANDS SEEN

Multiple commands are passed with the same sequence number, but
there is only zero or one reply per sequence number.

																										sent
	semantic						command	func(15)													by			reply			notes
	guess				length		dword	navqry		seq_num		params								me? 		expected?

	erase context		0400		b101	0f00		!! 4 byte message with no seqnum				tested		sometimes		sent twice to start create sequence
	erase context		0400		b201	0f00		!! 4 byte message with no seqnum				tested		sometimes

	context (waypoint) 	0800		0001	0f00		{seq_num}										working		no              | the sequence number
	context (route) 	0800		4001	0f00		{seq_num}										working		no              | passed into these is
	context (group) 	0800		8001	0f00		{seq_num}										working		no              | the one returned by get* replies
	context (???)		0800		0d01	0f00 		{seq_num}										in create	yes				sent at top of create sequence


	commit context 		1400		0002	0f00		{seq_num} 00000000 00000000 1a000000			working		no
	create (2/4)		1400		0002	0f00 		{seq_cr#) {uuid    uuid}	01000000										interesting, commit context required, like 'chg_dir' for other commands

	set buffer			3400		0102	0f00		{seq_num} 28000000 ... 10270000 ...				working		no				| all these 3400 variants
	set buffer			3400 		0102	0f00		{seq_num} 28000000 ... 96000000 ...             tested      no              | appear to behave the same
	set buffer			3400 		0102	0f00		{seq_num} 28000000 ... 64000000 ...				tested      no              | in my testing/usage thus far
	set buffer			3400 		0102	0f00		{seq_num} 28000000 ... e8550f16 64000000 ...	tested      no              |
	set buffer			3400 		0102	0f00		{seq_num} 28000000 ... e8550f16 96000000 ...                                |

	get dictionary		1000		0202	0f00		{seq_num} 00000000 00000000						working		yes				| the seqnum from the context will be returned
	create(4/4)			1000		0202	0f00 		{seq_cr#) {uuid    uuid}													interesting that this has saome command as getting a dictionary
	get waypoint		1000		0301	0f00		{seq_num} qword{uuid}                           working		yes				| context seqnum, sometimes does not work out of context
	get route			1000		4301	0f00		{seq_num} qword{uuid}                           working		yes				| context seqnum, sometimes does not work out of context
	get group 			1000		8301	0f00		{seq_num} qword{uuid}							working		yes				| context seqnum, sometimes does not work out of context
	create(1/4)			1000		0701	0f00 		{seq_cr#) eeeeeeee eeee0110						not yet		no				| create item command(1/4) = the type? and guid being created

	check name?			1900*		0c01	0f00 		{seq_num} {null_term_name} 0000 90c71900 834e2a65 00			create-yes	# before item command; length of message probably varies by length of name
	create(3/4) 		4100		0102	0f00 		{seq_cr#) {understood waypoint structure starting with length1) 			sends well understood waypoint data starting with length1(35)


The create(4/4) message appears to rely on a context that "we are creating a waypoint", and the semantics of the command,
which is SO similar to a normal get dictionary ... hmmm ... as is the low nibble of low byte (3) implies 'commit', or 'doit'
or something.


# Create Sequence for new waypoint Popa0 uuid(eeeeeeeeeeee0110)

	<--	clear context	0400 		b101	0f00																					# BEGIN CREATE SEQUENCE
	-->					0800		0500	0f00 		00000000 08004500 0f000000 00000800 85000f00 00000000						# common reply
	<--	clear context	0400 		b101	0f00																					# no reply second time
	<--	context ???		0800		0d01	0f00 		16000000 = seq_num															# not sure what context? this might be
	-->					0c00		0900	0f00 		16000000 00000000															# 1st time seen reply to context command
	<-- get waypoint	1000		0301	0f00 		17000000 eeeeeeee eeee0110													# try to get the uuid being create
	-->					0c00		0600	0f00 		17000000 030b0480 															# not 0000400=failure; may see 030b0480 often?
	<--	check name?		1900		0c01    0f00 		18000000 506f7061 30000000 90c71900 834e2a65 00								........Popa0........N*e.
	--> doesn't exist	1400		0800	0f00 		18000000 030b0480 00000000 0000000											# there's that 030b0480 again; maybe slot 0 significant?

	<-- create(1/4)		1000		0701	0f00 		19000000 eeeeeeee eeee0110													# start create sequence
	<-- create(2/4)		1400		0002	0f00 		19000000 eeeeeeee eeee0110 01000000
	<-- create(3/4)		4100		0102	0f00 		19000000 35000000 9e449005 ecdbface c16a9f06 ad4a84c5 ...					# data=clear nav+common WP record starting at length1(3500000) lat(9e449005) lon(ecdbface) ends on name (no comment, no RG uuids)
	<-- create(4/4)		1000		0202	0f00 		19000000 eeeeeeee eeee0110 													# finished/commit?

I got an event in shark at this point

	shark event 		1000		0700 	0f00		eeeeeeee eeee0110 00000000 													# 0700 = notify new waypoint?

as the E80 responded to RNS

	--> item created?	0c00		0300	0f00 		19000000 00000400 10000700 0f00eeee eeeeeeee 01100000 0000					# 00000400 success signature, see the UUID in it

After which RNS does a readback check

	<-- get waypoint	1000		0301	0f00 		1a000000 eeeeeeee eeee0110

and the E80 replied by sending RNS back a typical waypoint record (with 00000400) signature, and 119 length packet waypoint(119)
which precisely follows the well understood waypoint decode method, includng the 00000400 success signature, self ids, etc

	--> 				0c00		0600	0f00 		1a000000 00000400 14000002 0f001a00 0000eeee eeeeeeee 01100100   		  ................................
                                                        00004100 01020f00 1a000000 35000000 9e449005 ecdbface c16a9f06 ad4a84c5   ..A.........5....D.......j...J..
                                                        00000000 00000000 00000000 02010000 000000f2 3c010081 4f000500 00000000   ....................<...O.......
                                                        506f7061 30100002 020f001a 000000ee eeeeeeee ee0110                       Popa0..................


It's length 119 at this point, with
         sig1(0600 0f00)
         seqnum1(1a000000)
         sig2(00000400)
         constant1(1400002)											- starts 1400-0002 'command'
         constant2(0f00)
         seq_num2(1a000000)
         self_id(eeeeeeee eeee0110)
         constant3(01000000) 										sligntly different at 01100100
         length1(4100)=65 matches invariant							- starts 4100-0102 command (which includes exactly the wp name)
         constant4(01020f00)
         seq_num3(1a000000)
         length2(35000000)=53 like I told it, matches invariant
		 followed by the lat,lon, and common waypoint tructure
         that ends after the name(506f706130)=Popa0
         - the 10000202 marker has been added
         - 0f001a00 0000 has been added
         - self_id(eeeeeeee eeee0110) has been added

It is interesting to note that in decomposing this message if we took the first 0c00 (12 bytes), that
would include the 00000400 success signature:

	0c00-0600 0f00 1a000000 00000400

what then follows looks like it has the same structure as a
"1400 - 0002 0f00 {seq_num=1a0000) {uid uid} 1a000000" command,
except that instead of 1a000000 the constant3(01000100) is passed

	1400-0002 0f00	1a000000 eeeeeeee eeee0110 01000000

which just happens to match my invariant constant3.

Continuing "4100-0102 0f00" looks like a 0x41=65 byte message,
which would end directly after the waypoint name, and somewhat
coresponds to a "1000-0202 0f00 1a000000 eeeeeeee eeee0110",
"get_waypoint" message, instead of containg a requested {uuid} after the
seq_num(1a000000), in this case, this record contains the length2(35) dword,
then lat, lon, and then a common waypoint record, that ends with the name.

And weirdly, finally, the 'signature' I've been using to detect the ends of
uuid lists, 10000202, which is (always?) followed by 0f00, would then
correspond to a "get_waypoint" 1000-0202 0f00 {seq_num} {uuid} messaage of
16 bytes that includes the self-uuid

	1000-0202 0f00 1a000000 eeeeeeee eeee0110

**THIS IS WHEN I REALIZED THAT REQUESTS AND REPLIES ARE MADE OF MULTIPLE MESSAGES**

- the 0c00 reponses actually refer to the FIRST part of the response.
  where subsequent parts must be parsed as a stream
- we are communicating 'records' back and forth, not command/replies,
  where the 'command word' indicates the status of the record in some
  way, and the record may be something like a context, dictionary
  wp, route, or group, as we are building, and reflecting some data
  structure.


##  Analysis

	semantic			command		operation bitwise
	guess				word

	erase context		b101		0001
	erase context		b201		0010
	context (waypoint) 	0001		0000
	context (route) 	4001		0000
	context (group) 	8001		0000
	context (???)		0d01		1101
	commit context 		0002		0000
	create (2/4)		0002		0000
	set buffer			0102		0001
	set buffer			0102		0001
	set buffer			0102		0001
	set buffer			0102		0001
	set buffer			0102		0001
	get dictionary		0202		0010
	create(4/4)			0202		0010
	get waypoint		0301		0011
	get route			4301		0011
	get group 			8301		0011
	create(1/4)			0701		0111
	check name?			0c01		1100
	create(3/4) 		0102		0001


	operation notes

		I never send an operation(6)
		but all wp, route, and group items have this in their reply signature


	wxyz	command
	4301	Get Route

	w 		class
			0 = waypoint / default
			4 = route
			8 = group
			b = 1011 = all classes?

	x		operation (bitwise)
			0
			1
			2
			4
			8
	y		always zero

	z		item/dictionary?
			1 = item
			2 = dictionary



--------------------- THOUGHTS FOLLOW --------------------------------



## Command Structure

Commands are sent to the server preceded by a word that indicates their length
This command gets a dictionary (a listing of the uuids) for WAYPOINTS, ROUTES,
or GROUPS depending on the context set by preceding commands.

	tcp(2)  10.0.241.54:2052 <-- 10.0.241.200:52811		1000
	tcp(16) 10.0.241.54:2052 <-- 10.0.241.200:52811		02020f00 01000000 00000000 00000000

The command takes place in two separate TCP sends.
The first word above 1000 (0x0010) is the length of the sentence, 16 bytes, that follows.
The actual command sentence is the four dwords that follow.

	command	 seq_num  params......
	02020f00 01000000 00000000 00000000

The command dword itself consits of a word 0202 followed by the func(15)=0f00
Rembmer that the hex stream is byte flpped.

The command appears to be broken up as follows

	WXYZ
	0202

In practice I only have the vaguest clue of the semantics

It is likely that the high byte YZ is the command itself.
W appears to be, in the case of the "get item" command,
an indicator of what to get

	get_waypoint	= '1000'.'0301'.'0f00'.'{seq_num}'.'{uuid}';
	get_route		= '1000'.'4301'.'0f00'.'{seq_num}'.'{uuid}',
	get_group 		= '1000'.'8301'.'0f00'.'{seq_num}'.'{uuid}',

W=0 for waypoint, W=4 for route, and W=8 for group
X=3
YZ=01




## GET ALL WAYPOINTS

The conversation starts with

	tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52811	0c00
	tcp(12)   10.0.241.54:2052     --> 10.0.241.200:52811	b0000f00 00000000 08000000
	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811	0800
	tcp(8)    10.0.241.54:2052     <-- 10.0.241.200:52811	00010f00 01000000
	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811	1400
	tcp(20)   10.0.241.54:2052     <-- 10.0.241.200:52811	00020f00 01000000 00000000 00000000 1a000000
	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811	3400
	tcp(52)   10.0.241.54:2052     <-- 10.0.241.200:52811	01020f00 01000000 28000000 00000000 00000000 00000000 00000000 00000000
															10270000 00000000 00000000 00000000 00000000
	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811	1000
	tcp(16)   10.0.241.54:2052     <-- 10.0.241.200:52811	02020f00 01000000 00000000 00000000

At which point the E80 returns the **Waypoint Index**

	tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52811   0c00                                                                      ..
	tcp(158)  10.0.241.54:2052     --> 10.0.241.200:52811   00000f00 01000000 00000400 14000002 0f000100 00000000 00000000 00001900
															00006800 01020f00 01000000 5c000000 0b000000 [d18299aa f567e68e] 81b237a6
															37008ff4 81b237a6 36002a9d 81b237a6 3700208c 81b237a6 36001996 81b237a6
															370014d0 81b237a6 3600b880 81b237a6 35008a98 81b237a6 34007ff8 81b237a6
															3500818a 81b237a6 3500478a 10000202 0f000100 00000000 00000000 0000

Then it appears as if it gets the uint32's pairs starting with d18299aa f567e68e (14th and 15th uint32's, 1 based)
from that 0c00 packet and sends a 1000 packet with those bytes, iterating over the subsequent uint32 pairs,
which I now call, combined, the UUIDs

	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811   1000                                                                      ..
	tcp(16)   10.0.241.54:2052     <-- 10.0.241.200:52811   03010f00 02000000 d18299aa f567e68e                                       .............g..
	tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52811   0c00                                                                      ..
	tcp(131)  10.0.241.54:2052     --> 10.0.241.200:52811   06000f00 02000000 00000400 14000002 0f000200 0000d182 99aaf567 e68e0100   ...........................g....
															00004d00 01020f00 02000000 41000000 ef488405 48dbf4ce 72069106 64217dc5   ..M.........A....H..H...r...d!..
															00000000 00000000 00000000 026100ff ffffff62 d700007b 4f000900 01000000   .............a.....b....O.......
															43726973 746f6261 6cd38299 a1f567e6 8e100002 020f0002 000000d1 8299aaf5   Cristobal.....g.................
															67e68e                                                                    g..

	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811   1000                                                                      ..
	tcp(16)   10.0.241.54:2052     <-- 10.0.241.200:52811   03010f00 03000000 81b237a6 37008ff4                                       ..........7.7...
	tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52811   0c00                                                                      ..
	tcp(120)  10.0.241.54:2052     --> 10.0.241.200:52811   06000f00 03000000 00000400 14000002 0f000300 0000[81b2 37a6]3700 8ff40100   ........................7.7.....
															00004200 01020f00 03000000 36000000 23cf8605 7e9200cf 790e9406 971b8bc5   ..B.........6...#.......y.......
															00000000 00000000 00000000 02ffffff ffffff3a 8d00007e 4f000600 00000000   ...................:....O.......
															506f7061 30311000 02020f00 03000000 81b237a6 37008ff4                     Popa01............7.7...
And so on ...

	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811   1000                                                                      ..
	tcp(16)   10.0.241.54:2052     <-- 10.0.241.200:52811   03010f00 04000000 81b237a6 36002a9d                                       ..........7.6.*.
	tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52811   0c00


# NEW

The following <fe> is the result of a folder change.
I believe the [0b] is the length of the waypoint name 'Waypoint 12' (it doesn't have an 'A')

uuid(81b237a63900e6cc)
134   -->06000f000800000000000400140000020f000800000081b237a63900e6cc01000000500001020f000800000044 >>>
wp(6)
   000000 (0)          06 00 0f 00 08 00 00 00 00 00 04 00 14 00 00 02    ................
   000010 (16)         0f 00 08 00 00 00 81 b2 37 a6 39 00 e6 cc 01 00    ........7.9.....
   000020 (32)         00 00 50 00 01 02 0f 00 08 00 00 00 44 00 00 00    ..P.........D...
   000030 (48)         1e e5 89 05 b8 60 09 cf 35 c3 97 06 fc 9c 95 c5    .......5.......
   000040 (64)         00 00 00 00 00 00 00 00 00 00 00 00 00 ff ff ff    ................
   000050 (80)         ff ff ff 00 00 00 00 00 00 00[0b]01 00 00 01 00    ................
   000060 (96)         57 61 79 70 6f 69 6e 74 20 31 32 41 ee 82 99<fe>   Waypoint 12A....
   000070 (112)        f5 67 e6 8e 10 00 02 02 0f 00 08 00 00 00{81 b2    .g..............
   000080 (128)        37 a6 39 00 e6 cc}                                 7.9...
(9544,4)  NET/r_NAVQRY.pm[98]               ERROR - waypoint(6) uuid(81b237a63900e6cc) changed at byte(111) old(d3) new(fe)

When the length of the waypoint name changes, the length of the packet changes.
Changing the sort position of the name within the list caused all waypoints after
	its old position to experience 3 byte changes, so I believe a sort order, perhaps
	within 'all waypoints', and perhaps within it's folder
There appears to be an event when a waypoint starts editing, perhaps a lock.
Another event when a waypoint has changed.  Perhaps an updated dictionary.
I suspect the last eight bytes in {} are (part of) the uuid of the group it belongs to.

I got this message when I changed the name of the waypoint. Which changed its position.
The UUID is clearly in the message. I got it again when I quit editing the waypoint

36    -->10008700 0f0081b2 37a63900 14d00200 00001000 07000f00 81b237a6 3900e6cc   ........7.9...............7.9...
         02000000

The length of the waypoint changed from 134 to 126 when I moved it from group2 to my waypoints.
Perhaps my waypoints is just a default.



#		All commands
#	init_c	0800	b0010f00	00000000
#	start_c	0800	00010f00 	01000000
#	negot1	0800	b0010f00	05000000	this is why RNS switches to 6 for the next WP NN
#	negot2	0800	b0010f00	07000000
#			1400	00020f00	01000000	00000000	00000000	1a000000
#			3400	01020f00	01000000	28000000	00000000	00000000	00000000	00000000	00000000	10270000	00000000	00000000	00000000	00000000
#	dict_c	1000	02020f00	01000000	00000000	00000000
#	wp_c	1000	03010f00 	NN000000 	{UUID1}		{UUID2}
#			NN = 02,03,04,06,08

#		All replies
#	init_r	0c00	b0000f00 	00000000 	0b000000
#	negot1r	0c00	b0000f00	05000000
#   negot2r 0c00	b0000f00	07000000
#	dict_r	0c00	00000f00 	01000000 	00000400	14000002	0f000100	00000000	00000000	00001900	00000002	01020f00	01000000	f4010000	53000000

#	wp_r	0c00	06000f00 	02000000 	00000400 	14000002	0f000200	00000d00	00000000	00000100	00005000	01020f00	02000000 	44000000
#	wp_r	0c00	06000f00 	03000000 	00000400 	14000002	0f000300	00000e00	00000000	00000100	00005000	01020f00	03000000 	44000000
#	wp_r	0c00	06000f00 	04000000 	00000400 	14000002	0f000400	00000f00	00000000	00000100	00005000	01020f00	04000000 	44000000
#	wp_r	0c00	06000f00 	06000000 	00000400 	14000002	0f000600	00001000	00000000	00000100	00005000	01020f00	06000000 	44000000
#	wp_r	0c00	06000f00 	NN000000 	00000400 	14000002	0f00NN00	00001100	00000000	00000100	00005000	01020f00	NN000000 	44000000

# generalized (I notice a sequence at the second N)
#                   | sig -------------------------|                                                                length								offset
#	(134)	0c00	06000f00   [NN000000] 	00000400 	14000002	0f00[NN00	0000][UUID  UUIDUUID   UUID]0100	00005000	01020f00	[NN000000] 	44000000  route and group
#	(131)	0c00	06000f00   [NN000000] 	00000400 	14000002	0f00[NN00	0000][UUID  UUIDUUID   UUID]0100	00004d00	01020f00	[NN000000] 	41000000  group
#	(122)	0c00	06000f00   [NN000000] 	00000400 	14000002	0f00[NN00	0000][UUID  UUIDUUID   UUID]0100	00004400	01020f00	[NN000000] 	38000000  no group or route

# 0		0x50 = 80		0x44=68
# -3	0x4d = 77		0x41=65
# -12	0x44 = 68		0x38=56
#
# So it looks the offsets are dropping directly in correspondence to the record size as they are missing a route, group, or both
# I don't quite understand why those number though.  Why -3 bytes when not part of a route?  And an additional odd number 9 when not part of a route.
# None of my placemarks are currently in more than one route.
#
# (136) Popa10, Waypoint PA102
# (135)	Popa00 - Popa09, Starfish (in Route and Group 'Bocas'), Waypoint PA02, Waypoint PA08
# (120) Popa02,03,05,08]
# (121) Popa041
# (125) Waypoint15
# (127) Waypoint PA01
# (128) Waypoint PA011


#
# I'm thinking that the lone word is a request/reply "type" word encoded in binary
# 	That the next word is the command (i.e. b0010f00), the following word is just
# a sequence number (00000000) and that certain commands include following data.
# 	NAVQUERY is func(15) and I don't see any obvious self referencing of the func
# 	in the command as I did in the FILESYS udp stuff.
# The 3400 commannd in paricular
# and furthermore 0c00 means "nothing"



# Thus far I have seen that the dictionary grows.
# It was 182 bytes with 15 waypoints, and is now 190 bytes
#     with 16 waypoints.  Based on the fact that a typical
#     packet has been limited to 1K, there might be a multi
#     record scheme, but, since this is TCP, perhaps it just
#     grows as big as needed.
# It will get really messy, but I'm going to try to import
#     all my nav waypoints into RNS and see how it changes.
# A shitload of waypoints appeared on the E80. Most are probably
#     hiddin in RNS.  I got a bunch of big notification
#     events in shark, one of them 2088 bytes, so I suspect
#     there will only be one wp_dict, but now it will be
#     huge.
# Quit RNS.


# The dictionary record appears capable of holding 16 uuids,
# but always contains the $DICT_END_RECORD_MARKER so is capable
# of holding 15 actual waypoint uuids.

			#		01000000 00000400
			#		14000002 0f000100
			#		00000000 00000000
			#		00001900 00000002
			#		01020f00 01000000
			#		f4010000 53000000




					# We got a reply for a waypoint request, but it failed.
					#
					# The last one that succeeded is WP(61) uuid(81b237a637008ff4)            Popa02
					#
					# The one that fails is b40001020f000100 at offset 548, which is
					# not a real waypoint uuid (i'm pretty sure).
					# I see that 0001020 pattern.
					# The ones after that need to be "pushed back" by 4 bytes
					# to start lining up again.

					# So the first thing I will do is just try to skip the b400 word
					# by adding 2 to the offset at 548 while raw parsing the uuids

					# I tried skiping it and continuing, but I kept getting
					# more invalid responses.  This leads me to think that the
					# request needs to change on waypoint 61.  The request is
					# 		03010f0040000000b40001020f000100
					# I doubt that the 4000 0000 sequence number is too much
					# Lets see if, and how RNS requests it.
					# RNS appears to (a) go slower (b) renegotiate several times,
					# (c) get a different and bigger dictionary at some point,
					# and (d) use a different command 83010f00 instead of 03010f00
					# for some waypoints, but does appears to request Popa02 the
					# same as the others.
					# Slowing my loop down did not help




			# in parsing this packet, I think there is a total number of waypoints at the dword in brackets
			#
			# parsing wp_dict(182): 00000f000100000000000400140000020f0001000000000000000000000019000000800001020f000100000074000000[0e000000]
			#        uuids-->       d18299aaf567e68e81b237a637008ff481b237a636002a9d81b237a63700208c81b237a63600199681b237a6370014d081b237a63
			#						900e6cc81b237a639001acd81b237a63600b88081b237a635008a9881b237a634007ff881b237a63900a72b81b237a63500818a81b237a63500478a
			#	end packet flag --> 100002020f00010000000000000000000000
			#
			# I suspect there is a way to ask for the next bunch of waypoints.
			# Also, by way, I think there's a folder associated with each waypoint.


			# So the first thing I will do is just try to skip the b400 word
			# by adding 2 to the offset at 548 while raw parsing the uuids
			# Now I think we need to jump to offset 560, that there are 12 bytes
			# inserted here (to get us back to the uuid that sarts tith 04, conitinuing that sequence)
			# Now I think its 14 bytes.
			#
			# That got it to stop parsing after 74 uuids and succesfully retrieve all of them.

			# Why did I think the parsing starts at the 13th dword?  because I recognized a wp uuid there.
			# What if before that there are Group or Route UUIDs?  Hmm .. I have changed the number of
			# routes and waypoints and still always started at dword(13).

			# Once again, I'm getting the feeling the whole thing is organized by UUIDs.
			# Its an odd number because there is a sequence dword at the head of the dict reply
			# Before dword 13, I see the following dwords
			#
			#		01000000 00000400
			#		14000002 0f000100
			#		00000000 00000000
			#		00001900 00000002
			#		01020f00 01000000
			#		f4010000 53000000
			#


