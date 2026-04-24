#-----------------------------------------
# migrate/_import_kml.pm
#-----------------------------------------
# Run from apps/navMate/ as: perl migrate/_import_kml.pm

package _import_kml;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use XML::Simple;
use Time::Local qw(timegm);
use File::Basename;
use Pub::Utils;
use a_defs;
use a_utils;
use c_db;


my @KML_FILES = (
	'C:/junk/Navigation.kml',
	'C:/junk/all_data_from_old_chartplotter.kml',
	'C:/junk/RhapsodyLogs - ends May 31, 2009.kml',
	'C:/junk/MandalaLogs.kml',
	'C:/junk/Michelle 2010-2012.kml',
	'C:/junk/MiscBocas.kml',
	'C:/junk/Tooling Around Bocas 2009.kml',
	'C:/junk/Cartagena Trip End 2009.kml',
);

my %SOURCE_NAMES = (
	'Navigation.kml'                        => 'Navigation',
	'all_data_from_old_chartplotter.kml'    => 'OldE80',
	'RhapsodyLogs - ends May 31, 2009.kml'  => 'RhapsodyLogs',
	'MandalaLogs.kml'                        => 'MandalaLogs',
	'Michelle 2010-2012.kml'                => 'Michelle',
	'MiscBocas.kml'                          => 'MiscBocas',
	'Tooling Around Bocas 2009.kml'         => 'Bocas2009',
	'Cartagena Trip End 2009.kml'            => 'Cartagena2009',
);

my $xs = XML::Simple->new(
	KeyAttr       => [],
	ForceArray    => ['Folder', 'Placemark'],
	SuppressEmpty => '');

my $import_ts = time();


c_db::openDB();
_run();
display(0,0,"_import_kml done");


#---------------------------------
# _run
#---------------------------------

sub _run
{
	for my $path (@KML_FILES)
	{
		if (!-f $path)
		{
			warning("_import_kml: not found: $path");
			next;
		}
		display(0,0,"importing $path");
		eval { _importFile($path) };
		error("_import_kml: $path failed: $@") if $@;
	}
}


#---------------------------------
# _importFile
#---------------------------------

sub _importFile
{
	my ($path) = @_;
	my $kml_name    = basename($path);
	my $source_file = $SOURCE_NAMES{$kml_name} // $kml_name;
	my $data        = $xs->XMLin($path);
	my $doc         = $data->{Document}
		or die "no Document element in $path";

	my $top_coll   = insertCollection($source_file, undef,     'branch',    '');
	my $wp_coll    = insertCollection('Waypoints',  $top_coll, 'waypoints', '');
	my $route_coll = insertCollection('Routes',     $top_coll, 'routes',    '');
	my $track_coll = insertCollection('Tracks',     $top_coll, 'tracks',    '');

	my $ctx = {
		wp_coll     => $wp_coll,
		route_coll  => $route_coll,
		track_coll  => $track_coll,
		source_file => $source_file,
		folder_type => '',
	};

	for my $folder (@{$doc->{Folder} // []})
	{
		_walkFolder($folder, $ctx);
	}
	for my $pm (@{$doc->{Placemark} // []})
	{
		_importPlacemark($pm, $ctx);
	}

	display(0,0,"  done: $source_file");
}


#---------------------------------
# _walkFolder
#---------------------------------

sub _walkFolder
{
	my ($folder, $ctx) = @_;
	my $name = $folder->{name} // '';

	my $explicit_ftype;
	if    ($name =~ /^(waypoints?|places?)$/i) { $explicit_ftype = 'waypoints' }
	elsif ($name =~ /^routes?$/i)              { $explicit_ftype = 'routes'    }
	elsif ($name =~ /^(tracks?|soundings?)$/i) { $explicit_ftype = 'tracks'    }
	elsif ($name =~ /^groups?$/i)              { $explicit_ftype = 'groups'    }

	# Named sub-folder inside a routes/groups context → one route definition
	if (($ctx->{folder_type} // '') =~ /^(routes|groups)$/ && !defined($explicit_ftype))
	{
		_importRouteFolder($folder, $ctx);
		return;
	}

	my $ftype       = $explicit_ftype // ($ctx->{folder_type} // '');
	my $child_ctx   = { %$ctx, folder_type => $ftype };

	for my $pm (@{$folder->{Placemark} // []})
	{
		_importPlacemark($pm, $child_ctx);
	}
	for my $sub (@{$folder->{Folder} // []})
	{
		_walkFolder($sub, $child_ctx);
	}
}


#---------------------------------
# _importPlacemark
#---------------------------------

sub _importPlacemark
{
	my ($pm, $ctx) = @_;
	return if ($pm->{name} // '') =~ /~$/;

	if (exists $pm->{Point})
	{
		_importWaypoint($pm, $ctx);
	}
	elsif (exists $pm->{LineString})
	{
		if (($ctx->{folder_type} // '') eq 'routes')
		{
			_importRouteFromLine($pm, $ctx);
		}
		else
		{
			_importTrack($pm, $ctx);
		}
	}
}


#---------------------------------
# _importWaypoint
#---------------------------------

sub _importWaypoint
{
	my ($pm, $ctx) = @_;
	my $raw = $pm->{Point}{coordinates} // '';
	$raw =~ s/^\s+|\s+$//g;
	my ($lon, $lat) = split /,/, $raw;
	return unless defined $lat && defined $lon;
	return insertWaypoint(
		name            => $pm->{name},
		lat             => $lat + 0,
		lon             => $lon + 0,
		created_ts      => $import_ts,
		ts_source       => $TS_SOURCE_IMPORT,
		source_file     => $ctx->{source_file},
		collection_uuid => $ctx->{wp_coll});
}


#---------------------------------
# _importTrack
#---------------------------------

sub _importTrack
{
	my ($pm, $ctx) = @_;
	my ($ts_start, $ts_end, $ts_source) = (0, undef, $TS_SOURCE_IMPORT);

	if (ref($pm->{LookAt}) eq 'HASH')
	{
		my $span = $pm->{LookAt}{'gx:TimeSpan'};
		if (ref($span) eq 'HASH' && $span->{begin})
		{
			$ts_start  = _parseISO($span->{begin});
			$ts_end    = _parseISO($span->{end}) if $span->{end};
			$ts_source = $TS_SOURCE_KML_TIMESPAN if $ts_start;
		}
	}

	my @pts = _parseCoords($pm->{LineString}{coordinates});
	return unless @pts;

	my $uuid = insertTrack(
		name            => $pm->{name},
		ts_start        => $ts_start,
		ts_end          => $ts_end,
		ts_source       => $ts_source,
		source_file     => $ctx->{source_file},
		collection_uuid => $ctx->{track_coll},
		point_count     => scalar @pts);

	insertTrackPoints($uuid, \@pts);
}


#---------------------------------
# _importRouteFolder
#---------------------------------
# Named sub-folder inside routes/groups context.
# Points in order → named-waypoint route.
# LineStrings (no Points) → coord-based route(s).

sub _importRouteFolder
{
	my ($folder, $ctx) = @_;
	my @pms       = grep { ($_->{name} // '') !~ /~$/ } @{$folder->{Placemark} // []};
	my @point_pms = grep { exists $_->{Point}       } @pms;
	my @line_pms  = grep { exists $_->{LineString}  } @pms;

	if (@point_pms)
	{
		my $route_uuid = insertRoute($folder->{name}, 0, '', $ctx->{route_coll});
		my $pos = 0;
		for my $pm (@point_pms)
		{
			my $wp_uuid = _importWaypoint($pm, $ctx);
			appendRouteWaypoint($route_uuid, $wp_uuid, $pos++) if $wp_uuid;
		}
	}
	elsif (@line_pms)
	{
		for my $pm (@line_pms)
		{
			_importRouteFromLine($pm, $ctx);
		}
	}
}


#---------------------------------
# _importRouteFromLine
#---------------------------------

sub _importRouteFromLine
{
	my ($pm, $ctx) = @_;
	my @pts = _parseCoords($pm->{LineString}{coordinates});
	return unless @pts;
	my $route_uuid = insertRoute($pm->{name}, 0, '', $ctx->{route_coll});
	my $pos = 0;
	for my $pt (@pts)
	{
		my $wp_uuid = insertWaypoint(
			name            => sprintf("%s.%03d", $pm->{name}, $pos),
			lat             => $pt->{lat},
			lon             => $pt->{lon},
			created_ts      => $import_ts,
			ts_source       => $TS_SOURCE_IMPORT,
			source_file     => $ctx->{source_file},
			collection_uuid => $ctx->{wp_coll});
		appendRouteWaypoint($route_uuid, $wp_uuid, $pos++);
	}
}


#---------------------------------
# _parseCoords
#---------------------------------

sub _parseCoords
{
	my ($raw) = @_;
	return () unless $raw;
	my @pts;
	for my $t (split /\s+/, $raw)
	{
		next unless $t =~ /,/;
		my ($lon, $lat) = split /,/, $t;
		push @pts, { lat => $lat + 0, lon => $lon + 0 };
	}
	return @pts;
}


#---------------------------------
# _parseISO
#---------------------------------

sub _parseISO
{
	my ($s) = @_;
	return 0 unless $s;
	return 0 unless $s =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z?$/;
	return eval { timegm($6, $5, $4, $3, $2-1, $1-1900) } // 0;
}


1;
