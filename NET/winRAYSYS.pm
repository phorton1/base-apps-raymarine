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


my $ID_SORT_BY			  = 902;

my $ID_SHOW_WPMGR_TCP_INPUT   	= 903;
my $ID_SHOW_WPMGR_TCP_OUTPUT  	= 904;
my $ID_SHOW_WPMGR_PARSED_INPUT  = 905;
my $ID_SHOW_WPMGR_PARSED_OUTPUT = 906;


my $SORT_BYS = ['port','service','device','num'];


my $SPAWN_ID_BASE		= 1000;
my $MON_FROM_ID_BASE 	= 1100;
my $MON_TO_ID_BASE 		= 1200;
my $MULTI_ID_BASE		= 1300;
my $LISTEN_ID_BASE  	= 1400;
my $COLOR_ID_BASE 		= 1500;

	# Apps should only use control IDs >= 200 !!!
	# As Pub::WX::Frame disables the standard "View" menu commands
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
		# the id:ip:port occupying this y position in the table
	$this->{service_ports} = {};
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

	# repopulate any slots that don't have the correct slot_key

	for (my $i=0; $i<$num_slots; $i++)
	{
		my $slot = $$slots[$i];
		my $slot_key = $slot_keys[$i];
		my $service_port = $service_ports->{$slot_key};
		my $name = $service_port->{name};
		my $proto = $service_port->{proto};

		if ($slot->{key} ne $slot_key)
		{
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
}



sub X
{
	my ($this,$col) = @_;
	return $LEFT_MARGIN + $this->{CHAR_WIDTH} * $col;
}


sub onIdle
{
	my ($this,$event) = @_;
	my $service_ports = getServicePorts();
	
	my $slots = $this->{slots};
	my $num_slots = @$slots;
	my $num_service_ports = @$service_ports;
	if ($num_slots != $num_service_ports)
	{
		# add the new records from RAY_DP (which are in first come order)
		# into the hash of service_ports by id:ip:port, and then call populate(),
		# creating controls for them as we go, that will be fixed up in
		# sortSlots.

		my $my_service_ports = $this->{service_ports};
		for (my $i=$num_slots; $i<$num_service_ports; $i++)
		{
			my $service_port = $service_ports->[$i];
			my $device_id 	 = $service_port->{device_id};
			my $service_id 	 = $service_port->{service_id};
			my $name 		 = $service_port->{name};
			my $proto 		 = $service_port->{proto};
			my $ip 			 = $service_port->{ip};
			my $port 		 = $service_port->{port};
			my $addr 		 = $service_port->{addr};
			
			# temporary stuff color to avoid undef warnings
			
			$service_port->{color} ||= 0;
			my $color_num	 = $service_port->{color};

			display($dbg_win,0,"adding service_port device_id($device_id} service_id($service_id) $name $proto $addr ");
				# "in($service_port->{mon_from}) out($service_port->{mon_to}) ".
				# "color($service_port->{color}) multi($service_port->{multi})");

			$my_service_ports->{$addr} = $service_port;

			my $ypos = $TOP_MARGIN + $i * $LINE_HEIGHT;

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

			my $spawn_id = $i + $SPAWN_ID_BASE;
			my $spawn_box = Wx::CheckBox->new($this,$spawn_id,	"spawn",	[$this->X($COL_SPAWN),	$ypos]);
			my $spawn_enable = !$service_port->{implemented} ? 1 : 0; # && ($proto eq 'udp' || $proto eq 'tcp') ? 1 : 0;
			display(0,2,"enable=$spawn_enable");
			$spawn_box->Enable($spawn_enable);
			$spawn_box->SetValue($service_port->{created});

			push @$slots,{
				key 			=> $addr,
				ctrl_device_id 	=> Wx::StaticText->new($this,-1,$device_id,	[$this->X($COL_DEVICE_ID),	$ypos]),
				ctrl_service_id	=> Wx::StaticText->new($this,-1,$service_id,[$this->X($COL_SERVICE_ID),	$ypos]),
				ctrl_name 		=> Wx::StaticText->new($this,-1,$name,		[$this->X($COL_NAME),		$ypos]),
				ctrl_proto		=> Wx::StaticText->new($this,-1,$proto,		[$this->X($COL_PROTO),		$ypos]),
				ctrl_ip 		=> Wx::StaticText->new($this,-1,$ip,		[$this->X($COL_IP),			$ypos]),
				ctrl_port 		=> Wx::StaticText->new($this,-1,$port,		[$this->X($COL_PORT),		$ypos]),
				spawn_box		=> $spawn_box,
				
				#	from_box		=> $from_box,
				#	out_box     	=> $to_box,
				#	multi			=> $multi,
				#	listen			=> $listen,
				#	ctrl_color  	=> $combo,
			};
		}

		$this->SetVirtualSize([$COL_TOTAL * $this->{CHAR_WIDTH} + 10,$TOP_MARGIN + scalar(@$slots)*$LINE_HEIGHT ]);
		# $this->sortRecords();
	}
	
	$event->RequestMore(1);
}



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
	spawnServicePortByName($name,$checked) if $field eq 'spawn';


	#	if ($field eq 'listen')
	#	{
	#		my $base = findTcpBase($service_port->{name});
	#		if ($checked)
	#		{
	#			display(0,1,"starting tcpBase for func($service_port->{func} $service_port->{addr} $service_port->{proto} $service_port->{name}");
	#			return error("already started!") if $base;
	#			# my $box = $event->GetEventObject();
	#			# $box->Enable(0);
	#			my $base = tcpBase->new({
	#				name => $service_port->{name},
	#				EXIT_ON_CLOSE => 1,
	#				show_input => 1,
	#				show_output => 1,
	#				in_color => $service_port->{color},
	#				out_color => $service_port->{color} });
	#			$base->start();
	#
	#			# tcpListener->startTcpListener($service_port->{ip},$service_port->{port});
	#		}
	#		else
	#		{
	#			display(0,1,"stopping tcpBase for func($service_port->{func}) $service_port->{addr} $service_port->{proto} $service_port->{name}");
	#
	#			return error("could not find tcpBase!") if !$base;
	#			$base->stop();
	#		}
	#	}

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

	

1;
