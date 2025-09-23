#---------------------------------------------
# r_RAYDP.pm
#---------------------------------------------
# I have more or less decoded all of the RAYNET (5800) packets,
# except for one that is 56 bytes long and which does not appear
# to match the conventions used by all of the others.

#	UNKNOWN PACKET(56)
#		01000000 00000000 37a681b2 39020000 [36f1000a] 0023ad01 5cd87304 01000000
#		00000000 37a681b2 39220000 [36f1000a] 0033cc33 02000100
#
#	[36f1000a] == 10.0.241.54
#


package apps::raymarine::NET::r_RAYDP;
use strict;
use warnings;
use threads;
use threads::shared;
use apps::raymarine::NET::r_utils;
use Socket;
use Pub::Utils;

my $dbg_raydp = 1;

BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

        $MONITOR_RAYDP_ALIVE

        findRayDevice
        findRayPort
        getRayPorts
		findRayPortByName

        decodeRAYDP
    );
}


# a raydp "device" represents a unique func:id pair that was broadcast
#   to the RAYDP udp multicast group and which exposes raydp "ports"
# a raydp "port" is a protocol (tcp/ip) ip_address, and port within a
#   raydp device. A device typically exposes a tcp port and a multicast
#   udp port, though some only expose a single tcp port and no udp ports,
#   and some expose multiple tcp ports along with a single udp port
# We have tentatively named some of the funcs, but that is a work in progress.

# devices apparently send out keep alive messaes and
# join the multicast group with their own listeners.
# This global variable allows the UI to turn the monitoring
# of those keep alive messages on or off

our $MONITOR_RAYDP_ALIVE:shared = 0;


my $KNOWN_UNDECODED = [
	# 56
	pack("H*","010000000000000037a681b23902000036f1000a0033cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc3302000100"),
	pack("H*","010000000000000037a681b23902000036f1000a0033cc33cc32c433cc33cc33cc33cc33cc33cc37cc33c833cc33cc33cc33cc3302000100"),
];


# Most recent devices found, sorted by length,func
#
#   len(28) type(0) id(37a681b2) func( 7) x(01001e00,06080800) ip(10.0.241.54) port(2054)
#   len(28) type(0) id(37a681b2) func(15) x(01001e00,04080800) ip(10.0.241.54) port(2052)
#   len(28) type(0) id(37a681b2) func(19) x(01001e00,05080800) ip(10.0.241.54) port(2053)
#   len(28) type(0) id(37a681b2) func(22) x(01001e00,07080800) ip(10.0.241.54) port(2055)
#   len(36) type(0) id(37a681b2) func( 8) x(09001e00,08081000) mcast_ip(224.30.38.196) mcast_port(2563) tcp_ip(10.0.241.54)  tcp_port(2056)
#   len(36) type(0) id(37a681b2) func(27) x(01001e00,aa161000) mcast_ip(224.0.0.2)     mcast_port(5801) tcp_ip(10.0.241.54)  tcp_port(5802)
#   len(36) type(0) id(ffffffff) func(27) x(01001e00,aa161000) mcast_ip(224.0.0.2)     mcast_port(5801) tcp_ip(10.0.241.200) tcp_port(5802)
#   len(36) type(0) id(37a681b2) func(35) x(01001e00,00081000) mcast_ip(224.30.38.193) mcast_port(2560) tcp_ip(10.0.241.54)  tcp_port(2048)
#   len(37) type(0) id(37a681b2) func( 5) x(01001e00,01081100) mcast_ip(224.30.38.194) mcast_port(2561) tcp_ip(10.0.241.54)  tcp_port(2049) flags(1)
#   len(40) type(0) id(37a681b2) func(16) x(01001e00,02081400) tcp_ip(10.0.241.54) tcp_port1(2050) tcp_port2(2051) mcast_ip(224.30.38.195) mcast_port(2562)
#

# It looks like this "trigger packet" may be  registering port 18432 (0x0048) for
# chart functions? xx010500 where xx is 0x09 and subsequently requests are
# made to via udp to port(2049) and *perhaps* the packets are sent via tcp
# to the requester ip address and the given port 18432
#
# udp(10)   10.0.241.54:2049     <-- 10.0.241.200:55481    09010500 00000000 0048
#
# in my tcp_old.pm program I sent the same packet with my encoded ip address
# 



# Most recent ray_port breakdown, sorted by port number
# with the names I previously associated with the funcs
#
# 									def color			notes
#---------------------------------------------------------------------------
#   35	tcp	10.0.241.54		2048
#   5	tcp	10.0.241.54		2049					UDP !!! CHARTREQ register and requests
#   16	tcp	10.0.241.54		2050					GPS
#   16	tcp	10.0.241.54		2051
#   15	tcp	10.0.241.54		2052					NAVQRY sends and receive (ack?) waypoints
#   19	tcp	10.0.241.54		2053
#   7	tcp	10.0.241.54		2054
#   22	tcp	10.0.241.54		2055
#   8	tcp	10.0.241.54		2056

#   35	udp	224.30.38.193	2560
#   5	udp	224.30.38.194	2561
#   16	udp	224.30.38.195	2562					E80NAV udp that I actually parsed
#   8	udp	224.30.38.196	2563
#  *0*	udp 224.0.0.1		5800					RAYNET itself, RNS at $LOCAL_IP also advertises this
#   27	udp	224.0.0.2		5801	in 				HEARTBEAT Two advertisments, one port once RNS starts
#   27	tcp	10.0.241.54		5802
#   27	tcp	10.0.241.200	5802

# my $E80_IP = '10.0.241.54';
# my $REGISTER_PORT = 2049;
# UUU fucking DDDDD PPPPP ????

# 5801 appears to get keep alive messages from the E80

#    'Default',
#    'Blue',
#    'Green',
#    'Cyan',
#    'Red',
#    'Magenta',
#    'Brown',
#    'Light Gray',
#    'Gray',
#    'Light Blue',
#    'Light Green',
#    'Light Cyan',
#    'Light Red',
#    'Light Magenta',
#    'Yellow',
#    'White',

my $RNS_INIT  = 0;
my $UNDER_WAY = 0;
my $FILESYS = 0;
my $MY_GPS = $UNDER_WAY;
my $MY_NAV = 1;

# the zeros are things that happen when underway with I_0183 and RNS running
# $RNS_INIT only happened during RNS startup after that

my $PORT_DEFAULTS  = {
	2048 => { name=>'',			mon_in=>1,			mon_out=>$UNDER_WAY,	multi=>1,	color=>0,	 },
	2049 => { name=>'FILESYS',	mon_in=>$FILESYS,	mon_out=>1,				multi=>1,	color=>$UTILS_COLOR_CYAN,    },
	2050 => { name=>'GPS',		mon_in=>$MY_GPS,	mon_out=>$MY_GPS,		multi=>1,	color=>0,    },
	2051 => { name=>'',			mon_in=>1,			mon_out=>1,				multi=>1,	color=>0,    },
	2052 => { name=>'NAVQRY',	mon_in=>$MY_NAV,	mon_out=>$MY_NAV,		multi=>1,	color=>$UTILS_COLOR_LIGHT_GREEN,    },	#
	2053 => { name=>'',			mon_in=>1,			mon_out=>1,				multi=>1,	color=>0,    },
	2054 => { name=>'',			mon_in=>$RNS_INIT,	mon_out=>$UNDER_WAY,	multi=>1,	color=>$UTILS_COLOR_LIGHT_CYAN,    },
	2055 => { name=>'',			mon_in=>1,			mon_out=>1,				multi=>1,	color=>0,    },
	2056 => { name=>'',			mon_in=>1,			mon_out=>1,				multi=>1,	color=>0,    },
	2560 => { name=>'',			mon_in=>1,			mon_out=>1,				multi=>1,	color=>0,    },
	2561 => { name=>'',			mon_in=>1,			mon_out=>1,				multi=>1,	color=>0,    },
	2562 => { name=>'E80NAV',	mon_in=>$UNDER_WAY,	mon_out=>1,				multi=>1,	color=>$UTILS_COLOR_GREEN,    },
	2563 => { name=>'',			mon_in=>$UNDER_WAY,	mon_out=>1,				multi=>1,	color=>0,    },
	5801 => { name=>'ALIVE',	mon_in=>$UNDER_WAY,	mon_out=>1,				multi=>1,	color=>$UTILS_COLOR_BLUE,    },
	5802 => { name=>'',			mon_in=>1,			mon_out=>1,				multi=>1,	color=>0,    },
	5802 => { name=>'',			mon_in=>1,			mon_out=>1,				multi=>1,	color=>0,    },
};






my $devices:shared = shared_clone({});
    # a hash of all unique RAYDP udp descriptor packets by func:id
my $ports = shared_clone([]);
my $ports_by_addr:shared = shared_clone({});
    # a list of all ports in order they're found,
    # and ahash of them by addr
my $duplicate_unknown:shared = shared_clone({});


#------------------------------------
# accesors
#------------------------------------


sub findRayDevice
{
    my ($func,$id) = @_;
    my $key = "$func:$id";
    return $devices->{$key};
}

sub findRayPort
{
    my ($ip,$port) = @_;
    my $addr = "$ip:$port";
    return $ports_by_addr->{$addr};
}

sub getRayPorts
{
    return $ports;
}

sub findRayPortByName
{
	my ($name) = @_;
	for my $rayport (@$ports)
	{
		return $rayport if $rayport->{name} eq $name;
	}
	return 0;
}



#-----------------------------------
# sniffer API (called by shark.pm
#-----------------------------------

sub _addPort
{
    my ($rec,$proto,$ip,$port) = @_;
    my $ip_str = inet_ntoa(pack('N', $ip));
    my $addr = "$ip_str:$port";
    my $found = $ports_by_addr->{$addr};
    if (!$found)
    {
		my $def = $PORT_DEFAULTS->{$port} || {};
		# warning(0,0,"adding port $proto $addr in($def->{mon_in}) out($def->{mon_out}) color($def->{color}) multi($def->{multi})");

        my $ray_port = shared_clone({
            proto   => $proto,
            ip      => $ip_str,
            port    => $port,
            addr    => $addr,
            func    => $rec->{func},    # the function is??
			id      => $rec->{id},

            # for wxWidgets winRAYDP
			
			name    => $def->{name},
            mon_in => $def->{mon_in} || 0,
            mon_out => $def->{mon_out} || 0,
            color => $def->{color} || 0,
			multi => $def->{multi} || 0,
        });
        $ports_by_addr->{$addr} = $ray_port;
        push @$ports,$ray_port;
    }
	elsif (0)
	{
		display_hash(0,0,"Duplicate port_addr($addr)",$rec);
		display_hash(0,1,"prev",$found);
	}
}


sub _decode_header
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
    # and $RAYDP_PORT.
	#
	# Returns 1 on the first time an interesting message is found,
	# in which case the app can choose to monitor the raw bytes for comparison,
	# or 0 for known repetitive or previously decoded mesages.
{
    my ($packet) = @_;
    my $raw = $packet->{raw_data};
    my $len = length($raw);
    display($dbg_raydp,0,"decodeRAYDP($len)");

    # packets we can skip merely based on the raw contents

    if ($raw eq $RAYDP_ALIVE_PACKET)
    {
        print packetWireHeader($packet,0)."RAYDP_ALIVE_PACKET\n"
            if $MONITOR_RAYDP_ALIVE;
        return 0;
    }
    if ($raw eq $RAYDP_WAKEUP_PACKET)
    {
        print packetWireHeader($packet,0)."RAYDP_WAKEUP_PACKET: ".unpack("H*",$raw)."\n";
        return 0;
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
    my $found = $devices->{$key};
    if ($found && $rec->{raw} ne $found->{raw})
    {
		setConsoleColor($DISPLAY_COLOR_ERROR);
		print packetWireHeader($packet,0)."SKIPPING CHANGED RAYDP_PACKET len($len) func($func) id($id)!!\n";
		print "old=".unpack("H*",$found->{raw})."\n";
		print "new=".unpack("H*",$rec->{raw})."\n";
		setConsoleColor();
    }

    # set the count and return if the RAYDP packet has already been parsed

    my $count = $found ? $found->{count} : 0;
    $count++;
    $rec->{count} = $count;
    return 0 if $found;

    # PARSE AND ADD A NEW RAYDP RECORD

    my $text2 = '';
    my $text1 = sprintf("len(%d) type(%d) id(%s) func(%2d) x(%s,%s)", $len, $type, $id, $func, $x1, $x2);
    my $payload = $len > 20 ? substr($raw, 5 * 4) : '';

    if ($len == 28)
    {
        $text2 = _decode_header(0,$rec, $payload, qw(ip port));
        _addPort($rec,'tcp',$rec->{ip},$rec->{port});
    }
    elsif ($len == 36)
    {
        $text2 = _decode_header(0,$rec, $payload, qw(mcast_ip mcast_port tcp_ip tcp_port));
        _addPort($rec,'udp',$rec->{mcast_ip},$rec->{mcast_port});
        _addPort($rec,'tcp',$rec->{tcp_ip},$rec->{tcp_port});
    }
    elsif ($len == 37)
    {
        $text2 = _decode_header(1, $rec, $payload, qw(mcast_ip mcast_port tcp_ip tcp_port));
        _addPort($rec,'udp',$rec->{mcast_ip},$rec->{mcast_port});
        _addPort($rec,'tcp',$rec->{tcp_ip},$rec->{tcp_port});
    }
    elsif ($len == 40)
    {
        $text2 = _decode_header(0,$rec, $payload, qw(tcp_ip tcp_port1 tcp_port2 mcast_ip mcast_port));
        _addPort($rec,'udp',$rec->{mcast_ip},$rec->{mcast_port});
        _addPort($rec,'tcp',$rec->{tcp_ip},$rec->{tcp_port1});
        _addPort($rec,'tcp',$rec->{tcp_ip},$rec->{tcp_port2});
    }

    # packets that we skip but display

    else
	{
		my $matched = '';
		for my $match (@$KNOWN_UNDECODED)
		{
			if ($raw eq $match)
			{
				$matched = "KNOWN UNDECODED PACKET($len)";
				last;
			}
		}
		if ($matched)
		{
			$text1 = $matched;
		}
		else
		{
			if (!$duplicate_unknown->{$raw})
			{
				$duplicate_unknown->{$raw} = 1;
				setConsoleColor($DISPLAY_COLOR_WARNING);
				print packetWireHeader($packet,0)."UNKNOWN PACKET($len) ".unpack("H*",$rec->{raw})."\n";
				setConsoleColor();
				return 1;
			}
			return 0;
		}
    }

    setConsoleColor($DISPLAY_COLOR_LOG);
    print packetWireHeader($packet,0)."$text1 $text2\n";
    setConsoleColor();
    $devices->{$key} = $rec;
	return 1;
}



1;