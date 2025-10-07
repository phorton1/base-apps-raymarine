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

		$RAYPORT_DEFAULTS
    );
}



# I use a friendly name in place of the Service's id for
# known E80s in my system.  These Ids are visible on the
# E80's in the Diagnostics-ExternalInterfaces-Ehernet-Devices
# dialog when one E80 identifies others on the network.


our %KNOWN_E80_IDS = (
	'37a681b2' =>	'E80 #1',
	'37ad80b2' =>	'E80 #2' );

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
#									My Name
#									if diff		known func
#   Raymarine Name  UDP		TCP		or addl*	(Service ID)
#	-------------------------------------------------------------------------
#	Radar			UDP 						1
#	Fishfinder		UDP 			SONAR
#	Database		UDP  	TCP		DBNAV*		16
#   Waypoint				TCP		WPMGR		15
#   Track					TCP					19
#	Navigation				TCP 	NAVSTAT
#   Chart			UDP
#	CF Access		UDP 			FILESYS		5
#	GPS				UDP
#	DGOS			UDP
#	Compass			UDP
#	Navtext			UDP
#	AIS				UDP
#   Autopilot		UDP
#	Alarm			UDP
#	Sys				UDP 			RAYSYS		0	note that I assign this func(0)
#	GVM						TCP
#	Monitor					TCP 	MON
#	Keyboard		UDP 			KBD
#	RML Monitors	UDP 			RMLMON
#
# * I am still probing DATABASE, but had previously parsed, with some
# 	success, the packets that arrived from its UDP port, that I first
# 	called E80NAV, then NAVSTAT, and now call DBNAV.


#------------------------------------------------------------------------
# BY PORT (quick list)
#------------------------------------------------------------------------
# I find it useful sometime to look at the list of Rayports either sorted by
# their Service func() numbers, but more often, I find it easier to look at
# the list of rayports sorted by their port number.  The internet protocol
# is only shown if I know that it is actually used for that port
#
#			known
#			internet								known
#	func	protocol	ip							service
#	------------------------------------------------------------------------
#   35					10.0.241.54			2048
#   5					10.0.241.54			2049	FILESYS
#   16					10.0.241.54			2050	DATABASE
#   16					10.0.241.54			2051	DATABASE
#   15					10.0.241.54			2052	WAYPOINT
#   19					10.0.241.54			2053	TRACK
#   7					10.0.241.54			2054
#   22					10.0.241.54			2055
#   8					10.0.241.54			2056
#	?					?					2058
#   35		mcast		224.30.38.193		2560
#   5		mcast		224.30.38.194		2561	FILESYS
#   16		mcast		224.30.38.195		2562	NAVSTAT
#   8		mcast		224.30.38.196		2563
#  *0*		mcast 		224.0.0.1			5800	RAYSYS 	RNS also advertises this, but there's only one Rayport
#   27		mcast		224.0.0.2			5801	ALARM 	RNS also advertises this, but there's only one Rayport
#   27					10.0.241.54			5802	ALARM	as advertised by master E80
#   27					10.0.241.200		5802	ALARM	as advertised by RNS running on my laptop


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
#		!tcp	- means I have surmised it is likely tcp, tried connecting to it,
#				  and the connection failed
#		blank   - means I dont know if it's udp or tcp
#
# In the below defaults, I have named the RayPorts according
# to a convention.
#
#		UPPERCASE 	- a rayport that I have decoded or strongly feel I understand
#		Capitalized	- a rayport that I have conclusively correlated with a named
# 					  service and internet protocol on the E80, and believe is
#					  the primary client API to the E80.
#   	lowercase   - a rayport that I believe correlates to to a known Service,
#					  but which I do not claim to undertand or know how to use it
#					  likely a 'secondary' api to the service
#		lowercase?	- a question mark indicates a rayport that *might* be correlated
#					  with a given service, but I'm not sure
#   	blank		- a rayport for which I have no clue about what Service it belongs to,
#					  and what kind of protocol to use with the port.



our $RAYPORT_DEFAULTS  = {

	# Most of these take on the IP address of the E80 master.
	# 'sid' is the standard func (Service Id) that I believe
	# 	should be associated with the rayport, but 'func'
	# 	(determined by actaual RAYSYS packets) is the
	# 	deifnitive number

	2048 => { sid => 35,	name => '',			proto=>'!tcp',	mon_from=>1,			mon_to=>$UNDER_WAY,		multi=>1,	color=>0,	 },
	2049 => { sid => 5,		name => 'FILESYS',	proto=>'udp',	mon_from=>$FILESYS,		mon_to=>1,				multi=>1,	color=>$UTILS_COLOR_CYAN,    },
	2050 => { sid => 16,	name => 'DATABASE',	proto=>'tcp',	mon_from=>$MY_DB,		mon_to=>$MY_DB,			multi=>1,	color=>0,    },
	2051 => { sid => 16,	name => 'database',	proto=>'!tcp',	mon_from=>1,			mon_to=>1,				multi=>1,	color=>0,    },
	2052 => { sid => 15,	name => 'WPMGR',	proto=>'tcp',	mon_from=>$MY_WPS,		mon_to=>$MY_WPS,		multi=>1,	color=>$UTILS_COLOR_LIGHT_GREEN,    },	#
	2053 => { sid => 19,	name => 'TRACK',	proto=>'tcp',	mon_from=>1,			mon_to=>1,				multi=>1,	color=>0,    },
	2054 => { sid => 7,		name => '',			proto=>'udp',	mon_from=>$RNS_INIT,	mon_to=>$UNDER_WAY,		multi=>1,	color=>$UTILS_COLOR_LIGHT_CYAN,    },
	2055 => { sid => 22,	name => '',			proto=>'tcp',	mon_from=>1,			mon_to=>1,				multi=>1,	color=>0,    },
	2056 => { sid => 8,		name => '',			proto=>'!tcp',	mon_from=>1,			mon_to=>1,				multi=>1,	color=>0,    },
	2058 => { sid => -2,	name => '',			proto=>'',		mon_from=>1,			mon_to=>1,				multi=>1,	color=>0,    },
	2560 => { sid => 35,	name => '',			proto=>'!tcp',	mon_from=>1,			mon_to=>1,				multi=>1,	color=>0,    },
	2561 => { sid => 5,		name => '',			proto=>'!tcp',	mon_from=>1,			mon_to=>1,				multi=>1,	color=>0,    },
	2562 => { sid => 16,	name => 'DBNAV',	proto=>'udp',	mon_from=>$MY_NAV,		mon_to=>1,				multi=>1,	color=>$UTILS_COLOR_GREEN,    },
	2563 => { sid => 8,		name => '',			proto=>'udp',	mon_from=>$UNDER_WAY,	mon_to=>1,				multi=>1,	color=>0,    },

	5800 => { sid => 0,		name => 'RAYSYS',	proto=>'mcast',	mon_from=>1,			mon_to=>$RAYSYS,		multi=>1,	color=>$UTILS_COLOR_LIGHT_BLUE,    },
	5801 => { sid => 27,	name => 'ALARM',	proto=>'mcast',	mon_from=>$UNDER_WAY,	mon_to=>1,				multi=>1,	color=>$UTILS_COLOR_BLUE,    },
	5802 => { sid => 27,	name => 'alarm',	proto=>'!tcp',	mon_from=>1,			mon_to=>1,				multi=>1,	color=>0,    },

	# these empirical port numbers carry fake funcs of 105, 106

	$FILESYS_LISTEN_PORT =>		# 18433
			{ idea=>5,	name=>'MY_FILE',	proto=>'udp',	mon_from=>$FILE,		mon_to=>1,				multi=>0,	color=>$UTILS_COLOR_BROWN,    },
	$RNS_FILESYS_LISTEN_PORT =>	# 18432
			{ idea=>5,	name=>'FILE_RNS',	proto=>'udp',	mon_from=>$FILE_RNS,	mon_to=>1,				multi=>1,	color=>$UTILS_COLOR_BROWN,    },
};




1;