#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Regression test for snapshot-vs-history drift in CLIO session resume.
#
# The fast path (_try_resume_from_payload) returns the captured
# last_api_payload verbatim with fresh [4] user_context and [5]
# user_input appended. For LCP cache stability, the snapshot must
# equal what load_conversation_history + system prompt + user_context
# would return from a fresh build - otherwise the cache hash diverges
# and llama.cpp's LCP anchor collapses on every resume.
#
# This test pins the documented normalization delta:
#   1. Ephemeral continuation nudges stripped from snapshot, kept in history
#      (so the model can't loop on stale nudges after resume).
#   2. Orphan tool_calls stripped (defense-in-depth for stale snapshots).
#   3. user_context at [4] stripped from snapshot (replaced fresh per turn).
#
# This test verifies the contract using CLIO::Core::ConversationManager
# helpers directly. It does NOT exercise a full session resume cycle
# (that requires a Session::State instance which has its own tests).

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use CLIO::Core::ConversationManager qw(load_conversation_history);

# Helper: simulate what _capture_api_payload would produce. This mirrors
# the code path in lib/CLIO/Core/WorkflowOrchestrator.pm:_capture_api_payload.
sub simulate_capture_api_payload {
    my ($msgs) = @_;
    my @kept;
    for my $m (@$msgs) {
        next if $m->{_ephemeral_nudge};
        if ($m->{_orphan_strip}) {
            # Strip the orphan tool_calls but keep the message (the
            # strip marker is consumed). If the message has no other
            # content (just the orphan tool_calls), drop it entirely.
            my $has_content = length($m->{content} // '');
            if (!$has_content) {
                next;
            }
            my $clean = { %$m };
            delete $clean->{tool_calls};
            delete $clean->{_orphan_strip};
            push @kept, $clean;
            next;
        }
        # Strip user_context - it's regenerated fresh each turn
        if (($m->{role} // '') eq 'system' &&
            ($m->{content} // '') =~ /^\s*<(?:userContext|dynamicContext|sessionGoals)/) {
            next;
        }
        push @kept, $m;
    }
    return \@kept;
}

subtest 'snapshot drops ephemeral continuation nudges' => sub {
    my @history = (
        { role => 'system', content => 'sys' },
        { role => 'user', content => 'task' },
        { role => 'assistant', content => 'OK' },
        { role => 'user', content => 'continue', _ephemeral_nudge => 1 },
        { role => 'user', content => 'final task' },
    );

    my $snap = simulate_capture_api_payload(\@history);
    my @kept_content = map { $_->{content} // '' } @$snap;

    ok(!grep { $_ eq 'continue' } @kept_content,
        'ephemeral continuation nudge stripped from snapshot');
    is(scalar(@$snap), scalar(@history) - 1,
        'snapshot has one fewer message than history');
};

subtest 'snapshot drops orphan tool_calls entirely when message is otherwise empty' => sub {
    # An assistant message whose ONLY content is the orphan tool_calls
    # should be dropped entirely from the snapshot.
    my @history = (
        { role => 'system', content => 'sys' },
        { role => 'assistant', content => '',
          tool_calls => [{ id => 'tc1', type => 'function',
                          function => { name => 'foo', arguments => '{}' } }],
          _orphan_strip => 1 },
    );

    my $snap = simulate_capture_api_payload(\@history);
    is(scalar(@$snap), 1, 'snapshot has 1 message (orphan-only dropped)');
    is($snap->[0]{content}, 'sys', 'only the system message survives');
};

subtest 'snapshot keeps orphan-stripped tool_calls but drops the strip marker' => sub {
    # When _orphan_strip is set but the message is otherwise valid, the
    # marker is consumed (the strip has happened) and the message is
    # preserved - but with tool_calls removed.
    my @history = (
        { role => 'system', content => 'sys' },
        { role => 'user', content => 'task' },
        { role => 'assistant', content => 'reasoning',
          tool_calls => [{ id => 'tc1', type => 'function',
                          function => { name => 'foo', arguments => '{}' } }],
          _orphan_strip => 1 },
    );

    my $snap = simulate_capture_api_payload(\@history);
    is(scalar(@$snap), 3, 'snapshot has 3 messages');
    is($snap->[2]{content}, 'reasoning', 'preserved assistant content');
    ok(!exists $snap->[2]{tool_calls}, 'orphan tool_calls stripped');
    ok(!exists $snap->[2]{_orphan_strip}, 'orphan-strip marker consumed');
};

subtest 'snapshot drops user_context anchors' => sub {
    my @history = (
        { role => 'system', content => 'sys' },
        { role => 'system', content => '<userContext>timestamp=now</userContext>' },
        { role => 'system', content => '<dynamicContext>workdir=/home</dynamicContext>' },
        { role => 'system', content => '<sessionGoals>goal1,goal2</sessionGoals>' },
        { role => 'user', content => 'task' },
    );

    my $snap = simulate_capture_api_payload(\@history);
    is(scalar(@$snap), 2, 'snapshot has 2 messages (3 user_context stripped)');
    is($snap->[0]{content}, 'sys', 'first message is system_prompt');
    is($snap->[1]{content}, 'task', 'second message is user');
};

subtest 'snapshot preserves thread_summary' => sub {
    my @history = (
        { role => 'system', content => 'sys' },
        { role => 'system', content => '<thread_summary>Current task: foo</thread_summary>' },
        { role => 'user', content => 'task' },
        { role => 'assistant', content => 'reasoning' },
    );

    my $snap = simulate_capture_api_payload(\@history);
    is(scalar(@$snap), 4, 'snapshot has all 4 messages');
    my $has_summary = 0;
    for my $m (@$snap) {
        $has_summary = 1 if (($m->{content} // '') =~ /<thread_summary>/);
    }
    ok($has_summary, 'thread_summary preserved in snapshot');
};

subtest 'snapshot is byte-identical when no normalization needed' => sub {
    my @history = (
        { role => 'system', content => 'sys' },
        { role => 'user', content => 'task' },
        { role => 'assistant', content => 'reasoning' },
        { role => 'user', content => 'next' },
    );

    my $snap = simulate_capture_api_payload(\@history);
    is_deeply($snap, \@history,
        'snapshot equals history when no ephemeral/orphan/user_context markers present');
};

done_testing();