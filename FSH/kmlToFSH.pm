#-----------------------------------------
# kmlToFSH.pm
#-----------------------------------------
# Conventions
#
# KML files parsed by this program shall consist of a <Document> element,
# within which there are three primary named <Folders>, GROUPS, ROUTES.
# and TRACKS (case insenstive). Groups and Routes consist of sub-folders
# within which exist Waypoints.
#
# The Tracks folder contains one <Placemark> element for each Track.
#
#	<Name>
#		The name of the track, truncated to 15 characters for Raymarine.
#   <LineString><coordinates>
#		A series of whitespace delimited triplets consisting of
#		lon,lat,depth, although historically the depth has not
#		been consistently recorded and is likely not meaningful
#	<ExtendedData>
#	  <Data name="mta_uuid"><value>dddd-dddd-dddd-0001</value></Data>
#	  <Data name="trk_uuid"><value>dddd-dddd-ddde-0001</value></Data>
#	  <Data name="line_color"><value>1</value></Data>
#	</ExtendedData>
#
#	Specifies the MTA and TRK uuids that will be put in the FSH file,
#   	linking them together. along with attributes of the MTA,
#		at this time, the Raymarine color constant for the line
#		(which should maatch the GE styling I have previously created
#       but which temporarily doesn't)



package apps::raymarine::FSH::kmlToFSH;
use strict;
use warnings;
use XML::Simple;
use Data::Dumper;
use Pub::Utils;
use apps::raymarine::FSH::fshUtils;
use apps::raymarine::FSH::fshBlocks;
use apps::raymarine::FSH::fshFile;

$Data::Dumper::Indent = 1;
$Data::Dumper::Sortkeys = 1;

my $xmlsimple = XML::Simple->new(
	KeyAttr => [],						# don't convert arrays with 'id' members to hashes by id
	ForceArray => [						# identifiers that we want to always be arrayed
		'Placemark',
		'Data',
	],
	SuppressEmpty => '',				# empty elements will return ''
);



sub parseKML
	# shows debugging at $dbg
	# shows input and output at $dbg_details
	# dumps raw.txt, pretty.txt, and xml.txt if $dump
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



# Raymarine Symbol Numbers
#
#  0	illegal				red square
#  1	blank				red square
#  2	Red Square			2 concentrick red square outlines
#  3	Big Fish			blue fish jumping left
#  4	Anchor				black anchor
#  5	Smiley				yellow filled smily face
#  6	Sad					green filled sad face
#  7	Red Button			black outline red filled medium circle
#  8	Sailfish			blue fish jumping right
#  9	Danger				black skull and cross bones
# 10	Attention			red circle with exclamation point
# 11	Black Square		2 concentric black square outlines
# 12	Intl Dive Flag		white and blue right facing pendant
# 13	Vessel				blue sailboat
# 14	Lobster				black lobster
# 15	Buoy				red leaning right thing
# 16	Exclamation			black exclamation mark
# 17	Red X				big red X
# 18	Check Mark			green check mark
# 19	Black Plus			smaller black plus
# 20  	Black Cross			big black X
# 21 	MOB					small red circle outline
# 22 	Billfish			red fish jumping right
# 23 	Bottom Mark			red triangle with something in it
# 24 	Circle				bigger red circle outline
# 25 	Diamond				filled red diamond
# 26 	Diamond Quarters	odd 1/2 filled red diamond
# 27 	U.S. Dive Flag		red flag to right with white strop
# 28 	Dolphin				red fish jumping right
# 29 	Few Fish			red rish swimming with bubble
# 30 	Multple Fish		red fish swimming with more bubbles
# 31 	Many Fish			red fish swimming with most bubbles
# 32 	Single Fish			red fish swimming
# 33 	Small Fish			smaller red fish swiming
# 34 	Marker				red H in circle
# 35 	Cocktail			red cocktail glass
# 36 	Red Box Marker		big red box outlne with X in it
# 37 	Reef				some weird red drawing
# 38 	Rocks				looks like a red rain cloud
# 39 	Fish School			two red fish swimming opposite directions
# 40 	Seaweed				red strings from bottom left to upper right
# 41 	Shark				bigger? red fish swimming left
# 42 	Sportfisher			red drawing of something with two sticks from center to upper left
# 43 	Swimmer				red swimmer in water
# 44 	Top Mark			down pointing red triangle with something in it
# 45 	Trawler				red boat, sort of
# 46 	Tree				looks like red arrowish pointing up towards line
# 47 	Triangle			red triangle, slightly thicker, standing normal
# 48 	Wreck             	red boat sinking from upper right to lower left
# 49+   blank				2 concentric red squares


#-------------------------------------------------
# kml utilities
#-------------------------------------------------


sub extractData
{
	my ($ele,$required) = @_;
	my $data = {};
	if ($ele && $ele->{Data})
	{
		for my $value_pair (@{$ele->{Data}})
		{
			$data->{$value_pair->{name}} = $value_pair->{value};
		}
		for my $req (@$required)
		{
			if (!defined($data->{$req}))
			{
				warning(0,0,"missing required Data($req)");
				$data->{$req} = '';
			}
		}
	}
	else
	{
		error("missing or empty ExtendedData element");
	}
	return $data;
}



sub extractPoints
{
	my ($line_string) = @_;
	my $points = [];
	if ($line_string && $line_string->{coordinates})
	{
		my $string = $line_string->{coordinates};
		$string =~ s/^\s+|\s+$//g;
		for my $part (split(/\s+/,$string))
		{
			my ($lon,$lat,$depth) = split(/,/,$part);
			push @$points,{
				lat => $lat,
				lon => $lon,
				depth => $depth};
		}
		warning(0,0,"empty LineString coordinates") if !@$points;
	}
	else
	{
		error("missing or empty LineString element");
	}
	return $points;
}



#-------------------------------------------------
# tracks
#-------------------------------------------------

sub processTrack
{
	my ($fsh_file, $mark) = @_;

	my $name = $mark->{name};
	my $data = extractData($mark->{ExtendedData});
	my $points = extractPoints($mark->{LineString},[qw(mta_uuid trk_uuid color)]);

	display(0,1,"found Track $name with ".scalar(@$points)." points");
	display(0,2,"mta_uuid   = $data->{mta_uuid}");
	display(0,2,"trk_uuid   = $data->{trk_uuid}");
	display(0,2,"line_color = $data->{line_color}");

	return 0 if !$fsh_file->encodeTRK({
		trk_uuid => $data->{trk_uuid},
		points	=> $points, });
	return 0 if !$fsh_file->encodeMTA({
		name		=> $name,
		mta_uuid	=> $data->{mta_uuid},
		trk_uuid	=> $data->{trk_uuid},
		color		=> $data->{line_color},
		points		=> $points,
		length		=> 0, });

	return 1;

}


#-------------------------------------------------
# main
#-------------------------------------------------


my $ifilename = "/junk/tracks.kml";
my $ofilename = "/junk/tracks.fsh";


my $kml = parseKML($ifilename);
if ($kml)
{
	my $fsh_file = apps::raymarine::FSH::fshFile->new();
	my $folder = $kml->{Document}->{Folder};
	if ($folder)
	{
		display(0,0,"found folder($folder->{name})");
		if ($folder->{name} =~ /Tracks/i)
		{
			display(0,1,"Processing Tracks folder");
			my $num = 0;
			my $marks = $folder->{Placemark};	# Arrayed by xml setup
			for my $mark (@$marks)
			{
				exit 0 if !processTrack($fsh_file,$mark);
			}
		}
	}
	if (@{$fsh_file->{blocks}})
	{
		$fsh_file->write($ofilename);
	}
}










1;
