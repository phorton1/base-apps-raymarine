#---------------------------------------
# tcp.pm
#---------------------------------------
# No joy in trying to hookup with the E80 with TCP
# to do Route and Track managment.
#
# This program tried just about everything to emulate RNS
# and talk to the E80 via TCP.  It was able to connect, but
# there is apparently some kind of session managment that I
# don't understand.
#
# One unclear, but positive lead about session  managment is
# that we were able to setup a listener socket and tell the
# E80 what port to send (a single uknown) unicast to.
#
# Nonetheless, even if I got a response from TCP, deciphering
# the packets, and coming up with a robust protocol for managing
# Route and Track managment on the E80 is probably a pipe dream.

package bat::raymarineE80::tcp;
use strict;
use warnings;
use Socket;
use Time::HiRes qw(sleep time);
use IO::Select;
use IO::Socket::INET;
use IO::Socket::Multicast;
use Pub::Utils;

my $dbg = 0;


my $local_ip = '10.0.241.200';
my $local_port = 8679;			# arbitrary

my $RAYNET_GROUP = '224.0.0.1';
my $RAYNET_PORT  = 5800;
my $RAYNET_ADDR = pack_sockaddr_in($RAYNET_PORT, inet_aton($RAYNET_GROUP));
my $LISTEN_PORT = 18433;
my $E80NAV_GROUP = '224.30.38.195';
my $E80NAV_PORT  = 2562;


my $RAYNET_INIT_PACKET = pack("H*",
    "0100000003000000ffffffff76020000018e768000000000000000000000000000000000000000000000000000000000000000000000");
    #0100000003000000ffffffff76020000018e768000000000000000000000000000000000000000000000000000000000000000000000

my $RAYNET_WAKEUP_PACKET = "ABCDEFGHIJKLMNOP";
	# these are sent to and from the E80 vis RAYNET!
	# They do no, per-se come from or go to the E80!

my $TRIGGER_PACKET = pack("H*", "0901050000000000").pack('v',$LISTEN_PORT);
    # 18433 encodes to "09010500000000000148"
    # but it works with any unused port number

my $ANNOUNCE_PACKET = pack("H*","00000000ffffffff1b00000001001e00aa161000020000e0a9160000c8f1000aaa160000");


#----------------------------------
# main
#----------------------------------


my $sock_send;      # generic udp socket with dest specified in send
my $sock_5801;      # multicast 224.0.0.2:5801
my $sock_2561;      # multicast 224.30.38.194:2561
my $sock_2562;      # multicast 224.30.38.195:2562
my $sock_listen;    # generic udp port that listens to LISTEN_PORT
my $sock_trigger;   # for writing to 10.0.241.54:2049


sub openMulticastSocket
{
	my ($name,$GROUP,$PORT) = @_;
	my $sock;
    display($dbg,0,"openMulticastSocket($name,$GROUP:$PORT)");
    $sock = IO::Socket::Multicast->new(
        LocalPort => $PORT,
        ReuseAddr => 1,
        Proto     => 'udp') ||
        die("Coult not open multicast socket($name,$GROUP:$PORT): $!");

    if (!$sock->mcast_add($GROUP))
    {
        $sock->close();
        die("Can't joint multicast($name,$GROUP:$PORT): $!");
    }
	return $sock;
}


sub sendInitPacket
{
    display($dbg,0,"sendInitPacket()");
    $sock_send->send($RAYNET_INIT_PACKET, 0, $RAYNET_ADDR);
}

sub sendWakeupPacket
{
    display($dbg,0,"sendWakeupPacket()");
	$sock_send->send($RAYNET_WAKEUP_PACKET, 0, $RAYNET_ADDR);
}


# state machine that mimics, to the best of my ability
# the startup sequence of RNS.  When to open (and/or
# close) sockets is questionable.
#
# Note that we do not actually monitor any multicast
# sockets, so particularly, we don't get RAYNET packets.
# I have already deciphered much of the RAYNET packets,
# but there could be lurking information there, that I am
# missing when formulating the TCP packet, that remains
# undiscovered.

my $state = 0;

while (1)
{
    # Open a generic udp unicast socket for sending packet

    if ($state == 0)
    {
        display($dbg,0,"open sock_send");
        $sock_send = IO::Socket::INET->new(
            LocalAddr => $local_ip,
            LocalPort => $local_port,
            Proto    => 'udp',
            ReuseAddr => 1 ) ||
            die("Could not open sock_send: $!");
        $state++;
    }

    # Emulate the wakeupE80 method by sending 5 init packets once
    # per second, then 10 wakeup packets in rapid succession.

    elsif ($state == 1)
    {
        for (my $i=0; $i<5; $i++)
        {
            sendInitPacket();
            sleep(1);
        }
        $state++;
    }
    elsif ($state == 2 && $state <= 15)
    {
        for (my $i=0; $i<10; $i++)
        {
            sendWakeupPacket();
            sleep(0.001);
        }
        $state++;
    }

    # For lack of a better place to do this, we now open some
    # multi-cast sockets similar to what RNS does and open a
    # listener socket.

    elsif ($state == 3)
    {
        $sock_5801 = openMulticastSocket('5801','224.0.0.2',5801);
        sleep(0.1);
        $sock_2561 = openMulticastSocket('2561','224.30.38.194',2561);
        sleep(0.1);
        $sock_2562 = openMulticastSocket('2562','224.30.38.195',2562);
        sleep(0.01);
        display($dbg,0,"opening sock_listen");
        $sock_listen = IO::Socket::INET->new(
            LocalPort => $LISTEN_PORT,
            Proto     => 'udp',
            ReuseAddr => 1 ) ||
            die("Could not open sock_listen: $!");
        sleep(0.1);
        $state++;
    }

    # Send the trigger packet and read the UDP listener socket.
    # This receives 0900050000000000700a00000100140020202020303031343830324130385737393232330f270c
    # exactly the same as RNS
    #                                        09 00 05 00 00 00   ....H../........
    #   0030   00 00 88 13 00 00 01 00 14 00 20 20 20 20 30 30   ..........    00
    #   0040   31 34 38 30 32 41 30 38 57 37 39 32 32 33 0f 27   14802A08W79223.'
    #   0050   0c
    #
    # I could make nothing of the obvious text string.

    elsif ($state == 4)
    {
        display($dbg,0,"opening sock_trigger");
        $sock_trigger = IO::Socket::INET->new(
            PeerAddr => '10.0.241.54',
            PeerPort => 2049,
            Proto    => 'udp' ) ||
            die("Coult not open sock_trigger; $!");
        sleep(0.5);

        display($dbg,0,"sending trigger packet");
        $sock_trigger->send($TRIGGER_PACKET);

        my $buf;
        $sock_listen->recv($buf, 1024);
        if ($buf)
        {
            print "Received: ", unpack("H*", $buf), "\n";
        }
        else
        {
            die("nothing on listen_sock");
        }
        sleep(0.5);
        $state++;
    }

    # send the announce packet, preceded by send another pair
    # of init and wakeup packets JIC

    elsif ($state == 5)
    {
        sendInitPacket();
        sendWakeupPacket();
        sleep(0.1);
        display($dbg,0,"sending announce packet");
        $sock_send->send($ANNOUNCE_PACKET, 0, $RAYNET_ADDR);
        sleep(0.5);
        last;
    }
}


# Create TCP socket to E80
#
# I played quite a bit with various packets and observed behavior.
#
# When RNS sends 0800 and 0201100062000000, it gets a two byte TCP reply.
# When I send it, I get nothing. RNS then sends the final bytes
# 0c00050110000100000062000000 and gets a lot of TCP replies.
#
# 0900 - if I send 0900 the recv() hangs, as apparently the E80 is
# waiting for more bytes.  I tried a lot of bytes and it didn't unhang.
#
# I have tried sending the whole message at once, varying some of
# the bytes in the 0201100062000000 packet, all with no joy.
#
# The suspicion is that the 0201100062000000 packet contains some
# kind of session management key to/from RAYNET, and that I'm not
# sending the right stuff (for my instance).  In any case, I havn't
# figured it out and there are many other things to do.

# my $packet = pack('H*', '080002011000620000000c00050110000100000062000000');
my $packet1 = pack('H*', '0800');         # First 2 bytes
my $packet2 = pack('H*', '0201100062000000');  # Next 8 bytes
#my $packet2 = pack('H*', 'b0010f0000000000');
my $packet3 = pack('H*', '0c');
my $packet4 = pack('H*',' 00050110000100000062000000'); # final bytes


display($dbg,0,"creating sock_tcp");
my $sock_tcp = IO::Socket::INET->new(
    LocalAddr => $local_ip,
    PeerAddr => '10.0.241.54',
    PeerPort => 2052,
    Proto    => 'tcp',
    Timeout  => 5 ) ||
die("Could not create sock_tcp: $!");


display($dbg,0, "sending tcp packet(s)");

my $sleep_interval = 0;

sleep($sleep_interval);
print $sock_tcp $packet1 if 1;
sleep($sleep_interval);
print $sock_tcp $packet2 if 1;
sleep($sleep_interval);
print $sock_tcp $packet3 if 1;
sleep($sleep_interval);
print $sock_tcp $packet4 if 1;

sleep(0.1);

my $response;
my $bytes = read($sock_tcp, $response, 1024);
if ($bytes)
{
    print "Received $bytes bytes:\n";
    print unpack('H*', $response), "\n";
}
else
{
    print "No response received\n";
}



$sock_tcp->close();
$sock_send->close();
$sock_5801->close();
$sock_2561->close();
$sock_trigger->close() if $sock_trigger;
$sock_listen->close() if $sock_listen;

print "tcp.pm finishing\n";

1;
