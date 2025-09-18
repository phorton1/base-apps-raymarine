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
        $LOCAL_UDP_SEND_PORT
		$UDP_SEND_SOCKET

        wakeup_e80
		packetWireHeader
		setConsoleColor
    );
}


our $RAYDP_IP            = '224.0.0.1';
our $RAYDP_PORT          = 5800;
our $RAYDP_ADDR			 = pack_sockaddr_in($RAYDP_PORT, inet_aton($RAYDP_IP));
our $RAYDP_ALIVE_PACKET  = pack("H*", "0100000003000000ffffffff76020000018e768000000000000000000000000000000000000000000000000000000000000000000000"),
our $RAYDP_WAKEUP_PACKET = "ABCDEFGHIJKLMNOP",

our $LOCAL_IP       	 = '10.0.241.200';
our $LOCAL_UDP_SEND_PORT = 8765;                 # arbitrary but recognizable

# The global $UDP_SEND_SOCKET is opened
# in the main thread at the outer perl
# level so-as to be available from threads

our $UDP_SEND_SOCKET = IO::Socket::INET->new(
        LocalAddr => $LOCAL_IP,
        LocalPort => $LOCAL_UDP_SEND_PORT,
        Proto     => 'udp',
        ReuseAddr => 1);
error("Could not open UDP_SEND_SOCKET")
	if !$UDP_SEND_SOCKET;



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

	my $left_ip = $backwards ? $packet->{dest_ip} : $packet->{src_ip};
	my $left_port = $backwards ? $packet->{dest_port} : $packet->{src_port};
	my $right_ip = $backwards ? $packet->{src_ip} : $packet->{dest_ip};
	my $right_port = $backwards ? $packet->{src_port} : $packet->{dest_port};
	my $arrow = $backwards ? "<--" : "-->";

	return
		"$packet->{proto} ".
		pad("$left_ip:$left_port",21).
		"$arrow ".
		pad("$right_ip:$right_port",21).
		" ";
}


sub wakeup_e80
	# Can be called from a thread.
{
	if (!$UDP_SEND_SOCKET)
	{
		error("wakeup_e80() fail because UDP_SEND_SOCKET is not open");
		return;
	}

	display(0,0,"wakeup_e80");

    for (my $i = 0; $i < 5; $i++)
    {
		display(0,1,"sending RAYDP_ALIVE_PACKET");
        $UDP_SEND_SOCKET->send($RAYDP_ALIVE_PACKET, 0, $RAYDP_ADDR);
        sleep(1);
    }

    for (my $i = 0; $i < 10; $i++)
    {
		display(0,1,"sending RAYDP_INIT_PACKET");
        $UDP_SEND_SOCKET->send($RAYDP_WAKEUP_PACKET, 0, $RAYDP_ADDR);
        sleep(0.001);
    }

	return 1;
}


1;
