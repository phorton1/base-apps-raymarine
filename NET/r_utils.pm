#---------------------------------------------
# r_utils.pm
#---------------------------------------------

package r_utils;
use strict;
use warnings;
use threads;
use threads::shared;
use Socket;
use IO::Socket::INET;
use IO::Socket::Multicast;
use Time::HiRes qw(sleep);
use Wx qw(:everything);
use Pub::Utils;
use r_parse;

my $dbg_nq = 0;


my $PARSE_WP_BUFFERS = 1;
my $PARSE_ROUTE_BUFFERS = 1;
my $PARSE_GROUP_BUFFERS = 1;


our $RAYDP_IP            = '224.0.0.1';
our $RAYDP_PORT          = 5800;
our $RAYDP_ADDR			 = pack_sockaddr_in($RAYDP_PORT, inet_aton($RAYDP_IP));
our $RAYDP_ALIVE_PACKET  = pack('H*', '0100000003000000ffffffff76020000018e768000000000000000000000000000000000000000000000000000000000000000000000'),
our $RAYDP_WAKEUP_PACKET = 'ABCDEFGHIJKLMNOP',

our $LOCAL_IP	= '10.0.241.200';
our $LOCAL_UDP_PORT = 8765;                 # arbitrary but recognizable

# static and known udp listening ports

our $FILESYS_LISTEN_PORT		= 0x4801;   # 18433
our $RNS_FILESYS_LISTEN_PORT	= 0x4800;	# 18432
our $NAVQUERY_PORT 				= 9877;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(
        $RAYDP_IP
        $RAYDP_PORT
		$RAYDP_ADDR
        $RAYDP_ALIVE_PACKET
        $RAYDP_WAKEUP_PACKET

        $LOCAL_IP
        $LOCAL_UDP_PORT
		$LOCAL_UDP_SOCKET

		$FILESYS_LISTEN_PORT
		$RNS_FILESYS_LISTEN_PORT
		$NAVQUERY_PORT

		sendUDPPacket
		sendAlive
        wakeup_e80

		parseNavPacket

		setConsoleColor
		packetWireHeader
		showPacket

		navQueryLog
		clearLog
		
		degreeMinutes

		@color_names
		$color_values

	    $color_red
	    $color_green
	    $color_blue
	    $color_cyan
	    $color_magenta
	    $color_yellow
	    $color_dark_yellow
	    $color_grey
	    $color_purple
	    $color_orange
	    $color_white
	    $color_medium_cyan
	    $color_dark_cyan
	    $color_lime
	    $color_light_grey
	    $color_medium_grey

		%NAV_DIRECTION
		%NAV_WHAT
		%NAV_COMMAND 

    );
}

# The global $UDP_SEND_SOCKET is opened
# in the main thread at the outer perl
# level so-as to be available from threads

our $LOCAL_UDP_SOCKET = IO::Socket::INET->new(
        LocalAddr => $LOCAL_IP,
        LocalPort => $LOCAL_UDP_PORT,
        Proto     => 'udp',
        ReuseAddr => 1);
$LOCAL_UDP_SOCKET ?
	display(0,0,"LOCAL_UDP_SOCKET opened") :
	error("Could not open UDP_SEND_SOCKET");

# console colors
# given names for monitor dropdown

our @color_names = (
    'Default',
    'Blue',
    'Green',
    'Cyan',
    'Red',
    'Magenta',
    'Brown',
    'Light Gray',
    'Gray',
    'Light Blue',
    'Light Green',
    'Light Cyan',
    'Light Red',
    'Light Magenta',
    'Yellow',
    'White', );
our $color_values = { map { $color_names[$_] => $_ } 0..$#color_names };
	# $#array gives the last index of the array as opposed to @array which is the length in a scalar context
	# map takes a list and applies a block of code to each element, returning a new list.
	# The block of code is within the {} and $_ is each element of the elist is presented to the right
	# map {block} list


# wx colors

our $color_red     	     = Wx::Colour->new(0xE0, 0x00, 0x00);		# commit: deletes; link: errors or needs pull; dialog: repoError
our $color_green   	     = Wx::Colour->new(0x00, 0x60, 0x00);		# commit: staged M's; link: public
our $color_blue    	     = Wx::Colour->new(0x00, 0x00, 0xC0);		# commit: icons and repo line; link: private
our $color_cyan          = Wx::Colour->new(0x00, 0xE0, 0xE0);		# winInfoRight header
our $color_magenta       = Wx::Colour->new(0xC0, 0x00, 0xC0);		# link: staged or unstaged changes
our $color_yellow        = Wx::Colour->new(0xFF, 0xD7, 0x00);		# winCommitRight title background; dialog: repoWarning
our $color_dark_yellow   = Wx::Colour->new(0xA0, 0xA0, 0x00);		# default branch warning
our $color_grey          = Wx::Colour->new(0x99, 0x99, 0x99);		# unused
our $color_purple        = Wx::Colour->new(0x60, 0x00, 0xC0);		# unused
our $color_orange        = Wx::Colour->new(0xC0, 0x60, 0x00);		# link: needs Push; history: tags
our $color_white         = Wx::Colour->new(0xFF, 0xFF, 0xFF);		# dialog: repoNote
our $color_medium_cyan   = Wx::Colour->new(0x00, 0x60, 0xC0);		# repo: forked
our $color_dark_cyan     = Wx::Colour->new(0x00, 0x60, 0x60);		# unused
our $color_lime  	     = Wx::Colour->new(0x50, 0xA0, 0x00);		# hitory: tags
our $color_light_grey    = Wx::Colour->new(0xF0, 0xF0, 0xF0);		# winCommitRight panel; dialog: repoDisplay
our $color_medium_grey   = Wx::Colour->new(0xC0, 0xC0, 0xC0);		# winInfoLeft selected item


#---------------------------------
# method
#---------------------------------


sub sendUDPPacket
{
    my ($name,$dest_ip,$dest_port,$packet) = @_;
    display(0,1,"sending $name packet: ".unpack('H*',$packet));
    if (!$LOCAL_UDP_SOCKET)
    {
        error("LOCAL_UDP_SOCKET not open in sendRequest packet");
        return;
    }
    my $dest_addr = pack_sockaddr_in($dest_port, inet_aton($dest_ip));
    $LOCAL_UDP_SOCKET->send($packet, 0, $dest_addr);
}



sub sendAlive
{
	$LOCAL_UDP_SOCKET->send($RAYDP_ALIVE_PACKET, 0, $RAYDP_ADDR);
}



sub wakeup_e80
	# Can be called from a thread.
{
	if (!$LOCAL_UDP_SOCKET)
	{
		error("wakeup_e80() fail because UDP_SEND_SOCKET is not open");
		return;
	}

	display(0,0,"wakeup_e80");

    for (my $i = 0; $i < 5; $i++)
    {
		display(0,1,"sending RAYDP_ALIVE_PACKET");
		sendAlive();
        sleep(1);
    }

    for (my $i = 0; $i < 10; $i++)
    {
		display(0,1,"sending RAYDP_INIT_PACKET");
        $LOCAL_UDP_SOCKET->send($RAYDP_WAKEUP_PACKET, 0, $RAYDP_ADDR);
        sleep(0.001);
    }

	return 1;
}



sub degreeMinutes
{
	my $DEG_CHAR = chr(0xB0);
	my ($ll) = @_;
	my $deg = int($ll);
	my $min = round(abs($ll - $deg) * 60,3);
	return "$deg$DEG_CHAR$min";
}


sub setConsoleColor
	# running in context of Pub::Utils; does not use ansi colors above
	# just sets the console to the given Pub::Utils::$DISPLAY_COLOR_XXX or $UTILS_COLOR_YYY
	# wheree XXX is NONE, LOG, ERROR, or WARNING and YYY are color names
	# if $utils_color not provide, uses $DISPLAY_COLOR_NONE to return to standard light grey
{
	my ($utils_color) = @_;
	$utils_color = $DISPLAY_COLOR_NONE if !defined($utils_color);
	Pub::Utils::_setColor($utils_color);
}



sub packetWireHeader
	# General printable packet header for console-type messages
{
	my ($packet,$backwards) = @_;

	my $len = length($packet->{raw_data});
	my $left_ip = $backwards ? $packet->{dest_ip} : $packet->{src_ip};
	my $left_port = $backwards ? $packet->{dest_port} : $packet->{src_port};
	my $right_ip = $backwards ? $packet->{src_ip} : $packet->{dest_ip};
	my $right_port = $backwards ? $packet->{src_port} : $packet->{dest_port};
	my $arrow = $backwards ? '<--' : '-->';

	return
		$packet->{proto}.
		pad("($len)",7).
		pad("$left_ip:$left_port",21).
		$arrow.' '.
		pad("$right_ip:$right_port",21).
		' ';
}



my %declared_len:shared;	# by port
	# Used on sniffer packets to rebuild them for parseNavQuery


# These are used to maintain context between the first
# message in a request and subsequent messages in the
# request as well as the subsequent reply.
# They are set to defaults at the end of a request.

my %nav_context:shared;		# by client port
	# DATABASE, WAYPOINT, ROUTE, or GROUP
my %nav_type:shared;		# by client port
	# ITEM, LIST


# WC0D
# reply comes AFTER, where as USE/APPLY come before rest

our %NAV_DIRECTION = (
	0x000 => 'recv',
	0x100 => 'send',
	0x200 => 'info',
);

our %NAV_WHAT = (
	0x00 => 'WAYPOINT',
	0x40 => 'ROUTE',
	0x80 => 'GROUP',
	0xb0 => 'DATABASE',
);


our %NAV_COMMAND = (
	0x0 => 'CONTEXT',
	0x1 => 'BUFFER',
	0x2 => 'LIST',
	0x3 => 'ITEM',				# by uuid
	0x4 => 'EXIST',				# by uuid returns
	0x5 => 'EVENT',
	0x6 => 'DATA',				# reply only
	0x7 => 'MODIFY',
	0x8 => 'DELETE',
	0x9 => 'COUNT',
	0xa => 'AVERB',
	0xb => 'BVERB',
	0xc => 'FIND',				# by name
	0xd => 'SPACE',
	0xe => 'EVERB',
	0xf => 'FVERB',
);


# database checks are not needed
#
#	$request = createMsg(-1,$DIR_SEND,$CMD_BUFFER,$WHAT_DATABASE);
#	return 0 if !$this->sendRequest($sock,$sel,-1,'init1',$request);
#		# NAVQRY <--51412  0400 b1010f00                                                                  ....
#		#      # send: BUFFER DATABASE
#	$request = createMsg(-2,$DIR_SEND,$CMD_BUFFER,$WHAT_DATABASE);
#	return 0 if !$this->sendRequest($sock,$sel,-2,'init2',$request);
#		# no reply expected on second
#
#	$seq = $this->{next_seqnum}++;
#	$request = createMsg($seq,$DIR_SEND,$CMD_SPACE);
#	return 0 if !$this->sendRequest($sock,$sel,$seq,'space',$request);
#	return 0 if !$this->waitReply();
#		# NAVQRY <--51412  0800 0d010f00 9b010000                                                         ........
#		#	# send: SPACE DATABASE
#		# NAVQRY -->51412  0c00 09000f00 9b010000 00000000                                                ............
#		# 	# recv: COUNT DATABASE number=0


sub clearLog
{
	my ($filename) = @_;
	my $record_filename = "docs/junk/$filename";
	if (open(AFILE,">$record_filename"))
	{
		close AFILE;
	}
}

sub navQueryLog
{
	my ($text,$filename) = @_;
	my $record_filename = "docs/junk/$filename";
	if (open(AFILE,">>$record_filename"))
	{
		print AFILE $text;
		close AFILE;
	}
}


sub parseNavPacket
	# with normal packets, it's src_port --> dest_port
	# but for nav packets, its NAVQRY <-> client_port
	# is_request should be passed in as one when the
	# source is NOT NAVQRY
{
	my ($is_reply,$client_port,$raw_data,$NAVQRY) = @_;
	display($dbg_nq,0,"parseNavPacket($is_reply,$client_port) ".unpack('H*',$raw_data));

	# initialize state variables

	$nav_context{$client_port} = 'DATABASE' if !defined($nav_context{$client_port});
	$nav_type{$client_port} = 'ITEM' if !defined($nav_type{$client_port});

	# create the header

	my $arrow = $is_reply ? '-->' : '<--';
	my $first_header = pad('NAVQRY',7).$arrow.' '.pad($client_port,7);
	my $header_len = length($first_header);

	# output messages loop

	my $num = 0;
	my $text = '';
	my $comment = '';
	my $offset = 0;
	my $packet_len = length($raw_data);

	while ($offset < $packet_len)
	{
		my $data_offset = 0;
		my $data_len = unpack('v',substr($raw_data,$offset,2));
		my $hex_len = unpack('H*',substr($raw_data,$offset,2));
		my $data = substr($raw_data,$offset+2,$data_len);
		my $hex_data = unpack('H*',$data);
		my $header = $num ? pad('',$header_len) : $first_header;

		my $output = parse_dwords($header.$hex_len.' ',$data,1);

		$text .= $output;

		# get the comand word and move past {seq_num}

		my $command_word = unpack('v',$data);
		my $D = $command_word & 0xf00;	# substr($hex_data,3,1);
		my $W = $command_word & 0xf0;	# substr($hex_data,0,1);
		my $C = $command_word & 0xf;	# substr($hex_data,1,1);

		# $is_reply = 1 if !$num && !$D;

		my $dir = $NAV_DIRECTION{$D};
		my $command = $NAV_COMMAND{$C};
		my $what = $NAV_WHAT{$W};

		if (!$is_reply && $dir eq 'send')
		{
			$text .= "    set nav_context($client_port) = $what($W)\n";

			$nav_context{$client_port} = $what
				# set the conversation context for the entire request-reqply from the first request message
		}
		
		my $context = $W ? $what : $nav_context{$client_port};
			# override the displayed context if it's excplitily non-zero

		$context = $what if
			$command eq 'MODIFY' ||
			$command eq 'EVENT';

		display($dbg_nq,1,"PART($num) offset($offset) dir($dir) command($command) what($what) context($context) nav_context($nav_context{$client_port}) nav_type($nav_type{$client_port})");
		display($dbg_nq,2,"data=".unpack('H*',$data));
		
		# commands that do not have seq_num

		if ($is_reply && (
			$command eq 'MODIFY' ||
			$command eq 'EVENT'))
		{
			$data_offset = 4;
		}
		else
		{
			$data_offset = 8;
		}

		# for first line of replies, get the status and move past it ...

		my $ok = 1;
		my $answer = '';

		if ($is_reply && !$num &&
			# replies that don't carry success codes
			$command ne 'COUNT' &&
			$command ne 'MODIFY' &&
			$command ne 'EVENT')
		{
			my $status = unpack('H*',substr($data,$data_offset,4));
			$data_offset += 4;
			if ($status ne '00000400')
			{
				$answer = 'failed';
				$ok = 0;
			}
			else
			{
				$answer = 'ok ';
			}
		}
		
		if ($ok)
		{
			if ($command eq 'LIST')
			{
				$nav_type{$client_port} = 'INDEX' if !$is_reply;
					# set the 'type' of the buffer data to INDEX
					# if a LIST command is encountered in a request
			}
			elsif ($command eq 'BUFFER') 	# !$num)
			{
				# there's no actual buffer data if the commands
				# is the outer request or reply

				my $buffer_type = $nav_type{$client_port};
				$answer = $buffer_type;
				if ($buffer_type eq 'INDEX')
				{
					$data_offset += 4;		# skip dword(2c000000)
					my $num_uuids = unpack('v',substr($data,$data_offset,2));
					$data_offset += 4;
						# start of uuids
					$answer .= " num_uuids($num_uuids)";
					$answer .= " first:".unpack('H*',substr($data,$data_offset,8))
						if $num_uuids;
				}
				else # if ($buffer_type eq 'ITEM')
				{
					my $buffer = substr($data,8);
					display($dbg_nq,2,"buffer=".unpack('H*',$buffer));

					$answer .= parseNavQueryWaypointBuffer($buffer,$header_len+2)
						if $context eq 'WAYPOINT' && $PARSE_WP_BUFFERS;
					$answer .= parseNavQueryRouteBuffer($buffer,$header_len+2)
						if $context eq 'ROUTE' && $PARSE_ROUTE_BUFFERS;
					$answer .= parseNavQueryGroupBuffer($buffer,$header_len+2)
						if $context eq 'GROUP' && $PARSE_GROUP_BUFFERS;

					$NAVQRY->{$NAVQRY->{NAVQRY_HASH}}->{$NAVQRY->{NAVQRY_UUID}} = $buffer
						if $NAVQRY && $NAVQRY->{NAVQRY_HASH} && $NAVQRY->{NAVQRY_UUID};
				}
			}
			elsif ($command eq 'FIND')
			{
				my $name = unpack('Z*',substr($data,$data_offset));
				$answer .= "'$name'";
			}
			elsif ($command eq "UUID")
			{
				my $uuid .= unpack('H*',substr($data,$data_offset,8));
				$answer .= $uuid;
			}
			elsif ($command eq "COUNT")
			{
				my $count = unpack('V',substr($data,$data_offset,4));
				$answer .= "number=".$count;
			}

			# things that are regularly possibly followed by a uuid &
			# possibly bits

			elsif ($command eq 'MODIFY' ||
				   $command eq 'ITEM' ||
				   $command eq 'CONTEXT' ||
				   $command eq 'LIST' ||
				   $command eq 'BUFFER' ||
				   $command eq 'LIST' ||
				   $command eq 'DELETE')
			{
				my $uuid = '';
				my $bits = 0;

				if ($data_offset + 8 <= $data_len)
				{
					$uuid = unpack('H*',substr($data,$data_offset,8)) || '';
					$data_offset += 8;
					if ($data_offset + 1 <= $data_len)
					{
						$bits = unpack('H2',substr($data,$data_offset,1)) || 0;
					}
				}
				$answer .= $uuid if $uuid;
				$answer .= " bits($bits)" if $bits;
			}
		}

		my $comment =  "     # $dir: $command $context $answer\n";
		$text .= $comment;
		# print $comment;

		$offset += 2 + $data_len;
		$num++;
	}
	
	if ($is_reply)
	{
		$nav_context{$client_port} = 'DATABASE';
		$nav_type{$client_port} = 'ITEM';
		$text .= "\n";
	}

	return $text;
}


my $MON_SELF_NAVQRY = 0;


sub showPacket
{
	my ($rayport,$packet,$backwards) = @_;
	return if length($packet->{raw_data}) == 1;		# skip keep-aives

	if ($rayport->{name} eq 'NAVQRY')
	{
		my $src_port = $packet->{src_port};
		my $dest_port = $packet->{dest_port};
		my $raw_data = $packet->{raw_data};
		my $is_reply = $src_port == $rayport->{port};
		my $client_port = $is_reply ? $dest_port : $src_port;

		# temporary for lack of a better UI
		
		return if $client_port == $NAVQUERY_PORT && !$MON_SELF_NAVQRY;
		
		# remember the length of the packet if it's length is 2
		# or prepend it onto the current packet if available

		if (length($raw_data) == 2)
		{
			my $use_len = unpack('v',$raw_data);
			$declared_len{$dest_port} = $use_len;
			# print "declared_len($dest_port)=$use_len\n";
			return;
		}
		my $use_len = $declared_len{$dest_port};
		$declared_len{$dest_port} = -1;
		if ($use_len && $use_len != -1)
		{
			my $prepend = pack('v',$use_len);
			$raw_data = $prepend.$raw_data;
			# warning(0,0,"prepending($use_len) to raw packet");
		}

		# parse and display and/or log the packet

		my $text = parseNavPacket($is_reply,$client_port,$raw_data);
		navQueryLog($text,"rns.log");

		my $color = $rayport->{color};
		setConsoleColor($color) if $color;
		print $text;
		setConsoleColor() if $color;

	}
	else
	{
		my $header = packetWireHeader($packet,$backwards);
		my $multi = $rayport->{multi};
		my $color = $rayport->{color} || 0;
		my $raw_data = $packet->{raw_data};
		my $full_packet = parse_dwords($header,$raw_data,$multi);
		setConsoleColor($color) if $color;
		print $full_packet;
		setConsoleColor() if $color;
	}
}




my $BYTES_PER_GROUP = 4;
my $GROUPS_PER_LINE = 8;
my $BYTES_PER_LINE	= $GROUPS_PER_LINE * $BYTES_PER_GROUP;
my $LEFT_SIZE = $GROUPS_PER_LINE * $BYTES_PER_GROUP * 2 + $GROUPS_PER_LINE;

sub parse_dwords
{
	my ($header,$raw_data,$multi) = @_;
	my $offset = 0;
	my $byte_num = 0;
	my $group_byte = 0;
	my $left_side = '';
	my $right_side = '';
	my $full_packet = $header;
	my $header_len = length($header);
	my $packet_len = length($raw_data);
	# $full_packet .= "\nONE($hex_data)\n" if $packet_len == 1;
	while ($offset < $packet_len)
	{
		$byte_num = $offset % $BYTES_PER_LINE;
		if ($offset && !$byte_num)
		{
			$full_packet .= $left_side.'  '.$right_side;
			$full_packet .= ' >>>' if !$multi;
			$full_packet .= "\n";
			$left_side = '';
			$right_side = '';
			$group_byte = 0;
			last if !$multi;
			$full_packet .= pad('',$header_len);
		}

		my $byte = substr($raw_data,$offset++,1);
		$left_side .= unpack('H2',$byte);
		$group_byte++;
		if ($group_byte == $BYTES_PER_GROUP)
		{
			$left_side .= ' ';
			$group_byte = 0;
		}
		$right_side .= ($byte ge ' ' && $byte le 'z') ? $byte : '.';
	}
	if ($left_side)
	{
		$full_packet .= pad($left_side,$LEFT_SIZE).'  '.$right_side."\n";
	}
	return $full_packet;
}






1;
