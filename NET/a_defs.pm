#---------------------------------------------
# a_defs.pm
#---------------------------------------------
# For sanity, Oct29, I have to start working down from the top now,
# turning off sniffer, and only caring about syntax errors there,
# and adding a single 'on/off' switch (mon_active) to the DEFAULTS
# which will get reflected in the winRAYSYS UI, once I figure out
# a bit more how this is going to work.

package a_defs;
use strict;
use warnings;
use threads;
use threads::shared;
use Socket qw(pack_sockaddr_in inet_aton);
use Pub::Utils;


# shark features that can be turned on and off

our $WITH_SERIAL		= 1;
our $WITH_RAYSYS		= 1;
our $WITH_HTTP_SERVER	= 0;
our $WITH_SNIFFER 		= 0;
our $WITH_TCP_SCANNER	= 0;
our $WITH_UDP_SCANNER	= 0;	# sniffer must be disabled for udp_scanner
our $WITH_WX			= 1;

# implemented service_ports that can be turned on and of

our $WITH_TRACK 		= 0;
our $WITH_WPMGR 		= 0;
our $WITH_FILESYS 		= 1;
our $WITH_DBNAV 		= 0;

our $AUTO_START_IMPLEMENTED_SERVICES = 1;
	# RAYSYS will automatically start service_ports marked as 'implemented'.
	# Otherwise shark will start them, and they will wait for RAYSYS to find them.
	

BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		$WITH_SERIAL
		$WITH_RAYSYS
		$WITH_HTTP_SERVER
		$WITH_SNIFFER
		$WITH_TCP_SCANNER
		$WITH_UDP_SCANNER
		$WITH_WX

		$WITH_TRACK
		$WITH_WPMGR
		$WITH_FILESYS
		$WITH_DBNAV
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

		$DIRECTION_RECV
		$DIRECTION_SEND
		$DIRECTION_INFO
		%DIRECTION_NAME

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

		$MON_HEADER
		$MON_RAW
		$MON_MULTI
		$MON_PARSE
		$MON_PIECES
		$MON_DICT
		$MON_PACK
		$MON_PACK_CONTROL
		$MON_PACK_UNKNOWN
		$MON_REC
		$MON_REC_CONTROL
		$MON_REC_UNKNOWN
		$MON_ALL
		$MON_DUMP_RECORD
		$MON_DUMP_DETAILS
		$MON_SNIFF_SELF


		$MON_WRITE_LOG
		$MON_LOG_ONLY
		$MON_SRC_SHARK
	
		$MON_WHAT_WAYPOINT
		$MON_WHAT_ROUTE
		$MON_WHAT_GROUP
		
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

# The direction nibble of the command word seems to
# be consistent across all services

our $DIRECTION_RECV		= 0x000;
our $DIRECTION_SEND		= 0x100;
our $DIRECTION_INFO		= 0x200;

our %DIRECTION_NAME = (
	$DIRECTION_RECV => 'recv',
	$DIRECTION_SEND => 'send',
	$DIRECTION_INFO => 'info',
);



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




# Add fields for implemented service_ports
# I use tPORT here to connote that I have defined these
# ports by other constants but I am not using those here yet.

my $SPORT_FILESYS 	= 2049;
my $SPORT_WPMGR 	= 2052;
my $SPORT_TRACK 	= 2053;
my $SPORT_DBNAV 	= 2562;


mergeHash($SERVICE_PORT_DEFS{$SPORT_FILESYS},{
	parser_class	=> 'e_FILESYS',
	implemented 	=> $WITH_FILESYS,
	auto_connect 	=> 1,
	auto_populate	=> 1 });
mergeHash($SERVICE_PORT_DEFS{$SPORT_WPMGR},{
	parser_class	=> 'e_WPMGR',
	implemented 	=> $WITH_WPMGR,
	auto_connect 	=> 1,
	auto_populate 	=> 1, });
mergeHash($SERVICE_PORT_DEFS{$SPORT_TRACK},{
	parser_class	=> 'e_TRACK',
	implemented 	=> $WITH_TRACK,
	auto_connect 	=> 1,
	auto_populate 	=> 1, });
mergeHash($SERVICE_PORT_DEFS{$SPORT_DBNAV},{
	parser_class	=> 'e_DBNAV',
	implemented 	=> $WITH_DBNAV,
	auto_connect 	=> 1,
	auto_populate 	=> 1 });


#---------------------------------------------
# monitor bit utilities
#---------------------------------------------
# moved away from end of this file for readability
# array positions for WPMGR mon_ins/outs and colors

our $MON_WHAT_WAYPOINT		= 0;
our $MON_WHAT_ROUTE			= 1;
our $MON_WHAT_GROUP			= 2;


sub applyMonBits
	# apply the $MON_SNIFF_SELF to the in/outs of
	# of the given port. i.e. show this implemented
	# service_ports messages in sniffer as well
{
	my ($hash,$port,$bits,$remove) = @_;
	my $def = $hash->{$port};
	if ($port == $SPORT_WPMGR)
	{
		for my $i ($MON_WHAT_WAYPOINT..$MON_WHAT_GROUP)
		{
			if ($remove)
			{
				$def->{mon_ins}->[$i]  &= ~$bits;
				$def->{mon_outs}->[$i] &= ~$bits;
			}
			else
			{
				$def->{mon_ins}->[$i]  |= $bits;
				$def->{mon_outs}->[$i] |= $bits;
			}
		}
	}
	elsif ($remove)
	{
		$def->{mon_in} 	&= ~$bits;
		$def->{mon_out} &= ~$bits;
	}
	else
	{
		$def->{mon_in} 	|= $bits;
		$def->{mon_out} |= $bits;

	}

}


#======================================================================
#======================================================================
# PACKET MONITORING BITS
#======================================================================
#======================================================================
# Note that $MON_DUMP records are not placed in recordings (log files),
# as they would break the notion of a cleanly playable recorded session.
# Otherwise, everything shown uses # comments or is the header with an arrow
# to make it easily parsable for playback.

our $MON_HEADER				= 0x0001;			# the packet header with source and destination addresses and arrow
our $MON_RAW				= 0x0002;			# the raw messages, tcp with length WORD, all with CMD_WORD, DWORDS, and ascii
our $MON_MULTI				= 0x0004;			# show full raw messages vs only the first line of DWORDS

our $MON_PARSE				= 0x0010;			# show parsing of ind			ividual messages within a packet
our $MON_PIECES				= 0x0020;			# show the pieces parsed out of individual messages
our $MON_DICT				= 0x0040;			# show the uuids in parsed dictionariees

our $MON_PACK				= 0x0100;			# monitoring of packing/unpacking main fields, i.e. name, latlon, etc
our $MON_PACK_CONTROL		= 0x0200;			# monitoring of packing/unpacking control fields, i.e. name_len, num_wpts, etc
our $MON_PACK_UNKNOWN		= 0x0400;			# monitoring of packing/unpacking unknown fields, i.e. u1, u3_200, etc

our $MON_REC				= 0x1000;			# show finished records with semantic decoding of main fields (i.e. latlon, northeast, date, time, etc)
our $MON_REC_CONTROL		= 0x2000;			# show finished records' conntrol fields, as unpacked
our $MON_REC_UNKNOWN		= 0x8000;			# show finished records' unknown fields as upacked

our $MON_ALL				= 0xffff;			# does not include final packet dummping

our $MON_DUMP_RECORD		= 0x10000;			# perl dump of finished record in json like format
our $MON_DUMP_DETAILS		= 0x20000;			# include certain big things (i.e. arrays of points in tracks) in the dump

our $MON_SNIFF_SELF			= 0x80000;			# monitor 'real' shark (b_sock) packets from sniffer

our $MON_WRITE_LOG			= 0x100000;			# write to the shark.log or rns.log files based on {is_shark} packet member
our $MON_LOG_ONLY			= 0x200000;			# don't show on console, only write to log file
	# NOT in $MON_ALL

our $MON_SRC_SHARK			= 0x1000000;		# essentially a denormalized version of $packet->{is_shark}
	# used to determine which log file to write to


# some common combinations

our $MON_START				= $MON_HEADER | $MON_RAW;
our $MON_PARSE_FULL			= $MON_START | $MON_PARSE | $MON_PIECES | $MON_DICT;
our $MON_PACK_FULL			= $MON_PACK | $MON_PACK_CONTROL | $MON_PACK_UNKNOWN;
our $MON_REC_FULL			= $MON_REC | $MON_REC_CONTROL | $MON_REC_UNKNOWN;

my $MON_CMD					= $MON_HEADER | $MON_PARSE | $MON_PIECES;
	# dont want to see dictionaries on command requests




#======================================================================
# Shark Defaults
#======================================================================
# IN and OUT are from the CLIENT's perspective,
# which corresponds to REPLY and REQUEST

our %RAYSYS_DEFAULTS;
for my $port (keys %SERVICE_PORT_DEFS)
{
	my $def = $RAYSYS_DEFAULTS{$port} = {};
	mergeHash($def,$SERVICE_PORT_DEFS{$port});

	$def->{mon_active}	= 1;

	$def->{is_shark} 	= 1;
	$def->{is_sniffer}	= 0;
	$def->{mon_in}		= 0;
	$def->{mon_out}		= 0;
	$def->{in_color}	= 0;
	$def->{out_color}	= 0;
}

# My current hardwired monitoring preferences, per implemented service

my $SHARK_MON_FILESYS	= $MON_ALL;
my $SHARK_MON_DBNAV		= $MON_ALL;
my $SHARK_MON_TRACK 	= $MON_ALL;
my $SHARK_MON_WAYPOINT 	= $MON_ALL; # $MON_PARSE_FULL;	# $MON_ALL;
my $SHARK_MON_ROUTE 	= $MON_ALL; # $MON_HEADER | $MON_DUMP_RECORD;	#$MON_ALL;
my $SHARK_MON_GROUP 	= $MON_ALL; # 0;	# $MON_ALL;

mergeHash($RAYSYS_DEFAULTS{$SPORT_FILESYS},{
	mon_in			=> $SHARK_MON_FILESYS,
	mon_out 		=> $SHARK_MON_FILESYS,
	in_color		=> $UTILS_COLOR_BROWN,
	out_color		=> $UTILS_COLOR_LIGHT_MAGENTA, });
mergeHash($RAYSYS_DEFAULTS{$SPORT_DBNAV},{
	mon_in			=> $SHARK_MON_DBNAV,
	mon_out 		=> $SHARK_MON_DBNAV,
	in_color		=> $UTILS_COLOR_LIGHT_GREEN,
	out_color		=> $UTILS_COLOR_LIGHT_MAGENTA, });
mergeHash($RAYSYS_DEFAULTS{$SPORT_TRACK},{
	mon_in			=> $SHARK_MON_TRACK,
	mon_out 		=> $SHARK_MON_TRACK,
	in_color		=> $UTILS_COLOR_LIGHT_CYAN,
	out_color		=> $UTILS_COLOR_LIGHT_BLUE, });

# WPMGR has arrays of mon/colors and MOVES
# them to the scalars based on WHAT is being
# talked about.  The order is WAYPOINT, ROUTE, GROUP

mergeHash($RAYSYS_DEFAULTS{$SPORT_WPMGR},{
	mon_ins => [
		$SHARK_MON_WAYPOINT,
		$SHARK_MON_ROUTE,
		$SHARK_MON_GROUP,
	],
	mon_outs => [
		$MON_CMD,	# $SHARK_MON_WAYPOINT,
		$MON_CMD,	# $SHARK_MON_ROUTE,
		0,#$MON_CMD,	# $SHARK_MON_GROUP,
	],
	in_colors => shared_clone([
		$UTILS_COLOR_BROWN,
		$UTILS_COLOR_BROWN,
		$UTILS_COLOR_BROWN, ]),
	out_colors => shared_clone([
		$UTILS_COLOR_LIGHT_CYAN,
		$UTILS_COLOR_LIGHT_CYAN,
		$UTILS_COLOR_LIGHT_CYAN, ]),
});



# apply the $MON_SRC_SHARK bits to %RAYSYS_DEFAULTS
# after the implemented services mergeHash() calls

for my $port (keys %RAYSYS_DEFAULTS)
{
	# print "raysys port($port)\n";
	applyMonBits(\%RAYSYS_DEFAULTS,$port,$MON_SRC_SHARK);
}



#======================================================================
# SNIFFER defaults
#======================================================================
# completely separated from RAYSYS_DEFAULTS
# and regenerated from scratch from SERVICE_PORT_DEFS

our %SNIFFER_DEFAULTS;
for my $port (keys %RAYSYS_DEFAULTS)
{
	my $def = $SNIFFER_DEFAULTS{$port} = shared_clone({});
	mergeHash($def,$SERVICE_PORT_DEFS{$port});

	$def->{is_shark}	= 0;
	$def->{is_sniffer}	= 1;
	$def->{mon_in}		= $MON_ALL;
	$def->{mon_out}		= $MON_ALL;
	$def->{in_color}	= 0;
	$def->{out_color}	= 0;

}

my $SNIFF_MON_FILESYS	= 0;	# $MON_ALL;
my $SNIFF_MON_DBNAV		= 0;	# $MON_ALL;
my $SNIFF_MON_TRACK 	= $MON_ALL;
my $SNIFF_MON_WAYPOINT 	= $MON_ALL;
my $SNIFF_MON_ROUTE 	= $MON_ALL;
my $SNIFF_MON_GROUP 	= $MON_ALL;

mergeHash($SNIFFER_DEFAULTS{$SPORT_FILESYS},{
	mon_in			=> $SNIFF_MON_FILESYS,
	mon_out 		=> $SNIFF_MON_FILESYS,
	in_color		=> $UTILS_COLOR_BROWN,
	out_color		=> $UTILS_COLOR_LIGHT_MAGENTA, });
mergeHash($SNIFFER_DEFAULTS{$SPORT_DBNAV},{
	mon_in			=> $SNIFF_MON_DBNAV,
	mon_out 		=> $SNIFF_MON_DBNAV,
	in_color		=> $UTILS_COLOR_LIGHT_GREEN,
	out_color		=> $UTILS_COLOR_LIGHT_MAGENTA, });
mergeHash($SNIFFER_DEFAULTS{$SPORT_TRACK},{
	mon_in			=> $SNIFF_MON_TRACK,
	mon_out 		=> $SNIFF_MON_TRACK,
	in_color		=> $UTILS_COLOR_LIGHT_CYAN,
	out_color		=> $UTILS_COLOR_LIGHT_BLUE, });
mergeHash($SNIFFER_DEFAULTS{$SPORT_WPMGR},{
	mon_ins => shared_clone([
		$SNIFF_MON_WAYPOINT,
		$SNIFF_MON_ROUTE,
		$SNIFF_MON_GROUP,
	]),
	mon_outs => shared_clone([
		$SNIFF_MON_WAYPOINT,
		$SNIFF_MON_ROUTE,
		$SNIFF_MON_GROUP,
	]),
	in_colors => shared_clone([
		$UTILS_COLOR_BROWN,
		$UTILS_COLOR_BROWN,
		$UTILS_COLOR_BROWN, ]),
	out_colors => shared_clone([
		$UTILS_COLOR_LIGHT_CYAN,
		$UTILS_COLOR_LIGHT_CYAN,
		$UTILS_COLOR_LIGHT_CYAN, ]),
});



# selected self monitoring of implemented services
#
# applyMonBits(\%SNIFFER_DEFAULTS,$SPORT_FILESYS,$MON_SNIFF_SELF);
# applyMonBits(\%SNIFFER_DEFAULTS,$SPORT_DBNAV,$MON_SNIFF_SELF);
# applyMonBits(\%SNIFFER_DEFAULTS,$SPORT_TRACK,$MON_SNIFF_SELF);
# applyMonBits(\%SNIFFER_DEFAULTS,$SPORT_WPMGR,$MON_SNIFF_SELF);


# apply the $MON_WRITE_LOG bits to SNIFFER_DEFAULTS
# after the sniffer mergeHash() calls

for my $port (keys %SNIFFER_DEFAULTS)
{
	# print "sniffer port($port)\n";
	applyMonBits(\%SNIFFER_DEFAULTS,$port,$MON_WRITE_LOG | $MON_LOG_ONLY);
}



1;