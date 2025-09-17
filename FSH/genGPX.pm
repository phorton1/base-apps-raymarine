#-------------------------------------------------------
# genGPX.pm
#-------------------------------------------------------
# Generates a GPX file from $all_blocks

package apps::raymarine::FSH::genGPX;
use strict;
use warnings;
use Fcntl qw(:seek);
use Time::Local;
use Pub::Utils;
use apps::raymarine::FSH::fshUtils;
use apps::raymarine::FSH::fshFile;
use apps::raymarine::FSH::fshBlocks;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
		generateGPX
	);
}

my $gpx = gpx_header();
my $gpx_level = 1;

sub inc_gpx_level { $gpx_level++; }
sub dec_gpx_level { $gpx_level--; $gpx_level=0 if $gpx_level<0; }

sub addGpxLine
{
	my ($level,$line) = @_;
	$level += $gpx_level;
	while ($level > 0)
	{
		$gpx .= "    ";
		$level--;
	}
	$gpx .= $line."\n";
}




sub gpx_header
{
	return
		"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n".
        "<gpx xmlns=\"http://www.topografix.com/GPX/1/1\" creator=\"parsefsh\" version=\"1.1\"\n".
         "   xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"\n".
         "   xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd\">\n";
}

sub gpx_footer
{
	return "</gpx>\n";
}


sub genWaypoint
	# common to BLK_WPT, BLK_RTE, and BLK_GRP
{
	my ($kind,$wpt) = @_;
	my $sym_type = 'Flag';
	my $dt = fshDateTimeToStr($wpt->{date},$wpt->{time});

	addGpxLine(0,"<$kind lat=\"$wpt->{lat}\" lon=\"$wpt->{lon}\">");
	addGpxLine(1,"<name>$wpt->{name}</name>");
	addGpxLine(1,"<cmt>$wpt->{comment}</cmt>") if $wpt->{comment};
	addGpxLine(1,"<src>fshConvert.pm</src>");
	addGpxLine(1,"<sym>$sym_type</sym>");
	addGpxLine(1,"<time>$dt</time>");
	addGpxLine(0,"</$kind>");
}

sub genWaypoints
	# from BLK_WPT's
{
	my $wpts = getWaypoints();
	display(0,0,"generating ".scalar(@$wpts)." waypoints");
	for my $wpt (@$wpts)
	{
		genWaypoint('wpt',$wpt);
	}
}



sub genTrack
	# from BLK_MTA's combined with BLK_TRK's
{
	my ($track) = @_;
	my $points = $track->{points};
	display(0,0,"generating track($track->{name}) with ".scalar(@$points)." points");

	addGpxLine(0,"<trk>");
	addGpxLine(1,"<name>$track->{name}</name>");
	addGpxLine(1,"<trkseg>");

	my $inc_num = '000';


	for my $point (@$points)
	{
		my $lat = $point->{lat};

		# some of my big tracks have occasional lat/lon = -0.0000 in them.
		# My first idea was to break them up into separate trksegs, but they show up as
		# many same-named things in GE.  I think for GE I really probably want
		# to output a KML, since that's a verys specific format.

		# for going to GE it would be bet
		if ($lat =~ /^-0\.00/)
		{
			if (1)	# create a new serialized entire track
			{
				$inc_num++;
				addGpxLine(1,"</trkseg>");
				addGpxLine(0,"</trk>");
				addGpxLine(0,"<trk>");
				addGpxLine(1,"<name>$track->{name}-$inc_num</name>");
				addGpxLine(1,"<trkseg>");
			}
			else	# just create a new track seg
			{
				addGpxLine(1,"</trkseg>");
				addGpxLine(1,"<trkseg>");
			}
		}
		else
		{
			addGpxLine(2,"<trkpt lat=\"$lat\" lon=\"$point->{lon}\"></trkpt>");
		}
	}
	addGpxLine(1,"</trkseg>");
	addGpxLine(0,"</trk>");
}

sub genTracks
{
	my $tracks = getTracks();
	display(0,0,"generating ".scalar(@$tracks)." tracks");
	for my $track (@$tracks)
	{
		genTrack($track);
	}
}




sub genRoute
{
	my ($route) = @_;
	my $wpts = $route->{wpts};
	display(0,0,"generating route($route->{name}) with ".scalar(@$wpts)." waypoints");

	addGpxLine(0,"<rte>");
	addGpxLine(1,"<name>$route->{name}</name>");
	addGpxLine(1,"<cmt>$route->{comment}</cmt>") if $route->{comment};

	inc_gpx_level();

	for my $wpt (@$wpts)
	{
		genWaypoint('rtept',$wpt);
	}
	dec_gpx_level();

	addGpxLine(0,"</rte>");
}

sub genRoutes
{
	my $routes = getRoutes();
	display(0,0,"generating ".scalar(@$routes)." routes");
	for my $route (@$routes)
	{
		genRoute($route);
	}
}



sub genGroup
	# GPX does not have an explicit GROUP mechanism, so, for now,
	# i'm just going to create a route with a name of GROUP-{name}
{
	my ($group) = @_;
	my $wpts = $group->{wpts};
	display(0,0,"generating group($group->{name}) with ".scalar(@$wpts)." waypoints");

	addGpxLine(0,"<rte>");
	addGpxLine(1,"<name>GROUP-$group->{name}</name>");
	inc_gpx_level();
	for my $wpt (@$wpts)
	{
		genWaypoint('rtept',$wpt);
	}
	dec_gpx_level();

	addGpxLine(0,"</rte>");
}

sub genGroups
{
	my $groups = getGroups();
	display(0,0,"generating ".scalar(@$groups)." groups");
	for my $group (@$groups)
	{
		genGroup($group);
	}
}



sub generateGPX
{
	my ($all_blocks,$ofilename) = @_;
	display(0,0,"generateGPX($ofilename) ...");
	genGroups();
	genRoutes();
	genWaypoints();
	genTracks();
	$gpx .= gpx_footer();
	printVarToFile(1,$ofilename,$gpx,1);
}



1;  #end of genGPX.pm
