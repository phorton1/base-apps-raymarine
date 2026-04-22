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
use c_RAYDP;
use base qw(Wx::ScrolledWindow Pub::WX::Window);

my $dbg_win = 0;
my $dbg_slots = 1;

my $TOP_MARGIN = 60;
my $HEADER_Y = 37;
my $LEFT_MARGIN = 10;
my $LINE_HEIGHT = 20;


my $COL_NAME 		= 2;
my $COL_CONNECT 	= 6;
my $COL_LOCAL_PORT 	= 7;

my @COL_WIDTHS = (
	9,		# $COL_DEVICE_ID
	4,		# $COL_SERVICE_ID
	10,		# $COL_NAME
	6,      # $COL_PROTO
	15,     # $COL_IP
	6,      # $COL_PORT
	10,     # $COL_CONNECT
	8,		# $COL_LOCAL_PORT
);


my $COL_TOTAL = 0;
$COL_TOTAL += $_ for @COL_WIDTHS;

my @COL_NAMES = qw(
	DEV_ID
	SID
	NAME
	PROTO
	IP
	PORT
	CONNECT
	LOCAL );

my @field_names = qw(
	device_id
	service_id
	name
	proto
	ip
	port
	connect
	local_port );




my $SORT_BYS = ['port','service','device','num'];


my $ID_SORT_BY			= 902;
my $ID_HEADER_BASE 		= 1000;
my $CONNECT_ID_BASE		= 1100;
	# Apps should only use control IDs >= 200 !!!
	# ... as Pub::WX::Frame disables the standard "View" menu commands
	# $CLOSE_ALL_PANES = 101 and/or $CLOSE_OTHER_PANES = 102 based
	# on pane existence.



my $font_fixed = Wx::Font->new(9,wxFONTFAMILY_MODERN,wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD);


sub new
{
	my ($class,$frame,$book,$id,$data) = @_;
	my $this = $class->SUPER::new($book,$id);
	display($dbg_win,0,"winRAYDP::new() called");
	$this->MyWindow($frame,$book,$id,'RAYDP',$data);

	$this->SetFont($font_fixed);
	my $dc = Wx::ClientDC->new($this);
	$dc->SetFont($font_fixed);
	my $CHAR_WIDTH = $this->{CHAR_WIDTH} = $dc->GetCharWidth();
	display($dbg_win,1,"CHAR_WIDTH=$CHAR_WIDTH");

	my $char_offset = 0;
	for (my $i=0; $i<@COL_WIDTHS; $i++)
	{
		my $xpos = $LEFT_MARGIN + $char_offset * $CHAR_WIDTH;
		my $ctrl = Wx::StaticText->new($this,$ID_HEADER_BASE+$i,$COL_NAMES[$i], [$xpos,$HEADER_Y]);
		$ctrl->SetForegroundColour($wx_color_blue);
		$char_offset += $COL_WIDTHS[$i];
	}


	Wx::StaticText->new($this,-1,'Sort by',[10,10]);
	Wx::ComboBox->new($this, $ID_SORT_BY, $$SORT_BYS[0],
		[84,7],wxDefaultSize,$SORT_BYS,wxCB_READONLY);

	$this->{sort_by} = $$SORT_BYS[0];
	$this->{slots} = [];
		# a record with the current addr and controls for a given row
	$this->{addrs} = {};
		# hash by addr of { addr=>addr; found=>1; }
	
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
	return if !$raydp;

	my $slot_num = $id - $CONNECT_ID_BASE;
	my $slot = $this->{slots}->[$slot_num];
	my $addr = $slot->{addr};
	my $service_port = $raydp->{ports_by_addr}->{$addr};
	my $name = $service_port->{name};

	display($dbg_win,0,"$addr = $name connect($checked) $service_port->{proto}");
	$raydp->connectServicePort($addr,$checked);

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
}



#----------------------------------------------------
# sort
#----------------------------------------------------

sub cmpRecords
{
	my ($this,$ports_by_addr,$keyA, $keyB) = @_;
	my $sort_by = $this->{sort_by};

	my $recA = $ports_by_addr->{$keyA};
	my $recB = $ports_by_addr->{$keyB};
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
	return if !$raydp;
	lock($raydp);
	my $ports_by_addr = $raydp->{ports_by_addr};
	my $implemented_services = $raydp->{implemented_services};

	my $sort_by 	= $this->{sort_by};
	my $slots   	= $this->{slots};
	my $num_slots   = @$slots;

	my $addrs = $this->{addrs};
	my @addrs = keys %$addrs;
	@addrs = sort { $this->cmpRecords($ports_by_addr,$a,$b) } @addrs;

	# repopulate slots

	for (my $i=0; $i<$num_slots; $i++)
	{
		my $slot = $$slots[$i];
		my $controls = $slot->{controls};
		my $addr = $addrs[$i];
		my $service_port = $ports_by_addr->{$addr};
		if (!$service_port)
		{
			$slot->{addr} = '';
			error("Could not find service_port($addr}");
			next;
		}

		$slot->{addr} = $addr;
		
		for (my $j=0; $j<@$controls; $j++)
		{
			my $ctrl = $$controls[$j];
			if ($j == $COL_CONNECT)
			{
				if ($service_port->{implemented})
				{
					$ctrl->SetLabel('connect');
					my $name = $service_port->{name};
					my $implemented_service = $implemented_services->{$name};
					if ($implemented_service)
					{
						$ctrl->Enable(1);
						$ctrl->SetValue($implemented_service->{connected});
					}
					else
					{
						warning($dbg_win,0,"could not find implemented_service($name)");
						$ctrl->Enable(0);
						$ctrl->SetValue(0);
					}
				}
				else
				{
					$ctrl->SetLabel('spawn');
					$ctrl->SetValue($service_port->{created});
				}
			}
			else
			{
				my $field_name = $field_names[$j];
				my $value = $service_port->{$field_name} || '';
				$ctrl->SetLabel($value);
				$ctrl->SetForegroundColour($service_port->{implemented} ?
					$wx_color_blue : wxBLACK) if $j == $COL_NAME;
			}
		}
	}
}



sub setConnectBoxes
{
	my ($this) = @_;
	return if !$raydp;
	lock($raydp);
	my $ports_by_addr = $raydp->{ports_by_addr};
	my $implemented_services = $raydp->{implemented_services};

	for my $slot (@{$this->{slots}})
	{
		my $addr = $slot->{addr};
		my $service_port = $ports_by_addr->{$addr};
		if (!$service_port)
		{
			$slot->{addr} = '';
			error("Could not find service_port($addr}");
			next;
		}


		my $checked = $service_port->{created} || 0;
		my $port = $service_port->{port};
		my $local_port = $service_port->{local_port} || 0;
		
		if ($service_port->{implemented})
		{
			my $name = $service_port->{name};
			my $implemented_service = $implemented_services->{$name};
			if ($implemented_service)
			{
				$checked = $implemented_service->{connected} || 0;
				$local_port = $implemented_service->{local_port} || 0;
			}
			else
			{
				warning($dbg_win,0,"could not find implemented_service($name)");
				$checked = 0;
				$local_port = 0;
			}
		}

		$local_port = 0 if $local_port == $port;
			# don't reshow all the same local ports

		my $controls = $slot->{controls};
		my $connect_ctrl = $$controls[$COL_CONNECT];
		my $local_port_ctrl = $$controls[$COL_LOCAL_PORT];

		my $cur_checked = $connect_ctrl->GetValue() ? 1 : 0;
		my $cur_local_port = $local_port_ctrl->GetLabel() || 0;

		$connect_ctrl->SetValue($checked)
			if $cur_checked != $checked;
		$local_port_ctrl->SetLabel($local_port?$local_port:'')
			if $cur_local_port != $local_port;
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
	lock($raydp);

	#------------------------------------------------------
	# (a) FIND NEW, OR TO BE DELETED SERVICE PORTS
	#------------------------------------------------------

	my $addrs = $this->{addrs};
	my $service_ports = $raydp->getServicePortsByAddr();

	for my $addr (keys %$addrs)
	{
		$addrs->{$addr}->{found} = 0;
	}

	my $num_found = 0;
	my @new_addrs = ();
	for my $addr (keys %$service_ports)
	{
		my $found = $addrs->{$addr};
		if ($found)
		{
			$num_found++;
			$found->{found} = 1;
		}
		else
		{
			my $service_port = $service_ports->{$addr};
			push @new_addrs,$service_port->{addr};
		}
	}

	my @delete_addrs = ();
	for my $addr (keys %$addrs)
	{
		my $rec = $addrs->{$addr};
		push @delete_addrs,$addr
			if !$rec->{found};
	}

	# (b) NO CHANGES - RETURN

	if (!@new_addrs && !@delete_addrs)
	{
		$this->setConnectBoxes();
		return;
	}

	#------------------------------------------------------
	# (c) ADD new and DELETE missing service ports
	#------------------------------------------------------

	my $slots = $this->{slots};
	my $num_slots = @$slots;

	display($dbg_slots,0,"num_slots=$num_slots",0,$UTILS_COLOR_CYAN);
	display($dbg_slots,1,"found $num_found out of ".scalar(keys %$addrs)." existing addrs",0,$UTILS_COLOR_LIGHT_CYAN);
	display($dbg_slots,1,"found ".scalar(@new_addrs)." new and ".scalar(@delete_addrs)." ports to delete",0,$UTILS_COLOR_LIGHT_CYAN);

	for my $addr (sort @delete_addrs)
	{
		display($dbg_slots,2,"deleting service_port->($addr)",0,$UTILS_COLOR_LIGHT_CYAN);
		delete $addrs->{$addr};
	}
	for my $addr (sort @new_addrs)
	{
		display($dbg_slots,2,"adding service_port->{$addr}",0,$UTILS_COLOR_LIGHT_CYAN);
		$addrs->{$addr} = { addr=>$addr, found=>1, };
	}

	#------------------------------------------------------
	# (d) add or remove slots
	#------------------------------------------------------
	
	my $num_slots_added = @new_addrs - @delete_addrs;
	my $new_num_slots = $num_slots + $num_slots_added;

	if ($new_num_slots < $num_slots)
	{
		display($dbg_slots,1,"num($num_slots) new_num($new_num_slots) removing ".(-$num_slots_added)." slots",0,$UTILS_COLOR_LIGHT_CYAN);
		for (my $i=$num_slots-1; $i>=0 && $i>$new_num_slots-1; $i--)
		{
			$this->deleteSlot($i);
		}
		splice @$slots,$new_num_slots;
		$this->Update();
	}
	elsif ($new_num_slots > $num_slots)
	{
		display($dbg_slots,1,"num($num_slots) new_num($new_num_slots)  adding $num_slots_added slots",0,$UTILS_COLOR_LIGHT_CYAN);
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
	display($dbg_slots+2,3,"createSlot($slot_num)");
	my $ypos = $TOP_MARGIN + $slot_num * $LINE_HEIGHT;

	my $num = 0;
	my $char_offset = 0;
	my @controls;
	
	for my $char_width (@COL_WIDTHS)
	{
		my $name = $COL_NAMES[$num];
		my $xpos = $LEFT_MARGIN + $char_offset * $this->{CHAR_WIDTH};
		my $width = $char_width * $this->{CHAR_WIDTH};
		if ($num == $COL_CONNECT)
		{
			my $connect_id = $slot_num + $CONNECT_ID_BASE;
			push @controls, Wx::CheckBox->new($this,$connect_id,"connect",[$xpos,$ypos-4],[$width,$LINE_HEIGHT]);
		}
		else
		{
			push @controls, Wx::StaticText->new($this,-1,'', [$xpos,$ypos],[$width,$LINE_HEIGHT]),
		}
		$char_offset += $char_width;
		$num++;
	}

	return { controls => \@controls };
}


sub deleteSlot
{
	my ($this,$slot_num) = @_;
	display($dbg_slots+1,3,"deleteSlot($slot_num)");
	my $slots = $this->{slots};
	my $slot = $$slots[$slot_num];
	my $controls = $slot->{controls};
	for my $control (@$controls)
	{
		$control->Destroy();
	}
}


1;
