#-------------------------------------------------------------------------
# winShark.pm
#-------------------------------------------------------------------------
# A general purpose window that allows me to control
# certain aspects of the system, like monitoring my
# own TCP/UDP traffic, setting debug levels, etc.


package winShark;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_CHECKBOX
	EVT_BUTTON );
use Pub::Utils;
use Pub::WX::Window;
use apps::teensyBoat::tbUtils;
use apps::teensyBoat::tbBinary;
use apps::teensyBoat::tbConsole;
use base qw(Wx::Window MyWX::Window);


my $TOP_MARGIN = 50;
my $LINE_HEIGHT = 25;

my $LEFT_COL = 20;
my $COL_WIDTH = 80;

my $NUM_PORT_BUTTONS = 2;
my $INST_NUM_ALL_ON = $NUM_INSTRUMENTS;
my $INST_NUM_ALL_OFF = $NUM_INSTRUMENTS+1;
my $NUM_PORT_CTRLS = $NUM_INSTRUMENTS + 2;
# my $NUM_CTRLS = $NUM_PORT_CONTROLS * $NUM_BOAT_PORTS;

my @BUTTON_NAMES = ( 'all_on', 'all_off' );



my $ID_LOAD_DEFAULTS = 900;
my $ID_SAVE_DEFAULTS = 901;

my $ID_CTRL_BASE = 1000;	# uses $NUM_CTRLS identifiers


my $font_fixed = Wx::Font->new(12,wxFONTFAMILY_MODERN,wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD);


sub idOf
{
	my ($port_num, $inst_num) = @_;
	return $port_num * $NUM_PORT_CTRLS + $inst_num;
}

sub portOf
{
	my ($id) = @_;
	return int($id / $NUM_PORT_CTRLS);
}

sub instrumentOf
{
	my ($id) = @_;
	return $id % $NUM_PORT_CTRLS;
}





sub new
{
	my ($class,$frame,$book,$id,$data) = @_;
	my $this = $class->SUPER::new($book,$id);
	display(0,0,"winBoat::new() called");
	$this->MyWindow($frame,$book,$id,"Prog");

	# default buttons

	Wx::Button->new($this,$ID_LOAD_DEFAULTS,"LOAD",[20,20], [60,20]);
	Wx::Button->new($this,$ID_SAVE_DEFAULTS,"SAVE",[100,20],[60,20]);

	# column headers

	for (my $i=0; $i<$NUM_BOAT_PORTS; $i++)
	{
		my $name = portName($i);
		my $x = $LEFT_COL + (1 + $i) * $COL_WIDTH;
		Wx::StaticText->new($this,-1,$name,[$x,$TOP_MARGIN],[$COL_WIDTH,$LINE_HEIGHT],
			wxALIGN_CENTRE_HORIZONTAL);
	}

	# instrument names

	for (my $i=0; $i<$NUM_INSTRUMENTS; $i++)
	{
		my $name = instrumentName($i);
		my $y = $TOP_MARGIN + (1 + $i) * $LINE_HEIGHT;
		Wx::StaticText->new($this,-1,$name,[$LEFT_COL,$y]);
	}

	# checkboxes

	for (my $i=0; $i<$NUM_BOAT_PORTS; $i++)
	{
		for (my $j=0; $j<$NUM_INSTRUMENTS; $j++)
		{
			my $id = idOf($i,$j);
			my $x = $LEFT_COL + (1 + $i) * $COL_WIDTH + ($COL_WIDTH/2 - 10);
			my $y = $TOP_MARGIN + (1 + $j) * $LINE_HEIGHT;
			my $box = Wx::CheckBox->new($this,$id,"",[$x,$y]);
		}
	}

	# buttons

	for (my $i=0; $i<$NUM_BOAT_PORTS; $i++)
	{
		for (my $j=0; $j<$NUM_PORT_BUTTONS; $j++)
		{
			my $inst_num = $j + $NUM_INSTRUMENTS;
			my $name = $BUTTON_NAMES[$j];


			my $id = idOf($i,$inst_num);
			my $x = $LEFT_COL + (1 + $i) * $COL_WIDTH + 10;
			my $y = $TOP_MARGIN + (1 + $inst_num) * $LINE_HEIGHT;
			my $button = Wx::Button->new($this,$id,$name,[$x,$y],[60,20]);
		}
	}

	EVT_BUTTON($this,-1,\&onButton);
	EVT_CHECKBOX($this,-1,\&onCheckBox);

	sendTeensyCommand("STATE");

	return $this;
}



sub onButton
{
	my ($this,$event) = @_;
	my $id = $event->GetId();
	my $command;

	if ($id == 	$ID_LOAD_DEFAULTS)
	{
		display(0,0,"onButton(LOAD)");
		$command = "LOAD";
	}
	elsif ($id == 	$ID_SAVE_DEFAULTS)
	{
		display(0,0,"onButton(SAVE)");
		$command = "SAVE";
	}
	else
	{
		my $port_num = portOf($id);
		my $port_name = portName($id);
		my $inst_num = instrumentOf($id);
		my $button_num = $inst_num - $NUM_INSTRUMENTS;
		my $value = $button_num ? 0 : 1;

		display(0,0,"onButton $port_name($port_num) @BUTTON_NAMES($button_num)");

		# turn all the checkboxes on or off

		for (my $i=0; $i<$NUM_INSTRUMENTS; $i++)
		{
			my $box_id = idOf($port_num,$i);
			my $box = $this->FindWindow($box_id);
			$box->SetValue($value);
		}

		# send the command

		my @command_ports = qw(ST 0183 2000);
		$value += $NO_ECHO_TO_PERL;	# don't echo
		$command = "I_$command_ports[$port_num]=$value";
	}

	sendTeensyCommand($command);
}



sub onCheckBox
{
	my ($this,$event) = @_;
	my $id = $event->GetId();
	my $checked = $event->IsChecked() || 0;

	my $port_num = portOf($id);
	my $port_name = portName($id);
	my $inst_num = instrumentOf($id);
	my $inst_name = instrumentName($inst_num);
	display(0,0,"onCheckBox $port_name($port_num) $inst_name($inst_num) checked=$checked");

	# the "i_{inst_name}=XX" command currntly expects a portwise binary XX
	# we build the binary number here.

	my $port_mask = 0;
	for (my $i=0; $i<$NUM_BOAT_PORTS; $i++)
	{
		my $box_id = idOf($i,$inst_num);
		my $box = $this->FindWindow($box_id);
		$port_mask |= (1 << $i) if $box->GetValue();
	}

	$port_mask += $NO_ECHO_TO_PERL;	# don't echo
	my $command = "I_$inst_name=$port_mask";
	sendTeensyCommand($command);
}





sub handleBinaryData
{
	my ($this,$counter,$type,$packet) = @_;
	# display(0,0,"handleBinaryData($counter) len=".length($binary_data));
	display_bytes(0,0,"packet",$packet);

	my $offset = 0;
	for (my $i=0; $i<$NUM_INSTRUMENTS; $i++)
	{
		my $mask = binaryByte($packet,\$offset);
		for (my $j=0; $j<$NUM_BOAT_PORTS; $j++)
		{
			my $box_id = idOf($j,$i);
			my $box = $this->FindWindow($box_id);
			my $value = $mask & (1 << $j) ? 1 : 0;
			$box->SetValue($value);
		}
	}
}



1;
