#---------------------------------------------
# a_mon.pm
#---------------------------------------------
# monitor bit definitions and shared objects

package apps::raymarine::NET::a_mon;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use apps::raymarine::NET::a_defs;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		$MON_HEADER
		$MON_RAW
		$MON_MULTI
		$MON_PARSE
		$MON_PIECES
		$MON_DICT
		$MON_PACK
		$MON_PACK_CONTROL
		$MON_PACK_UNKNOWN
		$MON_PACK_SUBRECORDS
		$MON_REC
		$MON_REC_DETAILS
		$MON_ALL
		$MON_DUMP_RECORD
		$MON_DUMP_DETAILS
		$MON_SNIFF_SELF

		$MON_WRITE_LOG
		$MON_LOG_ONLY
		$MON_SRC_SHARK
		$MON_SELF_SNIFFED

		$MON_WHAT_WAYPOINT
		$MON_WHAT_ROUTE
		$MON_WHAT_GROUP

		%SHARK_DEFAULTS
		%SNIFFER_DEFAULTS

		$MONITOR_API_BUILDS

    );
}


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
	my ($add,$hash,$port,$bits) = @_;
	my $def = $hash->{$port};
	if ($port == $SPORT_WPMGR)
	{
		for my $i ($MON_WHAT_WAYPOINT..$MON_WHAT_GROUP)
		{
			if ($add)
			{
				$def->{mon_ins}->[$i]  |= $bits;
				$def->{mon_outs}->[$i] |= $bits;
			}
			else
			{
				$def->{mon_ins}->[$i]  &= ~$bits;
				$def->{mon_outs}->[$i] &= ~$bits;
			}
		}
	}
	elsif ($add)
	{
		$def->{mon_in} 	|= $bits;
		$def->{mon_out} |= $bits;
	}
	else
	{
		$def->{mon_in} 	&= ~$bits;
		$def->{mon_out} &= ~$bits;

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
our $MON_PACK_SUBRECORDS	= 0x0800;			# monitor packing/unpacking subrecords, mostly Track Points which can be huge

our $MON_REC				= 0x1000;			# show finished records
our $MON_REC_DETAILS		= 0x2000;			# show finished records' subfields (i.e. Route and Track points)

our $MON_ALL				= 0xffff;			# does not include final packet dummping

our $MON_DUMP_RECORD		= 0x10000;			# perl dump of finished record in json like format
our $MON_DUMP_DETAILS		= 0x20000;			# include certain big things (i.e. arrays of points in tracks) in the dump
our $MON_SNIFF_SELF			= 0x80000;			# monitor 'real' shark (b_sock) packets from sniffer

our $MON_WRITE_LOG			= 0x100000;			# write to the shark.log or rns.log files based on {is_shark} packet member
our $MON_LOG_ONLY			= 0x200000;			# don't show on console, only write to log file
	# NOT in $MON_ALL; NOT stored on individual monitor definitions;
	# These applied to packets from def->{log} in applyMonDefs()

our $MON_SRC_SHARK			= 0x1000000;		# essentially a denormalized version of $packet->{is_shark}
our $MON_SELF_SNIFFED		= 0x2000000;		# put on packets that are self sniffed

	# used to determine which log file to write to


# some common combinations

my $MON_MIN 			 	= $MON_HEADER | $MON_PARSE;
my $MON_CMD					= $MON_HEADER | $MON_PARSE | $MON_PIECES;
	# dont want to see dictionaries on command requests



## Special variable for monitoring WPMGR API use of buildXXX() methods

our $MONITOR_API_BUILDS :shared = $MON_REC | $MON_REC_DETAILS | $MON_PACK | $MON_PACK_CONTROL | $MON_PACK_UNKNOWN;
	# Outside of the per-service monitor bit passing scheme, this variable
	# controls whether to show debugging output while calling b_record::buildXXX()
	# WRG methods directly from the WPMGR API call.
	# 0 will turn the output off, or a variety of the monitoring bits may be
	# used as indicated in the # following the =0; above.


#======================================================================
# Shark Defaults
#======================================================================
# IN and OUT are from the CLIENT's perspective,
# which corresponds to REPLY and REQUEST

our %SHARK_DEFAULTS;
for my $port (keys %SERVICE_PORT_DEFS)
{
	my $def = $SHARK_DEFAULTS{$port} = shared_clone({});
	mergeHash($def,$SERVICE_PORT_DEFS{$port});

	$def->{active}		= 0;
	$def->{log}			= 0;	# $MON_WRITE_LOG;
	
	$def->{is_shark} 	= 1;
	$def->{is_sniffer}	= 0;
	$def->{mon_in}		= $MON_ALL;
	$def->{mon_out}		= $MON_ALL;
	$def->{in_color}	= 0;
	$def->{out_color}	= 0;
}

# My current hardwired monitoring preferences, per implemented service

my $SHARK_MON_FILESYS	= $MON_HEADER | $MON_RAW | $MON_PARSE | $MON_PIECES;
my $SHARK_MON_DBNAV		= $MON_ALL;
my $SHARK_MON_TRACK 	= $MON_HEADER | $MON_RAW | $MON_MULTI | $MON_PARSE | $MON_PIECES |
	$MON_PACK		|
    $MON_PACK_CONTROL |
    $MON_PACK_UNKNOWN;

my $SHARK_MON_WAYPOINT 	= $MON_ALL;
my $SHARK_MON_ROUTE 	= $MON_ALL;
my $SHARK_MON_GROUP 	= $MON_ALL;

my $ACTIVE_TRACK 		= 1;
my $ACTIVE_WPMGR 		= 1;
my $ACTIVE_FILESYS 		= 0;
my $ACTIVE_DBNAV 		= 0;
my $ACTIVE_DB 			= 0;
	# defaults for SHARK_DEFAULT {active} to turn
	# monitoring on at startup vs only via UI later



mergeHash($SHARK_DEFAULTS{$SPORT_FILESYS},{
	active			=> $ACTIVE_FILESYS,
	mon_in			=> $SHARK_MON_FILESYS,
	mon_out 		=> $SHARK_MON_FILESYS,
	in_color		=> $UTILS_COLOR_BROWN,
	out_color		=> $UTILS_COLOR_LIGHT_MAGENTA, });
mergeHash($SHARK_DEFAULTS{$SPORT_DBNAV},{
	active			=> $ACTIVE_DBNAV,
	mon_in			=> $SHARK_MON_DBNAV,
	mon_out 		=> $SHARK_MON_DBNAV,
	in_color		=> $UTILS_COLOR_LIGHT_GREEN,
	out_color		=> $UTILS_COLOR_LIGHT_MAGENTA, });
mergeHash($SHARK_DEFAULTS{$SPORT_TRACK},{
	active			=> $ACTIVE_TRACK,
	mon_in			=> $SHARK_MON_TRACK,
	mon_out 		=> $SHARK_MON_TRACK,
	in_color		=> $UTILS_COLOR_LIGHT_BLUE,
	out_color		=> $UTILS_COLOR_LIGHT_CYAN, });
mergeHash($SHARK_DEFAULTS{$SPORT_DB},{
	active			=> $ACTIVE_DB,
	mon_in			=> $MON_ALL,
	mon_out 		=> $MON_ALL,
	in_color		=> $UTILS_COLOR_LIGHT_GREEN,
	out_color		=> $UTILS_COLOR_LIGHT_BLUE, });



# WPMGR has arrays of mon/colors and MOVES
# them to the scalars based on WHAT is being
# talked about.  The order is WAYPOINT, ROUTE, GROUP

mergeHash($SHARK_DEFAULTS{$SPORT_WPMGR},{
	active => $ACTIVE_WPMGR,
	mon_ins => shared_clone([
		$SHARK_MON_WAYPOINT,
		$SHARK_MON_ROUTE,
		$SHARK_MON_GROUP,
	]),
	mon_outs => shared_clone([
		$SHARK_MON_WAYPOINT,   # $MON_CMD,
		$SHARK_MON_ROUTE,      # $MON_CMD,
		$SHARK_MON_GROUP,      # $MON_CMD,
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



# apply the $MON_SRC_SHARK bits to %SHARK_DEFAULTS
# after the implemented services mergeHash() calls

for my $port (keys %SHARK_DEFAULTS)
{
	# print "raydp port($port)\n";
	applyMonBits(1,\%SHARK_DEFAULTS,$port,$MON_SRC_SHARK);
}

if (0)
{
	applyMonBits(1,\%SHARK_DEFAULTS,$SPORT_FILESYS,$MON_SNIFF_SELF);
	applyMonBits(1,\%SHARK_DEFAULTS,$SPORT_DBNAV,$MON_SNIFF_SELF);
	applyMonBits(1,\%SHARK_DEFAULTS,$SPORT_TRACK,$MON_SNIFF_SELF);
	applyMonBits(1,\%SHARK_DEFAULTS,$SPORT_WPMGR,$MON_SNIFF_SELF);
	applyMonBits(1,\%SHARK_DEFAULTS,$SPORT_DB,$MON_SNIFF_SELF);
}


#======================================================================
# SNIFFER defaults
#======================================================================
# completely separated from SHARK_DEFAULTS
# and regenerated from scratch from SERVICE_PORT_DEFS

our %SNIFFER_DEFAULTS;
for my $port (keys %SERVICE_PORT_DEFS)
{
	my $def = $SNIFFER_DEFAULTS{$port} = shared_clone({});
	mergeHash($def,$SERVICE_PORT_DEFS{$port});

	$def->{active}		= 0;
	$def->{log}			= 0;	# $MON_WRITE_LOG;

	$def->{is_shark}	= 0;
	$def->{is_sniffer}	= 1;
	$def->{mon_in}		= $MON_ALL;
	$def->{mon_out}		= $MON_ALL;
	$def->{in_color}	= 0;
	$def->{out_color}	= 0;

}

my $SNIFF_MON_FILESYS	= 0;	# $MON_HEADER | $MON_RAW | $MON_PARSE | $MON_PIECES;
my $SNIFF_MON_DBNAV		= 0;	# $MON_ALL;
my $SNIFF_MON_TRACK 	= 0;	# $MON_ALL;
my $SNIFF_MON_WAYPOINT 	= 0;	# $MON_MIN;
my $SNIFF_MON_ROUTE 	= $MON_ALL;
my $SNIFF_MON_GROUP 	= 0;	# $MON_MIN;


mergeHash($SNIFFER_DEFAULTS{$SPORT_FILESYS},{
	parser_class	=> 'apps::raymarine::NET::e_FILESYS',
	mon_in			=> 0, # 2026-04-12 turned off for chart analysis: $SNIFF_MON_FILESYS,
	mon_out 		=> $SNIFF_MON_FILESYS,
	in_color		=> $UTILS_COLOR_BROWN,
	out_color		=> $UTILS_COLOR_LIGHT_MAGENTA, });
mergeHash($SNIFFER_DEFAULTS{$SPORT_DBNAV},{
	parser_class	=> 'apps::raymarine::NET::e_DBNAV',
	mon_in			=> $SNIFF_MON_DBNAV,
	mon_out 		=> $SNIFF_MON_DBNAV,
	in_color		=> $UTILS_COLOR_GREEN,
	out_color		=> $UTILS_COLOR_MAGENTA, });
mergeHash($SNIFFER_DEFAULTS{$SPORT_TRACK},{
	parser_class	=> 'apps::raymarine::NET::e_TRACK',
	mon_in			=> $SNIFF_MON_TRACK,
	mon_out 		=> $SNIFF_MON_TRACK,
	in_color		=> $UTILS_COLOR_CYAN,
	out_color		=> $UTILS_COLOR_BLUE, });
mergeHash($SNIFFER_DEFAULTS{$SPORT_WPMGR},{
	parser_class	=> 'apps::raymarine::NET::e_WPMGR',
	active => 1,
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
		$UTILS_COLOR_CYAN,
		$UTILS_COLOR_CYAN,
		$UTILS_COLOR_CYAN, ]),
});
mergeHash($SNIFFER_DEFAULTS{$SPORT_DB},{
	parser_class	=> 'apps::raymarine::NET::e_DB',
	mon_in			=> $MON_ALL,
	mon_out 		=> $MON_ALL,
	in_color		=> $UTILS_COLOR_LIGHT_GREEN,
	out_color		=> $UTILS_COLOR_YELLOW, });



1;