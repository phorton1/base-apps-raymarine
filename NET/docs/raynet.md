# RAYNET — Protocol Architecture

**[Home](../../docs/readme.md)** --
**[NET](readme.md)** --
**RAYNET** --
**[RAYDP](RAYDP.md)** --
**[WPMGR](WPMGR.md)** --
**[TRACK](TRACK.md)** --
**[FILESYS](FILESYS.md)** --
**[DBNAV](DBNAV.md)** --
**[shark](shark.md)** --
**[Cables](ethernet_cables.md)**

**RAYNET** is the working name for Raymarine's **SeatalkHS** ethernet protocol
suite. Raymarine does not publish technical documentation for these protocols;
all content here was derived from packet capture and probing.

**RAYDP** (Raymarine Discovery Protocol) is the service discovery protocol
within RAYNET — the multicast protocol at 224.0.0.1:5800 through which devices
advertise their services. It was called **RAYSYS** for a time in this codebase
to match the Raymarine "Sys" label in the E80 diagnostics dialog, but has been
renamed back to RAYDP. References to RAYSYS in older notes and probe files mean
RAYDP.

Communications on **RAYNET** are framed in terms of *Requests and Replies*,
that consist of *Messages*, that happen on a particular **ip:port**,
using a specific internet protocol, **tcp, udp, or mcast**.
Requests and Replies may also be termed as *Broadcasts* or *Events*,
respectively, in the context of this discussion.

The entry point into RAYNET is the **RAYDP** discovery protocol at
the known mcast address **224.0.0.1:5800**, and working with RAYNET
requires that one sets up a multicast listener on that address
and processes the advertisement broadcast messages that are sent
**to** that multicast address.

RAYNET is composed of one or more *Devices* that advertise themselves
via the RAYDP discovery protocol with an *IDENT* message.
Each Device then advertises one or more *service_ids* (whose correspondence
to Raymarine service names has not been fully established),
that the Device supports.

Each **service_id** advertisement message contains one or more *ip:port*
combinations for the service_id.  Every advertised port has been identified
to uniquely identify a particular internet protocol, *tcp, udp, or mcast*,
and a particular service_id. The **port** is treated as the identifier for a
*Service Class*, with the ip address determining an *instance* of the
Service Class.

Each ip:port combination represents an instance of a *Service*,
where the port is sufficient to determine (the service_id, and hence)
the *Class* of the service.

Each Service Class utilizes a specific internet protocol and has a
Class specific parser to decode (and possibly use) its messages,
A Service Class, depending on how fully the port has been decoded,
also possibly has methods to build and send Request messages.



### Requests, Replies, and Messages

Typically communications over RAYNET are framed in terms
of Requests made by the Client to the Server, and
Replies received by the Client from the Server.
In the end however, the *Protocols* Requests and Replies
will be understood in terms of **Messages** making up
those Requests and Replies.
The notion of *Messages* will be described more fully below.


#### Events and Broadcasts as Replies

Replies may be received by the Client in the absence of
any Request, in the form of **Events**.
Also, **broadcast messages** sent *to* a multicast port can be
thought of as Replies, to the degree that, although they were sent
to the multicast port, they are received and processed by the Client.
In the following, a Request is *anything sent* by the Client
**to** the Server, and a Reply is anything *received* by the Client
**from** the Server.


#### udp/mcast Messages are a single packet

**udp/mcast Requests and Replies** consist of a single
*Message* that is entirely contained in a single internet
packet. The length is of the message is the length of
the internet packet.

	<message> == internet packet with implied length


#### tcp Messages are sent and received in groups

**tcp Requests and Replies** consist of at least one Message
but may contain several Messages, where each message
is preceded by a &lt;length> word that allows for deserializing
the Reply or Request into an ordered array of Messages.
tcp Requests are generally sent in a single internet packet,
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
and object classes (Perl packages) that may or may
not have been implemented yet.


### Parsing and Monitoring

There is a base class Parser that can handle the basic
parsing of internet packets into a series of one or more messages
and can monitor (display) the raw bytes in the payloads
as a series of dwords with ascii to the right.

It then passes the undecoded messages (Request or Reply)
to a service specific Parser, if available, which can then, possibly,
decode the message into a meaningful semantic structure (record)
for use by the Client Service Instance or to
validate outgoing Requests.

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

A RAYNAME is a unique identifier per PORT associated with a
particular service_id. The convention follows a maturity tier:

	ALLCAPS = a mature port with at least partially decoded replies;
		typically fully probed with known communication patterns.

		RAYDP		- mcast
		WPMGR		- tcp
		TRACK		- tcp
		FILESYS		- udp
		DBNAV		- mcast from Database; partially decoded
		MY_FILE		- udp FILESYS listener port used by shark; can be monitored
		FILE_RNS	- udp RNS's FILESYS listener port; identified and can be monitored

	Capitalized = a port associated with a known Raymarine service
		(as displayed in the E80's ethernet Services dialog box),
		believed to be the primary client API (typically tcp)
		of the service.

		Alarm		- mcast
		Database	- tcp
		Navig		- tcp

	lowercase = a port which is either a secondary client
		API to an identified Service (udp/mcast), or a
		placeholder that identifies its state of maturity;
		not extensively probed

		alarm		- udp
		database	- udp
		func8_m		- mcast
		func8_u		- udp
		func22_t	- tcp
		func35_m	- mcast
		func35_u	- udp
		hidden_t	- tcp

	Question Mark

		A question mark may be appended to a Capitalized or lowercase
		RAYNAME when there is a speculative association with a known
		functionality or E80-advertised service.




---

**Next:** [RAYDP](RAYDP.md)
