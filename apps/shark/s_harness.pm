#---------------------------------------------
# s_harness.pm
#---------------------------------------------
# Shark-only test harness for WPMGR.
# Provides numbered test-item creation and name/integer-to-UUID
# translation for shark serial debug commands.
# Not used by navMate or NET.

package s_harness;
use strict;
use warnings;
use Time::Local;
use Pub::Utils qw(display error);
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::e_wp_defs;

BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(
		resolveUUID
		createTestWaypoint
		createTestRoute
		createTestGroup
	);
}


my $STD_WP_UUID    = 'aaaaaaaaaaaa{int}';
my $STD_ROUTE_UUID = 'bbbbbbbbbbbb{int}';
my $STD_GROUP_UUID = 'cccccccccccc{int}';

my $LAT_LON = [
	[ 9.334083,-82.242050 ],
	[ 9.272120,-82.204624 ],
	[ 9.255866,-82.197158 ],
	[ 9.249720,-82.193311 ],
	[ 9.231067,-82.180733 ],
	[ 9.227000,-82.165517 ],
	[ 9.208679,-82.155577 ],
	[ 9.202670,-82.157985 ],
	[ 9.200271,-82.152427 ],
	[ 9.200832,-82.145835 ],
];


sub std_uuid
{
	my ($template,$int) = @_;
	my $pack = pack('v',$int);
	my $hex  = unpack('H4',$pack);
	$template =~ s/\{int\}/$hex/;
	return $template;
}


sub resolveUUID
	# Translate a name-or-integer to a UUID via the E80 in-memory database.
	# Integer: constructs "testThing$num" name, then looks up UUID.
	# Name: looks up directly.
{
	my ($wpmgr,$what,$id) = @_;
	return undef if !defined $id;
	my $name = ($id =~ /^\d+$/) ? "test\u${what}${id}" : $id;
	return $wpmgr->findUUIDByName($what,$name);
}


sub createTestWaypoint
{
	my ($wpmgr,$num) = @_;
	my $lat_lon = $$LAT_LON[$num - 1];
	return error("createTestWaypoint: no lat/lon for num($num)") if !$lat_lon;
	$wpmgr->createWaypoint({
		name    => "testWaypoint$num",
		uuid    => std_uuid($STD_WP_UUID,$num),
		lat     => $$lat_lon[0],
		lon     => $$lat_lon[1],
		sym     => 2,
		depth   => 10 * $FEET_PER_METER * 10,
		comment => "wpComment$num",
	});
}


sub createTestRoute
{
	my ($wpmgr,$num,$bits) = @_;
	$bits //= 0;
	$wpmgr->createRoute({
		name  => "testRoute$num",
		uuid  => std_uuid($STD_ROUTE_UUID,$num),
		bits  => $bits,
	});
}


sub createTestGroup
{
	my ($wpmgr,$num) = @_;
	$wpmgr->createGroup({
		name => "testGroup$num",
		uuid => std_uuid($STD_GROUP_UUID,$num),
	});
}


1;
