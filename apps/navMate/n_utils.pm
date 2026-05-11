#---------------------------------------------
# n_utils.pm
#---------------------------------------------

package n_utils;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time);
use Pub::Utils;
use n_defs;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		$appName
		makeUUID
		parseLatLon
		formatLatLon
		@E80_ROUTE_COLOR_ABGR
		abgrToE80Index
		isExactE80Color
	);
}


our $appName = 'navMate';


#---------------------------------
# makeUUID
#---------------------------------

sub makeUUID
	# Generate a navMate UUID (16 hex chars = 8 bytes).
	# Byte 1 = 0x4E ('N') identifies navMate-created objects.
	# Bytes 4-5 hold the persistent counter (little-endian).
	# Byte 0 and bytes 2-3 are random; bytes 6-7 are intra-tick random.
{
	my ($counter) = @_;
	return sprintf("%02x4e%04x%s%04x",
		int(rand(256)),
		int(rand(65536)),
		unpack('H*', pack('v', $counter)),
		int(rand(65536)));
}



#---------------------------------
# parseLatLon
#---------------------------------
# Accepts decimal degrees or degrees+decimal-minutes, with optional
# leading minus or trailing NSEW compass letter.  NSEW overrides
# a leading minus when both are present.
#
# Accepted formats (whitespace flexible):
#   DD:   9.3617   -9.3617   9.3617 N   9.3617 S
#   DDM:  9 21.702   -9 21.702   9 21.702 N   9 21.702 S
#
# Returns decimal degrees as a number, or undef on parse failure.

sub parseLatLon
{
	my ($str) = @_;
	return undef if !defined($str);
	$str =~ s/^\s+|\s+$//g;
	return undef if $str eq '';

	my $sign = 1;

	# Optional leading minus
	if ($str =~ s/^-//)
	{
		$sign = -1;
	}
	$str =~ s/^\s+//;

	# Optional trailing NSEW - overrides leading minus
	if ($str =~ s/\s*([NSEWnsew])$//)
	{
		my $dir = uc($1);
		$sign = ($dir eq 'S' || $dir eq 'W') ? -1 : 1;
	}
	$str =~ s/\s+$//;

	# DDM: non-negative integer degrees + space + decimal minutes (0..59.999)
	if ($str =~ /^(\d+)\s+(\d+(?:\.\d+)?)$/)
	{
		my ($deg, $min) = ($1 + 0, $2 + 0);
		return undef if $min >= 60;
		return $sign * ($deg + $min / 60);
	}

	# DD: single non-negative number
	if ($str =~ /^(\d+(?:\.\d+)?)$/)
	{
		return $sign * ($1 + 0);
	}

	return undef;
}


#---------------------------------
# formatLatLon
#---------------------------------
# Formats a decimal-degree value as "DD (DDM)" for display.
# $is_lat true -> N/S compass; false -> E/W.
# Example: formatLatLon(9.3617, 1)  -> "9.361700 N  (9deg21.702' N)"
#          formatLatLon(-82.2451, 0) -> "82.245100 W  (82deg14.706' W)"

sub formatLatLon
{
	my ($dd, $is_lat) = @_;
	my $abs = abs($dd);
	my $dir = $is_lat
		? ($dd >= 0 ? 'N' : 'S')
		: ($dd >= 0 ? 'E' : 'W');
	my $deg     = int($abs);
	my $min     = ($abs - $deg) * 60;
	my $deg_sym = chr(176);
	return sprintf("%.6f %s  (%d%s%06.3f' %s)", $abs, $dir, $deg, $deg_sym, $min, $dir);
}


#---------------------------------
# E80 route/track line colors
#---------------------------------
# Index 0-5 maps to $ROUTE_COLOR_XXX constants in NET::a_defs.pm.
# Index 5 ($ROUTE_COLOR_BLACK) displays as white on the Leaflet map.

our @E80_ROUTE_COLOR_ABGR = qw(
	ff0000ff
	ff00ffff
	ff00ff00
	ffff0000
	ffff00ff
	ffffffff
);


sub abgrToE80Index
{
	my ($abgr) = @_;
	return 0 if !($abgr && length($abgr) >= 8);
	my $rr = hex(substr($abgr, 6, 2));
	my $gg = hex(substr($abgr, 4, 2));
	my $bb = hex(substr($abgr, 2, 2));
	my @targets = (
		[255,   0,   0],   # 0 RED
		[255, 255,   0],   # 1 YELLOW
		[  0, 255,   0],   # 2 GREEN
		[  0,   0, 255],   # 3 BLUE
		[255,   0, 255],   # 4 PURPLE
		[255, 255, 255],   # 5 WHITE (protocol name: BLACK)
	);
	my ($best_idx, $best_dist) = (0, 9e99);
	for my $i (0 .. $#targets)
	{
		my $d = ($rr - $targets[$i][0])**2
		      + ($gg - $targets[$i][1])**2
		      + ($bb - $targets[$i][2])**2;
		$best_idx = $i if $d < $best_dist and do { $best_dist = $d; 1 };
	}
	return $best_idx;
}


my %_e80_exact_color = map { $_ => 1 } @E80_ROUTE_COLOR_ABGR;
sub isExactE80Color { $_e80_exact_color{lc($_[0] // '')} ? 1 : 0 }


1;

