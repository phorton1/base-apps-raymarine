#---------------------------------------------
# shark.pm
#---------------------------------------------
package apps::raymarine::NET::shark;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use apps::raymarine::NET::r_utils;
use apps::raymarine::NET::r_sniffer;
use apps::raymarine::NET::r_RAYDP;
use Pub::Utils;


my $dbg_shark = 0;

sub sniffer_thread
{
    display($dbg_shark,0,"sniffer thread started");
    while (1)
    {
        my $packet = nextSniffPacket();
        if ($packet)
        {
            my $len = length($packet->{payload});
            display($dbg_shark+1,1,"got $packet->{proto} packet len($len)");
            if ($packet->{udp} &&
                $packet->{dest_ip} eq $RAYDP_IP &&
                $packet->{dest_port} == $RAYDP_PORT)
            {
                decodeRAYDP($packet);
            }
            elsif ($packet->{raw} =~ /Waypoint (\w+)/)
            {
                my $wp_name = $1;
                print "$packet->{src_ip}:$packet->{src_port} --> $packet->{dest_ip}:$packet->{dest_port} : Found Waypoint: $wp_name\n";
            }
            elsif ($packet->{tcp} && $packet->{src_ip} eq '10.0.241.200')
            {
                print(packetWireHeader($packet,0)."$packet->{hex32}\n");
            }
            elsif ($packet->{tcp} && $packet->{src_ip} eq '10.0.241.54')
            {
                print(packetWireHeader($packet,1)."$packet->{hex32}\n");
            }
        }
        else
        {
            sleep(0.001);
        }
    }
}


#---------------------------------------------------------
# main
#---------------------------------------------------------

display(0,0,"shark.pm started");

# exit(0) if !wakeup_e80();
exit(0) if !startSniffer();


my $sniffer_thread = threads->create(\&sniffer_thread);
$sniffer_thread->detach();

display(0,0,"starting main loop");

while (1)
{
    sleep(1);
}


1;