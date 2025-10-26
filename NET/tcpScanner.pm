#---------------------------------------------
# tcpScanner.pm
#---------------------------------------------
# A general purpose tcp port scanner at a
# given IP address.  With this I discovered
# only one hidden tcp port 6667, on the E80.

package tcpScanner;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Socket;
use IO::Select;
use Pub::Utils;

# temporary implementation
# Try to find the last two unmapped TCP client in Raymarine Services Menu

my $E80_1_IP	= '10.0.241.54';
my $E80_2_IP	= '10.0.241.83';
my $RNS_IP 		= '128.118.142.1';

my $TARGET_IP = $E80_1_IP;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(
		$tcp_scanner
    );
}

my $MAX_SCANS  = 10;
my $MIN_PORT    = 23;
my $MAX_PORT	= 32768;


our $tcp_scanner:shared;

sub new
{
	my ($class) = @_;
	return error("tcp scanner already exists",1) if $tcp_scanner;

	$tcp_scanner = shared_clone({
		started => 0,
		num_scanned => 0,
		num_unscanned => 0,
		scans => shared_clone({}), });
	bless $tcp_scanner,$class;
	return $tcp_scanner;
}




sub showAliveScans
{
	my ($this) = @_;
	display(0,0,"The following TCP ports are alive");
	my $num_alive = 0;
	for my $port (sort keys %{$this->{scans}})
	{
		my $exists = $this->{scans}{$port} || 0;
		if ($exists > 0)
		{
			display(0,1,"PORT($port) is ALIVE!");
			$num_alive++;
		}
	}
	display(0,1,"There are $num_alive alive ports");
}



sub scanRange
{
	my ($this,$low,$high) = @_;
	lock($this);

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

	return warning(0,0,"NO NEW PORTS ADDED TO TCP SCAN RANGE")
		if !$num_new;
	display(0,1,"added $num_new ports to tcp_scan range");
	$this->{num_unscanned} += $num_new;

	# start the scanMasterThread if !started

	if (!$this->{started})
	{
		display(0,1,"creating tcp scanMasterThread");
		my $master_thread = threads->create(\&scanMasterThread,$this);
		$master_thread->detach();
		$this->{started} = 1;
	}
}


sub scanMasterThread
{
	my ($this) = @_;
	display(0,0,"tcp scanMasterThread running");
	while (1)
	{
		if ($this->{num_unscanned})
		{
			lock($this);
			for my $port (sort keys %{$this->{scans}})
			{
				my $scan = $this->{scans}->{$port};
				if ($scan == 0)
				{
					display(0,1,"scanning tcp port($port)");
					$this->{num_unscanned}--;
					$this->{num_scanned}++;

					my $sock = IO::Socket::INET->new(
						PeerAddr  => $TARGET_IP,
						PeerPort  => $port,
						Proto     => 'tcp',
						Reuse	  => 1,	# allows open even if windows is timing it out
						Timeout	  => 2 );

					if ($sock)
					{
						$this->{scans}->{$port} = 1;
						display(0,2,"CONNECTED TO remote port($port) !!!",0,$UTILS_COLOR_LIGHT_GREEN);
						$sock->close();
					}
					else
					{
						$this->{scans}->{$port} = -1;
					}
				}
			}
		}
		else
		{
			sleep(0.1);
		}
	}
}




1;