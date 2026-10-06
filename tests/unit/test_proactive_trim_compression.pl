#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: Proactive trim drops messages without thread_summary injection
#
# Verifies that MessageValidator::_role_based_tail_walk drops messages
# when over budget. When NO active_task is provided (simulating the
# no-summary case), no thread_summary system message is injected.
# When active_task IS provided, exactly ONE thread_summary is injected
# (the canonical single-artifact invariant — old summaries are
# replaced, not accumulated).

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More tests => 9;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);

# ---------------------------------------------------------------------------
# Build a large enough message array to force the tail walk to drop messages.
# ---------------------------------------------------------------------------
my @messages;
push @messages, { role => 'system', content => 'You are a helpful assistant.' };
push @messages, { role => 'user', content => 'Original task: write tests for the new compression pipeline.' };
push @messages, { role => 'assistant', content => 'I will start working on that.' };
push @messages, { role => 'tool', tool_call_id => 'tc0', content => 'result 0' };

for my $i (1 .. 50) {
    push @messages, { role => 'user', content => "Question $i: " . ('x' x 200) };
    push @messages, { role => 'assistant', content => "Answer $i: " . ('y' x 200) };
    push @messages, { role => 'tool', content => "Result $i", tool_call_id => "call_$i" };
}

# Tight limit to force drops.
my $effective_limit = 2000;

# Model capabilities for validate_and_truncate calls (Test 7)
my $caps = {
    max_prompt_tokens         => 8000,
    max_output_tokens         => 4096,
    max_context_window_tokens => 8000,
};

my $trimmed_ref = CLIO::Core::API::MessageValidator::_role_based_tail_walk(\@messages, $effective_limit, 1);
my @trimmed = ref($trimmed_ref) eq 'ARRAY' ? @$trimmed_ref : ($trimmed_ref);

ok(scalar(@trimmed) < scalar(@messages),
    'Tail walk dropped messages (was ' . scalar(@messages) . ', now ' . scalar(@trimmed) . ')');

# NO thread_summary system message should be injected — the compressed
# summary lives in the dynamic UC (projection's compressed_tail), not
# as a separate injected system message. Injecting one here would
# break KV cache stability of the prefix.
my $has_summary = 0;
for my $msg (@trimmed) {
    if (ref($msg) eq 'HASH'
        && ($msg->{role} // '') eq 'system'
        && ($msg->{content} // '') =~ /<thread_summary>/) {
        $has_summary = 1;
        last;
    }
}
ok(!$has_summary, 'No thread_summary system message injected (no active_task provided)');

# The first user message should be preserved (pinned)
my $has_first_user = 0;
for my $msg (@trimmed) {
    if (ref($msg) eq 'HASH'
        && ($msg->{role} // '') eq 'user'
        && ($msg->{content} // '') =~ /Original task/) {
        $has_first_user = 1;
        last;
    }
}
ok($has_first_user, 'First user message (original task) preserved after trim');

# The system prompt should be preserved (pinned)
my $has_system = 0;
for my $msg (@trimmed) {
    if (ref($msg) eq 'HASH' && ($msg->{role} // '') eq 'system') {
        $has_system = 1;
        last;
    }
}
ok($has_system, 'System prompt preserved after trim');

# No orphaned tool calls (every tool result has a matching assistant)
my %tool_call_ids;
for my $msg (@trimmed) {
    if (ref($msg) eq 'HASH' && ($msg->{role} // '') eq 'assistant' && $msg->{tool_calls}) {
        for my $tc (@{$msg->{tool_calls}}) {
            $tool_call_ids{$tc->{id}} //= 0;
            $tool_call_ids{$tc->{id}} = 1;
        }
    }
}
my $orphans = 0;
for my $msg (@trimmed) {
    if (ref($msg) eq 'HASH' && ($msg->{role} // '') eq 'tool' && $msg->{tool_call_id}) {
        $orphans++ unless $tool_call_ids{$msg->{tool_call_id}};
    }
}
is($orphans, 0, 'No orphaned tool results after trim');

# Messages should be in valid role-based order (no consecutive system)
my $prev_role = '';
my $consecutive_system = 0;
for my $msg (@trimmed) {
    my $r = ref($msg) eq 'HASH' ? ($msg->{role} // '') : '';
    $consecutive_system++ if $r eq 'system' && $prev_role eq 'system';
    $prev_role = $r;
}
is($consecutive_system, 0, 'No consecutive system messages');

# ---------------------------------------------------------------------------
# Test 7: When active_task IS provided, exactly ONE thread_summary is
# injected (the canonical single-artifact invariant). An existing
# thread_summary (simulating a compressed_tail system message from the
# projection) must be REPLACED, not accumulated.
# ---------------------------------------------------------------------------
my @messages_with_summary;
push @messages_with_summary, { role => 'system', content => 'You are a helpful assistant.' };
push @messages_with_summary, { role => 'user', content => 'Original task: write tests for the new compression pipeline.' };
push @messages_with_summary, { role => 'assistant', content => 'I will start working on that.' };
push @messages_with_summary, { role => 'tool', tool_call_id => 'tc0', content => 'result 0' };

# Pre-inject an existing thread_summary (simulating projection's compressed_tail)
push @messages_with_summary, { role => 'system', content => "<thread_summary>\nCurrent task: Old task that should be carried over\nRecent user requests:\n- Build widget system\n</thread_summary>" };

for my $i (1 .. 50) {
    push @messages_with_summary, { role => 'user', content => "Question $i: " . ('x' x 200) };
    push @messages_with_summary, { role => 'assistant', content => "Answer $i: " . ('y' x 200) };
    push @messages_with_summary, { role => 'tool', content => "Result $i", tool_call_id => "call_$i" };
}
push @messages_with_summary, { role => 'user', content => 'Current request to check glyph width' };

my $trimmed_with_task = validate_and_truncate(
    messages           => \@messages_with_summary,
    model_capabilities => $caps,
    tools              => [],
    token_ratio        => 2.5,
    active_task        => 'Current request to check glyph width',
    debug              => 1,
);

my $summary_count = 0;
my $new_summary;
for my $msg (@$trimmed_with_task) {
    if (ref($msg) eq 'HASH'
        && ($msg->{role} // '') eq 'system'
        && ($msg->{content} // '') =~ /<thread_summary>/) {
        $summary_count++;
        $new_summary = $msg->{content} unless $new_summary;
    }
}
is($summary_count, 1, 'With active_task: exactly 1 thread_summary (old replaced, no accumulation)');

# The new summary should carry the old state (cross-cycle carryover)
like($new_summary, qr/Old task that should be carried over/i, 'New summary carries old summary state (cross-cycle carryover)');
unlike($new_summary // '', qr/Old task.*Old task/s, 'No duplicate "Old task" in new summary (no recursion)');

done_testing();
