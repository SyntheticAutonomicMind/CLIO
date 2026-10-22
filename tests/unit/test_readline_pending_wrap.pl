#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Regression test for pending-wrap cursor positioning bug.
#
# The bug: when the cursor is at the last column of a row (pending-wrap state)
# — which happens after typing the char that fills the last column — and the
# user navigates with arrow keys, the CR path in reposition_cursor emits
# ESC[nA/ESC[nB which resolves pending on some terminals (Terminal.app,
# Linux console), wrapping the cursor to the wrong row.
#
# CR does NOT clear pending on these terminals; only character output does.
# This test creates a VT state with pending active (by typing an input
# whose total display width is an exact multiple of term_width) and then
# navigates, verifying the VT cursor position matches the model at every step.
#
# VT models:
#   VTxterm  — CR does NOT clear pending, ESC does NOT resolve pending (xterm).
#   VTLinux  — CR does NOT clear pending, ESC DOES resolve pending (Linux console,
#              macOS Terminal.app). This is the model that exposes the bug.
#   VTCrClears — CR clears pending, ESC does NOT resolve pending.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use CLIO::Core::ReadLine;

my $cols = 80;
my $prompt = '>' . (' ' x 36);  # 37 chars

# Build 123-char input: 37 + 123 = 160 = exactly 2 full rows.
# The last char is at col 80 (1-indexed) of row 1, creating a pending state.
my $input = '';
for my $i (0 .. 122) {
    $input .= chr(ord('a') + ($i % 26));
}
die "Input should be 123 chars" unless length($input) == 123;

my $rl = CLIO::Core::ReadLine->new(prompt => $prompt);
$rl->{_term_size_cache} = [$cols, 24];
$rl->{_term_size_time} = time();
$rl->{_prompt_disp_cache} = length($prompt);

# model_pos: returns (row, col_0indexed, pending) for a given cp.
# Uses the actual pending flag from _cursor_at_codepoint, not a col-based
# heuristic, because col==term_width can occur with pending=0 (when the
# last placed char exactly fills the last column without wrapping).
sub model_pos {
    my ($cp) = @_;
    my ($row, $col, $pending) = $rl->_cursor_at_codepoint($input, $cp, $prompt);
    # col is 1-indexed from _cursor_at_codepoint; convert to 0-indexed.
    return ($row, $col - 1, $pending);  # 0-indexed row, 0-indexed col, pending
}

# ---- VT Base class ----
package VTBase;
sub new {
    my ($class, %opts) = @_;
    return bless {
        cols   => $opts{cols} || 80,
        rows   => $opts{rows} || 24,
        row    => 0,
        col    => 0,
        buffer => [],
        pending => 0,
    }, $class;
}
sub cursor { my $s = shift; return ($s->{row}, $s->{col}, $s->{pending}) }
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
                $i = $j + 1;
               next if $param =~ /\?/;
                if ($cmd eq 'H' || $cmd eq 'f') {
                    my @p = split /;/, $param;
                    my $hrow = ($p[0] eq '' ? 1 : $p[0]) + 0;
                    my $hcol = ($p[1] eq '' ? 1 : $p[1]) + 0;
                    $self->_csi_H($hrow, $hcol);
                } else {
                    my $n = ($param eq '' ? 1 : $param) + 0;
                    $n = 1 if $n == 0;
                    $self->_csi($cmd, $n);
                }
            } else {
                $i++;
            }
        } elsif ($ch eq "\r") {
            $self->_cr();
            $i++;
        } elsif ($ch eq "\n") {
            $self->_lf();
            $i++;
        } elsif ($ch eq "\b") {
            $self->_bs();
            $i++;
        } else {
            $self->_char($ch);
            $i++;
        }
    }
}

# VT Model A (true xterm): CR does NOT clear pending, ESC does NOT resolve pending
package VTxterm;
our @ISA = qw(VTBase);
sub _cr   { my $s = shift; $s->{col} = 0; }
sub _lf   { my $s = shift; $s->{pending} = 0; $s->{row}++; $s->{col} = 0 }
sub _bs   { my $s = shift; $s->{col}--; $s->{col} = 0 if $s->{col} < 0 }
sub _char {
    my ($s, $ch) = @_;
    if ($s->{pending}) { $s->{row}++; $s->{col} = 0; $s->{pending} = 0 }
    $s->{buffer}[$s->{row}][$s->{col}] = $ch;
    $s->{col}++;
    if ($s->{col} >= $s->{cols}) { $s->{pending} = 1; $s->{col} = $s->{cols} - 1; }
}
sub _csi { my ($s,$cmd,$n) = @_; if ($cmd eq 'C') { $s->{col}+=$n; $s->{col}=$s->{cols}-1 if $s->{col}>=$s->{cols} } elsif ($cmd eq 'D') { $s->{col}-=$n; $s->{col}=0 if $s->{col}<0 } elsif ($cmd eq 'A') { $s->{row}-=$n; $s->{row}=0 if $s->{row}<0 } elsif ($cmd eq 'B') { $s->{row}+=$n } elsif ($cmd eq 'K') { for (my $c=$s->{col};$c<$s->{cols};$c++){delete $s->{buffer}[$s->{row}][$c]} } }
sub _csi_H {
    my ($s, $row, $col) = @_;
    $s->{row} = $row - 1;
    $s->{col} = $col - 1;
}

# VT Model B (Linux console / Terminal.app): CR does NOT clear pending, ESC DOES resolve pending
package VTLinux;
our @ISA = qw(VTBase);
sub _cr   { my $s = shift; $s->{col} = 0; }
sub _lf   { my $s = shift; $s->{pending} = 0; $s->{row}++; $s->{col} = 0 }
sub _bs   {
    my $s = shift;
    if ($s->{pending}) { $s->{row}++; $s->{col} = 0; $s->{pending} = 0 }
    $s->{col}--; $s->{col} = 0 if $s->{col} < 0;
}
sub _char {
    my ($s, $ch) = @_;
    if ($s->{pending}) { $s->{row}++; $s->{col} = 0; $s->{pending} = 0 }
    $s->{buffer}[$s->{row}][$s->{col}] = $ch;
    $s->{col}++;
    if ($s->{col} >= $s->{cols}) { $s->{pending} = 1; $s->{col} = $s->{cols} - 1; }
}
sub _csi {
    my ($s,$cmd,$n) = @_;
    if ($s->{pending}) { $s->{row}++; $s->{col} = 0; $s->{pending} = 0 }
    if ($cmd eq 'C') { $s->{col}+=$n; $s->{col}=$s->{cols}-1 if $s->{col}>=$s->{cols} }
    elsif ($cmd eq 'D') { $s->{col}-=$n; $s->{col}=0 if $s->{col}<0 }
    elsif ($cmd eq 'A') { $s->{row}-=$n; $s->{row}=0 if $s->{row}<0 }
    elsif ($cmd eq 'B') { $s->{row}+=$n }
    elsif ($cmd eq 'K') { for (my $c=$s->{col};$c<$s->{cols};$c++){delete $s->{buffer}[$s->{row}][$c]} }
}
sub _csi_H {
    my ($s, $row, $col) = @_;
    # VTLinux: ESC resolves pending before applying
    if ($s->{pending}) { $s->{row}++; $s->{col} = 0; $s->{pending} = 0 }
    $s->{row} = $row - 1;
    $s->{col} = $col - 1;
}

# VT Model C (CR clears pending, ESC doesn't resolve): what the code assumed
package VTCrClears;
our @ISA = qw(VTBase);
sub _cr   { my $s = shift; $s->{col} = 0; $s->{pending} = 0 }
sub _lf   { my $s = shift; $s->{pending} = 0; $s->{row}++; $s->{col} = 0 }
sub _bs   {
    my $s = shift;
    if ($s->{pending}) { $s->{row}++; $s->{col} = 0; $s->{pending} = 0 }
    $s->{col}--; $s->{col} = 0 if $s->{col} < 0;
}
sub _char {
    my ($s, $ch) = @_;
    if ($s->{pending}) { $s->{row}++; $s->{col} = 0; $s->{pending} = 0 }
    $s->{buffer}[$s->{row}][$s->{col}] = $ch;
    $s->{col}++;
    if ($s->{col} >= $s->{cols}) { $s->{pending} = 1; $s->{col} = $s->{cols} - 1; }
}
sub _csi { my ($s,$cmd,$n) = @_; if ($cmd eq 'C') { $s->{col}+=$n; $s->{col}=$s->{cols}-1 if $s->{col}>=$s->{cols} } elsif ($cmd eq 'D') { $s->{col}-=$n; $s->{col}=0 if $s->{col}<0 } elsif ($cmd eq 'A') { $s->{row}-=$n; $s->{row}=0 if $s->{row}<0 } elsif ($cmd eq 'B') { $s->{row}+=$n } elsif ($cmd eq 'K') { for (my $c=$s->{col};$c<$s->{cols};$c++){delete $s->{buffer}[$s->{row}][$c]} } }
sub _csi_H {
    my ($s, $row, $col) = @_;
    $s->{row} = $row - 1;
    $s->{col} = $col - 1;
}

package main;

use Encode;
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
    return Encode::decode('UTF-8', $buf);
}

# Simulate: type the full input (which ends at pending position), then
# navigate back left one step at a time.
sub setup_vt {
    my ($vt_class) = @_;
    my $vt = $vt_class->new(cols => 80, rows => 24);
    my $buf = capture(sub {
        $rl->_emit_text($prompt);
        $rl->_emit_text($input);
    });
    $vt->feed($buf);
    # Update model state
    $rl->_refresh_geometry($input, length($input), $prompt);
    return $vt;
}

sub do_reposition {
    my ($vt, $from_cp, $to_cp) = @_;
    my $buf = capture(sub {
        $rl->reposition_cursor(\($from_cp), \($to_cp), \$input, $prompt);
    });
    $vt->feed($buf);
}

# check both row and col
sub check {
    my ($vt, $cp, $label, $vt_class_name) = @_;
    my ($vr, $vc, $vp) = $vt->cursor();
    my ($mr, $mc, $mp) = model_pos($cp);
    # Normalize: VT model may store col=cols (overflow) when pending is
    # set after character output (cursor at last column, 0-indexed cols-1).
    # Real terminals keep cursor at col=cols-1 in this state.
    if ($vc >= $cols) { $vc = $cols - 1 }
    is($vr, $mr, "$vt_class_name $label: row (VT=$vr, model=$mr)");
    is($vc, $mc, "$vt_class_name $label: col (VT=$vc, model=$mc)");
    is($vp, $mp, "$vt_class_name $label: pending (VT=$vp, model=$mp)");
}

# Test with each VT model
for my $vt_class ('VTxterm', 'VTLinux', 'VTCrClears') {
    my $label = $vt_class;
    $label =~ s/^VT//;

    # Setup: type 123 chars (ends at pending position on row 1, col 79 0-indexed)
    my $vt = setup_vt($vt_class);

    # Verify initial position: cp=123 -> (1, 79 0-indexed, pending=1)
    my ($vr, $vc, $vp) = $vt->cursor();
    my ($mr, $mc, $mp) = model_pos(123);
    if ($vc >= $cols) { $vc = $cols - 1 }  # Normalize VT col overflow
    is($vr, $mr, "$label T1 initial: row (VT=$vr, model=$mr)");
    is($vc, $mc, "$label T1 initial: col (VT=$vc, model=$mc)");
    is($vp, $mp, "$label T1 initial: pending (VT=$vp, model=$mp)");

    # Navigate Left 1: cp=123 -> cp=122 (row 1, col 77 0-indexed, not pending)
    do_reposition($vt, 123, 122);
    check($vt, 122, "after 1st Left (from pending boundary)", $label);

    # Navigate Left to cp=80 (end of row 0, pending)
    for my $cp (reverse 81..122) {
        do_reposition($vt, $cp, $cp - 1);
    }
    check($vt, 80, "at row 0/row 1 boundary (pending)", $label);

    # Navigate Left 1 more: cp=80 -> cp=79 (row 0, col 77 0-indexed)
    do_reposition($vt, 80, 79);
    check($vt, 79, "past row 0/row 1 boundary", $label);

    # Navigate all the way back to cp=0
    for my $cp (reverse 1..79) {
        do_reposition($vt, $cp, $cp - 1);
    }
    check($vt, 0, "navigated all the way back to start", $label);
}

# Also test with input ending at col 43 (row 0 only), 43 chars: 37+43=80, pending=1
{
    my $input2 = '';
    for my $i (0 .. 42) {
        $input2 .= chr(ord('a') + ($i % 26));
    }
    die "Input2 should be 43 chars" unless length($input2) == 43;

    for my $vt_class ('VTxterm', 'VTLinux', 'VTCrClears') {
        my $label = $vt_class;
        $label =~ s/^VT//;

        # Build a separate rl for this input size
        my $rl2 = CLIO::Core::ReadLine->new(prompt => $prompt);
        $rl2->{_term_size_cache} = [$cols, 24];
        $rl2->{_term_size_time} = time();
        $rl2->{_prompt_disp_cache} = length($prompt);

        sub model_pos2 {
            my ($cp) = @_;
            my ($row, $col, $pending) = $rl2->_cursor_at_codepoint($input2, $cp, $prompt);
            return ($row, $col - 1, $pending);
        }

        my $vt = $vt_class->new(cols => 80, rows => 24);
        my $buf = capture(sub {
            $rl2->_emit_text($prompt);
            $rl2->_emit_text($input2);
        });
        $vt->feed($buf);
        $rl2->_refresh_geometry($input2, length($input2), $prompt);

        # Verify initial: cp=43 -> (0, 79 0-indexed, pending=1)
        my ($vr, $vc, $vp) = $vt->cursor();
        my ($mr, $mc, $mp) = model_pos2(43);
        if ($vc >= $cols) { $vc = $cols - 1 }  # Normalize VT col overflow
    is($vr, $mr, "$label T2 initial: row (VT=$vr, model=$mr)");
    is($vc, $mc, "$label T2 initial: col (VT=$vc, model=$mc)");
    is($vp, $mp, "$label T2 initial: pending (VT=$vp, model=$mp)");

        # Left 1: cp=43 -> cp=42 (pending -> not pending, same row)
        $buf = capture(sub {
            $rl2->reposition_cursor(\(my $f=43), \(my $t=42), \$input2, $prompt);
        });
        $vt->feed($buf);
        ($vr, $vc, $vp) = $vt->cursor();
        ($mr, $mc, $mp) = model_pos2(42);
        is($vr, $mr, "$label T2 1st Left: row (VT=$vr, model=$mr)");
        is($vc, $mc, "$label T2 1st Left: col (VT=$vc, model=$mc)");
        is($vp, $mp, "$label T2 1st Left: pending (VT=$vp, model=$mp)");

        # Navigate all the way back to cp=0
        for my $cp (reverse 1..42) {
            $buf = capture(sub {
                $rl2->reposition_cursor(\(my $f=$cp), \(my $t=$cp-1), \$input2, $prompt);
            });
            $vt->feed($buf);
        }
        ($vr, $vc, $vp) = $vt->cursor();
        ($mr, $mc, $mp) = model_pos2(0);
        is($vr, $mr, "$label T2 all the way back: row (VT=$vr, model=$mr)");
        is($vc, $mc, "$label T2 all the way back: col (VT=$vc, model=$mc)");
        is($vp, $mp, "$label T2 all the way back: pending (VT=$vp, model=$mp)");
    }
}

# ---- T3: Direct jumps from pending to col 0 of another row ----
# This tests the user's exact bug scenario: cursor at a pending position
# (end of a row) and user directly navigates to col 0 of a DIFFERENT row.
# The previous code (CR-only pending resolution) failed on VTLinux because
# CR didn't clear pending and cursor movement wrapped to the wrong row.
{
    # Use the same $rl/$input/$prompt from T1 (123-char input, 37-char prompt)
    # and model_pos() from the outer scope.

    for my $vt_class ('VTxterm', 'VTLinux', 'VTCrClears') {
        my $label = $vt_class;
        $label =~ s/^VT//;

        # Setup: type the full input (ends at pending position on input row 1)
        my $vt = setup_vt($vt_class);

        # Verify initial: cp=123 -> (1, 79 0-indexed, pending=1)
        check($vt, 123, "$label T3 initial at pending boundary", $label);

        # Direct jump from cp=123 (pending, end of row 1) to cp=0 (row 0, col 0).
        # This is the user's bug: navigating from a pending position to col 0
        # of a different row.
        do_reposition($vt, 123, 0);
        check($vt, 0, "$label T3 direct jump to start", $label);

        # Direct jump from cp=0 back to cp=123 (pending, end of row 1).
        # Tests forward navigation to a pending position.
        do_reposition($vt, 0, 123);
        check($vt, 123, "$label T3 direct jump back to pending", $label);

        # Direct jump from cp=0 to cp=43 (row 0/row 1 boundary, pending).
        do_reposition($vt, 123, 43);
        check($vt, 43, "$label T3 direct jump to row boundary", $label);

        # Direct jump from cp=43 (pending, end of row 0) to cp=123 (pending, end of row 1).
        do_reposition($vt, 43, 123);
        check($vt, 123, "$label T3 pending->pending direct jump", $label);

        # Navigate left from cp=123 to cp=43 (pending boundary), then
        # continue left to cp=42 (col 80, not pending, row 0).
        do_reposition($vt, 123, 43);
        check($vt, 43, "$label T3 to row boundary (pending)", $label);
        do_reposition($vt, 43, 42);
        check($vt, 42, "$label T3 past boundary to col 80 non-pending", $label);

        # Now from cp=42, jump to cp=44 (start of row 1, col 1).
        # cp=42: (0, 80, 0) — col 80 non-pending.
        # cp=44: (1, 2, 0) — col 2 of row 1.
        do_reposition($vt, 42, 44);
        check($vt, 44, "$label T3 jump across wrap to row 1", $label);

        # Jump back to cp=42 (cross-row backward, from non-pending to non-pending).
        do_reposition($vt, 44, 42);
        check($vt, 42, "$label T3 jump back across wrap", $label);
    }
}

done_testing();