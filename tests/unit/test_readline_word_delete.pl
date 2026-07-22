#!/usr/bin/perl
# Test: ReadLine word-delete helpers
# Covers:
#   - _kill_word_backward (Ctrl+W, Alt+Backspace, Shift+Delete)
#   - _kill_word_forward (Alt+D, Ctrl+Delete)
#   - Behavior on edge cases (start of line, end of line, whitespace runs)
#
# Behavior matches GNU readline's unix-word-rubout (Ctrl+W) and
# kill-word (Alt+D): both directions consume trailing/leading whitespace
# first, then walk back/forward through word characters.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use lib '../../lib';

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
    if (defined $got && $got eq $expected) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label (got=" . (defined $got ? "'$got'" : 'undef') . ", expected='$expected')\n";
        $fail++;
    }
}

sub ok_int {
    my ($got, $expected, $label) = @_;
    if (defined $got && $got == $expected) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label (got=" . (defined $got ? $got : 'undef') . ", expected=$expected)\n";
        $fail++;
    }
}

# Stub redraw_line / reposition_cursor so we don't actually emit escape codes.
no warnings 'redefine';
*CLIO::Core::ReadLine::redraw_line = sub { return; };
*CLIO::Core::ReadLine::reposition_cursor = sub { return; };
use warnings;

# --- _kill_word_backward tests ---

# Empty input - no-op
{
    my $input = '';
    my $cursor_pos = 0;
    $rl->_kill_word_backward(\$input, \$cursor_pos, '> ');
    ok($input, '', 'backward: empty input unchanged');
    ok_int($cursor_pos, 0, 'backward: empty input cursor unchanged');
}

# Cursor at start - no-op
{
    my $input = 'hello world';
    my $cursor_pos = 0;
    $rl->_kill_word_backward(\$input, \$cursor_pos, '> ');
    ok($input, 'hello world', 'backward: at start unchanged');
    ok_int($cursor_pos, 0, 'backward: at start cursor unchanged');
}

# Mid-word: "hello wo|rld" -> "hello rld" (deletes "wo", preserves space)
{
    my $input = 'hello world';
    my $cursor_pos = 8;
    $rl->_kill_word_backward(\$input, \$cursor_pos, '> ');
    ok($input, 'hello rld', 'backward: mid-word removes preceding chars to word start');
    ok_int($cursor_pos, 6, 'backward: cursor lands after preceding space');
}

# At end of input: "hello world|" -> "hello " (deletes "world")
{
    my $input = 'hello world';
    my $cursor_pos = 11;
    $rl->_kill_word_backward(\$input, \$cursor_pos, '> ');
    ok($input, 'hello ', 'backward: at end removes last word');
    ok_int($cursor_pos, 6, 'backward: cursor at start of whitespace');
}

# Trailing whitespace: "hello world |" -> "hello " (deletes trailing space first)
{
    my $input = 'hello world ';
    my $cursor_pos = 12;
    $rl->_kill_word_backward(\$input, \$cursor_pos, '> ');
    ok($input, 'hello ', 'backward: trailing space removed first');
    ok_int($cursor_pos, 6, 'backward: cursor at start of whitespace run');
}

# --- _kill_word_forward tests ---

# Empty input - no-op
{
    my $input = '';
    my $cursor_pos = 0;
    $rl->_kill_word_forward(\$input, \$cursor_pos, '> ');
    ok($input, '', 'forward: empty input unchanged');
    ok_int($cursor_pos, 0, 'forward: empty input cursor unchanged');
}

# Cursor at end - no-op
{
    my $input = 'hello world';
    my $cursor_pos = 11;
    $rl->_kill_word_forward(\$input, \$cursor_pos, '> ');
    ok($input, 'hello world', 'forward: at end unchanged');
    ok_int($cursor_pos, 11, 'forward: at end cursor unchanged');
}

# Mid-word: "hel|lo world" -> "hel world"
{
    my $input = 'hello world';
    my $cursor_pos = 3;
    $rl->_kill_word_forward(\$input, \$cursor_pos, '> ');
    ok($input, 'hel world', 'forward: mid-word removes rest of word');
    ok_int($cursor_pos, 3, 'forward: mid-word cursor unchanged');
}

# At word boundary: "hello| world" -> "hello"
{
    my $input = 'hello world';
    my $cursor_pos = 5;
    $rl->_kill_word_forward(\$input, \$cursor_pos, '> ');
    ok($input, 'hello', 'forward: at word boundary removes whitespace + next word');
    ok_int($cursor_pos, 5, 'forward: cursor unchanged');
}

# Leading whitespace: "|   hello world" -> "" (consumes all)
{
    my $input = '   hello world';
    my $cursor_pos = 0;
    $rl->_kill_word_forward(\$input, \$cursor_pos, '> ');
    ok($input, ' world', 'forward: leading whitespace + first word consumed, trailing space remains');
    ok_int($cursor_pos, 0, 'forward: cursor unchanged');
}

# --- Unicode word delete ---

# CJK is treated as part of the word (not whitespace), so Ctrl+W on the
# ASCII word preceding CJK should delete that ASCII word.
{
    my $input = 'hello 你好 world';
    my $cursor_pos = 12;  # after "world"
    $rl->_kill_word_backward(\$input, \$cursor_pos, '> ');
    ok($input, 'hello 你好 ld', 'backward: prior 3 chars of trailing word removed, CJK preserved');
    ok_int($cursor_pos, 9, 'backward: cursor lands before last remaining word fragment');
}

# Shift+Delete semantics: same as Ctrl+W.
{
    my $input = 'hello world';
    my $cursor_pos = 11;
    $rl->_kill_word_backward(\$input, \$cursor_pos, '> ');
    ok($input, 'hello ', 'Shift+Delete: same as Ctrl+W (kills previous word)');
    ok_int($cursor_pos, 6, 'Shift+Delete: cursor at whitespace run start');
}

# Ctrl+Delete semantics: same as Alt+D.
{
    my $input = 'hello world';
    my $cursor_pos = 5;  # at end of 'hello'
    $rl->_kill_word_forward(\$input, \$cursor_pos, '> ');
    ok($input, 'hello', 'Ctrl+Delete: same as Alt+D (kills next word)');
    ok_int($cursor_pos, 5, 'Ctrl+Delete: cursor unchanged');
}

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);