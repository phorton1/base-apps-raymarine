#-----------------------------------------
# migrate/_import_kml.pm
#-----------------------------------------
# Run from apps/navMate/ as: perl migrate/_import_kml.pm
#
# Folder hierarchy rules:
#   - Each KML <Folder> becomes one collection (findCollection before
#     insertCollection avoids same-name duplicates at the same level).
#   - If the Document's sole top-level folder name matches the source
#     file's long name, it is merged into the source collection (no
#     redundant wrapper).
#   - Route import never creates new waypoints; each vertex is looked
#     up by coordinate (findWaypointByLatLon) and linked by UUID.

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
	'C:/junk/MiscBocas.kml',
	'C:/junk/Michelle 2010-2012.kml',
	'C:/junk/Tooling Around Bocas 2009.kml',
	'C:/junk/Cartagena Trip End 2009.kml',
	'C:/junk/RhapsodyLogs - ends May 31, 2009.kml',
	'C:/junk/MandalaLogs.kml',
);

my %SOURCE_NAMES = (
	'Navigation.kml'                       => 'Navigation',
	'all_data_from_old_chartplotter.kml'   => 'OldE80',
	'MiscBocas.kml'                        => 'MiscBocas',
	'Michelle 2010-2012.kml'               => 'Michelle',
	'Tooling Around Bocas 2009.kml'        => 'Bocas2009',
	'Cartagena Trip End 2009.kml'          => 'Cartagena2009',
	'RhapsodyLogs - ends May 31, 2009.kml' => 'RhapsodyLogs',
	'MandalaLogs.kml'                      => 'MandalaLogs',
);

my $xs = XML::Simple->new(
	KeyAttr       => [],
	ForceArray    => ['Folder', 'Placemark', 'Style', 'StyleMap', 'Pair'],
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
			warning(0,0,"_import_kml: not found: $path");
			next;
		}
		display(0,0,"importing $path");
		eval { _importFile($path) };
		error("_import_kml: $path failed: $@") if $@;
	}
	_autoTypeCollections();
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

	my $top_coll     = insertCollection($source_file, undef, 'branch', '');
	my $wp_sink_uuid = undef;
	my $style_colors = _buildStyleMap($doc);

	my $ctx = {
		coll_uuid     => $top_coll,
		node_type     => 'branch',
		source_file   => $source_file,
		top_coll_uuid => $top_coll,
		wp_sink_ref   => \$wp_sink_uuid,
		style_colors  => $style_colors,
	};

	for my $folder (@{$doc->{Folder} // []})
	{
		my $fname = $folder->{name} // '';
		if (($SOURCE_NAMES{$fname . '.kml'} // '') eq $source_file)
		{
			# Merge top-level wrapper folder directly into $top_coll.
			# Sub-folders first so typed collections exist before any wp_sink fires.
			for my $sub (@{$folder->{Folder} // []})
			{
				_walkFolder($sub, $ctx);
			}
			for my $pm (@{$folder->{Placemark} // []})
			{
				_importPlacemark($pm, $ctx);
			}
		}
		else
		{
			_walkFolder($folder, $ctx);
		}
	}
	for my $pm (@{$doc->{Placemark} // []})
	{
		_importPlacemark($pm, $ctx);
	}

	display(0,0,"  done: $source_file");
}


#---------------------------------
# _getWpSink
#---------------------------------
# Returns the uuid of a 'Waypoints' group collection under the source
# file's top-level collection.  Created on first call; reused thereafter.
# Used only when route Point placemarks have no pre-existing waypoint match.

sub _getWpSink
{
	my ($ctx) = @_;
	my $ref = $ctx->{wp_sink_ref};
	unless ($$ref)
	{
		my $existing_uuid = findCollection('Waypoints',    $ctx->{top_coll_uuid})
		                 // findCollection('My Waypoints', $ctx->{top_coll_uuid});
		if ($existing_uuid)
		{
			my $existing = getCollection($existing_uuid);
			if (($existing->{node_type} // '') eq 'groups')
			{
				# groups container — create/find 'My Waypoints' inside it
				$$ref = findCollection('My Waypoints', $existing_uuid)
				     // insertCollection('My Waypoints', $existing_uuid, 'group', '');
			}
			else
			{
				$$ref = $existing_uuid;
			}
		}
		else
		{
			$$ref = insertCollection('My Waypoints', $ctx->{top_coll_uuid}, 'group', '');
		}
	}
	return $$ref;
}


#---------------------------------
# _walkFolder
#---------------------------------

sub _walkFolder
{
	my ($folder, $ctx) = @_;
	my $name = $folder->{name} // '';
	return if $name =~ /~$/;

	my $node_type = 'branch';
	if ($name =~ /^(waypoints?|my\s+waypoints?)$/i)
	{
		# groups if it contains sub-folders (it's a container of groups),
		# group if it contains only waypoints directly
		$node_type = @{$folder->{Folder} // []} ? 'groups' : 'group';
	}
	elsif ($name =~ /^groups?$/i)                      { $node_type = 'groups' }
	elsif ($name =~ /^routes?$/i)                      { $node_type = 'routes' }
	elsif ($name =~ /^(tracks?|soundings?)$/i)         { $node_type = 'tracks' }

	# Named sub-folder inside a groups context → promote to group
	if ($ctx->{node_type} eq 'groups' && $node_type eq 'branch')
	{
		$node_type = 'group';
	}

	# Named sub-folder inside a routes context with no explicit type → one route
	if ($ctx->{node_type} eq 'routes' && $node_type eq 'branch')
	{
		_importRouteFolder($folder, $ctx);
		return;
	}

	my $coll_uuid = findCollection($name, $ctx->{coll_uuid})
	             // insertCollection($name, $ctx->{coll_uuid}, $node_type, '');

	my $child_ctx = { %$ctx, coll_uuid => $coll_uuid, node_type => $node_type };

	# Sub-folders first so typed collections exist before any wp_sink fires.
	for my $sub (@{$folder->{Folder} // []})
	{
		_walkFolder($sub, $child_ctx);
	}
	for my $pm (@{$folder->{Placemark} // []})
	{
		_importPlacemark($pm, $child_ctx);
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
		# Waypoints must live in a group collection; redirect if context is not a group
		my $wp_ctx = ($ctx->{node_type} eq 'group')
			? $ctx
			: { %$ctx, coll_uuid => _getWpSink($ctx) };
		_importWaypoint($pm, $wp_ctx);
	}
	elsif (exists $pm->{LineString})
	{
		if ($ctx->{node_type} eq 'routes')
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
		collection_uuid => $ctx->{coll_uuid});
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

	my $color = _resolveColor($ctx->{style_colors}, $pm->{styleUrl});
	my $uuid = insertTrack(
		name            => $pm->{name},
		color           => $color,
		ts_start        => $ts_start,
		ts_end          => $ts_end,
		ts_source       => $ts_source,
		source_file     => $ctx->{source_file},
		collection_uuid => $ctx->{coll_uuid},
		point_count     => scalar @pts);

	insertTrackPoints($uuid, \@pts);
}


#---------------------------------
# _importRouteFolder
#---------------------------------
# Named sub-folder inside a routes context.
# Route record in the routes collection ($ctx->{coll_uuid}).
# For Point placemarks: look up by coordinate first (handles files where
#   waypoints were already imported from a groups folder); if not found,
#   create the waypoint in the peer wp_sink group collection.
# For LineString placemarks: delegates to _importRouteFromLine.

sub _importRouteFolder
{
	my ($folder, $ctx) = @_;
	my $route_name = $folder->{name} // '';
	my @pms        = grep { ($_->{name} // '') !~ /~$/ } @{$folder->{Placemark} // []};
	my @point_pms  = grep { exists $_->{Point}      } @pms;
	my @line_pms   = grep { exists $_->{LineString} } @pms;

	if (@point_pms)
	{
		my $color = @line_pms
			? _resolveColor($ctx->{style_colors}, $line_pms[0]{styleUrl})
			: 0;
		my $route_uuid = insertRoute($route_name, $color, '', $ctx->{coll_uuid});
		my $pos     = 0;
		my $created = 0;
		for my $pm (@point_pms)
		{
			my $raw = $pm->{Point}{coordinates} // '';
			$raw =~ s/^\s+|\s+$//g;
			my ($lon, $lat) = split /,/, $raw;
			next unless defined $lat && defined $lon;
			my $wp_uuid = findWaypointByLatLon($lat + 0, $lon + 0, $ctx->{source_file});
			unless ($wp_uuid)
			{
				$wp_uuid = insertWaypoint(
					name            => $pm->{name},
					lat             => $lat + 0,
					lon             => $lon + 0,
					created_ts      => $import_ts,
					ts_source       => $TS_SOURCE_IMPORT,
					source_file     => $ctx->{source_file},
					collection_uuid => _getWpSink($ctx));
				$created++;
			}
			appendRouteWaypoint($route_uuid, $wp_uuid, $pos++);
		}
		display(0,1,"  route '$route_name': $pos pts ($created created in wp_sink)") if $created;
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
# Route record in $ctx->{coll_uuid}.
# Coordinate-matches each LineString vertex to an existing waypoint UUID.
# NEVER creates new waypoint records; warns on any miss.

sub _importRouteFromLine
{
	my ($pm, $ctx) = @_;
	my @pts = _parseCoords($pm->{LineString}{coordinates});
	return unless @pts;
	my $route_name = $pm->{name} // '';
	my $color      = _resolveColor($ctx->{style_colors}, $pm->{styleUrl});
	my $route_uuid = insertRoute($route_name, $color, '', $ctx->{coll_uuid});
	my $pos   = 0;
	my $found = 0;
	for my $pt (@pts)
	{
		my $wp_uuid = findWaypointByLatLon($pt->{lat}, $pt->{lon}, $ctx->{source_file});
		if ($wp_uuid)
		{
			appendRouteWaypoint($route_uuid, $wp_uuid, $pos++);
			$found++;
		}
		else
		{
			warning(0,0,"route '$route_name': no waypoint match at $pt->{lat},$pt->{lon}");
		}
	}
	display(0,1,"  route '$route_name': $found/" . scalar(@pts) . " vertices matched");
}


#---------------------------------
# _buildStyleMap
#---------------------------------
# Collects <Style id="..."><LineStyle><color> entries from the Document,
# then resolves <StyleMap> "normal" pairs so both #style_id and
# #stylemap_id keys are available.  Returns hashref of url→abgr_string.

sub _buildStyleMap
{
	my ($doc) = @_;
	my %sc;

	for my $s (@{$doc->{Style} // []})
	{
		my $id    = $s->{id} // next;
		my $color = $s->{LineStyle}{color} // next;
		$sc{"#$id"} = $color;
	}

	for my $sm (@{$doc->{StyleMap} // []})
	{
		my $id = $sm->{id} // next;
		for my $pair (@{$sm->{Pair} // []})
		{
			next unless ($pair->{key} // '') eq 'normal';
			my $url = $pair->{styleUrl} // next;
			next unless exists $sc{$url};
			$sc{"#$id"} = $sc{$url};
			last;
		}
	}

	return \%sc;
}


#---------------------------------
# _abgrToRouteColor
#---------------------------------
# Parses an 8-char ABGR hex string (Google Earth format: aabbggrr) and
# returns the nearest E80 color index 0-5 by Euclidean distance in RGB.

sub _abgrToRouteColor
{
	my ($abgr) = @_;
	return 0 unless $abgr && length($abgr) >= 8;
	my $rr = hex(substr($abgr, 6, 2));
	my $gg = hex(substr($abgr, 4, 2));
	my $bb = hex(substr($abgr, 2, 2));
	my @targets = (
		[255,   0,   0],   # 0 RED
		[255, 255,   0],   # 1 YELLOW
		[  0, 255,   0],   # 2 GREEN
		[  0,   0, 255],   # 3 BLUE
		[255,   0, 255],   # 4 PURPLE
		[255, 255, 255],   # 5 WHITE
	);
	my ($best_idx, $best_dist) = (0, 9e99);
	for my $i (0 .. $#targets)
	{
		my $d = ($rr-$targets[$i][0])**2
		      + ($gg-$targets[$i][1])**2
		      + ($bb-$targets[$i][2])**2;
		if ($d < $best_dist) { $best_dist = $d; $best_idx = $i; }
	}
	return $best_idx;
}


#---------------------------------
# _resolveColor
#---------------------------------
# Given a styleUrl (e.g. '#myStyle') and the file's style_colors map,
# returns an E80 color index 0-5, defaulting to 0.

sub _resolveColor
{
	my ($style_colors, $style_url) = @_;
	return 0 unless $style_url && $style_colors;
	my $abgr = $style_colors->{$style_url};
	return 0 unless $abgr;
	return _abgrToRouteColor($abgr);
}


#---------------------------------
# _autoTypeCollections
#---------------------------------
# Upgrade leaf branch collections of uniform object type to their typed node_type.

sub _autoTypeCollections
{
	my $branches = getAllBranchCollections();
	my $n_typed  = 0;
	for my $coll (@$branches)
	{
		my $counts = getCollectionCounts($coll->{uuid});
		next if $counts->{collections};
		my $total = $counts->{waypoints} + $counts->{routes} + $counts->{tracks};
		next unless $total;
		if    ($counts->{tracks}    == $total) { updateCollectionNodeType($coll->{uuid}, 'tracks'); $n_typed++ }
		elsif ($counts->{waypoints} == $total) { updateCollectionNodeType($coll->{uuid}, 'group');  $n_typed++ }
		elsif ($counts->{routes}    == $total) { updateCollectionNodeType($coll->{uuid}, 'routes'); $n_typed++ }
	}
	display(0,0,"_autoTypeCollections: $n_typed collections typed");
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
