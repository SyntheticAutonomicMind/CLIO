#!/usr/bin/perl
# Regression test: off-by-one cursor after wrap, then word movement.
#
# User scenario (regression): paste text that wraps to a second row,
# shift-left until cursor sits on the first row, shift-right to return
# to the second row. Cursor landed one column past where it should have
# been, and every subsequent cursor movement was off by one.
#
# Root cause: _cursor_at_codepoint and _emit_text modeled autowrap as
# "wrap first, then place the char". That miscounted columns: after the
# wrap the cursor was reported at col=2 of the new row when the terminal
# actually had it at col=1. Every position computed past the first
# wrap carried a +1 column error.
#
# This test reproduces the user's exact flow with a virtual terminal
# that tracks cursor position from the actual ANSI bytes CLIO emits.
# Before the fix the test failed with cursor positions off by one on
# every step; after the fix the VT cursor matches _cursor_at_codepoint
# at every step.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    no warnings 'redefine', 'prototype';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (50, 24) };
    *CLIO::Compat::Terminal::ReadMode = sub { return 1 };
}

package VirtualTerminal;
sub new {
    my ($class, %opts) = @_;
    return bless {
        cols => $opts{cols} || 50,
        rows => $opts{rows} || 24,
        row => 0, col => 0,
        buffer => [], pending => 0,
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
                my @parts = split /;/, $param;
                my $n = (@parts && $parts[0] ne '' ? $parts[0] : 1) + 0;
                if ($cmd eq 'C') {
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{col} += $n;
                    $self->{col} = $self->{cols} - 1 if $self->{col} >= $self->{cols};
                } elsif ($cmd eq 'D') {
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{col} -= $n;
                    $self->{col} = 0 if $self->{col} < 0;
                } elsif ($cmd eq 'A') {
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{row} -= $n;
                    $self->{row} = 0 if $self->{row} < 0;
                } elsif ($cmd eq 'B') {
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{row} += $n;
                }
                $i = $j + 1;
            } else {
                $i += 2;
            }
        } elsif ($ch eq "\r") {
            $self->{col} = 0; $self->{pending} = 0; $i++;
        } elsif ($ch eq "\n") {
            $self->{row}++; $i++;
        } elsif ($ch eq "\b") {
            if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
            $self->{col}--;
            $self->{col} = 0 if $self->{col} < 0; $i++;
        } else {
            if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
            $self->{buffer}[$self->{row}][$self->{col}] = $ch;
            $self->{col}++;
            if ($self->{col} >= $self->{cols}) {
                $self->{pending} = 1;
            }
            $i++;
        }
    }
}

sub cursor { my $s = shift; return ($s->{row}, $s->{col}) }

package main;

use Test::More;
use CLIO::Core::ReadLine;

# 48 chars on row 0, 27 chars on row 1. Matches the user's scenario
# (paste text that goes past the edge of the line, then continues).
my $input  = "When you paste text that goes past the edge of t";
$input .= "he line and continues below";

die "Wrong length: " . length($input) unless length($input) == 75;

my $prompt = '> ';

sub capture {
    my ($code) = @_;
    pipe(my $r, my $w) or die "pipe: $!";
    my $old = select($w); $| = 1;
    $code->();
    select($old);
    close $w;
    my $buf = '';
    local $/;
    $buf = <$r>;
    close $r;
    return $buf;
}

sub emit_all {
    my ($rl, $vt) = @_;
    my $buf = capture(sub {
        $rl->_emit_text($prompt);
        $rl->_emit_text($input);
    });
    $vt->feed($buf);
}

sub do_reposition {
    my ($rl, $vt, $from_cp, $to_cp) = @_;
    my $buf = capture(sub {
        $rl->reposition_cursor(\($from_cp), \($to_cp), \$input, $prompt);
    });
    $vt->feed($buf);
}

sub pos_for_cp {
    my ($cp) = @_;
    my $rl = CLIO::Core::ReadLine->new(prompt => $prompt);
    return $rl->_cursor_at_codepoint($input, $cp, $prompt);
}

sub check_vt {
    my ($vt, $cp, $label) = @_;
    my ($vr, $vc) = $vt->cursor();
    my ($er, $ec) = pos_for_cp($cp);
    my $vt_col_1idx = $vc + 1;
    is($vr, $er, "$label: VT row matches _cursor_at_codepoint (got $vr, expected $er)");
    is($vt_col_1idx, $ec, "$label: VT col matches _cursor_at_codepoint (got $vt_col_1idx, expected $ec)");
}

# Pure layout oracle: walks the input with the terminal's autowrap
# semantics (NOT CLIO's) and returns (row, col) 0-indexed / 1-indexed.
# This catches the class of bug where CLIO's tracking and the actual
# terminal agree on a wrong shared model.
sub oracle_position {
    my ($cp) = @_;
    my $term_width = 50;
    # prompt "> " is 2 visible cols (ASCII). Compute by summing per-char.
    my $prompt_disp = 0;
    for my $i (0 .. length($prompt) - 1) {
        $prompt_disp += _display_width_(substr($prompt, $i, 1));
    }
    my $row = 0;
    my $col = $prompt_disp + 1;
    for my $i (0 .. $cp - 1) {
        my $w = _display_width_(substr($input, $i, 1));
        if ($col + $w - 1 > $term_width) {
            $row++;
            $col = 1;
        }
        $col += $w;
        if ($col > $term_width) {
            $row++;
            $col = 1;
        }
    }
    return ($row, $col);
}

sub _display_width_ {
    my ($ch) = @_;
    return 0 if length($ch) == 0;
    my $o = ord($ch);
    return 2 if $o >= 0x1100 &&
                 ($o <= 0x115F ||
                  ($o >= 0x2E80 && $o <= 0x9FFF) ||
                  ($o >= 0xAC00 && $o <= 0xD7A3) ||
                  ($o >= 0xFF00 && $o <= 0xFF60));
    return 1;
}

# Inlined word-move logic that mirrors CLIO::Core::ReadLine::move_word_*
# but reports the cp delta via return values so we can drive the
# virtual terminal through reposition_cursor for each step.
sub step_back {
    my ($rl, $vt, $cp) = @_;
    my $old_cp = $cp;
    $cp--;
    if (substr($input, $cp, 1) =~ /\s/) {
        while ($cp > 0 && substr($input, $cp, 1) =~ /\s/) { $cp-- }
    }
    while ($cp > 0 && substr($input, $cp - 1, 1) !~ /\s/) { $cp-- }
    do_reposition($rl, $vt, $old_cp, $cp);
    return $cp;
}

sub step_fwd {
    my ($rl, $vt, $cp) = @_;
    my $old_cp = $cp;
    my $len = length($input);
    if (substr($input, $cp, 1) =~ /\s/) {
        while ($cp < $len && substr($input, $cp, 1) =~ /\s/) { $cp++ }
    }
    while ($cp < $len && substr($input, $cp, 1) !~ /\s/) { $cp++ }
    do_reposition($rl, $vt, $old_cp, $cp);
    return $cp;
}

# The full flow: paste, then walk back to row 0, then walk forward.
{
    my $rl = CLIO::Core::ReadLine->new(prompt => $prompt);
    my $vt = VirtualTerminal->new(cols => 50, rows => 24);
    emit_all($rl, $vt);

    my $cp = length($input);
    check_vt($vt, $cp, "initial: cursor at end of pasted input");
    {
        my ($vr, $vc) = $vt->cursor();
        my ($or, $oc) = oracle_position($cp);
        is($vr, $or, "initial cp=$cp: VT row matches terminal layout oracle (got $vr, expected $or)");
        is($vc + 1, $oc, "initial cp=$cp: VT col matches terminal layout oracle (got " . ($vc + 1) . ", expected $oc)");
    }

    # Walk back word by word until we're on row 0.
    while (1) {
        my ($cur_r,) = pos_for_cp($cp);
        last if $cur_r == 0;
        last if $cp == 0;
        $cp = step_back($rl, $vt, $cp);
        check_vt($vt, $cp, "shift+left: cp=$cp");
        my ($vr, $vc) = $vt->cursor();
        my ($or, $oc) = oracle_position($cp);
        is($vr, $or, "shift+left cp=$cp: VT row matches terminal layout oracle (got $vr, expected $or)");
        is($vc + 1, $oc, "shift+left cp=$cp: VT col matches terminal layout oracle (got " . ($vc + 1) . ", expected $oc)");
    }

    # Walk forward word by word until we cross back into row 1+.
    for my $step (1..6) {
        last if $cp >= length($input);
        my $old_cp = $cp;
        $cp = step_fwd($rl, $vt, $cp);
        last if $cp == $old_cp;
        check_vt($vt, $cp, "shift+right: cp=$cp (step $step)");
        my ($vr, $vc) = $vt->cursor();
        my ($or, $oc) = oracle_position($cp);
        is($vr, $or, "shift+right cp=$cp: VT row matches terminal layout oracle (got $vr, expected $or)");
        is($vc + 1, $oc, "shift+right cp=$cp: VT col matches terminal layout oracle (got " . ($vc + 1) . ", expected $oc)");
        last if $cp == length($input);
    }
}

done_testing();