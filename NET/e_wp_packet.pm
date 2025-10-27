#---------------------------------------------
# e_wp_packet.pm
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

package d_WPMGR;	# continued ...
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time sleep);
use Pub::Utils;
use a_defs qw($SUCCESS_SIG);
use b_records;
use e_wp_defs;

my $dbg_wpp = 1;


#--------------------------------------------------
# parseWPMGRPacket
#--------------------------------------------------


sub parseWPMGRPacket
	# For the text with normal packets, it's src_port --> dest_port
	# 	but for nav packets, its WPMGR <-> client_port
	#
	# $is_reply is passed in as one when the source is
	#	the WPMGR service, 0 for requests,
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
	my ($this,$with_text,$is_reply,$client_port,$raw_data) = @_;
	$with_text ||= 0;
	display($dbg_wpp,0,"parseWPMGRPacket($with_text,$is_reply,$client_port) ".unpack('H*',$raw_data));

	# create the header

	my $arrow;
    my $first_header;
    my $header_len = 0;
	if ($with_text)
	{
		$arrow = $is_reply ? '-->' : '<--';
		$first_header = pad('WPMGR',6).$arrow." ";
		$header_len = length($first_header);
	}
	
	my $rec = shared_clone({
		dir 		=> 0,
		what 		=> 0,
		is_dict 	=> 0,
		client_port => $client_port,
		is_reply 	=> $is_reply,
		seq_num 	=> 0,
		is_event 	=> 0,
		uuid		=> '' });


	# messages loop

	my $num = 0;
	my $text = '';
	my $offset = 0;
	# my $rec;
	my $packet_len = length($raw_data);

	while ($offset < $packet_len)
	{
		my $data_len = unpack('v',substr($raw_data,$offset,2));
		my $data = substr($raw_data,$offset+2,$data_len);
		my $header = $num ? pad('',$header_len) : $first_header;

		if ($with_text)
		{
			my $hex_len = unpack('H*',substr($raw_data,$offset,2));
			$text .= a_utils::parse_dwords($header.$hex_len.' ',$data,1);
		}
		
		# get the comand word

		my $command_word = unpack('v',$data);
		my $D = $command_word & 0xf00;	# substr($hex_data,3,1);
		my $W = $command_word & 0xf0;	# substr($hex_data,0,1);
		my $C = $command_word & 0xf;	# substr($hex_data,1,1);
		my $dir = $NAV_DIRECTION{$D};
		my $command = $NAV_COMMAND{$C};
		my $what = $NAV_WHAT{$W};

		$rec->{what} = $W if $W || $D != $DIR_INFO;
		my $show_what = $NAV_WHAT{$rec->{what}};

		display($dbg_wpp,1,"PART($num) offset($offset) dir($dir) command($command) what($what) context($show_what) dict($rec->{is_dict}) uuid($rec->{uuid})");
		display($dbg_wpp+1,2,"data=".unpack('H*',$data));

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

			$rec->{seq_num}  ||= $seq_num;
			$data_offset += 4;
		}

		# find rule, first by full command word, then by $dir | $cmd

		my $rule = $WPMGR_PARSE_RULES{$command_word};
		$rule = $WPMGR_PARSE_RULES{ $D | $C } if !$rule;
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

	display_hash($dbg_wpp+2,0,"parseWPMGRPacket() returning",$rec);
	
	return $rec;
}


sub parsePiece
{
	my ($with_text,$rec,$piece,$data,$pdata,$indent) = @_;

	my $text = '';

	if ($piece eq 'buffer')
	{
		if (!$rec->{is_dict})
		{
			my $detail_level = 0;
			my $show_what = $NAV_WHAT{$rec->{what}};
			my $item = parseWPMGRRecord($show_what,substr($data,$$pdata));
			$text = WPRecordToText($item,$show_what,$indent,$detail_level)
				if $with_text;
			$rec->{item} = $item;
		}
		elsif ($rec->{is_reply})
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
				$rec->{is_dict} = 1;
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

			my $mask = $rec->{what};
			$mask |= 1;					# add in specific 1=waypoints
			$mask <<= $value * 4;		# shift closing flags to high nibble
			$rec->{evt_mask} |= $mask;
		}
		elsif ($piece eq 'mod_bits')
		{
			my $what = $rec->{what};
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
