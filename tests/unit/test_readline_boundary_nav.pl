#!/usr/bin/perl
# Reproduction test for the "stuck cursor at row boundary" bug.
#
# User scenario: 80-col terminal, 37-char prompt, input wraps across
# multiple rows. When the cursor sits at the start of a wrapped row
# (col 1) and the user presses Left, the cursor correctly jumps to
# the end of the previous row (col 80, pending). But then the NEXT
# key press requires two presses to move - the cursor appears "stuck".
#
# This test directly drives reposition_cursor with the user's exact
# terminal dimensions and traces the VT cursor at every step.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use CLIO::Core::ReadLine;

BEGIN {
    no warnings 'redefine', 'prototype';
    require CLIO::Compat::Terminal;
}

# VT model: real terminal pending-wrap semantics
# - Character output at last column enters pending state (cursor stays
#   at last col, wraps to next row on next char output)
# - Cursor movement (ESC[C/D/A/B) does NOT enter pending state and
#   does NOT clear pending (cursor goes wherever the movement puts it)
# - CR (\r) clears pending state (cursor to col 0)
# - This models xterm behavior. On some terminals (e.g. Linux console),
#   cursor movement at pending state resolves pending first, which is
#   modeled separately in test_readline_wide_terminal_scenarios.pl.

package VirtualTerminal;
sub new {
    my ($class, %opts) = @_;
    return bless {
        cols => $opts{cols} || 80,
        rows => $opts{rows} || 24,
        row => 0, col => 0,  # 0-indexed
        pending => 0,
    }, $class;
}

sub feed {
    my ($self, $bytes) = @_;
    my $i = 0;
    while ($i < length($bytes)) {
        my $ch = substr($bytes, $i, 1);
        if ($ch eq "\e") {
            my $next = substr($bytes, $i + 1, 1);
            if ($next eq '[') {
                my $j = $i + 2;
                $j++ while $j < length($bytes) && substr($bytes, $j, 1) =~ /[\d;?]/;
                my $param = substr($bytes, $i + 2, $j - $i - 2);
                my $cmd = substr($bytes, $j, 1);
                $i = $j + 1;
                if ($param =~ /\?/) { next }  # skip private modes
                my $n = ($param ne '' && $param =~ /^(\d+)/ ? $1 : 1) + 0;
                $n = 1 if $n == 0;
                if ($cmd eq 'A') {
                    $self->{row} -= $n;
                    $self->{row} = 0 if $self->{row} < 0;
                } elsif ($cmd eq 'B') {
                    $self->{row} += $n;
                } elsif ($cmd eq 'C') {
                    $self->{col} += $n;
                    $self->{col} = $self->{cols} - 1 if $self->{col} >= $self->{cols};
                } elsif ($cmd eq 'D') {
                    $self->{col} -= $n;
                    $self->{col} = 0 if $self->{col} < 0;
                } elsif ($cmd eq 'K') {
                    # erase to end of line (no-op for cursor tracking)
                } elsif ($cmd eq 'J') {
                    # erase to end of screen (no-op for cursor tracking)
               } elsif ($cmd eq 'H') {
                    my @p = split /;/, $param;
                    $self->{row} = (($p[0] // '') ne '' ? $p[0] : 1) - 1;
                    $self->{col} = (($p[1] // '') ne '' ? $p[1] : 1) - 1;
               }
            } else {
                $i += 2;  # skip ESC + non-[
            }
        } elsif ($ch eq "\r") {
            $self->{col} = 0;
            $self->{pending} = 0;
            $i++;
        } elsif ($ch eq "\n") {
            $self->{row}++;
            $self->{col} = 0;
            $self->{pending} = 0;
            $i++;
        } else {
            # Character output
            if ($self->{pending}) {
                $self->{row}++;
                $self->{col} = 0;
                $self->{pending} = 0;
            }
            $self->{col}++;
            if ($self->{col} >= $self->{cols}) {
                $self->{pending} = 1;
                $self->{col} = $self->{cols} - 1;
            }
            $i++;
        }
    }
}

sub cursor {
    my ($self) = @_;
    return ($self->{row}, $self->{col});
}

sub pending {
    my ($self) = @_;
    return $self->{pending};
}

package main;

# 80-col terminal, 37-char prompt
my $cols = 80;
my $prompt = 'P' x 37;

# Build input that wraps to 4 rows:
# Row 0: 43 chars (cols 38-80, col 80 pending)
# Row 1: 80 chars (cols 1-80, col 80 pending)
# Row 2: 80 chars (cols 1-80, col 80 pending)
# Row 3: 10 chars (cols 1-10)
my $input = '';
for my $i (0 .. 212) {
    $input .= chr(ord('a') + ($i % 26));
}

*CLIO::Compat::Terminal::GetTerminalSize = sub { return ($cols, 24); };
*CLIO::Compat::Terminal::ReadMode = sub { return 1 };

my $rl = CLIO::Core::ReadLine->new(prompt => $prompt);
$rl->{_term_size_cache} = [$cols, 24];
$rl->{_term_size_time} = time();
$rl->{_prompt_disp_cache} = length($prompt);

sub capture_output {
    my ($code) = @_;
    my $buf = '';
    open my $fh, '>', \$buf or die "open to scalar: $!";
    my $old = select($fh);
    $| = 1;
    $code->();
    select($old);
    close $fh;
    return $buf;
}

sub emit_reposition {
    my ($vt, $rl, $from_cp, $to_cp, $input_ref, $prompt) = @_;
    my $bytes = capture_output(sub {
        $rl->reposition_cursor(\$from_cp, \$to_cp, $input_ref, $prompt);
    });
    $vt->feed($bytes);
    return $bytes;
}

sub check_cursor {
    my ($vt, $rl, $cp, $input, $prompt, $label) = @_;
    my ($vr, $vc) = $vt->cursor();
    my ($er, $ec, $ep) = $rl->_cursor_at_codepoint($input, $cp, $prompt);
    is($vr, $er, "$label: VT row matches (got $vr, expected $er)");
    is($vc + 1, $ec, "$label: VT col matches (got " . ($vc + 1) . ", expected $ec)");
    is($vt->pending(), $ep, "$label: VT pending matches (got " . $vt->pending() . ", expected $ep)");
}

# --- Set up initial VT state: prompt + full input typed ---
my $vt = VirtualTerminal->new(cols => $cols, rows => 24);
my $initial_bytes = capture_output(sub {
    $rl->_emit_text($prompt);
    $rl->_emit_text($input);
});
$vt->feed($initial_bytes);

# Verify initial cursor position at end of input (cp=213)
check_cursor($vt, $rl, 213, $input, $prompt, 'initial: cursor at end');
ok(!$vt->pending(), 'initial: VT not pending');

# --- Scenario 1: Navigate from end to start of row 3 (cp=204) ---
# 9 Left presses through row 3. All same-row, col < 80.
my $cp = 213;
for my $step (1..9) {
    my $old_cp = $cp;
    $cp--;
    emit_reposition($vt, $rl, $old_cp, $cp, \$input, $prompt);
    check_cursor($vt, $rl, $cp, $input, $prompt, "left-to-row3-$step");
}

# --- Scenario 2: Left from cp=204 (row 3, col 2) to cp=203 (row 2, col 80 pending) ---
# This is the cross-row move that lands at the boundary.
{
    my $old_cp = 204;
    $cp = 203;
    my $bytes = emit_reposition($vt, $rl, $old_cp, $cp, \$input, $prompt);
    check_cursor($vt, $rl, $cp, $input, $prompt, 'cross-row-left-to-boundary');
}

# --- Scenario 3: Left from cp=203 (row 2, col 80) to cp=202 (row 2, col 79) ---
# THIS IS THE BUG: After landing at col 80 (pending), the next Left
# should use CR to resolve pending and move to col 79.
{
    my $old_cp = 203;
    $cp = 202;
    my $bytes = emit_reposition($vt, $rl, $old_cp, $cp, \$input, $prompt);
    check_cursor($vt, $rl, $cp, $input, $prompt, 'left-from-col80');
    ok(!$vt->pending(), 'left-from-col80: VT not pending after move');
}

# --- Scenario 4: Another Left from cp=202 to cp=201 ---
{
    my $old_cp = 202;
    $cp = 201;
    emit_reposition($vt, $rl, $old_cp, $cp, \$input, $prompt);
    check_cursor($vt, $rl, $cp, $input, $prompt, 'left-from-col79');
}

# --- Scenario 5: Full left-arrow sequence to beginning of input ---
# Navigate from cp=213 to cp=0, pressing Left one at a time.
# Verify VT cursor matches _cursor_at_codepoint at every step.
$vt = VirtualTerminal->new(cols => $cols, rows => 24);
$vt->feed($initial_bytes);
$cp = 213;

my $mismatches = 0;
while ($cp > 0) {
    my $old_cp = $cp;
    $cp--;
    emit_reposition($vt, $rl, $old_cp, $cp, \$input, $prompt);
    my ($vr, $vc) = $vt->cursor();
    my ($er, $ec) = $rl->_cursor_at_codepoint($input, $cp, $prompt);
    if ($vr != $er || $vc + 1 != $ec) {
        $mismatches++;
        diag(sprintf("MISMATCH at cp=%d: VT=(%d,%d) model=(%d,%d) pending=%d",
            $cp, $vr, $vc, $er, $ec, $vt->pending()));
    }
}
is($mismatches, 0, 'full left-navigation: no VT/model mismatches');

# --- Scenario 6: Full right-arrow sequence back to end ---
$cp = 0;
$mismatches = 0;
while ($cp < 213) {
    my $old_cp = $cp;
    $cp++;
    emit_reposition($vt, $rl, $old_cp, $cp, \$input, $prompt);
    my ($vr, $vc) = $vt->cursor();
    my ($er, $ec) = $rl->_cursor_at_codepoint($input, $cp, $prompt);
    if ($vr != $er || $vc + 1 != $ec) {
        $mismatches++;
        diag(sprintf("MISMATCH at cp=%d: VT=(%d,%d) model=(%d,%d) pending=%d",
            $cp, $vr, $vc, $er, $ec, $vt->pending()));
    }
}
is($mismatches, 0, 'full right-navigation: no VT/model mismatches');

done_testing();