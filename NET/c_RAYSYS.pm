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
#   parties that handle the data.  That will typically include,
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
use Socket;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use a_defs;
use a_utils;
use b_sock;
use a_parser;
use base qw(b_sock a_parser);

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



#--------------------------------------------------------------
# ctor
#-------------------------------------------------------------
# RAYSYS is multiply inherited from b_sock and b_parser,
# is never destroyed, and does not use the init method.
# Instead it knowingly sets up the required b_sock and a_parser
# members.


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

	my $this = shared_clone($RAYSYS_DEFAULTS{$RAYSYS_PORT});
	mergeHash($this, shared_clone({
		name 			=> $RAYSYS_NAME,
		proto			=> 'mcast',
		service_id		=> $RAYSYS_SID,
		local_ip		=> $LOCAL_IP,
		ip   			=> $RAYSYS_IP,
		port 			=> $RAYSYS_PORT,

		DELAY_START		=> $DELAY_START,

		devices 		=> shared_clone({}),	# by friendly name; never culled
		ports_by_addr 	=> shared_clone({}),	# by ip:port addr; culled after $SERVICE_PORT_TIMEOUT if not re-advertised
		unknown			=> shared_clone({}),	# unknown messages, for debugging, none at this time, only shown once

		implemented_services => shared_clone({}),
			# a separate hash by NAME of implemented services that
			# have been discovered, and created, but not yet destroyed

		# AS AN A_PARSER, on the known shark device_id 'aaaaaaaa'

		device_id		=> $KNOWN_DEVICES{$SHARK_DEVICE_ID},
		parent			=> $this,				# uses self as the parent of the parser
		parser			=> $this,				# uses self AS the parser
		# 	mon_in			=> 0,
		# 	mon_out			=> 0,
		# 	in_color		=> 0,
		# 	out_color		=> 0,

	}));

	bless $this,$class;
	$this->init();
	$raysys = $this;

	$this->addServicePort({
		proto => 'tcp',
		service_id => -1,
		device_id  => $KNOWN_DEVICES{'37a681b2'}, # 'E80 #1'
		},$E80_1_IP,$HIDDEN_PORT1,1);
	
	return $this;
}



#------------------------------------
# client API
#------------------------------------

sub getRaysys
{
	return $raysys;
}


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


sub findServicePortByName
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


sub connectServicePort
	# Called by winRAYSYS directly when the spawn checkbox is
	# checked or unchecked.
{
	my ($this,$addr,$checked) = @_;
	my $service_port = $this->{ports_by_addr}->{$addr};
	return error("Could not find service_port($addr)") if !$service_port;
	my $name = $service_port->{name};
	warning($dbg_raysys,0,"connectServicePort($addr=$name,$checked)");

	# If the service_port is IMPLEMENTED, that means that the command
	# is actually 'connectServicePortByName() and we call connect()

	if ($service_port->{implemented})
	{
		$service_port = $this->{implemented_services}->{$name};
		error("no implemented_services($name)") if !$service_port;
		$service_port->connect($checked);
		return;
	}

	my $proto = $service_port->{proto};
	return error("$name is already created") if $checked && $service_port->{created};
	return error("$name is not created") if !$checked && !$service_port->{created};
	return error("Don't know how to spawn $proto->{proto} for $name")
		if $proto ne 'udp' && $proto ne 'tcp' && $proto ne 'mcast';
		
	if ($checked)
	{
		$service_port->{EXIT_ON_CLOSE} = 1;
		$service_port->{local_port} = $LOCAL_UDP_PORT_BASE + $service_port->{service_id}
			if $proto eq 'udp';

		bless $service_port, 'b_sock';
		$service_port->init();

		$service_port->{show_raw_input} = 1;
		$service_port->{show_raw_output} = 1;
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

sub addServicePort
{
    my ($this,$rec,$ip,$port,$no_delete) = @_;
    my $addr = "$ip:$port";
    my $found = $this->{ports_by_addr}->{$addr};
	display_hash($dbg_raysys+1,0,"addServicePort($addr)",$rec);

    if ($found)
	{
		$found->{alive_time} = time();
		return 0;	# not new
	}

	my $def = $RAYSYS_DEFAULTS{$port};
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

	# HUH?!?!?  More weird Perl behavior when RAYSYS_DEFAULTS was shared
	# Somehow the RAYSYS_DEFAULTS shared record was getting the fields
	# from the SERIVCE_PORT, which is *supposed* to be a shared_clone
	# of the RAYSYS_DEFAULTS.  I *thought* shared_clone created a DEEP
	# clone, re-instantiating all the sub shared_references, but I
	# changed back to a non-shared version as of this writing
	
	display_hash($dbg_raysys+1,1,"adding ServicePort($ip:$port) def",$def);
	my $service_port = shared_clone($def);
	mergeHash($service_port,$rec);
	display_hash($dbg_raysys+2,1,"after merge",$service_port);

	$service_port->{ip}			= $ip;
	$service_port->{port}		= $port;
	$service_port->{addr}		= $addr;
	$service_port->{alive_time} = time();
	$service_port->{no_delete}	= $no_delete if $no_delete;
	
	$this->{ports_by_addr}->{$addr} = $service_port;


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
	warning(0,0,"STARTING IMPLEMENTED SERVICE $class auto_start($service_port->{auto_connect}) populate($service_port->{auto_populate})");
    bless $service_port, $class;
	$this->{implemented_services}->{$name} = $service_port;
	
    $service_port->init();

	# if auto_start give the E80 a chance to open the port after advertising it
	# otherwise set $SHUTDOWN_DONE to prevent it from connecting
	
	$service_port->{auto_connect} ?
		$service_port->{DELAY_START} = 4 :
		$service_port->{shutdown} = $SHUTDOWN_DONE;
		
    $service_port->start();
	b_sock::incVersion();	# addition or deletion of implemented services causes h_server to send a new page

}




#-------------------------------------------------------
# A_PARSER parsePacket() OVERRIDE !!!
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
			my $def = $RAYSYS_DEFAULTS{$value};
			my $proto = $def ? $def->{proto} : '';
			$text .= "$field($value)='$proto' ";
		}
		else
		{
			$text .= "$field($value) ";
		}
    }
	return $text;
}



sub parsePacket
	# a_parser override
	# Always returns undef so that b_sock does not queue replies.
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
    my ($this,$packet) = @_;
    my $raw = $packet->{payload};
    my $len = length($raw);
    display($dbg_raysys+1,0,"decodeRAYSYS($len) raw=".unpack('H*',$raw));
	lock($raysys);

    # packets we can skip merely based on the raw contents

	if ($raw eq $RAYSYS_WAKEUP_PACKET)
    {
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
 		my $version = unpack('V',substr($raw,12,4))/100;

		# The ip is obvious, the ports are maybe, the service id
		# and name are pur conjecture. One time I saw something that
		# looked like a legitimate name for the E80, but I now think it,
		# and quite possibly the ports, are buffer junk.

		my $ip = inet_ntoa(pack('N', unpack('V',substr($raw,16,4))));
		my $listen_port = unpack('v',substr($raw,20,2));
		my $svc_port = unpack('v',substr($raw,22,2));

		my $name_len = unpack('V',substr($raw,24,4));
			# includes a dword for the service id?
		my $service_id = unpack('V',substr($raw,28,4));
		my $name = $name_len ? unpack('a*',substr($raw,32,($name_len-2)*2)) : '';
		$name =~ s/\x00//g;

		my $is_master = $len == 56 ? unpack('v',substr($raw,54,2)) : -1;
		my $role =
			$is_master == -1 ? "UNDEFINED" :
			$is_master ? "MASTER" : "SLAVE";

		if (0)	# when I saw, and was trying to probe "RML Monito"
		{
			$this->addServicePort({
				device_id => $device_id,
				service_id => $service_id,
				},
				$ip,$svc_port) if $svc_port;
		}
		
		my $found_device = $this->{devices}->{$device_id};
		if ($found_device)
		{
			$found_device->{alive_time} = time();
			return undef;
		}

		$this->{devices}->{$device_id} = shared_clone({
			alive_time	=> time(),
			device_id 	=> $device_id,
			version		=> $version,
			listen_port	=> $listen_port,
			ip 			=> $ip,
			svc_port	=> $svc_port,
			is_master	=> $is_master,
			role		=> $role, });

		if ($dbg_raysys <= 0)
		{
			my $text = "RAYSYS IDENT type($type) device_id($device_id) role($role) vers($version) ip($ip)";
			$text .= " name($name) sid($service_id) svc($svc_port) listen($listen_port)" if $svc_port;

			setConsoleColor($DISPLAY_COLOR_WARNING);
			print $text."\n";
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
		my $header = 'RAYSYS '; 
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
# b_sock overrides
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
		next if $service_port->{no_delete};
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