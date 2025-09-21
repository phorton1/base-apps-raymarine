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
use Pub::Utils;


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

		sendAlive
        wakeup_e80
		setConsoleColor
		packetWireHeader
		showPacket

		@color_names
		$color_values

    );
}


our $RAYDP_IP            = '224.0.0.1';
our $RAYDP_PORT          = 5800;
our $RAYDP_ADDR			 = pack_sockaddr_in($RAYDP_PORT, inet_aton($RAYDP_IP));
our $RAYDP_ALIVE_PACKET  = pack("H*", "0100000003000000ffffffff76020000018e768000000000000000000000000000000000000000000000000000000000000000000000"),
our $RAYDP_WAKEUP_PACKET = "ABCDEFGHIJKLMNOP",

our $LOCAL_IP       = '10.0.241.200';
our $LOCAL_UDP_PORT = 8765;                 # arbitrary but recognizable

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



sub showPacket
{
	my ($rayport,$packet,$backwards) = @_;
	my $header = packetWireHeader($packet,$backwards);
	my $header_len = length($header);
	my $multi = $rayport->{multi};

	my $raw_data = $packet->{raw_data};
	my $hex_data = $packet->{hex_data};
	my $packet_len = length($raw_data);
	# $packet_len = $BYTES_PER_LINE if !$multi && ($packet_len > $BYTES_PER_LINE);

	my $offset = 0;
	my $byte_num = 0;
	my $group_byte = 0;
	my $left_side = '';
	my $right_side = '';
	my $full_packet = $header;
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


	my $color = $rayport->{color} || 0;
    setConsoleColor($color) if $color;
    print $full_packet;
	setConsoleColor() if $color;
}




1;
