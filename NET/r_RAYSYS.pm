#---------------------------------------------
# r_RAYSYS.pm
#---------------------------------------------
# RAYSYS is the heart of RAYNET (Seatalk HS ethernet)
# It is named RAYSYS because it is listed as "System" in the
# E80 ethernet diagnostics Services dialog.
#
# RAYSYS is, essentially, a service discovery protocol, like SSDP,
# that broadcasts the Services (functions) available via RAYNET,
# over a known udp multicast address.
#
#		224.0.0.1:5800
#
# This package parses those multicast messages into a list of
# available Services with given ip:port addresses for each Service,
# as well as doing quite a bit of other stuff.
#
# Each Service runs on a Device, some of which are actual physical E80's,
# and others which are virtual devices, like a running RNS program.
# Each Device has an 'id', some of which are known physical E80's,
# and others that are made up by me, or by RNS.
#
# Services may advertise a UDP address, a TCP address, or both.
#
# In all cases, the IP:PORT of the particular addresss
# can also be used to uniquely identify the Service, and the
# specific the internet protocol (udp/tcp), as well as defining
# the Protocol used to decode and create the packets sent and
# received to/from the Service on that specific ip:port and
# internet protocol.
#
# Therefore the list of Services is actually kept as a list of records.
# and a hash of pointers to those records by {ip:port}. Each record
# includes the Service func number, and there is no record for a Service
# itself, per-se.
#
# I call these RayPorts,  Each rayport has a 'name'.
#
# I have generally tried to use names that correlate to those E80 ethernet
# diagnostics Services dialog, but a few I invented to be more catchy and
# easier to type, like FILESYS instead of CFCard.
#
#------------------------------------------------------------------------
#
# This code is not perfect. RAYNET presents a large number of Services,
# only some of which I have 'solved' and been able to use with the E80,
# some that I have identified, but have never seen packets for because
# they are related to specific hardware that I don't have, and some of
# which, to date, remain unidentified and uncorrelated with the Services
# shown in the E80 ethernet diagnostics.
#
# Nonetheless, this package contains my best overview of the entire
# RAYNET set of Services and Protocols.
#
# Each Service has a func() number associated with it, and as mentioned
# above, may have one or more udp or tcp addresses associated with it.
# Some (Most) Services are only advertised by the Master E80 in the system.
# A few, like FILESYS (read-only accesses the CF Card) are also advertised by
# the Slave, and others are advertised by RNS when it runs, apparently as
# a second pseudo-master.
#
# Finally, this package is overloaded with program and UI support,
# for monitoring and probing the services, and I have added 'fake'
# rayports to take advantage of the UI to control and probe specific
# ip:ports that are not, per-se, advertised by RAYSYS.
#
#---------------------------------------------------------------------
# TODO:
#
# 	I have not yet added the known 52 byte packet for RADAR
#		The structure of the RAYSYS packet, as well as detailed
#		knowledge of the RADAR protocol can be found in
#		RMRadar_pi/RMControl.cpp
#
#	There is one 56 byte long RAYSYS packet that does not match
#		the structure of all the others (does not start with
#		type,id,func), that has a leading 01 byte, that I have
#		not figured out yet.
#
#		01000000 00000000 37a681b2 39020000 [36f1000a] 0023ad01 5cd87304 01000000
#		00000000 37a681b2 39220000 [36f1000a] 0033cc33 02000100
#
#		[36f1000a] == 10.0.241.54, the ip address of my master E80


package r_RAYSYS;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Socket;
use IO::Select;
use Pub::Utils;
use r_utils;
use rayports;



my $dbg_raydp = 1;



BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		initRAYSYS
        decodeRAYSYS

        findRayPort
        getRayPorts
		findRayPortByName
    );
}



# IDENT PACKETS START with 01
#
#                                ---ID--- VERS     ---IP---                                                                       MASTER v
#	E80 #1 M - 01000000 00000000 37a681b2 39020000 36f1000a 0033cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 02000100
#	E80 #1 S - 01000000 00000000 37ad80b2 39020000 53f0000a 0033cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 02000000
#
#	E80 #1 S - 01000000 00000000 37a681b2 39020000 36f1000a 0033cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 02000000
#	E80 #2 M - 01000000 00000000 37ad80b2 39020000 53f0000a 0033cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 02000100
#   RNS      - 01000000 03000000 ffffffff 76020000 018e7680 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 0000


my $devices:shared = shared_clone({});
    # a hash of all unique RAYSYS udp descriptor packets by func:id
my $ports = shared_clone([]);
my $ports_by_addr:shared = shared_clone({});
    # a list of all ports in order they're found,
    # and a hash of them by addr (ip:port)
my %unknown:shared;
	# a hash by raw bytes of all unknown messages shown once
my %duplicates:shared;
	# if id:func matches, we will still add the device

	



sub initRAYSYS
{
	display(0,0,"creating default RAYSYS ports");
	# The ip addresses have to be turned into inet ip's,
	# and then unpacked into the numbers that RAYSYS would
	# have given for them.
	_addPort({func => 0, id=>'sys'},
		$RAYDP_IP,
		$RAYDP_PORT);
	_addPort({func => 500,id=>'shark'},
		$LOCAL_IP,
		$RNS_FILESYS_LISTEN_PORT);
	_addPort({func => 501,id=>'shark'},
		$LOCAL_IP,
		$FILESYS_LISTEN_PORT);
}





#------------------------------------
# accesors
#------------------------------------

sub findRayPort
	# This is what r_sniffer uses to filter packets for general display.
	# There can be multiple Ids that are sharing the same ip:port, implying
	# that the port is a mcast port, in which it really doesn't make sense
	# to have multiple lines for them in the UI, though we still want to
	# know the ip's of all the ones that have the same mcast ip:port.
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

sub is_multicast
{
    my ($ip) = @_;
    return 0 if $ip !~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/;
    my ($oct1, $oct2, $oct3, $oct4) = ($1, $2, $3, $4);
    # Multicast range: 224.0.0.0 to 239.255.255.255
    return ($oct1 >= 224 && $oct1 <= 239) ? 1 : 0;
}



sub _addPort
{
    my ($rec,$ip,$port) = @_;
    my $addr = "$ip:$port";
    my $found = $ports_by_addr->{$addr};
	my $proto = '';
    if (!$found)
    {
		my $def = $RAYPORT_DEFAULTS->{$port};

		if (!$def)
		{
			error("NO DEFINITION FOR RAYSYS PORT($port)");
			$def = {
				name=>'unknown',
				proto=>'',
				mon_from=>1,
				mon_to=>1,
				multi=>1,
				color=>0 };
		}


		$proto = $def->{proto};

		# warning(0,0,"adding port $proto $addr in($def->{mon_from}) out($def->{mon_to}) color($def->{color}) multi($def->{multi})");

		my $port_counter = @$ports;
		$proto = 'mcast' if is_multicast($ip);
        my $ray_port = shared_clone({
			num		=> $port_counter,
            proto   => $def->{proto},
            ip      => $ip,
            port    => $port,
            addr    => $addr,
            func    => $rec->{func},    # the function is??
			id      => raydpIdIfKnown($rec->{id}),

 			name    => $def->{name},
            mon_from => $def->{mon_from} || 0,
            mon_to => $def->{mon_to} || 0,
            color => $def->{color} || 0,
			multi => $def->{multi} || 0,
        });
        $ports_by_addr->{$addr} = $ray_port;
        push @$ports,$ray_port;
    }

	# give an error if I havent previously
	# recognized the ip:port as multicast

	elsif ($found->{proto} ne 'mcast')
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
            $rec->{$field} = $value;
        }

		if ($field =~ /^port/)	# for non-multicast ports, show my guess as to the internet protocol
		{
			my $def = $RAYPORT_DEFAULTS->{$value};
			my $guess = $def ? $def->{proto} : '';

			$text .= "$field($value)='$guess' ";
		}
		else
		{
			$text .= "$field($value) ";
		}
    }
	return $text;
}



sub decodeRAYSYS
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
    display($dbg_raydp,0,"decodeRAYSYS($len)");

    # packets we can skip merely based on the raw contents

	if ($raw eq $RAYDP_WAKEUP_PACKET)
    {
        print packetWireHeader($packet,0)."RAYDP_WAKEUP_PACKET: ".unpack("H*",$raw)."\n";
        return 0;
    }

    # parse the RAYSYS packet for header fields

	my $src ="$packet->{src_ip}:$packet->{src_port}";
    my ($type, $id, $func, $x1, $x2) = unpack('VH8VH8H8', $raw);
	$id = raydpIdIfKnown($id);
    my $rec = shared_clone({
		src   => $src,
        raw   => $raw,
        len   => $len,
        type  => $type,
        id    => $id,
        func  => $func,
        x1    => $x1,
        x2    => $x2,
    });

	# we will only continue to parse if the the func:id has
	# not been previously found, but we want to see
	# duplicate or changed advertisements of the same function
	# one time

    my $key = "$func.$id";
    my $found = $devices->{$key};
    if ($found && (
		$rec->{src} ne $src ||
		$rec->{raw} ne $found->{raw}))
    {
		my $what_diff = '';
		$what_diff .= 'SRC ' if $rec->{src} ne $src;
		$what_diff .= 'RAW ' if $rec->{raw} ne $found->{raw};
		my $src_msg = '';
		$src_msg = "old_src($rec->{src}) new_src($src) " if $rec->{src} ne $src;

		my $dup_key = "$func.$id.$src";
		my $found_dup = $duplicates{$dup_key};

		setConsoleColor($DISPLAY_COLOR_ERROR);
		my $header = packetWireHeader($packet,0);
		my $pad = pad('',length($header));
		print $header."RAYDP $what_diff CHANGED PACKET len($len) func($func) id($id) $src_msg!!\n";
		if ($rec->{raw} ne $found->{raw})
		{
			print parse_dwords($pad."old=",$rec->{raw},1);
			print parse_dwords($pad."new=",$found->{raw},1);
			$found->{raw} = $rec->{raw};
		}
		setConsoleColor();
    }

    # set the count and return if the RAYSYS packet has already been parsed

    my $count = $found ? $found->{count} : 0;
    $count++;
    $rec->{count} = $count;
    return 0 if $found;

    # PARSE AND ADD A NEW RAYSYS RECORD

    my $text2 = '';

	my $func_name = $KNOWN_FUNCS{$func} || 'func';
	my $func_str = pad("$func_name($func)",12);

	my $id_str = pad($id,8);
    my $text1 = "$len:$type $id_str $func_str x($x1,$x2)";
    my $payload = $len > 20 ? substr($raw, 5 * 4) : '';

    if ($len == 28)
    {
        $text2 = _decode_header(0,$rec, $payload, qw(ip port));
        _addPort($rec,$rec->{ip},$rec->{port});
    }
    elsif ($len == 36)
    {
        $text2 = _decode_header(0,$rec, $payload, qw(mcast_ip mcast_port ip port));
        _addPort($rec,$rec->{mcast_ip},$rec->{mcast_port});
        _addPort($rec,$rec->{ip},$rec->{port});
    }
    elsif ($len == 37)
    {
        $text2 = _decode_header(1, $rec, $payload, qw(mcast_ip mcast_port ip port));
        _addPort($rec,$rec->{mcast_ip},$rec->{mcast_port});
       _addPort($rec,$rec->{ip},$rec->{port});
    }
    elsif ($len == 40)
    {
        $text2 = _decode_header(0,$rec, $payload, qw(ip port1 port2 mcast_ip mcast_port));
        _addPort($rec,$rec->{mcast_ip},$rec->{mcast_port});
        _addPort($rec,$rec->{ip},$rec->{port1});
        _addPort($rec,$rec->{ip},$rec->{port2});
    }

    # unknown packets that show the first time we see them

    else
	{
		return 0 if $unknown{$raw};
		$unknown{$raw} = 1;

		my $name = 'UNKNOWN';
		if (unpack('C',$raw) == 1)	# length($raw) == 56 || length($raw) == 54)
		{
			$name = 'IDENT';
			my $ident_id = raydpIdIfKnown(unpack('H*',substr($raw,8,4)));
			my $version = unpack('v',substr($raw,12,2))/100;
			my $ip = inet_ntoa(pack('N', unpack('V',substr($raw,16,4))));
			my $is_master = $len == 56 ? unpack('v',substr($raw,54,2)) : -1;
			my $role =
				$is_master == -1 ? "UNDEFINED" :
				$is_master ? "MASTER" : "SLAVE";

			$text2 = "id($ident_id) vers($version) ip($ip) role($role)";
		}

		my $header = packetWireHeader($packet,0);
		setConsoleColor($DISPLAY_COLOR_WARNING);
		print $header."$name($len) $text2\n";
		print parse_dwords(pad('',length($header)),$raw,1);
		setConsoleColor();
		return 1;
    }

    setConsoleColor($DISPLAY_COLOR_LOG);
    print packetWireHeader($packet,0)."$text1 $text2\n";
    setConsoleColor();
    $devices->{$key} = $rec;
	return 1;
}




1;