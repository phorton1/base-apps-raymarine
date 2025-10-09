#---------------------------------------------
# rayports.pm
#---------------------------------------------
# Contains the defaults for rayports and walls of text


package rayports;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use r_utils;
use Socket;
use IO::Select;
use Pub::Utils;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		%KNOWN_E80_IDS
		raydpIdIfKnown
		%KNOWN_FUNCS
		$RAYPORT_DEFAULTS
    );
}



# I use a friendly name in place of the Service's id for
# known E80s in my system.  These Ids are visible on the
# E80's in the Diagnostics-ExternalInterfaces-Ehernet-Devices
# dialog when one E80 identifies others on the network.


our %KNOWN_E80_IDS = (
	'37a681b2' =>	'E80 #1',
	'37ad80b2' =>	'E80 #2',
	'ffffffff' =>	'RNS' );

sub raydpIdIfKnown
{
	my ($id) = @_;
	my $e80 = $KNOWN_E80_IDS{$id};
	return $e80 if $e80;
	return $id;
}



#--------------------------------------------------------------------------------------
# Broadcast Service records BY LENGTH
#--------------------------------------------------------------------------------------
# Originally I started looking at them by the length of the ethernet packet
# the advertistement arrived in.
#
# This early list is incomplete but remains useful for understanding the parser.
# The length of the packet determines the number of Rayports within the Service.
# Note that:
#
#		10.0.241.54 	is the ip address of my master e80,
#		37a681b2 		is my master E80's id
#		10.0.241.200	is the assigned address of my laptop (running RNS) within RAYNET
#
# Each records contains two dwords(x) that I don't claim to understand
#
#	length(28) - contain a single ip:port address
#
#   	id(37a681b2) func( 7) x(01001e00,06080800) ip(10.0.241.54) port(2054)
#   	id(37a681b2) func(15) x(01001e00,04080800) ip(10.0.241.54) port(2052)
#   	id(37a681b2) func(19) x(01001e00,05080800) ip(10.0.241.54) port(2053)
#   	id(37a681b2) func(22) x(01001e00,07080800) ip(10.0.241.54) port(2055)
#
#	length(36) - two ip:port addreses
#
#   	id(37a681b2) func( 8) x(09001e00,08081000) mcast_ip(224.30.38.196) port(2563) 	2nd_ip(10.0.241.54)  port(2056)
#   	id(37a681b2) func(27) x(01001e00,aa161000) mcast_ip(224.0.0.2)     port(5801) 	2nd_ip(10.0.241.54)  port(5802)
#   	id(ffffffff) func(27) x(01001e00,aa161000) mcast_ip(224.0.0.2)     port(5801) 	2nd_ip(10.0.241.200) port(5802)
#   	id(37a681b2) func(35) x(01001e00,00081000) mcast_ip(224.30.38.193) port(2560) 	2nd_ip(10.0.241.54)  port(2048)
#
#		note that 'ffffffff' is the id of func(27)=Alarm when RNS is running, but there is no ssuch thing as
#		TWO of the same ip:port addresses in the system, so the mcast_ip for it does not generate a rayport record.
#
#	length(37) - same as length(36), but with a flags byte
#
#   	id(37a681b2) func( 5) x(01001e00,01081100) mcast_ip(224.30.38.194) port(2561) 	2nd_ip(10.0.241.54) port(2049) 	flags(1)
#
#	length(40) - an ip with two ports, and a second (mcast) ip:port
#
#   	id(37a681b2) func(16) x(01001e00,02081400) ip(10.0.241.54) port1(2050) port2(2051) mcast_ip(224.30.38.195) port(2562)


#------------------------------------------------------------------------
# Raymarine Diagnostics Services Names
#------------------------------------------------------------------------
# Services enumerated on E80 Menu-System Diagnostis-External Interfaces-Ethernet
# when pressing the "Services" button, along with My general name for the service
# Each Service that has a TCP port, also keeps a count of the Client/Server
# connections which is handy in probing the E80 to correlate func numbers
# to specific Services
#
# In the remainder of thises comments, I have named the RayPorts according
# to a convention.
#
#		UPPERCASE 	- a rayport that with known Raymarine function
#					  that I have decoded and implemented
#		Capitalized	- a rayport that with known Raymarine function
#					  that I have connected to, seen traffic,
#					  and/or communicated with
#   	lowercase   - a rayport with known Raymrine function,
#					  that I have not seen packets from
#		lowercase?	- a rarport with a possible known Raymarine function
#   	blank		- a rayport for which I have no clue
#
#
#									My Name
#											known func
#   Raymarine Name  TCP		UDP				(Service ID)	notes
#	-------------------------------------------------------------------------
#	Radar					UDP 	Radar		1			extensively document in docs/reference/RMRadar_pi-master.zip
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
#	GVM				TCP				Gvm
#	Monitor			TCP				monitor
#	  Monitor				UDP		monitor
#	Keyboard				UDP 	kbd
#	RML Monitors			UDP 	rmlmon
#
# * I am still probing DATABASE, but had previously parsed, with some
# 	success, the packets that arrived from its UDP port, that I first
# 	called E80NAV, then NAVSTAT, and now call DBNAV.

our %KNOWN_FUNCS = (
		0	=> 'RAYSYS',
		1	=> 'Radar',
		5	=> 'FILESYS',
		7	=> 'Navig',
		15	=> 'WPMGR',
		16	=> 'Database',
		19	=> 'Track', );


#--------------------------------------------------------------------------------------
# BY PORT - Definitive List
#--------------------------------------------------------------------------------------
# This defines the defaults, by port, for each Rayport.
# In the UI, the useer can choose, for each rayport to,
#
#	- monitor packets 'from' the port
#	- monitor packets 'to' the port
#	- show the entire packet (multi) or only display one line per packet
#	- show each rayport's monitor output in a different color
#
# The color names are
#
#    'Default',
#    'Blue',
#    'Green',
#    'Cyan',
#    'Red',
#    'Magenta',
#    'Brown',
#    'Light Gray',
#    'Gray',
#    'Light Blue',
#    'Light Green',
#    'Light Cyan',
#    'Light Red',
#    'Light Magenta',
#    'Yellow',
#    'White',

# These constants allow me to turn default monitoring on or off for
# a number of different rayports with a single variable

my $RNS_INIT  	= 0;			# starts happening when RNS starts
my $UNDER_WAY 	= 0;			# emitted by E80 while "underway"
my $FILESYS 	= 0;			# requests made TO the filesystem
my $MY_DB		= 0;
my $MY_NAV 		= $UNDER_WAY;	# many packets are sent when 'Underway'
my $MY_WPS 		= 0;			# the important Waypoint, Route, and Group management tcp protocol
my $RAYSYS		= 0;
my $FILE		= 0;
my $FILE_RNS 	= 0;

my $EXPLORING 	= 0;


# The ports that have mon_from or mon_to set to one(1) are those I have never seen
# packets to/from.
#
# The ones I have seen can be turned on or off for program start up by the variables above.
# For ports with known internet protocols (or observed traffic, or known in the
# E80 services list) the internet protocol for the port is listed below.
#
#		mcast	- defined by the ip address
#		udp		- means I have seen udp traffic, or surmised it is udp from services list
#		tcp 	- means I have connected to it
#		udp	- means I have surmised it is likely tcp, tried connecting to it,
#				  and the connection failed
#		blank   - means I dont know if it's udp or tcp
#



our $RAYPORT_DEFAULTS  = {

	# Most of these take on the IP address of the E80 master.
	# 'sid' is the standard func (Service Id) that I believe
	# 	should be associated with the rayport, but 'func'
	# 	(determined by actaual RAYSYS packets) is the
	# 	deifnitive number

	# No new ports show up on bare E80 with chart card

	# 2048-2055 show up on bare E80 

	2048 => { sid => 35,	name => '',			proto=>'udp',	mon_from=>$UNDER_WAY,	mon_to=>1,			multi=>1,	color=>0,	 },
	2049 => { sid => 5,		name => 'FILESYS',	proto=>'udp',	mon_from=>1,			mon_to=>$FILESYS,	multi=>1,	color=>$UTILS_COLOR_CYAN,    },
	2050 => { sid => 16,	name => 'Database',	proto=>'tcp',	mon_from=>$MY_DB,		mon_to=>$MY_DB,		multi=>1,	color=>0,    },
	2051 => { sid => 16,	name => 'database',	proto=>'udp',	mon_from=>1,			mon_to=>1,			multi=>1,	color=>0,    },
	2052 => { sid => 15,	name => 'WPMGR',	proto=>'tcp',	mon_from=>$MY_WPS,		mon_to=>$MY_WPS,	multi=>1,	color=>$UTILS_COLOR_LIGHT_GREEN,    },	#
	2053 => { sid => 19,	name => 'Track',	proto=>'tcp',	mon_from=>1,			mon_to=>1,			multi=>1,	color=>0,    },
	2054 => { sid => 7,		name => 'Navig',	proto=>'tcp',	mon_from=>$UNDER_WAY,	mon_to=>$RNS_INIT,	multi=>1,	color=>$UTILS_COLOR_LIGHT_CYAN,    },
	2055 => { sid => 22,	name => 'Unknown1',	proto=>'tcp',	mon_from=>1,			mon_to=>1,			multi=>1,	color=>0,    },
		# am able to connect with TCP, but no new connections show in E80 Services list
		# immediatly starts receiving 9 byte messags with command_word(0000) func(1600) dword(00570200) byte(00)

	# 2056,2058 do not show up on bare E80

	2056 => { sid => 8,		name => '',			proto=>'udp',	mon_from=>1,			mon_to=>1,			multi=>1,	color=>0,    },
		# shows up after turning on TB compass and GPS device
	2058 => { sid => -2,	name => '',			proto=>'',		mon_from=>1,			mon_to=>1,			multi=>1,	color=>0,    },

	# 2560-2563 show up on bare E80

	2560 => { sid => 35,	name => '',			proto=>'mcast',	mon_from=>1,			mon_to=>1,			multi=>1,	color=>0,    },
	2561 => { sid => 5,		name => '',			proto=>'mcast',	mon_from=>1,			mon_to=>1,			multi=>1,	color=>0,    },
	2562 => { sid => 16,	name => 'DBNAV',	proto=>'mcast',	mon_from=>1,			mon_to=>$MY_NAV,	multi=>1,	color=>$UTILS_COLOR_GREEN,    },
		# E80 starts broadcasting these when TB autopilot instrument exists and RNS is running
	2563 => { sid => 8,		name => '',			proto=>'mcast',	mon_from=>1,			mon_to=>$EXPLORING,	multi=>0,	color=>$UTILS_COLOR_LIGHT_MAGENTA,    },
		# start getting udp packets when RNS is started and UNDER_WAY = heading and fix
		# 		224.30.38.196:2563   <-- 10.0.241.54:1219
		#			00000800 05f40500 dc000000 01000000 74f88210 914f0000 00000000 00000000
		# no new Service UDP byte tx/rx seen


	# 5800 added by me

	5800 => { sid => 0,		name => 'RAYSYS',	proto=>'mcast',	mon_from=>1,			mon_to=>$RAYSYS,	multi=>1,	color=>$UTILS_COLOR_LIGHT_BLUE,    },

	# 5801-5802 show up on bare E80

	5801 => { sid => 27,	name => 'ALARM',	proto=>'mcast',	mon_from=>1,			mon_to=>$UNDER_WAY,	multi=>1,	color=>$UTILS_COLOR_BLUE,    },
	5802 => { sid => 27,	name => 'alarm',	proto=>'udp',	mon_from=>1,			mon_to=>1,			multi=>1,	color=>0,    },
		# RNS adds alarm udp port at id(ffffffff) with no chart card

	# these empirical port numbers carry fake funcs of 105, 106

	$FILESYS_LISTEN_PORT =>		# 18433
			{ sid=>5,		name=>'MY_FILE',	proto=>'udp',	mon_from=>1,			mon_to=>$FILE,		multi=>0,	color=>$UTILS_COLOR_BROWN,    },
	$RNS_FILESYS_LISTEN_PORT =>	# 18432
			{ sid=>5,		name=>'FILE_RNS',	proto=>'udp',	mon_from=>1,			mon_to=>$FILE_RNS,	multi=>1,	color=>$UTILS_COLOR_BROWN,    },
};




1;