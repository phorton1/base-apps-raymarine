#---------------------------------------------
# c_RAYSYS.pm
#---------------------------------------------
# RAYSYS is the heart of RAYNET (Seatalk HS ethernet)
# It is named RAYSYS because it is listed as "System" in the
# E80 ethernet diagnostics Services dialog.
#
# RAYSYS is, essentially, a service discovery protocol, like SSDP,
# that broadcasts the Services (service_ids) available via RAYNET,
# over a known udp multicast address.
#
#		224.0.0.1:5800
#
# Services may advertise a UDP address, a TCP address, or both.
# This package parses those multicast messages into a list of
# available SERVICE_PORTS with a given (possibly unknown)
# service_id, a known internet protocol, and a specific
# ip:port address.
#
# Each Service runs on a Device.
# Each Device has an 'id'.
# Device id's on my system are known.
# Some service_ids are known.
# Some service_ports are fully implemented.

# This is where it gets complicated, and the crux of the biscuit.
#
# - we want the ability to use r_sniffer to monitor traffic between
#   RNS and the E80 on a service_port basis
# - locally, some service_port are fully implemented, and we want
#   to either start/stop, but not necessarily destroy them automatically
#	when RAYSYS finds them or loses them, or optionally in shark.pm with
#   a waitloop for RAYSYS
# - we generally want the ability to start/stop/destroy not-fully implemented
#	local service_ports, either via constants for intense probing of a given
#	service port, or via the UI.
# - we'd like the ability to define, via constants, or UI, the colors,
#   and level of detail that we wish to see for either RNS or local
#   service ports when monitoring:
#
#		raw_messages
#			always includes a length and {cmd_word}{service_id}
#			where, for udp, the length is the packet length, but
#			for tcp the length is explicit, and there can be
#			a number of messages in the packet
#		message_parsing
#			upto, but not including 'records' within the buffers
#		raw_records
#			the unpacking of records into fields, which, by convention
#			includes a level of detail 0=known data; 1=control_data; 2=unknowns
#		finished records
#			containing the same level of detail
#
# Thats a lot of stuff to cram into a single structure/UI
# I think there are now two shark windows.
#
#	- sniffer, which can monitor RNS and/or local service_ports
#	  without opening actual sockets
#	- raysys, which can only monitor local service ports that
#	  are actually opened
#
# One way or the other, the b_sock is just an extension to a service_port
# that adds a bunch of fields.  In all cases, henceforth, RAYSYS itself
# is only run as a real, local service, and not sniffed.


package c_RAYSYS;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Socket;
use IO::Select;
use Pub::Utils;
use a_defs;
use a_utils;
use base qw(b_sock);

my $dbg_raysys = 0;

my $self:shared;

my $DELAY_START = 3;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		findServicePort
		getServicePorts
		findServicePortByName

	);
}

my $CMD_AD		= 0;
my $CMD_IDENT	= 1;

my %CMD_NAME = (
	$CMD_AD 	=> 'ad',
	$CMD_IDENT => 'IDENT',
);

#--------------------------------------------------
# ctor
#--------------------------------------------------


sub new
	# We don't keep track of Services, per-se, but rather of
	# 	the individual service_ports that are advertised, and
	# 	we just call them 'ports' in our implementation.
	# The list of devices is by $device_id (friendly name if known)
	# Unknown is a hash by raw bytes of all unknown messages shown once
{
	my ($class) = @_;
	display($dbg_raysys,0,"c_RAYSYS new()");
	my $this = shared_clone({	# $class->SUPER::new({
		name 			=> $RAYSYS_NAME,
		proto			=> 'mcast',
		service_id		=> $RAYSYS_SID,
		ip   			=> $RAYSYS_IP,
		port 			=> $RAYSYS_PORT,

		DELAY_START		=> $DELAY_START,

		show_raw_input 	=> 0,
		show_raw_output => 0,

		devices 		=> shared_clone({}),
		device_services => shared_clone({}),
		ports 			=> shared_clone([]),
		ports_by_addr 	=> shared_clone({}),
		ports_by_name 	=> shared_clone({}),
		unknown			=> shared_clone({}),
	});

	bless $this,$class;
	$this->init();
	$self = $this;
	return $this;
}



#------------------------------------
# client API
#------------------------------------


sub findServicePort
	# This is what s_sniffer uses to filter packets for general display.
	# There can be multiple Ids that are sharing the same ip:port, implying
	# that the port is a mcast port, in which it really doesn't make sense
	# to have multiple lines for them in the UI, though we still want to
	# know the ip's of all the ones that have the same mcast ip:port.
{
    my ($ip,$port) = @_;
	return undef if !$self;
    my $addr = "$ip:$port";
    return $self->{ports_by_addr}->{$addr};
}


sub getServicePorts
{
	return [] if !$self;
    return $self->{ports};
}

sub findServicePortByName
{
	my ($name,$quiet) = @_;
	my $service_port = $self ? $self->{ports_by_name}->{$name} : undef;
	error("Could not findServicePortByName($name)") if !$service_port && !$quiet;
	return $service_port;
}



#-----------------------------------
# private API
#-----------------------------------

sub is_multicast
{
    my ($ip) = @_;
    return 0 if $ip !~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/;
    my ($oct1, $oct2, $oct3, $oct4) = ($1, $2, $3, $4);
    # Multicast range: 224.0.0.0 to 239.255.255.255
    return ($oct1 >= 224 && $oct1 <= 239) ? 1 : 0;
}



sub addServicePort
{
    my ($this,$rec,$ip,$port) = @_;
    my $addr = "$ip:$port";
    my $found = $this->{ports_by_addr}->{$addr};
	display_hash($dbg_raysys+1,0,"addServicePort($addr)",$rec);
	
    if (!$found)
    {
		my $def = $SERVICE_PORT_DEFS{$port};

		if (!$def)
		{
			error("NO DEFINITION FOR RAYSYS PORT($port)");
			$def = {
				sid		=> -2,
				name	=> 'unknown',
				proto	=> '',
				# mon_from=>1,
				# mon_to=>1,
				# multi=>1,
				# color=>0,
			};
		}

		display_hash($dbg_raysys+2,1,"def",$def);
		my $port_counter = @{$this->{ports}};
        my $service_port = shared_clone($def);
		mergeHash($service_port,$rec);
		display_hash($dbg_raysys+2,1,"after merge",$service_port);

		$service_port->{num}	= $port_counter;
		$service_port->{ip}		= $ip;
		$service_port->{port}	= $port;
		$service_port->{addr}	= $addr;

		# mon_from => $def->{mon_from} || 0,
		# mon_to 	=> $def->{mon_to} || 0,
		# color 	=> $def->{color} || 0,
		# multi 	=> $def->{multi} || 0,

		push @{$this->{ports}},$service_port;
        $this->{ports_by_addr}->{$addr} = $service_port;

			# only take the first named service (by name)

		#=======================================================
		# spawn a real service
		#=======================================================
		# This is where it gets intereting (and messes up the display).
		# If the $def has implemented=>1, we will attempt to create, and
		# start, the "real" service for the given function

		if ($AUTO_START_IMPLEMENTED_SERVICES &&
			$def->{implemented} &&
			!$this->{ports_by_name}->{$service_port->{name}})
		{
			# We only allow one instance, by name, of an implemented service_port.
			# This *may* be short signted.
			# The only multiple instance service_port at this time is udp FILESYS,
			# and, at this time, udp service_ports work by opening a (single)
			# listener socket, at a known port number, and sending their commands,
			# which include that port number, via a_utils::sendUDPPacket()

			promote_to_real_service($service_port);
		}

		# add the name AFTER spawning the service
		$this->{ports_by_name}->{$service_port->{name}} ||= $service_port;

    }

	# give an error if I havent previously
	# recognized the ip:port as multicast

	elsif ($found->{proto} ne 'mcast')
	{
		display_hash(0,0,"Duplicate port_addr($addr)",$rec);
		display_hash(0,1,"prev",$found);
	}
}


sub promote_to_real_service
{
    my ($service_port) = @_;
    my $class = "d_$service_port->{name}";
	warning(0,0,"SPAWNING REAL $class !!!");
    bless $service_port, $class;
    $service_port->init();
    $service_port->start();
}



#-------------------------------------------------------
# packet handling
#-------------------------------------------------------


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
			my $def = $SERVICE_PORT_DEFS{$value};
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



sub handlePacket
	# Returns 1 on the first time an interesting message is found,
	# 	or 0 for known repetitive or previously decoded mesages,
	#	noting that I have not yet established a use for handlePacket's
	#	return value in b_sock.
	#
	# Note that with a "typical" command processor, these wouuld
	# 	all come in as    cmd_word(0) service_id(0), except IDENT
	#	which comes in as cmd_word(1) service_id(0)
	#
	# I still haven't figured out
	#	x1(01001e00) always for me so far
	# 	x2(04080800) except
	#          ^ word length of what follows this dword (alternative to using packet len for decoding)
	#        ^ some bit flag but does NOT correlate to contents
	#      ^ byte looks like a creation order or some other index, except for a which appears special
	#
	# So, as of the new b_sock implementation, the length is still the best indicator of how
	# to decode these packets, and I am not using a command processor for RAYSYS
{
    my ($this,$raw) = @_;
    #my $raw = $packet->{raw_data};
    my $len = length($raw);
    display($dbg_raysys+1,0,"decodeRAYSYS($len) raw=".unpack('H*',$raw));

    # packets we can skip merely based on the raw contents

	if ($raw eq $RAYSYS_WAKEUP_PACKET)
    {
        # print packetWireHeader($packet,0)."RAYDP_WAKEUP_PACKET: ".unpack("H*",$raw)."\n";
		print "RAYDP_WAKEUP_PACKET: ".unpack("H*",$raw)."\n";
        return 0;
    }

    # parse the RAYSYS packet for header fields

    my ($cmd_word, $raysys_service_id, $device_id, $service_id, $x1, $x2) = unpack('vvH8VH8H8', $raw);
	$device_id = $KNOWN_DEVICES{$device_id} || $device_id;
    my $rec = shared_clone({
        # raw   		=> $raw,
        # len   		=> $len,
        # type  		=> $type,
        device_id   => $device_id,
        service_id  => $service_id,
        x1    		=> $x1,
        x2    		=> $x2,
    });

    display_hash($dbg_raysys+1,0,"decodeRAYSYS($len)",$rec);

	# handle IDENT messages first

	if ($cmd_word == $CMD_IDENT)
	{
		my $type = unpack('V',substr($raw,4,4));
		$type = $DEVICE_TYPE{$type} || "$type=unknown";

		$device_id = unpack('H*',substr($raw,8,4));
		$device_id = $KNOWN_DEVICES{$device_id} || $device_id;
		return if $this->{devices}->{$device_id};

 		my $version = unpack('v',substr($raw,12,2))/100;
		my $ip = inet_ntoa(pack('N', unpack('V',substr($raw,16,4))));
		my $is_master = $len == 56 ? unpack('v',substr($raw,54,2)) : -1;
		my $role =
			$is_master == -1 ? "UNDEFINED" :
			$is_master ? "MASTER" : "SLAVE";

		$this->{devices}->{$device_id} = shared_clone({
			device_id => $device_id,
			version		=> $version,
			ip 			=> $ip,
			is_master	=> $is_master,
			role		=> $role, });

		if ($dbg_raysys <= 0)
		{
			setConsoleColor($DISPLAY_COLOR_WARNING);
			print "RAYSYS IDENT type($type) device_id($device_id) vers($version) ip($ip) role($role)\n";
			setConsoleColor();
		}
		return;
	}

    # set the count and return if the device_service packet has already been parsed

    my $device_service = "$device_id.$service_id";
    my $found = $this->{device_services}->{$device_service};
    my $count = $found ? $found->{count} : 0;
    $count++;
    $rec->{count} = $count;
    return 0 if $found;

    # PARSE AND ADD A NEW device_service and set of service_port records

    my $text2 = '';

	my $service_id_name = $KNOWN_SERVICES{$service_id} || "service_id";
	my $service_id_string = pad("$service_id_name($service_id)",14);

	my $id_str = pad($device_id,8);
	my $cmd_name = $CMD_NAME{$cmd_word} || 'unknown command';
    my $text1 = "len($len) $id_str $service_id_string x($x1,$x2)";
    my $payload = $len > 20 ? substr($raw, 5 * 4) : '';

    if ($len == 28)
    {
        $text2 = _decode_header(0,$rec, $payload, qw(ip port));
        $this->addServicePort($rec,$rec->{ip},$rec->{port});
    }
    elsif ($len == 36)
    {
        $text2 = _decode_header(0,$rec, $payload, qw(mcast_ip mcast_port ip port));
        $this->addServicePort($rec,$rec->{mcast_ip},$rec->{mcast_port});
        $this->addServicePort($rec,$rec->{ip},$rec->{port});
    }
    elsif ($len == 37)
    {
        $text2 = _decode_header(1, $rec, $payload, qw(mcast_ip mcast_port ip port));
        $this->addServicePort($rec,$rec->{mcast_ip},$rec->{mcast_port});
        $this->addServicePort($rec,$rec->{ip},$rec->{port});
    }
    elsif ($len == 40)
    {
        $text2 = _decode_header(0,$rec, $payload, qw(ip port1 port2 mcast_ip mcast_port));
        $this->addServicePort($rec,$rec->{mcast_ip},$rec->{mcast_port});
        $this->addServicePort($rec,$rec->{ip},$rec->{port1});
        $this->addServicePort($rec,$rec->{ip},$rec->{port2});
    }

    # UNKNOWN packets that show the first time we see them

    else
	{
		return 0 if $this->{unknown}->{$raw};
		$this->{unknown}->{$raw} = 1;

		my $name = 'UNKNOWN';
		my $header = 'RAYSYS '; # packetWireHeader($packet,0);
		setConsoleColor($DISPLAY_COLOR_WARNING);
		print $header."$name($len) $text2\n";
		print parse_dwords(pad('',length($header)),$raw,1);
		setConsoleColor();
		return 1;
    }

	# finished. Register the new device_service and show its facts

	if ($dbg_raysys <= 0)
	{
		setConsoleColor($DISPLAY_COLOR_LOG);
		print "RAYSYS $text1 $text2\n";
		setConsoleColor();
	}
	$this->{device_services}->{$device_service} = $rec;
	return 1;
}


sub onStartSocketThread
{
	my ($this) = @_;
	display($dbg_raysys,0,"RAYSYS onStartSocketThread()");
	wakeup_e80();
		# Must be called, perhaps because MSWindows,
		# before attempting to open the RAYSYS multicast socket
}


1;