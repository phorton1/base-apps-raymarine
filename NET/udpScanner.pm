#---------------------------------------------
# udpScanner.pm
#---------------------------------------------
# Probes UDP ports and watches for ICMP Port Unreachable responses

package udpScanner;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use IO::Socket::INET;
use Pub::Utils;

BEGIN
{
    use Exporter qw(import);
    our @EXPORT = qw(
		$udp_scanner
    );
}

my $TARGET_IP     = '10.0.241.54';
my $MIN_PORT      = 1;
my $MAX_PORT      = 64356;


our $udp_scanner:shared;


sub new
{
	my ($class) = @_;
	return error("udp scanner already exists",1) if $udp_scanner;

	$udp_scanner = shared_clone({
		started => 0,
		icmp_running => 0,
		num_scanned => 0,
		num_unscanned => 0,
		scans => shared_clone({}), });
	bless $udp_scanner,$class;
	return $udp_scanner;
}



sub showAliveScans
{
	my ($this) = @_;
    display(0, 0, "The following ports DID NOT trigger ICMP Port Unreachable:");

	my $num_alive = 0;
    for my $port (sort keys %{$this->{scans}})
    {
		my $scan = $this->{scans}->{$port};
		my $sent = $scan->{sent};
		my $icmp = $scan->{icmp};
        if ($sent > $icmp)
		{
			$num_alive++;
            display(0, 1, "PORT($port) may be open sent($sent) icmp($icmp)");
        }
    }
	display(0,1,"There are $num_alive possibly alive ports");
}





sub scanRange
{
	my ($this,$low,$high,$agressive) = @_;
	$agressive ||= 0;
	lock($this);

	$this->{scans} = shared_clone({});
	$this->{num_scanned} = 0;
	$this->{num_unscanned} = 0;
	$this->{agressive} = $agressive ? 1 : 0;

	$low ||= 0;
	$high ||= $low;
	display(0,0,"scanRange($low,$high)");
	return error("low must be specified") if !$low;
	return error("low must be > $MIN_PORT") if $low<$MIN_PORT;
	return error("low and high must <= $MAX_PORT")
		if $low > $MAX_PORT || $high > $MAX_PORT;
	return error("low($low) must be >= high($high)")
		if $high < $low;

	my $num_new = 0;
	for my $port ($low..$high)
	{
		my $exists = $this->{scans}->{$port};
		next if defined($exists);
		$num_new++;
		$this->{scans}->{$port} = 0;
	}

	return warning(0,0,"NO NEW PORTS ADDED TO UDP SCAN RANGE")
		if !$num_new;
	display(0,1,"added $num_new ports to udp scan range");
	$this->{num_unscanned} += $num_new;

	# start the icmpWatcherThread thread and scanMasterThread if !started

	if (!$this->{started})
	{
		display(0,1,"creating udp scanMasterThread");
		my $master_thread = threads->create(\&scanMasterThread,$this);
		$master_thread->detach();

		display(0,1,"creating udp icmpWatcherThread");
		my $icmp_thread = threads->create(\&icmpWatcherThread,$this);
		$icmp_thread->detach();

		$this->{started} = 1;

	}

}


sub scanMasterThread
{
	my ($this) = @_;
	while (!$this->{icmp_running})
	{
		sleep(0.1);
	}
	display(0,0,"tcp scanMasterThread running");
	sleep(2);
	
	while (1)
	{
		if ($this->{num_unscanned})
		{
			lock($this);
			for my $port (sort keys %{$this->{scans}})
			{
				my $scan = $this->{scans}->{$port};
				if (!$scan)
				{
					$scan = $this->{scans}->{$port} = shared_clone({
						sent => 0,
						icmp => 0 });
														   
					display(0,1,"scanning udp port($port)");
					$this->{num_unscanned}--;
					$this->{num_scanned}++;

					my $sock = IO::Socket::INET->new(
						PeerAddr => $TARGET_IP,
						PeerPort => $port,
						Proto    => 'udp',
						Reuse    => 1,
						Timeout  => 1
					);

					if (!$sock)
					{
						error("Could not create UDP socket for port($port)");
						$this->{scans}->{$port} = -2;
					}
					else
					{
						my $payload = "probe-$port";
						for my $i (0..$this->{agressive}*999)
						{
							send($sock, $payload, 0);
							$scan->{sent}++;
						}
						sleep(0.1);
						$sock->close();
					}
				}
			}
		}
		else
		{
			sleep(0.01);
		}
	}
}






sub icmpWatcherThread
{
	my ($this) = @_;
    display(0, 0, "udp icmpWatcherThread started");

    my $cmd =
		'"C:\\Program Files\\Wireshark\\tshark.exe" '.
		'-i Ethernet '.
		'-l '.
		'-f "icmp" '.
		'2>NUL';

	my $fh;
    if (!open($fh, '-|', $cmd))
    {
        error("Could not start tshark for ICMP");
        return;
    }

	$this->{icmp_running} = 1;
    while (my $line = <$fh>)
    {
        chomp $line;
		# print "UDP LINE=$line\n";
		if ($line =~ /(\d+) ICMP 128 Destination unreachable/)
		{
			lock($this);
			my $port = $1;
			my $scan = $this->{scans}->{$port};
			if ($scan)
			{
				$scan->{icmp}++;
				if (!$scan->{reported} && $scan->{sent} == $scan->{icmp})
				{
					display(0,4,"ICMP Port($port) Unreachable",0,$UTILS_COLOR_MAGENTA);
					$scan->{reported} = 1;
				}
			}
		}
    }
}



1;