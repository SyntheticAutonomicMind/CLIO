#!/usr/bin/perl
# Test: ReadLine cursor positioning math
# Covers _cursor_at_codepoint — the single source of truth for cursor
# position. Every cursor movement, redraw, and reposition computes from
# this pure function, never from incrementally-tracked shadow state.
#
# Test cases (20-col terminal, 2-char prompt "> "):
#   - Cursor at codepoint 0 in empty input
#   - Cursor at various codepoint offsets in ASCII input
#   - Cursor at wrap boundaries (autowrap positions)
#   - Cursor at start/end of multi-row input
#   - Wide character (CJK) positioning (the bug _pos_to_rowcol had)
#   - Off-by-one regression at position 5
#   - ANSI-colored prompt (visible width 2, ANSI bytes invisible)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use lib '../../lib';

# Force a known terminal width so we can reason about positions.
BEGIN {
    no warnings 'redefine';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (20, 24); };
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

# --- _cursor_at_codepoint tests ---
# Prompt "> " = 2 visible columns. On a 20-col terminal, the prompt
# occupies columns 1-2. Cursor starts at column 3.
#
# _cursor_at_codepoint(input, cp, prompt) walks codepoints 0..cp-1
# and returns the (row, col) where the cursor sits BEFORE codepoint cp.

# Empty input, cursor at 0: position after prompt = (0, 3)
rows_equal($rl->_cursor_at_codepoint("", 0, '> '), 0, 3, "empty input, cp=0 -> (0,3) after 2-col prompt");

# Single char, cursor at 0: position before 'a' = (0, 3)
rows_equal($rl->_cursor_at_codepoint("a", 0, '> '), 0, 3, "cp=0 in 'a' -> (0,3) before first char");

# Single char, cursor at 1: position after 'a' = (0, 4)
rows_equal($rl->_cursor_at_codepoint("a", 1, '> '), 0, 4, "cp=1 in 'a' -> (0,4) after first char");

# Fill the first row: 20 cols, 2-char prompt, so 18 input chars fill the row.
# Cursor at cp=17 (before 18th char): col = 3 + 17 = 20 (last col)
rows_equal($rl->_cursor_at_codepoint("a" x 18, 17, '> '), 0, 20, "cp=17 in 18-char input -> (0,20) last col of row 0");

# Cursor at cp=18 (after all 18 chars): the 18th char lands at col=20,
# then autowraps the cursor to (row=1, col=1). Cursor before char 19
# therefore sits at (1, 1).
rows_equal($rl->_cursor_at_codepoint("a" x 18, 18, '> '), 1, 1, "cp=18 in 18-char input -> (1,1) after wrap");

# Cursor at cp=19 (before 19th char): char 19 lands on row 1 col 1,
# cursor advances to (1, 2). End of input.
rows_equal($rl->_cursor_at_codepoint("a" x 19, 19, '> '), 1, 2, "cp=19 in 19-char input -> (1,2) end of input");

# Cursor at cp=0 in 19-char input: at start of row 0
rows_equal($rl->_cursor_at_codepoint("a" x 19, 0, '> '), 0, 3, "cp=0 in 19-char input -> (0,3) at start");

# --- Wrap boundary tests ---
# 20-col terminal, 2-char prompt. 18 chars fill row 0 (cols 3-20).
# 36 chars fill row 0 + row 1.

# Cursor at cp=36 (after 36 chars = 2 full rows): 18 chars on row 0
# (last at col=20), 18 chars on row 1 (last at col=18). Cursor at (1, 19).
rows_equal($rl->_cursor_at_codepoint("a" x 36, 36, '> '), 1, 19, "cp=36 in 36-char input -> (1,19) after row 1 fills");

# Cursor at cp=37 (before 37th char): char 37 lands on row 1 col 19,
# cursor advances to (1, 20).
rows_equal($rl->_cursor_at_codepoint("a" x 37, 37, '> '), 1, 20, "cp=37 in 37-char input -> (1,20) before next wrap");

# Cursor at cp=38 (after char 37, which autowraps): cursor at (2, 1).
rows_equal($rl->_cursor_at_codepoint("a" x 38, 38, '> '), 2, 1, "cp=38 in 38-char input -> (2,1) after second wrap");

# --- Regression: off-by-one at position 5 ---
# Input "hello world test" (16 chars), prompt "> " (2 cols).
# Cursor at cp=5: prompt(2) + "hello"(5) = 7 display cols.
# col = prompt_disp + 1 + display_width("hello") = 3 + 5 = 8.
my ($r, $c) = $rl->_cursor_at_codepoint("hello world test", 5, '> ');
rows_equal($r, $c, 0, 8, "regression: cp=5 in 'hello world test' -> (0,8) (off-by-one bug was col=7)");

# Cursor at end of "hello world test" (cp=16): col = 3 + 16 = 19
($r, $c) = $rl->_cursor_at_codepoint("hello world test", 16, '> ');
rows_equal($r, $c, 0, 19, "regression: cp=16 (end of 16-char input) -> (0,19)");

# Cursor at cp=16 in 18-char input (pending wrap): col = 3 + 16 = 19. Not 20.
($r, $c) = $rl->_cursor_at_codepoint("a" x 18, 16, '> ');
rows_equal($r, $c, 0, 19, "cp=16 in 18-char input -> (0,19) before last char");

# Cursor at cp=18 in 18-char input: 18 chars placed, last at col=20.
# Autowrap moves cursor to (1, 1).
($r, $c) = $rl->_cursor_at_codepoint("a" x 18, 18, '> ');
rows_equal($r, $c, 1, 1, "cp=18 in 18-char input -> (1,1) after wrap");

# --- Wide character positioning ---
# _pos_to_rowcol used arithmetic division which doesn't account for
# wide characters. _cursor_at_codepoint walks each char individually.
#
# Input "a你b" (1+2+1=4 display cols), prompt "> " (2 cols).
# Total display = 6. On 20-col terminal, all on row 0.
# Cursor at cp=0: col = 2+1 = 3 (before 'a')
rows_equal($rl->_cursor_at_codepoint("a\x{4F60}b", 0, '> '), 0, 3, "CJK: cp=0 in 'a你b' -> (0,3) before 'a'");
# Cursor at cp=1: after 'a', before '你'. col = 3+1 = 4.
($r, $c) = $rl->_cursor_at_codepoint("a\x{4F60}b", 1, '> ');
rows_equal($r, $c, 0, 4, "CJK: cp=1 in 'a你b' -> (0,4) after 'a' before '你'");
# Cursor at cp=2: after '你'. col = 3+1+2 = 6.
($r, $c) = $rl->_cursor_at_codepoint("a\x{4F60}b", 2, '> ');
rows_equal($r, $c, 0, 6, "CJK: cp=2 in 'a你b' -> (0,6) after '你' before 'b'");
# Cursor at cp=3: after 'b'. col = 3+1+2+1 = 7.
($r, $c) = $rl->_cursor_at_codepoint("a\x{4F60}b", 3, '> ');
rows_equal($r, $c, 0, 7, "CJK: cp=3 in 'a你b' -> (0,7) after 'b'");

# Wide char at wrap boundary:
# Input: 17 'a's + '你' (2 cols) = 19 display cols. Prompt 2 = 21 total.
# On 20-col terminal: row 0 = 18 cols (prompt 2 + 16 'a's), row 1 = 3 cols (2 'a's + '你').
# Cursor at cp=17 (before '你', after 17 'a's):
#   col after 17 'a's = 3+17 = 20. Cursor sits at last col of row 0.
($r, $c) = $rl->_cursor_at_codepoint(("a" x 17) . "\x{4F60}", 17, '> ');
rows_equal($r, $c, 0, 20, "CJK at boundary: cp=17 before '你' -> (0,20) at last col");
# Cursor at cp=18 (after '你', wraps to row 1):
#   After 17 'a's: col=20. i=17 places '你' (w=2): col+w-1=21>20, wrap to (1,1).
#   col += w = 3. col > 20? No. Cursor at (1, 3).
($r, $c) = $rl->_cursor_at_codepoint(("a" x 17) . "\x{4F60}", 18, '> ');
rows_equal($r, $c, 1, 3, "CJK at boundary: cp=18 after '你' -> (1,3)");

# --- ANSI-colored prompt ---
# Prompt is "\e[36m>\e[0m " = visible "> " (2 cols), ANSI bytes invisible.
my $ansi_prompt = "\e[36m>\e[0m ";
# _get_prompt_disp strips ANSI and returns 2.
ok($rl->_get_prompt_disp($ansi_prompt), 2, "ANSI prompt: visible width is 2 (ANSI bytes stripped)");
# Cursor at cp=0 in empty input: col = 2+1 = 3.
($r, $c) = $rl->_cursor_at_codepoint("", 0, $ansi_prompt);
rows_equal($r, $c, 0, 3, "ANSI prompt: cp=0 in empty input -> (0,3)");
# Cursor at cp=5 in "hello": col = 2+1+5 = 8.
($r, $c) = $rl->_cursor_at_codepoint("hello", 5, $ansi_prompt);
rows_equal($r, $c, 0, 8, "ANSI prompt: cp=5 in 'hello' -> (0,8)");

# --- Cursor at start of multi-row input ---
# 19 chars on 20-col terminal (2-col prompt): 2+19=21, wraps.
# Row 0: 18 chars (cols 3-20). Row 1: 1 char (col 2).
# Cursor at cp=0: (0, 3)
rows_equal($rl->_cursor_at_codepoint("a" x 19, 0, '> '), 0, 3, "multi-row: cp=0 -> (0,3) at start");
# Cursor at cp=18: 18 chars placed, last at col=20. Autowrap to (1, 1).
($r, $c) = $rl->_cursor_at_codepoint("a" x 19, 18, '> ');
rows_equal($r, $c, 1, 1, "multi-row: cp=18 -> (1,1) start of row 1");
# Cursor at cp=19: char 19 lands at row 1 col 1, cursor at (1, 2).
($r, $c) = $rl->_cursor_at_codepoint("a" x 19, 19, '> ');
rows_equal($r, $c, 1, 2, "multi-row: cp=19 -> (1,2) end of input");

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);
