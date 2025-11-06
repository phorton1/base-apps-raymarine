#--------------------------------------------
# fshWriter
#--------------------------------------------
# Uses FSH routines to write an FSH file

package fshWriter;
use strict;
use warnings;
use POSIX qw(floor pow atan);
use Fcntl qw(:seek);
use Time::Local;
use Pub::Utils;
use apps::raymarine::FSH::fshUtils;
use apps::raymarine::FSH::fshFile;
use a_defs;
use a_mon;
use b_records;
use c_RAYSYS;
use Pub::Utils;

my $dbg_fwr = 0;

sub createBlock
{
	my ($fsh_file,$num,$active,$shark_uuid,$type,$bytes) = @_;
	my $uuid = pack('H16',$shark_uuid);
	my $block_type = blockTypeToStr($type);
	my $show_uuid = uuidToStr($uuid);
	my $len = length($bytes);

	display($dbg_fwr,0,"createBlock($block_type) shark($shark_uuid) $show_uuid len($len)");
	push @{$fsh_file->{blocks}},{
		num 	=> $num,
		active 	=> $active,
		uuid 	=> $uuid,
		type 	=> $type,
		bytes 	=> $bytes, };
}


sub write
{
	display($dbg_fwr,0,"fshWriter::write()");
	my $fsh_file = apps::raymarine::FSH::fshFile->new();
	my $wp_mgr = $raysys->findImplementedService('WPMGR');
	my $trk_mgr = $raysys->findImplementedService('TRACK');

	my $mon = 0;
	my $color = $UTILS_COLOR_WHITE;
	
	my $block_num = 0;

	if ($wp_mgr)
	{
		my $hash = $wp_mgr->{waypoints};
		for my $shark_uuid (sort keys %$hash)
		{
			my $item = $hash->{$shark_uuid};
			my $bytes = buildWaypoint(1,$item,$mon,$color);
			createBlock($fsh_file,$block_num++,1,$shark_uuid,$FSH_BLK_WPT,$bytes);
		}
	}

	$fsh_file->write("/junk/test.fsh");

}



1;