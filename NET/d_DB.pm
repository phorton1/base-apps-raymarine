#===========================================================================
# d_DB implemented service
#===========================================================================
# Breakthrough rapid implementation
# Asking for eventing (populate in onConnect) of all possible fids
# - is time consuming and probasbly not necessary as only certain ones
#   even consistently have unknown values
# - should be short circuited if DBNAV gets field_values by $fid before us
# Which brings up that DBNAV is just an arm of DB, and that we can also
# 	parse values here, as well as respond to the occasional event.
#	The only real difference being that DBNAV is udp and we want
#   to control its monitoring separately (service_ports architecture).
# Which brings up that
# - parsers should live in the b_layer and do all the command / rule definition
# - parsers should not maintain state, implemented services should
# - we should add systematic control of debugging (monitoring) of
#   command and control processes
# - as well as implementing command and control processes uniformly

package apps::raymarine::NET::d_DB;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use apps::raymarine::NET::a_utils;
use apps::raymarine::NET::a_defs;
use base qw(apps::raymarine::NET::b_sock);


my $dbg = 0;


my $INIT_NONE = 0;
my $INIT_KNOWN = 1;
my $INIT_ALL = 2;

my $HOW_INIT = $INIT_ALL;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(

		$self_db

		$DB_SERVICE_ID

		$SUCCESS2_SIG

		$DB_CMD_UUID
		$DB_CMD_DEF
		$DB_CMD_FIELD
		$DB_CMD_EXISTS
		$DB_CMD_NAME
		$DB_CMD_QUERY

		%DB_PARSE_RULES
		%DB_FIELDS

		$DB_FIELD_WIND_ANGLE_APP
		$DB_FIELD_WIND_ANGLE_TRUE
	);
}

our $self_db:shared;


#------------------------------------------
# main definitions
#------------------------------------------

our $DB_SERVICE_ID = 16;
	# 16 == 0x10 == '1000' in streams

our $SUCCESS2_SIG = '04000000';
										# Reply			Request (command)
our $DB_CMD_UUID   		= 0x00;		#
our $DB_CMD_DEF			= 0x01;		#
our $DB_CMD_FIELD		= 0x02;		#
our $DB_CMD_EXISTS  	= 0x03;		#
our $DB_CMD_NAME		= 0x04;		#
our $DB_CMD_QUERY		= 0x05;		#


our %DB_CMD_NAME = (
	$DB_CMD_UUID   	 => 'UUID',
	$DB_CMD_DEF		 => 'DEF',
	$DB_CMD_FIELD	 => 'FIELD',
	$DB_CMD_EXISTS   => 'EXISTS',
	$DB_CMD_NAME	 => 'NAME',
	$DB_CMD_QUERY	 => 'QUERY',
);


our %DB_PARSE_RULES = (

	# keep alive event

	$DIRECTION_EVENT | $DB_CMD_UUID		=> [],

	# typical field_def request/reply

	$DIRECTION_SEND  | $DB_CMD_FIELD	=> [ 'fid' ],
	$DIRECTION_SEND  | $DB_CMD_QUERY	=> [ 'seq','fid' ],

	$DIRECTION_RECV  | $DB_CMD_EXISTS	=> [ 'seq','fid','db_bits','word' ],
	$DIRECTION_INFO  | $DB_CMD_UUID		=> [ 'seq','uuid','success2' ],
	$DIRECTION_INFO  | $DB_CMD_DEF		=> [ 'seq','def_buffer' ],
	$DIRECTION_INFO  | $DB_CMD_FIELD	=> [ 'seq','uuid' ],

	# later field_name? request/reply

	$DIRECTION_SEND  | $DB_CMD_UUID		=> [ 'fid' ],
	$DIRECTION_SEND  | $DB_CMD_NAME		=> [ 'seq','fid' ],
	$DIRECTION_RECV  | $DB_CMD_FIELD	=> [ 'seq','fid','name_buffer' ],

	# events

	$DIRECTION_RECV  | $DB_CMD_DEF		=> [ 'zero','fid','db_bits','word' ],
	$DIRECTION_INFO  | $DB_CMD_EXISTS	=> [ 'zero','uuid','success2' ],
	$DIRECTION_INFO  | $DB_CMD_NAME		=> [ 'zero','dword','fid','def_buffer' ],
	$DIRECTION_INFO  | $DB_CMD_QUERY	=> [ 'zero','uuid' ],

);




#--------------------------------------------------------------
# FID mapping
#--------------------------------------------------------------
# FIDs used by DB_NAV

our $DB_FIELD_WIND_ANGLE_APP	= 0x59;		# 360 relative to bow heading
our $DB_FIELD_WIND_ANGLE_TRUE	= 0x5b;		# 360 relative to bow heading

# This deserves a comment.  The fuel math is just plain weird.
# Given two tanks with a level 0..100 and a capacity in gallons, litres whatever,
# - they give level2 (scaled by 250) as 0..100 in the engine section
# - they give the total fuel remaining as (capacity1 * level1 + capacity2 * level2) in the summary section
# - the give the capacity of tank2 in the total section, as the final FID
# Its asymetric, sparse, and you would have to solve a pair of equations in two variables
# 	to figure out tank1's level and capacity, though tank1 is arguably the 'main' fuel tank
# 	on the boat.
# Furthermore, just so you know, they DONT follow the NMEA2000 spec for sending the levels
# 	to the E80, which states they *should* be scaled by 250 on input, 

our %DB_FIELDS = (

	0x03	=> { name => 'SPEED', 			type => 'centiMetersPerSec', },		# thru water
	0x04	=> { name => 'SOG', 			type => 'centiMetersPerSec', },     #
	0x07	=> { name => 'LOG_TOTAL',		type => 'distanceMeters', },		#
	0x08	=> { name => 'LOG_TRIP',		type => 'distanceMeters', },		#
	0x09	=> { name => 'DEPTH',			type => 'depth',     },             #
	0x12	=> { name => 'TIME',			type => 'time',      },             #
	0x13	=> { name => 'DATE',			type => 'date',      },             #
	0x17	=> { name => 'HEADING',			type => 'heading',   },             #
	0x18	=> { name => 'SET',				type => 'heading',   },             #
	0x19	=> { name => 'DRIFT',			type => 'centiMetersPerSec', },   	#
	0x1a	=> { name => 'COG',				type => 'heading',   },             #
	0x1c	=> { name => 'HEAD_MAYBE',		type => 'heading',   },             # just a guess
	0x21	=> { name => 'ENG_OIL_PRESS1',	type => 'millibarsToPSI', },		# psi
	0x22	=> { name => 'ENG_OIL_TEMP1',	type => 'kelvinOver10', },			# farenheight
	0x24	=> { name => 'ENG_COOL_TEMP1',	type => 'kelvinOver100', },			# farenheight
	0x25	=> { name => 'ENG_ALT_VOLT1',   type => 'wordOver100',},			#
	0x26	=> { name => 'ENG_FUEL_RATE',   type => 'deciLitresToGallons',},	# gph
	0x30	=> { name => 'ENG_RPM1',   		type => 'intWordOver4',},			# rpms
	0x32	=> { name => 'FUEL_LEVEL2',		type => 'wordOver250',},			# 0..100 percent; weirdly stored as *250
	0x34	=> { name => 'XTE',				type => 'distanceCentiMeters', },   # centimeters, was $DB_FIELD_WP_TIME_2000 from NMEA2000
	0x44	=> { name => 'LATLON',			type => 'latLon',    },             #
	0x47	=> { name => 'HEADING_MAG',		type => 'heading',   },             #
	0x48	=> { name => 'HEADING_MAG2',	type => 'heading',   },             #
	0x49	=> { name => 'SET_MAG',			type => 'heading',   },             #
	0x55	=> { name => 'VMG_WIND', 		type => 'centiMetersPerSec', },     #
	0x58	=> { name => 'WIND_SPEED_APP', 	type => 'deciMetersPerSec', },		#
	0x59	=> { name => 'WIND_ANGLE_APP',	type => 'heading',   },             # 360 relative to bow heading
	0x5a	=> { name => 'WIND_SPEED_TRUE', type => 'deciMetersPerSec', },		# 360 relative to bow heading
	0x5b	=> { name => 'WIND_ANGLE_TRUE',	type => 'heading',   },             #
	0x5c	=> { name => 'WIND_SPEED_GND', 	type => 'deciMetersPerSec', },		#
	0x5d	=> { name => 'WIND_ANGLE_GND',	type => 'heading',   },             # note that the E80 shows MAG despite the "T" it shows
	0x66	=> { name => 'WP_HEADING',		type => 'heading', 	 },				#
	0x67	=> { name => 'WP_HEADING_MAG',	type => 'heading', 	 },				#
	0x6a	=> { name => 'WP_DISTANCE',		type => 'distanceMeters', },		#
	0x69	=> { name => 'WP_ID',			type => 'string',	 },				# only to two decimal places (60 feet)
	0x93	=> { name => 'NORTHEAST',		type => 'northEast', },             #
	0x70	=> { name => 'WP_HEADING2',		type => 'heading', 	 },				#
	0x7f	=> { name => 'VMG_WIND', 		type => 'centiMetersPerSec', },     #
	0x99	=> { name => 'LATLON2',			type => 'latLon',    },             #
	0x9c	=> { name => 'TIME2',			type => 'time',  	 },      		#
	0xaa	=> { name => 'DATE2',			type => 'date',      },             #
	0xb6	=> { name => 'VMG_WPT', 		type => 'centiMetersPerSec', },     #
	0xba	=> { name => 'HEAD2',			type => 'heading',   },             #
	0xbb	=> { name => 'HEAD3',			type => 'heading',   },             #
	0xbc	=> { name => 'HEAD4',			type => 'heading',   },             #
	0xbd	=> { name => 'HEAD5_MAG',		type => 'heading',   },             #
	0xbe	=> { name => 'SPEED_AVG', 		type => 'centiMetersPerSec', },		#
	0xbf	=> { name => 'DEPTH_AVG',		type => 'depth',     },             #
	0xc1	=> { name => 'COG2',			type => 'heading',   },             #
	0xc3	=> { name => 'WP_HEADING3',		type => 'heading', 	 },				#
	0xc4	=> { name => 'WP_LATLON',		type => 'latLon',    },             #
	0xc5	=> { name => 'WP_NORTHEAST',	type => 'northEast', },             #
	0xcf	=> { name => 'WP_LEG_DIST?',	type => 'distanceMeters', },		#
	0xd0	=> { name => 'WP_TIME',			type => 'seconds',      },          # seconds
	0xd8	=> { name => 'WP_NAME',			type => 'string15',  },				# might be null terminated; remove empty spaces
	0xdf	=> { name => 'TIME3',			type => 'time',      },             #
	0xee	=> { name => 'TIME4',			type => 'time',      },             #
	0xef	=> { name => 'DATE2',			type => 'date',      },             #
	0xf2	=> { name => 'SET_AVG',			type => 'heading',   },             #
	0xf3	=> { name => 'SET_MAG_AVG',		type => 'heading',   },             #
	0xfa	=> { name => 'TOTAL_FUEL',		type => 'deciLitresToGallons',},	# gallons
	0xff	=> { name => 'FUEL_CAPACITY2',	type => 'deciLitresToGallons',},	# gallons

);



#---------------------------------------------------
# implementation
#---------------------------------------------------

sub init
{
	my ($this) = @_;
	display($dbg,0,"d_DB init($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto}");
	$this->SUPER::init();
	$this->{local_ip} = $LOCAL_IP;
	$this->{inited} = 0;
	$this->{exists} = shared_clone({});
	$self_db = $this;
	return $this;
}


sub destroy
{
	my ($this) = @_;
	display($dbg,0,"d_DB destroy($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto}");
	$this->SUPER::destroy();
	$self_db = undef;

    delete @$this{qw()};
	return $this;
}


sub uiInit
{
	my ($this) = @_;
	display($dbg,0,"d_DB uiInit()");
	$this->{exists} = shared_clone({});
	$this->{inited} = 0;
}


sub onConnect
{
	my ($this) = @_;
	#	if (1 && $this->{auto_populate})
	#	{
	#		my $command = shared_clone({
	#			name => 'populate' });
	#		push @{$this->{command_queue}},$command;
	#	}
}



sub onIdle
{
	my ($this) = @_;
	display($dbg+2,0,"$this->{name} onIdle()");

	if (!$this->{inited})
	{
		if ($HOW_INIT == $INIT_NONE)
		{
			warning($dbg,0,"INIT_NONE");
			$this->{inited} = 1;
			return;
		}

		my @fids = $HOW_INIT == $INIT_KNOWN ?
			(sort {$a <=> $b} keys %DB_FIELDS) :
			(0x02 .. 0xff);

		my $any = 0;
		my $exists = $this->{exists};
		
		for my $fid (@fids)
		{
			next if $exists->{$fid};
			$any++;

			my $fid_name = $DB_FIELDS{$fid}->{name} || sprintf("UNKNOWN(%02x)",$fid);
			display($dbg+1,0,"CMD_UUID: $fid_name");
			$this->sendDBCommand(
				$DIRECTION_SEND,
				$DB_CMD_UUID,
				$fid);

			if (0)
			{
				my $seq = $this->{next_seqnum}++;
				$this->{wait_seq} = $seq;
				$this->{wait_name} = "CMD_NAME: $fid_name";
				$this->sendDBCommand(
					$DIRECTION_SEND,
					$DB_CMD_NAME,
					$fid,
					$seq);
				my $reply = $this->waitReply(0);
			}

			$exists->{$fid} = 1;
		}

		$this->{inited} = 1 if !$any;
	}
}




sub sendDBCommand
{
	my ($this,$dir,$cmd,$fid,$seq) = @_;
	my $cmd_name = apps::raymarine::NET::e_DB::dbCmdName($cmd);
	display($dbg+1,0,sprintf("sendDBCommand("._def($seq).",0x%02x)=$cmd_name",$cmd));

	return error("No 'this' in queueTRACKCommand") if !$this;
	return error("Not started") if !$this->{started};
	return error("Not running") if !$this->{running};

	my $cmd_word = $dir | $cmd;
	my $payload =
		pack('v',$cmd_word).
		pack('v',$DB_SERVICE_ID);
	$payload .= pack('V',$seq) if $seq;
	$payload .= pack('V',$fid);
	my $len = length($payload);
	$payload = pack('v',$len).$payload;
	$this->sendPacket($payload);
}

	



#===========================================================================
# e_DB parser
#===========================================================================

package apps::raymarine::NET::e_DB;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::a_mon;
use apps::raymarine::NET::a_utils;
use base qw(apps::raymarine::NET::a_parser);

my $dbg_ep = 0;

BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(
	);
}



sub dbCmdName
{
	my ($cmd) = @_;
	return $DB_CMD_NAME{$cmd} || "UNKNOWN_CMD($cmd)";
}


sub fidName
{
	my ($fid) = @_;
	my $field_def = $DB_FIELDS{$fid};
	return $field_def ? $field_def->{name} : sprintf("UNKNOWN(%02x)",$fid);
}


sub newParser
{
	my ($class, $mon_defs) = @_;
	display($dbg_ep,0,"apps::raymarine::NET::e_DB::new($mon_defs->{name})");
	my $this = $class->SUPER::newParser($mon_defs);
	bless $this,$class;
	$this->{fids} = shared_clone({});
	return $this;
}




sub showFids
{
	my ($this) = @_;
	my $fids = $this->{fids};
	c_print("FIDS\n");
	my $pad1 = pad('',4);
	my $pad2 = pad('',8);

	for my $fid (sort {$a <=> $b} keys %$fids)
	{
		my $fid_rec = $fids->{$fid};
		my $uuid = $fid_rec->{uuid};
		my $def_buffer = $fid_rec->{def_buffer};
		my $name_buffer = $fid_rec->{name_buffer};

		c_print($pad1.sprintf("0x%08x\n",$fid));
		c_print($pad2."uuid = $uuid\n") if $uuid;
		c_print(parse_dwords($pad2."def_buffer  ",$def_buffer,1)) if $def_buffer;
		c_print(parse_dwords($pad2."name_buffer ",$name_buffer,1)) if $name_buffer;
	}
}




sub assignFields
{
	my ($fid_rec,$packet,@fields) = @_;
	my $fid = $fid_rec->{fid};
	for my $field (@fields)
	{
		my $new_value = $packet->{$field};
		next if !defined($new_value);
		my $old_value = $fid_rec->{$field};
		if (!defined($old_value))
		{
			$fid_rec->{$field} = $new_value;
			next;
		}

		warning(0,0,"fid($fid) field($field) VALUE CHANGED")
			if $old_value ne $new_value;
	}
}



sub parsePacket
	# Sets up class specific state members, then
	# calls base class to do all the work.
{
	my ($this,$packet) = @_;

	display($dbg_ep+1,0,"apps::raymarine::NET::e_DB::parsePacket() is_reply($packet->{is_reply})");
	my $rslt = $this->SUPER::parsePacket($packet);

	my $fid = $packet->{fid};
	if ($rslt && $fid)
	{
		$fid &= 0xff;
		$this->{fids}->{$fid} ||= shared_clone({ fid => $fid });
		my $fid_rec = $this->{fids}->{$fid};
		assignFields($fid_rec,$packet,qw(uuid def_buffer name_buffer));
	}

	return $rslt;
}



sub parseMessage
	# Calls base_clase BEFORE doing derived class specific stuff.
	# and checking twice for rules,
{
	my ($this,$packet,$len,$part) = @_;
	display($dbg_ep+2,0,"apps::raymarine::NET::e_DB::parseMessage($len)");
	return undef if !$this->SUPER::parseMessage($packet,$len,$part);

	my $cmd_word = unpack('v',substr($part,0,2));
	my $cmd = $cmd_word & 0xff;
	my $dir = $cmd_word & 0xff00;

	my $cmd_name = dbCmdName($cmd);
	my $dir_name = $DIRECTION_NAME{$dir};
	display($dbg_ep+2,1,"apps::raymarine::NET::e_DB::parseMessage() dir($dir)=$dir_name cmd($cmd)=$cmd_name");;

	my $mon = $packet->{mon};
	printConsole(1,$mon,$packet->{color},"$dir_name $cmd_name")
		if $mon & $MON_PARSE;

	# get the rule

	my $rule = $DB_PARSE_RULES{ $cmd_word };
	if (!$rule)
	{
		error("NO RULE dir($dir)=$dir_name cmd($cmd)=$cmd_name") if !$rule;
		return $packet;
	}

	# parse the pieces

	my $offset = 4;				# skip cmd_word and sid
	for my $piece (@$rule)
	{
		$this->parsePiece(
			$packet,
			$piece,
			$part,
			\$offset);			# for checking big_len
	}

	return $packet;
}




sub parsePiece
{
	my ($this,$packet,$piece,$part,$poffset) = @_;
	my $mon = $packet->{mon};
	my $color = $packet->{color};

	if ($piece eq 'def_buffer' ||
		$piece eq 'name_buffer')
	{
		printConsole(2,$mon,$color,$piece)
			if $mon & $MON_PIECES;
		$packet->{$piece} = substr($part,$$poffset);
	}
	elsif ($piece eq 'success2')
	{
		my $status = unpack('H*',substr($part,$$poffset,4));
		my $ok = $status eq $SUCCESS2_SIG ? 1 : 0;
		$packet->{success} = $ok;
		$$poffset += 4;
		printConsole(2,$mon,$color,"$piece = $ok")
			if $mon & $MON_PIECES;
	}
	elsif ($piece =~ /^(db_bits|word)$/)				# one word (flag on wpmgr changed events)
	{
		my $word = unpack('H*',substr($part,$$poffset,2));
		$packet->{$piece} = $word;
		$$poffset += 2;
		printConsole(2,$mon,$color,"$piece = $word")
			if $mon & $MON_PIECES;
	}
	elsif ($piece eq 'fid')				# fid was referenced
	{
		my $fid_str = substr($part,$$poffset,4);
		my $fid_hex = unpack('H*',$fid_str);
		my $fid = unpack('V',$fid_str);

		$packet->{$piece} = $fid;
		$$poffset += 4;
		printConsole(2,$mon,$color,"$piece = '$fid_hex' = ".sprintf('0x%x',$fid)." ".fidName($fid & 0xff))
			if $mon & $MON_PIECES;
	}
	else
	{
		return $this->SUPER::parsePiece($packet,$piece,$part,$poffset)
	}
	return 1;
}




1;