#!/usr/bin/perl
#-------------------------------------------------------------------------
# winRAYSYS.pm
#-------------------------------------------------------------------------
# A Window reflecting the Raynet Discovery Protocol
# that allows for control of shark monitoring.
#
# Allows sorting by func,id,port, port,id,func, or num=raw order of addition



package winRAYSYS;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Wx qw(:everything);
use Wx::Event qw(
	EVT_IDLE
	EVT_CHECKBOX
	EVT_COMBOBOX );
use Pub::Utils;
use Pub::WX::Window;
use a_defs;
use a_utils;
use c_RAYSYS;
use base qw(Wx::ScrolledWindow MyWX::Window);

my $dbg_win = 0;

my $TOP_MARGIN = 50;
my $LEFT_MARGIN = 10;
my $LINE_HEIGHT = 24;

my $COL_DEVICE_ID 	= 0;
my $COL_SERVICE_ID 	= 10;
my $COL_NAME 		= 14;
my $COL_PROTO		= 24;
my $COL_IP			= 30;
my $COL_PORT		= 47;
my $COL_SPAWN		= 55;
my $COL_TOTAL		= 67;

#	my $COL_FROM_BOX	= 55;
#	my $COL_TO_BOX		= 63;
#	my $COL_MULTI		= 71;
#	my $COL_LISTEN		= 81;
#	my $COL_COLOR		= 93;	# width 14
#	my $COL_TOTAL		= 107;




my $SORT_BYS = ['port','service','device','num'];


my $ID_SORT_BY			= 902;
my $SPAWN_ID_BASE		= 1000;
my $MON_FROM_ID_BASE 	= 1100;
my $MON_TO_ID_BASE 		= 1200;
my $MULTI_ID_BASE		= 1300;
my $LISTEN_ID_BASE  	= 1400;
my $COLOR_ID_BASE 		= 1500;
	# Apps should only use control IDs >= 200 !!!
	# ... as Pub::WX::Frame disables the standard "View" menu commands
	# $CLOSE_ALL_PANES = 101 and/or $CLOSE_OTHER_PANES = 102 based
	# on pane existence.



my $font_fixed = Wx::Font->new(11,wxFONTFAMILY_MODERN,wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD);


sub new
{
	my ($class,$frame,$book,$id,$data) = @_;
	my $this = $class->SUPER::new($book,$id);
	display(0,0,"winRAYSYS::new() called");
	$this->MyWindow($frame,$book,$id,"RAYSYS");

	$this->SetFont($font_fixed);
	my $dc = Wx::ClientDC->new($this);
	$dc->SetFont($font_fixed);
	my $CHAR_WIDTH = $this->{CHAR_WIDTH} = $dc->GetCharWidth();
	display($dbg_win,1,"CHAR_WIDTH=$CHAR_WIDTH");

	Wx::StaticText->new($this,-1,'Sort by',[10,13]);
	Wx::ComboBox->new($this, $ID_SORT_BY, $$SORT_BYS[0],
		[84,10],wxDefaultSize,$SORT_BYS,wxCB_READONLY);

	$this->{sort_by} = $$SORT_BYS[0];
	$this->{slots} = [];
		# a record identifying which service_port occupies
		# the given row of the display
	$this->{service_ports} = {};
		# hash by addr of existing service_ports

	$this->SetVirtualSize([$COL_TOTAL * $CHAR_WIDTH + 10,$TOP_MARGIN]);
	$this->SetScrollRate(0,$LINE_HEIGHT);

	EVT_IDLE($this,\&onIdle);
	EVT_CHECKBOX($this,-1,\&onCheckBox);
	EVT_COMBOBOX($this,-1,\&onComboBox);
	return $this;
}


#------------------------------------
# event handlers
#------------------------------------

sub onCheckBox
{
	my ($this,$event) = @_;
	my $id = $event->GetId();
	my $checked = $event->IsChecked() || 0;

	my $field = "spawn";
	my $slot_num = $id - $SPAWN_ID_BASE;

	#	if ($id >= $LISTEN_ID_BASE)
	#	{
	#		$field = "listen";
	#		$slot_num = $id - $LISTEN_ID_BASE;
	#	}
	#	elsif ($id >= $MULTI_ID_BASE)
	#	{
	#		$field = "multi";
	#		$slot_num = $id - $MULTI_ID_BASE;
	#	}
	#	elsif ($id >= $MON_TO_ID_BASE)
	#	{
	#		$field = "mon_to";
	#		$slot_num = $id - $MON_TO_ID_BASE;
	#	}
	#	elsif ($id >= $MON_FROM_ID_BASE)
	#	{
	#		$field = "mon_from";
	#		$slot_num = $id - $MON_FROM_ID_BASE;
	#	}
	# $service_port->{$field} = $checked;

	my $slot = $this->{slots}->[$slot_num];
	my $key = $slot->{key};
	my $service_port = $this->{service_ports}->{$key};
	my $name = $service_port->{name};

	display(0,0,"$name $field($checked) $service_port->{proto} $service_port->{addr}");
	$raysys->spawnServicePortByName($name,$checked) if $field eq 'spawn';

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
	#	else
	#	{
	#		my $value = $console_color_values->{$selected};
	#		my $slot_num = $id - $COLOR_ID_BASE;
	#		my $slot = $this->{slots}->[$slot_num];
	#		my $key = $slot->{key};
	#		my $service_port = $this->{service_ports}->{$key};
	#		$service_port->{color} = $value;
	#		warning(0,0,"color($selected)=$value $service_port->{proto} $service_port->{addr}");
	#	}
}



#----------------------------------------------------
# sort
#----------------------------------------------------

sub cmpRecords
{
	my ($this,$keyA, $keyB) = @_;
	my $sort_by = $this->{sort_by};

	my $service_ports = $this->{service_ports};
	my $recA = $service_ports->{$keyA};
	my $recB = $service_ports->{$keyB};
	return $recA->{num} <=> $recB->{num} if $sort_by eq 'num';

	my $cmp;
	my $service_idA = $recA->{service_id};
	my $service_idB = $recB->{service_id};
	my $device_idA	= $recA->{device_id};
	my $device_idB = $recB->{device_id};
	my $portA = $recA->{port};
	my $portB = $recB->{port};

	if ($sort_by eq 'port')
	{
		$cmp = $portA <=> $portB;
		return $cmp if $cmp;
		$cmp = $device_idA cmp $device_idB;
		return $cmp if $cmp;
		$cmp = $service_idA <=> $service_idB;
		return $cmp if $cmp;
	}
	elsif ($sort_by eq 'device')
	{
		$cmp = $device_idA cmp $device_idB;
		return $cmp if $cmp;
		$cmp = $portA <=> $portB;
		return $cmp if $cmp;
		$cmp = $service_idA <=> $service_idB;
		return $cmp if $cmp;
	}
	else	# sort_by == 'service'
	{
		$cmp = $service_idA <=> $service_idB;
		return $cmp if $cmp;
		$cmp = $device_idA cmp $device_idB;
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

	my $service_ports = $this->{service_ports};
	my @slot_keys = keys %$service_ports;
	@slot_keys = sort { $this->cmpRecords($a,$b) } @slot_keys;

	# repopulate slots

	for (my $i=0; $i<$num_slots; $i++)
	{
		my $slot = $$slots[$i];
		my $slot_key = $slot_keys[$i];
		my $service_port = $service_ports->{$slot_key};
		my $name = $service_port->{name};
		my $proto = $service_port->{proto};

		$slot->{key} = $slot_key;

		$slot->{ctrl_device_id}		->SetLabel($service_port->{device_id});
		$slot->{ctrl_service_id}	->SetLabel($service_port->{service_id});
		$slot->{ctrl_name}			->SetLabel($name);
		$slot->{ctrl_proto}			->SetLabel($proto);
		$slot->{ctrl_ip}			->SetLabel($service_port->{ip});
		$slot->{ctrl_port}			->SetLabel($service_port->{port});

		my $spawn_box = $slot->{spawn_box};
		my $spawn_enable = !$service_port->{implemented} ? 1 : 0; # && ($proto eq 'udp' || $proto eq 'tcp') ? 1 : 0;
		$spawn_box->Enable($spawn_enable);
		$spawn_box->SetValue($service_port->{created});

		# $slot->{from_box}->SetValue($service_port->{mon_from});
		# $slot->{out_box}->SetValue($service_port->{mon_to});
		# $slot->{multi}->SetValue($service_port->{multi});
		# $slot->{listen}->SetValue($service_port->{listen});
		#
		# my $disable_listen = $service_port->{proto} =~ /mcast|udp/ || $service_port->{listen};
		# $slot->{listen}->Enable(!$disable_listen);

		# my $color = $console_color_names[$service_port->{color}];
		# $slot->{ctrl_color}->SetValue($color);
	}
}




#----------------------------------------------------
# onIdle
#----------------------------------------------------

sub X
{
	my ($this,$col) = @_;
	return $LEFT_MARGIN + $this->{CHAR_WIDTH} * $col;
}



sub onIdle
{
	my ($this,$event) = @_;
	$event->RequestMore(1);
	lock($raysys);

	#------------------------------------------------------
	# (a) FIND NEW, OR TO BE DELETED SERVICE PORTS
	#------------------------------------------------------

	my $service_ports = $this->{service_ports};
	my $raysys_service_ports = $raysys->getServicePortsByAddr();

	for my $addr (keys %$service_ports)
	{
		$service_ports->{$addr}->{found} = 0;
	}

	my $num_found = 0;
	my @new_service_ports = ();
	for my $addr (keys %$raysys_service_ports)
	{
		my $found = $service_ports->{$addr};
		if ($found)
		{
			if ($found->{found})
			{
				error("HUH? how can the same $addr=$found->{name} exist more than once in c_RAYSYS?");
				next;
			}

			$num_found++;
			$found->{found} = 1;
		}
		else
		{
			my $service_port = $raysys_service_ports->{$addr};
			push @new_service_ports,$service_port;
		}
	}

	my @delete_service_ports = ();
	for my $addr (keys %$service_ports)
	{
		my $service_port = $service_ports->{$addr};
		push @delete_service_ports,$addr
			if !$service_port->{found};
	}

	# (b) NO CHANGES - RETURN

	return  if !@new_service_ports && !@delete_service_ports;

	#------------------------------------------------------
	# (c) ADD new and DELETE missing service ports
	#------------------------------------------------------

	my $slots = $this->{slots};
	my $num_slots = @$slots;

	display($dbg_win,0,"num_slots=$num_slots",0,$UTILS_COLOR_CYAN);
	display($dbg_win,1,"found $num_found out of ".scalar(keys %$service_ports)." existing service_ports",0,$UTILS_COLOR_LIGHT_CYAN);
	display($dbg_win,1,"found ".scalar(@new_service_ports)." new and ".scalar(@delete_service_ports)." ports to delete",0,$UTILS_COLOR_LIGHT_CYAN);

	for my $addr (sort @delete_service_ports)
	{
		display($dbg_win,2,"deleting $addr=$service_ports->{$addr}->{name}",0,$UTILS_COLOR_LIGHT_CYAN);
		delete $service_ports->{$addr};
	}
	for my $service_port (sort @new_service_ports)
	{
		display($dbg_win,2,"adding $service_port->{addr}=$service_port->{name}",0,$UTILS_COLOR_LIGHT_CYAN);
		my $new_service_port = {};
		mergeHash($new_service_port,$service_port);	# take out of shared memory
		$service_ports->{$service_port->{addr}} = $new_service_port;
	}

	#------------------------------------------------------
	# (d) add or remove slots
	#------------------------------------------------------
	
	my $num_slots_added = @new_service_ports - @delete_service_ports;
	my $new_num_slots = $num_slots + $num_slots_added;

	if ($new_num_slots < $num_slots)
	{
		display($dbg_win,1,"num($num_slots) new_num($new_num_slots) removing ".(-$num_slots_added)." slots",0,$UTILS_COLOR_LIGHT_CYAN);
		for (my $i=$num_slots-1; $i>=0 && $i>$new_num_slots-1; $i--)
		{
			$this->deleteSlot($i);
		}
		splice @$slots,$new_num_slots;
		$this->Update();
	}
	elsif ($new_num_slots > $num_slots)
	{
		display($dbg_win,1,"num($num_slots) new_num($new_num_slots)  adding $num_slots_added slots",0,$UTILS_COLOR_LIGHT_CYAN);
		for (my $i=$num_slots; $i<$new_num_slots; $i++)
		{
			push @$slots,$this->createSlot($i);
		}
	}

	#-----------------------------
	# sort and return
	#-----------------------------

	$this->SetVirtualSize([$COL_TOTAL * $this->{CHAR_WIDTH} + 10,$TOP_MARGIN + scalar(@$slots)*$LINE_HEIGHT ]);
	$this->sortRecords();
}



sub createSlot
	# create a new empty slot
{
	my ($this,$slot_num) = @_;
	display($dbg_win+2,3,"createSlot($slot_num)");
	my $ypos = $TOP_MARGIN + $slot_num * $LINE_HEIGHT;

	#	my $from_id 	= $i + $MON_FROM_ID_BASE;
	#	my $to_id 		= $i + $MON_TO_ID_BASE;
	#	my $multi_id 	= $i + $MULTI_ID_BASE;
	#	my $listen_id 	= $i + $LISTEN_ID_BASE;
	#	my $from_box = Wx::CheckBox->new($this,$from_id,	"from",	 [$this->X($COL_FROM_BOX),	$ypos]);
	#	my $to_box 	 = Wx::CheckBox->new($this,$to_id,		"to",	 [$this->X($COL_TO_BOX),	$ypos]);
	#	my $multi 	 = Wx::CheckBox->new($this,$multi_id,	"multi", [$this->X($COL_MULTI),		$ypos]);
	#	my $listen 	 = Wx::CheckBox->new($this,$listen_id,	"listen",[$this->X($COL_LISTEN),	$ypos]);
	#
	#	$from_box->	SetValue(1)	if $service_port->{mon_from};
	#	$to_box->	SetValue(1) if $service_port->{mon_to};
	#	$multi->	SetValue(1)	if $service_port->{multi};
	#	$listen->	SetValue(1)	if $service_port->{listen};		# local to winRAYSYS layer
	#
	#	$listen->Enable(0) if $proto =~ /mcast|udp/;# || $service_port->{listen};
	#
	#	my $color = $console_color_names[$color_num];
	#	my $combo_id = $COLOR_ID_BASE + $i;
	#	my $combo = Wx::ComboBox->new($this, $combo_id, $color,
	#		[$this->X($COL_COLOR),$ypos-2],wxDefaultSize,\@console_color_names,wxCB_READONLY);

	my $spawn_id = $slot_num + $SPAWN_ID_BASE;
	my $spawn_box = Wx::CheckBox->new($this,$spawn_id,	"spawn",	[$this->X($COL_SPAWN),	$ypos]);
	$spawn_box->Enable(0);

	return {
		# key 			=> $addr,
		ctrl_device_id 	=> Wx::StaticText->new($this,-1,'', [$this->X($COL_DEVICE_ID),	$ypos]),
		ctrl_service_id	=> Wx::StaticText->new($this,-1,'', [$this->X($COL_SERVICE_ID),	$ypos]),
		ctrl_name 		=> Wx::StaticText->new($this,-1,'', [$this->X($COL_NAME),		$ypos]),
		ctrl_proto		=> Wx::StaticText->new($this,-1,'', [$this->X($COL_PROTO),		$ypos]),
		ctrl_ip 		=> Wx::StaticText->new($this,-1,'', [$this->X($COL_IP),			$ypos]),
		ctrl_port 		=> Wx::StaticText->new($this,-1,'', [$this->X($COL_PORT),		$ypos]),
		spawn_box		=> $spawn_box,
	};

}


sub deleteSlot
{
	my ($this,$slot_num) = @_;
	display($dbg_win+1,3,"deleteSlot($slot_num)");
	my $slots = $this->{slots};
	my $slot = $$slots[$slot_num];
	$slot->{ctrl_device_id}	 ->Destroy();
	$slot->{ctrl_service_id} ->Destroy();
	$slot->{ctrl_name} 		 ->Destroy();
	$slot->{ctrl_proto}		 ->Destroy();
	$slot->{ctrl_ip} 		 ->Destroy();
	$slot->{ctrl_port} 		 ->Destroy();
	$slot->{spawn_box}		 ->Destroy();

}


1;
