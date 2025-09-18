#---------------------------------------------
# r_RAYDP.pm
#---------------------------------------------

package apps::raymarine::NET::r_RAYDP;
use strict;
use warnings;
use threads;
use threads::shared;
use apps::raymarine::NET::r_utils;
use Socket;
use Pub::Utils;

my $dbg_raydp = 1;

# a raydp "device" represents a unique func:id pair that was broadcast
#   to the RAYDP udp multicast group and which exposes raydp "ports"
# a raydp "port" is a protocol (tcp/ip) ip_address, and port within a
#   raydp device. A device typically exposes a tcp port and a multicast
#   udp port, though some only expose a single tcp port and no udp ports,
#   and some expose multiple tcp ports along with a single udp port
# We have tentatively named some of the funcs, but that is a work in progress.

our $FUNC_E80TCP = 27;
our $raydp_devices:shared = shared_clone({});
    # a hash of all unique RAYDP udp descriptor packets on the wire
our $raydp_ports:shared = shared_clone({});
    # a list built from that of all ports that can be monitored

# devices apparently send out keep alive messaes and
# join the multicast group with their own listeners.
# This global variable allows the UI to turn the monitoring
# of those keep alive messages on or off

our $MONITOR_RAYDP_ALIVE = 0;

our $KNOWN_UNDECODED56 = pack("H*","010000000000000037a681b23902000036f1000a0033cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc3302000100");



BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(
        funcName

        $MONITOR_RAYDP_ALIVE
        $raydp_ports

        decodeRAYDP
        $raydp_devices
        findRayDevice
    );
}


#------------------------------------
# UI API (in addition to hashes)
#------------------------------------

sub funcName
{
    my ($func) = @_;
    return "E80NAV" if $func == 16;
    return "E80TCP" if $func == 27;
    return "func($func)";
}

sub findRayDevice
{
    my ($func,$id) = @_;
    my $key = "$func:$id";
    return $raydp_devices->{$key};
}



#-----------------------------------
# sniffer API (called by shark.pm
#-----------------------------------

sub addPort
{
    my ($rec,$proto,$ip,$port) = @_;
    my $addr = "$proto $ip:$port";
    my $found = $raydp_ports->{$addr};
    if (!$found)
    {
        my $port = shared_clone({
            proto   => $proto,
            ip      => $ip,
            port    => $port,
            addr    => $addr,
            func    => $rec->{func},    # the function IS the kind of device
            id      => $rec->{id},

            # preparation for wx widgets UI to control monitor

            mon_in => 0,
            mon_out => 0,
        });
        $raydp_ports->{$addr} = $port;
    }
}


sub decode_stuff
{
    my ($with_flags, $rec, $raw, @fields) = @_;
    my @values = @{$rec}{@fields} = unpack("V" . @fields, $raw);
    if ($with_flags)
    {
        my $flags = unpack("C",substr($raw,4 * @fields));
        push @fields,"flags";
        push @values,$flags;
        $rec->{flags} = $flags;
    }

    my $text = '';
    for (my $i = 0; $i < @fields; $i++)
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
    return $text;
}



sub decodeRAYDP
    # MAIN ENTRY POINT from shark.pm that gets called
    # with all packets that are sent to the $RAYDP_GROUP
    # and $RAYDP_PORT
{
    my ($packet) = @_;
    my $raw = $packet->{raw};
    my $len = length($raw);
    display($dbg_raydp,0,"decodeRAYDP($len)");

    # packets we can skip merely based on the raw contents

    if ($raw eq $RAYDP_ALIVE_PACKET)
    {
        print packetWireHeader($packet,0)."RAYDP_ALIVE_PACKET\n"
            if $MONITOR_RAYDP_ALIVE;
        return;
    }
    if ($raw eq $RAYDP_WAKEUP_PACKET)
    {
        print packetWireHeader($packet,0)."RAYDP_WAKEUP_PACKET: ".unpack("H*",$raw)."\n";
        return;
    }

    # parse the RAYDP packet for header fields

    my ($type, $id, $func, $x1, $x2) = unpack('VH8VH8H8', $raw);
    my $rec = shared_clone({
        raw   => $raw,
        len   => $len,
        type  => $type,
        id    => $id,
        func  => $func,
        x1    => $x1,
        x2    => $x2,
    });


    # implementation error if the key is not unique enough

    my $key = sprintf("$func:$id");
    my $found = $raydp_devices->{$key};
    if ($found && $rec->{raw} ne $found->{raw})
    {
        if ($found && $rec->{raw} ne $found->{raw})
        {
            setConsoleColor($DISPLAY_COLOR_ERROR);
            print packetWireHeader($packet,0)."SKIPPING CHANGED RAYDP_PACKET len($len) func($func) id($id)!!\n";
            print "old=".unpack("H*",$found->{raw})."\n";
            print "new=".unpack("H*",$rec->{raw})."\n";
            setConsoleColor();
            return;
        }
    }

    # set the count and return if the RAYDP packet has already been parsed

    my $count = $found ? $found->{count} : 0;
    $count++;
    $rec->{count} = $count;
    return if $found;

    # PARSE AND ADD A NEW RAYDP RECORD


    my $text2 = '';
    my $text1 = sprintf("len(%d) type(%d) id(%s) func(%2d) x(%s,%s)", $len, $type, $id, $func, $x1, $x2);
    my $payload = $len > 20 ? substr($raw, 5 * 4) : '';

    if ($len == 28)
    {
        $text2 = decode_stuff(0,$rec, $payload, qw(ip port));
        addPort($rec,'tcp',$rec->{ip},$rec->{port});
    }
    elsif ($len == 36)
    {
        $text2 = decode_stuff(0,$rec, $payload, qw(mcast_ip mcast_port tcp_ip tcp_port));
        addPort($rec,'udp',$rec->{mcast_ip},$rec->{mcast_port});
        addPort($rec,'tcp',$rec->{tcp_ip},$rec->{tcp_port});
    }
    elsif ($len == 37)
    {
        $text2 = decode_stuff(1, $rec, $payload, qw(mcast_ip mcast_port tcp_ip tcp_port));
        addPort($rec,'udp',$rec->{mcast_ip},$rec->{mcast_port});
        addPort($rec,'tcp',$rec->{tcp_ip},$rec->{tcp_port});
    }
    elsif ($len == 40)
    {
        $text2 = decode_stuff(0,$rec, $payload, qw(tcp_ip tcp_port1 tcp_port2 mcast_ip mcast_port));
        addPort($rec,'udp',$rec->{mcast_ip},$rec->{mcast_port});
        addPort($rec,'tcp',$rec->{tcp_ip},$rec->{tcp_port1});
        addPort($rec,'tcp',$rec->{tcp_ip},$rec->{tcp_port2});
    }

    # packets that we skip but display

    elsif ($len == 56 && $raw eq $KNOWN_UNDECODED56)
    {
		$text1 = "KNOWN UNDECODED PACKET(56)";
    }
    else
    {
        setConsoleColor($DISPLAY_COLOR_WARNING);
		print packetWireHeader($packet,0)."UNKNOWN PACKET($len) ".unpack("H*",$rec->{raw})."\n";
        setConsoleColor();
        return;
    }

    setConsoleColor($DISPLAY_COLOR_LOG);
    print packetWireHeader($packet,0)."$text1 $text2\n";
    setConsoleColor();
    $raydp_devices->{$key} = $rec;
}



1;