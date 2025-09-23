# next stab at WPT

## GET ALL WAYPOINTS

The conversation starts with

	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811	0800
	tcp(8)    10.0.241.54:2052     <-- 10.0.241.200:52811	b0010f00 00000000
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
   000030 (48)         1e e5 89 05 b8 60 09 cf 35 c3 97 06 fc 9c 95 c5    .....`..5.......
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


