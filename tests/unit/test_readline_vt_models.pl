#!/usr/bin/perl
# Direct test of reposition_cursor with multiple VT models.
#
# Tests the user's exact scenario on 80-col terminal with 37-char prompt:
# Type 213 chars (4 rows), then navigate Left through boundaries.
#
# VT Model A (true xterm): CR does NOT clear pending, ESC does NOT
#   resolve pending. Pending only resolved by character output.
#
# VT Model B (Linux console / rxvt): CR does NOT clear pending, ESC
#   DOES resolve pending (pending wraps to next row, then ESC applies).
#
# VT Model C (xterm with CR clearing pending): CR clears pending, ESC
#   does NOT resolve pending. (This is what the code currently assumes.)

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use CLIO::Core::ReadLine;

my $cols = 80;
my $prompt = '>' . (' ' x 36);  # 37 chars

# Build 213-char input (4 rows: 43 + 80 + 80 + 10)
my $input = '';
for my $i (0 .. 212) {
    $input .= chr(ord('a') + ($i % 26));
}
die "Input should be 213 chars" unless length($input) == 213;

my $rl = CLIO::Core::ReadLine->new(prompt => $prompt);
$rl->{_term_size_cache} = [$cols, 24];
$rl->{_term_size_time} = time();
$rl->{_prompt_disp_cache} = length($prompt);

# model_pos: get (row_0indexed, col_0indexed, pending) from _cursor_at_codepoint
sub model_pos {
    my ($cp) = @_;
    my ($row, $col, $pending) = $rl->_cursor_at_codepoint($input, $cp, $prompt);
    # Determine pending: col == term_width means pending (if there are
    my $term_width = $cols;
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
               next if $param =~ /\?/;  # skip private modes
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
sub _cr   { my $s = shift; $s->{col} = 0; }  # No pending clear
sub _lf   { my $s = shift; $s->{pending} = 0; $s->{row}++; $s->{col} = 0 }
sub _bs   { my $s = shift; $s->{col}--; $s->{col} = 0 if $s->{col} < 0 }
sub _char {
    my ($s, $ch) = @_;
    if ($s->{pending}) { $s->{row}++; $s->{col} = 0; $s->{pending} = 0 }
    $s->{buffer}[$s->{row}][$s->{col}] = $ch;
    $s->{col}++;
    if ($s->{col} >= $s->{cols}) { $s->{pending} = 1; $s->{col} = $s->{cols} - 1; }
}
sub _csi_H {
    my ($s, $row, $col) = @_;
    $s->{row} = $row - 1;
    $s->{col} = $col - 1;
}
# ESC[C: cursor right, no pending resolution
sub _csi { my ($s,$cmd,$n) = @_; if ($cmd eq 'C') { $s->{col}+=$n; $s->{col}=$s->{cols}-1 if $s->{col}>=$s->{cols} } elsif ($cmd eq 'D') { $s->{col}-=$n; $s->{col}=0 if $s->{col}<0 } elsif ($cmd eq 'A') { $s->{row}-=$n; $s->{row}=0 if $s->{row}<0 } elsif ($cmd eq 'B') { $s->{row}+=$n } elsif ($cmd eq 'K') { for (my $c=$s->{col};$c<$s->{cols};$c++){delete $s->{buffer}[$s->{row}][$c]} } }

# VT Model B (Linux console): CR does NOT clear pending, ESC DOES resolve pending
package VTLinux;
our @ISA = qw(VTBase);
sub _cr   { my $s = shift; $s->{col} = 0; }  # No pending clear
sub _lf   { my $s = shift; $s->{pending} = 0; $s->{row}++; $s->{col} = 0 }
sub _bs   { my $s = shift; if ($s->{pending}) { $s->{row}++; $s->{col} = 0; $s->{pending} = 0 } $s->{col}--; $s->{col} = 0 if $s->{col} < 0 }
sub _char {
    my ($s, $ch) = @_;
    if ($s->{pending}) { $s->{row}++; $s->{col} = 0; $s->{pending} = 0 }
    $s->{buffer}[$s->{row}][$s->{col}] = $ch;
    $s->{col}++;
    if ($s->{col} >= $s->{cols}) { $s->{pending} = 1; $s->{col} = $s->{cols} - 1; }
}
sub _csi {
    my ($s,$cmd,$n) = @_;
    # ESC resolves pending: pending wraps to next row first, then ESC applies
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

# VT Model C (CR clears pending, ESC doesn't resolve): what code assumes
package VTCrClears;
our @ISA = qw(VTBase);
sub _cr   { my $s = shift; $s->{col} = 0; $s->{pending} = 0 }  # CR clears pending
sub _lf   { my $s = shift; $s->{pending} = 0; $s->{row}++; $s->{col} = 0 }
sub _bs   { my $s = shift; if ($s->{pending}) { $s->{row}++; $s->{col} = 0; $s->{pending} = 0 } $s->{col}--; $s->{col} = 0 if $s->{col} < 0 }
sub _char {
    my ($s, $ch) = @_;
    if ($s->{pending}) { $s->{row}++; $s->{col} = 0; $s->{pending} = 0 }
    $s->{buffer}[$s->{row}][$s->{col}] = $ch;
    $s->{col}++;
    if ($s->{col} >= $s->{cols}) { $s->{pending} = 1; $s->{col} = $s->{cols} - 1; }
}
sub _csi_H {
    my ($s, $row, $col) = @_;
    $s->{row} = $row - 1;
    $s->{col} = $col - 1;
}
# ESC[C: cursor right, no pending resolution
sub _csi { my ($s,$cmd,$n) = @_; if ($cmd eq 'C') { $s->{col}+=$n; $s->{col}=$s->{cols}-1 if $s->{col}>=$s->{cols} } elsif ($cmd eq 'D') { $s->{col}-=$n; $s->{col}=0 if $s->{col}<0 } elsif ($cmd eq 'A') { $s->{row}-=$n; $s->{row}=0 if $s->{row}<0 } elsif ($cmd eq 'B') { $s->{row}+=$n } elsif ($cmd eq 'K') { for (my $c=$s->{col};$c<$s->{cols};$c++){delete $s->{buffer}[$s->{row}][$c]} } }

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

# Simulate: type 213 chars, then navigate back left.
# We drive reposition_cursor directly (no full readline loop) because
# reposition_cursor is what handles arrow key movement.

sub setup_vt {
    my ($vt_class) = @_;
    my $vt = $vt_class->new(cols => 80, rows => 24);
    # Emit prompt + input (simulates initial typing)
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

sub check {
    my ($vt, $cp, $label, $vt_class_name) = @_;
    my ($vr, $vc, $vp) = $vt->cursor();
    my ($mr, $mc, $mp) = model_pos($cp);
    is($vr, $mr, "$vt_class_name $label: row (VT=$vr, model=$mr)") ;
    is($vc, $mc, "$vt_class_name $label: col (VT=$vc, model=$mc)") ;
    is($vp, $mp, "$vt_class_name $label: pending (VT=$vp, model=$mp)") ;
    diag("  $vt_class_name $label cp=$cp: VT=($vr,$vc,pending=$vp) model=($mr,$mc,pending=$mp)")
        if $vr != $mr || $vc != $mc;
}

# Test with each VT model
for my $vt_class ('VTxterm', 'VTLinux', 'VTCrClears') {
    my $label = $vt_class;
    $label =~ s/^VT//;

    # Test 1: Type all 213 chars, then navigate Left to row 2/row 3 boundary
    {
        my $vt = setup_vt($vt_class);
        # Verify initial position: cp=213 -> (3, 9 0-indexed), not pending
        my ($vr, $vc, $vp) = $vt->cursor();
        my ($mr, $mc, $mp) = model_pos(213);
        is($vr, $mr, "$label T1 initial: row (VT=$vr, model=$mr)");
        is($vc, $mc, "$label T1 initial: col (VT=$vc, model=$mc)");

        # Navigate Left 10 times: cp=213 -> cp=203 (boundary, pending)
        for my $cp (reverse 204..213) {
            do_reposition($vt, $cp, $cp - 1);
        }
        # Now at cp=203: model says (2, 79 0-indexed, pending=1)
        check($vt, 203, "after 10 Lefts to boundary", $label);

        # One more Left: cp=203 -> cp=202 (row 2, col 78, not pending)
        do_reposition($vt, 203, 202);
        check($vt, 202, "after 11th Left (past boundary)", $label);

        # Continue Left: cp=202 -> cp=123 (boundary, pending)
        for my $cp (reverse 124..202) {
            do_reposition($vt, $cp, $cp - 1);
        }
        check($vt, 123, "after reaching row 1/row 2 boundary", $label);

        # One more Left: cp=123 -> cp=122
        do_reposition($vt, 123, 122);
        check($vt, 122, "after passing row 1/row 2 boundary", $label);

        # Navigate all the way back to cp=0
        for my $cp (reverse 1..122) {
            do_reposition($vt, $cp, $cp - 1);
        }
        check($vt, 0, "after navigating all the way back", $label);
    }
}

done_testing();