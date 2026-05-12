#!/usr/bin/perl
#---------------------------------------------
# navLeaflet.pm
#---------------------------------------------
# Dispatches track/route-edit commands posted from the Leaflet map client.
# Called from nmFrame::onIdle on the Wx thread.
#
# Track ops (via POST /track/edit):
#   update  - replace all points of an existing track
#   split   - split a track at a vertex index; second segment gets new_name
#   join    - merge two db tracks at chosen vertices; second track is deleted
#
# Route ops (via POST /route/edit, db-only):
#   full_update - rewrite all route_waypoints; create new WPs for uuid=null entries
#   split       - split route at vertex index; second route gets new_name
#   create      - create new route with all-new waypoints

package navLeaflet;
use strict;
use warnings;
use JSON::PP qw(decode_json);
use Pub::Utils qw(display warning error);
use nmResources qw($WIN_DATABASE $WIN_FSH);

my $dbg_nl = 1;

BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(dispatchTrackEdit dispatchRouteEdit);
}


sub dispatchTrackEdit
{
	my ($main_win, $edit_json) = @_;
	my $edit = eval { decode_json($edit_json) };
	if ($@) { warning(0,0,"navLeaflet: bad JSON: $@"); return; }

	my $op     = $edit->{op}     // '';
	my $source = $edit->{source} // '';
	display($dbg_nl,0,"navLeaflet::dispatchTrackEdit op=$op source=$source");

	if ($source eq 'db')
	{
		my $database = $main_win->findPane($WIN_DATABASE);
		if ($database)
		{
			$database->onLeafletTrackEdit($edit);
		}
		else
		{
			warning(0,0,"navLeaflet: dispatchTrackEdit - no DATABASE pane");
		}
	}
	elsif ($source eq 'fsh')
	{
		my $fsh = $main_win->findPane($WIN_FSH);
		if ($fsh)
		{
			$fsh->onLeafletTrackEdit($edit);
		}
		else
		{
			warning(0,0,"navLeaflet: dispatchTrackEdit - no FSH pane");
		}
	}
	else
	{
		warning(0,0,"navLeaflet: unknown source '$source'");
	}
}


sub dispatchRouteEdit
{
	my ($main_win, $edit_json) = @_;
	my $edit = eval { decode_json($edit_json) };
	if ($@) { warning(0,0,"navLeaflet: bad JSON: $@"); return; }

	my $op  = $edit->{op}  // '';
	display($dbg_nl,0,"navLeaflet::dispatchRouteEdit op=$op");

	my $database = $main_win->findPane($WIN_DATABASE);
	if ($database)
	{
		$database->onLeafletRouteEdit($edit);
	}
	else
	{
		warning(0,0,"navLeaflet: dispatchRouteEdit - no DATABASE pane");
	}
}


1;
