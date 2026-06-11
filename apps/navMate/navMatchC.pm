#!/usr/bin/perl
#------------------------------------------
# navMatchC.pm
#------------------------------------------
# C-kernel companion to navMatch.pm.  Exposes compareLineStringPair_c(),
# returning the SAME result hash that navMatch::scoreLineStringPair()
# returns.  Algorithm is a direct line-for-line port of the PP cascade
# (bbox -> exact pass -> bobbing-decimate -> subsequence DTW -> classify).
#
# Boundary chosen at the per-pair level (rather than the inner DP cell)
# so the Perl/C transition cost is paid ONCE per pair, not N*M times.
# Everything between "given two point arrays" and "here is the score
# struct" runs in C.  Candidate enumeration, ranking, dedup, and UI
# stay in Perl / wxPerl.
#
# Source of truth for constants:
#   navMatch.pm's `use constant { ... }` block.  This file reads those
#   values via navMatch::EXACT_DEG() etc. and packs them into the
#   per-call buffer header so the C kernel sees current Perl values
#   on every call.  No hard-coded mirrors of constants in the C source.
#
# Mode selection:
#   This module's compareLineStringPair_c() is called by navMatch.pm's
#   dispatcher when $navMatch::COMPARE_MODE is 'c' or 'both'.  The
#   dispatcher itself lives in navMatch.pm and is added in a later step;
#   this file is reviewable in isolation first.
#
# Memory:
#   All working buffers (DP cost grid, traceback, decimated arrays,
#   exact-pass run trackers) are allocated lazily on the FIRST call
#   from inside the C kernel and reused for the life of the process.
#   Peak resident footprint ~ 48 MB (DTW grid at DTW_MAX_CELLS).  No
#   per-call malloc/free.  NOT THREAD SAFE -- assumes single-threaded
#   wxPerl, which is how navMate runs.
#
# Toolchain:
#   ActivePerl 5.12.4 + Inline 0.5 + MinGW gcc 4.5.2 on Windows.  Code
#   uses the packed-SV* pattern (one SV * in, one SV * out) per the
#   global Inline::C conventions memory -- so old-Inline parser quirks
#   never come into play.  Same pattern is forward-compatible to newer
#   Inline on Linux / rPi if this ever needs to run there.

package navMatchC;
use strict;
use warnings;
use Win32;
use Pub::Utils qw(display warning error $resource_dir $temp_dir);
use n_utils qw($app_dir);
use navMatch;

our $dbg_navmc = -1;   # raise for tracing pack/unpack; -1 = silent

# Inline cache directory.  Inline 0.5 needs an absolute, drive-lettered,
# WRITABLE directory.  The compiled .dll ships bundled (read-only, and under a
# drive-less /PROGRA~2 path that Inline rejects) in the resource tree at
# $resource_dir/_Inline.  In a packaged build, copy it out to a writable,
# drive-lettered temp dir (Win32::GetFullPathName normalizes the path) and
# point Inline there.  In dev, the in-repo _res/_Inline is already writable.
our $INLINE_DIR;
BEGIN
{
	if ($Cava::Packager::PACKAGED)
	{
		my $src = Win32::GetFullPathName("$resource_dir/_Inline");
		my $tmp = $temp_dir || $ENV{TEMP};
		$INLINE_DIR = Win32::GetFullPathName("$tmp/_Inline");
		if (-d $src && !-d $INLINE_DIR)
		{
			system('xcopy', $src, $INLINE_DIR, '/E', '/I', '/Y', '/Q');
		}
	}
	else
	{
		$INLINE_DIR = "$resource_dir/_Inline";
	}
	mkdir $INLINE_DIR if !-d $INLINE_DIR;
}

use Inline
	Config =>
	DIRECTORY => $INLINE_DIR;

use Inline C => <<'__END_C__';

/*
 * ===========================================================================
 *  navMatchC -- pair scorer kernel
 * ===========================================================================
 *
 *  Entry point:  score_pair_xs(SV *packed_in)
 *
 *  packed_in layout (built by Perl side -- see _pack_inputs):
 *
 *    HEADER (fixed):
 *      double EXACT_DEG
 *      double BBOX_PAD_DEG          -- unused inside C (bbox runs in PP)
 *      double DTW_PRUNE_DEG
 *      double DTW_SEG_PRUNE_DEG
 *      double STEP_PENALTY
 *      double BOBBING_DEG
 *      double LAT_SHIFT_DEG
 *      double SHIFT_TOLERANCE_DEG
 *      int    EXACT_MIN_RUN
 *      int    DTW_MAX_CELLS
 *      int    subj_n
 *      int    cand_n
 *      int    with_steps           -- 1 = include DTW steps in output
 *
 *    POINTS:
 *      double subj_lat[subj_n], subj_lon[subj_n]   (interleaved lat,lon)
 *      double cand_lat[cand_n], cand_lon[cand_n]
 *
 *  Output  (one SV pushed via Inline_Stack_Push, a packed byte string):
 *
 *    HEADER (fixed, 80 bytes):
 *      int    tier_code     0=none 1=exact 2=match 3=near
 *      int    shape_code    0=undef 1=full 2=subset 3=superset
 *                           4=trimmed 5=partial 6=anomaly
 *      int    mode_code     0=undef 1=noshift 2=latshift
 *      double quality                 (0.0 when undef)
 *      double subj_coverage
 *      double cand_coverage
 *      int    win_subj_start          (-1 when no window)
 *      int    win_subj_end
 *      int    win_cand_start
 *      int    win_cand_end
 *      int    subj_before
 *      int    subj_in_match
 *      int    subj_after
 *      int    cand_before
 *      int    cand_in_match
 *      int    cand_after
 *      int    steps_n                 (>0 only when DTW; 0 otherwise)
 *
 *    STEPS (variable, only present when steps_n > 0):
 *      For each step, 20 bytes tightly packed:
 *        int    subj_idx_original
 *        int    cand_idx_original
 *        int    tb              0=diag 1=vert 2=horiz 3=start
 *        double cost
 *
 *  Tightness: all writes are byte-by-byte via memcpy so there is no
 *  struct-padding ambiguity.  Perl side unpacks with matching offsets.
 */

#include <math.h>
#include <string.h>
#include <stdlib.h>

#define INF              1e18
#define HEADER_BYTES     80
#define STEP_BYTES       20

#define TIER_NONE        0
#define TIER_EXACT       1
#define TIER_MATCH       2
#define TIER_NEAR        3

#define SHAPE_UNDEF      0
#define SHAPE_FULL       1
#define SHAPE_SUBSET     2
#define SHAPE_SUPERSET   3
#define SHAPE_TRIMMED    4
#define SHAPE_PARTIAL    5
#define SHAPE_ANOMALY    6

#define MODE_UNDEF       0
#define MODE_NOSHIFT     1
#define MODE_LATSHIFT    2

#define TB_DIAG          0
#define TB_VERT          1
#define TB_HORIZ         2
#define TB_START         3
#define TB_NONE         -1

/*
 * --- module-level buffers, allocated once on first call ---
 */
static int g_initialized = 0;
static int g_max_cells   = 0;
static int g_max_pts     = 0;

static double *g_D       = NULL;   /* DP cost grid, g_max_cells doubles */
static char   *g_TB      = NULL;   /* DP traceback,  g_max_cells bytes  */

static double *g_raw_subj_lat = NULL;
static double *g_raw_subj_lon = NULL;
static double *g_raw_cand_lat = NULL;
static double *g_raw_cand_lon = NULL;

static double *g_dec_subj_lat = NULL;
static double *g_dec_subj_lon = NULL;
static int    *g_dec_subj_idx = NULL;
static double *g_dec_cand_lat = NULL;
static double *g_dec_cand_lon = NULL;
static int    *g_dec_cand_idx = NULL;

/* exact-pass run trackers, sized to g_max_pts */
static int *g_active_no_si = NULL;   /* run i_start indexed by j */
static int *g_active_no_sj = NULL;   /* run j_start indexed by j */
static int *g_active_no_ln = NULL;   /* run length indexed by j, 0 = no run */
static int *g_active_sh_si = NULL;
static int *g_active_sh_sj = NULL;
static int *g_active_sh_ln = NULL;
static int *g_new_no_si    = NULL;
static int *g_new_no_sj    = NULL;
static int *g_new_no_ln    = NULL;
static int *g_new_sh_si    = NULL;
static int *g_new_sh_sj    = NULL;
static int *g_new_sh_ln    = NULL;

/* candidate index sorted by lat_bin, for exact-pass 3-bin lookup */
static int *g_cand_sorted   = NULL;   /* indices into cand arrays */
static int *g_cand_lat_bin  = NULL;   /* parallel: lat_bin of each cand */

/* walkback step buffer (decimated-index) -- holds current path being explored */
static int    *g_step_i    = NULL;
static int    *g_step_j    = NULL;
static int    *g_step_tb   = NULL;
static double *g_step_cost = NULL;
/* and the BEST path found so far */
static int    *g_best_step_i    = NULL;
static int    *g_best_step_j    = NULL;
static int    *g_best_step_tb   = NULL;
static double *g_best_step_cost = NULL;
static int     g_best_n = 0;


static void ensure_init(int max_cells, int max_pts)
{
	if (g_initialized) return;
	g_max_cells = max_cells;
	g_max_pts   = max_pts;

	g_D  = (double *)malloc(sizeof(double) * max_cells);
	g_TB = (char   *)malloc(sizeof(char)   * max_cells);

	g_raw_subj_lat = (double *)malloc(sizeof(double) * max_pts);
	g_raw_subj_lon = (double *)malloc(sizeof(double) * max_pts);
	g_raw_cand_lat = (double *)malloc(sizeof(double) * max_pts);
	g_raw_cand_lon = (double *)malloc(sizeof(double) * max_pts);

	g_dec_subj_lat = (double *)malloc(sizeof(double) * max_pts);
	g_dec_subj_lon = (double *)malloc(sizeof(double) * max_pts);
	g_dec_subj_idx = (int    *)malloc(sizeof(int)    * max_pts);
	g_dec_cand_lat = (double *)malloc(sizeof(double) * max_pts);
	g_dec_cand_lon = (double *)malloc(sizeof(double) * max_pts);
	g_dec_cand_idx = (int    *)malloc(sizeof(int)    * max_pts);

	g_active_no_si = (int *)malloc(sizeof(int) * max_pts);
	g_active_no_sj = (int *)malloc(sizeof(int) * max_pts);
	g_active_no_ln = (int *)malloc(sizeof(int) * max_pts);
	g_active_sh_si = (int *)malloc(sizeof(int) * max_pts);
	g_active_sh_sj = (int *)malloc(sizeof(int) * max_pts);
	g_active_sh_ln = (int *)malloc(sizeof(int) * max_pts);
	g_new_no_si    = (int *)malloc(sizeof(int) * max_pts);
	g_new_no_sj    = (int *)malloc(sizeof(int) * max_pts);
	g_new_no_ln    = (int *)malloc(sizeof(int) * max_pts);
	g_new_sh_si    = (int *)malloc(sizeof(int) * max_pts);
	g_new_sh_sj    = (int *)malloc(sizeof(int) * max_pts);
	g_new_sh_ln    = (int *)malloc(sizeof(int) * max_pts);

	g_cand_sorted  = (int *)malloc(sizeof(int) * max_pts);
	g_cand_lat_bin = (int *)malloc(sizeof(int) * max_pts);

	/* walkback buffers sized to max path length = max_pts + max_pts */
	int max_path = 2 * max_pts;
	g_step_i    = (int    *)malloc(sizeof(int)    * max_path);
	g_step_j    = (int    *)malloc(sizeof(int)    * max_path);
	g_step_tb   = (int    *)malloc(sizeof(int)    * max_path);
	g_step_cost = (double *)malloc(sizeof(double) * max_path);
	g_best_step_i    = (int    *)malloc(sizeof(int)    * max_path);
	g_best_step_j    = (int    *)malloc(sizeof(int)    * max_path);
	g_best_step_tb   = (int    *)malloc(sizeof(int)    * max_path);
	g_best_step_cost = (double *)malloc(sizeof(double) * max_path);

	g_initialized = 1;
}


/*
 * --- helpers ---
 */
static double point_to_segment_distance(double plat, double plon,
                                        double alat, double alon,
                                        double blat, double blon)
{
	double ax = blat - alat;
	double ay = blon - alon;
	double len_sq = ax * ax + ay * ay;
	if (len_sq < 1e-20)
	{
		double dx = plat - alat;
		double dy = plon - alon;
		return sqrt(dx * dx + dy * dy);
	}
	double t = ((plat - alat) * ax + (plon - alon) * ay) / len_sq;
	if (t < 0.0) t = 0.0;
	if (t > 1.0) t = 1.0;
	double cx = alat + t * ax;
	double cy = alon + t * ay;
	double dx = plat - cx;
	double dy = plon - cy;
	return sqrt(dx * dx + dy * dy);
}


/*
 * Decimate bobbing -- exact port of _decimateBobbing.  First and last
 * points always preserved; intermediate points dropped if closer than
 * BOBBING_DEG to the most recently kept point.  Returns decimated count;
 * writes to out_lat/out_lon/out_idx.
 */
static int decimate_bobbing(const double *lat, const double *lon, int n,
                             double bobbing_deg,
                             double *out_lat, double *out_lon, int *out_idx)
{
	if (n < 3)
	{
		int i;
		for (i = 0; i < n; i++)
		{
			out_lat[i] = lat[i];
			out_lon[i] = lon[i];
			out_idx[i] = i;
		}
		return n;
	}

	int kept = 0;
	out_lat[kept] = lat[0];
	out_lon[kept] = lon[0];
	out_idx[kept] = 0;
	kept++;

	double last_lat = lat[0];
	double last_lon = lon[0];
	double thresh_sq = bobbing_deg * bobbing_deg;

	int i;
	for (i = 1; i < n - 1; i++)
	{
		double dlat = lat[i] - last_lat;
		double dlon = lon[i] - last_lon;
		double d2 = dlat * dlat + dlon * dlon;
		if (d2 >= thresh_sq)
		{
			out_lat[kept] = lat[i];
			out_lon[kept] = lon[i];
			out_idx[kept] = i;
			kept++;
			last_lat = lat[i];
			last_lon = lon[i];
		}
	}
	out_lat[kept] = lat[n-1];
	out_lon[kept] = lon[n-1];
	out_idx[kept] = n-1;
	kept++;
	return kept;
}


/*
 * Comparator for qsort -- sort candidate-index array by g_cand_lat_bin.
 * Operates on indices so we can iterate candidates in lat-bin order.
 */
static int *g_sort_keys = NULL;   /* set by exact_pass before qsort */
static int cmp_cand_lat_bin(const void *a, const void *b)
{
	int ia = *(const int *)a;
	int ib = *(const int *)b;
	int ka = g_sort_keys[ia];
	int kb = g_sort_keys[ib];
	if (ka < kb) return -1;
	if (ka > kb) return  1;
	return 0;
}


/*
 * Exact pass -- hash-based search for the longest contiguous run of 1:1
 * aligned cells under the no-shift or lat-shift predicate.  Match for
 * _exactPass in PP.  Returns 1 if a qualifying run was found (writing
 * results to *out_*), 0 otherwise.
 *
 * Binning strategy: candidates are sorted once by lat_bin.  For each
 * subject point we binary-search the run of candidates whose lat_bin is
 * within [bl-1, bl+1] (no-shift) and the two lat-shifted ranges (one
 * for each sign of the shift).  Within each range we test the cell
 * predicates directly.  This matches the PP version's 3x3+shifted-3x3
 * neighborhood walk but trades a Perl hash table for a sorted-array
 * lookup, which is what works cleanly in C.
 */
static int exact_pass(const double *slat, const double *slon, int n,
                       const double *clat, const double *clon, int m,
                       double exact, double shift_mag, double shift_tol,
                       int min_run,
                       int *out_i_start, int *out_i_end,
                       int *out_j_start, int *out_j_end,
                       int *out_length,  int *out_mode)
{
	if (n < 1 || m < 1) return 0;

	double bin_size = exact;
	double exact_sq = exact * exact;
	int shift_bins  = (int)(shift_mag / bin_size + 0.5);

	/* sort candidate indices by lat_bin.  Use (int) truncation toward
	 * zero, matching PP's `int($lat / $bin_size)` semantics. */
	int j;
	for (j = 0; j < m; j++)
	{
		g_cand_sorted[j]  = j;
		g_cand_lat_bin[j] = (int)(clat[j] / bin_size);
	}
	g_sort_keys = g_cand_lat_bin;
	qsort(g_cand_sorted, m, sizeof(int), cmp_cand_lat_bin);

	/* reset active-run arrays (lengths to 0 = empty) */
	int jj;
	for (jj = 0; jj < m; jj++)
	{
		g_active_no_ln[jj] = 0;
		g_active_sh_ln[jj] = 0;
	}

	int best_len     = 0;
	int best_i_start = 0;
	int best_i_end   = 0;
	int best_j_start = 0;
	int best_j_end   = 0;
	int best_mode    = MODE_UNDEF;

	int i;
	for (i = 0; i < n; i++)
	{
		double s_lat = slat[i];
		double s_lon = slon[i];
		int bl = (int)(s_lat / bin_size);

		/* reset new-* run trackers for this subject row */
		for (jj = 0; jj < m; jj++)
		{
			g_new_no_ln[jj] = 0;
			g_new_sh_ln[jj] = 0;
		}

		/* walk candidates whose lat_bin is in one of three bands:
		 *   [bl-1,           bl+1]                no-shift band
		 *   [bl-shift_bins-1, bl-shift_bins+1]    -shift band
		 *   [bl+shift_bins-1, bl+shift_bins+1]    +shift band
		 * For each, binary-search the sorted array for the range.
		 * We tolerate duplicate j's across overlapping bands -- handled
		 * by a seen-mark array kept in g_new_no_ln re-test (a cand j
		 * never appears twice in one band's range since each j has one
		 * lat_bin, but it can appear once in noshift and once in shift).
		 * In PP this was deduped with a %seen hash; here, we make the
		 * predicate evaluation idempotent (the run-extension logic only
		 * looks at active_*_ln[j-1], so repeating the test on the same
		 * j just reproduces the same run -- harmless).
		 */
		int band;
		for (band = 0; band < 3; band++)
		{
			int center;
			if      (band == 0) center = bl;
			else if (band == 1) center = bl - shift_bins;
			else                center = bl + shift_bins;

			int lo_bin = center - 1;
			int hi_bin = center + 1;

			/* binary search for the first cand_sorted index with
			 * lat_bin >= lo_bin */
			int lo = 0, hi = m;
			while (lo < hi)
			{
				int mid = (lo + hi) / 2;
				if (g_cand_lat_bin[g_cand_sorted[mid]] < lo_bin)
					lo = mid + 1;
				else
					hi = mid;
			}
			int start = lo;

			int k;
			for (k = start; k < m; k++)
			{
				int cj = g_cand_sorted[k];
				int cb = g_cand_lat_bin[cj];
				if (cb > hi_bin) break;

				double dlat = s_lat - clat[cj];
				double dlon = s_lon - clon[cj];

				/* No-shift predicate */
				if (dlat * dlat + dlon * dlon <= exact_sq)
				{
					int prev_len = (cj > 0) ? g_active_no_ln[cj - 1] : 0;
					int run_si, run_sj, run_len;
					if (prev_len > 0)
					{
						run_si  = g_active_no_si[cj - 1];
						run_sj  = g_active_no_sj[cj - 1];
						run_len = prev_len + 1;
					}
					else
					{
						run_si  = i;
						run_sj  = cj;
						run_len = 1;
					}
					int ex_len = g_new_no_ln[cj];
					if (ex_len == 0 || run_len > ex_len)
					{
						g_new_no_si[cj] = run_si;
						g_new_no_sj[cj] = run_sj;
						g_new_no_ln[cj] = run_len;
					}
					if (run_len > best_len)
					{
						best_len     = run_len;
						best_i_start = run_si;
						best_i_end   = i;
						best_j_start = run_sj;
						best_j_end   = cj;
						best_mode    = MODE_NOSHIFT;
					}
				}
				/* Lat-shift predicate (disjoint band, mutually exclusive) */
				else if (fabs(dlon) <= exact
				      && fabs(fabs(dlat) - shift_mag) <= shift_tol)
				{
					int prev_len = (cj > 0) ? g_active_sh_ln[cj - 1] : 0;
					int run_si, run_sj, run_len;
					if (prev_len > 0)
					{
						run_si  = g_active_sh_si[cj - 1];
						run_sj  = g_active_sh_sj[cj - 1];
						run_len = prev_len + 1;
					}
					else
					{
						run_si  = i;
						run_sj  = cj;
						run_len = 1;
					}
					int ex_len = g_new_sh_ln[cj];
					if (ex_len == 0 || run_len > ex_len)
					{
						g_new_sh_si[cj] = run_si;
						g_new_sh_sj[cj] = run_sj;
						g_new_sh_ln[cj] = run_len;
					}
					if (run_len > best_len)
					{
						best_len     = run_len;
						best_i_start = run_si;
						best_i_end   = i;
						best_j_start = run_sj;
						best_j_end   = cj;
						best_mode    = MODE_LATSHIFT;
					}
				}
			}
		}

		/* swap new -> active for the next i-row */
		int *t;
		t = g_active_no_si; g_active_no_si = g_new_no_si; g_new_no_si = t;
		t = g_active_no_sj; g_active_no_sj = g_new_no_sj; g_new_no_sj = t;
		t = g_active_no_ln; g_active_no_ln = g_new_no_ln; g_new_no_ln = t;
		t = g_active_sh_si; g_active_sh_si = g_new_sh_si; g_new_sh_si = t;
		t = g_active_sh_sj; g_active_sh_sj = g_new_sh_sj; g_new_sh_sj = t;
		t = g_active_sh_ln; g_active_sh_ln = g_new_sh_ln; g_new_sh_ln = t;
	}

	if (best_len < min_run) return 0;
	*out_i_start = best_i_start;
	*out_i_end   = best_i_end;
	*out_j_start = best_j_start;
	*out_j_end   = best_j_end;
	*out_length  = best_len;
	*out_mode    = best_mode;
	return 1;
}


/*
 * Subsequence DTW -- fills g_D / g_TB and returns 1 on success.
 *
 * Direct port of _subsequenceDTW: Sakoe-Chiba band, outer point-to-point
 * prune at DTW_PRUNE_DEG, refined point-to-segment cost, inner prune at
 * DTW_SEG_PRUNE_DEG, free start on row 0 / column 0, four-way predecessor
 * with STEP_PENALTY on vert/horiz.
 */
/* NOTE: parameter is named "outer_prune" rather than "near" because
 * MinGW's windows.h legacy macros #define `near` to nothing -- a leftover
 * from 16-bit segment qualifiers.  Any C identifier named `near` gets
 * macro-substituted and the parser reports it as a missing parameter
 * name.  Same applies to `far`.  Avoid both. */
static int subsequence_dtw(const double *a_lat, const double *a_lon, int n,
                            const double *b_lat, const double *b_lon, int m,
                            double exact,
                            double outer_prune, double seg_prune,
                            double step_penalty)
{
	double outer_prune_sq = outer_prune * outer_prune;
	int    larger  = (n > m) ? n : m;
	int    K       = (int)(larger * 0.25);
	if (K < 30) K = 30;
	double slope   = (double)m / (double)n;

	int i, j;
	for (i = 0; i < n; i++)
	{
		int i_off    = i * m;
		int j_center = (int)(i * slope);
		int j_min    = j_center - K;
		int j_max    = j_center + K;
		if (j_min < 0)      j_min = 0;
		if (j_max > m - 1)  j_max = m - 1;

		double alat = a_lat[i];
		double alon = a_lon[i];

		for (j = 0; j < m; j++)
		{
			int idx = i_off + j;
			if (j < j_min || j > j_max)
			{
				g_D[idx]  = INF;
				g_TB[idx] = TB_NONE;
				continue;
			}

			double dlat = alat - b_lat[j];
			if (fabs(dlat) > outer_prune)
			{
				g_D[idx]  = INF;
				g_TB[idx] = TB_NONE;
				continue;
			}
			double dlon = alon - b_lon[j];
			if (fabs(dlon) > outer_prune)
			{
				g_D[idx]  = INF;
				g_TB[idx] = TB_NONE;
				continue;
			}
			double d2 = dlat * dlat + dlon * dlon;
			if (d2 > outer_prune_sq)
			{
				g_D[idx]  = INF;
				g_TB[idx] = TB_NONE;
				continue;
			}
			double d = sqrt(d2);

			/* Segment-distance refinement only when point-to-point exceeds
			 * EXACT_DEG -- mirror of PP `if ($d > EXACT_DEG)` */
			if (d > exact)
			{
				if (j > 0)
				{
					double ds = point_to_segment_distance(
						alat, alon,
						b_lat[j-1], b_lon[j-1],
						b_lat[j],   b_lon[j]);
					if (ds < d) d = ds;
				}
				if (i > 0)
				{
					double ds = point_to_segment_distance(
						b_lat[j], b_lon[j],
						a_lat[i-1], a_lon[i-1],
						a_lat[i],   a_lon[i]);
					if (ds < d) d = ds;
				}
			}

			if (d > seg_prune)
			{
				g_D[idx]  = INF;
				g_TB[idx] = TB_NONE;
				continue;
			}

			double best_pred = INF;
			int    best_tb   = TB_NONE;

			if (i == 0 || j == 0)
			{
				best_pred = 0.0;
				best_tb   = TB_START;
			}
			if (i > 0 && j > 0)
			{
				double v = g_D[idx - m - 1];
				if (v < best_pred) { best_pred = v; best_tb = TB_DIAG; }
			}
			if (i > 0)
			{
				double v = g_D[idx - m] + step_penalty;
				if (v < best_pred) { best_pred = v; best_tb = TB_VERT; }
			}
			if (j > 0)
			{
				double v = g_D[idx - 1] + step_penalty;
				if (v < best_pred) { best_pred = v; best_tb = TB_HORIZ; }
			}

			if (best_pred >= INF)
			{
				g_D[idx]  = INF;
				g_TB[idx] = TB_NONE;
			}
			else
			{
				g_D[idx]  = best_pred + d;
				g_TB[idx] = (char)best_tb;
			}
		}
	}
	return 1;
}


/*
 * Walk back from end cell (i_end, j_end), writing the path (in reverse
 * order, i.e. end-to-start) into g_step_*.  Returns the number of steps
 * written, or 0 on failure (unreachable cell).
 *
 * The path's max_step_cost, total_cost, i_start, j_start are written
 * to the four out_* pointers.
 */
static int walkback_dtw(int i_end, int j_end, int m,
                         double *out_total_cost,
                         double *out_max_step_cost,
                         int    *out_i_start,
                         int    *out_j_start)
{
	int i = i_end;
	int j = j_end;
	int n_steps = 0;
	double total_cost = 0.0;
	double max_step   = 0.0;

	while (i >= 0 && j >= 0)
	{
		int idx = i * m + j;
		int tb  = g_TB[idx];
		if (tb == TB_NONE) break;

		double cell_cost;
		if (tb == TB_START)
		{
			cell_cost = g_D[idx];
		}
		else if (tb == TB_DIAG)
		{
			cell_cost = g_D[idx] - g_D[idx - m - 1];
		}
		else if (tb == TB_VERT)
		{
			cell_cost = g_D[idx] - g_D[idx - m];
		}
		else
		{
			cell_cost = g_D[idx] - g_D[idx - 1];
		}
		if (cell_cost < 0.0) cell_cost = 0.0;

		if (cell_cost > max_step) max_step = cell_cost;
		total_cost += cell_cost;

		g_step_i[n_steps]    = i;
		g_step_j[n_steps]    = j;
		g_step_tb[n_steps]   = tb;
		g_step_cost[n_steps] = cell_cost;
		n_steps++;

		if (tb == TB_START)        break;
		else if (tb == TB_DIAG)  { i--; j--; }
		else if (tb == TB_VERT)  { i--; }
		else                     { j--; }
	}

	if (n_steps == 0) return 0;
	*out_total_cost    = total_cost;
	*out_max_step_cost = max_step;
	*out_i_start       = g_step_i[n_steps - 1];
	*out_j_start       = g_step_j[n_steps - 1];
	return n_steps;
}


/*
 * --- output helpers --- packed-buffer writers, advance ptr by N bytes.
 */
static void write_int(char **p, int v)    { memcpy(*p, &v, 4); *p += 4; }
static void write_dbl(char **p, double v) { memcpy(*p, &v, 8); *p += 8; }

/* qsort comparator for sorting step costs ascending (used for median).
 * Hoisted to file scope rather than nested inside score_pair_xs so we
 * don't depend on the gcc nested-function extension. */
static int cmp_double_asc(const void *a, const void *b)
{
	double da = *(const double *)a;
	double db = *(const double *)b;
	if (da < db) return -1;
	if (da > db) return  1;
	return 0;
}

/* return an empty result (tier=none) as the output buffer */
static SV *make_empty_result()
{
	char buf[HEADER_BYTES];
	memset(buf, 0, HEADER_BYTES);
	char *p = buf;
	write_int(&p, TIER_NONE);     /* tier */
	write_int(&p, SHAPE_UNDEF);   /* shape */
	write_int(&p, MODE_UNDEF);    /* mode */
	write_dbl(&p, 0.0);           /* quality */
	write_dbl(&p, 0.0);           /* subj_coverage */
	write_dbl(&p, 0.0);           /* cand_coverage */
	write_int(&p, -1);            /* win_subj_start */
	write_int(&p, -1);            /* win_subj_end */
	write_int(&p, -1);            /* win_cand_start */
	write_int(&p, -1);            /* win_cand_end */
	write_int(&p, 0);             /* subj_before */
	write_int(&p, 0);             /* subj_in_match */
	write_int(&p, 0);             /* subj_after */
	write_int(&p, 0);             /* cand_before */
	write_int(&p, 0);             /* cand_in_match */
	write_int(&p, 0);             /* cand_after */
	write_int(&p, 0);             /* steps_n */
	return newSVpvn(buf, HEADER_BYTES);
}


/*
 * ===========================================================================
 *  Entry point.
 * ===========================================================================
 */
void score_pair_xs(SV *packed_in)
{
	Inline_Stack_Vars;

	STRLEN in_len;
	char *in = SvPV(packed_in, in_len);
	char *ip = in;

	/* header */
	double exact_deg, bbox_pad_deg, dtw_prune_deg, seg_prune_deg;
	double step_penalty, bobbing_deg, shift_mag, shift_tol;
	int    min_run, max_cells, subj_n, cand_n, with_steps;

	memcpy(&exact_deg,     ip, 8); ip += 8;
	memcpy(&bbox_pad_deg,  ip, 8); ip += 8;
	memcpy(&dtw_prune_deg, ip, 8); ip += 8;
	memcpy(&seg_prune_deg, ip, 8); ip += 8;
	memcpy(&step_penalty,  ip, 8); ip += 8;
	memcpy(&bobbing_deg,   ip, 8); ip += 8;
	memcpy(&shift_mag,     ip, 8); ip += 8;
	memcpy(&shift_tol,     ip, 8); ip += 8;
	memcpy(&min_run,       ip, 4); ip += 4;
	memcpy(&max_cells,     ip, 4); ip += 4;
	memcpy(&subj_n,        ip, 4); ip += 4;
	memcpy(&cand_n,        ip, 4); ip += 4;
	memcpy(&with_steps,    ip, 4); ip += 4;

	(void)bbox_pad_deg;   /* bbox runs in PP, value unused here */

	/* one-time allocation. max_pts conservatively bounded by max_cells
	 * (worst case both tracks equal sqrt(max_cells) in length); but we
	 * cap at 16384 just to bound memory.  At DTW_MAX_CELLS=4M sqrt=2000;
	 * raw point counts can be larger before decimation, so use a safe
	 * ceiling that exceeds any plausible track length. */
	int max_pts = (int)sqrt((double)max_cells) * 4;
	if (max_pts < 8192)  max_pts = 8192;
	if (max_pts > 32768) max_pts = 32768;
	ensure_init(max_cells, max_pts);

	/* Defensive guard: refuse to overflow the static raw buffers.  At
	 * Patrick's current data scale (~5000 pts max) and the default
	 * DTW_MAX_CELLS = 4M (yielding max_pts = 8192) this is unreachable.
	 * If it ever fires, raise DTW_MAX_CELLS in navMatch.pm and the
	 * derived max_pts grows with it. */
	if (subj_n > max_pts || cand_n > max_pts)
	{
		Inline_Stack_Reset;
		Inline_Stack_Push(sv_2mortal(make_empty_result()));
		Inline_Stack_Done;
		return;
	}

	/* read points (raw, undecimated) into the static buffers */
	{
		int i;
		for (i = 0; i < subj_n; i++)
		{
			memcpy(&g_raw_subj_lat[i], ip, 8); ip += 8;
			memcpy(&g_raw_subj_lon[i], ip, 8); ip += 8;
		}
		for (i = 0; i < cand_n; i++)
		{
			memcpy(&g_raw_cand_lat[i], ip, 8); ip += 8;
			memcpy(&g_raw_cand_lon[i], ip, 8); ip += 8;
		}
	}

	/*
	 * ----- Stage 1: exact pass on RAW points -----
	 */
	int ex_i_start, ex_i_end, ex_j_start, ex_j_end, ex_length, ex_mode;
	int got_exact = exact_pass(g_raw_subj_lat, g_raw_subj_lon, subj_n,
	                            g_raw_cand_lat, g_raw_cand_lon, cand_n,
	                            exact_deg, shift_mag, shift_tol, min_run,
	                            &ex_i_start, &ex_i_end,
	                            &ex_j_start, &ex_j_end,
	                            &ex_length,  &ex_mode);

	if (got_exact)
	{
		/* --- classify_exact (port of _classifyExact) --- */
		int subj_before = ex_i_start;
		int subj_in     = ex_i_end - ex_i_start + 1;
		int subj_after  = subj_n - 1 - ex_i_end;
		int cand_before = ex_j_start;
		int cand_in     = ex_j_end - ex_j_start + 1;
		int cand_after  = cand_n - 1 - ex_j_end;
		int s_out = subj_before + subj_after;
		int c_out = cand_before + cand_after;

		int shape;
		if      (s_out == 0 && c_out == 0) shape = SHAPE_FULL;
		else if (s_out == 0)               shape = SHAPE_SUBSET;
		else if (c_out == 0)               shape = SHAPE_SUPERSET;
		else                               shape = SHAPE_ANOMALY;

		double subj_cov = (subj_n > 0) ? ((double)subj_in / (double)subj_n) : 0.0;
		double cand_cov = (cand_n > 0) ? ((double)cand_in / (double)cand_n) : 0.0;

		char buf[HEADER_BYTES];
		memset(buf, 0, HEADER_BYTES);
		char *p = buf;
		write_int(&p, TIER_EXACT);
		write_int(&p, shape);
		write_int(&p, ex_mode);
		write_dbl(&p, 0.0);          /* quality undef for exact */
		write_dbl(&p, subj_cov);
		write_dbl(&p, cand_cov);
		write_int(&p, ex_i_start);
		write_int(&p, ex_i_end);
		write_int(&p, ex_j_start);
		write_int(&p, ex_j_end);
		write_int(&p, subj_before);
		write_int(&p, subj_in);
		write_int(&p, subj_after);
		write_int(&p, cand_before);
		write_int(&p, cand_in);
		write_int(&p, cand_after);
		write_int(&p, 0);            /* no steps on exact */

		Inline_Stack_Reset;
		Inline_Stack_Push(sv_2mortal(newSVpvn(buf, HEADER_BYTES)));
		Inline_Stack_Done;
		return;
	}

	/*
	 * ----- Stage 2: DTW fallback on DECIMATED points -----
	 */
	int nd = decimate_bobbing(g_raw_subj_lat, g_raw_subj_lon, subj_n,
	                           bobbing_deg,
	                           g_dec_subj_lat, g_dec_subj_lon, g_dec_subj_idx);
	int md = decimate_bobbing(g_raw_cand_lat, g_raw_cand_lon, cand_n,
	                           bobbing_deg,
	                           g_dec_cand_lat, g_dec_cand_lon, g_dec_cand_idx);

	if (nd < 2 || md < 2 || (double)nd * (double)md > (double)max_cells)
	{
		Inline_Stack_Reset;
		Inline_Stack_Push(sv_2mortal(make_empty_result()));
		Inline_Stack_Done;
		return;
	}

	subsequence_dtw(g_dec_subj_lat, g_dec_subj_lon, nd,
	                g_dec_cand_lat, g_dec_cand_lon, md,
	                exact_deg, dtw_prune_deg, seg_prune_deg, step_penalty);

	/* Select best end cell from last row + last column.  PP walks each
	 * candidate end cell, ranks by `covered - avg_cost * 1e6`, and keeps
	 * the best.  Same logic here. */
	int    best_n = 0;
	double best_rank = -INF;
	int    best_i_start = 0, best_j_start = 0;
	int    best_i_end   = 0, best_j_end   = 0;
	double best_total = 0.0, best_max = 0.0;

	int j;
	for (j = 0; j < md; j++)
	{
		int idx = (nd - 1) * md + j;
		if (g_D[idx] >= INF) continue;

		double total, max_step;
		int    i_start, j_start;
		int n_steps = walkback_dtw(nd - 1, j, md,
		                            &total, &max_step, &i_start, &j_start);
		if (n_steps < 2) continue;

		int subj_span = (nd - 1) - i_start + 1;
		int cand_span = j - j_start + 1;
		int covered   = subj_span + cand_span;
		double avg    = total / (double)n_steps;
		double rank   = (double)covered - avg * 1.0e6;

		if (rank > best_rank)
		{
			best_rank = rank;
			best_n    = n_steps;
			best_i_start = i_start;
			best_j_start = j_start;
			best_i_end   = nd - 1;
			best_j_end   = j;
			best_total   = total;
			best_max     = max_step;
			memcpy(g_best_step_i,    g_step_i,    sizeof(int)    * n_steps);
			memcpy(g_best_step_j,    g_step_j,    sizeof(int)    * n_steps);
			memcpy(g_best_step_tb,   g_step_tb,   sizeof(int)    * n_steps);
			memcpy(g_best_step_cost, g_step_cost, sizeof(double) * n_steps);
		}
	}

	int i;
	for (i = 0; i < nd - 1; i++)
	{
		int idx = i * md + (md - 1);
		if (g_D[idx] >= INF) continue;

		double total, max_step;
		int    i_start, j_start;
		int n_steps = walkback_dtw(i, md - 1, md,
		                            &total, &max_step, &i_start, &j_start);
		if (n_steps < 2) continue;

		int subj_span = i - i_start + 1;
		int cand_span = (md - 1) - j_start + 1;
		int covered   = subj_span + cand_span;
		double avg    = total / (double)n_steps;
		double rank   = (double)covered - avg * 1.0e6;

		if (rank > best_rank)
		{
			best_rank = rank;
			best_n    = n_steps;
			best_i_start = i_start;
			best_j_start = j_start;
			best_i_end   = i;
			best_j_end   = md - 1;
			best_total   = total;
			best_max     = max_step;
			memcpy(g_best_step_i,    g_step_i,    sizeof(int)    * n_steps);
			memcpy(g_best_step_j,    g_step_j,    sizeof(int)    * n_steps);
			memcpy(g_best_step_tb,   g_step_tb,   sizeof(int)    * n_steps);
			memcpy(g_best_step_cost, g_step_cost, sizeof(double) * n_steps);
		}
	}
	(void)best_total; (void)best_max;

	if (best_n < 2)
	{
		Inline_Stack_Reset;
		Inline_Stack_Push(sv_2mortal(make_empty_result()));
		Inline_Stack_Done;
		return;
	}

	/*
	 * ----- classify_dtw (port of _classifyDTW) -----
	 */
	int L = best_n;

	/* median step cost.  Sort a COPY of the cost array so we keep the
	 * original per-step costs in path order for the steps-output pass
	 * below.  Reuse g_step_cost as scratch (it's free at this point --
	 * walkback_dtw is done). */
	memcpy(g_step_cost, g_best_step_cost, sizeof(double) * L);
	qsort(g_step_cost, L, sizeof(double), cmp_double_asc);
	double median_step = g_step_cost[L / 2];
	int tier = (median_step <= exact_deg) ? TIER_MATCH : TIER_NEAR;

	/* quality = fraction of sub-meter cells */
	int sub_meter = 0;
	int k;
	for (k = 0; k < L; k++)
	{
		if (g_best_step_cost[k] <= exact_deg) sub_meter++;
	}
	double quality = (L > 0) ? ((double)sub_meter / (double)L) : 0.0;

	/* Map decimated indices back to original index space */
	int orig_i_start = g_dec_subj_idx[best_i_start];
	int orig_i_end   = g_dec_subj_idx[best_i_end];
	int orig_j_start = g_dec_cand_idx[best_j_start];
	int orig_j_end   = g_dec_cand_idx[best_j_end];

	int subj_before = orig_i_start;
	int subj_in     = orig_i_end - orig_i_start + 1;
	int subj_after  = subj_n - 1 - orig_i_end;
	int cand_before = orig_j_start;
	int cand_in     = orig_j_end - orig_j_start + 1;
	int cand_after  = cand_n - 1 - orig_j_end;
	int s_out = subj_before + subj_after;
	int c_out = cand_before + cand_after;

	int small_subj = (s_out <= 5) || ((double)s_out <= 0.05 * (double)subj_n);
	int small_cand = (c_out <= 5) || ((double)c_out <= 0.05 * (double)cand_n);

	int shape;
	if      (s_out == 0 && c_out == 0)    shape = SHAPE_FULL;
	else if (small_subj && small_cand)    shape = SHAPE_TRIMMED;
	else if (small_subj && !small_cand)   shape = SHAPE_SUBSET;
	else if (!small_subj && small_cand)   shape = SHAPE_SUPERSET;
	else                                  shape = SHAPE_PARTIAL;

	double subj_cov = (subj_n > 0) ? ((double)subj_in / (double)subj_n) : 0.0;
	double cand_cov = (cand_n > 0) ? ((double)cand_in / (double)cand_n) : 0.0;

	/* Steps output -- reverse to start-to-end order, map to original idx. */
	int out_steps_n = with_steps ? L : 0;

	int out_total_bytes = HEADER_BYTES + out_steps_n * STEP_BYTES;
	char *out_buf = (char *)malloc(out_total_bytes);
	memset(out_buf, 0, out_total_bytes);
	char *op = out_buf;

	write_int(&op, tier);
	write_int(&op, shape);
	write_int(&op, MODE_UNDEF);          /* no mode for DTW tier */
	write_dbl(&op, quality);
	write_dbl(&op, subj_cov);
	write_dbl(&op, cand_cov);
	write_int(&op, orig_i_start);
	write_int(&op, orig_i_end);
	write_int(&op, orig_j_start);
	write_int(&op, orig_j_end);
	write_int(&op, subj_before);
	write_int(&op, subj_in);
	write_int(&op, subj_after);
	write_int(&op, cand_before);
	write_int(&op, cand_in);
	write_int(&op, cand_after);
	write_int(&op, out_steps_n);

	if (with_steps)
	{
		/* Walkback recorded steps end-to-start; we want start-to-end.
		 * Iterate in reverse and translate decimated indices.  But the
		 * cost array has been SORTED for median calculation -- we no
		 * longer have per-step costs in path order.  Re-derive costs
		 * from g_D / g_TB by re-walking the path.
		 *
		 * Simpler fix: snapshot g_best_step_cost ORIGINALS before the
		 * sort.  Re-walk avoids that complexity, but means another pass
		 * over the alignment.  Choosing snapshot for clarity. */

		/* By construction, the unsorted costs are no longer in g_best_step_cost
		 * (we sorted it).  But g_best_step_i / j / tb still hold the path
		 * positions.  We re-derive per-step costs from the D-grid. */

		/* steps recorded end -> start; reverse on emit */
		int k;
		for (k = L - 1; k >= 0; k--)
		{
			int  di = g_best_step_i[k];
			int  dj = g_best_step_j[k];
			int  tb = g_best_step_tb[k];
			int  idx = di * md + dj;
			double cell_cost;
			if (tb == TB_START)      cell_cost = g_D[idx];
			else if (tb == TB_DIAG)  cell_cost = g_D[idx] - g_D[idx - md - 1];
			else if (tb == TB_VERT)  cell_cost = g_D[idx] - g_D[idx - md];
			else                     cell_cost = g_D[idx] - g_D[idx - 1];
			if (cell_cost < 0.0) cell_cost = 0.0;

			write_int(&op, g_dec_subj_idx[di]);
			write_int(&op, g_dec_cand_idx[dj]);
			write_int(&op, tb);
			write_dbl(&op, cell_cost);
		}
	}

	SV *out_sv = newSVpvn(out_buf, out_total_bytes);
	free(out_buf);

	Inline_Stack_Reset;
	Inline_Stack_Push(sv_2mortal(out_sv));
	Inline_Stack_Done;
}

__END_C__

#========================================================================
# Perl side
#========================================================================

# Build an empty-result hash matching PP's _empty_result.  Kept local so
# this module does not have to reach into navMatch's private subs.
sub _empty_result_pp_compat
{
	return {
		tier           => 'none',
		shape          => undef,
		quality        => undef,
		subj_coverage  => 0,
		cand_coverage  => 0,
		matched_window => undef,
		counts         => undef,
	};
}

# Decode tables -- mirror the C-side integer codes.
my @TIER_CODE  = ('none', 'exact', 'match', 'near');
my @SHAPE_CODE = (undef, 'full', 'subset', 'superset',
                  'trimmed', 'partial', 'anomaly');
my @MODE_CODE  = (undef, 'noshift', 'latshift');

# Pack header for a call.  Pulls constant values from navMatch via its
# `use constant` accessor subs -- single source of truth.
sub _pack_header
{
	my ($subj_n, $cand_n, $with_steps) = @_;
	return pack('d8 l5',
		navMatch::EXACT_DEG(),
		navMatch::BBOX_PAD_DEG(),
		navMatch::DTW_PRUNE_DEG(),
		navMatch::DTW_SEG_PRUNE_DEG(),
		navMatch::STEP_PENALTY(),
		navMatch::BOBBING_DEG(),
		navMatch::LAT_SHIFT_DEG(),
		navMatch::SHIFT_TOLERANCE_DEG(),
		navMatch::EXACT_MIN_RUN(),
		navMatch::DTW_MAX_CELLS(),
		$subj_n,
		$cand_n,
		$with_steps ? 1 : 0,
	);
}

# Pack one track's points (lat,lon interleaved as doubles).
sub _pack_points
{
	my ($pts) = @_;
	my @flat;
	for my $pt (@$pts)
	{
		push @flat, ($pt->{lat} // 0), ($pt->{lon} // 0);
	}
	return pack('d*', @flat);
}

# Unpack output buffer into the same hash shape scoreLineStringPair returns.
sub _unpack_result
{
	my ($buf) = @_;

	# Header is 80 bytes: 14 ints + 3 doubles.  pack/unpack template
	# 'l3 d3 l4 l6 l' totals 14 + 3 in the right order.
	my @h = unpack('l3 d3 l4 l6 l', $buf);
	my ($tier_code, $shape_code, $mode_code,
	    $quality, $subj_cov, $cand_cov,
	    $win_ss, $win_se, $win_cs, $win_ce,
	    $sb, $sin, $sa, $cb, $cin, $ca,
	    $steps_n) = @h;

	my $tier  = $TIER_CODE [$tier_code  // 0] // 'none';
	my $shape = $SHAPE_CODE[$shape_code // 0];
	my $mode  = $MODE_CODE [$mode_code  // 0];

	if ($tier eq 'none')
	{
		return {
			tier           => 'none',
			shape          => undef,
			quality        => undef,
			subj_coverage  => 0,
			cand_coverage  => 0,
			matched_window => undef,
			counts         => undef,
		};
	}

	my $result =
	{
		tier           => $tier,
		shape          => $shape,
		subj_coverage  => $subj_cov,
		cand_coverage  => $cand_cov,
		matched_window => [$win_ss, $win_se, $win_cs, $win_ce],
		counts         =>
		{
			subj_before   => $sb,
			subj_in_match => $sin,
			subj_after    => $sa,
			cand_before   => $cb,
			cand_in_match => $cin,
			cand_after    => $ca,
		},
	};

	if ($tier eq 'exact')
	{
		$result->{quality} = undef;
		$result->{mode}    = $mode;
	}
	else
	{
		$result->{quality} = $quality;
	}

	if ($steps_n > 0)
	{
		my @steps;
		my $off = 80;
		for (my $k = 0; $k < $steps_n; $k++)
		{
			my ($si, $cj, $tb, $cost) = unpack('l3 d', substr($buf, $off, 20));
			push @steps,
			{
				subj_idx => $si,
				cand_idx => $cj,
				tb       => $tb,
				cost     => $cost,
			};
			$off += 20;
		}
		$result->{steps} = \@steps;
	}

	return $result;
}


# Public entry point.  Same signature and contract as
# navMatch::scoreLineStringPair(), with optional %opts:
#   with_steps => 0|1  (default 1 -- include DTW path on match/near tiers)
sub compareLineStringPair_c
{
	my ($subj_pts, $cand_pts, %opts) = @_;
	my $with_steps = exists($opts{with_steps}) ? $opts{with_steps} : 1;

	# Apply the same preconditions PP applies up-front.
	return _empty_result_pp_compat()
		if !$subj_pts || !@$subj_pts;
	return _empty_result_pp_compat()
		if !$cand_pts || !@$cand_pts;

	my $n = scalar @$subj_pts;
	my $m = scalar @$cand_pts;
	return _empty_result_pp_compat() if $n < 2 || $m < 2;

	# Bbox prefilter runs in PP -- cheap, no marshaling cost, matches
	# the existing reject behavior exactly.
	my $sb = navMatch::bboxOfPoints($subj_pts);
	my $cb = navMatch::bboxOfPoints($cand_pts);
	return _empty_result_pp_compat()
		if !navMatch::bboxOverlaps($sb, $cb);

	my $hdr  = _pack_header($n, $m, $with_steps);
	my $sbuf = _pack_points($subj_pts);
	my $cbuf = _pack_points($cand_pts);

	my $packed = $hdr . $sbuf . $cbuf;

	if ($dbg_navmc >= 0)
	{
		display($dbg_navmc, 0,
			"navMatchC compare n=$n m=$m with_steps=$with_steps "
			. "packed_in=" . length($packed) . " bytes");
	}

	my $out_buf = score_pair_xs($packed);
	return _unpack_result($out_buf);
}


1;
