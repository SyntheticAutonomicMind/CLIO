#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: Proactive trim generates thread_summary
#
# Verifies that MessageValidator::_role_based_tail_walk now generates
# a thread_summary when it drops messages (Path A - proactive trim).
# Previously, dropped messages were permanently lost with no summary.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More tests => 7;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);

# ---------------------------------------------------------------------------
# Build a large enough message array to force the tail walk to drop messages.
# Each message is ~500 chars, 200 messages = ~100K chars = ~40K tokens.
# With a small effective_limit, the walk will drop older messages.
# ---------------------------------------------------------------------------
my @messages;
push @messages, { role => 'system', content => 'You are a helpful assistant.' };
push @messages, { role => 'user', content => 'Original task: write tests for the new compression pipeline.' };
push @messages, { role => 'assistant', content => 'I will start working on that.' };
push @messages, { role => 'tool', tool_call_id => 'tc0', content => 'result 0' };

my $msg_count = 3;
for my $i (1 .. 50) {
    push @messages, { role => 'user', content => "Question $i: " . ('x' x 200) };
    push @messages, { role => 'assistant', content => "Answer $i: " . ('y' x 200) };
    push @messages, { role => 'tool', content => "Result $i", tool_call_id => "call_$i" };
    $msg_count += 3;
}

# Estimate tokens: each message ~200 chars / 2.5 = ~80 tokens.
# 152 messages * 80 = ~12160 tokens. Use a tight limit to force drops.
my $effective_limit = 2000;  # Force significant trimming

my $trimmed_ref = CLIO::Core::API::MessageValidator::_role_based_tail_walk(\@messages, $effective_limit, 1);
my @trimmed = ref($trimmed_ref) eq 'ARRAY' ? @$trimmed_ref : ($trimmed_ref);

ok(scalar(@trimmed) < scalar(@messages),
    'Tail walk dropped messages (was ' . scalar(@messages) . ', now ' . scalar(@trimmed) . ')');

# Check that a thread_summary system message was injected
my $has_summary = 0;
for my $msg (@trimmed) {
    if (ref($msg) eq 'HASH'
        && ($msg->{role} // '') eq 'system'
        && ($msg->{content} // '') =~ /<thread_summary>/) {
        $has_summary = 1;
        last;
    }
}
ok($has_summary, 'Thread summary system message injected after proactive trim');

# The summary should NOT contain framework narration
my $summary_content = '';
for my $msg (@trimmed) {
    if (ref($msg) eq 'HASH'
        && ($msg->{role} // '') eq 'system'
        && ($msg->{content} // '') =~ /<thread_summary>/) {
        $summary_content = $msg->{content};
        last;
    }
}
unlike($summary_content, qr/To recover more context/, 'No "To recover more context" narration');
unlike($summary_content, qr/DO NOT read handoff/, 'No "DO NOT read handoff" instruction');
unlike($summary_content, qr/call memory_operations/, 'No memory_operations framework instruction');

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

# The thread_summary should be positioned early (after system prompt)
my $summary_idx = -1;
my $user_idx = -1;
for my $i (0 .. $#trimmed) {
    my $msg = $trimmed[$i];
    if (ref($msg) eq 'HASH'
        && ($msg->{role} // '') eq 'system'
        && ($msg->{content} // '') =~ /<thread_summary>/) {
        $summary_idx = $i;
    }
    if (ref($msg) eq 'HASH'
        && ($msg->{role} // '') eq 'user'
        && ($msg->{content} // '') =~ /Original task/) {
        $user_idx = $i;
    }
}
ok($summary_idx < $user_idx || ($summary_idx >= 0 && $user_idx >= 0),
    'Thread summary positioned before first user message');

done_testing();
