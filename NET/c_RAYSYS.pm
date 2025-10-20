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
# 		Each Device has an 'id'.
# 		Device id's on my system are known.
#		We keep, but never prune, a list of online Devices
# Some service_ids are known.
# Some service_ports are fully implemented.

# $AUTO_START_IMPLEMENTED_SERVICES
#
#	- Locally, some service_port are fully implemented, and, based on
#	  $AUTO_START_IMPLEMENTED_SERVICES we 'promote' and start() them
#     upon discovery.
#   - Implemented service ports are promoted with EXIT_ON_CLOSE=0,
#     and the ability to attempt to reconnect, with the idea that they are
#     resilient to read/write errors with the socket (i.e. bad commands, etc,
#     that might cause the E80 to close the socket on its side.
#   - a separate hash of {implemented_services} is maintained, and the
#     findImplementedService() is used by UI code to determine if the
#     implemented service_port is up (exists)
#
# SPAWNING UN-IMPLEMENTED SERVICE_PORTS
#
# 	- we support the ability to start/promote and stop/destroy un-implemented
#	  local service_ports, via the winRAYSYS UI.
#	- These 'spawned' sockets are promoted with EXIT_ON_CLOSE=1,
#	  and go away automagically if there is a problem reading/writing
#     to the socket.
#
# AUTOMATIC DESTRUCTION OF STALE SERVICE_PORTS
#
#   - We maintain a service port in the absence of an advertisement for
#     $SERVICE_PORT_TIMEOUT seconds, after which we remove it from the
#	  hash of ports_by_addr, and it effectively disappears from the system
#   - Promoted service_ports (that have 'become' b_socks), are generally
#     destroyed, their sockets closed, and their threads exited, upon
#     destruction.
#   - implemented_services are only destroyed when the last INSTANCE
#     of a service_port matching that name goes away. This allows,
#     for exmple, c_FILESYS and winFILESYS to have one implemented
#     service_port that can deal with multiple destination udp
#     E80's that advertise a FILESERVICE.
#
# LOCKING($this)
#
#   It has been demonstrated that, for thread safety between the
#   wxPerl UI and these implementation classes, starting with c_RAYSYS
#   itself, that (a) everyone should "use" threads and threads::shared,
#   and (b) access to the service_port shared variables must be protected
#   by calling lock($this) (or lock($raysys) or whatever) by the various
#   parties that handle the data.  That will typically include handlePacket(),
#   handleCommand(), and/or onIdle() in these base classes, and/or the
#   onIdle() or other methods that access the members in the wxPerl UI.
#
# TODO
#
# 	- we want the ability to use r_sniffer to monitor traffic between
#     RNS and the E80 on a service_port basis; this is not implemented yet
# 	- we'd like the ability to define, via constants, or UI, the colors,
#     and level of detail that we wish to see for either RNS or local
#     service ports when monitoring:
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

our $raysys:shared;


my $DELAY_START = 3;
my $SERVICE_PORT_TIMEOUT = 3;
	# after this many seconds, RAYSYS will destroy and
	# delete the service port.
	

BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		$raysys
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
	# We don't keep track of Raymarine Services, per-se, but rather of
	# 	the individual service_ports that are advertised, and
	# 	we just call them 'ports' in our implementation.
	# The list of devices is by $device_id (friendly name if known)
	#   and is never culled.
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

		devices 		=> shared_clone({}),	# by friendly name; never culled
		ports_by_addr 	=> shared_clone({}),	# by ip:port addr; culled after $SERVICE_PORT_TIMEOUT if not re-advertised
		unknown			=> shared_clone({}),	# unknown messages, for debugging, none at this time, only shown once

		implemented_services => shared_clone({}),
			# a separate hash by NAME of implemented services that
			# have been discovered, and created, but not yet destroyed
	});

	bless $this,$class;
	$this->init();
	$raysys = $this;
	return $this;
}



#------------------------------------
# client API
#------------------------------------

sub getRaysys
{
	return $raysys;
}


#	sub findServicePort
#		# This is what s_sniffer uses to filter packets for general display.
#		# There can be multiple Ids that are sharing the same ip:port, implying
#		# that the port is a mcast port, in which it really doesn't make sense
#		# to have multiple lines for them in the UI, though we still want to
#		# know the ip's of all the ones that have the same mcast ip:port.
#	{
#	    my ($this,$ip,$port) = @_;
#	    my $addr = "$ip:$port";
#	    return $this->{ports_by_addr}->{$addr};
#	}



sub getServicePortsByAddr
	# returns the whole hash
	# used by winFILESYS to setup its dropdown box
	# of devices it can work with
{
	my ($this) = @_;
	return $this->{ports_by_addr};
}


sub findImplementedService
	# used by much of shark to find the important
	# implemented, and running, service_ports ...
{
	my ($this,$name,$quiet) = @_;
	my $service_port = $this->{implemented_services}->{$name};
	error("Could not findImplementedService($name)") if !$service_port && !$quiet;
	return $service_port;
}


sub spawnServicePortByName
	# Called by winRAYSYS directly when the spawn checkbox is
	# checked or unchecked.
{
	my ($this,$name,$create) = @_;
	warning($dbg_raysys,0,"spawnServicePortByName($name,$create)");
	my $service_port = $this->findServicePortByName($name);
	return if !$service_port;

	my $proto = $service_port->{proto};
	return error("cannot spawn IMPLMENTED service($name)") if $service_port->{implemented};
	return error("$name is already created") if $create && $service_port->{created};
	return error("$name is not created") if !$create && !$service_port->{created};
	return error("Don't know how to spawn $proto->{proto} for $name")
		if $proto ne 'udp' && $proto ne 'tcp' && $proto ne 'mcast';
		
	if ($create)
	{
		$service_port->{EXIT_ON_CLOSE} = 1;
		$service_port->{local_port}	= $service_port->{service_id};
		$service_port->{local_port} += $LOCAL_UDP_PORT_BASE if $proto eq 'udp';
		$service_port->{local_port} += $LOCAL_TCP_PORT_BASE if $proto eq 'tcp';
		bless $service_port, 'b_sock';
		$service_port->init();
		$service_port->start();
	}
	else
	{
		# $service_port->stop();
		$service_port->destroy();
		bless $service_port,'HASH';
	}
}



#-----------------------------------
# private API
#-----------------------------------

#	sub is_multicast
#	{
#	    my ($ip) = @_;
#	    return 0 if $ip !~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/;
#	    my ($oct1, $oct2, $oct3, $oct4) = ($1, $2, $3, $4);
#	    # Multicast range: 224.0.0.0 to 239.255.255.255
#	    return ($oct1 >= 224 && $oct1 <= 239) ? 1 : 0;
#	}


sub findServicePortByName
	# used internally, by c_RAYSYS only.
	# searches the ports_by_addr for a given name and returns
	# it, or undef, with an error on undef if !$quiet
{
	my ($this,$name,$quiet) = @_;
	my $ports_by_addr = $this->{ports_by_addr};
	for my $addr (sort keys %$ports_by_addr)
	{
		my $service_port = $ports_by_addr->{$addr};
		return $service_port if $service_port->{name} eq $name;
	}
	error("Could not findServicePortByName($name)") if !$quiet;
	return undef;
}


sub addServicePort
{
    my ($this,$rec,$ip,$port) = @_;
    my $addr = "$ip:$port";
    my $found = $this->{ports_by_addr}->{$addr};
	display_hash($dbg_raysys+1,0,"addServicePort($addr)",$rec);

    if ($found)
	{

		$found->{alive_time} = time();
		return 0;	# not new
	}

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
	my $service_port = shared_clone($def);
	mergeHash($service_port,$rec);
	display_hash($dbg_raysys+2,1,"after merge",$service_port);

	$service_port->{ip}			= $ip;
	$service_port->{port}		= $port;
	$service_port->{addr}		= $addr;
	$service_port->{alive_time} = time();
	
	# mon_from => $def->{mon_from} || 0,
	# mon_to 	=> $def->{mon_to} || 0,
	# color 	=> $def->{color} || 0,
	# multi 	=> $def->{multi} || 0,

	$this->{ports_by_addr}->{$addr} = $service_port;

		# only take the first named service (by name)

	#=======================================================
	# start implemented services
	#=======================================================
	# If the $def has implemented=>1, we will attempt to create, and
	# start, the "real" service for the given function if it has
	# not already been starrted.
	
	my $name = $service_port->{name};
	if ($AUTO_START_IMPLEMENTED_SERVICES &&
		$service_port->{implemented} &&
		!$this->findImplementedService($name,1))
	{
		$this->startImplementedService($service_port);
	}

	return 1;	# new
}


sub startImplementedService
{
    my ($this,$service_port) = @_;
	my $name = $service_port->{name};
    my $class = "d_$name";
	warning(0,0,"STARTING IMPLEMENTED SERVICE $class !!!");
    bless $service_port, $class;
	$this->{implemented_services}->{$name} = $service_port;
	
    $service_port->init();
	$service_port->{DELAY_START} = 4;
		# give the E80 a chance to open the port after advertising it
    $service_port->start();
	b_sock::incVersion();	# addition or deletion of implemented services causes h_server to send a new page

}




#-------------------------------------------------------
# handlePacket() b_sock override
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
	# Always returns undef so that b_sock does not queue replies.
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
	lock($raysys);

    # packets we can skip merely based on the raw contents

	if ($raw eq $RAYSYS_WAKEUP_PACKET)
    {
        # print packetWireHeader($packet,0)."RAYDP_WAKEUP_PACKET: ".unpack("H*",$raw)."\n";
		print "RAYDP_WAKEUP_PACKET: ".unpack("H*",$raw)."\n";
        return undef;
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
		my $found_device = $this->{devices}->{$device_id};
		if ($found_device)
		{
			$found_device->{alive_time} = time();
			return undef;
		}

 		my $version = unpack('v',substr($raw,12,2))/100;
		my $ip = inet_ntoa(pack('N', unpack('V',substr($raw,16,4))));
		my $is_master = $len == 56 ? unpack('v',substr($raw,54,2)) : -1;
		my $role =
			$is_master == -1 ? "UNDEFINED" :
			$is_master ? "MASTER" : "SLAVE";

		$this->{devices}->{$device_id} = shared_clone({
			alive_time	=> time(),
			device_id 	=> $device_id,
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
		return undef;
	}


    # PARSE the packet and call addServicePort for any service ports found

    my $text2 = '';
	my $is_new = 0;
	
	my $service_id_name = $KNOWN_SERVICES{$service_id} || "service_id";
	my $service_id_string = pad("$service_id_name($service_id)",14);

	my $id_str = pad($device_id,8);
	my $cmd_name = $CMD_NAME{$cmd_word} || 'unknown command';
    my $text1 = "len($len) $id_str $service_id_string x($x1,$x2)";
    my $payload = $len > 20 ? substr($raw, 5 * 4) : '';

    if ($len == 28)
    {
        $text2 = _decode_header(0,$rec, $payload, qw(ip port));
        $is_new = 1 if $this->addServicePort($rec,$rec->{ip},$rec->{port});
    }
    elsif ($len == 36)
    {
        $text2 = _decode_header(0,$rec, $payload, qw(mcast_ip mcast_port ip port));
        $is_new = 1 if $this->addServicePort($rec,$rec->{mcast_ip},$rec->{mcast_port});
        $is_new = 1 if $this->addServicePort($rec,$rec->{ip},$rec->{port});
    }
    elsif ($len == 37)
    {
        $text2 = _decode_header(1, $rec, $payload, qw(mcast_ip mcast_port ip port));
        $is_new = 1 if $this->addServicePort($rec,$rec->{mcast_ip},$rec->{mcast_port});
        $is_new = 1 if $this->addServicePort($rec,$rec->{ip},$rec->{port});
    }
    elsif ($len == 40)
    {
        $text2 = _decode_header(0,$rec, $payload, qw(ip port1 port2 mcast_ip mcast_port));
        $is_new = 1 if $this->addServicePort($rec,$rec->{mcast_ip},$rec->{mcast_port});
        $is_new = 1 if $this->addServicePort($rec,$rec->{ip},$rec->{port1});
        $is_new = 1 if $this->addServicePort($rec,$rec->{ip},$rec->{port2});
    }

    # UNKNOWN packets that show the first time we see them

    else
	{
		return undef if $this->{unknown}->{$raw};
		$this->{unknown}->{$raw} = 1;

		my $name = 'UNKNOWN';
		my $header = 'RAYSYS '; # packetWireHeader($packet,0);
		setConsoleColor($DISPLAY_COLOR_WARNING);
		print $header."$name($len) $text2\n";
		print parse_dwords(pad('',length($header)),$raw,1);
		setConsoleColor();
		return undef;
    }

	# finished. Display new ones

	if ($is_new && $dbg_raysys <= 0)
	{
		setConsoleColor($DISPLAY_COLOR_LOG);
		print "RAYSYS $text1 $text2\n";
		setConsoleColor();
	}

	return undef;
}



#------------------------------------------------
# other virtual b_sock overrides
#------------------------------------------------

sub onStartSocketThread
	# wakeup_e80 must be called, likely because of MSWindows,
	# before attempting to open the RAYSYS multicast socket
{
	my ($this) = @_;
	display($dbg_raysys,0,"RAYSYS onStartSocketThread()");
	wakeup_e80();
}



sub onIdle
	# Delete and possibly destroy() any service ports that have
	# not been advertised in SERVICE_PORT_TIMEOUT seconds
{
	my ($this) = @_;
	lock($raysys);

	my $now = time();
	my $ports_by_addr = $this->{ports_by_addr};
	for my $addr (keys %$ports_by_addr)
	{
		my $service_port = $ports_by_addr->{$addr};
		my $name = $service_port->{name};
		if ($now > $service_port->{alive_time} + $SERVICE_PORT_TIMEOUT)
		{
			warning($dbg_raysys,0,"deleting service_port $addr=$name");
			delete $ports_by_addr->{$addr};

			# We need to destroy() promoted ports that are really going away,
			# but NOT willy-nilly for udp implemented services.
			# We always remove it from {ports_by_addr}, but we only
			# destroy it if its (a) promoted and (b) not an implemented
			# service, or (c) its the last instance of the implemetned
			# service NAME.
			#
			# Thus, the given 'service_port' will disappear, but the
			# 'implemented_service' might not.

			my $implemented = $this->{implemented_services}->{$name};
			my $still_exists = $this->findServicePortByName($name,1);
			my $imp_desc = $implemented ? "$implemented->{addr} $name created("._def($implemented->{created}).")" : 'undef';
			warning($dbg_raysys+1,1,"implemented($imp_desc)  still_exists="._def($still_exists));

			# Note that the implemented service might not be the one triggering the delete
			
			if ($service_port->{created} && !$implemented)
			{
				warning($dbg_raysys,2,"DESTROYING service_port $addr $name");
				$service_port->destroy();
				bless $service_port,'HASH';
				b_sock::incVersion();	# addition or deletion of implemented services causes h_server to send a new page
			}
			elsif ($implemented && !$still_exists)				# its implemented and there are no more instances
			{
				warning($dbg_raysys,2,"DESTROYING IMPLEMENTED SERVICE $implemented->{addr} $name");
				delete $this->{implemented_services}->{$name};
				$implemented->destroy();
				bless $implemented,'HASH';
				b_sock::incVersion();	# addition or deletion of implemented services causes h_server to send a new page
			}
		}
	}
}



1; 