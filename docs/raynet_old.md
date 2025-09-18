# Raynet (SeatalkHS / ethernet)

This readme details what I have learned about Raynet
and other SeatakHS protocols.

I use the term RAYNET specifically for the udp multicast
protocol at 224.0.0.1:5800, or more genericall, as Raynet
to talk about the system as a whole.

There are likely to be a number of different protocols
explored in this project.

My goal is to do Route, Waypoint, and Track managment
in some other way than my current text based approach.

Thus far I have made zero progress towards that goal,
but I have been able to somewhat decipher the RAYNET
messages and some E80_NAV messages.   I have proven
that I can change the depth on the E80 with my Seatalk
interface, and find it in the E80_NAV udp multicast
protocol at

	RAYNET_MULTICAST = 224.0.0.1:5800
	E80_NAV MULTICAST = 224.30.38.195:2562.

## RAYNET packets

I have deciphered the following packets from, but not sent any to
RAYNET_MULTICAST protocol at 224.0.0.1:5800

This protocol appears to be an SSDP-like search and discovery
protocol, where "devices" advertise themselves and how to connect
with them.   The first clue came from the radara program.

In RMControl.cpp, GetNewDataSocket() opens the "reportSocket",
and the method ProcessReport() to parse it into a Structure
from which the ip anddress and port of the "radar' multicast
can be found.

	struct SRMRadarFunc {
		uint32_t type;
		uint32_t dev_id;
		uint32_t func_id;	// 1
		uint32_t something_1;
		uint32_t something_2;
		uint32_t mcast_ip;
		uint32_t mcast_port;
		uint32_t radar_ip;
		uint32_t radar_port;
	};

I found that if I generally treated RAYNET packets as arrays of uint32_t's,
I could somewhat decipher almost all of the udp packets from RAYNET
Here are all of the known raynet packts I have seen, by length and type:

	length(28) func(7)  x(1966081,526342)  addr(10.0.241.54:2054)
	length(28) func(19) x(1966081,526341)  addr(10.0.241.54:2053)
	length(28) func(22) x(1966081,526343)  addr(10.0.241.54:2055)
	length(36) func(27) x(1966081,1054378) mcast(224.0.0.2:5801) dev(10.0.241.54:5802)
	length(36) func(35) x(1966081,1050624) mcast(224.30.38.193:2560) dev(10.0.241.54:2048)
	length(37) func(5)  x(1966081,1116161) mcast(224.30.38.194:2561) dev(10.0.241.54:2049) flags(1)
	length(40) func(16) x(1966081,1312770) tcp?(10.0.241.54:2050:2051) e80_mcast(224.30.38.195:2562) !!!
	length(54) UNPARSED KNOWN E80_INIT_PACKET
	length(56) UNDECODED message appears to have the known E80 ip adddress

The most immediately pertinent thing is that one can get the E80_NAV multicast address
224.30.38.195:2562 from the length(40) packet.  The ip addresses and ports in the above
are useful to try to understand the conversation between RNS and the E80.

### RUNNING RNS

When running RNS against an "inactive E80" (I am not sending any seatalk, no fix, no sensors),
at some point, after sending the wakeup packets to the E80, it appears to"

- RNS joins the length(37) multicast group 224.30.38.194 (by sending to 224.0.0.22, the E80 DHCP server?)
- RNS sends a (grey) 10 byte UDP pcket to the length(37) dev at 10.0.241.54::2049 (E80) "09010500000000000048"
- E80 sends a 39 byte packet to RNS at port(18432=0x48c8) that contains the text "14802A08 W79223"
- RNS sends the same long 54 byte (keep alive?) packet to $REPORT_GROUP/PORT
- RNS joins the length(37) multicast group again
- RNS sends a new 36 byte packet to  to $REPORT_GROUP/PORT
  "00000000ffffffff1b00000001001e00aa161000020000e0a9160000c8f1000aaa160000"

The 54 byte and new 36 byte packet are sent to the E80 frequently, apparently as a keep alive ...
Then comes the first TCP packets

- RNS Sends to 10.0.241.54:2050, the first length(40) tcp port, and I kind of have to assume
  that is "map tile request" traffic

A UDP packet to 10.0.241.54:2049 looks like a request for \chartcat.xml


### Classifying UDP and TCP addresses

Here are the main IP addresses presented by the RAYNET search and discovery that
I have decoded, and, where possible, my idea of what kind of virtual device they represent:


- length(28) func(7)  addr(10.0.241.54:2054)
- length(28) func(19) addr(10.0.241.54:2053)
- length(28) func(22) addr(10.0.241.54:2055)
- length(36) func(27) mcast(224.0.0.2:5801) dev(10.0.241.54:5802)
- length(36) func(35) mcast(224.30.38.193:2560) dev(10.0.241.54:2048)
- length(37) func(5)  mcast(224.30.38.194:2561) dev(10.0.241.54:2049) flags(1)
- length(40) func(16) tcp?(10.0.241.54:2050:2051) e80_mcast(224.30.38.195:2562) -
  *E80_NAV* - This appears to be the E80 broadcasting standard navigation info, and
  I will call this E80_NAV. It has been extensively probed and I am begining to see
  a pattern to the broadcast messages.




## E80_NAV udp

As mentioned above, I am calling the following multicap address as
**E80_NAV**

	224.30.38.195:2562

Here I document my initial attempts to get the Date/Time, Heading,
and Depth. **In raynet.pm** I have now succesfully decoded:

- Date and Time
- Depth
- Heading/COG
- SOG
- Latitude and Longitude

Having prototypes for these embedded data types may be useful
as I try to understand other protocols, searching for Route
and Waypoint managment solutions.



### Date/Time

In the 01031000030000001200 message, I believe the date and time are in the
start of the message.

The Raymarine starts sending this, and the 00031000050000001300 message as soon
as it boots.


### Heading

In the 00031000020000001700 00002a00 0200[3a01] 0f060000 47000000 2a000200 [6903]0906 0000 message
I notice the bracket bytes change when I change the heading, or at offsets 6 and 20, respectively.

I believe the first is with magnetic deviation, and the second is without magnetic deviation.

I proved that, more or less, but now note that my when my Seatalk emulator sends a heading of
0 degrees, that if the E80 System Setup - Variation Source is set to "Auto 03W", that the E80
reports a heading of 357 (three degrees to the west of the heading I sent it).

As for the units?  Perhaps there is a clue in the radar or NMEA2000 code.
Using the second heading:

Heading(0) = 0
Heading(1) = 175
Heading(2) = 349
Heading(3) = 534
...
Heading(357) = 62308
Heading(358) = 62483
Heading(359) = 62657

In a talk with co-pilot, it was determined that the units are RADIANS*1000,
so to convert them, we first divide by 10000 and multiply by 180/pi.

The E80 sends out Heading without any other information, in other words if
ALL I send to the E80 is the Seatalk Heading message, it shows on the E80
AND gets sent out as the above message over ethernet.


### Depth

Unlike the heading, I do not start receiving the UDP messages for depth until
I send Lat/Lon and .... cog?

In the following message:

change 00031000170000000300 0000010002000000090600000400000001000200000009060000090000000e000400[31010000]09....

The depth is the bracketed uint32_t, in 100/s of a meter.


## E80_NAV packet classification

Given a "key" like '00031000040000000300', I believe there are three fields,
organized something like this:

	  device    version    type
	(00031000) (04000000) (0300)

Where the 'type' defines a "kind" of navigation message, i.e.
"rapid" versus "info" versus "heartbeat", and the 'version" indicates
increasingly large records of the type, where higher versions are
typically inherited from lower versions.

More accurately, the UDP is intended to be parsed as a stream, as,
although *typically* there is an apparent inheritance scheme, there
are also cases where fields appear to get inserted into the middle
of records in higher versions.

- type(300) - appears to be the most common generic NAV_INFO record,
  typically including most of the navigation information
- type(400) - appears similar to type(300)
- type(900) - similar to type(300)
- type(1200) - apears to be (mostly) a date-time heartbeat
- type(1700) - appears to be a rapid update, with heading


Here's a table of the types, and versions I have seen


	type	version		length		hierarchy	known fields
	300		04			60			base		SOG(6), HEAD(DEV,34)
	300		05			74			inherits	SOG(6), HEAD(DEV,34)
	300		06			94			inherits	SOG(6), HEAD(DEV,34)
	300		0a			151			inserts
	300		11			249			inserts
	300		17			332			inserts

	400		09						base		SOG(6), HEAD(DEV,50), HEAD(ABS,78)
	400		0b						inserts		SOG(6), HEAD(DEV,50), LATLON(78), HEAD(ABS,98)

	900		06									DEPTH(6)
	900		08									DEPTH(6), HEAD(DEV,36), HEAD(ABS,64)

	1200	02									TIME(6), DATE(22)
	1200	03			48

	1700	01			12
	1700	02			26			inherits	HEAD(DEV,6), HEAD(ABS,20)

### Summary thus far

See the file ray_E80.pm for my latest/best guess at the data structures and
inheritance scheme for the various types and versions of the UDP packets
output by the E80.
