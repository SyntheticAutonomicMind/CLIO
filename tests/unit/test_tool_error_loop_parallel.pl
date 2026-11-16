#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: parallel tool calls in one response must not inflate the
# error-loop counters.
#
# A model that emits three calls in one response and has all three fail is
# not looping - it made one decision. Only sequential retries across
# different iterations describe a loop. The accounting lives in
# WorkflowOrchestrator::track_tool_error_loop and is exercised directly here.

use strict;
use warnings;
use utf8;
use lib './lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

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

sub fail_call {
    my ($orch, %over) = @_;
    return $orch->track_tool_error_loop(
        tool        => $over{tool} // 'terminal_operations',
        operation   => $over{operation} // 'exec',
        category    => $over{category} // 'missing_required',
        args_digest => $over{digest} // 'same-arguments',
        iteration   => $over{iteration},
    );
}

subtest 'three parallel failures in one iteration count once' => sub {
    my $orch = build_orchestrator();

    my @verdicts = map { fail_call($orch, iteration => 5) } 1 .. 3;

    is($verdicts[0]{identical}, 1, 'first parallel call: count 1');
    is($verdicts[1]{identical}, 1, 'second parallel call: count unchanged');
    is($verdicts[2]{identical}, 1, 'third parallel call: count unchanged');
    is($verdicts[2]{same_mode}, 1, 'failure-mode count is unchanged too');
    is($verdicts[2]{guidance}, undef, 'parallel failures produce no note');
};

subtest 'sequential retries do accumulate' => sub {
    my $orch = build_orchestrator();

    my $one   = fail_call($orch, iteration => 1);
    my $two   = fail_call($orch, iteration => 2);
    my $three = fail_call($orch, iteration => 3);

    is($one->{identical}, 1, 'iteration 1: count 1');
    is($two->{identical}, 2, 'iteration 2: count 2');
    is($three->{identical}, 3, 'iteration 3: count 3');
    ok(defined $two->{guidance}, 'the identical-retry note fires at 2');
};

subtest 'parallel burst then a sequential retry' => sub {
    my $orch = build_orchestrator();

    # Three parallel failures, then one retry in the next iteration.
    fail_call($orch, iteration => 1) for 1 .. 3;
    my $retry = fail_call($orch, iteration => 2);

    is($retry->{identical}, 2,
        'the burst counted once, so the retry makes it a two-attempt loop');
    ok(defined $retry->{guidance}, 'note fires on the real retry, not on the burst');
};

subtest 'a success clears the counters' => sub {
    my $orch = build_orchestrator();

    fail_call($orch, iteration => 1);
    fail_call($orch, iteration => 2);
    $orch->reset_tool_error_loop();

    my $after = fail_call($orch, iteration => 3);
    is($after->{identical}, 1, 'identical count restarts at 1');
    is($after->{same_mode}, 1, 'mode count restarts at 1');
    is($after->{guidance}, undef, 'no note carried over the success');
};

done_testing();
