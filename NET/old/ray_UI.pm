#---------------------------------------
# ray_UI.pm
#---------------------------------------

package apps::raymarine::NET::ray_UI;
use strict;
use warnings;
use Win32::Console::ANSI;

BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (

		$fg_black
		$fg_red
		$fg_green
		$fg_brown
		$fg_blue
		$fg_magenta
		$fg_cyan
		$fg_light_gray

		$bg_black
		$bg_red
		$bg_green
		$bg_brown
		$bg_blue
		$bg_magenta
		$bg_cyan
		$bg_light_gray

		clear_screen
		clear_eol
		cursor
		color_str

		testUI

	);
}


our $fg_black 	     	= 30;
our $fg_red 	     	= 31;
our $fg_green 	     	= 32;
our $fg_brown 	 		= 33;
our $fg_blue 	     	= 34;
our $fg_magenta 	 	= 35;
our $fg_cyan 	     	= 36;
our $fg_light_gray 		= 37;

our $bg_black 	     	= 40;
our $bg_red 	     	= 41;
our $bg_green 	     	= 42;
our $bg_brown 	 		= 43;
our $bg_blue 	     	= 44;
our $bg_magenta 	 	= 45;
our $bg_cyan 	     	= 46;
our $bg_light_gray 		= 47;


sub clear_screen	{ print "\e[0;$bg_black"."m"; print "\e[2J";}
sub clear_eol		{ print "\e[K"; }
sub cursor 			{ my ($row, $col) = @_;  $row++; $col++; print "\e[$row;$col"."H"; }
sub color_str 		{ my ($color) = @_;  return "\e[".$color."m"; }

sub testUI
{
	for (my $i=0; $i<16; $i++)
	{
		my $bg = 40 + ($i % 8);

		for (my $j=0; $j<16; $j++)
		{
			cursor($i,$j * 6);

			my $fg = 30 + ($j % 8);
			my $bold = $j>=8 ? 1 : 21;
			print "\e[0;$bold;$fg;$bg"."m";
			print "TEST";
			print "\e[m";
		}
	}
}

1;

