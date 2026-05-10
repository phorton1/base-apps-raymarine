#---------------------------------------------
# a_defs.pm
#---------------------------------------------

package apps::raymarine::NET::a_defs;
use strict;
use warnings;
use threads;
use threads::shared;
use Socket qw(pack_sockaddr_in inet_aton);
use Pub::Utils;






BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		initServices
	
		$LOCAL_IP

		$RAYDP_NAME
		$RAYDP_SID
		$RAYDP_IP
		$RAYDP_PORT
		$RAYDP_ADDR

		$SPORT_FILESYS
        $SPORT_WPMGR
        $SPORT_TRACK
        $SPORT_DBNAV
		$SPORT_DB

		%DEVICE_TYPE
		%KNOWN_DEVICES
		%KNOWN_SERVER_IPS
		$SHARK_DEVICE_ID

		%KNOWN_SERVICES
		%SERVICE_PORT_DEFS

		$DIRECTION_RECV
		$DIRECTION_SEND
		$DIRECTION_INFO
		$DIRECTION_EVENT
		%DIRECTION_NAME

		$RNS_FILESYS_PORT
        $FILESYS_SERVICE_ID
        $FILESYS_PORT
		$HIDDEN_PORT1

		$LOCAL_UDP_PORT_BASE
        $LOCAL_UDP_SEND_PORT

		$SUCCESS_SIG
		$RAYDP_WAKEUP_PACKET

		$ROUTE_COLOR_RED
		$ROUTE_COLOR_YELLOW
		$ROUTE_COLOR_GREEN
		$ROUTE_COLOR_BLUE
		$ROUTE_COLOR_PURPLE
		$ROUTE_COLOR_BLACK
		$NUM_ROUTE_COLORS

		$E80_MAX_NAME
		$E80_MAX_COMMENT

		$PI
		$PI_OVER_2
		$SCALE_LATLON
		$METERS_PER_NM
		$FEET_PER_METER
		$SECS_PER_DAY
		$KNOTS_TO_METERS_PER_SEC
		$PSI_TO_MILLIBARS
		$GALLONS_TO_LITRES

		$E80_0A_IP
		$E80_1_IP
        $E80_2_IP
		$E80_3_IP
		$E80_4_IP
    );
}




# Interesting factoids that I want to remember

our $E80_0A_IP = '10.0.18.120';
our $E80_1_IP = '10.0.241.54';
our $E80_2_IP = '10.0.241.83';
our $E80_3_IP = '10.0.42.39';
our $E80_4_IP = '10.0.166.121';

#----------------------------------------
# main stuff
#----------------------------------------
# our local IP is fixed by ethernet config

our $LOCAL_IP = '10.0.241.200';

# raydp is at a known mcast address with service_id 0

our $RAYDP_NAME = 'RAYDP';
our $RAYDP_SID  = 0;
our $RAYDP_IP   = '224.0.0.1';
our $RAYDP_PORT = 5800;
our $RAYDP_ADDR = pack_sockaddr_in($RAYDP_PORT, inet_aton($RAYDP_IP));


our $SPORT_FILESYS 	= 2049;
our $SPORT_WPMGR 	= 2052;
our $SPORT_TRACK 	= 2053;
our $SPORT_DBNAV 	= 2562;
our $SPORT_DB 		= 2050;


our $LOCAL_UDP_PORT_BASE		= 9000;
our $LOCAL_UDP_SEND_PORT 		= $LOCAL_UDP_PORT_BASE;
	# the recognizable port of the single
	# global udp send-only socket
	# created (in a_utils.pm)


our $RNS_FILESYS_PORT		= 0x4800;	# 18432
our $FILESYS_SERVICE_ID 	= 0x0005;	# 5 = 0x005 = '0500'
our $FILESYS_PORT 			= $LOCAL_UDP_PORT_BASE + $FILESYS_SERVICE_ID;

# Found tcp port on E80 Master

our $HIDDEN_PORT1 = 6668;

# our local ports are at recognizable numbers distinct from RAYNET port ranges
# udp listeners, when needed, will be created at $LOCAL_UDP_PORT_BASE + func
# tcp ports, when needed, will be created at  $LOCAL_TCP_PORT_BASE + func



#-------------------------------------------
# fixed packets or parts of them
#-------------------------------------------

our $SUCCESS_SIG = '00000400';
our $RAYDP_WAKEUP_PACKET = 'ABCDEFGHIJKLMNOP',

# The direction nibble of the command word seems to
# be consistent across all services

our $DIRECTION_RECV		= 0x000;
our $DIRECTION_SEND		= 0x100;
our $DIRECTION_INFO		= 0x200;
our $DIRECTION_EVENT 	= 0x500;	# added for e_DB.pm

our %DIRECTION_NAME = (
	$DIRECTION_RECV => 'recv',
	$DIRECTION_SEND => 'send',
	$DIRECTION_INFO => 'info',
	$DIRECTION_EVENT => 'event',
);



#------------------------------
# E80 transport limits
#------------------------------
# Empirically confirmed hard limits on the E80 hardware.
# Exceeding these causes silent data loss on the device.
# The NET layer enforces these as hard errors; the DB has no such limits.

our $E80_MAX_NAME    = 15;    # waypoints, groups, routes, tracks
our $E80_MAX_COMMENT = 31;    # waypoints, groups, routes (tracks have no comment field)


#------------------------------
# E80 color constants
#------------------------------

our $ROUTE_COLOR_RED 	= 0;
our $ROUTE_COLOR_YELLOW = 1;
our $ROUTE_COLOR_GREEN	= 2;
our $ROUTE_COLOR_BLUE	= 3;
our $ROUTE_COLOR_PURPLE	= 4;
our $ROUTE_COLOR_BLACK	= 5;
our $NUM_ROUTE_COLORS   = 6;


#------------------------------
# mathematical constants
#------------------------------

our $PI 			= 3.14159265358979323846;
our $PI_OVER_2 		= $PI / 2;
our $SECS_PER_DAY 	= 86400;
our $SCALE_LATLON 	= 1e7;
our $METERS_PER_NM 	= 1852;
our $FEET_PER_METER	= 3.28084;
our $KNOTS_TO_METERS_PER_SEC = 0.5144;
our $PSI_TO_MILLIBARS	= 68.9476;
our $GALLONS_TO_LITRES 	= 3.78541;


#--------------------------------------------------
# Device types & IDENT packet comments
#--------------------------------------------------
# IDENT PACKETS START with 01
#
#                       _D_TYPE_ ---ID--- VERS     ---IP---                                                                       MASTER v
#	E80 #1 M - 01000000 00000000 37a681b2 39020000 36f1000a 0033cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 02000100
#	E80 #1 S - 01000000 00000000 37ad80b2 39020000 53f0000a 0033cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 02000000
#
#	E80 #1 S - 01000000 00000000 37a681b2 39020000 36f1000a 0033cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 02000000
#	E80 #2 M - 01000000 00000000 37ad80b2 39020000 53f0000a 0033cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 02000100
#   RNS      - 01000000 03000000 ffffffff 76020000 018e7680 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 0000
#
# my $FAKE_RNS_2  = '01000000 03000000'.$SHARK_DEVICE_ID.'76020000 018e7680 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 0000';
# my $FAKE_E80_3  = '01000000 00000000'.$SHARK_DEVICE_ID.'39020000 53f0000a 0033cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 02000000';

our %DEVICE_TYPE =(
	0 	=> 'E80',
	1 	=> 'E120',
	2 	=> 'DSM300',
	3 	=> 'RAYTECH',
	4 	=> 'SR100',
	5 	=> 'GPM400',
	6 	=> 'GVM400',
	7 	=> 'DSM400',
	8 	=> 'DSM30',
	9 	=> 'DIGITAL OPEN ARRAY',
	10	=> 'DIGITAL RADOME',
	11  => 'SEATALK HS RADOME', );
	#  12 = []
	#  13+ = Unknown


# I use a friendly name in place of the Service's id for
# known E80s in my system.  These Ids are visible on the
# E80's in the Diagnostics-ExternalInterfaces-Ehernet-Devices
# dialog when one E80 identifies others on the network.

our $SHARK_DEVICE_ID = 'aaaaaaaa';

our %KNOWN_DEVICES = (
	'c48a80b2' =>	'E80_0A',
	'37a681b2' =>	'E80_1',
	'37ad80b2' =>	'E80_2',
	'67e280b2' =>	'E80_3',
	'66af81b2' => 	'E80_4',
	'ffffffff' =>	'RNS',
	$SHARK_DEVICE_ID =>   'shark' );

our %KNOWN_SERVER_IPS = (
	$E80_0A_IP =>	'E80_0B',
	$E80_1_IP =>	'E80_1',
	$E80_2_IP =>	'E80_2',
	$E80_3_IP =>	'E80_3',
	$E80_4_IP =>	'E80_4',
	$LOCAL_IP =>	'RNS',	);



#------------------------------------------------------------------------
# Raymarine Diagnostics Services Names
#------------------------------------------------------------------------
# Services enumerated on E80 Menu-System Diagnostis-External Interfaces-Ethernet
# when pressing the "Services" button, along with my general name for the service
# Each Service that has a TCP port also keeps a count of the Client/Server
# connections which is handy in probing the E80 to correlate service_ids
# to specific Services
#
# In the remainder of these comments, I have named the RayPorts according
# to a convention.
#
#		UPPERCASE 	- a service_port that with known Raymarine function
#					  that I have decoded and implemented
#		Capitalized	- a service_port that with known Raymarine function
#					  that I have connected to, seen traffic,
#					  and/or communicated with
#   	lowercase   - a service_port with known Raymrine function,
#					  that I have not seen packets from
#		lowercase?	- a rarport with a possible known Raymarine function
#
#
#									My Name
#											known func
#   Raymarine Name  TCP		UDP				(Service ID)	notes
#	-------------------------------------------------------------------------
#	Radar					UDP 	Radar		1			extensively documented in docs/reference/RMRadar_pi-master.zip
#	Fishfinder				UDP 	sonar
#	Database		TCP				DB			16			probed with playback script enough to get events
#	   Database     		MCAST	DBNAV		16			previously E80NAV/NAVSTAT, have decoded many mcast packets;
#   Waypoint		TCP				WPMGR		15			can read/write WRGs; get waypoints while TB AP engaged
#   Track			TCP				Track		19			when E80 Track is on, I get short event packets as track points presumably added
#	Navigation		TCP 			Navig		7			once connected and TB AP engaged I get 100-150 byte length delimited packets every second or so
#   Chart					UDP		chart
#	CF Access				MCAST 	FILESYS		5			uses listener UDP port in requests; can read,traverse,and download; have UI
#	GPS						UDP		gps
#	DGPS					UDP		dgps
#	Compass					UDP		compass
#	Navtext					UDP		navtext
#	AIS						UDP		ais
#   Autopilot				UDP		pilot
#	Alarm					MCAST	alarm					broadcast by master E80 & RNS
#	Sys						MCAST 	RAYDP		0			well known main advertisement
#	GVM				TCP				Gvm						TCP PORT YET TO BE IDENTIFIED
#	Monitor			TCP				monitor					audio-video module - TCP PORT YET TO BE IDENTIFIED
#	  Monitor				UDP		monitor
#	Keyboard				UDP 	kbd
#	RML Monitors			UDP 	rmlmon
#
# * I am still probing DATABASE, but had previously parsed, with some
# 	success, the packets that arrived from its UDP port, that I first
# 	called E80NAV, then NAVSTAT, and now call DBNAV.

our %KNOWN_SERVICES = (
		0	=> 'RAYDP',
		1	=> 'Radar',
		5	=> 'FILESYS',
		7	=> 'Navig',
		15	=> 'WPMGR',
		16	=> 'DB',
		19	=> 'TRACK',
		27	=> 'Alarm' );


#--------------------------------------------------------------------------------------
# BASE SERVICE_PORT (by PORT) definitions
#--------------------------------------------------------------------------------------
# This hash is primarily used to drive RAYDP, but also forms the basis of the sniffer.
#
#	RAYDP 	== ports that can be derived from b_sock and may have parsers
#              that actually connect this program to the E80(s)
#	sniffer == monitoring driven by tshark that can display and possibly parse
#		       packets between RNS and the master E80
#
# In the context of RAYDP, these definitions are used to respond to
# advertisements of service_ports, which in turn drive:
#
#	- 'real' implemented services that have well understood protocols,
#	  message parsers, and likely database like storage hashes
#   - identified or unidentified RAYNET service_ids with their internet
#	  protocols, which can be connected to (or 'spawned' if udp/mcast)
#     and probed using the probe language.
#
# RAYDP also includes, by default, a known hidden (unadvertised) tcp
#	port 6668 service_id 22, as a hardwired default that can be connected to
#   and probed
#
# In the context of the sniffer, in combination with RAYDP discovery,
# 	this drives the list of ports for which communications between
#	RNS and the E80 can be sniffed, recorded, and possibly played back
#   from our own RAYDP service_ports.
#
#   In addition, sniffer adds some hardwired 'default' ports that can
#   always be sniffed, including particularly the RNS FILESYS listener
#   at port 18432.
#
#   To the degree that RNS also presents services that we have implemented,
#	the parsers for those services are available for packets that have been
#   sniffed.
#
# To the degree that this set of definitions not only defines those basic
# ports, but also defines the default monitoring characterics (i.e.
# monitor raw in/out, monitor parsed in/out, in and out colors), AND
# that we likely want those to be different between RAYDP and sniffer
# there are TWO sets of monitoring defaults, but only one (full) set
# of the basic definitions which drive the whole thing.
#
# General Behavioral Notes
#
# - No new ports show up on bare E80 with chart card
#
# PORT Specific Behavioral Notes
#
#	2055 - func22_t
#		I am able to connect with TCP with 2055, but no new connections show in E80 Services list.
# 		Immediatly starts receiving 9 byte messags with command_word(0000) func(1600) dword(00570200) byte(00)
#	2563 - func8_m
#		start getting udp packets when RNS running and E80 has Fix/Heading
#			224.30.38.196:2563   <-- 10.0.241.54:1219
#			00000800 05f40500 dc000000 01000000 74f88210 914f0000 00000000 00000000
#		no new Service UDP byte tx/rx seen
#	2057/2564 started showing up on E80 and 2056/2563 disapeared

# Additional "possibly open" udp ports between 1000 and 10000
#
#	PORT(69) 	may be open - adds to E80 rx queue
#	PORT(1000) 	may be open - adds to E80 rx queue
#	PORT(1001) 	may be open - no longer after I terminated RNS
#	PORT(1002) 	may be open - no longer after I terminated RNS
#	PORT(6667) 	may be open - adds to E80 rx queue; adds to E80 dropped packets stats
#	PORT(8443) 	may be open - adds to E80 rx queue; adds to E80 dropped packets stats
#	PORT(10000) may be open - no longer after I terminated RNS

# 2025-10-26 - found a potentially unadvertised 'self' mcast service on RNS
#	at 224.0.0.252:5355

our %SERVICE_PORT_DEFS  = (

	2048 => { sid => 35,	name => 'func35_u',	proto=>'udp',	},	# shows on bareE80
	2049 => { sid => 5,		name => 'FILESYS',	proto=>'udp',	},	# shows on bareE80;	addl added by E80#2
	2050 => { sid => 16,	name => 'DB',		proto=>'tcp',	},	# shows on bareE80
	2051 => { sid => 16,	name => 'data_udp',	proto=>'udp',	},	# shows on bareE80
	2052 => { sid => 15,	name => 'WPMGR',	proto=>'tcp',	},	# shows on bareE80
	2053 => { sid => 19,	name => 'TRACK',	proto=>'tcp',	},	# shows on bareE80
	2054 => { sid => 7,		name => 'Navig',	proto=>'tcp',	},	# shows on bareE80
	2055 => { sid => 22,	name => 'func22_t',	proto=>'tcp',	},	# shows on bareE80; tcp connect immediately starts getting events
	2056 => { sid => 8,		name => 'func8_ub',	proto=>'udp',	},	# ??? shows with E80 Fix/Heading
	2057 => { sid => 9,		name => 'func9_u',	proto=>'udp',	},	# shows with RNS & E80 Fix/Heading; originally named func8_u assuming sid=8 by analogy with 2056/2563; confirmed sid=9 on E80-4 v5.69 2026-04-11
	2058 => { sid => -2,	name => 'exists?',	proto=>'',		},	# seen in distant past

	2560 => { sid => 35,	name => 'func35_m',	proto=>'mcast',	},	# shows on bareE80
	2561 => { sid => 5,		name => 'filecast',	proto=>'mcast',	},	# shows on bareE80
	2562 => { sid => 16,	name => 'DBNAV',	proto=>'mcast',	},	# shows on bareE80; database variant; lots of packets with E80 Fix/Heading and RNS
	2563 => { sid => 8,		name => 'func8_mb',	proto=>'mcast',	},	# ??? shows, starts getting events with E80 Fix/Heading
	2564 => { sid => 9,		name => 'func9_m',	proto=>'mcast',	},	# shows with RNS E80 Fix/Heading; originally named func8_m assuming sid=8 by analogy with 2056/2563; confirmed sid=9 on E80-4 v5.69 2026-04-11

	5068 => { sid => -2,	name => 'RmlMon',	proto=>'udp',	},	# comes in E80 ident message?!?
		# guess: service_id=68,  listen_port=13056

	5800 => { sid => 0,		name => 'RAYDP',	proto=>'mcast',	},	# RAYDP not advertised
	5801 => { sid => 27,	name => 'Alarm',	proto=>'mcast',	},	# show on bare E80
	5802 => { sid => 27,	name => 'alarm_u',	proto=>'udp',	},	# show on bare E80; addl added by RNS

	$HIDDEN_PORT1 => { sid => -1,	name => 'hidden_t',	proto=>'tcp', },	# Hidden tcp port on E80; not probed yet
);



sub initServices
{
	my (%want) = @_;
	my $auto_query = $want{auto_query} // 0;
	mergeHash($SERVICE_PORT_DEFS{$SPORT_FILESYS},{
		parser_class	=> 'apps::raymarine::NET::e_FILESYS',
		implemented 	=> $want{filesys} || 0,
		auto_connect 	=> 1,
		auto_populate	=> $auto_query });
	mergeHash($SERVICE_PORT_DEFS{$SPORT_WPMGR},{
		parser_class	=> 'apps::raymarine::NET::e_WPMGR',
		implemented 	=> $want{wpmgr} || 0,
		auto_connect 	=> 1,
		auto_populate 	=> $auto_query });
	mergeHash($SERVICE_PORT_DEFS{$SPORT_TRACK},{
		parser_class	=> 'apps::raymarine::NET::e_TRACK',
		implemented 	=> $want{track} || 0,
		auto_connect 	=> 1,
		auto_populate 	=> $auto_query });
	mergeHash($SERVICE_PORT_DEFS{$SPORT_DBNAV},{
		parser_class	=> 'apps::raymarine::NET::e_DBNAV',
		implemented 	=> $want{dbnav} || 0,
		auto_connect 	=> 1,
		auto_populate 	=> $auto_query });
	mergeHash($SERVICE_PORT_DEFS{$SPORT_DB},{
		parser_class	=> 'apps::raymarine::NET::e_DB',
		implemented 	=> $want{db} || 0,
		auto_connect 	=> 1,
		auto_populate 	=> $auto_query });
}



1;
