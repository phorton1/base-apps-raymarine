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
my $WITH_FILESYS 	= 0;
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
		$SHARK_DEVICE_ID

		%KNOWN_SERVICES
		%RAYSYS_DEFAULTS
		%SNIFFER_DEFAULTS;

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

our $PI = 3.14159265358979323846;
our $PI_OVER_2 = $PI / 2;
our $SCALE_LATLON 	= 1e7;
our $METERS_PER_NM 	= 1852;
our $FEET_PER_METER  = 3.28084;
our $SECS_PER_DAY 	= 86400;
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
	'37a681b2' =>	'E80 #1',
	'37ad80b2' =>	'E80 #2',
	'ffffffff' =>	'RNS',
	$SHARK_DEVICE_ID =>   'shark' );


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
# Service (by PORT) definitions
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

	5068 => { sid => -2,	name => 'RmlMon',	proto=>'udp',	},	# comes in E80 ident message
		# guess: service_id=68,  listen_port=13056

	5800 => { sid => 0,		name => 'RAYSYS',	proto=>'mcast',	},	# RAYSYS not advertised
	5801 => { sid => 27,	name => 'Alarm',	proto=>'mcast',	},	# show on bare E80
	5802 => { sid => 27,	name => 'alarm_u',	proto=>'udp',	},	# show on bare E80; addl added by RNS

	$HIDDEN_PORT1 => { sid => -1,	name => 'hidden_t',	proto=>'tcp', },	# Hidden tcp port on E80; not probed yet
);


# Additional "possibly open" udp ports between 1000 and 10000
#
#	PORT(69) 	may be open - adds to E80 rx queue
#	PORT(1000) 	may be open - adds to E80 rx queue
#	PORT(1001) 	may be open - no longer after I terminated RNS
#	PORT(1002) 	may be open - no longer after I terminated RNS
#	PORT(6667) 	may be open - adds to E80 rx queue; adds to E80 dropped packets stats
#	PORT(8443) 	may be open - adds to E80 rx queue; adds to E80 dropped packets stats
#	PORT(10000) may be open - no longer after I terminated RNS


# Add fields for implemented service_ports

mergeHash($SERVICE_PORT_DEFS{2049},{
	implemented 	=> $WITH_FILESYS,
	auto_connect 	=> 1,
	auto_populate	=> 1 });
mergeHash($SERVICE_PORT_DEFS{2052},{
	implemented 	=> $WITH_WPMGR,
	auto_connect 	=> 1,
	auto_populate 	=> 1 });
mergeHash($SERVICE_PORT_DEFS{2053},{
	implemented 	=> $WITH_TRACK,
	auto_connect 	=> 1,
	auto_populate 	=> 1 });
mergeHash($SERVICE_PORT_DEFS{2562},{
	implemented 	=> $WITH_DBNAV,
	auto_connect 	=> 1,
	auto_populate 	=> 1 });



#---------------------------------------------------------
# Monitoring
#---------------------------------------------------------
# monitoring group variables to turn sets on and off

my $MON_RAYSYS			= 0;
my $MON_WPMGR 			= 0;
my $MON_FILESYS 		= 0;
my $MON_TRACK			= 0;
my $MON_DBNAV 			= 0;
my $MON_DATABASE		= 0;

my $MON_RNS_WPMGR 		= 0;
my $MON_RNS_FILESYS  	= 0;
my $MON_RNS_TRACK	 	= 0;
my $MON_RNS_DATABASE	= 0;

# general monitoring of other service_ports based
# on the state of the E80 or RNS

my $E80_UNDER_WAY		= 0;
my $RNS_INIT			= 0;





#---------------------------------------------------------
# RAYSYS_DEFAULTS
#---------------------------------------------------------
# In general MONITOR DEFAULTS are setup up sparsely
# with only interesting ones having colors. parsers, etc
#
# There are so many levels of potential monitoring and
# debugging.  Looking at WPMGR as an example.
#
#	- raw message packet 				b_sock		none													raw_bytes for multiple messages
#		- parse message packet			wp_packet	reply		is_event, mods, etc							optional {text} = raw_bytes and semantics per message
#			- parse message debug		wp_packet	display		pieces as they are parsed
#				- record parsing		b_record	{item}		full record returned within reply
#				- record parsing debug	b_record	display		not in packed records (name, uuids, etc)
#				    - unpack debug		a_utils		display		raw un/pack bytes and underlying types
#			- record display			b_record	text		type interpretation, scaling, etc			appended to {text} member in reply
#
# Then on top of that, add these complexities
#
#	- ip:port identifications
#	- log files
#	- api command demarcation on screen and in log files
#	- custom headers on screen and in log files
#	- general re-utilizaton of b_record to show items from hashes
#	- sniffer as a whole other way to get packets
#	- multiple different data types in WPMGR that might want monitor/debug focus
#	- individual items that might want monitor/debug focus
#
# Its a fucking ton.
#
# I don't think a couple of booleans are going to cut it.
#
# HYPER GENERALIZED SERVICE SPECIFIC BIT FIELD(s)
#
#	To some degree it is tempting to start at raw meessage packet level,
#		where the packet has been broken into a series of message, then
#		do one message at a time down the line.  This would require a
#		startParse() method
#
#	The raw header as-is is already pretty large, and combined
#		with the length word and dwords, runs up against the
#		ability to be displayed in the console window without wrapping.
#
#	There is also the discrepancy between
#
#		- uiCommand, handleCommand, and handlePacket demarcation,
#		- an inline "print" which is nearly instanteous
#		- writing to a log file, including custom headers
#		- a display() call which might occur some time after prints bracketing it
#		- a "print" of a large chunk of text after all the parsing is done
#
#	But, in the simplest idea with ONE record type with WPManager
#
#		b_sock or sniffer?
#			0x1000 - b_sock raw bytes
#			0x2000 - sniffer RNS
#			0x4000 - sniffer self
#		wp_packet
#			0x0001 - per message semantic header
#			0x0002 - pieces (before the semantic header)
#			0x0004 - dictionary internals (though this *could* be an entire cross service record type
#		wp_record
#			0x0010 - record level 0 = semantic fields interpretations
#			0x0020 - record level 1 - control fields generally uninterpreted
#			0x0040 - record level 2 - unknown fields generally uninterpreted
#		a_utils
#			0x0100 - pack level 0 = semantic fields (name, latlon, etc)
#			0x0200 - pack level 1 = control fields (name_len, num_uuids, etc)
#			0x0400 - pack level 2 = unknown fields (u1, etc)
#
#  	With one of these words for each (WP,ROUTE,GROUP)
#
# SNIFFER vs b_sock
#
#	TCP Service filtering (WPMGR, TRACK, upcoming Database) from sniffer
#		is not straight forward ...
#	  - how do I identify RNS versus me now that I am using
#	    ephemeral local ports?
#	  - If the service_port specifies a local_port and it matches,
#		its to/from me, if not I am not connected and it *must*
#		be TO/FROM RNS?
#	MCAST filtering (besides RAYSYS which I always connect to)
#	  - The only MCAST that is currently official, and bound to
#		is RAYSYS
#	  - Can we identify WHO sent the mcast packet and do we
#	    want to be able to filter by that?
#	UDP filtering (FILESYS and the others)
#	  - We have a formula for fixed UDP_PORTS for me
#	  - We use a single UDP port for all requests at this time
#	  - Services LISTEN on a specified UDP port which we either know
#       by our fixed udp port definitions, or by history, for the
#     - We can also get the listener port out of the requests sent
#		to FILESYS. Does this hold for any/all other udp servics?
#
# We want to, at a minumum, be able to monitor ALL raw packets
#	that we can identify between RNS and the E80.
# Are there services we can actually "hit" on RNS?
#	Thus far I dont generally see REQUESTS being made to
#	mcast ports by clients within these protocols, but it
#	is a capability
#
# TODO
#
#	- with teensyBoat we wanti to change the Boat window to the 'Simulator',
#     integrate controls into it, and in the Prog Window (instruments) have
#     the ability to monitor specific protocols.
#   - there is much work in TB to
#     - parse/forward NMEA0183 messaages
#	    not much advantage using the NMEA0183 library in either direction
#	  - winNMEA0183
#     - fix and go through NMEA2000 instrument messages sent
#     - parse/forward NMEA2000 messages
#	    its too bad that the NMEA2000 library doesnt impment a generalized
#		message-to-record parser and we have to immplement every message
#	    we want explicitly
#     - monitor NMEA2000 control messages
#     - monitor unknown or other NMEA2000 bus messages
#	  - winNMEA2000 (messages)
#	  - winNMEA3000Devices
#
# TB and SEATALK_JXN CIRCUIT BOARDS
#
#	I still need to try the new MAX3232 breakout boards and see
# 	if I even can talk 0183 to the VHF and E80 at the same time
#
#   Need to come to a firm decision regarding a permenant teensy
#   on the boat and whether it gets in between the VHF and E80
#	permanently, or only when the TB board is plugged in.
#
#   Really should try to hook up the ST50's and ST7000 an
#	   make sure I know all of their messages and relationsips
#	   The ST7000 will probably balk until I can sufficiently
#      emulate the computer/drive/rudder sensor
#
#   Really should hook up the DSM300 and see if it broadcasts
#		even with no sonar sensor hooked up.
#
#	Will need a whole pass for Radar when this is on the boat
#
#	Still would love to:
#
#		- get charts from the E80 and be able to see/use them
#		  in GE, my own program, or openCPN
#
#		- get a good idea how I'm gonna do WRGT management
#         - the ONLY way to write a track to the E80 would
#		    be to complete writeFSH and shuttle a CF card
#
#		- learn openCPN in general, and as a candidate for
#		  WRGT managment
#
#		- possibly write a 'C' socket based Json API
#		  to a running shark, or worse, a full re-implementation
#	      of shark in C/C++
#
# MAIN CURRENT GOAL
#
# 	However, the most important thing is still to probe the E80 and RNS
#	and for that I need sniffer. And decent control over its monitoring
#   and parsing capabilites, and for that, I need a scheme going forward.
#
#   Database needs to become DATABASE
#		RNS is clearly doing a lot of setup and communications
#		and I get many new DBNAV messages when it is running as a result.
#	DBNAV needs to be deterministic and able
#		to parse all field_type and determine their exact semantic.






our %RAYSYS_DEFAULTS;
for my $port (keys %SERVICE_PORT_DEFS)
{
	$RAYSYS_DEFAULTS{$port} = {};
	mergeHash($RAYSYS_DEFAULTS{$port},$SERVICE_PORT_DEFS{$port});
	mergeHash($RAYSYS_DEFAULTS{$port},{
		in_color			=> 0,
		out_color			=> $UTILS_COLOR_LIGHT_MAGENTA,
		mon_raw_in 			=> 1,
		mon_raw_out 		=> 1,
		in_multi			=> 1,
		out_multi			=> 1,

		mon_parsed_in 		=> 1,	# 0,
		mon_parsed_out 		=> 1,	# 0,
		in_parse_dbg_level 	=> 1,
		out_parse_dbg_level => 1,
		in_record_dbg_level => 1,
		out_record_dbg_level=> 1,
		in_pack_dbg_level 	=> 1,
		out_pack_level 		=> 1,
	});
}


mergeHash($RAYSYS_DEFAULTS{5800},{					# RAYSYS
	mon_raw_in 	=> $MON_RAYSYS,
	mon_raw_out	=> $MON_RAYSYS, });
mergeHash($RAYSYS_DEFAULTS{2049},{					# FILESYS
	in_color		=> $UTILS_COLOR_BROWN,
	out_color		=> $UTILS_COLOR_LIGHT_MAGENTA,
	in_multi		=> 0,
	mon_raw_in 		=> 0,
	mon_raw_out		=> 0,
	mon_parsed_in 	=> $MON_FILESYS,
	mon_parsed_out 	=> $MON_FILESYS, });
mergeHash($RAYSYS_DEFAULTS{2052},{					# WPMGR
	in_color		=> $UTILS_COLOR_LIGHT_BLUE,
	out_color		=> $UTILS_COLOR_LIGHT_CYAN,
	in_multi		=> 0,
	mon_raw_in 		=> 0,
	mon_raw_out		=> 0,
	mon_parsed_in 	=> $MON_WPMGR,
	mon_parsed_out  => $MON_WPMGR, });
mergeHash($RAYSYS_DEFAULTS{2053},{					# TRACK
	in_color		=> $UTILS_COLOR_BLUE,
	out_color		=> $UTILS_COLOR_LIGHT_CYAN,
	in_multi		=> 0,
	mon_raw_in 		=> 0,
	mon_raw_out		=> 0,
	mon_parsed_in 	=> $MON_TRACK,
	mon_parsed_out => $MON_TRACK, });
mergeHash($RAYSYS_DEFAULTS{2562},{					# DBNAV
	in_color		=> $UTILS_COLOR_LIGHT_GREEN,
	in_multi		=> 0,
	mon_raw_in 		=> 0,
	mon_parsed_in 	=> $MON_DBNAV, });
mergeHash($RAYSYS_DEFAULTS{2050},{					# Database
	in_color		=> $UTILS_COLOR_WHITE,
	out_color		=> $UTILS_COLOR_LIGHT_MAGENTA,
	mon_raw_in		=> $MON_DATABASE,
	mon_raw_out		=> $MON_DATABASE });
mergeHash($RAYSYS_DEFAULTS{2051},{});				# data_udp
mergeHash($RAYSYS_DEFAULTS{2054},{					# Navig
	in_color		=> $UTILS_COLOR_WHITE,
	mon_raw_in 		=> $E80_UNDER_WAY, });
mergeHash($RAYSYS_DEFAULTS{2561},{});				# filecast
mergeHash($RAYSYS_DEFAULTS{5801},{});				# Alarm
mergeHash($RAYSYS_DEFAULTS{5802},{});				# alarm_u
mergeHash($RAYSYS_DEFAULTS{2048},{});				# func35_u
mergeHash($RAYSYS_DEFAULTS{2055},{});				# func22_t
mergeHash($RAYSYS_DEFAULTS{2056},{});				# func8_u
mergeHash($RAYSYS_DEFAULTS{2058},{});				# exists?
mergeHash($RAYSYS_DEFAULTS{2560},{});				# func35_m
mergeHash($RAYSYS_DEFAULTS{2563},{});				# func8_m
mergeHash($RAYSYS_DEFAULTS{$HIDDEN_PORT1},{			# hidden port on E80
	in_color => $UTILS_COLOR_WHITE,	});


#	$RNS_FILESYS_PORT =>	{ mon_from=>1,	mon_to=>$FILE,		multi=>1,	color=>$UTILS_COLOR_BROWN,    },#``
#	$RNS_FILESYS_PORT =>	{ mon_from=>1,	mon_to=>$FILE_RNS,	multi=>1,	color=>$UTILS_COLOR_BROWN,    },



# In general SNIFFER_DEFAULTS are setup to
# automatically monitor the raw input and output of
# all ports that we have not seen (i.e. setup explicit
# defaults for).

our %SNIFFER_DEFAULTS;
for my $port (keys %RAYSYS_DEFAULTS)
{
	my $sniff_port = $SNIFFER_DEFAULTS{$port} = {};
	mergeHash($sniff_port,$RAYSYS_DEFAULTS{$port});
}


mergeHash($SNIFFER_DEFAULTS{5800},{					# RAYSYS
	mon_raw_in 	=> 0,
	mon_raw_out	=> 0, });
mergeHash($SNIFFER_DEFAULTS{2049},{					# FILESYS
	in_color		=> $UTILS_COLOR_BROWN,
	out_color		=> $UTILS_COLOR_MAGENTA,
	# in_multi		=> 0,
	# mon_raw_in 		=> 0,
	# mon_raw_out		=> 0,
	mon_parsed_in 	=> $MON_RNS_FILESYS,
	mon_parsed_out => $MON_RNS_FILESYS, });
mergeHash($SNIFFER_DEFAULTS{2052},{					# WPMGR
	in_color		=> $UTILS_COLOR_BLUE,
	out_color		=> $UTILS_COLOR_CYAN,
	# in_multi		=> 0,
	# mon_raw_in 		=> 0,
	# mon_raw_out		=> 0,
	mon_parsed_in 	=> $MON_RNS_WPMGR,
	mon_parsed_out => $MON_RNS_WPMGR, });
mergeHash($SNIFFER_DEFAULTS{2053},{					# TRACK
	in_color		=> $UTILS_COLOR_MAGENTA,
	out_color		=> $UTILS_COLOR_CYAN,
	# in_multi		=> 0,
	# mon_raw_in 		=> 0,
	# mon_raw_out		=> 0,
	mon_parsed_in 	=> $MON_RNS_TRACK,
	mon_parsed_out => $MON_RNS_TRACK, });
mergeHash($SNIFFER_DEFAULTS{2562},{					# DBNAV
	mon_raw_in 		=> 1,
	mon_parsed_in 	=> 1, });
mergeHash($SNIFFER_DEFAULTS{2050},{					# Database
	in_color		=> $UTILS_COLOR_WHITE,
	out_color		=> $UTILS_COLOR_LIGHT_MAGENTA,
	mon_raw_in		=> $MON_RNS_DATABASE,
	mon_raw_out		=> $MON_RNS_DATABASE });


1;