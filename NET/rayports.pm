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




		$RAYPORT_DEFAULTS

    );
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
#		TWO of the same mcast ip:port addresses in the system, so the mcast_ip for it does not generate a service_port record.
#
#	length(37) - same as length(36), but with a flags byte
#
#   	id(37a681b2) func( 5) x(01001e00,01081100) mcast_ip(224.30.38.194) port(2561) 	2nd_ip(10.0.241.54) port(2049) 	flags(1)
#
#	length(40) - an ip with two ports, and a second (mcast) ip:port
#
#   	id(37a681b2) func(16) x(01001e00,02081400) ip(10.0.241.54) port1(2050) port2(2051) mcast_ip(224.30.38.195) port(2562)





#--------------------------------------------------------------------------------------
# BY PORT - Definitive List
#--------------------------------------------------------------------------------------
# This defines the defaults, by port, for each Rayport.
# In the UI, the useer can choose, for each service_port to,
#
#	- monitor packets 'from' the port
#	- monitor packets 'to' the port
#	- show the entire packet (multi) or only display one line per packet
#	- show each service_port's monitor output in a different color
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
my $MY_TRACK	= 0;


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



our %RAYPORT_DEFAULTS  = {

	# Most of these take on the IP address of the E80 master.
	# 'sid' is the standard func (Service Id) that I believe
	# 	should be associated with the service_port, but 'func'
	# 	(determined by actaual RAYSYS packets) is the
	# 	deifnitive number

	# No new ports show up on bare E80 with chart card

	# 2048-2055 show up on bare E80 

	2048 => { sid => 35,	name => 'func35_u',	proto=>'udp',	mon_from=>$UNDER_WAY,	mon_to=>1,			multi=>1,	color=>0,	 },
	2049 => { sid => 5,		name => 'FILESYS',	proto=>'udp',	mon_from=>1,			mon_to=>$FILESYS,	multi=>1,	color=>$UTILS_COLOR_CYAN,    },
	2050 => { sid => 16,	name => 'Database',	proto=>'tcp',	mon_from=>$MY_DB,		mon_to=>$MY_DB,		multi=>1,	color=>$UTILS_COLOR_WHITE,    },
	2051 => { sid => 16,	name => 'database',	proto=>'udp',	mon_from=>1,			mon_to=>1,			multi=>1,	color=>0,    },
	2052 => { sid => 15,	name => 'WPMGR',	proto=>'tcp',	mon_from=>$MY_WPS,		mon_to=>$MY_WPS,	multi=>1,	color=>$UTILS_COLOR_LIGHT_GREEN, },	#
	2053 => { sid => 19,	name => 'TRACK',	proto=>'tcp',	mon_from=>$MY_TRACK,	mon_to=>$MY_TRACK,	multi=>1,	color=>$UTILS_COLOR_LIGHT_GREEN,  implemented => 1   },
	2054 => { sid => 7,		name => 'Navig',	proto=>'tcp',	mon_from=>$UNDER_WAY,	mon_to=>$RNS_INIT,	multi=>1,	color=>$UTILS_COLOR_LIGHT_CYAN,    },
	2055 => { sid => 22,	name => 'func22_t',	proto=>'tcp',	mon_from=>1,			mon_to=>1,			multi=>1,	color=>$UTILS_COLOR_LIGHT_MAGENTA,    },
		# I am able to connect with TCP with 2055 , but no new connections show in E80 Services list
		# Immediatly starts receiving 9 byte messags with command_word(0000) func(1600) dword(00570200) byte(00)

	# 2056,2058 do not show up on bare E80

	2056 => { sid => 8,		name => 'func8_u',	proto=>'udp',	mon_from=>1,			mon_to=>1,			multi=>1,	color=>0,    },
		# shows up after turning on TB compass and GPS device
	# 2058 => { sid => -2,	name => '',			proto=>'',		mon_from=>1,			mon_to=>1,			multi=>1,	color=>0,    },
		# I saw this somewhere in the vestigial past, but don't know for sure now

	# 2560-2563 show up on bare E80

	2560 => { sid => 35,	name => 'func35_m',	proto=>'mcast',	mon_from=>1,			mon_to=>1,			multi=>1,	color=>0,    },
	2561 => { sid => 5,		name => 'filesys',	proto=>'mcast',	mon_from=>1,			mon_to=>1,			multi=>1,	color=>0,    },
	2562 => { sid => 16,	name => 'DBNAV',	proto=>'mcast',	mon_from=>1,			mon_to=>$MY_NAV,	multi=>1,	color=>$UTILS_COLOR_GREEN,    },
		# E80 starts broadcasting these when TB autopilot instrument exists and RNS is running
	2563 => { sid => 8,		name => 'func8_m',	proto=>'mcast',	mon_from=>1,			mon_to=>$EXPLORING,	multi=>0,	color=>$UTILS_COLOR_LIGHT_MAGENTA,    },
		# start getting udp packets when RNS is started and UNDER_WAY = heading and fix
		# 		224.30.38.196:2563   <-- 10.0.241.54:1219
		#			00000800 05f40500 dc000000 01000000 74f88210 914f0000 00000000 00000000
		# no new Service UDP byte tx/rx seen


	# 5800 added by me

	5800 => { sid => 0,		name => 'RAYSYS',	proto=>'mcast',	mon_from=>1,			mon_to=>$RAYSYS,	multi=>1,	color=>$UTILS_COLOR_LIGHT_BLUE,    },

	# 5801-5802 show up on bare E80

	5801 => { sid => 27,	name => 'Alarm',	proto=>'mcast',	mon_from=>1,			mon_to=>$UNDER_WAY,	multi=>1,	color=>$UTILS_COLOR_BLUE,    },
	5802 => { sid => 27,	name => 'alarm',	proto=>'udp',	mon_from=>1,			mon_to=>1,			multi=>1,	color=>0,    },
		# RNS adds alarm udp port at id(ffffffff) with no chart card

	# these found by port scan and here as reminders (they will never be advertised
	
	6668 => { sid => -1,	name => 'hidden_t',	proto=>'tcp',	mon_from=>1,			mon_to=>1,			multi=>1,	color=>$UTILS_COLOR_LIGHT_MAGENTA,    },

	# these empirical port numbers carry fake funcs of 105, 106

#	$FILESYS_LISTEN_PORT =>		# 18433
#			{ sid=>5,		name=>'MY_FILE',	proto=>'udp',	mon_from=>1,			mon_to=>$FILE,		multi=>1,	color=>$UTILS_COLOR_BROWN,    },
#	$RNS_FILESYS_LISTEN_PORT =>	# 18432
#			{ sid=>5,		name=>'FILE_RNS',	proto=>'udp',	mon_from=>1,			mon_to=>$FILE_RNS,	multi=>1,	color=>$UTILS_COLOR_BROWN,    },
};




1;