#--------------------------------------
# fshUtils.pm
#--------------------------------------
# Based on the C code at https://github.com/rahra/parsefsh

package apps::raymarine::FSH::fshUtils;
use strict;
use warnings;
use POSIX qw(floor pow atan);
use Fcntl qw(:seek);
use Time::Local;
use Pub::Utils;


our $DEGREE_CHAR = "°";

our $FSH_BLK_WPT = 0x0001;
our $FSH_BLK_TRK = 0x000d;
our $FSH_BLK_MTA = 0x000e;
our $FSH_BLK_RTE = 0x0021;
our $FSH_BLK_GRP = 0x0022;
our $FSH_BLK_ILL = 0xffff;  # Invalid block type

our $GUID_SIZE = 8;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (

        $DEGREE_CHAR

        $FSH_BLK_WPT
        $FSH_BLK_TRK
        $FSH_BLK_MTA
        $FSH_BLK_RTE
        $FSH_BLK_GRP
        $FSH_BLK_ILL

		$GUID_SIZE

        blockTypeToStr
        guidToStr
        unpackRecord
        degreesWithMinutes
        northEastToLatLon
		fshDateTimeToStr
    );
}



sub blockTypeToStr
{
    my ($type) = @_;
    return "BLK_WPT" if ($type == $FSH_BLK_WPT);
    return "BLK_TRK" if ($type == $FSH_BLK_TRK);
    return "BLK_MTA" if ($type == $FSH_BLK_MTA);
    return "BLK_RTE" if ($type == $FSH_BLK_RTE);
    return "BLK_GRP" if ($type == $FSH_BLK_GRP);
    return "BLK_ILL" if ($type == $FSH_BLK_ILL);
    my $msg = "UNKNOWN BLOCK TYPE ".sprintf("0x%04X",$type);
    error($msg);
    return $msg;
}


sub guidToStr
{
    my ($guid) = @_;
    my $guid_str = length($guid) ? '' : "empty_guid";
    for (my $i=0; $i<8 && $i<length($guid); $i++)
    {
        my $byte = ord(substr($guid,$i,1));
        $guid_str .= sprintf("%02X",$byte);
        $guid_str .= "-" if ($i<7) && ($i & 1);
    }
    return $guid_str;
}



sub fshDateTimeToStr
    # unused at this time
{
    my ($date,$time) = @_;

    my $ts = ($date * 3600 * 24) + $time;
    my @tm = gmtime($ts);
    my $retval = sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", $tm[5] + 1900, $tm[4] + 1, $tm[3], $tm[2], $tm[1], $tm[0]);
	# display(0,0,"fshDateTimeToStr($date,$time) = $retval");
	return $retval;
}



sub unpackRecord
	# https://www.perlmonks.org/?node_id=224666
    # A utility to unpack a bunch of fields into a record.
    # Accepts an array where even number elements are field names
    #   and odd number elements are the unpack types and a perl
    #   string of bytes and returns a record with the unpacked fields
{
	my ($dbg,$field_specs,$bytes) = @_;
        # caller passes in $dbg level
	my $num_specs = scalar(@$field_specs) / 2;
	my $unpack_str = '';

	for (my $i=0; $i<$num_specs; $i++)
	{
		my $field = $field_specs->[$i * 2];
		my $spec = $field_specs->[$i * 2 + 1];
		$unpack_str .= ' ' if $unpack_str;
		$unpack_str .= $spec;
	}
	my $rec = {};
	my @vals = unpack($unpack_str,$bytes);
	for (my $i=0; $i<$num_specs; $i++)
	{
		my $field = $field_specs->[$i * 2];
		$rec->{$field} = $vals[$i];
		display($dbg,1,pad($field,20)."= '$rec->{$field}'");
	}
	return $rec;
}



sub northEastToLatLon
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

    my $LONG_SCALE = 0x7fffffff;  # 2147483647
    my $M_PI = 3.14159265358979323846;
    my $M_PI_2 = $M_PI / 2;

    my $longitude = ($east / $LONG_SCALE) * 180.0;
    my $N = $north / $FSH_LAT_SCALE;

    # WGS84 ellipsoid parameters
    my $a = 6378137;  # semi-major axis
    my $e = 0.08181919;  # eccentricity

    # Iterative calculation for latitude
    my $phi = $M_PI_2;  # Initial guess
    my $phi0;
    my $IT_ACCURACY = 1.5E-8;
    my $MAX_IT = 32;
    my $i = 0;

    do {
        $phi0 = $phi;
        my $esin = $e * sin($phi0);
        $phi = $M_PI_2 - 2.0 * atan(exp(-$N / $a) * pow((1 - $esin) / (1 + $esin), $e / 2));
        $i++;
    } while (abs($phi - $phi0) > $IT_ACCURACY && $i < $MAX_IT);

    # Convert radians to degrees
    my $latitude = $phi * 180 / $M_PI;

	my $lat = sprintf("%.6f",$latitude);
	my $lon = sprintf("%.6f",$longitude);

	#display(0,0,"northEastToLatLon($north,$east) ==> $lat,$lon");
	#latLonToNorthEast($lat,$lon);

    return {
        lat => $lat,
        lon => $lon };
}



sub latLonToNorthEast
{
    my ($latitude, $longitude) = @_;

    my $FSH_LAT_SCALE = 107.1709342;
    my $LONG_SCALE = 0x7fffffff;  # 2147483647
		# WEIRD AND INCORRECT

    # Convert latitude to north
    my $north = $latitude * 11901911; # 11891525;	#  $FSH_LAT_SCALE;

    # Convert longitude to east
    my $east = ($longitude / 180.0) * $LONG_SCALE;

	my $n = sprintf("%.6f", $north);
	my $e = sprintf("%.6f", $east);

	display(0,0,"latLonToNorthEast($latitude,$longitude) = $n,$e");

    return {
        north => $n,
        east => $e
    };
}



sub degreesWithMinutes
    # utility to show degrees like the E80,
    # in degrees and decimal minutes.
{
    my ($what,$float_degrees) = @_;
    my $dir_char = $what eq 'lat' ? 'N' : 'E';
    if ($float_degrees < 0)
    {
        $float_degrees = abs($float_degrees);
        $dir_char = $what eq 'lat' ? 'S' : 'W';
    }

    my $degrees = int($float_degrees);
    my $minutes = ($float_degrees - $degrees) * 60;
    $minutes = sprintf("%.3f", $minutes);
    return "$degrees$DEGREE_CHAR$minutes$dir_char";
}




1;  #end of fshUtils.pm
