# readme for /base/apps/raymarine/NET

Perl code specific to the my probing and undertanding of SeatalkHS,
Raymarine's proprietary UPD and TCP protocols.  They call it SeatalkHS,
but I just call it **raynet** as I have to type it over and over.


## General Goal

I am not necessarily trying to understand everything about raynet.
The main purport of this effort is for me to be able to do RWT
(Route, Waypoint, and Track) management on the E80 directly from
my laptop, over an ethernet cable, WITHOUT running the **Raytech RNS**
program.  I already have/had a "text based" solution this that
involves (or requires) RNS, as well as swapping CF cards out of the
E80 to my laptop, which is very onerous.  RNS itself is a horrible
program and I have worked very hard to to try get it out of my workflow.

Please see the higher level readme files and the FSH and CSV sibling
folders for more information on my "text based" RWT management solution.


## Desktop Network Configuration

Using the new E80 #1 to the Archer C20–AC750 Router to th Laptop

Starting with the fact that the New E80 shows an IP address of 10.0.241.54,
I configured the Router with an IP address of 10.0.241.254 and the laptop
with a fixed ethernet address of 10.0.241.200.

I figured out how to use a regular shielded ethernet cable in place of
the official shielded rayMarine ethernet cable. See ethernet_cables.md
for more info.

**The Laptop can be connected Wirelessly to the router, but that means
you have to be off the net.**

The router is setup with DHCP but uses address reservation to make sure
that the new E80 at mac address 00:11:C7:00:F1:36 is reserved for
10.0.241.54, and the laptop is at 200.

With this, RNS should come alive and/or when connecting to the E80 simultaneously
with a Seatalk, NMEA0183, or NMEA2000 simulator, I was able to begin deciphering
and/or learning aboutt the various protocols coming over the wire.


## Protocols and Naming Things

For lack of any official terminology, I have had to learn what comes and goes
over the wire, discern patterns, and break the traffic into a number of protocols,
each of which is explored in more detail in various programs and subsequent
readme files.

- raynet is the sum total of all UDP and TCP that comes and goes over the wire

The first, and practically only. clue I had when getting started was an
open source OpenCPN plugin that could (apparently) connect a Raymarine
Radar plugged into an E80 MFD to OpenCPN running on a Raspberry pi called
"RMRadar_pi" in a public github repo.  For completeness I have included a
zip file of that repo in the docs/reference folder within this folder.

From RMRadar_pi I learned the first "gateway" protcol of the raynet
protocol stack, that I call **RAY_DP**.  RMRadar_pi itself exposes one
of the sub protocols, entirely in UDP, that I think of as RAY_RADAR, but
have not explored further at this time.

Most of the work I have done involved "getting between" the Raynet RNS
program, running on my laptop, and an E80, on my desk, using tools like
wireShark and subsequently Perl programs that I wrote.

In a sense, raynet exposes a number of **virtual devices** that each have
various IP addresses and ports associated with them, and which, as far
as I can tell, use similar, but different packets in their communication.
Inasmuch as the purport of my efforts is to understand the **packets**
so as to learn to listen to and control the devices, my focus is on
the protocols, the packets, themselves.

It is likely that (much) later, I will come up with a better understanding
of "devices" versus "protocols". At this time the definition is rather fluid
and I use both terms as is convenient in my descriptions that follow.

The protocols I have thus far explored in some detail, and named, are as follows.

- *RAY_DP* - Raynet UDP multicast Discovery Protocol at 224.0.0.1:5800

**RAY_DP** is the very top level SSDP like protocol by which raynet exposes
the virtual devices, each with their own protocols, using multicast UDP.
By joining the multicast group at the above IP address and port, and listening
to UDP packets, subsequent virtual devices and protocols are discovered
and accessed. See **raynet.md** and the **raynet.pm** program for more
details about what I learned about this protocol.

- **E80_NAV** - is a multicast UDP protcol that appears to be sent by the
  E80 that contains basic Navigation information, like the lat/lon, heading
  speed of the boat, time of day, etc.  Although it would probablly be better
  called RAY_NAV, as it is probably also supported by other Raymarine MFD's
  and devices, I first decoded it on my E80 and the code that is already
  written currently refers to it as E80_NAV. See **e80.pm** and **ray_E80.pm*
  for more information.
- **E80_TCP** - is the holy grail I am trying to crack.  I have indications
  that RNS communicates Routes and Waypoints to and from the E80 using TCP
  at a particular IP address and port.

The IP addresses and ports for E80_NAV and E80_TCP are discovered by
monitoring the RAY_DP multicasts. Though they appear to be somewhat
fixed, based on the IP address shown by the E80 "Setup-System Diagnostics-
External Interfaces-SeatalkHS" dialog on the E80, I prefer here
to omit those addresses and will show my examples in the raynet.md
readme file.


## Programs

As of this time I have written a few programs to probe, explore, and
learn to control raynet and the E80.  This list is entirely in flux
as I am in the middle of this project.  At this time these are
the programs:

- raynet_old.pm - my first effort to probe RAY_DP, which then grew
  to also start decoding E80_NAV.  It currently consists of the
  files:
  - ray_UI.pm - a somewhat general approach to prenting a screen
    like UI in a Windows Console (Dos Box)
  - ray_E80.pm - a screen oriented program to understand and
    display various packets of E80_NAV that I learned abut.
- tcp_old.pm - my first (failed) attempt to connect to the E80 via TCP.
  I am currently keeping this because it has a handshaking clue
  where a unicast packet is sent to the E80 telling it what
  unicast address to send a subsequent packet to.
- shark_old.pm - a perl wireShark parser and monitor that gave
  me my first breakthrough in E80_TCP, and which will likely
  grow into the real program.

It is very possible that I will write a wxPerl app as the communication
grows too complex to capture and manipulate on a dos box console screen.
I like the dos box for the time being because it can display a lot of
information and be easily zoomed in and out.


## Wireshark (tshark) vs actual multicast UDP and TCP sockets

**tshark** is a CLI interface to wireShark that can be used via
a pipe from within a Perl program.

raynet_old.pm makes use of actual multicast UDP sockets to obtain and
parse RAY_DP and E80_NAV packets.   In the end, any actual program
for RWT management will also make use of actual UDP and TCP sockets.

But, for exploring and understanding how raynet works, it turns out
that using tshark within a perl parser has many advantages, including
allowing me to sniff non-multicast communications between RNS and the
E80, record sessions, and so on.

So the next verson of raynet.pm will be based on tshark.











