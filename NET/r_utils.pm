#---------------------------------------------
# r_utils.pm
#---------------------------------------------

package apps::raymarine::NET::r_utils;
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


our $RAYDP_IP            = '224.0.0.1';
our $RAYDP_PORT          = 5800;
our $RAYDP_ADDR			 = pack_sockaddr_in($RAYDP_PORT, inet_aton($RAYDP_IP));
our $RAYDP_ALIVE_PACKET  = pack("H*", "0100000003000000ffffffff76020000018e768000000000000000000000000000000000000000000000000000000000000000000000"),
our $RAYDP_WAKEUP_PACKET = "ABCDEFGHIJKLMNOP",

our $LOCAL_IP	= '10.0.241.200';
our $LOCAL_UDP_PORT = 8765;                 # arbitrary but recognizable

# static and known udp listening ports

our $FILESYS_LISTEN_PORT		= 0x4801;   # 18433
our $RNS_FILESYS_LISTEN_PORT	= 0x4800;	# 18432



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

		sendUDPPacket

		sendAlive
        wakeup_e80
		setConsoleColor
		packetWireHeader
		showPacket

		degreeMinutes

		show_dwords

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
	my $arrow = $backwards ? "<--" : "-->";

	return
		"$packet->{proto}".
		pad("($len)",7).
		pad("$left_ip:$left_port",21).
		"$arrow ".
		pad("$right_ip:$right_port",21).
		" ";
}


my $BYTES_PER_GROUP = 4;
my $GROUPS_PER_LINE = 8;

my $BYTES_PER_LINE	= $GROUPS_PER_LINE * $BYTES_PER_GROUP;
my $LEFT_SIZE = $GROUPS_PER_LINE * $BYTES_PER_GROUP * 2 + $GROUPS_PER_LINE;


# use apps::raymarine::NET::r_NAVQRY;
my %declared_len:shared;


sub showPacket
{
	my ($rayport,$packet,$backwards) = @_;

	return if length($packet->{raw_data}) == 1;		# skip keep-aives


		my $header = packetWireHeader($packet,$backwards);
		my $multi = $rayport->{multi};
		my $color = $rayport->{color} || 0;
		my $raw_data = $packet->{raw_data};
		my $hex_data = $packet->{hex_data};
		# $packet_len = $BYTES_PER_LINE if !$multi && ($packet_len > $BYTES_PER_LINE);
		show_dwords($header,$raw_data,$hex_data,$color,$multi);

	if ($rayport->{name} && $rayport->{name} eq 'NAVQRY')
	{
		my $dest_port = $packet->{dest_port};
		if (length($raw_data) == 2)
		{
			$declared_len{$dest_port} = unpack('v',$packet->{raw_data});
			print "declared_len{$dest_port}=$declared_len{$dest_port}\n";
		}
		else
		{
			my $src_port = $packet->{src_port};

			# some events come in without a previous length byte
			# ... and get the length from the packet
			my $use_len = $declared_len{$dest_port};
			if ($use_len == -1)
			{
				$use_len = unpack('v',$raw_data);
				$raw_data = substr($raw_data,2);
				$hex_data = substr($hex_data,4);
				warning(0,0,"using length($use_len) shifting packet by 2 to: $hex_data");
			}
			apps::raymarine::NET::r_NAVQRY::parse_stuff($src_port,$dest_port,$declared_len{$dest_port},$raw_data);
			# so I clear the previous length byte once I use it ...
			$declared_len{$dest_port} = -1;
		}
	}
}


sub show_dwords
{
	my ($header,$raw_data,$hex_data,$color,$multi) = @_;
	my $offset = 0;
	my $byte_num = 0;
	my $group_byte = 0;
	my $left_side = '';
	my $right_side = '';
	my $full_packet = $header;
	my $header_len = length($header);
	my $packet_len = length($raw_data);
	# $full_packet .= "\r\nONE($hex_data)\r\n" if $packet_len == 1;
	while ($offset < $packet_len)
	{
		$byte_num = $offset % $BYTES_PER_LINE;
		if ($offset && !$byte_num)
		{
			$full_packet .= $left_side."  ".$right_side;
			$full_packet .= " >>>" if !$multi;
			$full_packet .= "\r\n";
			$left_side = '';
			$right_side = '';
			$group_byte = 0;
			last if !$multi;
			$full_packet .= pad('',$header_len);
		}

		$left_side .= substr($hex_data,$offset * 2,2);
		$group_byte++;
		if ($group_byte == $BYTES_PER_GROUP)
		{
			$left_side .= " ";
			$group_byte = 0;
		}
		my $c = substr($raw_data,$offset++,1);
		$right_side .= ($c ge ' ' && $c le 'z') ? $c : '.';
	}
	if ($left_side)
	{
		$full_packet .= pad($left_side,$LEFT_SIZE)."  ".$right_side."\r\n";
	}

    setConsoleColor($color) if $color;
    print $full_packet;
	setConsoleColor() if $color;
}




1;
