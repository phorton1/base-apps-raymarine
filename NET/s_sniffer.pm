#---------------------------------------------
# s_sniffer.pm
#---------------------------------------------

package s_sniffer;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use a_defs;
use a_parser;

my $dbg_sniff = -1;

# ELIMINATE NON RAYNET TRAFFICE

my $ignore_ip_re = join('|',(
	'224.0.0.251',			# router
	'10.0.241.254',			# router ssdp
	'10.255.255.255',		# windows netbios dnd
	'239.255.255.250', ));	# ssdp

# QUIET OWN SOME PARTICULAR ports

my $ignore_port_re = join('|',(
	'5800',					# RAYSYS
	'5801', ));				# Alarm
# $ignore_port_re = '';



my $sniff_fh;
my $sniff_packet_handler;
my @sniff_fields = (
    'frame.time',
    'ip.src',
    'ip.dst',
    'udp.length',
    'udp.srcport',
    'udp.dstport',
    'udp.payload',
    'tcp.len',
    'tcp.srcport',
    'tcp.dstport',
    'tcp.payload',
);



sub new
{
	my ($class) = @_;
	my $this = shared_clone({});
	bless $this,$class;

    my $filter = '(tcp.len>1) || (udp.length>0)';
		# SKIP TCP KEEP ALIVE PACKETS
    display($dbg_sniff,0,"r_sniffer new($filter)");
    my $cmd = '"C:\\Program Files\\Wireshark\\tshark.exe" ';
	$cmd .=	'-i Ethernet ';
	$cmd .= '-l ';
	$cmd .= '-Y "' . $filter . '" ';
	$cmd .= '-T fields ';
	$cmd .= join ' ', map { "-e $_" } @sniff_fields;
	# $cmd .= ' -E occurrence=f';
    $cmd .= ' 2>NUL';
    display($dbg_sniff+1,1,"cmd='$cmd'");

	error("Could not open tshark pipe")
		if !open($sniff_fh, '-|', $cmd);

	$this->{buffers} = shared_clone({});
		# for buffering tcp packets that come in pairs
		# starting with a length word, followed by another packet
	$this->{parsers} = shared_clone({});
    display($dbg_sniff+1,0,"sniffer started");
    return $this;
}


sub start
{
	my ($this) = @_;
    display($dbg_sniff,0,"s_sniffer() start");
	my $thread = threads->create(\&sniffer_thread,$this);
    $thread->detach();
}


my $unknown = 0;

sub sniffer_thread
{
	my ($this) = @_;
    display($dbg_sniff,0,"sniffer thread started");
	my $start_time = int(time()) % $SECS_PER_DAY;
	$start_time -= 5 * 60 * 60;	# panama time zone

    while (1)
    {
		my $line = <$sniff_fh>;
		if (defined($line) && length($line))
		{
			chomp $line;
			# print "line=$line\n";
			return undef if !$line;

			#------------------------------------------
			# parse the line into meaningful locals
			#------------------------------------------

			my %values;
			my @parts = split(/\t/, $line);
			# @parts = (@parts, ('') x (@sniff_fields - @parts));
			@values{@sniff_fields} = @parts;

			my $src_port;
			my $dst_port;
			my $payload;
			my $ts     = $values{'frame.time'};
			my $src_ip = $values{'ip.src'};
			my $dst_ip = $values{'ip.dst'};
			my $proto  = $values{'tcp.len'} ? 'tcp' : 'udp';

			next if $ignore_ip_re && $src_ip =~ /$ignore_ip_re/;
			next if $ignore_ip_re && $dst_ip =~ /$ignore_ip_re/;

			# Oct 25, 2025 08:36:37.062254000 SA Pacific Standard Time

			my @time_parts = split(/\s+/,$ts);
			my $time_part = $time_parts[3];
			my ($h, $m, $s) = split /:/, $time_part;
			my $seconds = $h * 3600 + $m * 60 + $s;
			my $time = sprintf("%0.3f",$seconds-$start_time);
			# print "   time_part($time_part) seconds($seconds) start_time($start_time)\n";
			

			if ($proto eq 'tcp')
			{
				$src_port = $values{'tcp.srcport'};
				$dst_port = $values{'tcp.dstport'};
				my $bytes  = pack('H*',$values{'tcp.payload'});

				my $addr = "$src_ip:$src_port";
				$this->{buffers}->{$addr} ||= '';
				$this->{buffers}->{$addr} .= $bytes;
				next if length($this->{buffers}->{$addr}) <= 2;

				$payload = $this->{buffers}->{$addr};
				$this->{buffers}->{$addr} = '';
			}
			else
			{
				if (!$values{'udp.payload'})
				{
					error("UDP send likely failed: $line");
					next;
				}
				$src_port = $values{'udp.srcport'};
				$dst_port = $values{'udp.dstport'};
				$payload  = pack('H*',$values{'udp.payload'});
			}

			next if $ignore_port_re && $src_port =~ /$ignore_port_re/;
			next if $ignore_port_re && $dst_port =~ /$ignore_port_re/;

			# print "line=$line\n";


			#------------------------------------------------------------------
			# Map to server/client values based on SNIFFER_DEFAULTS
			#------------------------------------------------------------------

			my $client_ip 	= $src_ip;
			my $client_port = $src_port;
			my $server_ip 	= $dst_ip;
			my $server_port = $dst_port;

			my $def = $SNIFFER_DEFAULTS{$server_port};
			if (!$def)
			{
				$client_ip 	 = $dst_ip;
				$client_port = $dst_port;
				$server_ip 	 = $src_ip;
				$server_port = $src_port;
				$def = $SNIFFER_DEFAULTS{$server_port}
			}
			if (!$def)
			{
				# for ephemeral ports, we receive packets that don't map to any advertised services,
				# but inside the packet we can look at the sid_word and determine the service,
				# and thus, find existing ones. For tcp we have to skip the initial length word,
				# and on both we skip the cmd_word to get to the sid_word.  This is interesting
				# because it means I can discover new ephemeral udp ports used by RNS.

				my $sid_offset = $proto eq 'tcp' ? 4 : 2;
				my $sid_bytes = substr($payload,$sid_offset,2);
				my $sid = unpack('v',$sid_bytes);

				# Now we look through the SNIFFER defaults for any one that has a matching sid and proto

				warning($dbg_sniff+2,0,"Checking sid($sid) proto($proto) for existing SNIFFER_DEFAULT");

				for my $port (keys %SNIFFER_DEFAULTS)
				{
					my $try = $SNIFFER_DEFAULTS{$port};
					if ($try->{sid} == $sid && $try->{proto} eq $proto)
					{
						warning($dbg_sniff+2,1,"Found($port) at sid($sid) proto($proto) for existing SNIFFER_DEFAULT");
						$def = $try;
						last;
					}
				}

				# Acting under the assumption that the E80 is ALWAYS the server in these cases (?)
				# I can then adjust the $client_ip/port and $server_ip/port accordingly, which also
				# indicates that the parser should perhaps be hashed by the $client_ip and not the
				# $service_ip below

				if ($def)
				{
					if ($src_ip eq $E80_1_IP)
					{
						$client_ip 	 = $dst_ip;
						$client_port = $dst_port;
						$server_ip 	 = $src_ip;
						$server_port = $src_port;
					}
					elsif ($dst_ip eq $E80_1_IP)
					{
						$client_ip 	 = $src_ip;
						$client_port = $src_port;
						$server_ip 	 = $dst_ip;
						$server_port = $dst_port;
					}
				}
			}
			if (!$def)
			{
				error("NO SNIFFER_DEFAULTS for src($src_ip:$src_port) dst($dst_ip:$dst_port)");
				$def = {
						sid => -3,
						name => 'new'.$unknown++,
						proto => $proto,
						rx => { $MCTRL_WHAT_DEFAULT => { ctrl => $MCTRL_DIRECTION_REPLY,	mon => 0xffffffff, color => $UTILS_COLOR_RED, } },
						tx => { $MCTRL_WHAT_DEFAULT => { ctrl => $MCTRL_DIRECTION_REQUEST,	mon => 0xffffffff, color => $UTILS_COLOR_RED, } },
					};
				
				# next;
			}


			#--------------------------------------------------------------------
			# determine $is_reply, $is_shark, a $server_name and $client_name
			#--------------------------------------------------------------------
			# this code is nasty and ugly because sniffer has to empirically
			# determine if the client is shark or RNS (or something else?)


			my $MAX_UDP_LISTENER_SERVICE_ID = 100;
				# thus far we have never seen a service_id higher than this

			my $is_shark = 0;
			my $is_reply = $client_ip eq $dst_ip ? 1 : 0;
			my $device_id = $KNOWN_SERVER_IPS{$server_ip} || $server_ip;
			my $server_name = "$def->{name}($device_id)";
			my $client_name = $KNOWN_SERVER_IPS{$client_ip};
			$client_name = $client_name ?
				"$client_name($client_port)" :
				"$client_ip:$client_port";

			if ($proto eq 'tcp')
			{
				use c_RAYSYS;
				my $addr = "$server_ip:$server_port";
				my $service_port =
					$raysys->{implemented_services}->{$def->{name}} ||
					$raysys->{ports_by_addr}->{$addr};
				my $local_port = $service_port ? $service_port->{local_port} : 0;
				$local_port ||= 0;
				if ($client_port == $local_port)
				{
					# it was sent to/from the ephemeral port from one our
					# tcp b_socks
					$is_shark = 1;
					$client_name = "shark($local_port)";
				}
			}
			elsif ($client_port == $LOCAL_UDP_PORT_BASE)
			{
				# it was sent FROM shark's sendUDPPacket() method
				$is_shark = 1;
				$client_name = "shark(udp)";
			}
			elsif ($client_port >  $LOCAL_UDP_PORT_BASE &&
				   $client_port <= $LOCAL_UDP_PORT_BASE + $MAX_UDP_LISTENER_SERVICE_ID)
			{
				# it was sent TO one of our udp listener ports
				$is_shark = 1;
				$client_name = "shark($client_port)";
			}
			

			#---------------------------------------------------
			# construct or use existing parser
			#---------------------------------------------------

			my $mctrl_device = $is_shark ?
				$MCTRL_DEVICE_SHARK :
				$MCTRL_DEVICE_RNS ;
				
			my $parse_class = $def->{parser_class} || 'a_parser';
			my $parse_id = "$server_ip.$parse_class";
			my $parser = $this->{parsers}->{$parse_id};

			if (!$parser)
			{
				display($dbg_sniff+1,0,"creating new parser($parse_id)");
				$parser = $this->{parsers}->{$parse_id} = $parse_class->new($def,$mctrl_device)
			}

			# construct and parse the packet
			# a few of these fields are not needed
			#
			#	time
			#	src_ip/port
			#	dst_ip/port
			#
			# and are only added by me for clarity in debugging
			
			if (1)
			{
				# my $packet = a_packet->new({
				my $packet = shared_clone({
					is_shark	=> $is_shark,
					is_reply	=> $is_reply,
					time		=> $time,
					proto		=> $proto,
					src_ip		=> $src_ip,
					src_port	=> $src_port,
					dst_ip		=> $dst_ip,
					dst_port	=> $dst_port,
					client_ip	=> $client_ip,
					client_port	=> $client_port,
					server_ip	=> $server_ip,
					server_port	=> $server_port,
					client_name => $client_name,
					server_name => $server_name,
					payload	    => $payload, });
				$parser->parsePacket($packet);
			}
		}
		else
		{
			sleep(0.1);
		}
    }	# while 1
}	# sniffer_thread



1;