#---------------------------------------------
# n_utils.pm
#---------------------------------------------

package n_utils;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time);
use POSIX qw(strftime);
use Pub::Utils;
use n_defs;
use apps::raymarine::NET::a_utils qw(northEastToLatLon @E80_SYMS);


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		$appName
		makeUUID
		makeFSHUUID
		parseLatLon
		formatLatLon
		latLonLineText
		northEastLineText
		symText
		wpTypeText
		depthText
		tempKText
		tsText
		trackPointsText
		routePointsText
		uuidRefText
		@E80_ROUTE_COLOR_ABGR
		@E80_ROUTE_COLOR_NAMES
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


sub makeFSHUUID
{
	my ($counter) = @_;
	return sprintf("%02x46%04x%s%04x",
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

# Index 5 is called BLACK in the E80 protocol but its ABGR is ffffffff (white on Leaflet).
our @E80_ROUTE_COLOR_NAMES = ('Red', 'Yellow', 'Green', 'Blue', 'Purple', 'Black (White on Map)');


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


#---------------------------------
# info-text helpers
#---------------------------------
# Convergence layer used by winDatabase / winFSH / winE80 info panels.
# Each returns the formatted "value" portion -- callers wrap with their
# own "<key> = " prefix via sprintf / _fmt.

sub latLonLineText
	# Two-line block: "  lat = DD (DDM)\n  lon = DD (DDM)\n"
	# Caller-supplied indent (default 2 spaces) and key width.
{
	my ($lat, $lon, %opts) = @_;
	my $indent = $opts{indent} // '  ';
	my $kw     = $opts{kw}     // 12;
	return sprintf("%s%-${kw}s = %s\n%s%-${kw}s = %s\n",
		$indent, 'lat', formatLatLon($lat // 0, 1),
		$indent, 'lon', formatLatLon($lon // 0, 0));
}


sub northEastLineText
	# Two-line block showing raw N/E ints AND the lat/lon they round-trip
	# back to (diagnostic for Mercator precision delta).  nkey/ekey
	# default to 'north'/'east' but can be set to 'north_start'/'east_end'
	# etc. when an MTA record carries pair-suffixed fields.
{
	my ($north, $east, %opts) = @_;
	my $indent = $opts{indent} // '  ';
	my $kw     = $opts{kw}     // 12;
	my $nkey   = $opts{nkey}   // 'north';
	my $ekey   = $opts{ekey}   // 'east';
	my $c = northEastToLatLon($north // 0, $east // 0);
	return sprintf("%s%-${kw}s = %-12d -> %s\n%s%-${kw}s = %-12d -> %s\n",
		$indent, $nkey, $north // 0, formatLatLon($c->{lat} + 0, 1),
		$indent, $ekey, $east  // 0, formatLatLon($c->{lon} + 0, 0));
}


sub symText
{
	my ($sym) = @_;
	$sym //= 0;
	my $name = $E80_SYMS[$sym] // '?';
	return "$sym ($name)";
}


sub wpTypeText
{
	my ($wt) = @_;
	$wt //= 0;
	my $name = $WP_TYPE_NAMES[$wt] // '?';
	return "$wt ($name)";
}


sub depthText
	# Accepts depth in cm; renders "N cm  (X.X ft)".
{
	my ($cm) = @_;
	$cm //= 0;
	return sprintf('%d cm  (%.1f ft)', $cm, $cm / 30.48);
}


sub tempKText
	# Accepts Kelvin * 100; renders "N  (X.X F)".
{
	my ($tk) = @_;
	$tk //= 0;
	return sprintf('%d  (%.1f F)', $tk, ($tk / 100 - 273) * 9 / 5 + 32);
}


sub tsText
	# Unix epoch seconds -> "YYYY-MM-DD HH:MM UTC" or "(none)".
{
	my ($ts) = @_;
	return $ts ? strftime("%Y-%m-%d %H:%M UTC", gmtime($ts)) : '(none)';
}


sub trackPointsText
	# Renders an indexed table of trackpoints.  Each point may carry
	# {lat, lon, depth_cm OR depth, temp_k, ts} -- depth and ts are
	# optional.  with_datetime=1 adds a trailing UTC timestamp column
	# (only the DB carries per-point ts).
{
	my ($points, %opts) = @_;
	return '' if !$points || !@$points;
	my $with_dt = $opts{with_datetime} ? 1 : 0;
	my $text = '';
	for my $i (0 .. $#$points)
	{
		my $pt   = $points->[$i];
		my $lat  = ($pt->{lat} // 0) + 0;
		my $lon  = ($pt->{lon} // 0) + 0;
		# (0,0) treated as a sentinel (FSH zero-zero filler) -- depth/temp
		# blanked out to match the visual "no real data" cue.
		my $sentinel = ($lat == 0 && $lon == 0) ? 1 : 0;
		my $d_cm = $pt->{depth_cm} // $pt->{depth} // 0;
		my $d_ft = (!$sentinel && $d_cm) ? sprintf('%.1fft', $d_cm / 30.48) : '-';
		my $t_f  = (!$sentinel && ($pt->{temp_k} // 0))
			? sprintf('%.1fF', ($pt->{temp_k} / 100 - 273) * 9 / 5 + 32)
			: '-';
		my $dt = '';
		if ($with_dt)
		{
			$dt = (!$sentinel && ($pt->{ts} // 0))
				? '  ' . strftime("%Y-%m-%d %H:%M:%S UTC", gmtime($pt->{ts}))
				: '  -';
		}
		$text .= sprintf("  %3d  %9.6f  %10.6f  %8s  %6s%s\n",
			$i + 1, $lat, $lon, $d_ft, $t_f, $dt);
	}
	return $text;
}


sub routePointsText
	# Renders a list of route waypoints with their per-point geometry.
	# Each point may carry {name, lat, lon, bearing, legLength, totLength}.
	# bearing/legLength/totLength are present on E80/FSH route geometry
	# records and absent in the DB; rendered conditionally.
{
	my ($points) = @_;
	return '' if !$points || !@$points;
	my $text = '';
	for my $i (0 .. $#$points)
	{
		my $pt = $points->[$i];
		$text .= sprintf("  %2d. %s\n", $i + 1, $pt->{name} // '');
		$text .= sprintf("      lat       = %s\n", formatLatLon($pt->{lat} // 0, 1));
		$text .= sprintf("      lon       = %s\n", formatLatLon($pt->{lon} // 0, 0));
		$text .= sprintf("      bearing   = %.1f deg\n",
			($pt->{bearing} / 10000) * (180 / 3.14159265358979))
			if defined $pt->{bearing};
		$text .= sprintf("      legLength = %d m\n", $pt->{legLength}) if defined $pt->{legLength};
		$text .= sprintf("      totLength = %d m\n", $pt->{totLength}) if defined $pt->{totLength};
	}
	return $text;
}


sub uuidRefText
	# Render a UUID with optional name resolution.  $resolver is a
	# coderef taking the UUID and returning a descriptive string
	# (e.g. 'group "Foo"') or undef when not found.
{
	my ($uuid, $resolver) = @_;
	my $ref = $resolver ? $resolver->($uuid) : undef;
	return $ref ? "$uuid = $ref" : $uuid;
}


1;

