# RAYNET — Protocol Architecture

**[Home](../../docs/readme.md)** --
**[NET](readme.md)** --
**RAYNET** --
**[RAYSYS](RAYSYS.md)** --
**[WPMGR](WPMGR.md)** --
**[TRACK](TRACK.md)** --
**[FILESYS](FILESYS.md)** --
**[DBNAV](DBNAV.md)** --
**[shark](shark.md)** --
**[Cables](ethernet_cables.md)**

**RAYNET** is the working name for Raymarine's **SeatalkHS** ethernet protocol
suite. Raymarine does not publish technical documentation for these protocols;
all content here was derived from packet capture and probing.

**RAYSYS** is the service discovery protocol within RAYNET — the multicast
protocol at 224.0.0.1:5800 through which devices advertise their services.
It was originally named **RAYDP** (Raymarine Discovery Protocol) in this
codebase, which better captures its role, but was renamed to match the label
Raymarine uses in the E80's own ethernet diagnostics dialog ("Sys"). References
to RAYDP in older notes and probe files mean RAYSYS.

Communications on **RAYNET** are framed in terms of *Requests and Replies*,
that consist of *Messages*, that happen on a particular **ip:port**,
using a specific internet protocol, **tcp, udp, or mcast**.
Requests and Replies may also be termed as *Broadcasts* or *Events*,
respectively, in the context of this disccusion.

The entry point into RAYNET is the **RAYSYS** discovery protocol at
the known mcast address **224.0.0.1:5800**, and working with RAYNET
requires that one sets up a multicast listener on that address
and processes the advertisement broadcast messages that are sent
**to** that multicast address.

RAYNET is composed of one or more *Devices* that advertise themselves
via the RAYSYS discovery protocol with an *IDENT* message.
Each Device then advertises one or more *service_ids* (that Raymarine
directly relates to a particular Service, but which I do not),
that the Device supports.

Each **service_id** advertisement message contains one or more *ip:port*
combinations for the service_id.  Every advertised port has been identified
to uniquely identify a particular internet protocol, *tcp, udp, or mcast*,
and a particular service_id, so it is this **port** that I associate with a
*Service Class*, with the ip address determining an *instance* of the
Service Class.

In other words, in my current understanding and implementation,
each ip:port combination represents an instance of a *Service*,
where the port is sufficent to determine (the service_id, and hence)
the *Class* of the service.

Each Service Class utilizes a specific internet protocol and has a
Class specific parser to decode (and possibly use) its messages,
A Service Class, depending on the level of maturity of my undertanding
of the port also possibly has methods to build and send Request messages.



### Requests, Replies, and Messages

Typically communications over RAYNET are framed in terms
of Requests made by us (the Client) to the Server, and
Replies received by us from the Server.
In the end however, the *Protocols* Requests and Replies
will be understood in terms of **Messages** making up
those Requests and Replies.
The notion of *Messages* will be described more fully below.


#### Events and Broadcasts as Replies

Replies may be recieved by us (the Client) in the absence of
any Request, in the form of **Events**.
Also, **broadcast messages** sent *to* a multicast port  can be
thought of as Replies, to the degree that, although they were sent
to the multicast port, we (the client) read them and process them.
In any case, please do not let this terminology confuse you.
In the following a Request is *anything sent* by us, the Client,
**to** the Server, and a Reply is anything *received* by us,
as the Client, **from** the Server.


#### udp/mcast Messages are a single packet

**udp/mcast Requests and Replies** consist of a single
*Message* that is entirely contained in a single internet
packet. The length is of the message is the length of
the internet packet.

	<message> == internet packet with implied length


#### tcp Messages are sent and recieved in groups

**tcp Requests and Replies** consist of at least one Message
but may contain several Messages, where each message
is preceded by a &lt;length> word that allows for deserializing
the Reply or Request into an ordered array of Messages.
tcp Requests are generally sent (by us) in a single internet packet,
but are typically received in two internet packets, the first
consisting of the <length> word of the first message in the
following packet, and the second containing the first message,
possibly followed by more &lt;length>&lt;message> pairs.

	<length0>
	<message0><length1><message1>...<lengthN><messageN>


## Message Structure

**Messages** are composed of three parts

	<command_word><service_id_word><payload>

The &lt;service_id> of an incoming message MUST match the
service_id associated with the port, or the message/packet
will be considered an error.
**Error handling is a separate discussion.**

The semantics of the **&lt;command_word>**, a packed uint16_t, depend
n the the particular service_id, but generally
consist of two fields contained in the four nibbles of
the word

	0xDDWC

		DD is the <direction_byte>, or simply 'direction' or <dir> of the
			message, and has been identified with the following values:

			0 = info
				a message that provides additional information within
				the group of messages making up a tcp Request or Reply
			1 = send
				always sent as the first message in a Request
				may occur in Replies (?)
			2 - recv
				always (?) received as the first message in a Reply
				there may be more than one in a given Reply
			3 - mcast (?) not sure
				the typical direction received in mcast packets

		WC is the <command_byte> and its semantics are service dependent.
			The entire byte may be treated as an enumerated Command, or
			the low nibble may be treated as an enumerated Command, with
			the high nibble providing context of What is being talked about

The semantics and structure of the **&lt;payload>** are dependent
on the specific &ltservice_id> and &ltcommand_word> although there are
generalities (similarities) that are leveraged off of in the implementation
of the Service specific Parsers that deal with and/or compose the messages.

### Sequence Numbers and Events/Broadcasts

Many messages contain **Sequence Numbers**, &ltseq_num> or simply &ltseq>,
that are used to tie Replies back to their originating Requests,
so that the client can functionally pair them.
However, not all Requests and Replies contain Sequence numbers,
as some out-of-band Replies may occur as **Events** or mcast **Broadcasts**.

Additionally, some Request/Reply pairs do not contain a sequence
number because they are talking about a global state of the
service, and so the Replies do not need to be paired to
a particular Request.
*note: nonetheless these Request/Reply pairs may, depending on
  the implementation, be validated by the receipt of a Reply
  containing a particular command_byte in response to a Request
  containing a particular command_byte.*

The presence or absence of a &lt;seq_num> is dependent on the
service_id and the particular &lt;command_byte>.



## Implementation Overview

This section of the readme talks about implementation details,
and object classes (Perl packages in my case) that may or may
not have been implemented yet.


### Parsing and Monitoring

There is a base class Parser that can handle the basic
parsing of internet packets into a series of one or more messages
and can monitor (display) the raw bytes in the payloads
as a series of dwords with ascii to the right.

It then passes the undecoded messages (Request or Reply)
to a service specific Parser, if avaialble, which can then, possibly,
decode the message into a meaningful semantic structure (record)
for the use Replies by the Client Service Instance or to
validate outgoing Requsest.

These derived parsers may/will/do implement the ability to
monitor the semantic content of the Requests and/or Replies.


### r_service = Service Base Class

An r_service instance is an object that is identified by a particular
IP:PORT and which is associated with a particular service_id,
and which has a particular internet type (tcp/udp or mcast) and a
particular rayname.

An r_service HAS an r_parser that is specific to the service_id,
which may just be the 'dumb' r_parser base class,
or which may be a more, or totally fleshed out derived r_parser,
depending on the service.

An r_service can HAVE an r_sock, indicating that it is a "real"
Client Service, that calls its method, PRH TODO and which
can Send Requests (which can also just be "Probes") via the socket,
or it can be a Monitor Service, driven, directly, via it's
PRH TODO() method, by the r_sniffer. to merely decode
and monitor both incoming Requests and outgoing Replies
  to/from the given IP:PORT.


### RAYNAME

A RAYNAME is a unique identifier per PORT that is associated
with a particular service_id, that follows a convention depending
on the maturity of my understanding of that port within that service_id
where:

	ALLCAPS = a mature port (r_service) that I understand
		and have at least partially decoded Replies from, but
		more likely have completely probed, understood, and
		know pretty well how to communicate with.

		RAYSYS		- mcast
		WPMGR		- tcp
		TRACK		- tcp
		FILESYS		- udp
		DBNAV		- mcast from Database that I have partially decoded
		MY_FILE		- udp FILESYS listener port that I use, and can monitor
		FILE_RNS	- udp RNS's FILESYS listener port that I have identified, and can monitor

	Capitalized = a port (r_service) for which I have associated
		the service_id with a known "Raymarine Service" (as displayed in
		the E80's ethernet Services dialog box), and which I
		believe to be the primary client API (typically tcp)
		of the service.

		Alarm		- mcast
		Database	- tcp
		Navig		- tcp

	lowercase = a port which is either a secondary client
		API to an identified Service (udp/mcast), or a
		placekeeper that specifically identifies its state
		of maturity, that I have not extensivly probed, nor
		claim to understand

		alarm		- udp
		database	- udp
		func8_m		- mcast
		func8_u		- udp
		func22_t	- tcp
		func35_m	- mcast
		func35_u	- udp
		hidden_t	- tcp

	Question Mark

		I *may* append a question mark to a Capitalized or lowercase
		rayname if I have a speculative belief that it *might* be
		associated with a certain kind of functionality or specific
		E80 advertised service.




---

**Next:** [RAYSYS](RAYSYS.md)
