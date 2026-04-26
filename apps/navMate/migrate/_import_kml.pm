#-----------------------------------------
# migrate/_import_kml.pm
#-----------------------------------------
# Called from winMain File->Import KML menu item.
# run() parses C:/junk/My Places.kml and imports every top-level Folder
# and Document found there.  GE folder names become collection names directly.
#
# Folder hierarchy rules:
#   - Each KML <Folder> or <Document> becomes one collection (findCollection
#     before insertCollection avoids same-name duplicates at the same level).
#   - Route import never creates new waypoints; each vertex is looked
#     up by coordinate (findWaypointByLatLon) and linked by UUID.
#   - After all sources are imported, promoteWaypointOnlyBranches() promotes
#     any branch collection with only direct waypoints to node_type='group'.

package _import_kml;
use strict;
use warnings;
use XML::Simple;
use Time::Local qw(timegm);
use Pub::Utils;
use a_defs;
use a_utils;
use c_db;


my $MY_PLACES_KML = 'C:/junk/My Places.kml';

my $xs = XML::Simple->new(
	KeyAttr       => [],
	ForceArray    => ['Folder', 'Document', 'Placemark', 'Style', 'StyleMap', 'Pair'],
	SuppressEmpty => '');

my $import_ts = time();


sub run
{
	my $dbh = connectDB();
	_run($dbh);
	disconnectDB($dbh);
	display(0,0,"_import_kml done");
}


#---------------------------------
# _run
#---------------------------------

sub _run
{
	my ($dbh) = @_;
	die "_import_kml: not found: $MY_PLACES_KML" unless -f $MY_PLACES_KML;
	display(0,0,"importing $MY_PLACES_KML");
	my $data = $xs->XMLin($MY_PLACES_KML);
	my $root = $data->{Document}[0]
		or die "no root Document in $MY_PLACES_KML";
	my $style_colors = _buildStyleMap($root);

	# My Places.kml wraps everything in a single "My Places" Folder.
	# Descend into it so its children become the top-level sources.
	my $top_folders = $root->{Folder} // [];
	my $container   = (@$top_folders == 1 && ($top_folders->[0]{name}//'') =~ /^My Places/i)
	                ? $top_folders->[0]
	                : $root;

	for my $folder (@{$container->{Folder} // []})
	{
		next if ($folder->{name} // '') =~ /\(no import\)/i;
		eval { _importTopLevel($dbh, $folder, $style_colors) };
		error("_import_kml: folder '" . ($folder->{name}//'?') . "' failed: $@") if $@;
	}
	for my $doc (@{$container->{Document} // []})
	{
		next if ($doc->{name} // '') =~ /\(no import\)/i;
		eval { _importTopLevel($dbh, $doc, $style_colors) };
		error("_import_kml: document '" . ($doc->{name}//'?') . "' failed: $@") if $@;
	}

	promoteWaypointOnlyBranches($dbh);
}


#---------------------------------
# _importTopLevel
#---------------------------------

sub _importTopLevel
{
	my ($dbh, $item, $style_colors) = @_;
	my $name = $item->{name} // '';
	return if !$name || $name =~ /~$/;

	my $top_coll = insertCollection($dbh, $name, undef, $NODE_TYPE_BRANCH, '');
	my $ctx = {
		dbh          => $dbh,
		coll_uuid    => $top_coll,
		node_type    => $NODE_TYPE_BRANCH,
		style_colors => $style_colors,
	};

	for my $sub (@{$item->{Folder}    // []}) { _walkFolder($sub, $ctx) }
	for my $pm  (@{$item->{Placemark} // []}) { _importPlacemark($pm, $ctx) }
	for my $doc (@{$item->{Document}  // []})
	{
		my $doc_name = $doc->{name} // '';
		next if !$doc_name || $doc_name =~ /~$/;
		my $doc_uuid = findCollection($dbh, $doc_name, $top_coll)
		            // insertCollection($dbh, $doc_name, $top_coll, $NODE_TYPE_BRANCH, '');
		my $doc_ctx  = { %$ctx, coll_uuid => $doc_uuid };
		for my $sub (@{$doc->{Folder}    // []}) { _walkFolder($sub, $doc_ctx) }
		for my $pm  (@{$doc->{Placemark} // []}) { _importPlacemark($pm, $doc_ctx) }
	}

	my $n = promoteNavWaypoints($dbh, $top_coll);
	display(0,1,"  promoted $n waypoint(s) label->nav") if $n;
	display(0,0,"  done: $name");
}



#---------------------------------
# _walkFolder
#---------------------------------

sub _walkFolder
{
	my ($folder, $ctx) = @_;
	my $name = $folder->{name} // '';
	return if $name =~ /~$/;

	my $node_type = $NODE_TYPE_BRANCH;
	if    ($name =~ /^routes$/i)  { $node_type = 'routes' }
	elsif ($name =~ /Route$/i)    { _importRouteFolder($folder, $ctx); return; }
	elsif ($name =~ /^tracks?$/i) { $node_type = 'tracks' }

	# Named sub-folder inside a routes context with no explicit type → one route
	if ($ctx->{node_type} eq 'routes' && $node_type eq $NODE_TYPE_BRANCH)
	{
		_importRouteFolder($folder, $ctx);
		return;
	}

	my $dbh = $ctx->{dbh};
	my $db_type   = $node_type eq $NODE_TYPE_GROUP ? $NODE_TYPE_GROUP : $NODE_TYPE_BRANCH;
	my $coll_uuid = findCollection($dbh, $name, $ctx->{coll_uuid})
	             // insertCollection($dbh, $name, $ctx->{coll_uuid}, $db_type, '');

	my $child_ctx = { %$ctx, coll_uuid => $coll_uuid, node_type => $node_type };

	# Sub-folders first so route collections exist before their placemarks are processed.
	for my $sub (@{$folder->{Folder} // []})
	{
		_walkFolder($sub, $child_ctx);
	}
	for my $pm (@{$folder->{Placemark} // []})
	{
		_importPlacemark($pm, $child_ctx);
	}
	for my $doc (@{$folder->{Document} // []})
	{
		my $doc_name = $doc->{name} // '';
		next if !$doc_name || $doc_name =~ /~$/;
		my $doc_uuid = findCollection($dbh, $doc_name, $coll_uuid)
		            // insertCollection($dbh, $doc_name, $coll_uuid, $NODE_TYPE_BRANCH, '');
		my $doc_ctx  = { %$child_ctx, coll_uuid => $doc_uuid };
		for my $sub (@{$doc->{Folder}    // []}) { _walkFolder($sub, $doc_ctx) }
		for my $pm  (@{$doc->{Placemark} // []}) { _importPlacemark($pm, $doc_ctx) }
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

	my $name     = $pm->{name} // '';
	my $wp_type  = $WP_TYPE_LABEL;
	my $depth_cm = 0;
	if ($name =~ /^\d+$/)
	{
		$wp_type  = $WP_TYPE_SOUNDING;
		$depth_cm = int($name * 30.48);
	}

	return insertWaypoint($ctx->{dbh},
		name            => $name,
		wp_type         => $wp_type,
		depth_cm        => $depth_cm,
		lat             => $lat + 0,
		lon             => $lon + 0,
		created_ts      => $import_ts,
		ts_source       => $TS_SOURCE_IMPORT,
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

	my $dbh   = $ctx->{dbh};
	my $color = _resolveColor($ctx->{style_colors}, $pm->{styleUrl});
	my $uuid  = insertTrack($dbh,
		name            => $pm->{name},
		color           => $color,
		ts_start        => $ts_start,
		ts_end          => $ts_end,
		ts_source       => $ts_source,
		collection_uuid => $ctx->{coll_uuid},
		point_count     => scalar @pts);

	insertTrackPoints($dbh, $uuid, \@pts);
}


#---------------------------------
# _importRouteFolder
#---------------------------------
# Named sub-folder inside a routes context.
# Route record in the routes collection ($ctx->{coll_uuid}).
# For Point placemarks: look up by coordinate first (handles files where
#   waypoints were already imported from a sibling groups folder); if not found,
#   create the waypoint in a sub-collection named after the route.
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
		my $dbh   = $ctx->{dbh};
		my $color = @line_pms
			? _resolveColor($ctx->{style_colors}, $line_pms[0]{styleUrl})
			: 0;
		my $sub_coll;   # lazy: created only if a waypoint has no existing home
		my $route_uuid = insertRoute($dbh, $route_name, $color, '', $ctx->{coll_uuid});
		my $pos     = 0;
		my $created = 0;
		for my $pm (@point_pms)
		{
			my $raw = $pm->{Point}{coordinates} // '';
			$raw =~ s/^\s+|\s+$//g;
			my ($lon, $lat) = split /,/, $raw;
			next unless defined $lat && defined $lon;
			my $wp_uuid = findWaypointByLatLon($dbh, $lat + 0, $lon + 0);
			unless ($wp_uuid)
			{
				$sub_coll //= findCollection($dbh, $route_name, $ctx->{coll_uuid})
				          // insertCollection($dbh, $route_name, $ctx->{coll_uuid}, $NODE_TYPE_GROUP, '');
				$wp_uuid = insertWaypoint($dbh,
					name            => $pm->{name},
					wp_type         => $WP_TYPE_NAV,
					lat             => $lat + 0,
					lon             => $lon + 0,
					created_ts      => $import_ts,
					ts_source       => $TS_SOURCE_IMPORT,
					collection_uuid => $sub_coll);
				$created++;
			}
			appendRouteWaypoint($dbh, $route_uuid, $wp_uuid, $pos++);
		}
		display(0,1,"  route '$route_name': $pos pts ($created new)") if $created;
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
	my $dbh        = $ctx->{dbh};
	my $route_name = $pm->{name} // '';
	my $color      = _resolveColor($ctx->{style_colors}, $pm->{styleUrl});
	my $route_uuid = insertRoute($dbh, $route_name, $color, '', $ctx->{coll_uuid});
	my $pos   = 0;
	my $found = 0;
	for my $pt (@pts)
	{
		my $wp_uuid = findWaypointByLatLon($dbh, $pt->{lat}, $pt->{lon});
		if ($wp_uuid)
		{
			appendRouteWaypoint($dbh, $route_uuid, $wp_uuid, $pos++);
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
