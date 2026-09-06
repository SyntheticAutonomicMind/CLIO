#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: the dynamic userContext must sit at the recency
# anchor (tail) before each API call, not at its initial position.
#
# Old bug: the UC was pushed before user_input and tracked via an
# index. After tool execution appended assistant/tool messages, the
# UC was displaced from the tail. The fix moved it via splice+push,
# but that relied on fragile _dynamic_usercontext_idx tracking that
# could get stale after trims.
#
# New approach: _build_turn_context pushes user_input first, then
# the UC at the tail. On each subsequent iteration, the per-iteration
# refresh calls _replace_dynamic_usercontext which removes the old UC
# (by content: system msg that's not [0] and not <thread_summary>)
# and appends a fresh one at the tail. No index tracking needed.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::WorkflowOrchestrator;
use CLIO::Core::MessageHistory qw(messages_to_prose_dynamic);

# Build a minimal projection that produces non-empty prose.
sub make_proj {
    return {
        active_task => 'Fix bug X',
        environment => {
            working_directory => '/tmp',
            language          => 'English',
            datetime_iso      => '2026-09-06T12:00:00',
        },
    };
}

# --- Test 1: _replace_dynamic_usercontext removes old UC and appends at tail ---
subtest '_replace_dynamic_usercontext removes old UC and appends at tail' => sub {
    my @messages = (
        { role => 'system', content => 'STATIC_SYSTEM_PROMPT' },
        { role => 'user',    content => 'TURN_0_USER' },
        { role => 'assistant', content => 'Turn 0 response', tool_calls => [{ id => 'tc_1', function => { name => 'foo' } }] },
        { role => 'tool',    content => 'tool result 1', tool_call_id => 'tc_1' },
        # Old dynamic UC in the middle (simulating post-trim position).
        { role => 'system', content => 'OLD_DYNAMIC_UC' },
        { role => 'user',    content => 'CURRENT_USER_INPUT' },
    );

    my $wo = bless {}, 'CLIO::Core::WorkflowOrchestrator';
    $wo->{_current_projection} = make_proj();
    my $refreshed = messages_to_prose_dynamic($wo->{_current_projection});
    ok(length($refreshed) > 0, 'rendered UC is non-empty');

    $wo->_replace_dynamic_usercontext(\@messages, $refreshed);

    # The old UC should be gone.
    my $old_count = grep { $_->{role} eq 'system' && $_->{content} eq 'OLD_DYNAMIC_UC' } @messages;
    is($old_count, 0, 'old dynamic UC was removed');

    # The system_prompt at [0] should be preserved.
    is($messages[0]{content}, 'STATIC_SYSTEM_PROMPT', 'system_prompt preserved at index 0');

    # The fresh UC should be at the tail.
    is($messages[-1]{role}, 'system', 'UC is at the tail (recency anchor)');
    like($messages[-1]{content}, qr/Working directory/, 'UC content is the fresh render');

    # Thread_summary messages should also be preserved (not treated as UC).
    my @with_summary = (
        { role => 'system', content => 'STATIC_SYSTEM_PROMPT' },
        { role => 'user',    content => 'hi' },
        { role => 'system', content => '<thread_summary>Summary of old turns</thread_summary>' },
        { role => 'system', content => 'OLD_UC' },
    );
    $wo->_replace_dynamic_usercontext(\@with_summary, $refreshed);
    my $summary_count = grep { $_->{content} =~ /<thread_summary>/ } @with_summary;
    is($summary_count, 1, 'thread_summary system message preserved');
    is($with_summary[0]{content}, 'STATIC_SYSTEM_PROMPT', 'system_prompt preserved with thread_summary present');
    my $uc_count = grep { $_->{role} eq 'system' && $_->{content} !~ /<thread_summary>/ && $_->{content} ne 'STATIC_SYSTEM_PROMPT' } @with_summary;
    is($uc_count, 1, 'exactly one dynamic UC after replace');
};

# --- Test 2: _replace_dynamic_usercontext with empty content just removes ---
subtest '_replace_dynamic_usercontext with empty content removes old UC' => sub {
    my @messages = (
        { role => 'system', content => 'STATIC_SYSTEM_PROMPT' },
        { role => 'user',    content => 'hi' },
        { role => 'system', content => 'OLD_UC' },
    );
    my $wo = bless {}, 'CLIO::Core::WorkflowOrchestrator';
    $wo->_replace_dynamic_usercontext(\@messages, '');
    my $uc_count = grep { $_->{role} eq 'system' && $_->{content} eq 'OLD_UC' } @messages;
    is($uc_count, 0, 'old UC removed when content is empty');
    is(scalar(@messages), 2, 'only system_prompt and user remain');
};

# --- Test 3: _ensure_dynamic_usercontext_at_tail is a no-op when UC exists ---
subtest '_ensure_dynamic_usercontext_at_tail is no-op when UC present' => sub {
    my @messages = (
        { role => 'system', content => 'STATIC_SYSTEM_PROMPT' },
        { role => 'user',    content => 'hi' },
        { role => 'system', content => 'Dynamic UC content' },
    );
    my $wo = bless {}, 'CLIO::Core::WorkflowOrchestrator';
    $wo->{_current_projection} = make_proj();
    my $before = scalar(@messages);
    $wo->_ensure_dynamic_usercontext_at_tail(\@messages);
    is(scalar(@messages), $before, 'no new UC added when one already exists');
};

# --- Test 4: _ensure_dynamic_usercontext_at_tail restores missing UC ---
subtest '_ensure_dynamic_usercontext_at_tail restores missing UC' => sub {
    my @messages = (
        { role => 'system', content => 'STATIC_SYSTEM_PROMPT' },
        { role => 'user',    content => 'hi' },
        { role => 'tool',    content => 'result', tool_call_id => 'tc_1' },
    );
    my $wo = bless {}, 'CLIO::Core::WorkflowOrchestrator';
    $wo->{_current_projection} = make_proj();
    my $before = scalar(@messages);
    $wo->_ensure_dynamic_usercontext_at_tail(\@messages);
    is(scalar(@messages), $before + 1, 'UC added when missing');
    like($messages[-1]{content}, qr/Working directory/, 'restored UC at tail has environment content');
};

# --- Test 5: idempotency — calling replace twice doesn't duplicate UC ---
subtest 'idempotent: calling replace twice does not duplicate UC' => sub {
    my @messages = (
        { role => 'system', content => 'STATIC_SYSTEM_PROMPT' },
        { role => 'user',    content => 'hi' },
    );
    my $wo = bless {}, 'CLIO::Core::WorkflowOrchestrator';
    $wo->{_current_projection} = make_proj();
    my $refreshed = messages_to_prose_dynamic($wo->{_current_projection});
    $wo->_replace_dynamic_usercontext(\@messages, $refreshed);
    my $uc_count_1 = grep { $_->{role} eq 'system' && $_->{content} !~ /<thread_summary>/ && $_ ne $messages[0] } @messages;
    is($uc_count_1, 1, 'one UC after first replace');
    $wo->_replace_dynamic_usercontext(\@messages, $refreshed);
    my $uc_count_2 = grep { $_->{role} eq 'system' && $_->{content} !~ /<thread_summary>/ && $_ ne $messages[0] } @messages;
    is($uc_count_2, 1, 'still one UC after second replace (idempotent)');
};

done_testing();
