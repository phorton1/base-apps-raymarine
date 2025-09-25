#!/usr/bin/perl
#-------------------------------------------------------------------------
# winRAYDP.pm
#-------------------------------------------------------------------------
# A Window reflecting the Raynet Discovery Protocol
# that allows for control of shark monitoring


package apps::raymarine::NET::winRAYDP;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_IDLE
	EVT_CHECKBOX
	EVT_COMBOBOX );
use Pub::Utils;
use Pub::WX::Window;
use apps::raymarine::NET::r_utils;
use apps::raymarine::NET::r_RAYDP;
use base qw(Wx::Window MyWX::Window);

my $dbg_win = 0;

my $TOP_MARGIN = 50;
my $LEFT_MARGIN = 10;
my $LINE_HEIGHT = 24;

my $COL_FUNC 		= 0;	# width 2
my $COL_FUNCID 		= 4;	# width 8
my $COL_NAME 		= 14;	# width 8
my $COL_PROTO		= 24;	# width 3
my $COL_IP			= 29;	# width 15
my $COL_PORT		= 46;	# width 6
my $COL_IN_BOX		= 54;
my $COL_OUT_BOX		= 62;
my $COL_COLOR		= 70;	# width 14

my $ID_MON_RAYDP_ALIVE	= 901;
my $MON_IN_BOX_ID_BASE 	= 1000;
my $MON_OUT_BOX_ID_BASE = 1100;
my $MON_COMBO_ID_BASE 	= 1200;
	# Apps should only use control IDs >= 200 !!!
	# As Pub::WX::Frame disables the standard "View" menu commands
	# $CLOSE_ALL_PANES = 101 and/or $CLOSE_OTHER_PANES = 102 based
	# on pane existence.


my $font_fixed = Wx::Font->new(11,wxFONTFAMILY_MODERN,wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD);


sub new
{
	my ($class,$frame,$book,$id,$data) = @_;
	my $this = $class->SUPER::new($book,$id);
	display(0,0,"winRAYDP::new() called");
	$this->MyWindow($frame,$book,$id,"RAYDP");

	$this->SetFont($font_fixed);
	
	my $dc = Wx::ClientDC->new($this);
	$dc->SetFont($font_fixed);
	my $CHAR_WIDTH = $this->{CHAR_WIDTH} = $dc->GetCharWidth();
	display($dbg_win,1,"CHAR_WIDTH=$CHAR_WIDTH");

	# Wx::StaticText->new($this,-1,"static text",[10,10]);
	# EVT_CLOSE($this,\&onClose);

	my $alive = Wx::CheckBox->new($this,$ID_MON_RAYDP_ALIVE,"monitor RAYDP alive",[10,10]);
	$alive->SetValue(1) if $MONITOR_RAYDP_ALIVE;

	$this->{num_ports} = 0;
	$this->{line_num} = 0;

	EVT_IDLE($this,\&onIdle);
	EVT_CHECKBOX($this,-1,\&onCheckBox);
	EVT_COMBOBOX($this,-1,\&onComboBox);
	return $this;
}



sub X
{
	my ($this,$col) = @_;
	return $LEFT_MARGIN + $this->{CHAR_WIDTH} * $col;
}


sub onIdle
{
	my ($this,$event) = @_;
	my $ports = getRayPorts();
	my $num_ports = @$ports;
	if ($this->{num_ports} != $num_ports)
	{
		my $prev_key = '';
		for (my $i=$this->{num_ports}; $i<$num_ports; $i++)
		{
			my $port = $ports->[$i];

			my $ypos = $TOP_MARGIN + $i * $LINE_HEIGHT;
			my $key = "$port->{func}:$port->{id}";

			display(1,0,"adding port ".
				"$port->{func}:$port->{name} $port->{proto} $port->{addr} ".
				"in($port->{mon_in}) out($port->{mon_out}) ".
				"color($port->{color}) multi($port->{multi})");

			if ($prev_key ne $key)
			{
				$prev_key = $key;
				Wx::StaticText->new($this,-1,$port->{func},[$this->X($COL_FUNC),$ypos]);
				Wx::StaticText->new($this,-1,$port->{id},[$this->X($COL_FUNCID),$ypos]);
			}

			Wx::StaticText->new($this,-1,$port->{name},[$this->X($COL_NAME),$ypos]);
			Wx::StaticText->new($this,-1,$port->{proto},[$this->X($COL_PROTO),$ypos]);
			Wx::StaticText->new($this,-1,$port->{ip},[$this->X($COL_IP),$ypos]);
			Wx::StaticText->new($this,-1,$port->{port},[$this->X($COL_PORT),$ypos]);

			my $in_id = $MON_IN_BOX_ID_BASE + $i;
			my $out_id = $MON_OUT_BOX_ID_BASE + $i;
			my $in_box = Wx::CheckBox->new($this,$in_id,"in",[$this->X($COL_IN_BOX),$ypos]);
			my $out_box = Wx::CheckBox->new($this,$out_id,"out",[$this->X($COL_OUT_BOX),$ypos]);

			$in_box->SetValue(1) if $port->{mon_in};
			$out_box->SetValue(1) if $port->{mon_out};

			my $color = $color_names[$port->{color}];
			my $combo_id = $MON_COMBO_ID_BASE + $i;
			my $combo = Wx::ComboBox->new($this, $combo_id, $color,
				[$this->X($COL_COLOR),$ypos-2],wxDefaultSize,\@color_names,wxCB_READONLY);

		}
		$this->{num_ports} = $num_ports;
	}
	
	$event->RequestMore(1);
}



sub onCheckBox
{
	my ($this,$event) = @_;
	my $id = $event->GetId();
	my $checked = $event->IsChecked() || 0;
	if ($id == $ID_MON_RAYDP_ALIVE)
	{
		$MONITOR_RAYDP_ALIVE = $checked;
		warning(0,0,"MON_RAYDP_ALIVE=$MONITOR_RAYDP_ALIVE");
	}
	else
	{
		my $field = "mon_in";
		my $port_num = $id - $MON_IN_BOX_ID_BASE;
		if ($id >= $MON_OUT_BOX_ID_BASE)
		{
			$field = "mon_out";
			$port_num = $id - $MON_OUT_BOX_ID_BASE;
		}

		my $ports = getRayPorts();
		my $port = $ports->[$port_num];
		$port->{$field} = $checked;

		warning(0,0,"$field($checked) $port->{proto} $port->{addr}");
	}
}





sub onComboBox
	# reset filter and repopulate
	# on any checkbox clicks
{
	my ($this,$event) = @_;
	my $id = $event->GetId();
	my $combo = $event->GetEventObject();
	my $selected = $combo->GetValue();
	my $value = $color_values->{$selected};
	my $port_num = $id - $MON_COMBO_ID_BASE;
	my $ports = getRayPorts();
	my $port = $ports->[$port_num];
	$port->{color} = $value;
	warning(0,0,"color($selected)=$value $port->{proto} $port->{addr}");
}

	

1;
