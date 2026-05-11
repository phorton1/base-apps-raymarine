#-------------------------------------------------------
# genKML.pm
#-------------------------------------------------------
# Generates a KML file from $all_blocks

package apps::raymarine::FSH::genKML;
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
		generateKML
	);
}

my $kml;
my $indent_level;

sub inc_level { $indent_level++; }
sub dec_level { $indent_level--; $indent_level=0 if $indent_level<0; }

sub addLine
{
	my ($level,$line) = @_;
	$level += $indent_level;
	while ($level > 0)
	{
		$kml .= "    ";
		$level--;
	}
	$kml .= $line."\n";
}




sub kml_header
	# uses ABGR colors
{
	return <<EOKMLHEADER;
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2"
	xmlns:gx="http://www.google.com/kml/ext/2.2"
	xmlns:kml="http://www.opengis.net/kml/2.2"
	xmlns:atom="http://www.w3.org/2005/Atom">
<Folder>

	<Style id='s_track'>
		<LineStyle>
		  <color>#ffff6666</color>
		  <width>1</width>
		</LineStyle>
		<LabelStyle>
			<scale>0.8</scale>
			<color>#ffff6666</color>
		</LabelStyle>
		<IconStyle>
			<scale>0.8</scale>
			<Icon>
				<href>http://maps.google.com/mapfiles/kml/paddle/wht-blank.png</href>
			</Icon>
			<color>#ffff6666</color>
			<hotSpot x="10" y="2" xunits="pixels" yunits="pixels"/>
		</IconStyle>
	</Style>
	<Style id='s_route'>
		<LineStyle>
		  <color>#ffffff00</color>
		  <width>10</width>
		</LineStyle>
		<LabelStyle>
			<scale>0.8</scale>
			<color>#ffffff00</color>
		</LabelStyle>
		<IconStyle>
			<scale>0.8</scale>
			<Icon>
				<href>http://maps.google.com/mapfiles/kml/paddle/wht-blank.png</href>
			</Icon>
			<color>#ffffff00</color>
			<hotSpot x="10" y="2" xunits="pixels" yunits="pixels"/>
		</IconStyle>
	</Style>
	<Style id='s_waypoint'>
		<LabelStyle>
			<scale>0.8</scale>
			<color>#ff00ff00</color>
		</LabelStyle>
		<IconStyle>
			<scale>0.8</scale>
			<Icon>
				<href>http://maps.google.com/mapfiles/kml/paddle/wht-blank.png</href>
			</Icon>
			<color>#ff00ff00</color>
			<hotSpot x="10" y="2" xunits="pixels" yunits="pixels"/>
		</IconStyle>
	</Style>
	<Style id='s_group'>
		<LabelStyle>
			<scale>0.8</scale>
			<color>#ff00ffff</color>
		</LabelStyle>
		<IconStyle>
			<scale>0.8</scale>
			<Icon>
				<href>http://maps.google.com/mapfiles/kml/paddle/wht-blank.png</href>
			</Icon>
			<color>#ff00ffff</color>
			<hotSpot x="10" y="2" xunits="pixels" yunits="pixels"/>
		</IconStyle>
	</Style>
	<Style id='s_track_del'>
		<LineStyle>
		  <color>#ff808080</color>
		  <width>1</width>
		</LineStyle>
		<LabelStyle>
			<scale>0.8</scale>
			<color>#ff808080</color>
		</LabelStyle>
		<IconStyle>
			<scale>0.8</scale>
			<Icon>
				<href>http://maps.google.com/mapfiles/kml/paddle/wht-blank.png</href>
			</Icon>
			<color>#ff808080</color>
			<hotSpot x="10" y="2" xunits="pixels" yunits="pixels"/>
		</IconStyle>
	</Style>
	<Style id='s_route_del'>
		<LineStyle>
		  <color>#ff808080</color>
		  <width>10</width>
		</LineStyle>
		<LabelStyle>
			<scale>0.8</scale>
			<color>#ff808080</color>
		</LabelStyle>
		<IconStyle>
			<scale>0.8</scale>
			<Icon>
				<href>http://maps.google.com/mapfiles/kml/paddle/wht-blank.png</href>
			</Icon>
			<color>#ff808080</color>
			<hotSpot x="10" y="2" xunits="pixels" yunits="pixels"/>
		</IconStyle>
	</Style>
	<Style id='s_waypoint_del'>
		<LabelStyle>
			<scale>0.8</scale>
			<color>#ff808080</color>
		</LabelStyle>
		<IconStyle>
			<scale>0.8</scale>
			<Icon>
				<href>http://maps.google.com/mapfiles/kml/paddle/wht-blank.png</href>
			</Icon>
			<color>#ff808080</color>
			<hotSpot x="10" y="2" xunits="pixels" yunits="pixels"/>
		</IconStyle>
	</Style>
	<Style id='s_group_del'>
		<LabelStyle>
			<scale>0.8</scale>
			<color>#ff808080</color>
		</LabelStyle>
		<IconStyle>
			<scale>0.8</scale>
			<Icon>
				<href>http://maps.google.com/mapfiles/kml/paddle/wht-blank.png</href>
			</Icon>
			<color>#ff808080</color>
			<hotSpot x="10" y="2" xunits="pixels" yunits="pixels"/>
		</IconStyle>
	</Style>
EOKMLHEADER
}

sub kml_footer
{
	return "</Folder>\n</kml>\n";
}


sub genPlacemark
	# common to all BLK types
	# takes a track_pt with only lat and lon
	# or a full wpt with date, descript, etc.
{
	my ($name,$rec,$style) = @_;
	my $sym_type = 'Flag';
	my $dt = $rec->{date} ? fshDateTimeToStr($rec->{date},$rec->{time}) : '';

	my $descrip = '';
	if ($dt || $rec->{comment})
	{
		$descrip .= '<![CDATA[';
		$descrip .= $rec->{comment} ? $rec->{comment}."<br>" : '';
			# ."<br>" breaks the kml
		$descrip .= "Date: $dt" if $rec->{date};
		$descrip .= ']]>';
	}

	addLine(0,"<Placemark>");
	addLine(1,"<name>$name</name>");
	addLine(1,"<Point>");
	addLine(2,"<coordinates>$rec->{lon},$rec->{lat}</coordinates>");
	addLine(1,"</Point>");
	addLine(1,"<description>$descrip</description>") if $descrip;
	addLine(1,"<TimeStamp><when>$dt</when></TimeStamp>") if $dt;
	addLine(1,"<styleUrl>$style</styleUrl>");
	addLine(0,"</Placemark>");
}


sub genWaypoints
	# from BLK_WPT's
{
	my ($fsh_file) = @_;
	my $wpts = $fsh_file->getWaypoints();
	my (@active, @deleted);
	for my $wpt (@$wpts)
	{
		if ($wpt->{active})
			{ push @active, $wpt; }
		else
			{ push @deleted, $wpt; }
	}
	display(0,0,"generating ".scalar(@$wpts)." waypoints (".scalar(@active)." active, ".scalar(@deleted)." deleted)");
	if (@active || @deleted)
	{
		addLine(0,"<Folder>");
		addLine(1,"<name>Waypoints</name>");
		inc_level();
		for my $wpt (@active)
		{
			genPlacemark($wpt->{name},$wpt,'s_waypoint');
		}
		if (@deleted)
		{
			addLine(0,"<Folder>");
			addLine(1,"<name>Deleted</name>");
			inc_level();
			for my $wpt (@deleted)
			{
				genPlacemark($wpt->{name},$wpt,'s_waypoint_del');
			}
			dec_level();
			addLine(0,"</Folder>");
		}
		dec_level();
		addLine(0,"</Folder>");
	}
}



sub trackHeader
{
	my ($name,$pt,$style) = @_;
	genPlacemark($name,$pt,$style);
	addLine(0,"<Placemark>");
	addLine(1,"<name>$name</name>");;
	addLine(1,"<styleUrl>$style</styleUrl>");
	addLine(1,"<LineString>");
	addLine(2,"<gx:altitudeOffset>0</gx:altitudeOffset>");
	addLine(2,"<extrude>0</extrude>");
	addLine(2,"<tessellate>0</tessellate>");
	addLine(2,"<altitudeMode>clampToGround</altitudeMode>");
	addLine(2,"<gx:drawOrder>0</gx:drawOrder>");
	addLine(2,"<coordinates>");
}


sub trackFooter
{
	addLine(2,"</coordinates>");
	addLine(1,"</LineString>");
	addLine(0,"</Placemark>");
}


sub genTrack
	# from BLK_MTA's combined with BLK_TRK's
{
	my ($track,$style) = @_;
	$style //= 's_track';
	my $name = $track->{name};
	my $points = $track->{points};

	display(0,0,"generating track($name) with ".scalar(@$points)." points");

	# some of my big tracks have occasional lat/lon = -0.0000 in them.
	# this breaks them up into separate segments.

	my $segs = [];
	my $inc_num = '000';
	my $seg = { name=>$name, points=>[] };
	for my $point (@$points)
	{
		if ($point->{lat} =~ /^-0\.00/)
		{
			if (@{$seg->{points}})
			{
				push @$segs,$seg;
				$inc_num++;
				$name = $track->{name}."-$inc_num";
				$seg = { name=>$name, points=>[] };
			}
		}
		else
		{
			push @{$seg->{points}},$point;
		}
	}
	push @$segs,$seg if @{$seg->{points}};
	display(0,1,"found ".scalar(@$segs)." segments") if @$segs>1;

	# Now output a 'track' per segment

	for my $seg (@$segs)
	{
		trackHeader($seg->{name},$seg->{points}->[0],$style);
		for my $point (@{$seg->{points}})
		{
			addLine(3,"$point->{lon},$point->{lat},0");
		}
		trackFooter();
	}
}


sub genTracks
{
	my ($fsh_file) = @_;
	my $tracks = $fsh_file->getTracks();
	my (@active, @deleted);
	for my $track (@$tracks)
	{
		if ($track->{active})
			{ push @active, $track; }
		else
			{ push @deleted, $track; }
	}
	display(0,0,"generating ".scalar(@$tracks)." tracks (".scalar(@active)." active, ".scalar(@deleted)." deleted)");
	if (@active || @deleted)
	{
		addLine(0,"<Folder>");
		addLine(1,"<name>Tracks</name>");
		inc_level();
		for my $track (@active)
		{
			genTrack($track,'s_track');
		}
		if (@deleted)
		{
			addLine(0,"<Folder>");
			addLine(1,"<name>Deleted</name>");
			inc_level();
			for my $track (@deleted)
			{
				genTrack($track,'s_track_del');
			}
			dec_level();
			addLine(0,"</Folder>");
		}
		dec_level();
		addLine(0,"</Folder>");
	}
}




sub genRoute
{
	my ($route,$style) = @_;
	my $wpts = $route->{wpts};
	display(0,0,"generating route($route->{name}) with ".scalar(@$wpts)." waypoints");

	addLine(0,"<Folder>");
	addLine(1,"<name>$route->{name}</name>");
	addLine(1,"<description>$route->{comment}</description>") if $route->{comment};
	inc_level();

	# generate a single placemark for the route linestring
	addLine(0,"<Placemark>");
	addLine(1,"<name>Route</name>");
	addLine(1,"<description>$route->{comment}</description>") if $route->{comment};
	addLine(1,"<styleUrl>$style</styleUrl>");

	addLine(1,"<LineString>");
	addLine(2,"<gx:altitudeOffset>0</gx:altitudeOffset>");
	addLine(2,"<extrude>0</extrude>");
	addLine(2,"<tessellate>0</tessellate>");
	addLine(2,"<altitudeMode>clampToGround</altitudeMode>");
	addLine(2,"<gx:drawOrder>0</gx:drawOrder>");
	addLine(2,"<coordinates>");

	for my $wpt (@$wpts)
	{
		addLine(3,"$wpt->{lon},$wpt->{lat},0");
	}

	addLine(2,"</coordinates>");
	addLine(1,"</LineString>");
	addLine(0,"</Placemark>");

	for my $wpt (@$wpts)
	{
		genPlacemark($wpt->{name},$wpt,$style);
	}
	dec_level();

	addLine(0,"</Folder>");
}

sub genRoutes
{
	my ($fsh_file) = @_;
	my $routes = $fsh_file->getRoutes();
	my (@active, @deleted);
	for my $route (@$routes)
	{
		if ($route->{active})
			{ push @active, $route; }
		else
			{ push @deleted, $route; }
	}
	display(0,0,"generating ".scalar(@$routes)." routes (".scalar(@active)." active, ".scalar(@deleted)." deleted)");
	if (@active || @deleted)
	{
		addLine(0,"<Folder>");
		addLine(1,"<name>Routes</name>");
		inc_level();
		for my $route (@active)
		{
			genRoute($route,'s_route');
		}
		if (@deleted)
		{
			addLine(0,"<Folder>");
			addLine(1,"<name>Deleted</name>");
			inc_level();
			for my $route (@deleted)
			{
				genRoute($route,'s_route_del');
			}
			dec_level();
			addLine(0,"</Folder>");
		}
		dec_level();
		addLine(0,"</Folder>");
	}
}



sub genGroup
	# GPX does not have an explicit GROUP mechanism, so, for now,
	# i'm just going to create a route with a name of GROUP-{name}
{
	my ($group,$style) = @_;
	my $wpts = $group->{wpts};
	display(0,0,"generating group($group->{name}) with ".scalar(@$wpts)." waypoints");

	addLine(0,"<Folder>");
	addLine(1,"<name>$group->{name}</name>");
	inc_level();
	for my $wpt (@$wpts)
	{
		genPlacemark($wpt->{name},$wpt,$style);
	}
	dec_level();

	addLine(0,"</Folder>");
}

sub genGroups
{
	my ($fsh_file) = @_;
	my $groups = $fsh_file->getGroups();
	my (@active, @deleted);
	for my $group (@$groups)
	{
		if ($group->{active})
			{ push @active, $group; }
		else
			{ push @deleted, $group; }
	}
	display(0,0,"generating ".scalar(@$groups)." groups (".scalar(@active)." active, ".scalar(@deleted)." deleted)");
	if (@active || @deleted)
	{
		addLine(0,"<Folder>");
		addLine(1,"<name>Groups</name>");
		inc_level();
		for my $group (@active)
		{
			next if $group->{name} =~ /^test/;  # DEBUGGING
			genGroup($group,'s_group');
		}
		if (@deleted)
		{
			addLine(0,"<Folder>");
			addLine(1,"<name>Deleted</name>");
			inc_level();
			for my $group (@deleted)
			{
				genGroup($group,'s_group_del');
			}
			dec_level();
			addLine(0,"</Folder>");
		}
		dec_level();
		addLine(0,"</Folder>");
	}
}



sub generateKML
{
	my ($fsh_file,$ofilename) = @_;
	$kml = kml_header();
	$indent_level = 1;
	display(0,0,"generateKML($ofilename) ...");
	addLine(0,"<name>$ofilename</name>");
	genGroups($fsh_file);
	genRoutes($fsh_file);
	genWaypoints($fsh_file);
	genTracks($fsh_file);
	$kml .= kml_footer();
	printVarToFile(1,$ofilename,$kml,1);
}



1;  #end of genKML.pm
