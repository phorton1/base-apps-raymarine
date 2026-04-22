#!/usr/bin/perl
#-------------------------------------------------------------------------
# winShark.pm
#-------------------------------------------------------------------------

package winShark;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Wx qw(:everything);
use Wx::Event qw(
	EVT_IDLE
	EVT_BUTTON
	EVT_CHECKBOX
	EVT_COMBOBOX );
use Pub::Utils;
use Pub::WX::Window;
use a_defs;
use a_mon;
use a_utils;
use s_sniffer;
use base qw(Wx::ScrolledWindow Pub::WX::Window);

my $dbg_win = 0;

my $TOP_MARGIN  = 70;
my $START_TOP   = 5;
my $LEFT_MARGIN = 10;
my $LINE_HEIGHT = 20;
my $CHECK_COL	= 240;
my $CHECK_WIDTH = 80;


my $ID_ONOFF 		 = 1000;

my $ID_ACTIVE_OFF    = 1010;
my $ID_ACTIVE_ON	 = 1011;
my $ID_LOG_OFF    	 = 1012;
my $ID_LOG_ON	 	 = 1013;
my $ID_ONLY_OFF    	 = 1014;
my $ID_ONLY_ON	 	 = 1015;

my $ID_ACTIVE_BASE 	 = 2000;
my $ID_LOG_BASE 	 = 3000;
my $ID_ONLY_BASE 	 = 4000;




my $font_fixed = Wx::Font->new(10,wxFONTFAMILY_MODERN,wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD);


sub cmpFunc
{
	my ($a,$b) = @_;
	return
		lc($SHARK_DEFAULTS{$a}->{name}) cmp
		lc($SHARK_DEFAULTS{$b}->{name});
}


sub new
{
	my ($class,$frame,$book,$id,$data) = @_;
	my $this = $class->SUPER::new($book,$id);
	display($dbg_win,0,"winSniffer::new() called");
	$this->MyWindow($frame,$book,$id,'Shark',$data);

	Wx::Button->new($this,$ID_ACTIVE_OFF,'all_off',[$LEFT_MARGIN,				$START_TOP + 1*$LINE_HEIGHT],[60,$LINE_HEIGHT]);
	Wx::Button->new($this,$ID_ACTIVE_ON, 'all_on', [$LEFT_MARGIN,				$START_TOP + 2*$LINE_HEIGHT],[60,$LINE_HEIGHT]);
	Wx::Button->new($this,$ID_LOG_OFF,	 'all_off',[$CHECK_COL + 0*$CHECK_WIDTH,$START_TOP + 1*$LINE_HEIGHT],[60,$LINE_HEIGHT]);
	Wx::Button->new($this,$ID_LOG_ON, 	 'all_on', [$CHECK_COL + 0*$CHECK_WIDTH,$START_TOP + 2*$LINE_HEIGHT],[60,$LINE_HEIGHT]);
	Wx::Button->new($this,$ID_ONLY_OFF,	 'all_off',[$CHECK_COL + 1*$CHECK_WIDTH,$START_TOP + 1*$LINE_HEIGHT],[60,$LINE_HEIGHT]);
	Wx::Button->new($this,$ID_ONLY_ON, 	 'all_on', [$CHECK_COL + 1*$CHECK_WIDTH,$START_TOP + 2*$LINE_HEIGHT],[60,$LINE_HEIGHT]);

	$this->SetFont($font_fixed);

	my @ctrls;
	my $num = 0;
	for my $port (sort {cmpFunc($a,$b)} keys %SHARK_DEFAULTS)
	{
		my $def = $SHARK_DEFAULTS{$port};
		my $title =
			pad($port,6).
			pad($def->{name},12).
			pad($def->{proto},5);
		my $active_id = $ID_ACTIVE_BASE + $num;
		my $box = Wx::CheckBox->new($this,$active_id,$title,[$LEFT_MARGIN,$TOP_MARGIN + $num*$LINE_HEIGHT]);
		$box->SetValue($def->{active}?1:0);
		$box->{port} = $port;

		my $log_id = $ID_LOG_BASE + $num;
		$box = Wx::CheckBox->new($this,$log_id,'log',[$CHECK_COL + 0*$CHECK_WIDTH,$TOP_MARGIN + $num*$LINE_HEIGHT]);
		$box->SetValue(($def->{log} & $MON_WRITE_LOG)?1:0);
		$box->{port} = $port;

		my $only_id = $ID_ONLY_BASE + $num;
		$box = Wx::CheckBox->new($this,$only_id,'only',[$CHECK_COL + 1*$CHECK_WIDTH,$TOP_MARGIN + $num*$LINE_HEIGHT]);
		$box->SetValue(($def->{log} & $MON_LOG_ONLY)?1:0);
		$box->{port} = $port;

		$num++;
	}

	# $this->SetVirtualSize([$COL_TOTAL * $CHAR_WIDTH + 10,$TOP_MARGIN]);
	# $this->SetScrollRate(0,$LINE_HEIGHT);
	EVT_BUTTON($this,-1,\&onButton);
	EVT_CHECKBOX($this,-1,\&onCheckBox);
	# EVT_IDLE($this,\&onIdle);
	# EVT_COMBOBOX($this,-1,\&onComboBox);
	return $this;
}


#------------------------------------
# event handlers
#------------------------------------


sub onButton
{
	my ($this,$event) = @_;
	my $id = $event->GetId();
	display($dbg_win,0,"onButton($id)");

	my $on = 0;
	my $bit = 0;
	my $active = 0;
	my $id_base = 0;
	if ($id == $ID_ACTIVE_OFF || $id == $ID_ACTIVE_ON)
	{
		$id_base = $ID_ACTIVE_BASE;
		$on = $id == $ID_ACTIVE_OFF ? 0 : 1;
	}
	elsif ($id == $ID_LOG_OFF || $id == $ID_LOG_ON)
	{
		$id_base = $ID_LOG_BASE;
		$bit = $MON_WRITE_LOG;
		$on = $id == $ID_LOG_OFF ? 0 : 1;
	}
	elsif ($id == $ID_ONLY_OFF || $id == $ID_ONLY_ON)
	{
		$id_base = $ID_ONLY_BASE;
		$bit = $MON_LOG_ONLY;
		$on = $id == $ID_ONLY_OFF ? 0 : 1;
	}


	my $num = 0;
	for my $port (sort {cmpFunc($a,$b)} keys %SHARK_DEFAULTS)
	{
		my $def = $SHARK_DEFAULTS{$port};
		if ($bit)
		{
			$on ? ($def->{log} |= $bit) : ($def->{log} &= ~$bit);
		}
		else
		{
			$def->{active} = $on;
		}
		my $box = $this->FindWindow($id_base + $num);
		$box->SetValue($on);
		$num++;
	}
}


sub onCheckBox
{
	my ($this,$event) = @_;
	my $id = $event->GetId();
	my $box = $event->GetEventObject();
	my $checked = $event->IsChecked() || 0;

	display($dbg_win,0,"id($id) checked($checked)");

	my $port = $box->{port};
	my $def = $SHARK_DEFAULTS{$port};
	display($dbg_win,1,sprintf("onCheckbox port($port) before active($def->{active}) log(%04x)",$def->{log}));

	if ($id >= $ID_ONLY_BASE)
	{
		$checked ?
			($def->{log} |= $MON_LOG_ONLY) :
			($def->{log} &= ~$MON_LOG_ONLY);
	}
	elsif ($id >= $ID_LOG_BASE)
	{
		$checked ?
			($def->{log} |= $MON_WRITE_LOG) :
			($def->{log} &= ~$MON_WRITE_LOG);
	}
	elsif ($id >= $ID_ACTIVE_BASE)
	{
		$def->{active} = $checked;
	}

	display($dbg_win,2,sprintf("onCheckbox port($port) after active($def->{active}) log(%04x)",$def->{log}));

}



1;
