#!/usr/bin/perl
#-------------------------------------------------------------------------
# winRAYDP.pm
#-------------------------------------------------------------------------
# A Window reflecting the Raynet Discovery Protocol
# that allows for control of shark monitoring.
#
# Allows sorting by func,id,port, port,id,func, or num=raw order of addition



package winRAYDP;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_IDLE
	EVT_CHECKBOX
	EVT_COMBOBOX );
use Pub::Utils;
use Pub::WX::Window;
use r_utils;
use r_RAYDP;
use base qw(Wx::ScrolledWindow MyWX::Window);

my $dbg_win = 0;

my $TOP_MARGIN = 50;
my $LEFT_MARGIN = 10;
my $LINE_HEIGHT = 24;

my $COL_FUNC 		= 0;
my $COL_FUNCID 		= 4;
my $COL_NAME 		= 14;
my $COL_PROTO		= 24;
my $COL_IP			= 30;
my $COL_PORT		= 47;
my $COL_FROM_BOX	= 55;
my $COL_TO_BOX		= 63;
my $COL_MULTI		= 71;
my $COL_LISTEN		= 81;
my $COL_COLOR		= 93;	# width 14
my $COL_TOTAL		= 107;


my $ID_MON_RAYDP_ALIVE	= 901;
my $ID_SORT_BY			= 902;

my $SORT_BYS = ['func','port','num'];



my $MON_FROM_ID_BASE 	= 1000;
my $MON_TO_ID_BASE 		= 1100;
my $MULTI_ID_BASE		= 1200;
my $LISTEN_ID_BASE  	= 1300;
my $COLOR_ID_BASE 		= 1400;

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

	Wx::StaticText->new($this,-1,'Sort by',[320,12]);
	Wx::ComboBox->new($this, $ID_SORT_BY, $$SORT_BYS[0],
		[400,10],wxDefaultSize,$SORT_BYS,wxCB_READONLY);

	$this->{sort_by} = 'func';
	$this->{slots} = [];
		# the id:ip:port occupying this y position in the table
	$this->{rayports} = {};
		# hash by id:ip:port

	$this->SetVirtualSize([$COL_TOTAL * $CHAR_WIDTH + 10,$TOP_MARGIN]);
	$this->SetScrollRate(0,$LINE_HEIGHT);

	EVT_IDLE($this,\&onIdle);
	EVT_CHECKBOX($this,-1,\&onCheckBox);
	EVT_COMBOBOX($this,-1,\&onComboBox);
	return $this;
}




sub cmpRecords
{
	my ($this,$keyA, $keyB) = @_;
	my $sort_by = $this->{sort_by};

	my $rayports = $this->{rayports};
	my $recA = $rayports->{$keyA};
	my $recB = $rayports->{$keyB};
	return $recA->{num} <=> $recB->{num} if $sort_by eq 'num';

	my $cmp;
	my $funcA = $recA->{func};
	my $funcB = $recB->{func};
	my $idA	= $recA->{id};
	my $idB = $recB->{id};
	my $portA = $recA->{port};
	my $portB = $recB->{port};

	if ($sort_by eq 'port')
	{
		$cmp = $portA <=> $portB;
		return $cmp if $cmp;
		$cmp = $idA cmp $idB;
		return $cmp if $cmp;
		$cmp = $funcA <=> $funcB;
		return $cmp if $cmp;
	}
	else	# sort_by == 'func'
	{
		$cmp = $funcA <=> $funcB;
		return $cmp if $cmp;
		$cmp = $idA cmp $idB;
		return $cmp if $cmp;
		$cmp = $portA <=> $portB;
		return $cmp if $cmp;
	}
	return 0;
}



sub sortRecords
{
	my ($this) = @_;

	my $sort_by 	= $this->{sort_by};
	my $slots   	= $this->{slots};
	my $num_slots   = @$slots;
	
	my $rayports = $this->{rayports};
	my @slot_keys = keys %$rayports;
	@slot_keys = sort { $this->cmpRecords($a,$b) } @slot_keys;

	# repopulate any slots that don't have the correct slot_key

	for (my $i=0; $i<$num_slots; $i++)
	{
		my $slot = $$slots[$i];
		my $slot_key = $slot_keys[$i];
		my $rayport = $rayports->{$slot_key};

		if ($slot->{key} ne $slot_key)
		{
			$slot->{key} = $slot_key;

			$slot->{ctrl_func}	->SetLabel($rayport->{func});
			$slot->{ctrl_id}	->SetLabel($rayport->{id});
			$slot->{ctrl_name}	->SetLabel($rayport->{name});
			$slot->{ctrl_proto}	->SetLabel($rayport->{proto});
			$slot->{ctrl_ip}	->SetLabel($rayport->{ip});
			$slot->{ctrl_port}	->SetLabel($rayport->{port});

			$slot->{from_box}->SetValue($rayport->{mon_from});
			$slot->{out_box}->SetValue($rayport->{mon_to});
			$slot->{multi}->SetValue($rayport->{multi});
			$slot->{listen}->SetValue($rayport->{listen});

			my $disable_listen = $rayport->{proto} =~ /mcast|udp/ || $rayport->{listen};
			$slot->{listen}->Enable(!$disable_listen);

			my $color = $color_names[$rayport->{color}];
			$slot->{ctrl_color}->SetValue($color);
		}
	}
}



sub X
{
	my ($this,$col) = @_;
	return $LEFT_MARGIN + $this->{CHAR_WIDTH} * $col;
}


sub onIdle
{
	my ($this,$event) = @_;
	my $rayports = getRayPorts();

	my $slots = $this->{slots};
	my $num_slots = @$slots;
	my $num_rayports = @$rayports;
	if ($num_slots != $num_rayports)
	{
		# add the new records from RAY_DP (which are in first come order)
		# into the hash of rayports by id:ip:port, and then call populate(),
		# creating controls for them as we go, that will be fixed up in
		# sortSlots.

		my $my_rayports = $this->{rayports};
		for (my $i=$num_slots; $i<$num_rayports; $i++)
		{
			my $rayport = $rayports->[$i];
			my $id = $rayport->{id};
			my $ip = $rayport->{ip};
			my $port = $rayport->{port};
			my $key = "$ip:$port";

			display(0,0,"adding rayport".
				"$rayport->{func}:$rayport->{name} $rayport->{proto} $rayport->{addr} ".
				"in($rayport->{mon_from}) out($rayport->{mon_to}) ".
				"color($rayport->{color}) multi($rayport->{multi})");

			$my_rayports->{$key} = $rayport;

			my $ypos = $TOP_MARGIN + $i * $LINE_HEIGHT;

			my $from_id = $MON_FROM_ID_BASE + $i;
			my $to_id = $MON_TO_ID_BASE + $i;
			my $multi_id = $MULTI_ID_BASE + $i;
			my $listen_id = $LISTEN_ID_BASE + $i;

			my $from_box = Wx::CheckBox->new($this,$from_id,"from",[$this->X($COL_FROM_BOX),$ypos]);
			my $to_box = Wx::CheckBox->new($this,$to_id,"to",[$this->X($COL_TO_BOX),$ypos]);
			my $multi = Wx::CheckBox->new($this,$multi_id,"multi",[$this->X($COL_MULTI),$ypos]);
			my $listen = Wx::CheckBox->new($this,$listen_id,"listen",[$this->X($COL_LISTEN),$ypos]);

			$from_box->SetValue(1) if $rayport->{mon_from};
			$to_box->SetValue(1) if $rayport->{mon_to};
			$multi->SetValue(1) if $rayport->{multi};
			$listen->SetValue(1) if $rayport->{listen};		# local to winRAYDP layer

			$listen->Enable(0) if $rayport->{proto} =~ /mcast|udp/ || $rayport->{listen};

			my $color = $color_names[$rayport->{color}];
			my $combo_id = $COLOR_ID_BASE + $i;
			my $combo = Wx::ComboBox->new($this, $combo_id, $color,
				[$this->X($COL_COLOR),$ypos-2],wxDefaultSize,\@color_names,wxCB_READONLY);

			push @$slots,{
				key => $key,
				ctrl_func 	=> Wx::StaticText->new($this,-1,$rayport->{func},[$this->X($COL_FUNC),$ypos]),
				ctrl_id		=> Wx::StaticText->new($this,-1,$rayport->{id},[$this->X($COL_FUNCID),$ypos]),
				ctrl_name 	=> Wx::StaticText->new($this,-1,$rayport->{name},[$this->X($COL_NAME),$ypos]),
				ctrl_proto	=> Wx::StaticText->new($this,-1,$rayport->{proto},[$this->X($COL_PROTO),$ypos]),
				ctrl_ip 	=> Wx::StaticText->new($this,-1,$rayport->{ip},[$this->X($COL_IP),$ypos]),
				ctrl_port 	=> Wx::StaticText->new($this,-1,$rayport->{port},[$this->X($COL_PORT),$ypos]),
				from_box	=> $from_box,
				out_box     => $to_box,
				multi		=> $multi,
				listen		=> $listen,
				ctrl_color  => $combo,
			};
		}

		$this->SetVirtualSize([$COL_TOTAL * $this->{CHAR_WIDTH} + 10,$TOP_MARGIN + scalar(@$slots)*$LINE_HEIGHT ]);
		$this->sortRecords();
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
		my $field = "mon_from";
		my $slot_num = $id - $MON_FROM_ID_BASE;
		if ($id >= $LISTEN_ID_BASE)
		{
			$field = "listen";
			$slot_num = $id - $LISTEN_ID_BASE;
		}
		elsif ($id >= $MULTI_ID_BASE)
		{
			$field = "multi";
			$slot_num = $id - $MULTI_ID_BASE;
		}
		elsif ($id >= $MON_TO_ID_BASE)
		{
			$field = "mon_to";
			$slot_num = $id - $MON_TO_ID_BASE;
		}
		elsif ($id >= $MON_FROM_ID_BASE)
		{
			$field = "mon_from";
			$slot_num = $id - $MON_FROM_ID_BASE;
		}

		my $slot = $this->{slots}->[$slot_num];
		my $key = $slot->{key};
		my $rayport = $this->{rayports}->{$key};
		$rayport->{$field} = $checked;

		if ($field eq 'listen')
		{
			warning(0,0,"starting tcpListenerThread for func($rayport->{func} $rayport->{addr} $rayport->{proto} $rayport->{name}");
			my $box = $event->GetEventObject();
			$box->Enable(0);
			my $thread = threads->create(\&tcpListenerThread,$rayport->{ip},$rayport->{port});
			display(0,0,"alive_thread created");
			$thread->detach();
			display(0,0,"alive_thread detached");
		}

		warning(0,0,"$rayport->{name}($checked) $rayport->{proto} $rayport->{addr}");
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

	if ($id == $ID_SORT_BY)
	{
		$this->{sort_by} = $selected;
		$this->sortRecords();
	}
	else
	{
		my $value = $color_values->{$selected};
		my $slot_num = $id - $COLOR_ID_BASE;
		my $slot = $this->{slots}->[$slot_num];
		my $key = $slot->{key};
		my $rayport = $this->{rayports}->{$key};
		$rayport->{color} = $value;
		warning(0,0,"color($selected)=$value $rayport->{proto} $rayport->{addr}");
	}
}

	

1;
