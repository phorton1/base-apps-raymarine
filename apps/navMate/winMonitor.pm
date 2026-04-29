#!/usr/bin/perl
#-------------------------------------------------------------------------
# winMonitor.pm
#-------------------------------------------------------------------------

package winMonitor;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_CHECKBOX
	EVT_COMBOBOX
	EVT_IDLE
	EVT_TEXT_ENTER);
use Pub::Utils qw(display warning error);
use Pub::WX::Window;
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::a_mon;
use apps::raymarine::NET::c_RAYDP;
use w_resources;
use base qw(Wx::Panel Pub::WX::Window);


my @SVC_PRESETS = (
	['off',     0       ],
	['all',     0xffff  ],
	['cmds',    0x0031  ],
	['wire',    0x0037  ],
	['records', 0x3000  ],
	['fields',  0x3700  ],
	['verbose', 0x3f00  ],
	['dump',    0x13000 ],
);

my @API_PRESETS = (
	['off',     0       ],
	['all',     0xffff  ],
	['records', 0x3000  ],
	['fields',  0x3700  ],
	['verbose', 0x3f00  ],
	['dump',    0x13000 ],
);

my @SVC_NAMES = ((map { $_->[0] } @SVC_PRESETS), 'custom');
my @API_NAMES = ((map { $_->[0] } @API_PRESETS), 'custom');

my $DISPLAY_MASK = ~($MON_SRC_SHARK | $MON_SELF_SNIFFED);


sub new
{
	my ($class, $frame, $book, $id, $data) = @_;
	my $this = $class->SUPER::new($book, $id);
	$this->MyWindow($frame, $book, $id, 'Monitor', $data);
	$this->SetBackgroundColour(wxWHITE);

	my $outer = Wx::BoxSizer->new(wxVERTICAL);
	my $CV    = wxALIGN_CENTER_VERTICAL;

	my $base = $this->GetFont();
	my $bold = Wx::Font->new($base->GetPointSize(), $base->GetFamily(),
		$base->GetStyle(), wxFONTWEIGHT_BOLD);

	# ---- API Builds ----

	$this->{api_hex}   = Wx::TextCtrl->new($this, -1, '0x0',
		wxDefaultPosition, [70,-1], wxTE_PROCESS_ENTER);
	$this->{api_combo} = Wx::ComboBox->new($this, -1, 'off',
		wxDefaultPosition, [110,-1], \@API_NAMES, wxCB_READONLY);

	my $api_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$api_row->Add(Wx::StaticText->new($this, -1, 'API Builds'), 0, $CV, 0);
	$api_row->AddSpacer(10);
	$api_row->Add($this->{api_hex},   0, $CV, 0);
	$api_row->AddSpacer(5);
	$api_row->Add($this->{api_combo}, 0, $CV, 0);

	$outer->AddSpacer(10);
	$outer->Add($api_row, 0, wxLEFT, 10);
	$outer->AddSpacer(18);

	# ---- main grid ----

	my $grid = Wx::FlexGridSizer->new(0, 6, 5, 8);

	# header row
	for my $h ('', 'Active', 'In hex', 'In preset', 'Out hex', 'Out preset')
	{
		my $st = Wx::StaticText->new($this, -1, $h);
		$st->SetFont($bold);
		$grid->Add($st, 0, $CV);
	}

	# WPMGR header row — active only
	my $wlbl = Wx::StaticText->new($this, -1, 'WPMGR');
	$wlbl->SetMinSize([85,-1]);
	$this->{wpmgr_active} = Wx::CheckBox->new($this, -1, '');
	$grid->Add($wlbl,                 0, $CV);
	$grid->Add($this->{wpmgr_active}, 0, $CV);
	$grid->Add(Wx::StaticText->new($this, -1, ''), 0, $CV) for 1..4;

	# Waypoints / Routes / Groups
	_addMonRow($this, $grid, 'Waypoints', 'wp');
	_addMonRow($this, $grid, 'Routes',    'route');
	_addMonRow($this, $grid, 'Groups',    'group');

	# blank spacer before Track
	$grid->Add(Wx::StaticText->new($this, -1, ''), 0, 0) for 1..6;

	# Track — has its own active
	_addMonRow($this, $grid, 'Track', 'track', 1);

	$outer->Add($grid, 0, wxLEFT|wxBOTTOM, 10);
	$this->SetSizer($outer);

	# ---- event bindings ----

	EVT_CHECKBOX($this, $this->{wpmgr_active}, sub { _applyAll($this) });
	EVT_CHECKBOX($this, $this->{track_active},  sub { _applyAll($this) });

	_bindPair($this, $this->{api_hex},       $this->{api_combo},       \@API_PRESETS);
	_bindPair($this, $this->{wp_in_hex},     $this->{wp_in_combo},     \@SVC_PRESETS);
	_bindPair($this, $this->{wp_out_hex},    $this->{wp_out_combo},    \@SVC_PRESETS);
	_bindPair($this, $this->{route_in_hex},  $this->{route_in_combo},  \@SVC_PRESETS);
	_bindPair($this, $this->{route_out_hex}, $this->{route_out_combo}, \@SVC_PRESETS);
	_bindPair($this, $this->{group_in_hex},  $this->{group_in_combo},  \@SVC_PRESETS);
	_bindPair($this, $this->{group_out_hex}, $this->{group_out_combo}, \@SVC_PRESETS);
	_bindPair($this, $this->{track_in_hex},  $this->{track_in_combo},  \@SVC_PRESETS);
	_bindPair($this, $this->{track_out_hex}, $this->{track_out_combo}, \@SVC_PRESETS);

	EVT_IDLE($this, \&onIdle);

	_initFromData($this, $data);
	$this->Layout();

	return $this;
}


sub _addMonRow
{
	my ($this, $grid, $label, $key, $has_active) = @_;
	my $CV = wxALIGN_CENTER_VERTICAL;

	$grid->Add(Wx::StaticText->new($this, -1, $label), 0, $CV);

	if ($has_active)
	{
		$this->{"${key}_active"} = Wx::CheckBox->new($this, -1, '');
		$grid->Add($this->{"${key}_active"}, 0, $CV);
	}
	else
	{
		$grid->Add(Wx::StaticText->new($this, -1, ''), 0, $CV);
	}

	for my $dir ('in', 'out')
	{
		$this->{"${key}_${dir}_hex"} = Wx::TextCtrl->new($this, -1, '0x0',
			wxDefaultPosition, [70,-1], wxTE_PROCESS_ENTER);
		$grid->Add($this->{"${key}_${dir}_hex"}, 0, $CV);

		$this->{"${key}_${dir}_combo"} = Wx::ComboBox->new($this, -1, 'off',
			wxDefaultPosition, [110,-1], \@SVC_NAMES, wxCB_READONLY);
		$grid->Add($this->{"${key}_${dir}_combo"}, 0, $CV);
	}
}


sub _bindPair
{
	my ($this, $hex, $combo, $presets) = @_;

	EVT_TEXT_ENTER($this, $hex, sub
	{
		_syncHexToCombo($hex, $combo, $presets);
		_applyAll($this);
	});

	Wx::Event::EVT_KILL_FOCUS($hex, sub
	{
		my ($c, $e) = @_;
		_syncHexToCombo($hex, $combo, $presets);
		_applyAll($this);
		$e->Skip();
	});

	EVT_COMBOBOX($this, $combo, sub
	{
		_syncComboToHex($combo, $hex, $presets);
		_applyAll($this);
	});
}


#-------------------------------------------------
# idle — detect external monitor bit changes
#-------------------------------------------------

sub onIdle
{
	my ($this, $event) = @_;
	my $cur  = _currentSnapshot();
	my $snap = $this->{_mon_snapshot};

	my $changed = 0;
	for my $k (keys %$cur)
	{
		if (!defined($snap->{$k}) || $snap->{$k} != $cur->{$k})
		{
			$changed = 1;
			last;
		}
	}

	if ($changed)
	{
		$this->{_mon_snapshot} = $cur;
		_loadSnapshot($this, $cur);
	}

	$event->Skip();
	sleep(0.02);
	$event->RequestMore();
}


#-------------------------------------------------
# snapshot helpers
#-------------------------------------------------

sub _currentSnapshot
{
	my $mask  = $DISPLAY_MASK;
	my $wpmgr = $raydp->findImplementedService('WPMGR', 1);
	my $track = $raydp->findImplementedService('TRACK', 1);
	my $wmd   = $wpmgr ? $wpmgr->{mon_defs} : $SHARK_DEFAULTS{$SPORT_WPMGR};
	my $tmd   = $track ? $track->{mon_defs}  : $SHARK_DEFAULTS{$SPORT_TRACK};
	return {
		wpmgr_active => $wmd->{active} ? 1 : 0,
		wp_in        => $wmd->{mon_ins}[$MON_WHAT_WAYPOINT]  & $mask,
		wp_out       => $wmd->{mon_outs}[$MON_WHAT_WAYPOINT] & $mask,
		route_in     => $wmd->{mon_ins}[$MON_WHAT_ROUTE]     & $mask,
		route_out    => $wmd->{mon_outs}[$MON_WHAT_ROUTE]    & $mask,
		group_in     => $wmd->{mon_ins}[$MON_WHAT_GROUP]     & $mask,
		group_out    => $wmd->{mon_outs}[$MON_WHAT_GROUP]    & $mask,
		track_active => $tmd->{active} ? 1 : 0,
		track_in     => $tmd->{mon_in}  & $mask,
		track_out    => $tmd->{mon_out} & $mask,
		api_builds   => $MONITOR_API_BUILDS & $mask,
	};
}


sub _loadSnapshot
{
	my ($this, $snap) = @_;
	$this->{wpmgr_active}->SetValue($snap->{wpmgr_active} ? 1 : 0);
	_setRow($this, 'wp',    $snap->{wp_in}    // 0, $snap->{wp_out}    // 0, \@SVC_PRESETS);
	_setRow($this, 'route', $snap->{route_in} // 0, $snap->{route_out} // 0, \@SVC_PRESETS);
	_setRow($this, 'group', $snap->{group_in} // 0, $snap->{group_out} // 0, \@SVC_PRESETS);
	$this->{track_active}->SetValue($snap->{track_active} ? 1 : 0);
	_setRow($this, 'track', $snap->{track_in} // 0, $snap->{track_out} // 0, \@SVC_PRESETS);
	_setHexComboCtrl($this->{api_hex}, $this->{api_combo},
		$snap->{api_builds} // 0, \@API_PRESETS);
}


sub _initFromData
{
	my ($this, $data) = @_;

	my $snap = ($data && ref($data) eq 'HASH') ? $data : _currentSnapshot();
	_loadSnapshot($this, $snap);
	_applyAll($this);
	$this->{_mon_snapshot} = _currentSnapshot();
}


#-------------------------------------------------
# apply to SHARK_DEFAULTS (= live service mon_defs)
#-------------------------------------------------

sub _applyAll
{
	my ($this) = @_;

	my $shark = $MON_SRC_SHARK;

	my $active  = $this->{wpmgr_active}->GetValue() ? 1 : 0;
	my $wp_in   = _parseHex($this->{wp_in_hex}->GetValue())    | $shark;
	my $wp_out  = _parseHex($this->{wp_out_hex}->GetValue())   | $shark;
	my $rt_in   = _parseHex($this->{route_in_hex}->GetValue()) | $shark;
	my $rt_out  = _parseHex($this->{route_out_hex}->GetValue())| $shark;
	my $gr_in   = _parseHex($this->{group_in_hex}->GetValue()) | $shark;
	my $gr_out  = _parseHex($this->{group_out_hex}->GetValue())| $shark;

	my $wmd = $SHARK_DEFAULTS{$SPORT_WPMGR};
	$wmd->{active}                       = $active;
	$wmd->{mon_ins}[$MON_WHAT_WAYPOINT]  = $wp_in;
	$wmd->{mon_outs}[$MON_WHAT_WAYPOINT] = $wp_out;
	$wmd->{mon_ins}[$MON_WHAT_ROUTE]     = $rt_in;
	$wmd->{mon_outs}[$MON_WHAT_ROUTE]    = $rt_out;
	$wmd->{mon_ins}[$MON_WHAT_GROUP]     = $gr_in;
	$wmd->{mon_outs}[$MON_WHAT_GROUP]    = $gr_out;

	my $t_active = $this->{track_active}->GetValue() ? 1 : 0;
	my $t_in     = _parseHex($this->{track_in_hex}->GetValue())  | $shark;
	my $t_out    = _parseHex($this->{track_out_hex}->GetValue()) | $shark;

	my $tmd = $SHARK_DEFAULTS{$SPORT_TRACK};
	$tmd->{active}  = $t_active;
	$tmd->{mon_in}  = $t_in;
	$tmd->{mon_out} = $t_out;

	$MONITOR_API_BUILDS = _parseHex($this->{api_hex}->GetValue());
}


#-------------------------------------------------
# sync helpers
#-------------------------------------------------

sub _syncHexToCombo
{
	my ($hex_ctrl, $combo, $presets) = @_;
	my $val = _parseHex($hex_ctrl->GetValue());
	$hex_ctrl->SetValue(_fmtHex($val));
	$combo->SetSelection(_findPreset($val, $presets));
}


sub _syncComboToHex
{
	my ($combo, $hex_ctrl, $presets) = @_;
	my $idx = $combo->GetSelection();
	return if $idx < 0 || $idx >= scalar(@$presets);
	$hex_ctrl->SetValue(_fmtHex($presets->[$idx][1]));
}


sub _setRow
{
	my ($this, $key, $in_val, $out_val, $presets) = @_;
	_setHexComboCtrl($this->{"${key}_in_hex"},  $this->{"${key}_in_combo"},  $in_val,  $presets);
	_setHexComboCtrl($this->{"${key}_out_hex"}, $this->{"${key}_out_combo"}, $out_val, $presets);
}


sub _setHexComboCtrl
{
	my ($hex_ctrl, $combo, $val, $presets) = @_;
	$hex_ctrl->SetValue(_fmtHex($val));
	$combo->SetSelection(_findPreset($val, $presets));
}


#-------------------------------------------------
# low-level utilities
#-------------------------------------------------

sub _parseHex
{
	my ($str) = @_;
	$str =~ s/\s//g;
	$str =~ s/^0x//i;
	return 0 unless $str =~ /^[0-9a-fA-F]+$/;
	return hex($str);
}


sub _fmtHex
{
	my ($val) = @_;
	return sprintf('0x%x', $val // 0);
}


sub _findPreset
{
	my ($val, $presets) = @_;
	for my $i (0 .. $#$presets)
	{
		return $i if $presets->[$i][1] == $val;
	}
	return scalar(@$presets);	# 'custom'
}


#-------------------------------------------------
# ini persistence
#-------------------------------------------------

sub getDataForIniFile
{
	my ($this) = @_;
	return {
		wpmgr_active => $this->{wpmgr_active}->GetValue() ? 1 : 0,
		wp_in        => _parseHex($this->{wp_in_hex}->GetValue()),
		wp_out       => _parseHex($this->{wp_out_hex}->GetValue()),
		route_in     => _parseHex($this->{route_in_hex}->GetValue()),
		route_out    => _parseHex($this->{route_out_hex}->GetValue()),
		group_in     => _parseHex($this->{group_in_hex}->GetValue()),
		group_out    => _parseHex($this->{group_out_hex}->GetValue()),
		track_active => $this->{track_active}->GetValue() ? 1 : 0,
		track_in     => _parseHex($this->{track_in_hex}->GetValue()),
		track_out    => _parseHex($this->{track_out_hex}->GetValue()),
		api_builds   => _parseHex($this->{api_hex}->GetValue()),
	};
}


1;
