#---------------------------------------------
# raynet.pm
#---------------------------------------------

use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Socket;
use IO::Socket::INET;
use IO::Select;
use IO::Socket::INET;
use IO::Socket::Multicast;
use Pub::Utils;
use ray_UI;

my $dbg = 0;

# OLD COMMENT
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

# semi-known "fixed" RAYDP information

my $RAYDP_GROUP = '224.0.0.1';		# radar: SEATALK_HS_ANNOUNCE_GROUP in RMControl.cpp
my $RAYDP_PORT  = 5800;			    # radar: SEATALK_HS_ANNOUNCE_PORT in RMControl.cpp
my $RAYDP_ADDR = pack_sockaddr_in($RAYDP_PORT, inet_aton($RAYDP_GROUP));
my $RAYDP_INIT_PACKET = pack("H*","0100000003000000ffffffff76020000018e768000000000000000000000000000000000000000000000000000000000000000000000");
my $RAYDP_WAKEUP_PACKET= "ABCDEFGHIJKLMNOP";

my $local_ip = '10.0.241.200';
my $local_port = 8679;			# arbitrary
my $sock_send;      # generic udp (unicast) socket with dest specified in each send

my $E80TCP_IP;
my $E80TCP_PORT;
    # Discovered from RAYDP


my $raydp_info:shared = shared_clone({});
    # hash by (len:type) of RAYDP packets encountered
    # where each record contains various fields


sub openMulticastSocket
{
	my ($quiet,$name,$GROUP,$PORT) = @_;
	my $sock;
    display($dbg,0,"openMulticastSocket($name,$GROUP:$PORT) quiet=$quiet");
    $sock = IO::Socket::Multicast->new(
        LocalPort => $PORT,
        ReuseAddr => 1,
        Proto     => 'udp') || $quiet ||
            error("Coult not open multicast socket($name,$GROUP:$PORT): $!");

    if (!$sock->mcast_add($GROUP))
    {
        $sock->close();
        error("Can't joint multicast($name,$GROUP:$PORT): $!") if !$quiet;
        $sock = 0;
    }
	return $sock;
}


sub sendInitPacket
{
    display($dbg,0,"sendInitPacket()");
    $sock_send->send($RAYDP_INIT_PACKET, 0, $RAYDP_ADDR);
}

sub sendWakeupPacket
{
    display($dbg,0,"sendWakeupPacket()");
	$sock_send->send($RAYDP_WAKEUP_PACKET, 0, $RAYDP_ADDR);
}

sub wakeupE80
    # We were not sure if this was required to truly wake up the E80
    # or if it was necessary to generate some multicast traffic before
    # Windows would let us join the multi-cast group
{
    display($dbg,0,"open sock_send");
    $sock_send = IO::Socket::INET->new(
        LocalAddr => $local_ip,
        LocalPort => $local_port,
        Proto    => 'udp',
        ReuseAddr => 1 ) ||
            die("Could not open sock_send: $!");
    for (my $i=0; $i<5; $i++)
    {
        sendInitPacket();
        sleep(1);
    }
    for (my $i=0; $i<10; $i++)
    {
        sendWakeupPacket();
        sleep(0.001);
    }
}



#-----------------------------------
# handleRAYNET
#-----------------------------------

sub decodeStuff
{
    my ($rec,$raw,@fields) = @_;
    my @values = @{$rec}{@fields} = unpack("V" . @fields, $raw);
    my $text = '';
    for (my $i=0; $i<@fields; $i++)
    {
        my $field = $fields[$i];
        my $value = $values[$i];
        if ($field =~ /ip/)
        {
            $value = inet_ntoa(pack('N', $value));
            $rec->{"str_$field"} = $value;
        }
        $text .= "$field($value) ";
    }
    $rec->{text2} = $text;
    return substr($raw,4 * @values);
}




sub decodeRAYDP
{
	my ($orig_raw) = @_;
	my $len = length($orig_raw);

    # decode the first 5 32 bit uint32's

    my ($type, $id, $func, $x1, $x2) = unpack('VH8VH8H8', $orig_raw);
    my $rec = shared_clone({
        count => 1,
        raw => $orig_raw,
        type => $type,
        id => $id,
        func => $func,      # important
        x1 => $x1,
        x2 => $x2,
        text1 => sprintf("len($len) type($type) id($id) func(%2d) x($x1,$x2)",$func) });
    my $raw = substr($orig_raw,5 * 4);

	if ($len == 40)
	{
        decodeStuff($rec,$raw,qw(tcp_ip tcp_port1 tcp_port2 mcast_ip mcast_port));
	}
	elsif ($len == 36)
	{
        decodeStuff($rec,$raw,qw(mcast_ip mcast_port tcp_ip tcp_port));
        if ($func == 27)
        {
            $E80TCP_IP = $rec->{tcp_ip};
            $E80TCP_PORT = $rec->{tcp_port};
        }
	}
	elsif ($len == 37)
	{
        $raw = decodeStuff($rec,$raw,qw(mcast_ip mcast_port tcp_ip tcp_port));
        my $flags = unpack("C",$raw);
        $rec->{flags} = $flags;
        $rec->{text2} .= "flags($flags) ";
	}
	elsif ($len == 28)
	{
        decodeStuff($rec,$raw,qw(ip port));
	}
	elsif ($len == 54)
	{
		if ($orig_raw eq $RAYDP_INIT_PACKET)
		{
            $rec->{text1} = "id($rec->{id}";
			$rec->{text2} = "KNOWN E80_INIT_PACKET";
		}
		else
		{
			$rec->{text2} = "UNKNOWN PACKET(54) ".unpack("H*",$orig_raw);
		}
	}
	elsif ($len == 56)
	{
        $rec->{text1} = "id($rec->{id}";
		$rec->{text2} = "UNDECODED PACKET(56) ".unpack("H*",$orig_raw);
	}
	else
	{
		$rec->{text2} = "UNKNOWN PACKET($len) ".unpack("H*",$orig_raw);
	}


    my $key = sprintf("$len:%02d$id",$func);
    my $found = $raydp_info->{$key};
    $rec->{count} = $found->{count} + 1 if $found;
    if (!$found || $orig_raw ne $found->{raw})
    {
        print "$rec->{text1} $rec->{text2}\n";
        if ($found && $orig_raw ne $found->{raw})
        {
            error("DATA CHANGED!!");
            print "old=".unpack("H*",$found->{raw})."\n";
            print "new=".unpack("H*",$rec->{raw})."\n";
            $rec = $found;
        }

    }
    $raydp_info->{$key} = $rec;
    
    return $rec->{count};

}	# decodeRAYDP()



#------------------------------------
# main
#------------------------------------


my $sock_raydp = openMulticastSocket(1,'RAYDP',$RAYDP_GROUP,$RAYDP_PORT);
if (!$sock_raydp)
{
    wakeupE80();
    $sock_raydp = openMulticastSocket(0,'RAYDP',$RAYDP_GROUP,$RAYDP_PORT);
    exit(0) if !$sock_raydp;
}

my $sel = IO::Select->new();
$sel->add($sock_raydp);

# gets the $E80TCP_IP and PORT, but also does three full sets of
# RAYDP broadcasts to make  sure we have em all

my $count = 0;
while (!$E80TCP_IP || $count<=3)
{
	my @can_read = $sel->can_read(3);
	for my $sock (@can_read)
	{
		my $raw;
		recv ($sock, $raw, 4096, 0);
        $count = decodeRAYDP($raw);
    }
}

print "PROGRAM STARTED\n";




1;