#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for tool error loop accounting (WorkflowOrchestrator::track_tool_error_loop).
#
# The error loop used to set a break flag that ended the turn. That is gone:
# repeated failures now produce a guidance note the model can read and act on.
# These tests pin both halves of that contract:
#
# - A repeated identical call gets a note that says the input, not the
#   attempt, has to change.
# - Repeated failures with DIFFERENT arguments are recognized as a different
#   problem (wrong call shape) and never described as an identical retry.
# - Nothing in the verdict can end the turn.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use File::Temp qw(tempdir);
use CLIO::Core::Config;
use CLIO::Core::WorkflowOrchestrator;

sub build_orchestrator {
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$dir/config.json" or die $!;
    print $fh q({"provider":"github_copilot","api_key":"sk-test-key"});
    close $fh;
    return CLIO::Core::WorkflowOrchestrator->new(
        config  => CLIO::Core::Config->new(config_dir => $dir),
        debug   => 0,
        session => undef,
    );
}

sub error_call {
    my ($orch, %over) = @_;
    return $orch->track_tool_error_loop(
        tool        => $over{tool} // 'todo_operations',
        operation   => $over{operation} // 'update',
        category    => $over{category} // 'todo_validation_failed',
        args_digest => $over{digest} // 'digest-a',
        iteration   => $over{iteration} // 1,
    );
}

subtest 'a repeated identical call produces guidance, never a break' => sub {
    my $orch = build_orchestrator();

    my $first  = error_call($orch, iteration => 1);
    my $second = error_call($orch, iteration => 2);

    is($first->{identical}, 1, 'first failure: identical count 1');
    is($first->{guidance}, undef, 'first failure: no note');

    is($second->{identical}, 2, 'second identical failure: count 2');
    ok(defined $second->{guidance}, 'second identical failure: note emitted');
    like($second->{guidance}, qr/ERROR LOOP NOTICE/, 'note is identified as a loop notice');
    like($second->{guidance}, qr/attempt #2/, 'note states the attempt number');
    like($second->{guidance}, qr/Re-sending the same input cannot/, 'note explains why it is futile');

    for my $forbidden (qw(break nudge nudge_text error_type success)) {
        ok(!exists $second->{$forbidden}, "verdict carries no '$forbidden' field");
    }
};

subtest 'different arguments are not reported as identical retries' => sub {
    my $orch = build_orchestrator();

    # The gufo session: three different repair attempts, one failure mode.
    my @attempts = map { error_call($orch, digest => "digest-$_", iteration => $_) } 1 .. 3;

    is($attempts[0]{identical}, 1, 'attempt 1: not an identical retry');
    is($attempts[1]{identical}, 1, 'attempt 2: different arguments -> count stays 1');
    is($attempts[2]{identical}, 1, 'attempt 3: different arguments -> count stays 1');
    is($attempts[2]{same_mode}, 3, 'same failure mode counted three times');

    ok(defined $attempts[2]{guidance}, 'third same-mode failure produces a note');
    like($attempts[2]{guidance}, qr/REPEATED FAILURE/, 'note identifies a repeated failure');
    like($attempts[2]{guidance}, qr/Varying what you send has not fixed it/,
        'note points at the call shape rather than the values');
    unlike($attempts[2]{guidance}, qr/ERROR LOOP NOTICE/,
        'note never claims the call was identical');
    unlike($attempts[2]{guidance}, qr/attempt #/, 'note does not imply an identical retry');
};

subtest 'a different failure mode starts its own count' => sub {
    my $orch = build_orchestrator();

    error_call($orch, digest => 'a', iteration => 1);
    error_call($orch, digest => 'b', iteration => 2);
    my $other = error_call($orch, digest => 'c', category => 'missing_required', iteration => 3);

    is($other->{same_mode}, 1, 'new category starts at 1');
    is($other->{guidance}, undef, 'new category produces no note');
};

subtest 'success clears accumulated failures' => sub {
    my $orch = build_orchestrator();

    error_call($orch, digest => 'a', iteration => 1);
    error_call($orch, digest => 'b', iteration => 2);
    $orch->reset_tool_error_loop();

    my $after = error_call($orch, digest => 'c', iteration => 3);
    is($after->{identical}, 1, 'identical count restarts at 1');
    is($after->{same_mode}, 1, 'same-mode count restarts at 1');
    is($after->{guidance}, undef, 'no note after a success');
};

subtest 'notes repeat on a cadence rather than every call' => sub {
    my $orch = build_orchestrator();

    my @notes;
    for my $i (1 .. 6) {
        my $v = error_call($orch, digest => 'same', iteration => $i);
        push @notes, ($v->{guidance} ? $i : 0);
    }
    is_deeply([ grep { $_ } @notes ], [2, 4, 6],
        'identical-retry notes fire at 2, 4 and 6');
};

subtest 'an identical call and a same-mode failure stay separate channels' => sub {
    my $orch = build_orchestrator();

    # Two identical retries, then a genuinely different attempt.
    error_call($orch, digest => 'same', iteration => 1);
    my $identical = error_call($orch, digest => 'same', iteration => 2);
    like($identical->{guidance}, qr/ERROR LOOP NOTICE/,
        'identical channel fires while it is identical');

    my $changed = error_call($orch, digest => 'other', iteration => 3);
    is($changed->{identical}, 1, 'changing arguments resets the identical count');
    like($changed->{guidance} // '', qr/REPEATED FAILURE/,
        'the same-mode channel reports the third failure of the mode');
    unlike($changed->{guidance} // '', qr/ERROR LOOP NOTICE/,
        'the differing retry is not described as an identical one');
};

subtest 'guidance text names the call, not the internal signature' => sub {
    my $orch = build_orchestrator();

    error_call($orch, digest => 'x', iteration => 1);
    my $v = error_call($orch, digest => 'x', iteration => 2);

    like($v->{guidance}, qr/'todo_operations update'/,
        'note names the tool and operation as a caller would say them');
    unlike($v->{guidance}, qr/todo_validation_failed\|/,
        'note does not paste the internal signature');
};

done_testing();
