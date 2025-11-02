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
	EVT_IDLE );
use Pub::Utils;
use Pub::WX::Window;
use a_defs;
use a_utils;
use c_RAYSYS;
use d_DBNAV;
# use e_DBNAV;
use base qw(Wx::ScrolledWindow Pub::WX::Window);

my $dbg_win = 0;


my $CHANGE_TIMEOUT = 5;


my $HEADER_Y = 45;
my $TOP_MARGIN = 70;
my $LEFT_MARGIN = 10;
my $LINE_HEIGHT = 24;

my $COL_TTL = 1;
my $COL_HEX = 4;
my $COL_VALUE = 6;
my @COL_WIDTHS = (
	5,      # $COL_FID
	4,		# $COL_TTL
	5,		# $COL_TYPE
	4,      # $COL_SUB
	18,		# $COL_HEX
	16,     # $COL_NAME
	50,     # $COL_VALUE
);

my $COL_TOTAL = 0;
$COL_TOTAL += $_ for @COL_WIDTHS;

my @COL_NAMES = qw(
	FID
	TTL
	TYPE
	SUB
	HEX
	NAME
	VALUE );

my $ID_HEADER_BASE = 1000;




my $font_fixed = Wx::Font->new(11,wxFONTFAMILY_MODERN,wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD);


sub new
{
	my ($class,$frame,$book,$id,$data) = @_;
	my $this = $class->SUPER::new($book,$id);
	display(0,0,"winDBNAV::new() called");
	$this->MyWindow($frame,$book,$id,'DBNAV',$data);

	$this->SetFont($font_fixed);
	my $dc = Wx::ClientDC->new($this);
	$dc->SetFont($font_fixed);
	my $CHAR_WIDTH = $this->{CHAR_WIDTH} = $dc->GetCharWidth();
	display($dbg_win,1,"CHAR_WIDTH=$CHAR_WIDTH");

	my $offset = 0;
	for (my $i=0; $i<@COL_WIDTHS; $i++)
	{
		my $ctrl = Wx::StaticText->new($this,$ID_HEADER_BASE+$i,$COL_NAMES[$i], [$this->X($offset),$HEADER_Y]);
		$ctrl->SetForegroundColour($wx_color_blue);
		$offset += $COL_WIDTHS[$i];
	}

	$this->{slots} = [];
		# a record per visual slot on the screen
	$this->{field_values} = {};
		# the last gotten field values by fid

	EVT_IDLE($this,\&onIdle);
	return $this;
}


sub clear
{
	my ($this) = @_;
	my $offset = 0;

	$this->DestroyChildren();
	$this->{slots} = [];
	#	for my $child ($this->GetChildren())
	#	{
	#		# display(0,0,"child_id=".$child->GetId());
	#		$child->Destroy() if $child->GetId() < 0;	# I expected -1, but get a range of negative numbers
	#		#$this->RemoveChild($child); # if $child->GetId() == -1;
	#	}

	for (my $i=0; $i<@COL_WIDTHS; $i++)
	{
		my $ctrl = Wx::StaticText->new($this,$ID_HEADER_BASE+$i,$COL_NAMES[$i], [$this->X($offset),$HEADER_Y]);
		$ctrl->SetForegroundColour($wx_color_blue);
		$offset += $COL_WIDTHS[$i];
	}
	$this->SetVirtualSize([$COL_TOTAL * $this->{CHAR_WIDTH} + 10,$TOP_MARGIN]);
	$this->SetScrollRate(0,$LINE_HEIGHT);

}


sub X
{
	my ($this,$col) = @_;
	return $LEFT_MARGIN + $this->{CHAR_WIDTH} * $col;
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


sub onIdle
{
	my ($this,$event) = @_;
	$event->RequestMore(1);
	# sleep(0.1);
		# dunno why but this keeps it from freaking out

	my $dbnav = $raysys->findImplementedService('DBNAV',1);
	return if !$dbnav;
	lock($dbnav);
		# return if $dbnav->{in_record};

	# Add any new, or delete any missing field_values

	my $need_new_slots = 0;
	my $field_values = $this->{field_values};
	my $dbnav_field_values = $dbnav->getFieldValues();
	display($dbg_win+3,0,"working on ".scalar(keys  %$dbnav_field_values)." d_DBNAV values");

	for my $fid (keys %$field_values)
	{
		$field_values->{$fid}->{found} = 0;
	}

	for my $fid (keys %$dbnav_field_values)
	{
		my $dbnav_field_value = $dbnav_field_values->{$fid};
		my $value_name = $dbnav_field_value->{name};
		next if $value_name eq 'SUBRECORD';
			# too weird to deal with right now
		my $found = $field_values->{$fid};

		
		if ($found)
		{
			display($dbg_win+1,0,"onIdle found $fid=$value_name");
			
			$found->{found} = 1;
			if ($found->{value} ne $dbnav_field_value->{value})
			{
				display($dbg_win+1,1,"onIdle $value_name value changed");
				$found->{value} = $dbnav_field_value->{value};
				$found->{data}  = $dbnav_field_value->{data};
				$found->{changed} = 1;
				$found->{change_time} = time();
			}
			if ($found->{ttl} != $dbnav_field_value->{ttl})
			{
				$found->{ttl_changed} = 1;
				# display(0,0,"ttl changed from $found->{ttl} to $dbnav_field_value->{ttl}");
				# there are ttls that bop around (5 to six), especially starting AP (31 to 5)
				$found->{ttl} = $dbnav_field_value->{ttl};
			}
		}
		else
		{
			display($dbg_win+1,0,"onIdle adding $fid=$value_name");
			
			my $field_value = {};
			mergeHash($field_value,$dbnav_field_value);
				# denormalize from shared_memory
				
			$need_new_slots = 1;
			$field_value->{found} = 1;
			$field_value->{fid} = $fid;
			$field_value->{changed} = 1;
			$field_value->{change_time} = time();
			$field_values->{$fid} = $field_value;
		}
	}

	for my $fid (keys %$field_values)
	{
		my $field_value = $field_values->{$fid};
		if (!$field_value->{found})
		{
			my $dbg_name = $field_value->{name};
			display($dbg_win+1,0,"onIdle deleting $fid=$dbg_name");
			$need_new_slots = 1;
			delete $field_values->{$fid};
		}
	}
	

	# Create new sorted slots if needed

	if ($need_new_slots)
	{
		# get rid of all the slots and control children

		display(0,0,"creating new slots");
		$this->clear();

		my $rec_num = 0;
		my $slots = $this->{slots};
		for my $fid (sort {$a <=> $b} keys %$field_values)
		{
			my $field_value = $field_values->{$fid};

			my $name = $field_value->{name};
			my $value = valueToText($name,$field_value->{value});
			my $hex = _lim(unpack('H*',$field_value->{data}),16);
			my $extra = unpack('H*',$field_value->{extra} || '');
			$value .= " extra($field_value->{extra})" if $field_value->{extra};
			
			my @show;
			push @show, sprintf("%02x",$fid);
			push @show,	$field_value->{ttl};
			push @show,	sprintf("%02x",$field_value->{type});
			push @show,	sprintf("%02x",$field_value->{subtype});
			push @show, $hex;
			push @show,	$name;
			push @show,	$value;

			my @controls;
			my $offset = 0;
			my $col_num = 0;
			my $ypos = $TOP_MARGIN + $rec_num * $LINE_HEIGHT;
			for my $width (@COL_WIDTHS)
			{
				my $pixels = $width * $this->{CHAR_WIDTH};
				error("UNDEFINED show($col_num)") if !defined($show[$col_num]);
				push @controls, Wx::StaticText->new($this,-1,$show[$col_num], [$this->X($offset),$ypos], [$pixels,$LINE_HEIGHT] );
				$offset += $width;
				$col_num++;
			}

			my $slot = {
				controls	=> \@controls,
				field_value => $field_value,
				color		=> wxBLACK,
			};

			push @$slots,$slot;
			$rec_num++;
		}

		# $this->Update();
		$this->SetVirtualSize([$COL_TOTAL * $this->{CHAR_WIDTH} + 10,$TOP_MARGIN + $rec_num*$LINE_HEIGHT ]);

	}	# $need_new_slots

	# handle color changes

	my $now = time();

	for my $slot (@{$this->{slots}})
	{
		my $field_value = $slot->{field_value};
		next if
			!$field_value->{changed} &&
			!$field_value->{change_time} &&
			!$field_value->{ttl_changed} &&
			!$field_value->{ttl_change_time};
		
		my $controls = $slot->{controls};
		my $ttl_changed = $field_value->{ttl_changed};
		my $ttl_change_time = $field_value->{ttl_change_time};

		if ($ttl_changed)
		{
			$field_value->{ttl_changed} = 0;
			$field_value->{ttl_change_time} = $now;
			$controls->[$COL_TTL]->SetLabel($field_value->{ttl});
			$controls->[$COL_TTL]->SetForegroundColour($wx_color_magenta);
		}
		elsif ($ttl_change_time && $now>$ttl_change_time + $CHANGE_TIMEOUT)
		{
			$field_value->{ttl_change_time} = 0;
			$controls->[$COL_TTL]->SetForegroundColour(wxBLACK);
			$controls->[$COL_TTL]->Refresh();
		}

		my $ctrl = $controls->[$COL_VALUE];
		my $hex_ctrl = $controls->[$COL_HEX];
		my $change_time = $field_value->{change_time};
		my $is_color = $slot->{color};
		my $should_be = ($now > $change_time + $CHANGE_TIMEOUT) ? wxBLACK : $wx_color_red;

		if ($field_value->{changed})
		{
			$field_value->{changed} = 0;
			my $value = valueToText($field_value->{name},$field_value->{value});
			$value .= " extra($field_value->{extra})" if $field_value->{extra};

			$ctrl->SetLabel($value);
			my $hex = _lim(unpack('H*',$field_value->{data}),16);
			$hex_ctrl->SetLabel($hex);
		}
		if ($is_color != $should_be)
		{
			$slot->{color} = $should_be;
			$ctrl->SetForegroundColour($should_be);
			$ctrl->Refresh();
			$field_value->{change_time} = 0 if $should_be == wxBLACK;
		}
	}

}






1;
