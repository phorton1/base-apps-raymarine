#!/usr/bin/perl
#-------------------------------------------------------------------------
# winSniffer.pm
#-------------------------------------------------------------------------

package winSniffer;
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
use s_sniffer;
use base qw(Wx::ScrolledWindow Pub::WX::Window);

my $dbg_win = 0;

my $TOP_MARGIN = 60;
my $HEADER_Y = 37;
my $LEFT_MARGIN = 10;
my $LINE_HEIGHT = 20;

my $ID_ONOFF = 1000;



sub new
{
	my ($class,$frame,$book,$id,$data) = @_;
	my $this = $class->SUPER::new($book,$id);
	display($dbg_win,0,"winSniffer::new() called");
	$this->MyWindow($frame,$book,$id,'sniffer',$data);

	my $running = $sniffer && $sniffer->{running} ? 1 : 0;
	my $box = Wx::CheckBox->new($this,$ID_ONOFF,"on/off",[$LEFT_MARGIN,$HEADER_Y-4]);
	$box->SetValue($running);

	# $this->SetVirtualSize([$COL_TOTAL * $CHAR_WIDTH + 10,$TOP_MARGIN]);
	# $this->SetScrollRate(0,$LINE_HEIGHT);

	# EVT_IDLE($this,\&onIdle);
	EVT_CHECKBOX($this,-1,\&onCheckBox);
	# EVT_COMBOBOX($this,-1,\&onComboBox);
	return $this;
}


#------------------------------------
# event handlers
#------------------------------------

sub onCheckBox
{
	my ($this,$event) = @_;
	my $id = $event->GetId();
	my $box = $event->GetEventObject();
	my $checked = $event->IsChecked() || 0;

	if (!$sniffer)
	{
		$box->SetValue(0);
		return;
	}

	$sniffer->{running} = $checked;
}



1;
