#!/usr/bin/perl
# Regression test: scroll_offset is derived from content, never accumulates.
# Verifies that scroll_offset is correctly 0 when input shrinks below
# the terminal height, and that it does not retain stale values.
#
# Also verifies that SIGWINCH invalidates BOTH width and height caches.

use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    no warnings 'redefine', 'prototype';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (20, 5) };
    *CLIO::Compat::Terminal::ReadMode = sub { return 1 };
}

use CLIO::Core::ReadLine;

my ($cols, $rows) = (20, 5);
my $prompt = '> ';
my $max_row = $rows - 1;

# --- Test 1: scroll_offset is derived, not accumulated ---
# Terminal: 20 cols x 5 rows. Prompt: "> " (2 cols).
# Type 100 chars (display_lines=6, scroll_offset should be 1).
# Then shrink to 80 chars (display_lines=5, scroll_offset should be 0).
{
    my $input = 'a' x 100;
    my $rl = CLIO::Core::ReadLine->new(prompt => $prompt);
    $rl->{scroll_offset} = 0;

    # Simulate typing 100 chars via _emit_text (as the insert fast-path does)
    $rl->{last_cursor_row} = 0;
    $rl->{last_cursor_col} = 3;
    for my $i (0..99) {
        $rl->_emit_text('a');
    }
    # After 100 chars, _emit_text does NOT update scroll_offset anymore.
    # But the insert fast-path in readline() would call _refresh_geometry
    # or compute scroll_offset from _compute_display_lines.
    # Let's simulate that:
    my $dl_100 = $rl->_compute_display_lines(2 + 100);
    $rl->{scroll_offset} = _max(0, $dl_100 - $rl->_get_term_height());

    is($rl->{scroll_offset}, 1,
       "after 100 chars: scroll_offset=1 (6 rows - 5 terminal rows)");

    # Now shrink to 80 chars and recompute scroll_offset
    $input = 'a' x 80;
    my $dl_80 = $rl->_compute_display_lines(2 + 80);
    $rl->{scroll_offset} = _max(0, $dl_80 - $rl->_get_term_height());

    is($rl->{scroll_offset}, 0,
       "after shrink to 80 chars: scroll_offset=0 (5 rows = 5 terminal rows)");

    # Verify _refresh_geometry also computes correct scroll_offset
    my $rl2 = CLIO::Core::ReadLine->new(prompt => $prompt);
    $rl2->{scroll_offset} = 5;  # Deliberately stale
    $input = 'a' x 80;
    $rl2->_refresh_geometry($input, 80, $prompt);
    is($rl2->{scroll_offset}, 0,
       "_refresh_geometry: scroll_offset=0 for 80 chars (stale 5 overwritten)");

    # Now 100 chars via _refresh_geometry
    $input = 'a' x 100;
    $rl2->_refresh_geometry($input, 100, $prompt);
    is($rl2->{scroll_offset}, 1,
       "_refresh_geometry: scroll_offset=1 for 100 chars");
}

# --- Test 2: _input_row_to_screen_row with no overflow ---
# 80 chars on 5-row terminal: 5 rows, no overflow, scroll_offset=0.
# Cursor at end: input_row=4, screen_row should be 4.
{
    my $input = 'a' x 80;
    my $rl = CLIO::Core::ReadLine->new(prompt => $prompt);
    $rl->_refresh_geometry($input, 80, $prompt);

    my ($input_row, $col) = $rl->_cursor_at_codepoint($input, 80, $prompt);
    my $screen_row = $rl->_input_row_to_screen_row($input_row);

    is($input_row, 4, "80 chars: cursor input_row=4");
    is($screen_row, 4, "80 chars: screen_row=4 (no overflow, scroll_offset=0)");
}

# --- Test 3: _input_row_to_screen_row with overflow ---
# 100 chars on 5-row terminal: 6 rows, scroll_offset=1.
# Cursor at end: input_row=5, screen_row should be 4 (5-1).
{
    my $input = 'a' x 100;
    my $rl = CLIO::Core::ReadLine->new(prompt => $prompt);
    $rl->_refresh_geometry($input, 100, $prompt);

    my ($input_row, $col) = $rl->_cursor_at_codepoint($input, 100, $prompt);
    my $screen_row = $rl->_input_row_to_screen_row($input_row);

    is($input_row, 5, "100 chars: cursor input_row=5");
    is($screen_row, 4, "100 chars: screen_row=4 (1 row scrolled, 5-1=4)");
}

# --- Test 4: SIGWINCH invalidates both caches ---
{
    my $rl = CLIO::Core::ReadLine->new(prompt => '> ');
    $rl->{_term_size_cache} = [80, 24];
    $rl->{_term_size_time} = time();

    ok(defined($rl->{_term_size_cache}), "before SIGWINCH: size cache populated");

    $rl->_invalidate_term_size();
    ok(!defined($rl->{_term_size_cache}), "after _invalidate_term_size: cache cleared");
    is($rl->{_term_size_time}, 0, "after _invalidate_term_size: time reset");

    # Verify both width and height are refreshed
    my ($w, $h) = $rl->_refresh_term_size();
    is($w, 20, "after refresh: width=20 (stubbed)");
    is($h, 5, "after refresh: height=5 (stubbed)");
}

done_testing();

sub _max { $_[0] > $_[1] ? $_[0] : $_[1] }
