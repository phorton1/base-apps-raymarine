# The RaynetHS / E80 official Raymarine Ethernet Cable

WHAT IS DIFFERENT ABOUT THE OFFICIAL E80 (SeatalkHS) ETHERNET CABLE?

I saw a lot of (mostly uninformed junk) on the internet about these
cables, and how almost everyone thinks they are downright required to
connect SeatalkHS devices to a router or each other.

Short answer:  A standard shielded ethernet cable WILL work, despite all
that you've read on the internet about how it wont work, or doesn't fit.

Of course, a crossover cable is required to connect two E80's directly
together, and that is not my configuration, so this discussion is about
straight-through ethernet cables, but would apply if you wanted to make
your own cross over cable.

My success arrived, finally, when, on my standard shielded ethernet cable,
which has no "ledge" or "stop" (see below), and which has all 8 pins
connected, I bent back the rubber cover over the plastic locking tab
so that I could push the connector a bit farther into the E80 female.

Upon which it started working and everything became clear to me.

### Insertion Depth (Beware the Ledge)

The RJ45 plug needs to be inserted about 15-16mm into the E80 female for
the pins to make contact. I have seen (purchased, tested, modified
and "fixed") shielded connectors that have a "ledge" or "stop" (on the
side opposite the pins) that prevents the plug from being inseerted more
than about 14mm, just shy of what the E80 needs.

In fact, I bought a bunch of shielded RJ45 connectors and learned to
crimp them.  I took an old unshielded ethernet cable I had that only had
pins 1,2,3 and 6 wired (four conductors) and crimped s shielded connector on it.
It didn't work. But when I took a dremel to the shielded connector and removed
the "ledge" or "stop", so that I could insert the RJ45 plug a few more
mm into the E80, the cable started working.

So, beware shielded cables with "ledges" or "stops" on the side opposite
the pins.

### Waterproof Locking Ring

Apart from that, the female on the E80 does not have a catch for the plastic
locking tab on a standard ethernet cable.  Instead Raymarine used a "waterpoof
locking ring" to force the connector to stay in place.

The Raymarine "waterproof side" shielded RJ45 connector *may* be a little
wider than a standard shielded ethernet connector, but I don't think the
difference is significant. I could just be the years of corrosion on the
particular connectors I ahve.

### Slightly wider?

Probably not significant.

I measured all kinds of cables, including the 3 20 year old official
Raymarine cables I have, and generally found that the widths of all
of them were the same to within a few 1/10's of a millimeter.
Perhaps the official cables were a tidge wider.

- measured width of E80 side of official cable: 11.72 mm (snug fit)
- measured width of standard grounded ethernet cable: 11.67mm (jiggles a little)

I don't, can't, believe that Raymarine is/was depending on 0.01 mm accuracy
in the connectors.

### Shield Detection

I believe that within the female on the E80 there are two metal tabs on the
sides that must make contact with the the shield for the E80 to recognize
the cable and enable its ethernet connection, so a standard non-shielded
cable will not work. Or at least I never got one to work.

I don't believe there are any other interlock protection or magic to the
E80 female apart from the fact that I believe it must make contact on both
sides to the shielded connector.

### Only Four wires

Apart from that, I note that the cable, as bulky as it is, only has
four conductors, and the plugs only use 4 of the 8 RJ56 pins:

	E80 side	standard side	T568A colors	T568B colors	function
		1 			1			white green		white orange	transmit +
		2 			2			green			orange			transmit -
		3 			3			white orange	white green		receive +
		4 			NC			blue 			blue			not used	bi-directional transmit+
		5 			NC			white blue		white blue		not used	bi-directional transmit-
		6 			6			orange			green 			receive -
		7 			NC			white brown		white brown		not used	bi-directional transmit+
		8 			NC			brown			brown			not used	bi-directional transmit-


## Personal Boat Soolutions.

Subitle: Create a 3D printed Waterproof Ring Connector or crimp new RJ45's
to shortened versions of my existing official Raymarine cables?

I think I can 3D print my own "waterproof locking ring", one that
I can attach to the cable in the field, so that I can run a standard high
quality modern shielded ethernet cable through the tight spaces needed to
get to my E80 on the helm (which is in a Pod with barely space to get the
RJ45 through the holes in the stainless steel tubes), and then attach the
waterproof locking ring to keep the cable in place.

Previously I had an entire 1 meter "official" E80 ethernet cable coiled
up in the Pod, that connected to a female-to-female RJ45 adapter, that
connected on the other side to a 20 year old 50 foot radio shack standard
plastic ethernet cable.  Not only did an adapter and 1 meter of cable coiled
up in the Pod bother me, but there was also about 20 feet of the radio shack
eithernet cable of that coiled up on the other end near my "raymarine
ethernet switch".

I will continue to use the raymarine ethernet switch, but have learned
that any ethernet switch, including WiFi routers, will work.

Now that I have learned how to crimp RJ45 connectors, and depending on
how I feel about the 3D printed waterproof locking ring idea and reality,
I *may* cut the end off of one or more of my 3 official Raymarine E80
ethernet cables and make a shorter pigtails.  One would be for use in the
Pod with the same basic female-to-female RJ45 adapter scheme, though
the more connectors, the more chancs of a failure.

I have another E80 at the nav station, and a DSM300.
I will probably continue to use the official Raymarine cable to connect
to the nav station E80, as it is a few feet away from the router, so a
1 meter cable seems ok.

I have not checked if the DSM300 has the same interlock protection,
but know already that it won't hold a standard RJ45 jack without the
waterproof locking ring. My DSM300 is only a few inches from the Router
and I don't really like to have a 1 meter cable coiled up for that, so,
hence, I *may* cut another one of my my official Raymarine cables shorter,
and crimp an RJ45 to the shortened end (leaving the waterproof end unchanged),
just to minimize the cable mess in the instrument wiring compartment.

That concludes my experiments with old Raymarine "SeatalkHS" cables
and connectors to the E80.
