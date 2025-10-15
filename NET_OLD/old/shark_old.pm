#---------------------------------------------
# shark_old.pm
#---------------------------------------------
# A perl app that can act as a realtime packet processor for wireShark.
#
# Using this I FINALLY sent a tcp request to the E80 and got a valid 'waypoint' response!!!!
#
# At this point I am still running RNS and need to copy request packets from what it sends to the E80.
#
# I need to work backwards and be able to run this program stand alone without RNS.
#
# Note that the E80 ip address 10.0.241.54:2052 is rightfully exposed by UDP.
# See raynet.pm and raynet.md for details about that.
#
# This program succeesfully made contact with the E80 over TCP, but required
# me to have RNS running, and to paste constants captured from it into
# the stream.  Hence I pulled back and started a new raynet.pm based on
# what I learned here and previously in raynet_old.pm.

use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use IO::Socket::INET;
use Pub::Utils;


my $e80_ip   = '10.0.241.54';
my $e80_port = 2052;

my $sock = IO::Socket::INET->new(
    PeerAddr => $e80_ip,
    PeerPort => $e80_port,
    LocalPort => 60000,  # Arbitrary high port
    Proto    => 'tcp',
    Timeout  => 5,
) or die "Can't connect to E80: $!";

my $polling_thread = threads->create(\&polling_thread);
$polling_thread->detach();


sub polling_thread
{
    while (1)
    {
        # Send the polling request
        my $request1 = pack("H*", "1000");
        $sock->send($request1);
        sleep(0.001);

        ### THIS IS WHERE I RAN INTO TROUBLE
        ### I NEED TO FIGURE OUT HOW TO MAKE THIS PACKET.
        
        # my $request2 = pack("H*", "03010f00d818000081b237a63500b752");
        # my $request2 = pack("H*", "03010f004f00000081b237a63500d759");
        # my $request2 = pack("H*", "03010f00a601000081b237a63500195e");
        my $request2 = pack("H*", "03010f003203000081b237a63500c362");

        $sock->send($request2);
        my $response;
        my $bytes = $sock->recv($response, 1024) || 0;
        if ($bytes && length($response))
        {
            display_bytes(0,0,"response",$response);
            # my $ascii = $response;
            # $ascii =~ s/[^\x20-\x7E]/./g;
            # print "Received($bytes)\b"; #: $ascii\n";
        }
        sleep(1);
    }
}


my $data_info = [
    { name => 'src_ip',     field => 'ip.src' },
    { name => 'src_port',   field => 'tcp.srcport' },
    { name => 'dest_ip',    field => 'ip.dst' },
    { name => 'dest_port',  field => 'tcp.dstport' },
    { name => 'payload',    field => 'tcp.payload' },
];





my $tshark_cmd = '"C:\\Program Files\\Wireshark\\tshark.exe" -i Ethernet -l -Y "tcp.len > 0" -T fields ';
$tshark_cmd .= join ' ', map { "-e $_->{field}" } @$data_info;
$tshark_cmd .= ' 2>NUL';  # Suppress STDERR on Windows


open(my $fh, '-|', $tshark_cmd) or die "Failed to run tshark: $!";

while (my $line = <$fh>) {
    chomp $line;
    next if !$line;  # Skip empty lines

    my $rec = {};
    my @parts = split(/\t/,$line);
    @{$rec}{ map $_->{name}, @$data_info } = @parts;

    if ($rec->{src_ip} eq '10.0.241.200' &&
        $rec->{dest_ip} eq '10.0.241.54' &&
        $rec->{dest_port} == 2052)
    {
        print "REQUEST from($rec->{src_port}): $rec->{payload}\n";
    }
    
    my $ascii_payload = pack("H*",$rec->{payload});
    if ($ascii_payload =~ /Waypoint (\w+)/)
    {
        my $wp_name = $1;
        print "$rec->{src_ip}:$rec->{src_port} --> $rec->{dest_ip}:$rec->{dest_port} : Found Waypoint: $wp_name\n";
    }
}



1;