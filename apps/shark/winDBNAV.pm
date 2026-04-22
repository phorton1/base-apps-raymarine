#!/usr/bin/perl
#-------------------------------------------------------------------------
# winDBNAV.pm
#-------------------------------------------------------------------------
# A Window reflecting the DBNAV Service Port that
# shows navigation values.


package winDBNAV;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time sleep);
use Wx qw(:everything);
use Wx::Event qw(
	EVT_IDLE
	EVT_SIZE );
use Pub::Utils;
use Pub::WX::Window;
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::a_utils;
use apps::raymarine::NET::c_RAYDP;
# use d_DB;
# use d_DBNAV;
use x_listCtrl;
use base qw(Wx::ScrolledWindow Pub::WX::Window);

my $dbg_win = 0;


my $TOP_MARGIN = 0;


my $COL_FID 	= 0;
my $COL_TTL 	= 1;
my $COL_TYPE 	= 2;
my $COL_SUB 	= 3;
my $COL_EXTRA 	= 4;
my $COL_DATA 	= 5;
my $COL_NAME	= 6;
my $COL_VALUE 	= 7;


my $columns = [
	{name => 'FID',		field_name => 'fid',		width => 5, 	},
	{name => 'TTL',		field_name => 'ttl',		width => 4,		},
	{name => 'TYPE',	field_name => 'type',		width => 5,		},
	{name => 'SUB',		field_name => 'subtype',	width => 4, 	},
	{name => 'EXTRA',	field_name => 'extra',		width => 13,	},
	{name => 'DATA',	field_name => 'data',		width => 18,	},
	{name => 'NAME',	field_name => 'name',		width => 16,	},
	{name => 'VALUE',	field_name => 'value',		width => 50,	},
];



my $instance = 1;

my $font_fixed = Wx::Font->new(11,wxFONTFAMILY_MODERN,wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD);


sub new
{
	my ($class,$frame,$book,$id,$data) = @_;
	my $this = $class->SUPER::new($book,$id);
	display(0,0,"winDBNAV::new() called");
	$this->MyWindow($frame,$book,$id,"DBNAV($instance)",$data,$instance++);

	$this->{list_ctrl} = x_listCtrl->new($this,$TOP_MARGIN,$columns);

	EVT_IDLE($this,\&onIdle);
	EVT_SIZE($this,\&onSize);
	return $this;
}


sub onActivate
{
	my ($this) = @_;
	$this->{list_ctrl}->onSize() if $this->{list_ctrl};
}


sub onSize
{
	my ($this,$event) = @_;
	$this->{list_ctrl}->onSize($event);
}



sub valueToText
{
	my ($name,$value) = @_;
	if ($name =~ /latLon/i)
	{
		my ($lat,$lon) = split(',',$value);
		$value = sprintf("%-11.5f %-11.5f == %-11s %-11s",
			$lat,
			$lon,
			degreeMinutes($lat),
			degreeMinutes($lon));
	}
	elsif ($name =~ /northEast/i)
	{
		my ($north,$east) = split(',',$value);
		my $coords = northEastToLatLon($north,$east);
		$value = sprintf("%-11d %-11d == %-11s %-11s",
			$north,
			$east,
			degreeMinutes($coords->{lat}),
			degreeMinutes($coords->{lon}));
	}
	elsif ($name =~ /WindAngle/)
	{
		my $char = 'S';
		my $use_angle = $value;
		if ($use_angle > 180)
		{
			$char = 'P';
			$use_angle = 360-$use_angle;
		}
		$value = sprintf("%-5.1f == %5.1f $char",$value,$use_angle);
	}
	
	return $value;
}


# sub fullFidName
# {
# 	my ($fid) = @_;
# 	my $field_def = $DB_FIELDS{$fid};
# 	my $name = $field_def ? $field_def->{name} : 'UNKNOWN';
# 	return sprintf("$name(%02x)",$fid);
# }


sub getDisplayValue
	# required by list_ctrl
{
	my ($this,$rec,$col_num,$value) = @_;

	my $name = $rec->{name};

	$value = valueToText($name,$value) if $col_num == $COL_VALUE;
	$value = _lim(unpack('H*',$value),16) if $col_num == $COL_DATA;
	$value = sprintf("%02x",$value) if
		$col_num == $COL_FID ||
		$col_num == $COL_TYPE ||
		$col_num == $COL_SUB;

	return $value;
}


sub cmpRecs
	# required by list_ctrl
{
	my ($this,$sort_col,$sort_desc,$recs,$keyA,$keyB) = @_;
	my $field_name = $columns->[$sort_col]->{field_name};
	my $val_a = $recs->{$keyA}->{$field_name};
	my $val_b = $recs->{$keyB}->{$field_name};
	if ($sort_desc)
	{
		my $tmp = $val_a;
		$val_a = $val_b;
		$val_b = $tmp;
	}
	return $val_a <=> $val_b if
		$sort_col == $COL_FID ||
		$sort_col == $COL_TTL ||
		$sort_col == $COL_TYPE ||
		$sort_col == $COL_SUB;
	if ($sort_col == $COL_DATA)
	{
		my $len = length($val_a);
		my $cmp = $len <=> length($val_b);
		return $cmp if $cmp;

		return unpack('C',$val_a) <=> unpack('C',$val_b)
			if $len == 1;
		return unpack('v',$val_a) <=> unpack('v',$val_b)
			if $len == 2;
		return unpack('V',$val_a) <=> unpack('v',$val_b)
			if $len == 4;
		return unpack('H*',$val_a) cmp unpack('H*',$val_b)
	}
	return lc($val_a) cmp lc($val_b);
}




sub onIdle
{
	my ($this,$event) = @_;
	$event->RequestMore(1);

	my $dbnav = $raydp->findImplementedService('DBNAV',1);
	return if !$dbnav;
	lock($dbnav);

	my $new_recs = $dbnav->getFieldValues();
	$this->{list_ctrl}->notifyData($new_recs);
}






1;
