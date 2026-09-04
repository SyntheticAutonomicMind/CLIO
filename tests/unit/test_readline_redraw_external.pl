#!/usr/bin/perl
# Regression test for ReadLine::_redraw_line_external.
#
# _redraw_line_external is called when external output (e.g., broker
# events) has been printed above the input line and the readline needs
# to redraw the prompt + input below it. It emits \r\e[J then re-emits
# the prompt + input.
#
# This test exercises _redraw_line_external through a virtual
# terminal and verifies the rendered output matches
# _cursor_at_codepoint positions. The pre-existing code emits
# \r\e[J followed by _emit_text calls; both _emit_text and the
# trailing cursor-position logic must agree with the terminal.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    no warnings 'redefine';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (20, 24) };
}

use CLIO::Core::ReadLine;

my ($pass, $fail) = (0, 0);

sub ok {
    my ($cond, $label) = @_;
    $label //= '(no label)';
    if ($cond) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label\n";
        $fail++;
    }
}

# Capture STDOUT into a scalar for inspection.
sub capture_stdout {
    my ($code) = @_;
    my $captured = '';
    open my $fh, '>', \$captured or die "open to scalar: $!";
    my $old = select($fh);
    $| = 1;
    eval { $code->() };
    select($old);
    close $fh;
    return ($captured, $@);
}

# Minimal virtual terminal: tracks (row, col) as escape sequences are
# processed, and prints to a 2-D buffer. Handles CR, LF, ESC[CUDLRHJ,
# ESC[J, and printable chars. pending-wrap semantics: a printable char
# at the last column sets pending=1; the next char wraps.
package VirtualTerminal;
sub new {
    my ($class, %opts) = @_;
    return bless {
        cols => $opts{cols} || 20,
        rows => $opts{rows} || 24,
        row => 0, col => 0, buffer => [], pending => 0,
    }, $class;
}
sub feed {
    my ($self, $bytes) = @_;
    my $i = 0;
    while ($i < length($bytes)) {
        my $ch = substr($bytes, $i, 1);
        if ($ch eq "\e") {
            if (substr($bytes, $i + 1, 1) eq '[') {
                my $j = $i + 2;
                $j++ while $j < length($bytes) && substr($bytes, $j, 1) =~ /[\d;?]/;
                my $param = substr($bytes, $i + 2, $j - $i - 2);
                my $cmd = substr($bytes, $j, 1);
                if ($cmd eq 'C') {
                    my $n = ($param eq '' ? 1 : $param) + 0; $n = 1 if $n == 0;
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{col} += $n;
                    $self->{col} = $self->{cols} - 1 if $self->{col} >= $self->{cols};
                } elsif ($cmd eq 'D') {
                    my $n = ($param eq '' ? 1 : $param) + 0; $n = 1 if $n == 0;
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{col} -= $n;
                    $self->{col} = 0 if $self->{col} < 0;
                } elsif ($cmd eq 'A') {
                    my $n = ($param eq '' ? 1 : $param) + 0; $n = 1 if $n == 0;
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{row} -= $n;
                    $self->{row} = 0 if $self->{row} < 0;
                } elsif ($cmd eq 'B') {
                    my $n = ($param eq '' ? 1 : $param) + 0; $n = 1 if $n == 0;
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{row} += $n;
                } elsif ($cmd eq 'J') {
                    for my $r ($self->{row} .. $self->{rows} - 1) {
                        my $start = ($r == $self->{row}) ? $self->{col} : 0;
                        for my $c ($start .. $self->{cols} - 1) {
                            delete $self->{buffer}[$r][$c];
                        }
                    }
                } elsif ($cmd eq 'H') {
                    $self->{row} = 0; $self->{col} = 0; $self->{pending} = 0;
                }
                $i = $j + 1;
            } else { $i++; }
        } elsif ($ch eq "\r") {
            $self->{col} = 0; $self->{pending} = 0; $i++;
        } elsif ($ch eq "\n") {
            $self->{row}++; $i++;
        } else {
            if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
            $self->{buffer}[$self->{row}][$self->{col}] = $ch;
            $self->{col}++;
            if ($self->{col} >= $self->{cols}) { $self->{pending} = 1 }
            $i++;
        }
    }
}
sub render {
    my ($self) = @_;
    my @lines;
    for my $r (0 .. $self->{rows} - 1) {
        my $line = '';
        for my $c (0 .. $self->{cols} - 1) {
            $line .= $self->{buffer}[$r][$c] // ' ';
        }
        push @lines, $line;
    }
    return join("\n", @lines);
}

package main;

# Test 1: cursor_pos=3 (middle of "hello"), simple input. After
# _redraw_line_external the prompt + input should be rendered with
# the cursor at (0, 5) (between 'l' and 'l').
{
    my $rl = CLIO::Core::ReadLine->new(prompt => '> ');
    $rl->{last_cursor_col} = 7;  # pre-existing stale tracking

    my $input = 'hello';
    my $cursor_pos = 3;
    my ($bytes, $eval_err) = capture_stdout(sub {
        $rl->_redraw_line_external('> ', \$input, \$cursor_pos);
    });

    ok(!$eval_err, "test1: _redraw_line_external ran without error");

    my $vt = VirtualTerminal->new(cols => 20, rows => 24);
    $vt->feed($bytes);

    my $rendered = $vt->render;
    my @lines = split /\n/, $rendered;

    ok($lines[0] =~ /^> hel/, "test1: prompt + first 4 chars rendered correctly");

    # Verify final cursor position by emitting one more char and
    # checking it lands at col 5 (0-indexed = col 6 1-indexed) where
    # the cursor sits between the two 'l's. Inserting 'X' there
    # overwrites the second 'l': "hello" -> "helXo".
    $vt->feed("X");
    my @lines2 = split /\n/, $vt->render;
    my $cond1 = ($lines2[0] =~ /^> helXo/);
    ok($cond1, "test1: X placed at cursor (between the two l's), overwrites second l");
}

# Test 2: ANSI-colored prompt. _emit_text strips ANSI from tracking
# while still printing them. Same shape as test1 but with the
# PromptBuilder-style prompt that includes SGR sequences.
{
    my $rl = CLIO::Core::ReadLine->new(prompt => '> ');
    $rl->{last_cursor_col} = 5;  # pre-existing stale tracking

    my $ansi_prompt = "\e[36m> \e[0m";  # cyan "> "
    my $input = 'abc';
    my $cursor_pos = 1;
    my ($bytes, $eval_err) = capture_stdout(sub {
        $rl->_redraw_line_external($ansi_prompt, \$input, \$cursor_pos);
    });

    ok(!$eval_err, "test2: ANSI prompt _redraw_line_external ran");

    my $vt = VirtualTerminal->new(cols => 20, rows => 24);
    $vt->feed($bytes);

    my @lines = split /\n/, $vt->render;
    ok($lines[0] =~ /^> a/, "test2: ANSI prompt + 'a' visible at start of row 0");

    # Cursor should be at (0, 4) - after prompt (2 visible cols) + 'a' (1 col).
    $vt->feed("X");
    my @lines2 = split /\n/, $vt->render;
    my $cond2 = ($lines2[0] =~ /^> aX/);
    ok($cond2, "test2: X inserted at col 4 (after prompt + 'a')");
}

# Test 3: input that wraps. prompt "> " (2 cols), input "a" x 22.
# Cursor at end of input sits at (1, 3) (after the 22 chars wrap).
{
    my $rl = CLIO::Core::ReadLine->new(prompt => '> ');
    $rl->{last_cursor_col} = 19;

    my $input = 'a' x 22;
    my $cursor_pos = 22;
    my ($bytes, $eval_err) = capture_stdout(sub {
        $rl->_redraw_line_external('> ', \$input, \$cursor_pos);
    });

    ok(!$eval_err, "test3: wrap case _redraw_line_external ran");

    my $vt = VirtualTerminal->new(cols => 20, rows => 24);
    $vt->feed($bytes);

    my $rendered = $vt->render;
    my @lines = split /\n/, $rendered;

    # 20-col terminal: prompt takes cols 0-1, "a" x 18 fills cols 2-19.
    # Then 4 more a's wrap to row 1 cols 0-3 (col 4 = position after 4th 'a').
    ok($lines[0] =~ /^> a{18}$/, "test3: row 0 has prompt + 18 a's");
    ok($lines[1] =~ /^aaaa/, "test3: row 1 has 4 wrapped a's");

    # Cursor should be at end of input - col 5 (0-indexed) of row 1.
    # Emitting X overwrites the 5th col of row 1: "aaaa" -> "aaaaX".
    $vt->feed("X");
    my @lines2 = split /\n/, $vt->render;
    my $cond3 = ($lines2[1] =~ /^aaaaX/);
    ok($cond3, "test3: X placed at cursor (col 4 of row 1), overwrites that position");
}

print "\n--- $pass passed, $fail failed ---\n";
exit($fail ? 1 : 0);