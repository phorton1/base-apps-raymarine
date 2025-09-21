#---------------------------------------------
# r_sniffer.pm
#---------------------------------------------

package apps::raymarine::NET::r_sniffer;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;

my $dbg_sniff = 1;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(
        $SNIFF_FIELDS

        startSniffer
        nextSniffPacket
    );
}


my $sniff_fh;
my $sniff_fields = [
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

sub startSniffer
{
    my $filter = '(tcp.len>0) || (udp.length>0)';
    display($dbg_sniff,0,"startSniffer($filter)");
    my $cmd = '"C:\\Program Files\\Wireshark\\tshark.exe" -i Ethernet -l -Y "' . $filter . '" -T fields ';
    $cmd .= join ' ', map { "-e $_->{field}" } @{$sniff_fields};
    $cmd .= ' 2>NUL';

    display($dbg_sniff+1,1,"cmd='$cmd'");

    if (!open($sniff_fh, '-|', $cmd))
    {
        error("Could not open tshark pipe");
        return 0;
    }

    display($dbg_sniff,0,"sniffer started");
    return 1;
}


sub nextSniffPacket
{
    my $line = <$sniff_fh>;
    return undef if !$line;

    chomp $line;
    return undef if !$line;
    
    my %fields;
    my @parts = split(/\t/, $line);
    @fields{ map $_->{name}, @$sniff_fields } = @parts;

    my $rec = shared_clone({
        src_ip    => $fields{src_ip},
        dest_ip   => $fields{dest_ip},
        proto     => ($fields{tcp_len} ? 'tcp' : 'udp'),
    });

    if ($rec->{proto} eq 'udp') {
        $rec->{udp} = 1;
        $rec->{src_port} = $fields{udp_srcport};
        $rec->{dest_port} = $fields{udp_dstport};
        $rec->{hex_data} = $fields{udp_payload};
    } else {
        $rec->{tcp} = 1;
        $rec->{src_port} = $fields{tcp_srcport};
        $rec->{dest_port} = $fields{tcp_dstport};
        $rec->{hex_data} = $fields{tcp_payload};
    }

    if (!$rec->{hex_data})
    {
        error("no packet: $line");
        $rec->{hex_data} = '';
    }
    $rec->{raw_data} = pack("H*", $rec->{hex_data});

    display($dbg_sniff,0,"$rec->{proto} $rec->{src_ip}:$rec->{src_port} -> $rec->{dest_ip}:$rec->{dest_port}: $rec->{hex_data}");

    return $rec;
}



1;