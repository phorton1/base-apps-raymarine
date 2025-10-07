#---------------------------------------------
# wp_packet.pm
#---------------------------------------------
# Parses stateful WPMGR Requests and Replies.
# A Request or Reply is a series of Messages.
#
# The BUFFER message contains the actual WAYPOINTS, ROUTES, and/or GROUPS
# as well as Dictonaries of the uuids of the WRG's that exist on the E80.
#
# There's a fairly substantial difference between wanting to
# see whats going on, and coding the most efficient minimum
# functionality needed to support WPMGR.
#
# - display() statements, even without being output, take time to evaluate.
# - generating a huge amount of text that I probably wont need in a "real"
#   implementation takes even more time.
# - constantly monitoring all ethernet traffic to all RAYSYS ports using tshark
#   "just in case" is a huge hit.
# - writing it all to a log file is a disk hit.
#
# None of the above would be done in a lean-mean working implementation
# that did not additional try to watch all traffic to and/from the E80
# using tshark.
#
# There is still the issue of the way "waitReply()" is decoupled from
# read_buf() in r_WPMGR.pm, and the fact that "events" (incluing
# CMD_MONITOR) just don't fit into that scheme. Yet I am so close.
#
# - Instead of relying on a Query to get records, I *should* be using
#   events, although RNS itself essentially does a query at startup.
# - Real multi-cast listenters would be more efficient than tshark.

package wp_packet;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time sleep);
use Pub::Utils;
use wp_parse;

my $dbg_wpp = 1;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(

		parseWPMGR

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

my $CTX_DATABASE = $WHAT_DATABASE | $CMD_CONTEXT;
my $LST_DATABASE = $WHAT_DATABASE | $CMD_LIST;
my $BUF_DATABASE = $WHAT_DATABASE | $CMD_BUFFER ;

# This list includes every Request and Reply I have ever
# seen between the E80 and RNS.  We only use some (most) of them.

my %PARSE_RULES = (

	# monadic

	$DIR_SEND	| $CMD_COUNT	=> [],		# returns NUMBER; can this count Routes & Groups?
	$DIR_SEND	| $CMD_EVERB	=> [],		# returns AVERB; only ever seen $WHAT_GROUP
	$DIR_SEND	| $CMD_CONTEXT  => [],		# both ways, establishes WHAT context;

	$DIR_SEND	| $CTX_DATABASE => [],		# WHAT_DATABASE is a special case
	$DIR_SEND	| $LST_DATABASE => [],		# WHAT_DATABASE is a special case
	$DIR_SEND	| $BUF_DATABASE => [],		# WHAT_DATABASE is a special case

	# single dword parameter
	# CMD_EVENT consists of a series of messages, starting with
	# FIND CMD_EVENT(0)'s ending with WHAT CMD_EVENT(1)'s bracketing
	# zero or more MODIFY messages

	$DIR_RECV	| $CMD_EVENT	=> [ 'evt_flag'  ],
		# Does not have a sequence number, uhm,
		# That dword is 0 or 1 inicating start, and end of an event series.
		# Indicates, generrally that WHAT items/dictinoaries have changed.
		# Brackets MODIFY messages with more detail about what changed.

	$DIR_RECV	| $CMD_NUMBER	=> [ 'db_count'	],		# count of used items (per WHAT?)
	$DIR_RECV	| $CTX_DATABASE	=> [ 'db_version' ],	# DATABASE is a specific non standard reply
	$DIR_RECV	| $CMD_AVERB	=> [ 'amagic'	],		# non standard, not understood reply

	$DIR_RECV	| $CMD_CONTEXT	=> [ 'success'  ],  	# can establish WHAT context
	$DIR_RECV	| $CMD_LIST		=> [ 'success'	],		# establishes WHAT context
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
	$DIR_SEND	| $CMD_FIND		=> [ 'name16' 	],		# atomic command, returns UUID

	# uuid and bits

	$DIR_RECV	| $CMD_MODIFY	=> [ 'uuid', 'mod_bits' ],
		# Does not have a sequence number.
		# Received alone, or within EVENT series
		# CMD_MODIFY (which doesn't have a sequence number) are out of band messages where bits
		#		0 = new
		#		1 = deleted
		#		2 = changed
		
	$DIR_INFO	| $CMD_CONTEXT	=> [ 'uuid', 'context_bits' ],
		# 00000000 00000000 1n00000000	1n indicates DICTIONARY, n is 9,a,c
		# zzzzzzzz zzzzzzzz 0n00000000	0n indicates ITEM		 n is 0,1,2,3
		# zzzzzzzz zzzzzzzz 0300000000	I send for create_item() and modify_item()

	# leading magic number and uuid

	$DIR_SEND	| $CMD_EXIST	=> [ 'magic', 'uuid' ],		# atomic command BUT required for modify_item()
	$DIR_SEND	| $CMD_DATA		=> [ 'magic', 'uuid' ],		# I use this, after EXIST, for modify_item
		# 07000000 	cccccccc cccf0100
		# 0a000000 	dc82a921 f567e68e 	deleting a folder

	$DIR_INFO 	| $CMD_BUFFER 	=> [ 'buffer' ],
		# $CMD_BUFFER is handled specially
		# bits(1n00000) = dict_buffer_data	on send, CONTEXT bits(0x1n) the buffer is some kind of allocation scheme
		#									on recv, CONTEXT bits(0x1n) indicatss an INDEX (or dictionary if you prefer)
		# bits(0n00000) = item buffer 		on send/recv bits(0x0n) indicates an ITEM buffer, uuid given previously in series
);



#--------------------------------------------------
# parseWPMGR
#--------------------------------------------------
# The nav_context is used to maintain state for the
# messages within a Request or Reply.  It is a hash
# by client_port, consisting of
#
#	what => the kind of thing being talked about
#	uuid => the uuid of the thing being talked about
#   dict => 0/1 whehter the BUFFER is an Item (WRG) or dictionary
#
# 'dict' is based on the context_bits founc in a CONTEXT message
# before the BUFFER message, where
#
#	0x1n 	where the 1 indicates a dictionary
#   0x0n	where the 0 indicates an item
#
# and 'n' is some kind of a state enumeration that is not clearly
# understood at this time


my %nav_context:shared;

sub init_context
	# We assume serialized replies never come in multiple packets,
	# so the context is re-initialized on EVERY reply, but only
	# on is_reply changes for sends.
{
	my ($client_port,$is_reply,$D,$force) = @_;
	$is_reply ||= 0;
	display($dbg_wpp+1,0,"init_context called client_port($client_port) is_reply($is_reply) D($D)=".$NAV_DIRECTION{$D}." force($force)");


	my $key = "$is_reply.$client_port";
	my $context = $nav_context{$key};
	$context = $nav_context{$key} = shared_clone({})
		if !$context;
	display_hash($dbg_wpp+2,1,"initial($key)",$context);

	# re-initialize context if $is_reply changes
	
	$is_reply ||= 0;
	$context->{is_reply} ||= 0;
		# avoid warnings - one of these is undefined often

	return $context if !$force &&
		defined($context->{is_reply}) &&
		$context->{is_reply} == $is_reply;

	display($dbg_wpp,0,"INITIALIZE CONTEXT client_port($client_port) is_reply($is_reply) D($D)=".$NAV_DIRECTION{$D}." force($force)");
	# display(0,1,"context_mods="._def($context->{mods}));

	# return if $D == $DIR_INFO || (
	# 	defined($context->{dir}) &&
	# 	$context->{dir} != $D);

	$context->{dir} = $D;
	$context->{what} = 0;
	$context->{is_dict} = 0;
	$context->{client_port} = $client_port;
	$context->{is_reply} = $is_reply;
	$context->{seq_num} = 0;
	$context->{is_event} = 0;

	display_hash($dbg_wpp+2,1,"returning fucking($key)",$context);
	return $context;
}


sub parseWPMGR
	# For the text with normal packets, it's src_port --> dest_port
	# 	but for nav packets, its WPMGR <-> client_port
	#
	# $is_reply is passed in as one when the source is NOT
	#	the WPMGR service
	# $client_port differentiates this program, shark, from RNS
	#	and is used as the key to the nav_context hash.
	# $raw_data is a fully re-assembled Request or Reply which
	#	are usually received in two internet packets, first a
	#	length word, then a packet of 'lenth' containing the messages.
	#
	# Returns a shared record containing the nav_context
	#
	#	what
	#   client_port
	#   is_reply
	#   is_dict
	#
	# As well as, for both Requests and Replies, possibly:
	#
	#	seq_num		- the sequence number of the Request/Reply
	#	item 		- a fully parsed hash record of type WHAT
	#	uuid 		- the uuid of the item
	#
	# For requests only
	#
	#	name		- the name for CMD_FIND WHAT
	#
	# For replies only
	#
	#	success		- for replies, whether the Request 'succeeded' or not
	#	dict_uuids[]- array of uuids in the dictionarr of type WHAT
	#
	#	db_count	- the reply to a 'DATABASE" Request
	#   db_version	- the reply to a
	#	context_bits- the 0xXn bits from CONTEXT that determined is_dict
	#   amagic		- the unknown magic word from AVERB
	#
	#	is_event	- set to 1 for CMD_EVENT
	#	event_mask	- a mask built from the 'whats' recieved in this Reply
	#				  that indicates the opening and closure of the changes
	#				  to the entire set of WHATs on the E80.
	#
	#		0xXY	= X and Y are typical WHAT's (8=group, 4=routes) with
	#				  a specific 1=waypoints added
	#
	#			X   = the WHATs for closing events - evt_flag(1)
	#			Y	= the WHATs for opening events - evt_flag(0)
	#
	#	evt_flag	- artifact, the evt_flag(0/1) from the most
	#				  recently processed EVENT in the Reply
	#
	#   mods[]		- array of records telling WHAT uuid and
	#                 bits telling how the WHAT was modified
	#
	#		what	=> the kind of item that was modified
	#		uuid	=> the uuid of the modified item
	#		bits	=> 0=created, 1=deleted, 2=modified
	#
	# mods[] is included, but generally ignored for regular requests
	# 	     and is really only meaningful for event processing

{
	my ($with_text,$is_reply,$client_port,$raw_data) = @_;
	display($dbg_wpp,0,"parseWPMGR($is_reply,$client_port) ".unpack('H*',$raw_data));

	# create the header

	my $arrow;
    my $first_header;
    my $header_len = 0;
	if ($with_text)
	{
		$arrow = $is_reply ? '-->' : '<--';
		$first_header = pad('WPMGR',6).$arrow.' '.pad($client_port,7);
		$header_len = length($first_header);
	}
	
	# messages loop

	my $num = 0;
	my $text = '';
	my $offset = 0;
	my $rec;
	my $packet_len = length($raw_data);

	while ($offset < $packet_len)
	{
		my $data_len = unpack('v',substr($raw_data,$offset,2));
		my $data = substr($raw_data,$offset+2,$data_len);
		my $header = $num ? pad('',$header_len) : $first_header;

		if ($with_text)
		{
			my $hex_len = unpack('H*',substr($raw_data,$offset,2));
			$text .= r_utils::parse_dwords($header.$hex_len.' ',$data,1);
		}
		
		# get the comand word and move past {seq_num}

		my $command_word = unpack('v',$data);
		my $D = $command_word & 0xf00;	# substr($hex_data,3,1);
		my $W = $command_word & 0xf0;	# substr($hex_data,0,1);
		my $C = $command_word & 0xf;	# substr($hex_data,1,1);
		my $dir = $NAV_DIRECTION{$D};
		my $command = $NAV_COMMAND{$C};
		my $what = $NAV_WHAT{$W};

		my $context = init_context($client_port,$is_reply,$D,$num==0);
			# Force context initialization for ALL replies,
			# - we assume all replies come in single (possibly rebuilt) packets
			# - a regular WPMGR repl
			
		$context->{what} = $W if $W || $D != $DIR_INFO;
		my $show_what = $NAV_WHAT{$context->{what}};

		display($dbg_wpp,1,"PART($num) offset($offset) dir($dir) command($command) what($what) context($show_what) dict($context->}) uuid($context->uuid})");
		display($dbg_wpp+1,2,"data=".unpack('H*',$data));

		if (!$rec)
		{
			# Weirdest bug ever.
			# Somehow, {mods}, gets into the $context, even though
			# I only assign it to rec after
			#
			#	$rec = shared_clone($context);
			#
			# I really don't understand, but, by explicitly
			# stripping out that key and making a new hash
			# and share_cloning a ref to that, I can get on
			# with my work.

			display_hash($dbg_wpp+2,1,"before clone(context)",$context);

			my %clean;
			for my $k (keys %$context)
			{
				next if $k eq 'mods';  # skip ghost key
				$clean{$k} = $context->{$k};
			}
			$rec = shared_clone(\%clean);

			display_hash($dbg_wpp+2,1,"after clone",$rec);
		}
		
		# advance outer loop to next message

		$offset += 2 + $data_len;
		$num++;

		# the actual data starts after the cmd_word, 0f00, and the dword sequence number
		# MODIFY and EVENT dont have sequence numbers on replies

		my $data_offset = 4;
		if (!$is_reply || (
			$C != $CMD_MODIFY &&
			$C != $CMD_EVENT ))
		{
			my $seq_num = unpack('V',substr($data,$data_offset,4));
			display($dbg_wpp,0,"seq_num=$seq_num");

			$rec->{seq_num} = $context->{seq_num} ||= $seq_num;
			$data_offset += 4;
		}

		# find rule, first by full command word, then by $dir | $cmd

		my $rule = $PARSE_RULES{$command_word};
		$rule = $PARSE_RULES{ $D | $C } if !$rule;
		if ($rule)
		{
			my $comment = '';
			for my $piece (@$rule)
			{
				$comment .= parsePiece(
					$with_text,
					$rec,
					$piece,
					$data,
					\$data_offset,
					$context,
					$header_len + 2);	# indent buffer records a bit
			}
			$text .= "     # $dir: ".pad($command,8).pad($show_what,9)."$comment\n"
				if $with_text;
		}
		else # NO RULE!
		{
			my $msg = "NO RULE FOR $dir | $command | $what";
			warning(0,2,$msg);
			$text .= "     # $msg\n"
				if $with_text;
		}
	}

	# add extra cr for replies

	if ($with_text)
	{
		$text .= "\n" if $is_reply;
		$rec->{text} = $text;
	}

	display_hash($dbg_wpp+2,0,"parseWPMGR() returning",$rec);
	
	return $rec;
}


sub parsePiece
{
	my ($with_text,$rec,$piece,$data,$pdata,$context,$indent) = @_;

	my $text = '';

	if ($piece eq 'buffer')
	{
		if (!$context->{is_dict})
		{
			my $detail_level = 2;
			my $show_what = $NAV_WHAT{$context->{what}};
			my $item = parseWPMGRRecord($show_what,substr($data,$$pdata));
			$text = displayNQRecord($item,$show_what,$indent,$detail_level)
				if $with_text;
			$rec->{item} = $item;
		}
		elsif ($context->{is_reply})
		{
			$$pdata += 4;	# skiip biglen
			my $num = unpack('V',substr($data,$$pdata,4));
			$$pdata += 4;

			$text .= "dictionary($num)".($num?"\n":'')
				if $with_text;
			my $pad = pad('',$indent);
			my $dict_uuids = $rec->{dict_uuids};
			for (my $i=0; $i<$num; $i++)
			{
				my $uuid = unpack('H*',substr($data,$$pdata,8));
				$$pdata += 8;
				push @$dict_uuids,$uuid;
				$text .= $pad."uuid($i) = $uuid\n"
					if $with_text;
			}
		}
	}
	elsif ($piece eq 'uuid')
	{
		my $uuid = unpack('H*',substr($data,$$pdata,8));
		$rec->{uuid} = $uuid;
		$text = " uuid=$uuid" if $with_text;

		$$pdata += 8;
	}
	elsif ($piece eq 'name16')
	{
		my $name = unpack('Z*',substr($data,$$pdata,17));
		$rec->{name} = $name;
		$text = " name = $name" if $with_text;
		$$pdata += 17;
	}
	elsif ($piece eq 'success')
	{
		my $status = unpack('H*',substr($data,$$pdata,4));
		my $ok = $status eq $SUCCESS_SIG ? 1 : 0;
		$rec->{success} = $ok;
		if ($with_text)
		{
			$text .= $ok ? ' success' : ' failed';
		}
		$$pdata += 4;
	}
	else
	{
		my $str = substr($data,$$pdata,4);
		my $value = unpack('V',$str);
		$$pdata += 4;

		# I prefer to SEE non-counters in hex

		if ($with_text)
		{
			my $show_value = $value;
			$show_value = sprintf("0x%02x",$value)
				if $piece !~ /db_count|db_version|evt_flag/;
			$text .= " $piece=$value";
		}

		$rec->{$piece} = $value;

		if ($piece eq 'context_bits')
		{
			if ($value & 0x10)
			{
				$rec->{is_dict} = $context->{is_dict} = 1;
				$rec->{dict_uuids} = shared_clone([]);
				display($dbg_wpp+1,0,"setting is_dict bit");
			}
		}
		elsif ($piece eq 'evt_flag')
		{
			$rec->{is_event} = 1;
			$rec->{evt_mask} ||= 0;
				# Since all replies are atomic, the is_event from init_context()
				# is only used to set the initial record to zero. is_event is
				# never normalized back into the context.

			my $mask = $context->{what};
			$mask |= 1;					# add in specific 1=waypoints
			$mask <<= $value * 4;		# shift closing flags to high nibble
			$rec->{evt_mask} |= $mask;
		}
		elsif ($piece eq 'mod_bits')
		{
			my $what = $context->{what};
			my $uuid = $rec->{uuid};
			my $mods = $rec->{mods} = shared_clone([]) if !exists($rec->{mods});
			my $mod = shared_clone({
				what => $what,
				uuid => $uuid,
				bits => $value });
			push @$mods,$mod;
		}
	}

	return $text;
}





1;
