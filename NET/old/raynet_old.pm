#---------------------------------------
# raynet_old.pm
#---------------------------------------
# see docs/raynet.md

package raynet_old;
use strict;
use warnings;
use Socket;
use Time::HiRes qw(sleep time);
use IO::Select;
use IO::Socket::INET;
use IO::Socket::Multicast;
use Pub::Utils;
use old::ray_UI;
use old::ray_E80;


my $USE_MY_MCAST = 0;


my $local_ip = '10.0.241.200';	# assigned; see readme.md
my $local_port = 8679;			# arbitrary

# Here are all of the known raynet packets I have recieved, by length and type
#
#		length(28) func(7)  x(1966081,526342)  addr(10.0.241.54:2054)
#		length(28) func(19) x(1966081,526341)  addr(10.0.241.54:2053)
#		length(28) func(22) x(1966081,526343)  addr(10.0.241.54:2055)
#		length(36) func(27) x(1966081,1054378) mcast(224.0.0.2:5801) dev(10.0.241.54:5802)
#		length(36) func(35) x(1966081,1050624) mcast(224.30.38.193:2560) dev(10.0.241.54:2048)
#		length(37) func(5)  x(1966081,1116161) mcast(224.30.38.194:2561) dev(10.0.241.54:2049) flags(1)
#		length(40) func(16) x(1966081,1312770) tcp?(10.0.241.54:2050:2051) e80_mcast(224.30.38.195:2562) E80_NAV !!!
#		length(54) UNPARSED KNOWN E80_INIT_PACKET
#       length(56) UNDECODED message appears to have the known E80 ip adddress, with a
#       	preceding port of '569' and a lot of specific bytes after it.
#			01000000 00000000 37a681b2 39020000 36f1000a 0022cc23 ce33c237 cd35d833 ccf3dc33 cc33c033 cc33cc33 cc33cc33 4417c432 02000100
#                                               ^ 10.0.241.254 = the E80's IP address
#                                      ^ '569' some other port?

my $RAYNET_GROUP = '224.0.0.1';		# radar: SEATALK_HS_ANNOUNCE_GROUP in RMControl.cpp
my $RAYNET_PORT  = 5800;			# radar: SEATALK_HS_ANNOUNCE_PORT in RMControl.cpp

# The E80 appears to present a separate UDP multicast group for navigation data,
# that was provided in the Raynet length(37) packets.  The use of constants here
# is questionable.  Need to test with different/multiple E80s and probably better
# to get these from RAYNET length(40) func(16)

my $E80NAV_GROUP = '224.30.38.195';
my $E80NAV_PORT  = 2562;

# semi-known "fixed" RAYNET packets

my $RAYNET_INIT_PACKET = pack("H*","0100000003000000ffffffff76020000018e768000000000000000000000000000000000000000000000000000000000000000000000");
my $RAYNET_WAKEUP_PACKET= "ABCDEFGHIJKLMNOP";
	# these are sent to and from the E80 vis RAYNET!
	# They do no, per-se come from or go to the E80!


#-------------------------------------------
# $USE_MY_MCAST
#-------------------------------------------

sub _mcast_add
{
    my ( $sock, $addr ) = @_;
    my $ip_mreq = inet_aton( $addr ) . INADDR_ANY;

    if (!setsockopt(
        $sock,
        getprotobyname('ip') || 0,
        _constant('IP_ADD_MEMBERSHIP'),
        $ip_mreq  ))
    {
        error("SSDPScan Unable to add IGMP membership: $!");
        return 0;
    }
	return 1;
}


sub _mcast_send
{
    my ( $sock, $msg, $addr, $port ) = @_;

    # Set a TTL of 4 as per UPnP spec
    if (!setsockopt(
        $sock,
        getprotobyname('ip') || 0,
        _constant('IP_MULTICAST_TTL'),
        pack 'I', 4 ))
    {
        error("SSDPScan error setting multicast TTL to 4: $!");
        exit 1;
    };

    my $dest_addr = sockaddr_in( $port, inet_aton( $addr ) );
    my $bytes = send( $sock, $msg, 0, $dest_addr );

	$bytes = 0 if !defined($bytes);
		# otherwise in case of undef we get Perl unitialized variable warningds
	if ($bytes != length($msg))
	{
		error("SSDPScan could not _mcast_send() sent $bytes expected ".length($msg));
		return 0;
	}
	return 1;
}


sub _constant
{
    my ($name) = @_;
    my %names = (
        IP_MULTICAST_TTL  => 0,
        IP_ADD_MEMBERSHIP => 1,
        IP_MULTICAST_LOOP => 0,
    );
    my %constants = (
        MSWin32 => [10,12],
        cygwin  => [3,5],
        darwin  => [10,12],
        default => [33,35],
    );

    my $index = $names{$name};
    my $ref = $constants{ $^O } || $constants{default};
    return $ref->[ $index ];
}





#---------------------------------------------
# Session Methods
#---------------------------------------------

sub wakeUpE80
	# Appears to be necessary if RNS is not running to "wake up"
	# the E80, or perhaps MS Windows, to allow mcast_add to succeed
	# on the raynet_socket. Sends the 54 byte packet 5 times slowly
	# and then the short packet 5 times quickly.
{
	display(0,0,"wakeUpE80()");
	
	my $send_sock = IO::Socket::INET->new(
		LocalAddr => $local_ip,
		LocalPort => $local_port,
		Proto    => 'udp',
		ReuseAddr => 1 );

	if (!$send_sock)
	{
		error("Could not open send_sock: $!");
		return;
	}

	my $packed_to = pack_sockaddr_in($RAYNET_PORT, inet_aton($RAYNET_GROUP));

	my $count = 5;
	while ($count--)
	{

		$send_sock->send($RAYNET_INIT_PACKET, 0, $packed_to);
		print "init_packet($count) sent ..\n";
		sleep(0.8);
	}
	$count = 5;
	while ($count--)
	{
		$send_sock->send($RAYNET_WAKEUP_PACKET, 0, $packed_to);
		print "wakeup_packet($count) sent ..\n";
		sleep(0.01);
	}
}


sub openMulticastSocket
{
	my ($name,$GROUP,$PORT) = @_;
	my $sock;

	if ($USE_MY_MCAST)
	{
		display(0,0,"openMySocket($GROUP:$PORT)");
		$sock = IO::Socket::INET->new(
			# LocalAddr => $local_ip,
			LocalPort => $local_port,
			PeerPort  => $PORT,
			Proto     => 'udp',
			ReuseAddr => 1);

		if (!$sock)
		{
			error("Can't open my($name) socket($PORT): $!");
			return;
		}
		if (!_mcast_add($sock,$GROUP))
		{
			$sock->close();
			error("Can't joint my($name) group($GROUP): $!");
			return;
		}
	}
	else
	{
		display(0,0,"openMulticastSocket($GROUP:$PORT)");
		$sock = IO::Socket::Multicast->new(
			LocalPort => $PORT,
			ReuseAddr => 1,
			Proto     => 'udp');
		if (!$sock)
		{
			error("Can't open multicast($name) socket($PORT): $!");
			return;
		}
		if (!$sock->mcast_add($GROUP))
		{
			$sock->close();
			error("Can't joint multicast($name) group($GROUP): $!");
			return;
		}
	}

	display(0,0,"socket($name) opened!!");
	return $sock;
}


#-----------------------------------
# handleRAYNET
#-----------------------------------

sub handleRAYNET
{
	my ($raw) = @_;
	my $len = length($raw);

	if ($len == 40)
	{
		my ($type, $dev_id, $func_id, $x1, $x2,
			$tcp_ip, $tcp_port1, $tcp_port2, $e80_mcast_ip, $e80_mcast_port) = unpack('V10', $raw);
		my $tcp_ip_str = inet_ntoa(pack('N', $tcp_ip));
		my $e80_mcast_ip_str = inet_ntoa(pack('N', $e80_mcast_ip));

		print pad("",12)."type($type) id($dev_id) func($func_id) x($x1,$x2) tcp?($tcp_ip_str:$tcp_port1:$tcp_port2) e80_mcast($e80_mcast_ip_str:$e80_mcast_port)\n";
	}
	elsif ($len == 36)
	{
		my ($type, $dev_id, $func_id, $x1, $x2,
			$mcast_ip, $mcast_port, $dev_ip, $dev_port) = unpack('V9', $raw);
		my $mcast_ip_str = inet_ntoa(pack('N', $mcast_ip));
		my $dev_ip_str = inet_ntoa(pack('N', $dev_ip));

		print pad("",12)."type($type) id($dev_id) func($func_id) x($x1,$x2) mcast($mcast_ip_str:$mcast_port) dev($dev_ip_str:$dev_port)\n";
	}
	elsif ($len == 37)
	{
		# V=little endian; N=big endian

		my ($type, $dev_id, $func_id, $x1, $x2,
			$mcast_ip, $mcast_port, $dev_ip, $dev_port, $flags) = unpack('V9C', $raw);
		my $mcast_ip_str = inet_ntoa(pack('N', $mcast_ip));
		my $dev_ip_str = inet_ntoa(pack('N', $dev_ip));

		print pad("",12)."type($type) id($dev_id) func($func_id) x($x1,$x2) mcast($mcast_ip_str:$mcast_port) dev($dev_ip_str:$dev_port) flags($flags)\n";
	}
	elsif ($len == 28)
	{
		my ($type, $dev_id, $func_id, $x1, $x2,
			$ip, $port) = unpack('V7', $raw);
		my $ip_str = inet_ntoa(pack('N', $ip));

		print pad("",12)."type($type) id($dev_id) func($func_id) x($x1,$x2) addr($ip_str:$port)\n";
	}
	elsif ($len == 54)
	{
		print pad("",12);
		if ($raw eq $RAYNET_INIT_PACKET)
		{
			print "KNOWN E80_INIT_PACKET\n";
		}
		else
		{
			print "UNKNOWN RAYNET\n"
		}
	}
	elsif ($len == 56)
	{
		print pad("",12)."undecoded raynet(56)\n"
	}
	else
	{
		print "UNKNOWN RAYNET LENGTH!\n";
	}
}	# handleRAYNET()



#-----------------------------------
# main
#-----------------------------------

my $E80_OTHER_GROUP = '224.30.38.194';
my $E80_OTHER_PORT  = 2561;

my $SHOW_UI = 1;

wakeUpE80();


# We can monitor all known multicast addresses

my $sockets = {
	'e80nav' => { group=>$E80NAV_GROUP, 	port=>$E80NAV_PORT },
	'raynet' => { group=>$RAYNET_GROUP, 	port=>$RAYNET_PORT },
	'2561'   => { group=>'224.30.38.194',	port=>2561 },
	'2560'	 => { group=>'224.30.38.193',	port=>2560 },
	'5801'	 => { group=>'224.0.0.2',		port=>5801 },
};


my $any_bad = 0;
my $any_good = 0;
my $all_good = 1;
for my $name (reverse sort keys %$sockets)
{
	my $rec = $sockets->{$name};
	$rec->{socket} = 0;
	next if $SHOW_UI && $name ne 'e80nav';
	$rec->{socket} = openMulticastSocket($name,$rec->{group},$rec->{port}) || 0;
	$any_bad = 1 if !$rec->{socket};
	$any_good = 1 if $rec->{socket};
}

if (!$any_good)
{
	error("COULD NOT OPEN ANY SOCKETS!");
	exit 0;
}

display(0,0,"STARTING ...");

if ($any_bad)
{
	display(0,0,"Hit any key to continue -->");
	getc();
}

# Running

clear_screen() if $SHOW_UI;
if (0 && $SHOW_UI)
{
	testUI();
	getc();
	clear_screen();
}

my $sel = IO::Select->new();
for my $name (reverse sort keys %$sockets)
{
	next if $SHOW_UI && $name ne 'e80nav';
	my $sock = $sockets->{$name}->{socket};
	$sel->add($sock) if $sock;
}


sub findSocket
{
	my ($sock) = @_;
	for my $name (reverse sort keys %$sockets)
	{
		return $name if $sockets->{$name}->{socket} == $sock;
	}
	error("Could not find socket($sock)");
	return "error";
}


my $loop_count = 0;
while (1)
{
	$loop_count++;
	if ($SHOW_UI)
	{
		cursor(0,0);
		print "loop($loop_count)\n";
	}
	
	my @can_read = $sel->can_read(3);
	for my $sock (@can_read)
	{
		my $name = findSocket($sock);


		my $raw;
		recv ($sock, $raw, 4096, 0);

		if ($SHOW_UI && $name eq 'e80nav')
		{
			handleE80NAV($raw);
		}
		elsif (!$SHOW_UI)
		{
			my $byte_num = 0;
			my $show_hex = '';
			my $show_chars = '';
			my $len = length($raw);

			for ($byte_num=0; $byte_num<$len; $byte_num++)
			{
				if ($byte_num % 32 == 0)
				{
					print $show_hex."  ".$show_chars."\n" if $byte_num;
					print ($byte_num ? pad("",10) : pad($name,6)." ".pad($len,3) );
					print " ";
					$show_hex = '';
					$show_chars = '';
				}
				elsif ($byte_num % 4 == 0)
				{
					$show_hex .= " ";
				}
				my $byte = substr($raw,$byte_num,1);
				$show_hex .= unpack("H*",$byte);
				$show_chars .= $byte ge ' ' ? $byte : '.';
			}

			print pad($show_hex,71)."  ".$show_chars."\n" if $byte_num;

			handleRAYNET($raw) if $name eq 'raynet';
		}
	}	# for my $sock (@can_read)
}	# while (1)


1;
