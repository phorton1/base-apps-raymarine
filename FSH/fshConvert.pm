#-------------------------------------------------------
# This program converts rayMarine ARCHIVE.FSH files
# to Google Earth KML files, or generic GPX gps data files,
# extracting tracks, routes, and waypoints from E80's.

# It is based on the C code at https://github.com/rahra/parsefsh,
# and the info at https://wiki.openstreetmap.org/wiki/ARCHIVE.FSH
#
# With much hassle I was able to get the C code to compile in
# Visuial Studio Code to parsefsh.exe but it didn't work much.
#-------------------------------------------------------
#
# This code mimics the FSH C data structures using perl
# unpack() calls.
#
# ARCHIVE.FSH is made up of 64K chunks called "flobs".
# Each Flob can have "blocks". Really we are only
# interested in parsing the "blocks".
#
# GENERAL NOTE THAT 0.000001 degree of latitude =~ 11cm,
# so six places of accuracy is plenty for floating point coords
#
#---------------------------------------------
# Writing an FSH file
#---------------------------------------------
# Although I can *barely* read an FSH file, ambitiously,
# I want to be able to write them as well, so that I can
# manage waypoints, groups, and routes off of the E80
# with a reasonable UI.  I'm not sure there would ever be a
# **good** purpose to try to upload a track to the E80.


package apps::raymarine::FSH::fshConvert;
use strict;
use warnings;
use Fcntl qw(:seek);
use Time::Local;
use Pub::Utils;
use apps::raymarine::FSH::fshUtils;
use apps::raymarine::FSH::fshFile;
use apps::raymarine::FSH::fshBlocks;
use apps::raymarine::FSH::genGPX;
use apps::raymarine::FSH::genKML;


#---------------------------------------
# main
#---------------------------------------

my $ifilename = "/Archive/Archive.FSH";	# ARCHIVE2_FROM_OLD_E80.FSH";
    # in current directory
my $ofilename = "output/created_from_ARCHIVE_FSH.kml";

my $all_blocks = fshFileToBlocks($ifilename);


if ($all_blocks && processBlocks($all_blocks))
{
	generateGPX($all_blocks,$ofilename) if $ofilename =~ /\.gpx$/i;
	generateKML($all_blocks,$ofilename) if $ofilename =~ /\.kml$/i;
}



1;  #end of fshConvert.pm


