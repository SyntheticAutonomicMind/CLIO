# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::ReasoningLoopDetector;

use strict;
use warnings;
use utf8;

=head1 NAME

CLIO::Core::ReasoningLoopDetector - Detect verbatim repetition loops in model reasoning output

=head1 SYNOPSIS

    use CLIO::Core::ReasoningLoopDetector;

    my $detector = CLIO::Core::ReasoningLoopDetector->new();
    my $cycle_len = $detector->check(\$accumulated_reasoning);
    if ($cycle_len) {
        # The reasoning buffer has entered a verbatim repetition loop with
        # a cycle length of $cycle_len characters.
    }

=head1 DESCRIPTION

Local models served through llama.cpp occasionally enter degenerate
repetition loops mid-reasoning, re-emitting the same sentence or paragraph
verbatim dozens of times. This module detects such loops by scanning the
tail of the accumulated reasoning text for periodic structure: N
consecutive identical blocks of at least C<min_cycle_length> characters.

The detector is stateless per call - the caller owns the accumulated text
buffer and passes a reference on each check. Detection is purely
character-exact; paraphrased loops (same meaning, different wording) are
deliberately out of scope, since fuzzy similarity matching false-positives
on legitimate reasoning. Literal loops are the common failure mode, and
DRY anti-repetition sampling (applied separately) prevents most of them
from forming in the first place.

=cut

=head1 METHODS

=head2 new(%opts)

Constructor. Options override the detection thresholds:

  min_cycle_length  => 40,    # Repeated blocks shorter than this never trigger
  min_cycles        => 3,     # Consecutive identical blocks required to trigger
  max_tail          => 6144,  # Chars of the tail examined (bounds max cycle length)

Returns: a detector instance.

=cut

sub new {
    my ($class, %opts) = @_;
    my $self = {
        min_cycle_length => $opts{min_cycle_length} // 40,
        min_cycles       => $opts{min_cycles} // 3,
        max_tail         => $opts{max_tail} // 6144,
    };
    return bless $self, $class;
}

=head2 check($text)

Arguments: $text (required) - the full accumulated text, passed either as a
scalar reference (as used by the streaming integrator) or as a plain string.

Returns: the detected cycle length in characters (truthy) when the buffer
tail is periodic, 0 when no loop is detected.

A trigger means the tail of the buffer consists of at least
C<min_cycles> consecutive identical blocks (the cycle), each at least
C<min_cycle_length> characters. The scan is O(tail_length) per call at
worst a few milliseconds for the default window.

=cut

sub check {
    my ($self, $text) = @_;
    return 0 unless defined $text;
    $text = $$text if ref($text) eq 'SCALAR';
    return 0 unless defined $text && length $text;

    my $tail = substr($text, -$self->{max_tail});
    my $tlen = length $tail;
    my $min  = $self->{min_cycle_length};
    my $max  = int($tlen / $self->{min_cycles});
    return 0 if $max < $min;

    # Scan candidate cycle lengths ascending. Ascending order triggers at
    # the earliest stable point for short fast loops; longer true cycles
    # are also detected (any cycle length p divides the loop, so the
    # base period itself is found first).
    for (my $p = $min; $p <= $max; $p++) {
        next unless substr($tail, -$p) eq substr($tail, -2 * $p, $p);
        return $p if substr($tail, -3 * $p, $p) eq substr($tail, -$p);
    }

    return 0;
}

1;  # MANDATORY

=head1 AUTHOR

Andrew Wyatt (Fewtarius)

=head1 LICENSE

GPL-3.0-only

=cut
