#-----------------------------------------
# kmlToCSV.pm
#-----------------------------------------
# Parses Navigation.kml folder saved from Google Earth,
# which contains Waypoints and Routes Folders and produces
# a CSV file that can be imported into Raytech RNS and saved
# as an ARCHIVE.FSH that can be uploaded to the E80 on CF card.
#
# The Waypoints folder can contain sub folders that come out as
# separate Waypoint Groups on the E80. Any Placemark in the
# outer Waypoints folder are put into the E80 "My Waypoints"
# group.
#
# The Routes Folder contains subfolders that are the routes.
# It appears as if the way E80 Routes in CSV files work is
# that they are generated first as Waypoint groups, and then
# there is a route header, followed by the routes points
# within the route.
#
# This means that is impossible to generate routes without
# also generating a group of waypoints. If desired, the
# waypoint groups can be deleted in Raytech before moving
# to the E80, or on the E80 itself.
#
# Additionally outputs a ge_routes.h file that can be
# manually copied to the /src/Arduino/ NMEA0183 simulator
# directory to synchronize the simulator with the E80.

package apps::raymarine::CSV::kmlToCSV;
use strict;
use warnings;
use XML::Simple;
use Data::Dumper;
use Pub::Utils;

$Data::Dumper::Indent = 1;
$Data::Dumper::Sortkeys = 1;

my $xmlsimple = XML::Simple->new(
	KeyAttr => [],						# don't convert arrays with 'id' members to hashes by id
	ForceArray => [						# identifiers that we want to always be arrayed
		'Folder',
		'Placemark',
	],
	SuppressEmpty => '',				# empty elements will return ''
);


#--------------------------
# vars
#--------------------------

my $ifilename = "input/Navigation.kml";
	# This is tghe name of a folder in GE that is exported as
	# a single KML file that contains all of my official RWT
	# (Routes, Waypoints, and Tracks) that will be converted
	# into a Raymarine CSV file containing Routes, Waypoints,
	# and Waypoint Groups analagous to Folders,
my $ofilename = "output/Navigation.text";
	# The output CSV file is called Navigation.txt,
	# because its easier to navigate to in Raytech RNS
	# than Navigaation.csv
my $hfilename = "output/ge_routes.h";
	# to be manually copied to /src/Arduino NMEA0183 simulator
	

# parsed routes and waypoints

my $unique_id = 0;
my $waypoints = [];
my $routes = {};
my $route_points = [];


# Raymarine Symbol Numbers
# Grumble MF - the symbols are different on the E80
# and who knows if they are mapped in Raytech->ARCHIVE.FSH
#																				0	circle with exclamation				bocas
#                                                                         		1	circle with exclamation				popa0
#                                                                               2	circle with exclamation
#	RED_SQUARE			=  3;		# 2 concentric red square outlines          3 	square
#	BIG_FISH			=  4;		# blue fish jumping left                    4   left fish
#	ANCHOR				=  5;		# black anchor                              5   anchor
#	SMILEY				=  6;		# yellow filled smily face                  6	X									popa5
#	SAD					=  7;		# green filled sad face                     7	X
#	RED_BUTTON			=  8;		# black outline red filled medium circle    8	circle with exclamation
#	SAILFISH			=  9;		# blue fish jumping right                   9	fish jumping out of water
#	DANGER				= 10;		# black skull and cross bones               10	skull and cross bones
#	ATTENTION			= 11;		# red circle with exclamation point         11  circle with exclamation				popa10
#	BLACK_SQUARE		= 12;		# 2 concentric black square outlines        12	square								m001
#	INTL_DIVE_FLAG		= 13;		# white and blue right facing pendant       13	blue and white flag to right
#	VESSEL				= 14;		# blue sailboat                             14  sailboat
#	LOBSTER				= 15;		# black lobster                             15  crab
#	BUOY				= 16;		# red leaning right thing                   16  filled rounded triangle				m005
#	EXCLAMATION			= 17;		# black exclamation mark                    17  circle with exclamation
#	RED_X				= 18;		# big red X                                 17	X
#	CHECK_MARK			= 19;		# green check mark                          18  X
#	BLACK_PLUS			= 20;		# smaller black plus                        20  X
#	BLACK_CROSS			= 21;		# big black X                               21  X									m010
#	MOB					= 22;		# small red circle outline                  22  circle with M
#	BILLFISH			= 23;		# red fish jumping right                    23  fish jumping out of water
#	BOTTOM_MARK			= 24;		# red triangle with something in it         24  triangle with something in it
#	CIRCLE				= 25;		# bigger red circle outline                 25  circle
#	DIAMOND				= 26;		# filled red diamond                        26  filled diamond						m015
#	DIAMOND_QUARTERS	= 27;		# odd 1/2 filled red diamond                27  shaded diamond
#	DIVE_FLAG			= 28;		# red flag to right with white strop        28	dive flag to right
#	DOLPHIN				= 29;		# red fish jumping right                    29  dolphin jumping out of water
#	FEW_FISH			= 30;		# red rish swimming with bubble             30  left fish with one asterisk
#	MULTIPLE_FISH		= 31;		# red fish swimming with more bubbles       31  left fish with two asterisks		m020
#	MANY_FISH			= 32;		# red fish swimming with most bubbles       32  left fisih with three astericks
#	SINGLE_FISH			= 33;		# red fish swimming                         33  big left fish
#	SMALL_FISH			= 34;		# smaller red fish swiming                  34  smaller left fish
#	RED_H				= 35;		# red H in circle                           35  circle with m in it
#	COCKTAIL			= 36;		# red cocktail glass                        36  cocktail							m025
#	RED_BOX				= 37;		# big red box outlne with X in it           37  square with X in it
#	REEF				= 38;		# some weird red drawing                    38  sea grass with fish?
#	ROCKS				= 39;		# looks like a red rain cloud               39  clouds?
#	FISH_SCHOOL			= 40;		# two red fish swimming opposite            40  two fish swimming left/right
#	SEAWEED				= 41;		# red strings from bottom t                 41  sea grass							m030
#	SHARK				= 42;		# bigger? red fish swimming left            42  shark swimming left
#	SPORTFISHER			= 43;		# red boat with two sticks t                43  trawler going right
#	SWIMMER				= 44;		# red swimmer in water                      44  person swimming
#	TOP_MARK			= 45;		# down pointing red triangle T in it        45  upside down triangle with T
#	TRAWLER				= 46;		# red boat, sort of                         46  boat maybe military right			m035
#	TREE				= 47;		# looks like red arrowish below line        47  something under a squiggle
#	TRIANGLE			= 48;		# red triangle, slightly thicker            48  red triangle
#	WRECK             	= 49;		# red boat sinking                          49  sinking boat						m038


# Winnowed down to those that appear usable on E80, more or less in order they are presented on E80

my $SYM_X					= 18;		# big red X                                 17	circle with exclamation
my $SYM_CIRCLE				= 25;		# bigger red circle outline                 25  circle
my $SYM_SQUARE				=  3;		# 2 concentric red square outlines          3 	square
my $SYM_TRIANGLE			= 48;		# red triangle, slightly thicker            48  red triangle
my $SYM_DIAMOND				= 26;		# filled red diamond                        26  filled diamond						m015
my $SYM_DIAMOND_QUARTERS	= 27;		# odd 1/2 filled red diamond                27  shaded diamond
my $SYM_ANCHOR				=  5;		# black anchor                              5   anchor
my $SYM_DANGER				= 10;		# black skull and cross bones               10	skull and cross bones
my $SYM_SQUARE_WITH_X		= 37;		# big red box outlne with X in it           37  square with X in it
my $SYM_TRI_DOWN_WITH_T		= 45;		# down pointing red triangle T in it        45  upside down triangle with T
my $SYM_SAILBOAT			= 14;		# blue sailboat                             14  sailboat
my $SYM_WRECK             	= 49;		# red boat sinking                          49  sinking boat						m038
my $SYM_SWIMMER				= 44;		# red swimmer in water                      44  person swimming
my $SYM_EXCLAMATION			= 17;		# black exclamation mark                    17  circle with exclamation
my $SYM_REEF				= 38;		# some weird red drawing                    38  sea grass with fish?
my $SYM_SEAWEED				= 41;		# red strings from bottom t                 41  sea grass							m030
my $SYM_DIVE_FLAG			= 28;		# red flag to right with white strop        28	dive flag to right
my $SYM_BLUE_DIVE_FLAG		= 13;		# white and blue right facing pendant       13	blue and white flag to right
my $SYM_BIG_FISH			= 33;		# red fish swimming                         33  big left fish
my $SYM_SMALL_FISH			= 34;		# smaller red fish swiming                  34  smaller left fish
my $SYM_FISH_ONE_ASTERISK	= 30;		# red rish swimming with bubble             30  left fish with one asterisk
my $SYM_FISH_TWO_ASTERISK	= 31;		# red fish swimming with more bubbles       31  left fish with two asterisks		m020
my $SYM_FISH_THREE_ASTERISK = 32;		# red fish swimming with most bubbles       32  left fisih with three astericks
my $SYM_TWO_FISH			= 40;		# two red fish swimming opposite            40  two fish swimming left/right
my $SYM_SAILFISH			=  9;		# blue fish jumping right                   9	fish jumping out of water
my $SYM_DOLPHIN				= 29;		# red fish jumping right                    29  dolphin jumping out of water
my $SYM_SHARK				= 42;		# bigger? red fish swimming left            42  shark swimming left
my $SYM_LOBSTER				= 15;		# black lobster                             15  crab
my $SYM_SPORTFISHER			= 43;		# red boat with two sticks t                43  trawler going right
my $SYM_TRAWLER				= 46;		# red boat, sort of                         46  boat maybe military right			m035



#----------------------------------------------------------
# parse
#----------------------------------------------------------

sub parseInputFile
{
	my $kml = parseKML($ifilename);
	exit(0) if !$kml;

	my $nav_folder = $kml->{Document}->{Folder}[0];
	if (!$nav_folder)
	{
		error("No folders in $ifilename");
		exit(0);
	}

	if ($nav_folder->{name} ne "Navigation")
	{
		error("Expected 'Navigation', found found folder '$nav_folder->{name}'");
		exit(0);
	}

	my $folders = $nav_folder->{Folder};
	for my $folder (@$folders)
	{
		display(0,1,"Folder($folder->{name})");
		if ($folder->{name} eq 'Routes')
		{
			my $route_folders= $folder->{Folder};
			for my $route (@$route_folders)
			{
				my $route_name = $route->{name};
				my $num_points = addPoints("route_points",$route_points,$route_name,$route->{Placemark});
				$routes->{$route_name} = {
					num_points => $num_points,
					unique_id => $unique_id++ };
			}
		}
		elsif ($folder->{name} eq 'Waypoints')
		{
			my $groups = $folder->{Folder};
			for my $group (@$groups)
			{
				addPoints('waypoints',$waypoints,$group->{name},$group->{Placemark});
			}

			addPoints('waypoints',$waypoints,'My Waypoints',$folder->{Placemark})
				if ($folder->{Placemark})
		}
		else
		{
			warning(0,1,"Unexpected outer level folder($folder->{name})");
		}
	}
}


sub addPoints
{
	my ($what,$array,$group_name, $marks) = @_;
	display(0,1,"adding ".scalar(@$marks)." points for $what($group_name)");
	my $num = 0;
	my $num_marks = @$marks;
	for my $mark (@$marks)
	{
		my $name = $mark->{name};
		next if $name eq 'Route';
			# skip the lineString I put on some of my routes

		$num++;

		# 'My Waypoints' are big red X's
		# Group waypoints are smaller red triangles
		
		my $sym = $group_name eq 'My Waypoints' ?
			$SYM_X : $SYM_CIRCLE;
		if ($what eq 'route_points')
		{
			$sym =
				$num == 1 ? $SYM_SQUARE :					# red square starts a route
				$num == $num_marks ? $SYM_SQUARE_WITH_X :	# sqyare with X ends a route
				$SYM_TRIANGLE;								# intermediate waypoints are triangles
		}
		
		my ($lon,$lat) = split(/,/,$mark->{Point}->{coordinates});
		my $ts = '';
		$ts = $mark->{TimeStamp}->{when} if $mark->{TimeStamp} && $mark->{TimeStamp}->{when};
		$lat = sprintf("%.6f",$lat);
		$lon = sprintf("%.6f",$lon);
		display(0,2,"mark($name) $lat,$lon  ts=$ts");
		push @$array,{
			group => $group_name,
			name => $name,
			lat => $lat,
			lon => $lon,
			ts => $ts,
			unique_id => $unique_id++,
			sym => $sym };
	}
	return $num;
}




#-------------------------------------------
# low level XML parser
#-------------------------------------------

sub parseKML
{
	my ($filename) = @_;
	my $data = getTextFile($filename,1);
	display(0,0,"parseKML($filename) bytes=".length($data),1);

    my $xml;
    eval { $xml = $xmlsimple->XMLin($data) };
    if ($@)
    {
        error("Unable to parse xml from $filename:".$@);
        return;
    }
	if (!$xml)
	{
		error("Empty xml from $filename!!");
		return;
	}

	if (0)
	{
		my $mine = myDumper($xml,1);
		print $mine."\n";
	}

	if (0)
	{
		my $ddd =
			"-------------------------------------------------\n".
			Dumper($xml).
			"-------------------------------------------------\n";
		print $ddd."\n";
	}

	return $xml;
}


sub myDumper
{
	my ($obj,$level,$started) = @_;
	$level ||= 0;
	$started ||= 0;

	my $text;
	my $retval = '';
	$retval .= "-------------------------------------------------\n"
		if !$level;

	if ($obj =~ /ARRAY/)
	{
		$retval .= indent($level)."[\n";
		for my $ele (@$obj)
		{
			$retval .= myDumper($ele,$level+1,1);
		}

		$retval .= indent($level)."]\n";
	}
	elsif ($obj =~ /HASH/)
	{
		$started ?
			$retval .= indent($level) :
			$retval .= ' ';
		$retval .= "{\n";
		for my $k (keys(%$obj))
		{
			my $val = $obj->{$k};
			$retval .= indent($level+1)."$k =>";
			$retval .= myDumper($val,$level+2,0);
		}
		$retval .= indent($level)."}\n";
	}
	else
	{
		my @lines = split(/\n/,$obj);
		for my $line (@lines)
		{
			$retval .= indent($level) if $started;
			$started = 1;
			$retval .= "'$line'\n";
		}
	}

	$retval .= "-------------------------------------------------\n"
		if !$level;
	return $retval;
}


sub indent
{
	my ($level) = @_;
	$level = 0 if $level < 0;
	my $txt = '';
	while ($level--) {$txt .= "  ";}
	return $txt;
}


#-----------------------------------------------
# generateCSV
#-----------------------------------------------
# The raymarine CSV file
#
#	- requires the stupid header
#	- requires unique guids
#	- requires at least enough commas to get to the guid
#   - probably requires other fields
#   - i dont have time to narrow it down accurately

sub stupidHeader
{
return <<EOSTUPID;
*********** RAYTECH WAPOINT AND ROUTE TXT FILE --DO NOT EDIT THIS LINE!!!! ***********
*********** The first 10 lines of this file are reserved *****************
*********** The waypoint data is comma delimited in the order of: ***********
*********** Loc,Name,Lat,Long,Rng,Bear,Bmp,Fixed,Locked,Notes,Rel,RelSet,RcCount,RcRadius,Show,RcShow,SeaTemp,Depth,Time,MarkedForTransfer,GUID*********
*********** Following the waypoint data is the route data: ********
*********** Route data is also comma delimited in the order of:***********
*********** RouteName,Visible,MarkedForTransfer,NumMarks, Guid***********
*********** MarkName,Cog,Eta,Length,PredictedDrift,PredictedSet,PredictedSog,PredictedTime,PredictedTwa,PredictedTwd,PredictedTws***********
*****************************************************************************************************************
************************************ END HEADER ****************************************************************
EOSTUPID
}


# comments from https://www.justanswer.com/marine-electronics/8lwrr-transfer-waypoints-excel-spreadsheet-new.html
#	Field 1: Loc (Folder Name),
#	Field 2: Name (Waypoint Name),
#	Field 3: Lat (deg; negative values are used to represent south latitudes),
#	Field 4: Lon (deg; negative values are used to represent west longitudes),
#	Field 5: Rng (Range to relative waypoint (nm); Optional - default to 0.0),
#	Field 6: Bear (Bearing to relative waypoint (deg); Optional - default to 0.0),
#	Field 7: Bmp (Waypoint Symbol),
#	Field 8: Fixed (0=Fixed, 1=Relative, default to 0),
#	Field 9: Locked (0=No, 1=Yes; default to 0),
#	Field 10: Notes (Character String; optional – default to “”),
#	Field 11: Rel (Relative Waypoint Name; optional – default to “”),
#	Field 12: RelSet (0=???, 1=???; optional – default to 0),
#	Field 13: RcCount (Number of Range Circles; optional – default to 0),
#	Field 14: RcRadius (Range Circle Radius (nm); optional – default to 0.0),
#	Field 15: Show (0=No, 1=Yes; optional – default to 0),
#	Field 16: RcShow (Range Circles: 0=No, 1=Yes; optional – default to 0),
#	Field 17: SeaTemp (degrees C; optional – default to 0.0),
#	Field 18: Depth (meters; optional – default to 0.0),
#	Field 19: Time (Timestamp; optional),
#	Field 20: MarkedForTransfer (0=No, 1=Yes; optional – default to 0),
#	Field 21: GUID (Globally Unique Identifier (This field should be left null))

# Example from export in the middle of isla colon
# My Waypoints,Wp,9.397492848046962,-82.283214210064997,0.000000000000000,0.000000000000000,3,1,0,,,0,1,0.000000000000000,1,0,-32678.000000000000000,65535.000000000000000,45782.643993055557000,1,36582-26613-33881-33476


my $csv = stupidHeader();


sub generateWPTS
{
	my ($name,$points) = @_;

	display(0,0,"generating($name) ".scalar(@$points)." points");
	
	my $num = 0;
	for my $wpt (@$points)
	{
		# "Loc,Name,Lat,Long,Rng,Bear,Bmp,Fixed,Locked,Notes,Rel,RelSet,RcCount,RcRadius,Show,RcShow,SeaTemp,Depth,Time,MarkedForTransfer,GUID";

		my $rng 	= '0.0';
		my $bear 	= '0.0';
		my $bmp 	= $wpt->{sym};	# bmp = symbol
		my $fixed 	= '0';		# 1, otherwise it's 'relative' whatever that means
		my $locked 	= '0';
		my $notes 	= '';
		my $rel		= '';
		my $relset 	= '0';
		my $rc_cnt	= '0';
		my $rc_rad	= '0.0';
		my $show	= '0';
		my $rc_show	= '0';
		my $temp	= '0.0';
		my $depth	= '0.0';
		my $xfer 	= '1';
		my $guid 	= $wpt->{unique_id};

		# I believe that the raymarine is using Jan 1, 1900 as the epoch for fractional days
		# gmtToInt() is unix time since Jan 1, 1970.  They differ by 25670 days.

		my $use_ts 	= '';
		if (0)
		{
			$use_ts = gmtToInt($wpt->{ts}) / (3600 * 24);
			$use_ts += 25670;
		}

		$csv .= "$wpt->{group},$wpt->{name},$wpt->{lat},$wpt->{lon},".
				# "0.000000000000000,0.000000000000000,3,1,0,,,0,1,0.000000000000000,1,0,-32678.000000000000000,65535.000000000000000,45782.643993055557000,1,$guid\n";
				"$rng,$bear,$bmp,$fixed,$locked,$notes,$rel,$relset,$rc_cnt,$rc_rad,$show,$rc_show,$temp,$depth,$use_ts,$xfer,$guid\n";
	}
}



sub generateRoutes
{
	my $route_name = '';
	for my $point (@$route_points)
	{
		if ($route_name ne $point->{group})		# new route header
		{
			$route_name = $point->{group};
			my $route = $routes->{$route_name};
			# RouteName,Visible,MarkedForTransfer,NumMarks, Guid***********
			$csv .= "$route_name,0,1,$route->{num_points},$route->{unique_id}\n";
		}
		# and the route points are 'inactive' place keepers
		# MarkName,Cog,Eta,Length,PredictedDrift,PredictedSet,PredictedSog,PredictedTime,PredictedTwa,PredictedTwd,PredictedTws
		$csv .= "$point->{name},0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0\n";
	}
}


#--------------------------------------------------
# ge_routes_h
#--------------------------------------------------

sub ge_header
{
return <<EOGEHEADER;
//--------------------------------------------------
// ge_routes.h
//--------------------------------------------------
// Automatically generated by /base/bat/raymarineE80/kmlToCSV.pm
// from the Navigation.kml exported from googleEarth and
// manually normalized to this folder.
//
// Only included into simulator.cpp

EOGEHEADER
}


sub ge_points_header
{
	my ($route_name) = @_;
	my $array_name = $route_name."_waypoints";
	my $header = "static const waypoint_t $array_name\[] =\n";
	$header .= "{\n";
	return $header;
}



sub ge_routes_h
{
	my $points_part = '';
	my $routes_part = "\n\nstatic const route_t routes[] =\n";
	$routes_part .= "{\n";
	
	my $num_routes = 0;
	my $route_name = '';
	for my $point (@$route_points)
	{
		if ($route_name ne $point->{group})		# new route header
		{
			$num_routes++;
			$points_part .= "};\n\n" if $route_name;

			$route_name = $point->{group};
			$points_part .= ge_points_header($route_name);
			
			my $route = $routes->{$route_name};
			my $array_name = $route_name ."_waypoints";
			my $qp_route_name = pad("\"$route_name\",",20);
			my $qp_array_name = pad("$array_name,",30);

			$routes_part .= "    { $qp_route_name $qp_array_name $route->{num_points} },\n";
		}

		my $qp_point_name = pad("\"$point->{name}\",",12);
		$points_part .= "    { $qp_point_name $point->{lat}, $point->{lon} },\n";
	}

	$points_part .= "};\n\n";
	$routes_part .= "};\n\n";

	return ge_header().$points_part.$routes_part.
		"#define NUM_ROUTES $num_routes\n\n\n";
}





#-------------------------------------------------
# main
#-------------------------------------------------

parseInputFile();


generateWPTS('waypoints',$waypoints);
generateWPTS('route_points',$route_points);
generateRoutes();

display(0,0,"Writing ".length($csv)." bytes to $ofilename");
printVarToFile(1,$ofilename,$csv,1);

my $text = ge_routes_h();
display(0,0,"Writing ".length($text)." bytes to $hfilename");
printVarToFile(1,$hfilename,$text,1);


1;
