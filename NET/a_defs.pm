#---------------------------------------------
# a_defs.pm
#---------------------------------------------

package a_defs;
use strict;
use warnings;
use Socket qw(pack_sockaddr_in inet_aton);
use Pub::Utils;

our $AUTO_START_IMPLEMENTED_SERVICES = 1;
	# RAYSYS will automatically start service_ports marked as 'implemented'.
	# Otherwise shark will start them, and they will wait for RAYSYS to find them.
	
my $WITH_TRACK 		= 0;
my $WITH_WPMGR 		= 0;
my $WITH_FILESYS 	= 1;
my $WITH_DBNAV 		= 0;
	# Allow RAYSYS to start implemented 'real' services
	

BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		$AUTO_START_IMPLEMENTED_SERVICES
	
		$LOCAL_IP

		$RAYSYS_NAME
		$RAYSYS_SID
		$RAYSYS_IP
		$RAYSYS_PORT
		$RAYSYS_ADDR

		%DEVICE_TYPE
		%KNOWN_DEVICES
		%KNOWN_SERVER_IPS
		$SHARK_DEVICE_ID

		%KNOWN_SERVICES
		%RAYSYS_DEFAULTS
		%SNIFFER_DEFAULTS

		$RNS_FILESYS_PORT
        $FILESYS_SERVICE_ID
        $FILESYS_PORT
		$HIDDEN_PORT1

		$LOCAL_UDP_PORT_BASE
        $LOCAL_UDP_SEND_PORT

		$SUCCESS_SIG
		$RAYSYS_WAKEUP_PACKET

		$ROUTE_COLOR_RED
		$ROUTE_COLOR_YELLOW
		$ROUTE_COLOR_GREEN
		$ROUTE_COLOR_BLUE
		$ROUTE_COLOR_PURPLE
		$ROUTE_COLOR_BLACK
		$NUM_ROUTE_COLORS
		
		$PI
		$PI_OVER_2
		$SCALE_LATLON
		$METERS_PER_NM
		$FEET_PER_METER
		$SECS_PER_DAY
		$KNOTS_TO_METERS_PER_SEC

		$E80_1_IP
        $E80_2_IP


		$RX
		$TX

		$MCTRL_SOURCE_SNIFFER
		$MCTRL_DEVICE_SHARK
		$MCTRL_DEVICE_RNS
		$MCTRL_SNIFF_SELF
		$MCTRL_DIRECTION_REQUEST
		$MCTRL_DIRECTION_REPLY
		$MCTRL_WHAT_DEFAULT
		$MCTRL_WHAT_DICT
		$MCTRL_WHAT_TRACK
		$MCTRL_WHAT_WP
		$MCTRL_WHAT_ROUTE
		$MCTRL_WHAT_GROUP

		$MON_RAW
		$MON_MULTI
		$MON_PARSE
		$MON_PIECE
		$MON_SEMANTIC
		$MON_RECORD
		$MON_PACK
		$MON_PACK_CONTROL
		$MON_PACK_UNKNOWN
		$MON_UNPACK
		$MON_UNPACK_CONTROL
		$MON_UNPACK_UNKNOWN
		$MON_REC_RX
		$MON_REC_RX_CONTROL
		$MON_REC_RX_UNKNOWN
		$MON_REC_RX_DECODED
		$MON_REC_TX
		$MON_REC_TX_CONTROL
		$MON_REC_TX_UNKNOWN
		$MON_REC_TX_DECODED				
    );
}



# Interesting factoids that I want to remember


our $E80_1_IP = '10.0.241.54';
our $E80_2_IP = '10.0.241.83';



#----------------------------------------
# main stuff
#----------------------------------------
# our local IP is fixed by ethernet config

our $LOCAL_IP = '10.0.241.200';

# raysys is at a known mcast address with service_id 0

our $RAYSYS_NAME = 'RAYSYS';
our $RAYSYS_SID  = 0;
our $RAYSYS_IP   = '224.0.0.1';
our $RAYSYS_PORT = 5800;
our $RAYSYS_ADDR = pack_sockaddr_in($RAYSYS_PORT, inet_aton($RAYSYS_IP));

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
our $RAYSYS_WAKEUP_PACKET = 'ABCDEFGHIJKLMNOP',


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
our $FEET_PER_METER = 3.28084;
our $KNOTS_TO_METERS_PER_SEC = 0.5144;


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
	'37a681b2' =>	'E80_1',
	'37ad80b2' =>	'E80_2',
	'ffffffff' =>	'RNS',
	$SHARK_DEVICE_ID =>   'shark' );

our %KNOWN_SERVER_IPS = (
	$E80_1_IP =>	'E80_1',
	$E80_2_IP =>	'E80_2',
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
#	Database		TCP				Database	16			probed with playback script enough to get events
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
#	Sys						MCAST 	RAYSYS		0			well known main advertisement
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
		0	=> 'RAYSYS',
		1	=> 'Radar',
		5	=> 'FILESYS',
		7	=> 'Navig',
		15	=> 'WPMGR',
		16	=> 'Database',
		19	=> 'TRACK',
		27	=> 'Alarm' );



#------------------------------------------------
# PACKET MONITORING BITS
#------------------------------------------------
# Monitoring/logging is controlled by per-service_id, per-direction,
# and per-subclass MASKS that tell what to show/log and at what
# level of detail to do so, in parsing PACKETS that contain RAYSYS
# MESSAGES.
#
# This monitoring is focused entirely on the packets, and is
# not intended to provide options for service monitoring,
# which might include things like service_port public API's,
# database states, event handling, control flow, etc.
#
# It is built on the notion that certain services are IMPLEMENTED
# and/or have sophisticated parsers for understanding the semantic
# content of messages, whereas other services don't, and yet we
# still want to see traffic to/from them, and/or probe them.
#
# Monitoring inherently knows that there is a difference between
# packets sent/received by REAL service_ports derived from B_SOCK,
# which have a {SERVICE_ID} and a {PARSER}, and packets from SNIFFER,
# from which the service_id, and hence the parseer, must be derived
# from the packet (messages).
#
# Particularly important is the notion that SNIFFER is intended primarily
# for understanding traffic between RAYNET devices, particularly RNS<->E80,
# an only secondarily, for monitoring SHARK<->E80 'self' communications,
# i.e. comms between this program (b_sock service_ports), and RAYNET,
# which is mostly just the E80s at this time.
#
# For BSOCK device_ports, these monitoring bit-masks are placed on the
# single parser that is constructed when the b_sock is instantiated by RAYSYS.
# For SNIFFER the monitoring bits are used to create a hash of parsers
# that can be re-used on subsequent similar packet.
#
# Although parsing can be viewed as a LINEAR process, proceeding from
# the raw packets, through breaking them up into messages, through
# parsing those messages, and including parsing known record types,
# the packing/unpacking of those, and the highest level semantic
# interpretaion (decoding) of their contents, the MASK allows the
# selective visualization of any or all of those steps in the process
# independently for debugging, learning, and monitoring purposes.
#
#-----------------------------------------------------------------------
# PROBLEM
#-----------------------------------------------------------------------
# For 'real' service ports created by RAYSYS, these default bits
# are denormalized onto the service_ports, where it would then
# make sense to change them on a per-service_port basis, i.e. when
# there are multiple advertisers (at different ip's) for a 'soft'
# diffentiation.  This is/was especially convenient in the UI,
# which keeps track of advertised, not potential, service ports.
#
# For sniffer, however, there is no concept of a maintained list of
# advertised ports, and to some degree denormalizing these bits
# in that same way doesn't make any sense.  However, for each unique
# service ip:port that sniffer does see, it creates a new parser,
# so the UI equivilant of RAYSYS's list of service ports, *could be*
# sniffers list of parsers.
#
# I am tempted to just make the RAYSYS_DEFAULTS and SNIFFER_DEFAULTS
# shared and NOT denormalize them, and then let the UI modify them
# in place.



# directions as nice readable strings

our $RX = 'rx';
our $TX = 'tx';

# control bits go into the {ctrl} word and are used to
# provide meta information like the source of the packet,
# the client device (shark or rns), and/or record subtypes
# within associate with the monitoring bits.

our $MCTRL_SOURCE_SNIFFER			= 0x8000;				# packet orginated in sniffer as opposed to shark

our $MCTRL_DEVICE_SHARK				= 0x1000;				# shark is the client device
our $MCTRL_DEVICE_RNS				= 0x2000;				# RNS is the client device
our $MCTRL_SNIFF_SELF				= 0x4000;				# whether to sniff "self" (shark) packets in sniffer

our $MCTRL_DIRECTION_REQUEST		= 0x0100;				# packets sent from client --> server
our $MCTRL_DIRECTION_REPLY			= 0x0200;				# packets sent from server --> client

our $MCTRL_WHAT_DEFAULT				= 0x0000;				# default subtype for base parser and services that only have one record type
our $MCTRL_WHAT_DICT				= 0x0010;
our $MCTRL_WHAT_TRACK				= 0x0020;			    # duplicated; service specific
our $MCTRL_WHAT_WP					= 0x0020;
our $MCTRL_WHAT_ROUTE				= 0x0040;
our $MCTRL_WHAT_GROUP				= 0x0080;

# monitoring bits

our $MON_RAW						= 0x00000001;			# the raw packet, with source and destination addresses, arrow, and length header
our $MON_MULTI						= 0x00000002;			# show full messages vs only the first line

our $MON_PARSE						= 0x00000010;			# bracketting of multi-message packet parsing, including start and final return values
our $MON_PIECE						= 0x00000020;			# parsing of individual messages into pieces
our $MON_SEMANTIC					= 0x00000040;			# individual message semantic header COMMAND, SID, SEQ, {value}, etc

our $MON_RECORD						= 0x00000100;			# bracketting of parsing of known record types

our $MON_PACK						= 0x00001000;			# monitoring of packing
our $MON_PACK_CONTROL				= 0x00002000;
our $MON_PACK_UNKNOWN				= 0x00004000;

our $MON_UNPACK						= 0x00010000;			# monitoring of unpackking
our $MON_UNPACK_CONTROL				= 0x00020000;
our $MON_UNPACK_UNKNOWN				= 0x00040000;			# question whether unpacked uknowns should be propogated

our $MON_REC_RX						= 0x00100000;			# monitor reply records with most important fields (i.e. name, latlon, etc)
our $MON_REC_RX_CONTROL				= 0x00200000;			# 'control fields' within records (i.e. name_len, num_wpts, etc)
our $MON_REC_RX_UNKNOWN				= 0x00400000;			# as-yet unknown fields within records, typically displayed as their raw hex strings
our $MON_REC_RX_DECODED				= 0x00800000;			# decoded semantics, i.e. unscaled lat/lons, conversions of north/east to lat longs, times, dates, etc)

our $MON_REC_TX						= 0x01000000;			# monitor request records with most important fields (i.e. name, latlon, etc)
our $MON_REC_TX_CONTROL				= 0x02000000;           # 'control fields' within records (i.e. name_len, num_wpts, etc)
our $MON_REC_TX_UNKNOWN				= 0x04000000;           # as-yet unknown fields within records, typically displayed as their raw hex strings
our $MON_REC_TX_DECODED				= 0x08800000;			# decoded semantics, i.e. unscaled lat/lons, conversions of north/east to lat longs, times, dates, etc)


# Global Defaults and useful masks

my $MCTRL_TRACK		= $MCTRL_WHAT_DICT | $MCTRL_WHAT_TRACK;
my $MCTRL_WP		= $MCTRL_WHAT_DICT | $MCTRL_WHAT_WP;
my $MCTRL_ROUTE		= $MCTRL_WHAT_DICT | $MCTRL_WHAT_ROUTE;
my $MCTRL_GROUP		= $MCTRL_WHAT_DICT | $MCTRL_WHAT_GROUP;

my $MON_ALL			= 0xffffffff;
my $MON_MASK_RAW	= 0x0000000f;
my $MON_MASK_PARSE	= 0x000000f0;
my $MON_MASK_REC	= 0x00000f00;
my $MON_MASK_PACK	= 0x0000f000;
my $MON_MASK_UNPACK	= 0x000f0000;
my $MON_MASK_REC_RX	= 0x00f00000;
my $MON_MASK_REC_TX	= 0x0f000000;



#--------------------------------------------------------------------------------------
# BASE SERVICE_PORT (by PORT) definitions
#--------------------------------------------------------------------------------------
# This hash is primarily used to drive RAYSYS, but also forms the basis of the sniffer.
#
#	RAYSYS 	== ports that can be derived from b_sock and may have parsers
#              that actually connect this program to the E80(s)
#	sniffer == monitoring driven by tshark that can display and possibly parse
#		       packets between RNS and the master E80
#
# In the context of RAYSYS, these definitions are used to respond to
# advertisements of service_ports, which in turn drive:
#
#	- 'real' implemented services that have well understood protocols,
#	  message parsers, and likely database like storage hashes
#   - identified or unidentified RAYNET service_ids with their internet
#	  protocols, which can be connected to (or 'spawned' if udp/mcast)
#     and probed using the probe language.
#
# RAYSYS also includes, by default, a known hidden (unadvertised) tcp
#	port 6668 service_id 22, as a hardwired default that can be connected to
#   and probed
#
# In the context of the sniffer, in combination with RAYSYS discovery,
# 	this drives the list of ports for which communications between
#	RNS and the E80 can be sniffed, recorded, and possibly played back
#   from our own RAYSYS service_ports.
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
# that we likely want those to be different between RAYSYS and sniffer
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
	2050 => { sid => 16,	name => 'Database',	proto=>'tcp',	},	# shows on bareE80
	2051 => { sid => 16,	name => 'data_udp',	proto=>'udp',	},	# shows on bareE80
	2052 => { sid => 15,	name => 'WPMGR',	proto=>'tcp',	},	# shows on bareE80
	2053 => { sid => 19,	name => 'TRACK',	proto=>'tcp',	},	# shows on bareE80
	2054 => { sid => 7,		name => 'Navig',	proto=>'tcp',	},	# shows on bareE80
	2055 => { sid => 22,	name => 'func22_t',	proto=>'tcp',	},	# shows on bareE80; tcp connect immediately starts getting events
	2056 => { sid => 8,		name => 'func8_u',	proto=>'udp',	},	# ??? shows with E80 Fix/Heading
	2057 => { sid => 8,		name => 'func8_ub',	proto=>'udp',	},	# shows with E80 Fix/Heading
	2058 => { sid => -2,	name => 'exists?',	proto=>'',		},	# seen in distant past

	2560 => { sid => 35,	name => 'func35_m',	proto=>'mcast',	},	# shows on bareE80
	2561 => { sid => 5,		name => 'filecast',	proto=>'mcast',	},	# shows on bareE80
	2562 => { sid => 16,	name => 'DBNAV',	proto=>'mcast',	},	# shows on bareE80; database variant; lots of packets with E80 Fix/Heading and RNS
	2563 => { sid => 8,		name => 'func8_m',	proto=>'mcast',	},	# shows, starts getting events with E80 Fix/Heading
	2564 => { sid => 8,		name => 'func8_mb',	proto=>'udp',	},	# shows with E80 Fix/Heading

	5068 => { sid => -2,	name => 'RmlMon',	proto=>'udp',	},	# comes in E80 ident message?!?
		# guess: service_id=68,  listen_port=13056

	5800 => { sid => 0,		name => 'RAYSYS',	proto=>'mcast',	},	# RAYSYS not advertised
	5801 => { sid => 27,	name => 'Alarm',	proto=>'mcast',	},	# show on bare E80
	5802 => { sid => 27,	name => 'alarm_u',	proto=>'udp',	},	# show on bare E80; addl added by RNS

	$HIDDEN_PORT1 => { sid => -1,	name => 'hidden_t',	proto=>'tcp', },	# Hidden tcp port on E80; not probed yet
);


for my $port (keys %SERVICE_PORT_DEFS)
{
	my $def = $SERVICE_PORT_DEFS{$port};
	$def->{$RX} = { $MCTRL_WHAT_DEFAULT => { ctrl => $MCTRL_DIRECTION_REPLY, 	mon => $MON_MULTI, } };
	$def->{$TX} = { $MCTRL_WHAT_DEFAULT => { ctrl => $MCTRL_DIRECTION_REQUEST,	mon => $MON_MULTI, } };
}


# Add fields for implemented service_ports
# I use tPORT here to connote that I have defined these
# ports by other constants but I am not using those here yet.

my $tPORT_RAYSYS 	= 5800;
my $tPORT_FILESYS 	= 2049;
my $tPORT_WPMGR 	= 2052;
my $tPORT_TRACK 	= 2053;
my $tPORT_DBNAV 	= 2562;


mergeHash($SERVICE_PORT_DEFS{$tPORT_FILESYS},{
	parser_class	=> 'e_FILESYS',
	implemented 	=> $WITH_FILESYS,
	auto_connect 	=> 1,
	auto_populate	=> 1 });
mergeHash($SERVICE_PORT_DEFS{$tPORT_WPMGR},{
	parser_class	=> 'e_WPMGR',
	implemented 	=> $WITH_WPMGR,
	auto_connect 	=> 1,
	auto_populate 	=> 1,
	tx => {
		$MCTRL_WHAT_DICT	=> { ctrl => $MCTRL_DIRECTION_REQUEST | $MCTRL_WHAT_DICT, },
		$MCTRL_WHAT_WP		=> { ctrl => $MCTRL_DIRECTION_REQUEST | $MCTRL_WHAT_WP, },
		$MCTRL_WHAT_GROUP	=> { ctrl => $MCTRL_DIRECTION_REQUEST | $MCTRL_WHAT_ROUTE, },
		$MCTRL_WHAT_ROUTE	=> { ctrl => $MCTRL_DIRECTION_REQUEST | $MCTRL_WHAT_GROUP, }, },
	rx => {
		$MCTRL_WHAT_DICT	=> { ctrl => $MCTRL_DIRECTION_REPLY   | $MCTRL_WHAT_DICT, },
		$MCTRL_WHAT_WP		=> { ctrl => $MCTRL_DIRECTION_REPLY   | $MCTRL_WHAT_WP, },
		$MCTRL_WHAT_GROUP	=> { ctrl => $MCTRL_DIRECTION_REPLY   | $MCTRL_WHAT_ROUTE, },
		$MCTRL_WHAT_ROUTE	=> { ctrl => $MCTRL_DIRECTION_REPLY   | $MCTRL_WHAT_GROUP, }, },
	});
mergeHash($SERVICE_PORT_DEFS{$tPORT_TRACK},{
	parser_class	=> 'e_TRACK',
	implemented 	=> $WITH_TRACK,
	auto_connect 	=> 1,
	auto_populate 	=> 1,
	tx => {
		$MCTRL_WHAT_DICT	=> { ctrl => $MCTRL_DIRECTION_REQUEST | $MCTRL_WHAT_DICT, },
		$MCTRL_WHAT_TRACK	=> { ctrl => $MCTRL_DIRECTION_REQUEST | $MCTRL_WHAT_TRACK, }, },
	rx => {
		$MCTRL_WHAT_DICT	=> { ctrl => $MCTRL_DIRECTION_REPLY   | $MCTRL_WHAT_DICT, },
		$MCTRL_WHAT_TRACK	=> { ctrl => $MCTRL_DIRECTION_REPLY   | $MCTRL_WHAT_TRACK, }, },
	});
mergeHash($SERVICE_PORT_DEFS{$tPORT_DBNAV},{
	parser_class	=> 'e_DBNAV',
	implemented 	=> $WITH_DBNAV,
	auto_connect 	=> 1,
	auto_populate 	=> 1 });


#---------------------------------------------------------
# Shark Defaults
#---------------------------------------------------------


my $dbg_startup = 1;


our %RAYSYS_DEFAULTS;
for my $port (keys %SERVICE_PORT_DEFS)
{
	$RAYSYS_DEFAULTS{$port} = {};
	mergeHash($RAYSYS_DEFAULTS{$port},$SERVICE_PORT_DEFS{$port});
}


sub setMonCol
{
	my ($defs,$port,$dir,$what,$color) = @_;
	my $def = $defs->{$port};
	display($dbg_startup,0,"setMonCol($def->{name},$port,$dir,$what,$color)");
	my $def_dir = $def->{$dir};
	my $defaults = $def_dir->{$what};
	$defaults->{color} = $color;
}

sub addMonDef
{
	my ($defs,$port,$dir,$what,$mask) = @_;
	my $def = $defs->{$port};
	display($dbg_startup,0,"setMonDef($def->{name},$port,$dir,$what,$mask)");
	my $def_dir = $def->{$dir};
	my $defaults = $def_dir->{$what};
	$defaults->{mon} |= $mask;
}

sub addMonCtrl
{
	my ($defs,$port,$dir,$bits) = @_;
	my $def = $defs->{$port};
	display($dbg_startup,0,"addMonCtrl($def->{name},$port,$dir,$bits)");
	my $def_dir = $def->{$dir};

	for my $what (keys %$def_dir)
	{
		display($dbg_startup,1,"addMonCtrl($def->{name},$dir,$what) bits($bits)");
		$def_dir->{$what}->{ctrl} |= $bits;
	}
}


# initially defining monitoring defaults, per service-what, for both input and output


my $SHARK_MON_RAYSYS	= 0;	# $MON_RAW;
my $SHARK_MON_FILESYS	= $MON_ALL;
my $SHARK_MON_DBNAV		= $MON_ALL;

my $SHARK_MON_DICT 		= $MON_ALL;
my $SHARK_MON_TRACK 	= $MON_ALL;
my $SHARK_MON_WP 		= $MON_ALL;
my $SHARK_MON_ROUTE 	= $MON_ALL;
my $SHARK_MON_GROUP 	= $MON_ALL;


# raysys

addMonDef(\%RAYSYS_DEFAULTS, $tPORT_RAYSYS,  $RX, $MCTRL_WHAT_DEFAULT,	 $SHARK_MON_RAYSYS);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_RAYSYS,  $TX, $MCTRL_WHAT_DEFAULT,	 $SHARK_MON_RAYSYS);

# filesys

setMonCol(\%RAYSYS_DEFAULTS, $tPORT_FILESYS, $RX, $MCTRL_WHAT_DEFAULT,	 $UTILS_COLOR_BROWN);
setMonCol(\%RAYSYS_DEFAULTS, $tPORT_FILESYS, $TX, $MCTRL_WHAT_DEFAULT,	 $UTILS_COLOR_LIGHT_MAGENTA);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_FILESYS, $RX, $MCTRL_WHAT_DEFAULT,	 $SHARK_MON_FILESYS);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_FILESYS, $TX, $MCTRL_WHAT_DEFAULT,	 $SHARK_MON_FILESYS);

# dbnav

setMonCol(\%RAYSYS_DEFAULTS, $tPORT_DBNAV, 	 $RX, $MCTRL_WHAT_DEFAULT,	 $UTILS_COLOR_LIGHT_GREEN);
setMonCol(\%RAYSYS_DEFAULTS, $tPORT_DBNAV, 	 $TX, $MCTRL_WHAT_DEFAULT,	 $UTILS_COLOR_LIGHT_MAGENTA);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_DBNAV, 	 $RX, $MCTRL_WHAT_DEFAULT,	 $SHARK_MON_DBNAV);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_DBNAV, 	 $TX, $MCTRL_WHAT_DEFAULT,	 $SHARK_MON_DBNAV);

# track

setMonCol(\%RAYSYS_DEFAULTS, $tPORT_TRACK, 	 $RX, $MCTRL_WHAT_DICT,	 $UTILS_COLOR_WHITE);
setMonCol(\%RAYSYS_DEFAULTS, $tPORT_TRACK,	 $TX, $MCTRL_WHAT_TRACK, $UTILS_COLOR_LIGHT_CYAN);
setMonCol(\%RAYSYS_DEFAULTS, $tPORT_TRACK,	 $RX, $MCTRL_WHAT_TRACK, $UTILS_COLOR_LIGHT_BLUE);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_TRACK, 	 $RX, $MCTRL_WHAT_DICT,	 $SHARK_MON_DICT);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_TRACK, 	 $TX, $MCTRL_WHAT_DICT,	 $SHARK_MON_DICT);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_TRACK, 	 $RX, $MCTRL_WHAT_TRACK, $SHARK_MON_TRACK);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_TRACK, 	 $TX, $MCTRL_WHAT_TRACK, $SHARK_MON_TRACK);

# wpmgr

setMonCol(\%RAYSYS_DEFAULTS, $tPORT_WPMGR, 	 $RX, $MCTRL_WHAT_DICT,	 $UTILS_COLOR_WHITE);
setMonCol(\%RAYSYS_DEFAULTS, $tPORT_WPMGR, 	 $RX, $MCTRL_WHAT_WP,	 $UTILS_COLOR_BROWN);
setMonCol(\%RAYSYS_DEFAULTS, $tPORT_WPMGR, 	 $RX, $MCTRL_WHAT_ROUTE, $UTILS_COLOR_BROWN);
setMonCol(\%RAYSYS_DEFAULTS, $tPORT_WPMGR, 	 $RX, $MCTRL_WHAT_GROUP, $UTILS_COLOR_BROWN);
setMonCol(\%RAYSYS_DEFAULTS, $tPORT_WPMGR, 	 $TX, $MCTRL_WHAT_WP,	 $UTILS_COLOR_LIGHT_CYAN);
setMonCol(\%RAYSYS_DEFAULTS, $tPORT_WPMGR, 	 $TX, $MCTRL_WHAT_ROUTE, $UTILS_COLOR_LIGHT_CYAN);
setMonCol(\%RAYSYS_DEFAULTS, $tPORT_WPMGR, 	 $TX, $MCTRL_WHAT_GROUP, $UTILS_COLOR_LIGHT_CYAN);

addMonDef(\%RAYSYS_DEFAULTS, $tPORT_WPMGR, 	 $RX, $MCTRL_WHAT_DICT,	 $SHARK_MON_DICT);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_WPMGR, 	 $TX, $MCTRL_WHAT_DICT,	 $SHARK_MON_DICT);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_WPMGR, 	 $RX, $MCTRL_WHAT_WP,	 $SHARK_MON_WP);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_WPMGR, 	 $TX, $MCTRL_WHAT_WP,	 $SHARK_MON_WP);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_WPMGR, 	 $RX, $MCTRL_WHAT_ROUTE, $SHARK_MON_ROUTE);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_WPMGR, 	 $TX, $MCTRL_WHAT_ROUTE, $SHARK_MON_ROUTE);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_WPMGR, 	 $RX, $MCTRL_WHAT_GROUP, $SHARK_MON_GROUP);
addMonDef(\%RAYSYS_DEFAULTS, $tPORT_WPMGR, 	 $TX, $MCTRL_WHAT_GROUP, $SHARK_MON_GROUP);




#------------------------------
# SNIFFER defaults
#------------------------------
# Initially, out of laziness or whatever, SNIFFER_DEFAULTS are the
# same as RAYSYS_DEFAULTS, except with the $MCTRL_SOURCE_SNIFFER bit set.
# Note that I have not started using $MCTRL_DEVICE_SHARK or $MCTRL_DEVICE_RNS yet



our %SNIFFER_DEFAULTS;
for my $port (keys %RAYSYS_DEFAULTS)
{
	my $sniff_port = $SNIFFER_DEFAULTS{$port} = {};
	mergeHash($sniff_port,$RAYSYS_DEFAULTS{$port});
	addMonCtrl(\%SNIFFER_DEFAULTS,$port,$RX,$MCTRL_SOURCE_SNIFFER);
	addMonCtrl(\%SNIFFER_DEFAULTS,$port,$TX,$MCTRL_SOURCE_SNIFFER);
}

addMonCtrl(\%SNIFFER_DEFAULTS,$tPORT_WPMGR,	 $RX, $MCTRL_SNIFF_SELF);
addMonCtrl(\%SNIFFER_DEFAULTS,$tPORT_WPMGR,	 $TX, $MCTRL_SNIFF_SELF);
addMonCtrl(\%SNIFFER_DEFAULTS,$tPORT_TRACK,	 $RX, $MCTRL_SNIFF_SELF);
addMonCtrl(\%SNIFFER_DEFAULTS,$tPORT_TRACK,	 $TX, $MCTRL_SNIFF_SELF);
addMonCtrl(\%SNIFFER_DEFAULTS,$tPORT_FILESYS,$RX, $MCTRL_SNIFF_SELF);
addMonCtrl(\%SNIFFER_DEFAULTS,$tPORT_FILESYS,$TX, $MCTRL_SNIFF_SELF);

1;