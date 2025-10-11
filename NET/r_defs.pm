#---------------------------------------------
# r_defs.pm
#---------------------------------------------

package r_defs;
use strict;
use warnings;
use POSIX qw(floor pow atan tan);
use Pub::Utils;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(
	
		$SUCCESS_SIG
		name16_hex

		$PI
		$PI_OVER_2
		$SCALE_LATLON
		$METERS_PER_NM
		$FEET_PER_METER
		$SECS_PER_DAY

		$KNOTS_TO_METERS_PER_SEC

		degreeMinutes
		northEastToLatLon
		latLonToNorthEast

    );
}


our $SUCCESS_SIG = '00000400';

our $PI = 3.14159265358979323846;
our $PI_OVER_2 = $PI / 2;
our $SCALE_LATLON 	= 1e7;

our $METERS_PER_NM 	= 1852;
our $FEET_PER_METER  = 3.28084;
our $SECS_PER_DAY 	= 86400;
our $KNOTS_TO_METERS_PER_SEC = 0.5144;

my $FSH_LAT_SCALE = 107.1709342;  # same scale used in forward transform
my $LONG_SCALE = 0x7fffffff;  # 2147483647



sub name16_hex
	# return hex representation of max16 name + null
{
	my ($name,$no_delim) = @_;
	while (length($name) < 16) { $name .= "\x00" }
	$name .= "\x00" if !$no_delim;
	return unpack('H*',$name);
}


sub degreeMinutes
{
	my $DEG_CHAR = chr(0xB0);
	my ($ll) = @_;
	my $deg = int($ll);
	my $min = round(abs($ll - $deg) * 60,3);
	return "$deg$DEG_CHAR$min";
}



sub northEastToLatLon	# from FSH
    # Convert mercator north,east coords to lat/lon.
    # From blackbox.ai, based on https://wiki.openstreetmap.org/wiki/ARCHIVE.FSH
    # In my first 'fishfarm' test case, I expected 5.263N minutes but got 5.261N
    #   0.001 minutes == approx 1.8553 meters, so this is physically off by about 4 meters.
    #   More testing will be required to see if it's close on other coordinates.
    #   The original fshfunc.c implies an accuracy of 10cm, but that's only for the
    #   the iteration, not the actual value.
{
    my ($north, $east) = @_;

    my $FSH_LAT_SCALE = 107.1709342;
        # Northing in FSH is prescaled by this (empirically determined)
        # Original comment said "probably 107.1710725 is more accurate, not sure"
        # but that makes mine worse, not better.
    # my $FSH_LAT_SCALE = 107.1705000;
        # experimental value gave me 5.263 for fishfarm

    my $longitude = ($east / $LONG_SCALE) * 180.0;
    my $N = $north / $FSH_LAT_SCALE;

    # WGS84 ellipsoid parameters
    my $a = 6378137;  # semi-major axis
    my $e = 0.08181919;  # eccentricity

    # Iterative calculation for latitude
    my $phi = $PI_OVER_2;  # Initial guess
    my $phi0;
    my $IT_ACCURACY = 1.5E-8;
    my $MAX_IT = 32;
    my $i = 0;

    do {
        $phi0 = $phi;
        my $esin = $e * sin($phi0);
        $phi = $PI_OVER_2 - 2.0 * atan(exp(-$N / $a) * pow((1 - $esin) / (1 + $esin), $e / 2));
        $i++;
    } while (abs($phi - $phi0) > $IT_ACCURACY && $i < $MAX_IT);

    # Convert radians to degrees
    my $latitude = $phi * 180 / $PI;

	my $lat = sprintf("%.6f",$latitude);
	my $lon = sprintf("%.6f",$longitude);

	#display($dbg,0,"northEastToLatLon($north,$east) ==> $lat,$lon");
	#latLonToNorthEast($lat,$lon);

    return {
        lat => $lat,
        lon => $lon };
}


sub latLonToNorthEast
	# from copilot
{
    my ($lat_deg, $lon_deg) = @_;

    # WGS84 ellipsoid parameters
    my $a = 6378137;       # semi-major axis
    my $e = 0.08181919;    # eccentricity

    # Convert degrees to radians
    my $lat_rad = $lat_deg * $PI / 180.0;

    # Mercator projection formula for northing
    my $esin = $e * sin($lat_rad);
    my $N = $a * log(tan($PI / 4 + $lat_rad / 2) * ((1 - $esin) / (1 + $esin)) ** ($e / 2));

    # Apply FSH scaling
    my $north = int($N * $FSH_LAT_SCALE + 0.5);

    # Easting is linear
    my $east = int(($lon_deg / 180.0) * $LONG_SCALE + 0.5);

    return {
        north => $north,
        east  => $east
    };
}


1;