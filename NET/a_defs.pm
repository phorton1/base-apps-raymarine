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
	
my $WITH_TRACK 		= 1;
my $WITH_WPMGR 		= 1;
my $WITH_FILESYS 	= 1;
my $WITH_DBNAV 		= 1;
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
		%SERVICE_PORT_DEFS

		$RNS_FILESYS_LISTEN_PORT
		$HIDDEN_PORT1

		$LOCAL_UDP_PORT_BASE
        $LOCAL_TCP_PORT_BASE
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


    );
}



# Interesting factoids that I want to remember


my $E80_1_IP = '10.0.241.54';


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

# RNS listens for FILESYS udp packets at a repeatable address

our $RNS_FILESYS_LISTEN_PORT	= 0x4800;	# 18432

# Found tcp port on E80 Master

our $HIDDEN_PORT1 = 6668;

# our local ports are at recognizable numbers distinct from RAYNET port ranges
# udp listeners, when needed, will be created at $LOCAL_UDP_PORT_BASE + func
# tcp ports, when needed, will be created at  $LOCAL_TCP_PORT_BASE + func

our $LOCAL_UDP_PORT_BASE		= 9000;
our $LOCAL_TCP_PORT_BASE		= 12000;

our $LOCAL_UDP_SEND_PORT 		= $LOCAL_UDP_PORT_BASE;
	# the recognizable port of the single
	# global udp send-only socket
	# created (in a_utils.pm)


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
# There is a direct many-to-one mapping between port numbers and service_ids.
# In other words, Services always use the same set of Ports on RAYNET, so
# this is the definitive mapping of services and the ports they offer.
#
# General Notes
#
# - No new ports show up on bare E80 with chart card
#
# PORT Specific Notes
#
#	2055 - func22_t
#		I am able to connect with TCP with 2055, but no new connections show in E80 Services list.
# 		Immediatly starts receiving 9 byte messags with command_word(0000) func(1600) dword(00570200) byte(00)
#	2563 - func8_m
#		start getting udp packets when RNS running and E80 has Fix/Heading
#			224.30.38.196:2563   <-- 10.0.241.54:1219
#			00000800 05f40500 dc000000 01000000 74f88210 914f0000 00000000 00000000
#		no new Service UDP byte tx/rx seen


our %SERVICE_PORT_DEFS  = (

	2048 => { sid => 35,	name => 'func35_u',	proto=>'udp',	},								# shows on bareE80
	2049 => { sid => 5,		name => 'FILESYS',	proto=>'udp',	implemented => $WITH_FILESYS },	# shows on bareE80;	addl added by E80#2
	2050 => { sid => 16,	name => 'Database',	proto=>'tcp',	},								# shows on bareE80
	2051 => { sid => 16,	name => 'database',	proto=>'udp',	},								# shows on bareE80
	2052 => { sid => 15,	name => 'WPMGR',	proto=>'tcp',	implemented => $WITH_WPMGR },	# shows on bareE80
	2053 => { sid => 19,	name => 'TRACK',	proto=>'tcp',	implemented => $WITH_TRACK },	# shows on bareE80
	2054 => { sid => 7,		name => 'Navig',	proto=>'tcp',	},								# shows on bareE80
	2055 => { sid => 22,	name => 'func22_t',	proto=>'tcp',	},								# shows on bareE80; tcp connect immediately starts getting events
	2056 => { sid => 8,		name => 'func8_u',	proto=>'udp',	},								# shows with E80 Fix/Heading
	2058 => { sid => -2,	name => 'exists?',	proto=>'',		},								# seen in distant past

	2560 => { sid => 35,	name => 'func35_m',	proto=>'mcast',	},								# shows on bareE80
	2561 => { sid => 5,		name => 'filesys',	proto=>'mcast',	},								# shows on bareE80
	2562 => { sid => 16,	name => 'DBNAV',	proto=>'mcast',	implemented => $WITH_DBNAV },	# shows on bareE80; database variant; lots of packets with E80 Fix/Heading and RNS
	2563 => { sid => 8,		name => 'func8_m',	proto=>'mcast',	},								# shows, starts getting events with E80 Fix/Heading

	5800 => { sid => 0,		name => 'RAYSYS',	proto=>'mcast',	},								# RAYSYS not advertised
	5801 => { sid => 27,	name => 'Alarm',	proto=>'mcast',	},								# show on bare E80
	5802 => { sid => 27,	name => 'alarm',	proto=>'udp',	},								# show on bare E80; addl added by RNS

	6668 => { sid => -1,	name => 'hidden_t',	proto=>'tcp',	},								# Hidden tcp port on E80; not probed yet
);








1;