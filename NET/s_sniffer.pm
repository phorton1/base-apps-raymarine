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

my $dbg_sniff = 0;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(
    );
}


my $sniff_fh;
my $sniff_packet_handler;
my $sniff_fields = [
    { name => 'time',        field => 'frame.time' },
    { name => 'src_ip',      field => 'ip.src' },
    { name => 'dest_ip',     field => 'ip.dst' },
    { name => 'udp_len',     field => 'udp.length' },
    { name => 'udp_srcport', field => 'udp.srcport' },
    { name => 'udp_dstport', field => 'udp.dstport' },
    { name => 'udp_payload', field => 'udp.payload' },
    { name => 'tcp_len',     field => 'tcp.len' },
    { name => 'tcp_srcport', field => 'tcp.srcport' },
    { name => 'tcp_dstport', field => 'tcp.dstport' },
    { name => 'tcp_payload', field => 'tcp.payload' },
];


sub new
{
	my ($class,$handler) = @_;
	$sniff_packet_handler = $handler;
	my $this = shared_clone({});
	bless $this,$class;

    my $filter = '(tcp.len>0) || (udp.length>0)';
    display($dbg_sniff,0,"r_sniffer new($filter)");
    my $cmd = '"C:\\Program Files\\Wireshark\\tshark.exe" -i Ethernet -l -Y "' . $filter . '" -T fields ';
    $cmd .= join ' ', map { "-e $_->{field}" } @{$sniff_fields};
    $cmd .= ' 2>NUL';
    display($dbg_sniff+1,1,"cmd='$cmd'");

	error("Could not open tshark pipe")
		if !open($sniff_fh, '-|', $cmd);

    display($dbg_sniff,0,"sniffer started");
    return $this;
}


sub start
{
    display($dbg_sniff,0,"s_sniffer() start");
	my $thread = threads->create(\&sniffer_thread);
    $thread->detach();
}



sub sniffer_thread
{
   display($dbg_sniff,0,"sniffer thread started");

   while (1)
   {
		my $line = <$sniff_fh>;
		if (defined($line) && length($line))
		{
			chomp $line;
			return undef if !$line;

			my %fields;
			my @parts = split(/\t/, $line);
			@fields{ map $_->{name}, @$sniff_fields } = @parts;

			my $packet = shared_clone({
				time      => $fields{time},
				src_ip    => $fields{src_ip},
				dest_ip   => $fields{dest_ip},
				proto     => ($fields{tcp_len} ? 'tcp' : 'udp'),
			});

			if ($packet->{proto} eq 'udp')
			{
				$packet->{udp} = 1;
				$packet->{src_port} = $fields{udp_srcport};
				$packet->{dest_port} = $fields{udp_dstport};
				$packet->{hex_data} = $fields{udp_payload};
			}
			else
			{
				$packet->{tcp} = 1;
				$packet->{src_port} = $fields{tcp_srcport};
				$packet->{dest_port} = $fields{tcp_dstport};
				$packet->{hex_data} = $fields{tcp_payload};
			}

			# length(1) is an annoying ack message.

			if ($packet->{hex_data} && length($packet->{hex_data}) > 1)
			{
				$packet->{raw_data} = pack("H*", $packet->{hex_data});
				# display($dbg_sniff+1,0,"$packet->{proto} $packet->{src_ip}:$packet->{src_port} -> $packet->{dest_ip}:$packet->{dest_port}: $packet->{hex_data}");
				&{$sniff_packet_handler}($packet);
			}
			else
			{
				sleep(0.1);
			}
		}
		else
		{
			sleep(0.1);
		}
    }	# while 1
}	# sniffer_thread



1;