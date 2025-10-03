#---------------------------------------------
# r_utils.pm
#---------------------------------------------

package nq_packet;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use nq_parse;

my $dbg_nq = 1;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(

		parseNQPacket

		$SUCCESS_SIG

		%NAV_DIRECTION
		%NAV_WHAT
		%NAV_COMMAND

		$DIR_RECV
		$DIR_SEND
		$DIR_INFO

		$WHAT_WAYPOINT
		$WHAT_ROUTE
		$WHAT_GROUP
		$WHAT_DATABASE

		$CMD_CONTEXT
		$CMD_BUFFER
		$CMD_LIST
		$CMD_ITEM
		$CMD_EXIST
		$CMD_EVENT
		$CMD_DATA
		$CMD_MODIFY
		$CMD_UUID
		$CMD_NUMBER
		$CMD_AVERB
		$CMD_BVERB
		$CMD_FIND
		$CMD_COUNT
		$CMD_EVERB
		$CMD_FVERB
		
    );
}



our $DIR_RECV		= 0x000;
our $DIR_SEND		= 0x100;
our $DIR_INFO		= 0x200;

our $WHAT_WAYPOINT	= 0x00;
our $WHAT_ROUTE		= 0x40;
our $WHAT_GROUP		= 0x80;
our $WHAT_DATABASE	= 0xb0;

our $CMD_CONTEXT	= 0x0;
our $CMD_BUFFER    	= 0x1;
our $CMD_LIST     	= 0x2;
our $CMD_ITEM		= 0x3;
our $CMD_EXIST		= 0x4;
our $CMD_EVENT     	= 0x5;
our $CMD_DATA		= 0x6;
our $CMD_MODIFY    	= 0x7;
our $CMD_UUID    	= 0x8;
our $CMD_NUMBER     = 0x9;
our $CMD_AVERB     	= 0xa;
our $CMD_BVERB     	= 0xb;
our $CMD_FIND		= 0xc;
our $CMD_COUNT     	= 0xd;
our $CMD_EVERB    	= 0xe;
our $CMD_FVERB     	= 0xf;


our $SUCCESS_SIG = '00000400';


our %NAV_DIRECTION = (
	$DIR_RECV => 'recv',
	$DIR_SEND => 'send',
	$DIR_INFO => 'info',
);

our %NAV_WHAT = (
	$WHAT_WAYPOINT  => 'WAYPOINT',
	$WHAT_ROUTE		=> 'ROUTE',
	$WHAT_GROUP		=> 'GROUP',
	$WHAT_DATABASE  => 'DATABASE',
);


our %NAV_COMMAND = (
	$CMD_CONTEXT => 'CONTEXT',
	$CMD_BUFFER  => 'BUFFER',
	$CMD_LIST    => 'LIST',
	$CMD_ITEM	 => 'ITEM',
	$CMD_EXIST	 => 'EXIST',
	$CMD_EVENT   => 'EVENT',
	$CMD_DATA	 => 'DATA',
	$CMD_MODIFY  => 'MODIFY',
	$CMD_UUID    => 'UUID',
	$CMD_NUMBER  => 'NUMBER',
	$CMD_AVERB   => 'AVERB',
	$CMD_BVERB   => 'BVERB',
	$CMD_FIND	 => 'FIND',
	$CMD_COUNT   => 'COUNT',
	$CMD_EVERB   => 'EVERB',
	$CMD_FVERB   => 'FVERB',
);


# SENDS and RECEIVES establish context

my $CTX_DATABASE = $CMD_CONTEXT | $WHAT_DATABASE;

my %PARSE_RULES = (

	# monadic

	$DIR_SEND	| $CMD_COUNT	=> [],		# can this count Routes & Groups?
	$DIR_SEND	| $CMD_EVERB	=> [],		# only ever seen $WHAT_GROUP
	$DIR_SEND	| $CMD_CONTEXT  => [],		# establishes WHAT context;
	$DIR_SEND	| $CTX_DATABASE => [],		# WHAT_DATABASE is a special case

	# single dword parameter

	$DIR_RECV	| $CMD_EVENT	=> [ 'flag'  ],			# seq is 0/1 and events must be handled specially
														# 0 seems to be 'start' and 1 seems to be 'end'
														# WHAT appears to have 'generally' been changed
														# specific MODIFY recvs may be included with uuids and bits
	$DIR_RECV	| $CMD_NUMBER	=> [ 'count'	],		# count of used items (per WHAT?)
	$DIR_RECV	| $CTX_DATABASE	=> [ 'counter'	],		# DATABASE is a specific reeply non standard reply
	$DIR_RECV	| $CMD_AVERB	=> [ 'amagic'	],		# non standard, not understood reply
	$DIR_RECV	| $CMD_CONTEXT	=> [ 'success'  ],  	#
	$DIR_RECV	| $CMD_DATA		=> [ 'success'	],		# establishes WHAT context
	$DIR_RECV	| $CMD_ITEM		=> [ 'success'	],		# reply to a successful delete (from sending UUID)
	$DIR_RECV	| $CMD_BUFFER	=> [ 'success'	],		# a response to an EXIST uuid call to delete a folder (no actual buffer)
	$DIR_RECV	| $CMD_EXIST	=> [ 'success'	],		# reply to a successful delete (from sending UUID)

	# success & uuid

	$DIR_RECV	| $CMD_UUID		=> [ 'success',	'uuid' ],	# reply to FIND

	# single parameter

	$DIR_SEND	| $CMD_ITEM		=> [ 'uuid'		],		# atomic command, returns DATA;
	$DIR_SEND	| $CMD_MODIFY 	=> [ 'uuid'		],		# I send this with no bits to start create_item()
	$DIR_SEND	| $CMD_UUID		=> [ 'uuid'		],		# REALLY seems to mean 'delete' on a send, and info on a recv
	$DIR_INFO	| $CMD_LIST		=> [ 'uuid'		],		# 00000000 00000000 = send/receive for listing indexes
	$DIR_INFO	| $CMD_LIST		=> [ 'uuid'		],		# received with uuid at end of DATA series
	$DIR_SEND	| $CMD_FIND		=> [ 'name16' 	],		# atomic command, returns UUID (used to be DELETE)

	# uuid and bits

	$DIR_RECV	| $CMD_MODIFY	=> [ 'uuid', 'bits' ],	# Received within EVENT series with specific uuid and bits 0,1, or 2
	$DIR_INFO	| $CMD_CONTEXT	=> [ 'uuid', 'bits' ],
		# 00000000 00000000 1n00000000	1n indicates DICTIONARY, n is 9,a
		# zzzzzzzz zzzzzzzz 0n00000000	0n indicates ITEM		 n is 1,3
		# zzzzzzzz zzzzzzzz 0300000000	I send for create_item() and modify_item()

	# leading magic number and uuid

	$DIR_SEND	| $CMD_EXIST	=> [ 'magic', 'uuid' ],		# atomic command BUT required for modify_item()
	$DIR_SEND	| $CMD_DATA		=> [ 'magic', 'uuid' ],		# I use rhia, after EXIST, for modify_item
		# 07000000 	cccccccc cccf0100
		# 0a000000 	dc82a921 f567e68e 	deleting a folder

	$DIR_INFO 	| $CMD_BUFFER 	=> [ 'buffer' ],
		# $CMD_BUFFER is handled specially
		# bits(1n00000) = dict_buffer_data	on send, CONTEXT bits(0x1n) the buffer is some kind of allocation scheme
		#									on recv, CONTEXT bits(0x1n) indicatss an INDEX (or dictionary if you prefer)
		# bits(0n00000) = item buffer 		on send/recv bits(0x0n) indicates an ITEM buffer, uuid given previously in series
);








#--------------------------------------------------
# parseNQPacket
#--------------------------------------------------
#
# The nav_congext is a shared record consisting of
#
#	what => the kind of thing being talked about
#	uuid => the uuid of the thing being talked about
#   dict => 0/1 the bits of the thing being talked about
#   		where bits(0x1n) indicates a dictionary whose buffers are only parsed on recv
#				and are really a space allocation mechanism on send
#           and 0x0n indicates an item in either direction


my %nav_context:shared;

sub init_context
{
	my ($client_port,$is_reply) = @_;
	my $context = $nav_context{$client_port};
	$context = $nav_context{$client_port} = shared_clone({})
		if !$context;
	$context->{what} = '';
	$context->{dict} = 0;
	$context->{client_port} = $client_port;
	$context->{is_reply} = $is_reply;
}




sub parseNQPacket
	# with normal packets, it's src_port --> dest_port
	# but for nav packets, its NAVQRY <-> client_port
	# is_request should be passed in as one when the
	# source is NOT NAVQRY
{
	my ($is_reply,$client_port,$raw_data) = @_;
	display($dbg_nq,0,"parseNavPacket($is_reply,$client_port) ".unpack('H*',$raw_data));

	# create the header

	my $arrow = $is_reply ? '-->' : '<--';
	my $first_header = pad('NAVQRY',7).$arrow.' '.pad($client_port,7);
	my $header_len = length($first_header);

	# output messages loop

	my $num = 0;
	my $text = '';
	my $offset = 0;
	my $rec = shared_clone({});
	my $packet_len = length($raw_data);

	while ($offset < $packet_len)
	{
		my $data_len = unpack('v',substr($raw_data,$offset,2));
		my $hex_len = unpack('H*',substr($raw_data,$offset,2));
		my $data = substr($raw_data,$offset+2,$data_len);
		my $header = $num ? pad('',$header_len) : $first_header;

		$text .= r_utils::parse_dwords($header.$hex_len.' ',$data,1);

		# get the comand word and move past {seq_num}

		my $command_word = unpack('v',$data);
		my $D = $command_word & 0xf00;	# substr($hex_data,3,1);
		my $W = $command_word & 0xf0;	# substr($hex_data,0,1);
		my $C = $command_word & 0xf;	# substr($hex_data,1,1);
		my $dir = $NAV_DIRECTION{$D};
		my $command = $NAV_COMMAND{$C};
		my $what = $NAV_WHAT{$W};

		init_context($client_port,$is_reply) if $D != $DIR_INFO;
		my $context = $nav_context{$client_port};
		$context->{what} = $W if $W || $D != $DIR_INFO;
		my $show_what = $NAV_WHAT{$context->{what}};

		display($dbg_nq,1,"PART($num) offset($offset) dir($dir) command($command) what($what) context($show_what) dict($context->{dict}) uuid($context->uuid})");
		display($dbg_nq,2,"data=".unpack('H*',$data));


		# advance outer loop to next message

		$offset += 2 + $data_len;
		$num++;

		# the actual data starts after the cmd_word, 0f00, and the dword sequence number
		# MODIFY and EVENT dont have sequence numbers on replies
		
		my $data_offset = 8;
		$data_offset = 4 if $is_reply && (
			$C == $CMD_MODIFY ||
			$C == $CMD_EVENT );

		# find rule, first by full command word, then by $dir | $cmd

		my $rule = $PARSE_RULES{$command_word};
		$rule = $PARSE_RULES{ $D | $C } if !$rule;
		if ($rule)
		{
			my $comment = '';
			for my $piece (@$rule)
			{
				$comment .= parsePiece(
					$rec,
					$piece,
					$data,
					\$data_offset,
					$context,
					$header_len + 2);	# indent buffer records a bit
			}
			$text .= "     # $dir: ".pad($command,8).pad($show_what,9)."$comment\n";
		}
		else # NO RULE!
		{
			my $msg = "NO RULE FOR $dir | $command | $what";
			warning(0,2,$msg);
			$text .= "     # $msg\n";
		}
	}

	mergeHash($rec,$nav_context{$client_port});
	display_hash(0,8,"rec",$rec);
	# $$prec = $rec;
	return $text;
}


sub parsePiece
{
	my ($rec,$piece,$data,$pdata,$context,$indent) = @_;

	my $text = '';

	if ($piece eq 'buffer')
	{
		if (!$context->{dict})
		{
			my $detail_level = 2;
			my $show_what = $NAV_WHAT{$context->{what}};
			my $item = parseNQRecord($show_what,substr($data,$$pdata));
			$text = displayNQRecord($item,$show_what,$indent,$detail_level);
			$rec->{item} = $item;
		}
		elsif ($context->{is_reply})
		{
			$$pdata += 4;	# skiip biglen
			my $num = unpack('V',substr($data,$$pdata,4));
			$$pdata += 4;

			$text .= "dictionary($num)".($num?"\n":'');
			my $pad = pad('',$indent);
			my $uuids = $rec->{uuids} = shared_clone([]);
			for (my $i=0; $i<$num; $i++)
			{
				my $uuid = unpack('H*',substr($data,$$pdata,8));
				$$pdata += 8;
				$text .= $pad."uuid($i) = $uuid\n";
			}
		}
	}
	elsif ($piece eq 'uuid')
	{
		my $uuid = unpack('H*',substr($data,$$pdata,8));
		$rec->{uuid} = $uuid;
		$text = " uuid=$uuid";
		$$pdata += 8;
	}
	elsif ($piece eq 'name16')
	{
		my $name = unpack('Z*',substr($data,$$pdata,17));
		$rec->{name} = $name;
		$text = " name = $name";
		$$pdata += 17;
	}
	elsif ($piece eq 'success')
	{
		my $status = unpack('H*',substr($data,$$pdata,4));
		my $ok = $status eq $SUCCESS_SIG ? 1 : 0;
		$rec->{success} = $ok;
		$text .= $ok ? ' success' : ' failed';
		$$pdata += 4;
	}
	else
	{
		my $str = substr($data,$$pdata,4);
		my $value = unpack('V',$str);
		$context->{dict} = 1 if $piece eq 'bits' && $value & 0x10;
		$rec->{$piece} = $value;
		$value = sprintf("0x%02x",$value) if $piece !~ /count|flag/;
		$text .= " $piece=$value";
		$$pdata += 4;

	}

	return $text;
}





1;
