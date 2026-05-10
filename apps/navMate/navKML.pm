#-----------------------------------------
# navKML.pm
#-----------------------------------------
package navKML;
use strict;
use warnings;
use XML::Simple;
use Pub::Utils qw(display warning error);
use n_defs;
use n_utils;
use navDB;

my $KML_STYLE_VERSION = 1;
my $WHT_BLANK         = 'http://maps.google.com/mapfiles/kml/paddle/wht-blank.png';
my $DEFAULT_COLOR     = 'ffffffff';

my $xs = XML::Simple->new(
	KeyAttr       => [],
	ForceArray    => ['Folder', 'Document', 'Placemark', 'Style', 'StyleMap', 'Pair', 'Data'],
	SuppressEmpty => '');


#=================================================================
# EXPORT
#=================================================================

sub exportKML
{
	my ($path) = @_;
	my $dbh = connectDB();
	_export($dbh, $path);
	disconnectDB($dbh);
}

sub _export
{
	my ($dbh, $path) = @_;
	display(0,0,"navKML: exporting to $path");

	my %styles;
	my $content = '';
	my $roots = getCollectionChildren($dbh, undef);
	for my $coll (@{$roots // []})
	{
		$content .= _exportCollection($dbh, $coll, 2, \%styles);
	}

	my $style_xml = join('', map { $styles{$_} } sort keys %styles);

	my $fh;
	if (!open($fh, '>:encoding(UTF-8)', $path))
	{
		error("navKML: cannot write $path: $!");
		return;
	}
	print $fh qq{<?xml version="1.0" encoding="UTF-8"?>\n};
	print $fh qq{<kml xmlns="http://www.opengis.net/kml/2.2">\n};
	print $fh qq{<Document>\n};
	print $fh qq{  <name>navMate.kml</name>\n};
	print $fh $style_xml;
	print $fh qq{  <Folder>\n};
	print $fh qq{    <name>navMate</name>\n};
	print $fh $content;
	print $fh qq{  </Folder>\n};
	print $fh qq{</Document>\n};
	print $fh qq{</kml>\n};
	close $fh;
	display(0,0,"navKML: export complete");
}


sub _exportCollection
{
	my ($dbh, $coll, $depth, $styles) = @_;
	my $pad     = '  ' x $depth;
	my $nm_type = ($coll->{node_type} eq $NODE_TYPE_GROUP) ? 'group' : 'collection';

	my $s = "$pad<Folder>\n";
	$s .= "$pad  <name>" . _esc($coll->{name}) . "</name>\n";
	$s .= _extData("$pad  ", nm_uuid => $coll->{uuid}, nm_type => $nm_type);

	my $children = getCollectionChildren($dbh, $coll->{uuid});
	for my $child (@{$children // []})
	{
		$s .= _exportCollection($dbh, $child, $depth + 1, $styles);
	}

	my $objects = getCollectionObjects($dbh, $coll->{uuid});
	for my $obj (@{$objects // []})
	{
		my $t = $obj->{obj_type};
		if    ($t eq 'waypoint') { $s .= _exportWaypoint($dbh, $obj, $depth + 1, $styles) }
		elsif ($t eq 'route')    { $s .= _exportRoute($dbh, $obj, $depth + 1, $styles) }
		elsif ($t eq 'track')    { $s .= _exportTrack($dbh, $obj, $depth + 1, $styles) }
	}

	$s .= "$pad</Folder>\n";
	return $s;
}


sub _exportWaypoint
{
	my ($dbh, $wp, $depth, $styles) = @_;
	my $pad   = '  ' x $depth;
	my $color = _wpExportColor($dbh, $wp);
	my $stype = ($wp->{wp_type} eq $WP_TYPE_NAV) ? 'nav' : 'label';
	my $sid   = _styleId($stype, $color);
	$styles->{$sid} //= _buildStyle($stype, $color);

	my $s = "$pad<Placemark>\n";
	$s .= "$pad  <name>" . _esc($wp->{name}) . "</name>\n";
	$s .= "$pad  <styleUrl>#$sid</styleUrl>\n";
	$s .= _extData("$pad  ", nm_uuid => $wp->{uuid}, nm_type => 'waypoint');
	$s .= "$pad  <Point>\n";
	$s .= "$pad    <coordinates>$wp->{lon},$wp->{lat},0</coordinates>\n";
	$s .= "$pad  </Point>\n";
	$s .= "$pad</Placemark>\n";
	return $s;
}


sub _exportRoute
{
	my ($dbh, $route, $depth, $styles) = @_;
	my $pad   = '  ' x $depth;
	my $color = $route->{color} || $DEFAULT_COLOR;
	my $rsid  = _styleId('route',  $color);
	my $wsid  = _styleId('nav_sm', $color);
	$styles->{$rsid} //= _buildStyle('route',  $color);
	$styles->{$wsid} //= _buildStyle('nav_sm', $color);

	my $wps = getRouteWaypoints($dbh, $route->{uuid});

	my $s = "$pad<Folder>\n";
	$s .= "$pad  <name>" . _esc($route->{name}) . "</name>\n";
	$s .= _extData("$pad  ", nm_uuid => $route->{uuid}, nm_type => 'route');

	if (@{$wps // []})
	{
		my $coords = join(' ', map { "$_->{lon},$_->{lat},0" } @$wps);

		$s .= "$pad  <Placemark>\n";
		$s .= "$pad    <name>" . _esc($route->{name}) . "</name>\n";
		$s .= "$pad    <styleUrl>#$rsid</styleUrl>\n";
		$s .= "$pad    <LineString>\n";
		$s .= "$pad      <tessellate>1</tessellate>\n";
		$s .= "$pad      <coordinates>$coords</coordinates>\n";
		$s .= "$pad    </LineString>\n";
		$s .= "$pad  </Placemark>\n";

		for my $wp (@$wps)
		{
			$s .= "$pad  <Placemark>\n";
			$s .= "$pad    <name>" . _esc($wp->{name}) . "</name>\n";
			$s .= "$pad    <styleUrl>#$wsid</styleUrl>\n";
			$s .= _extData("$pad    ", nm_uuid => $wp->{uuid}, nm_ref => '1');
			$s .= "$pad    <Point>\n";
			$s .= "$pad      <coordinates>$wp->{lon},$wp->{lat},0</coordinates>\n";
			$s .= "$pad    </Point>\n";
			$s .= "$pad  </Placemark>\n";
		}
	}

	$s .= "$pad</Folder>\n";
	return $s;
}


sub _exportTrack
{
	my ($dbh, $track, $depth, $styles) = @_;
	my $pad   = '  ' x $depth;
	my $color = $track->{color} || $DEFAULT_COLOR;
	my $sid   = _styleId('track', $color);
	$styles->{$sid} //= _buildStyle('track', $color);

	my $pts = getTrackPoints($dbh, $track->{uuid});
	return '' if !@{$pts // []};

	my $coords = join(' ', map { "$_->{lon},$_->{lat},0" } @$pts);

	my $s = "$pad<Placemark>\n";
	$s .= "$pad  <name>" . _esc($track->{name}) . "</name>\n";
	$s .= "$pad  <styleUrl>#$sid</styleUrl>\n";
	$s .= _extData("$pad  ", nm_uuid => $track->{uuid}, nm_type => 'track');
	$s .= "$pad  <LineString>\n";
	$s .= "$pad    <tessellate>1</tessellate>\n";
	$s .= "$pad    <coordinates>$coords</coordinates>\n";
	$s .= "$pad  </LineString>\n";
	$s .= "$pad</Placemark>\n";
	return $s;
}


#---------------------------------
# Style helpers
#---------------------------------

sub _styleId
{
	my ($type, $color) = @_;
	return "nm${KML_STYLE_VERSION}_${type}_${color}";
}


sub _buildStyle
{
	my ($type, $color) = @_;
	my $sid = _styleId($type, $color);
	my $s   = "  <Style id=\"$sid\">\n";
	if ($type eq 'track')
	{
		$s .= "    <LineStyle><color>$color</color><width>1</width></LineStyle>\n";
		$s .= "    <PolyStyle><fill>0</fill></PolyStyle>\n";
	}
	elsif ($type eq 'route')
	{
		$s .= "    <LineStyle><color>$color</color><width>3</width></LineStyle>\n";
		$s .= "    <PolyStyle><fill>0</fill></PolyStyle>\n";
	}
	elsif ($type eq 'nav')
	{
		$s .= "    <IconStyle><color>$color</color><scale>0.5</scale><Icon><href>$WHT_BLANK</href></Icon></IconStyle>\n";
		$s .= "    <LabelStyle><color>$color</color><scale>0.55</scale></LabelStyle>\n";
	}
	elsif ($type eq 'nav_sm')
	{
		$s .= "    <IconStyle><color>$color</color><scale>0.35</scale><Icon><href>$WHT_BLANK</href></Icon></IconStyle>\n";
		$s .= "    <LabelStyle><color>$color</color><scale>0.55</scale></LabelStyle>\n";
	}
	elsif ($type eq 'label')
	{
		$s .= "    <IconStyle><Icon/></IconStyle>\n";
		$s .= "    <LabelStyle><color>$color</color><scale>0.6</scale></LabelStyle>\n";
	}
	$s .= "  </Style>\n";
	return $s;
}


sub _extData
{
	my ($pad, %tags) = @_;
	my $s = "${pad}<ExtendedData>\n";
	for my $key (sort keys %tags)
	{
		$s .= "$pad  <Data name=\"$key\"><value>" . _esc($tags{$key}) . "</value></Data>\n";
	}
	$s .= "${pad}</ExtendedData>\n";
	return $s;
}


sub _wpExportColor
{
	my ($dbh, $wp) = @_;
	if ($wp->{wp_type} eq $WP_TYPE_SOUNDING)
	{
		my $full  = getWaypoint($dbh, $wp->{uuid});
		my $depth = $full ? ($full->{depth_cm} // 0) : 0;
		return $depth < 200 ? 'ff0000ff' : 'ffffffff';
	}
	return $wp->{color} || $DEFAULT_COLOR;
}


sub _esc
{
	my ($s) = @_;
	$s //= '';
	$s =~ s/&/&amp;/g;
	$s =~ s/</&lt;/g;
	$s =~ s/>/&gt;/g;
	$s =~ s/"/&quot;/g;
	return $s;
}


#=================================================================
# IMPORT
#=================================================================

sub importKML
{
	my ($path) = @_;
	my $dbh = connectDB();
	_import($dbh, $path);
	disconnectDB($dbh);
}

sub _import
{
	my ($dbh, $path) = @_;
	if (!-f $path)
	{
		error("navKML: not found: $path");
		return;
	}
	display(0,0,"navKML: importing $path");

	my $data = $xs->XMLin($path);
	my $root = $data->{Document}[0];
	if (!$root)
	{
		error("navKML: no root Document in $path");
		return;
	}

	my $top_folders = $root->{Folder} // [];
	my ($nm_folder) = grep { ($_->{name}//'') =~ /^navMate/i } @$top_folders;
	$nm_folder //= $root;

	my %seen;
	my @pending_routes;

	for my $folder (@{$nm_folder->{Folder} // []})
	{
		_importFolder($dbh, $folder, undef, \%seen, \@pending_routes);
	}
	for my $pm (@{$nm_folder->{Placemark} // []})
	{
		_importPlacemark($dbh, $pm, undef, \%seen);
	}

	for my $r (@pending_routes)
	{
		_importRouteFolder($dbh, $r->{folder}, $r->{coll_uuid}, \%seen);
	}

	display(0,0,"navKML: import complete");
}


sub _parseExt
{
	my ($elem) = @_;
	my %tags;
	my $list = eval { $elem->{ExtendedData}{Data} } // [];
	$list = [$list] if ref($list) eq 'HASH';
	for my $d (@$list)
	{
		my $name = $d->{name} // next;
		$tags{$name} = $d->{value} // '';
	}
	return \%tags;
}


sub _importFolder
{
	my ($dbh, $folder, $parent_uuid, $seen, $pending_routes) = @_;
	my $name = $folder->{name} // '';
	return if !$name;

	my $ext     = _parseExt($folder);
	my $nm_uuid = $ext->{nm_uuid};
	my $nm_type = $ext->{nm_type} // 'collection';

	if ($nm_type eq 'route')
	{
		push @$pending_routes, { folder => $folder, coll_uuid => $parent_uuid };
		return;
	}

	my $db_type = ($nm_type eq 'group') ? $NODE_TYPE_GROUP : $NODE_TYPE_BRANCH;
	my $coll_uuid;

	if ($nm_uuid)
	{
		if ($seen->{$nm_uuid})
		{
			warning(0,0,"navKML: duplicate nm_uuid '$nm_uuid' collection '$name' - skipped");
			return;
		}
		$seen->{$nm_uuid} = 1;

		my $ex = getCollection($dbh, $nm_uuid);
		if ($ex)
		{
			$dbh->do("UPDATE collections SET name=?, node_type=? WHERE uuid=?",
				[$name, $db_type, $nm_uuid]);
			my $old_p = $ex->{parent_uuid} // '';
			my $new_p = $parent_uuid // '';
			moveCollection($dbh, $nm_uuid, $parent_uuid) if $old_p ne $new_p;
			$coll_uuid = $nm_uuid;
		}
		else
		{
			$coll_uuid = insertCollectionUUID($dbh, $nm_uuid, $name, $parent_uuid, $db_type, '');
		}
	}
	else
	{
		$coll_uuid = findCollection($dbh, $name, $parent_uuid)
		          // insertCollection($dbh, $name, $parent_uuid, $db_type, '');
	}

	return unless $coll_uuid;

	for my $child (@{$folder->{Folder} // []})
	{
		_importFolder($dbh, $child, $coll_uuid, $seen, $pending_routes);
	}
	for my $pm (@{$folder->{Placemark} // []})
	{
		_importPlacemark($dbh, $pm, $coll_uuid, $seen);
	}
}


sub _importPlacemark
{
	my ($dbh, $pm, $coll_uuid, $seen) = @_;
	return if ($pm->{name} // '') eq '';
	my $ext = _parseExt($pm);
	return if $ext->{nm_ref};

	if    (exists $pm->{Point})      { _importWaypoint($dbh, $pm, $coll_uuid, $seen, $ext) }
	elsif (exists $pm->{LineString}) { _importTrack($dbh, $pm, $coll_uuid, $seen, $ext) }
}


sub _importWaypoint
{
	my ($dbh, $pm, $coll_uuid, $seen, $ext) = @_;
	my $raw = $pm->{Point}{coordinates} // '';
	$raw =~ s/^\s+|\s+$//g;
	my ($lon, $lat) = split /,/, $raw;
	return if !(defined $lat && defined $lon);

	my $name    = $pm->{name} // '';
	my $nm_uuid = $ext->{nm_uuid};
	my $color   = _colorFromStyle($pm->{styleUrl}, 'nav');

	if ($nm_uuid)
	{
		if ($seen->{$nm_uuid})
		{
			warning(0,0,"navKML: duplicate nm_uuid '$nm_uuid' waypoint '$name' - skipped");
			return;
		}
		$seen->{$nm_uuid} = 1;

		my $ex = getWaypoint($dbh, $nm_uuid);
		if ($ex)
		{
			updateWaypoint($dbh, $nm_uuid,
				name       => $name,
				comment    => $ex->{comment},
				lat        => $lat + 0,
				lon        => $lon + 0,
				wp_type    => $ex->{wp_type},
				color      => $color // $ex->{color},
				depth_cm   => $ex->{depth_cm},
				created_ts => $ex->{created_ts},
				ts_source  => $ex->{ts_source},
				source     => $ex->{source});
			moveWaypoint($dbh, $nm_uuid, $coll_uuid)
				if defined $coll_uuid && $coll_uuid ne ($ex->{collection_uuid}//'');
		}
		else
		{
			my $wp_type = ($name =~ /^\d+$/) ? $WP_TYPE_SOUNDING : $WP_TYPE_NAV;
			insertWaypoint($dbh,
				uuid            => $nm_uuid,
				name            => $name,
				wp_type         => $wp_type,
				lat             => $lat + 0,
				lon             => $lon + 0,
				color           => $color,
				created_ts      => time(),
				ts_source       => $TS_SOURCE_IMPORT,
				collection_uuid => $coll_uuid);
		}
	}
	else
	{
		my $wp_type = ($name =~ /^\d+$/) ? $WP_TYPE_SOUNDING : $WP_TYPE_NAV;
		insertWaypoint($dbh,
			name            => $name,
			wp_type         => $wp_type,
			lat             => $lat + 0,
			lon             => $lon + 0,
			color           => $color,
			created_ts      => time(),
			ts_source       => $TS_SOURCE_IMPORT,
			collection_uuid => $coll_uuid);
	}
}


sub _importTrack
{
	my ($dbh, $pm, $coll_uuid, $seen, $ext) = @_;
	my $name    = $pm->{name} // '';
	my $nm_uuid = $ext->{nm_uuid};
	my $color   = _colorFromStyle($pm->{styleUrl}, 'track');

	if ($nm_uuid)
	{
		if ($seen->{$nm_uuid})
		{
			warning(0,0,"navKML: duplicate nm_uuid '$nm_uuid' track '$name' - skipped");
			return;
		}
		$seen->{$nm_uuid} = 1;

		my $ex = getTrack($dbh, $nm_uuid);
		if ($ex)
		{
			$dbh->do("UPDATE tracks SET name=?, color=? WHERE uuid=?",
				[$name, $color // $ex->{color}, $nm_uuid]);
			return;
		}

		my @pts = _parseCoords($pm->{LineString}{coordinates});
		return if !@pts;
		$dbh->do(
			"INSERT INTO tracks (uuid,name,color,ts_start,ts_source,point_count,collection_uuid) VALUES (?,?,?,?,?,?,?)",
			[$nm_uuid, $name, $color, time(), $TS_SOURCE_IMPORT, scalar @pts, $coll_uuid]);
		insertTrackPoints($dbh, $nm_uuid, \@pts);
	}
	else
	{
		my @pts = _parseCoords($pm->{LineString}{coordinates});
		return if !@pts;
		my $uuid = insertTrack($dbh,
			name            => $name,
			color           => $color,
			ts_start        => time(),
			ts_source       => $TS_SOURCE_IMPORT,
			collection_uuid => $coll_uuid,
			point_count     => scalar @pts);
		insertTrackPoints($dbh, $uuid, \@pts);
	}
}


sub _importRouteFolder
{
	my ($dbh, $folder, $coll_uuid, $seen) = @_;
	my $name    = $folder->{name} // '';
	my $ext     = _parseExt($folder);
	my $nm_uuid = $ext->{nm_uuid};

	my @pms     = @{$folder->{Placemark} // []};
	my ($line)  = grep { exists $_->{LineString} } @pms;
	my @ref_pms = grep { exists $_->{Point} && _parseExt($_)->{nm_ref} } @pms;

	my $color = ($line && $line->{styleUrl})
		? _colorFromStyle($line->{styleUrl}, 'route')
		: undef;

	if ($nm_uuid)
	{
		if ($seen->{$nm_uuid})
		{
			warning(0,0,"navKML: duplicate nm_uuid '$nm_uuid' route '$name' - skipped");
			return;
		}
		$seen->{$nm_uuid} = 1;

		my $ex = getRoute($dbh, $nm_uuid);
		if ($ex)
		{
			updateRoute($dbh, $nm_uuid, $name, $color // $ex->{color}, $ex->{comment});
			moveRoute($dbh, $nm_uuid, $coll_uuid)
				if defined $coll_uuid && $coll_uuid ne ($ex->{collection_uuid}//'');
			clearRouteWaypoints($dbh, $nm_uuid);
			_appendRefWaypoints($dbh, $nm_uuid, \@ref_pms, $name);
			return;
		}
		insertRouteUUID($dbh, $nm_uuid, $name, $color, '', $coll_uuid);
		_appendRefWaypoints($dbh, $nm_uuid, \@ref_pms, $name);
	}
	else
	{
		my $route_uuid = insertRoute($dbh, $name, $color, '', $coll_uuid);
		_appendRefWaypoints($dbh, $route_uuid, \@ref_pms, $name);
	}
}


sub _appendRefWaypoints
{
	my ($dbh, $route_uuid, $ref_pms, $route_name) = @_;
	my $pos = 0;
	for my $pm (@$ref_pms)
	{
		my $wp_uuid = _parseExt($pm)->{nm_uuid} // next;
		if (!getWaypoint($dbh, $wp_uuid))
		{
			warning(0,0,"navKML: route '$route_name' ref to unknown waypoint '$wp_uuid' - skipped");
			next;
		}
		appendRouteWaypoint($dbh, $route_uuid, $wp_uuid, $pos++);
	}
}


sub _colorFromStyle
{
	my ($style_url, $type) = @_;
	return undef if !$style_url;
	return $1 if $style_url =~ /nm\d+_\Q$type\E_([0-9a-fA-F]{8})/;
	return undef;
}


sub _parseCoords
{
	my ($raw) = @_;
	return () if !$raw;
	my @pts;
	for my $t (split /\s+/, $raw)
	{
		next if $t !~ /,/;
		my ($lon, $lat) = split /,/, $t;
		push @pts, { lat => $lat + 0, lon => $lon + 0 };
	}
	return @pts;
}


1;

