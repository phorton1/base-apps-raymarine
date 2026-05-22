#!/usr/bin/perl
#-------------------------------------------------------------------------
# _makeSwatches.pl
#-------------------------------------------------------------------------
# Generate fixed-size sym swatch assets for the winTreeBase swatch image
# list (see winTreeColors.pm).
#
# Source: apps/navMate/sym_catalog/clean00.png .. clean39.png
#         (variable-size 14x17 to 23x22, see e80_symbols_clipart memory)
# Output: apps/navMate/sym_catalog/swatch00.png .. swatch39.png
#         (fixed $SWATCH_W x $SWATCH_H, suitable for a wxImageList)
#
# The wxImageList that hosts sym + color swatches in the tree windows is
# fixed-size; the source clean*.png set is not, so they can't be loaded
# directly into the image list.  This script Lanczos-downsamples each
# clean*.png to the target swatch size.
#
# Aspect ratio: source bitmaps are roughly square (14x17 to 23x22); the
# small distortion from a straight stretch to a square target is below
# visual threshold at 13x13.  If a future swatch size makes the
# distortion visible, switch to fit-on-transparent-canvas here.
#
# Re-running this script is safe and idempotent -- it overwrites any
# existing swatch*.png with the freshly resampled copy.
#
# Run from the repo root via bash:
#   /c/Perl/bin/perl.exe -I/base apps/navMate/_makeSwatches.pl > \
#       /c/base_data/temp/raymarine/makeSwatches.log 2>&1
#
# Output goes to the log file (per global feedback_perl_output_capture
# rule) so the bare Wx loader chatter doesn't corrupt the Claude TUI.

use strict;
use warnings;
use Wx qw(:everything);
use n_utils qw($app_dir);

my $SWATCH_W = 15;
my $SWATCH_H = 15;
my $N_SYMS   = 40;

my $dir = "$app_dir/sym_catalog";

# wxImage needs the PNG handler registered before reading PNGs when
# running outside a wxApp context.
Wx::Image::AddHandler(Wx::PNGHandler->new);

my $made    = 0;
my $missing = 0;
my $failed  = 0;

for my $i (0 .. $N_SYMS - 1)
{
    my $src = sprintf('%s/clean%02d.png', $dir, $i);
    my $dst = sprintf('%s/swatch%02d.png', $dir, $i);
    if (!-f $src)
    {
        print STDERR "MISSING source: $src\n";
        $missing++;
        next;
    }
    my $img = Wx::Image->new($src, wxBITMAP_TYPE_PNG);
    if (!$img->IsOk())
    {
        print STDERR "LOAD failed: $src\n";
        $failed++;
        next;
    }
    my $w  = $img->GetWidth();
    my $h  = $img->GetHeight();
    $img->Rescale($SWATCH_W, $SWATCH_H, wxIMAGE_QUALITY_HIGH);
    if (!$img->SaveFile($dst, wxBITMAP_TYPE_PNG))
    {
        print STDERR "SAVE failed: $dst\n";
        $failed++;
        next;
    }
    printf("  %s (%2dx%-2d) -> %s (%2dx%-2d)\n",
        sprintf('clean%02d.png', $i), $w, $h,
        sprintf('swatch%02d.png', $i), $SWATCH_W, $SWATCH_H);
    $made++;
}

printf("done: %d made, %d missing, %d failed\n", $made, $missing, $failed);

1;
