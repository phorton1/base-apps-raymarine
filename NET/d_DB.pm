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

package d_DB;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use a_utils;
use a_defs;
use base qw(b_sock);


my $dbg = 0;



BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(

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

	);
}



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


my $DB_FIELD_SPEED 				= 0x03;		# thru water
my $DB_FIELD_SOG				= 0x04;
my $DB_FIELD_LOG_TOTAL			= 0x07;
my $DB_FIELD_LOG_TRIP			= 0x08;
my $DB_FIELD_DEPTH				= 0x09;
my $DB_FIELD_TIME				= 0x12;
my $DB_FIELD_DATE 				= 0x13;
my $DB_FIELD_HEADING 			= 0x17;
my $DB_FIELD_SET 				= 0x18;
my $DB_FIELD_DRIFT 				= 0x19;
my $DB_FIELD_COG 				= 0x1a;
my $DB_FIELD_HEAD_MAYBE 		= 0x1c;		# just a guess
my $DB_FIELD_LATLON				= 0x44;
my $DB_FIELD_HEADING_MAG		= 0x47;
my $DB_FIELD_HEADING_MAG2		= 0x48;
my $DB_FIELD_WIND_SPEED_APP		= 0x58;
my $DB_FIELD_WIND_ANGLE_APP		= 0x59;		# 360 relative to bow heading
my $DB_FIELD_WIND_SPEED_TRUE	= 0x5a;
my $DB_FIELD_WIND_ANGLE_TRUE	= 0x5b;		# 360 relative to bow heading
my $DB_FIELD_WIND_SPEED_GND		= 0x5c;
my $DB_FIELD_WIND_ANGLE_GND		= 0x5d;		# 360 relative to bow heading
my $DB_FIELD_WP_HEADING			= 0x66;
my $DB_FIELD_WP_HEADING_MAG		= 0x67;
my $DB_FIELD_WP_DISTANCE		= 0x6a;		# only to two decimal places (60 feet)
my $DB_FIELD_NORTHEAST			= 0x93;
my $DB_FIELD_LATLON2			= 0x99;
my $DB_FIELD_TIME2				= 0x9c;
my $DB_FIELD_DATE2 				= 0xaa;
my $DB_FIELD_HEAD2 				= 0xba;
my $DB_FIELD_HEAD3 				= 0xbb;
my $DB_FIELD_HEAD4 				= 0xbc;
my $DB_FIELD_HEAD5 				= 0xbd;
my $DB_FIELD_AVG_SPEED 			= 0xbe;
my $DB_FIELD_AVG_DEPTH			= 0xbf;
my $DB_FIELD_WP_LATLON			= 0xc4;
my $DB_FIELD_WP_NORTHEAST		= 0xc5;
my $DB_FIELD_WP_NAME			= 0xd8;
my $DB_FIELD_TIME3				= 0xdf;
my $DB_FIELD_TIME4				= 0xee;




our %DB_FIELDS = (

	$DB_FIELD_SPEED 			=> { name => 'SPEED', 			type => 'centiMetersPerSec', },		# 0x03
	$DB_FIELD_SOG				=> { name => 'SOG', 			type => 'centiMetersPerSec', },     # 0x04
	$DB_FIELD_LOG_TOTAL			=> { name => 'LOG_TOTAL',		type => 'distanceMeters', },		# 0x07
	$DB_FIELD_LOG_TRIP			=> { name => 'LOG_TRIP',		type => 'distanceMeters', },		# 0x08
	$DB_FIELD_DEPTH				=> { name => 'DEPTH',			type => 'depth',     },             # 0x09
	$DB_FIELD_TIME				=> { name => 'TIME',			type => 'time',      },             # 0x12
	$DB_FIELD_DATE 				=> { name => 'DATE',			type => 'date',      },             # 0x13
	$DB_FIELD_HEADING 			=> { name => 'HEADING',			type => 'heading',   },             # 0x17
	$DB_FIELD_SET 				=> { name => 'SET',				type => 'heading',   },             # 0x18
	$DB_FIELD_DRIFT 			=> { name => 'DRIFT',			type => 'centiMetersPerSec',   },   # 0x19
	$DB_FIELD_COG 				=> { name => 'COG',				type => 'heading',   },             # 0x1a
	$DB_FIELD_HEAD_MAYBE		=> { name => 'HEAD_MAYBE',		type => 'heading',   },             # 0x1c
	$DB_FIELD_LATLON			=> { name => 'LATLON',			type => 'latLon',    },             # 0x44
	$DB_FIELD_HEADING_MAG		=> { name => 'HEADING_MAG',		type => 'heading',   },             # 0x47
	$DB_FIELD_HEADING_MAG2		=> { name => 'HEADING_MAG2',	type => 'heading',   },             # 0x48
	$DB_FIELD_WIND_SPEED_APP	=> { name => 'WIND_SPEED_APP', 	type => 'deciMetersPerSec', },		# 0x58
	$DB_FIELD_WIND_ANGLE_APP	=> { name => 'WIND_ANGLE_APP',	type => 'heading',   },             # 0x59
	$DB_FIELD_WIND_SPEED_TRUE	=> { name => 'WIND_SPEED_TRUE', type => 'deciMetersPerSec', },		# 0x5a
	$DB_FIELD_WIND_ANGLE_TRUE	=> { name => 'WIND_ANGLE_TRUE',	type => 'heading',   },             # 0x5b
	$DB_FIELD_WIND_SPEED_GND	=> { name => 'WIND_SPEED_GND', 	type => 'deciMetersPerSec', },		# 0x5c
	$DB_FIELD_WIND_ANGLE_GND	=> { name => 'WIND_ANGLE_GND',	type => 'heading',   },             # 0x5d
	$DB_FIELD_WP_HEADING		=> { name => 'WP_HEADING',		type => 'heading', 	 },				# 0x66
	$DB_FIELD_WP_HEADING_MAG	=> { name => 'WP_HEADING_MAG',	type => 'heading', 	 },				# 0x67
	$DB_FIELD_WP_DISTANCE		=> { name => 'WP_DISTANCE',		type => 'distanceMeters', },		# 0x6a
	$DB_FIELD_NORTHEAST			=> { name => 'NORTHEAST',		type => 'northEast', },             # 0x93
	$DB_FIELD_LATLON2			=> { name => 'LATLON2',			type => 'latLon',    },             # 0x99
	$DB_FIELD_TIME2				=> { name => 'TIME3',			type => 'time',  	 },      		# 0x9c
	$DB_FIELD_DATE2				=> { name => 'DATE2',			type => 'date',      },             # 0xaa
	$DB_FIELD_HEAD2 			=> { name => 'HEAD2',			type => 'heading',   },             # 0xba
	$DB_FIELD_HEAD3 			=> { name => 'HEAD3',			type => 'heading',   },             # 0xbb
	$DB_FIELD_HEAD4 			=> { name => 'HEAD4',			type => 'heading',   },             # 0xbc
	$DB_FIELD_HEAD5 			=> { name => 'HEAD5_MAG',		type => 'heading',   },             # 0xbd
	$DB_FIELD_AVG_SPEED			=> { name => 'AVG_SPEED', 		type => 'centiMetersPerSec', },		# 0xbe
	$DB_FIELD_AVG_DEPTH			=> { name => 'AVG_DEPTH',		type => 'depth',     },             # 0xbf
	$DB_FIELD_WP_LATLON			=> { name => 'WP_LATLON',		type => 'latLon',    },             # 0xc4
	$DB_FIELD_WP_NORTHEAST		=> { name => 'WP_NORTHEAST',	type => 'northEast', },             # 0xc5
	$DB_FIELD_WP_NAME			=> { name => 'WP_NAME',			type => 'stringNul', },				# 0xd8
	$DB_FIELD_TIME3				=> { name => 'TIME3',			type => 'time',      },             # 0xdf
	$DB_FIELD_TIME4				=> { name => 'TIME4',			type => 'time',      },             # 0xee



);






sub init
{
	my ($this) = @_;
	display($dbg,0,"d_DB init($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto}");
	$this->SUPER::init();
	$this->{local_ip} = $LOCAL_IP;
	return $this;
}



sub destroy
{
	my ($this) = @_;
	display($dbg,0,"d_DB destroy($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto}");
	$this->SUPER::destroy();
    delete @$this{qw()};
	return $this;
}


sub onConnect
{
	my ($this) = @_;
	if (1 && $this->{auto_populate})
	{
		my $command = shared_clone({
			name => 'populate' });
		push @{$this->{command_queue}},$command;
	}
}



sub handleCommand
{
	my ($this,$command) = @_;
	display($dbg,0,"$this->{name} handleCommand(command->{name}) started");

	my %done;
	my @keys = (0x02 .. 0xff);	# sort {$a <=> $b} keys %DB_FIELDS;
	my $stage = 0;
	
	while ($stage < 1)
	{
		display($dbg,1,"doing stage($stage)");
		
		my $cmd1;
		my $cmd2;
		if ($stage & 1)
		{
			$cmd1 = $DB_CMD_UUID;
			$cmd2 = $DB_CMD_NAME;
		}
		else
		{
			$cmd1 = $DB_CMD_FIELD;
			$cmd2 = $DB_CMD_QUERY;
		}

		for my $fid (@keys)
		{
			my $done = $done{$fid};
			next if $done;

			my $send_fid = $fid;
			if ($stage >= 4)
			{
				$send_fid |= 0x03000000;
			}
			elsif ($stage >= 2)
			{
				$send_fid |= 0x01010000;
			}


			my $seq = $this->{next_seqnum}++;
			my $name = $DB_FIELDS{$fid}->{name} || sprintf("UNKNOWN(%02x)",$fid);
			my $cmd_name = $DB_CMD_NAME{$cmd2};

			display($dbg+1,2,"stage($stage) $cmd_name-$name");

			$this->{wait_seq} = $seq;
			$this->{wait_name} = "$stage-$cmd_name-$name";

			# sleep(0.01);
			$this->sendDBCommand(
				$DIRECTION_SEND,
				$cmd1,
				$send_fid);

			if (1)
			{
				# sleep(0.01);
				$this->sendDBCommand(
					$DIRECTION_SEND,
					$cmd2,
					$send_fid,
					$seq);

				my $reply = $this->waitReply(0);
				if (!$reply)
				{
					# sleep(0.5);
					next;
				}
				display($dbg+1,3,"got reply success="._def($reply->{success}));
				$done{$fid} = 1 if
					$reply->{success} &&
					($reply->{uuid} || $reply->{def_buffer});
			}
		}

		display($dbg,2,"stage($stage) finished");
		$stage++;
	}
	display($dbg,2,"$this->{name} handleCommand() finished");
}




sub sendDBCommand
{
	my ($this,$dir,$cmd,$fid,$seq) = @_;
	my $cmd_name = e_DB::dbCmdName($cmd);
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

package e_DB;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use a_defs;
use a_mon;
use a_utils;
use base qw(a_parser);

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
	display($dbg_ep,0,"e_DB::new($mon_defs->{name})");
	my $this = $class->SUPER::newParser($mon_defs);
	bless $this,$class;
	$this->{fids} = shared_clone({});
	return $this;
}




sub showFids
{
	my ($this) = @_;
	my $fids = $this->{fids};
	print "FIDS\n";
	my $pad1 = pad('',4);
	my $pad2 = pad('',8);

	for my $fid (sort {$a <=> $b} keys %$fids)
	{
		my $fid_rec = $fids->{$fid};
		my $uuid = $fid_rec->{uuid};
		my $def_buffer = $fid_rec->{def_buffer};
		my $name_buffer = $fid_rec->{name_buffer};

		print $pad1.sprintf("0x%08x\n",$fid);
		print $pad2."uuid = $uuid\n" if $uuid;
		print parse_dwords($pad2."def_buffer  ",$def_buffer,1) if $def_buffer;
		print parse_dwords($pad2."name_buffer ",$name_buffer,1) if $name_buffer;
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

	display($dbg_ep+1,0,"e_DB::parsePacket() is_reply($packet->{is_reply})");
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
	display($dbg_ep+2,0,"e_DB::parseMessage($len)");
	return undef if !$this->SUPER::parseMessage($packet,$len,$part);

	my $cmd_word = unpack('v',substr($part,0,2));
	my $cmd = $cmd_word & 0xff;
	my $dir = $cmd_word & 0xff00;

	my $cmd_name = dbCmdName($cmd);
	my $dir_name = $DIRECTION_NAME{$dir};
	display($dbg_ep+2,1,"e_DB::parseMessage() dir($dir)=$dir_name cmd($cmd)=$cmd_name");;

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