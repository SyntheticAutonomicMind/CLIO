#!/usr/bin/perl
# Test: ReadLine cursor positioning math
# Covers:
#   - _pos_to_rowcol pending-wrap handling
#   - Off-by-one bug that caused cursor to drift right after typing in middle
#   - End-of-row / wrapped cursor positioning

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use lib '../../lib';

# Force a known terminal width so we can reason about positions.
BEGIN {
    no warnings 'redefine';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (80, 24); };
}

use CLIO::Core::ReadLine;
my $rl = CLIO::Core::ReadLine->new(prompt => '> ');

my ($pass, $fail) = (0, 0);

sub ok {
    my ($got, $expected, $label) = @_;
    if (defined $got && $got == $expected) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label (got=" . (defined $got ? $got : 'undef') . ", expected=$expected)\n";
        $fail++;
    }
}

sub rows_equal {
    my ($got_r, $got_c, $exp_r, $exp_c, $label) = @_;
    if ($got_r == $exp_r && $got_c == $exp_c) {
        print "PASS: $label (row=$got_r col=$got_c)\n";
        $pass++;
    } else {
        print "FAIL: $label (got row=$got_r col=$got_c, expected row=$exp_r col=$exp_c)\n";
        $fail++;
    }
}

# --- _pos_to_rowcol tests ---
# Pos 0 -> row 0, col 1 (after \r)
rows_equal($rl->_pos_to_rowcol(0),  0, 1, "pos=0 -> row=0 col=1");

# Pos 1 -> row 0, col 2
rows_equal($rl->_pos_to_rowcol(1),  0, 2, "pos=1 -> row=0 col=2");

# Pos 79 -> row 0, col 80
rows_equal($rl->_pos_to_rowcol(79), 0, 80, "pos=79 -> row=0 col=80");

# Pos 80 -> PENDING WRAP -> row 0 col 80 (NOT row 1 col 1)
rows_equal($rl->_pos_to_rowcol(80), 0, 80, "pos=80 -> row=0 col=80 (pending wrap)");

# Pos 81 -> row 1 col 2
rows_equal($rl->_pos_to_rowcol(81), 1, 2, "pos=81 -> row=1 col=2");

# Pos 159 -> row 1 col 80
rows_equal($rl->_pos_to_rowcol(159), 1, 80, "pos=159 -> row=1 col=80");

# Pos 160 -> PENDING WRAP at row 1
rows_equal($rl->_pos_to_rowcol(160), 1, 80, "pos=160 -> row=1 col=80 (pending wrap)");

# Pos 161 -> row 2 col 2
rows_equal($rl->_pos_to_rowcol(161), 2, 2, "pos=161 -> row=2 col=2");

# --- Regression: cursor at codepoint position 5 in "helloX world test" ---
# Prompt "> " = 2 cols. input[0..5] = "hello" = 5 cols. total = 7.
# Expected: row=0, col=8 (1-indexed). The bug was col=7 (off by 1).
my ($r, $c) = $rl->_pos_to_rowcol(7);
rows_equal($r, $c, 0, 8, "regression: cursor at input[0..5] -> row=0 col=8 (off-by-one bug)");

# --- Regression: cursor at end of single line (pos=15, "hello world test" 15 chars) ---
# pos = 2 + 15 = 17
($r, $c) = $rl->_pos_to_rowcol(17);
rows_equal($r, $c, 0, 18, "regression: cursor at end of 'hello world test' -> col=18");

# --- Regression: cursor at row boundary (78 chars input) ---
# pos = 2 + 78 = 80 (pending wrap, cursor should be at row 0 col 80)
($r, $c) = $rl->_pos_to_rowcol(80);
rows_equal($r, $c, 0, 80, "regression: 78-char input ends at pending-wrap boundary col=80");

# --- Regression: cursor at row 1 start (81-char input) ---
# pos = 2 + 79 = 81 -> row 1 col 2 (after prompt chars on row 0)
($r, $c) = $rl->_pos_to_rowcol(81);
rows_equal($r, $c, 1, 2, "regression: 79-char input -> row 1 col 2");

# --- Regression: cursor at exact wrap boundary mid-input (input[0..78] of 79-char input) ---
# pos = 2 + 78 = 80 -> pending wrap at row 0 col 80
($r, $c) = $rl->_pos_to_rowcol(80);
rows_equal($r, $c, 0, 80, "regression: cursor at position 78 in 79-char input -> pending-wrap col=80");

# --- Simulate the original bug scenario ---
# User typed "hello world this is a test" (26 chars).
# Cursor moves to position 16 (between "this" and " is").
# Insert 'X' -> input becomes "hello world this Xis a test" (27 chars).
# The new char advances terminal cursor 1 col, then _redraw_from_cursor
# prints the tail (11 chars) so terminal cursor is at end-of-input (col 29).
# The desired cursor position is codepoint 17 -> display pos 19
# (prompt=2, "hello world this X" = 17 cols).
# _pos_to_rowcol(19) should give row=0, col=20.
($r, $c) = $rl->_pos_to_rowcol(19);
rows_equal($r, $c, 0, 20, "regression: insert 'X' at pos 16 -> target col=20 (was off-by-one =19)");

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);