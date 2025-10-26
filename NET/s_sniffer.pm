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
use a_packet;

my $dbg_sniff = -2;

my $ignore_ip_re = join('|',(
	'224.0.0.251',			# router
	'10.0.241.254',			# router ssdp
	'10.255.255.255',		# windows netbios dnd
	'239.255.255.250', ));	# ssdp
my $ignore_port_re = join('|',(
	'5800',					# RAYSYS
	'5801', ));				# Alarm


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(
    );
}


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

    display($dbg_sniff,0,"sniffer started");
    return $this;
}


sub start
{
	my ($this) = @_;
    display($dbg_sniff,0,"s_sniffer() start");
	my $thread = threads->create(\&sniffer_thread,$this);
    $thread->detach();
}



sub sniffer_thread
{
	my ($this) = @_;
    display($dbg_sniff,0,"sniffer thread started");
	my $start_time = time();

    while (1)
    {
		my $line = <$sniff_fh>;
		if (defined($line) && length($line))
		{
			chomp $line;
			# print "line=$line\n";
			return undef if !$line;

			my %values;
			my @parts = split(/\t/, $line);
			# @parts = (@parts, ('') x (@sniff_fields - @parts));
			@values{@sniff_fields} = @parts;

			#	if ($values{'icmp.code'})
			#	{
			#		if ($values{'icmp.code'} == 3)
			#		{
			#			my $raw = $values{'icmp.payload'};
			#			my $bytes = pack('H*', $raw);
            #
			#			# Skip the IP header (first 20 bytes)
			#			my $udp_header = substr($bytes, 20, 8);
			#			my ($src_port, $dst_port) = unpack('n n', $udp_header);
            #
			#			error("ICMP Port Unreachable: $values{'ip.src'} says $values{'ip.dst'}:$dst_port is unreachable");
			#		}
			#		next;
			#	}

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

			if (1)
			{
				my $packet = a_packet->new({
					time		=> $time,
					proto		=> $proto,
					src_ip	    => $src_ip,
					src_port	=> $src_port,
					dst_ip	    => $dst_ip,
					dst_port	=> $dst_port,
					payload	    => $payload, });
			}
		}
		else
		{
			sleep(0.1);
		}
    }	# while 1
}	# sniffer_thread



1;