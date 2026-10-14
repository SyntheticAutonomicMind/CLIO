#!/usr/bin/perl
# Regression test for the base_cursor_row / scroll_offset bug.
#
# Bug: After the DSR fix (20261013.1), _query_cursor_pos correctly
# reports base_cursor_row (the terminal row where the prompt starts).
# But scroll_offset was computed as max(0, display_lines - term_height),
# which ignores base_cursor_row. The available vertical space below the
# prompt is (term_height - base_cursor_row), not term_height.
#
# When base_cursor_row > 0 and the input wraps, scroll_offset was
# incorrectly 0. This caused _input_row_to_screen_row to clamp two
# different input rows to the same screen row. In reposition_cursor,
# this made the left-arrow at a line-wrap boundary use RELATIVE
# horizontal movement (move right to end of current line) instead of
# moving UP to the end of the previous line.
#
# The fix: scroll_offset = max(0, display_lines - (term_height - base_cursor_row))

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    no warnings 'redefine', 'prototype';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (20, 24) };
    *CLIO::Compat::Terminal::ReadMode        = sub { return 1 };
}

use CLIO::Core::ReadLine;
use Test::More;

# Helper: capture stdout from a code reference.
sub capture_stdout {
    my ($code) = @_;
    pipe(my $read_end, my $write_end) or die "pipe: $!";
    my $old_fh = select($write_end);
    $| = 1;
    $code->();
    select($old_fh);
    close $write_end;
    my $buf = '';
    while (1) {
        my $chunk = '';
        my $n = sysread($read_end, $chunk, 4096);
        last unless defined $n && $n > 0;
        $buf .= $chunk;
    }
    close $read_end;
    return $buf;
}

# ============================================================
# Unit: _compute_scroll_offset accounts for base_cursor_row
# ============================================================

{
    my $rl = CLIO::Core::ReadLine->new(prompt => '> ');
    $rl->{_term_size_cache} = [20, 24];
    $rl->{_term_size_time} = time();

    # base_cursor_row = 0: available = 24 (unchanged from old formula)
    $rl->{base_cursor_row} = 0;
    is($rl->_compute_scroll_offset(2), 0, "scroll_offset: base=0, 2 lines -> 0 (unchanged)");
    is($rl->_compute_scroll_offset(24), 0, "scroll_offset: base=0, 24 lines -> 0");
    is($rl->_compute_scroll_offset(25), 1, "scroll_offset: base=0, 25 lines -> 1");

    # base_cursor_row = 23: available = 1. 2 lines -> 1 scroll.
    $rl->{base_cursor_row} = 23;
    is($rl->_compute_scroll_offset(2), 1, "scroll_offset: base=23, 2 lines -> 1 (was 0 with old formula)");

    # base_cursor_row = 22: available = 2.
    $rl->{base_cursor_row} = 22;
    is($rl->_compute_scroll_offset(2), 0, "scroll_offset: base=22, 2 lines -> 0 (exact fit)");
    is($rl->_compute_scroll_offset(3), 1, "scroll_offset: base=22, 3 lines -> 1");

    # base_cursor_row = 10: available = 14.
    $rl->{base_cursor_row} = 10;
    is($rl->_compute_scroll_offset(10), 0, "scroll_offset: base=10, 10 lines -> 0");
    is($rl->_compute_scroll_offset(14), 0, "scroll_offset: base=10, 14 lines -> 0 (exact fit)");
    is($rl->_compute_scroll_offset(15), 1, "scroll_offset: base=10, 15 lines -> 1");
    is($rl->_compute_scroll_offset(27), 13, "scroll_offset: base=10, 27 lines -> 13");
}

# ============================================================
# Unit: _input_row_to_screen_row with base_cursor_row > 0
# ============================================================

{
    my $rl = CLIO::Core::ReadLine->new(prompt => '> ');
    $rl->{_term_size_cache} = [20, 24];
    $rl->{_term_size_time} = time();

    # base_cursor_row = 23, 2 display lines, scroll_offset = 1.
    $rl->{base_cursor_row} = 23;
    $rl->{scroll_offset} = 1;

    is($rl->_input_row_to_screen_row(0), 22,
       "screen_row: base=23, scroll=1, input_row 0 -> 22");
    is($rl->_input_row_to_screen_row(1), 23,
       "screen_row: base=23, scroll=1, input_row 1 -> 23");

    ok($rl->_input_row_to_screen_row(0) != $rl->_input_row_to_screen_row(1),
       "screen_row: input rows 0 and 1 map to different screen rows (bug was same row)");
}

# ============================================================
# Unit: _refresh_geometry sets correct scroll_offset
# ============================================================

{
    my $rl = CLIO::Core::ReadLine->new(prompt => '> ');
    $rl->{_term_size_cache} = [20, 24];
    $rl->{_term_size_time} = time();
    $rl->{base_cursor_row} = 23;

    # 19 chars + 2-char prompt = 21 display cols -> 2 display lines.
    # Available = 24 - 23 = 1. scroll_offset = 2 - 1 = 1.
    $rl->_refresh_geometry('a' x 19, 19, '> ');
    is($rl->{scroll_offset}, 1, "refresh_geometry: base=23, 19 chars -> scroll_offset=1 (was 0)");
    is($rl->{display_lines}, 2, "refresh_geometry: base=23, 19 chars -> display_lines=2");
}

# ============================================================
# Integration: reposition_cursor emits cursor-up at wrap boundary
# ============================================================
#
# With base_cursor_row = 23 (prompt at last terminal row) and 18 chars
# (fills the line exactly, cursor wraps to line 2), moving the cursor
# backward across the wrap boundary should emit cursor-UP (\e[NA).
#
# Without the fix: scroll_offset = 0, both input rows map to screen row
# 23, and reposition_cursor uses relative horizontal movement instead.

sub setup_rl {
    my ($base_row) = @_;
    my $rl = CLIO::Core::ReadLine->new(prompt => '> ');
    $rl->{_term_size_cache} = [20, 24];
    $rl->{_term_size_time} = time();
    $rl->{base_cursor_row} = $base_row;
    # Simulate cursor at beginning of line 2 after typing 18 chars.
    my $input = 'a' x 18;
    $rl->_refresh_geometry($input, 18, '> ');
    my ($ir, $ic) = $rl->_cursor_at_codepoint($input, 18, '> ');
    $rl->{last_cursor_row} = $rl->_input_row_to_screen_row($ir);
    $rl->{last_cursor_col} = $ic;
    $rl->{last_cursor_input_row} = $ir;
    return $rl;
}

# Test: base_cursor_row = 23, left arrow from pos 18 to 17 (cross boundary)
{
    my $rl = setup_rl(23);
    my $input = 'a' x 18;
    my $old = 18;
    my $new = 17;

    my $bytes = capture_stdout(sub {
        $rl->reposition_cursor(\$old, \$new, \$input, '> ');
    });

    ok($bytes =~ /\e\[\d+A/,
       "reposition: base=23, left at wrap boundary emits cursor-up");
    ok($bytes =~ /\e\[1A/,
       "reposition: base=23, left moves up exactly 1 row");
}

# Test: base_cursor_row = 0, left arrow from pos 18 to 17 (cross boundary)
{
    my $rl = setup_rl(0);
    my $input = 'a' x 18;
    my $old = 18;
    my $new = 17;

    my $bytes = capture_stdout(sub {
        $rl->reposition_cursor(\$old, \$new, \$input, '> ');
    });

    ok($bytes =~ /\e\[\d+A/,
       "reposition: base=0, left at wrap boundary emits cursor-up");
    ok($bytes =~ /\e\[1A/,
       "reposition: base=0, left moves up exactly 1 row");
}

# Test: same-row left arrow does NOT emit cursor-up (pos 19 -> 18)
{
    my $rl = setup_rl(23);
    my $input = 'a' x 19;
    my $old = 19;
    my $new = 18;
    my ($ir, $ic) = $rl->_cursor_at_codepoint($input, 19, '> ');
    $rl->{last_cursor_row} = $rl->_input_row_to_screen_row($ir);
    $rl->{last_cursor_col} = $ic;
    $rl->{last_cursor_input_row} = $ir;

    my $bytes = capture_stdout(sub {
        $rl->reposition_cursor(\$old, \$new, \$input, '> ');
    });

    ok($bytes !~ /\e\[\d+A/,
       "reposition: same-row left arrow (pos 19->18) does NOT emit cursor-up (correct)");
}

# ============================================================
# Regression: verify old formula would have failed
# ============================================================

{
    my $rl = CLIO::Core::ReadLine->new(prompt => '> ');
    $rl->{_term_size_cache} = [20, 24];
    $rl->{_term_size_time} = time();
    $rl->{base_cursor_row} = 23;
    $rl->_refresh_geometry('a' x 18, 18, '> ');

    is($rl->{scroll_offset}, 1,
       "regression: base=23 with 18 chars (1 pending-wrap line) -> scroll_offset=1 (old formula: 0)");

    my $row0 = $rl->_input_row_to_screen_row(0);
    my $row1 = $rl->_input_row_to_screen_row(1);
    ok($row0 != $row1,
       "regression: input rows 0 ($row0) and 1 ($row1) are on different screen rows");
}

done_testing();
