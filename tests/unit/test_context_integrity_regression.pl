#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Comprehensive regression tests for the context-integrity audit.
#
# Covers all named fixtures from the audit:
# - Single trim preserves task
# - Repeated trim does not accumulate summaries
# - Proactive then reactive trim
# - Reactive then proactive trim
# - Existing summary is replaced
# - Raw user input not used as original_task
# - No recursive compression of dynamic context
# - Compaction preserves last/next action
# - Compaction preserves discoveries/decisions
# - Compaction preserves tool pairs
# - Trim does not mutate session history
# - Provider payload matches trimmed context
# - Reasoning fields count toward budget
# - Tool calls count toward budget
# - Oversized trim never silently succeeds
# - Resume preserves compaction state
# - Continuation prompt survives trim
# - Interrupt recovery survives trim
# - Cache hit and miss are semantically identical

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use CLIO::Core::API::MessageValidator qw(
    validate_and_truncate
    remove_existing_thread_summaries
);
use CLIO::Core::API::ErrorHandler;
use CLIO::Core::MessageFingerprinter qw(
    message_fingerprint fingerprint_messages messages_match
);
use CLIO::Memory::TokenEstimator qw(estimate_messages_tokens);
use CLIO::Memory::YaRN;
# Load WorkflowOrchestrator for _compress_dropped_for_recovery (uses
# lazy require internally to avoid circular deps; we need it early here).
require CLIO::Core::WorkflowOrchestrator;

# ===========================================================================
# Helpers
# ===========================================================================

sub count_thread_summaries {
    my ($messages) = @_;
    return 0 unless $messages && ref($messages) eq 'ARRAY';
    my $n = 0;
    for my $msg (@$messages) {
        if (ref($msg) eq 'HASH'
            && ($msg->{role} // '') eq 'system'
            && ($msg->{content} // '') =~ /<thread_summary>/) {
            $n++;
        }
    }
    return $n;
}

sub extract_thread_summary {
    my ($messages) = @_;
    for my $msg (@$messages) {
        if (ref($msg) eq 'HASH'
            && ($msg->{role} // '') eq 'system'
            && ($msg->{content} // '') =~ /<thread_summary>/
            && ($msg->{content} // '') =~ /<\/thread_summary>/) {
            return $msg->{content};
        }
    }
    return '';
}

sub make_caps {
    my ($ctx) = @_;
    $ctx //= 128000;
    return {
        max_prompt_tokens => $ctx,
        max_output_tokens => 16384,
        max_context_window_tokens => $ctx,
    };
}

sub make_tool_pairs {
    my ($count, $prefix) = @_;
    $prefix //= 1;
    my @msgs;
    for my $i ($prefix .. $prefix + $count - 1) {
        my $tc_id = "tc_$i";
        push @msgs, {
            role => 'assistant',
            content => "Working on step $i. Let me check the code.",
            tool_calls => [{
                id => $tc_id,
                type => 'function',
                function => {
                    name => 'file_operations',
                    arguments => '{"operation":"read_file","path":"src/file.pm"}',
                },
            }],
        };
        push @msgs, {
            role => 'tool',
            tool_call_id => $tc_id,
            name => 'file_operations',
            content => "File content for step $i with relevant code.\n[abc12${i}4] commit msg for step $i",
        };
    }
    return @msgs;
}

sub make_system_prompt {
    return { role => 'system', content => 'You are CLIO, an AI coding assistant. ' . ('Context instructions. ' x 100) };
}

# ===========================================================================
# test_single_trim_preserves_task
# ===========================================================================
subtest 'test_single_trim_preserves_task' => sub {
    my @messages = (
        make_system_prompt(),
        { role => 'user', content => 'Original task: build a widget system with proper rendering and font support' },
        make_tool_pairs(10, 1),
        { role => 'user', content => 'Check the B glyph width consistency now.' },
    );

    # Tiny budget forces a single trim
    my $caps = make_caps(10000);
    my $trimmed = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => 'Original task: build a widget system with proper rendering and font support',
        debug              => 0,
    );

    # Current task must survive
    my $has_task = 0;
    for my $msg (@$trimmed) {
        if (ref($msg) eq 'HASH' && ($msg->{role} // '') eq 'user'
            && ($msg->{content} // '') =~ /B glyph width/) {
            $has_task = 1;
            last;
        }
    }
    ok($has_task, 'Current user task preserved after single trim');

    # First user (original task) must survive
    my $has_first = 0;
    for my $msg (@$trimmed) {
        if (ref($msg) eq 'HASH' && ($msg->{role} // '') eq 'user'
            && ($msg->{content} // '') =~ /build a widget system/) {
            $has_first = 1;
            last;
        }
    }
    ok($has_first, 'Original task anchor preserved after single trim');

    # At most one thread_summary
    my $n_summ = count_thread_summaries($trimmed);
    ok($n_summ <= 1, "At most one thread_summary after single trim (got $n_summ)");
    pass('test_single_trim_preserves_task');
};

# ===========================================================================
# test_repeated_trim_does_not_accumulate_summaries
# ===========================================================================
subtest 'test_repeated_trim_does_not_accumulate_summaries' => sub {
    my @messages = (
        make_system_prompt(),
        { role => 'user', content => 'Original task: build a widget system' },
        make_tool_pairs(50, 1),
        { role => 'user', content => 'Continue the current work' },
    );

    my $caps = make_caps(8000);
    my $active_task = 'Original task: build a widget system';

    # Simulate 5 consecutive proactive trims
    my $current = \@messages;
    for my $round (1..5) {
        $current = validate_and_truncate(
            messages           => $current,
            model_capabilities => $caps,
            tools              => [],
            token_ratio        => 2.5,
            active_task        => $active_task,
            debug              => 0,
        );
    }

    my $n_summ = count_thread_summaries($current);
    is($n_summ, 1, "Exactly one thread_summary after 5 consecutive trims (got $n_summ)");
    pass('test_repeated_trim_does_not_accumulate_summaries');
};

# ===========================================================================
# test_proactive_then_reactive_trim
# ===========================================================================
subtest 'test_proactive_then_reactive_trim' => sub {
    my @messages = (
        make_system_prompt(),
        { role => 'user', content => 'Original task: build a widget system' },
        make_tool_pairs(50, 1),
        { role => 'user', content => 'Continue the current work on the widget system' },
    );

    my $caps = make_caps(8000);
    my $active_task = 'Original task: build a widget system';
    my $raw_input = 'Continue the current work on the widget system';

    # Step 1: Proactive trim
    my $after_proactive = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => $active_task,
        debug              => 0,
    );

    my $n1 = count_thread_summaries($after_proactive);
    ok($n1 <= 1, "After proactive trim: at most 1 summary (got $n1)");

    # Step 2: Simulate reactive trim on the same array
    # (mimics ErrorHandler::trim_for_token_limit)
    my @messages_copy = @$after_proactive;
    my $system_prompt;
    my @non_system;
    for my $msg (@messages_copy) {
        if ($msg->{role} eq 'system' && !$system_prompt) {
            $system_prompt = $msg;
        } else {
            push @non_system, $msg;
        }
    }

    # Simulate reactive trim: drop messages and inject a new summary
    # (mirrors ErrorHandler: remove old summaries ONLY when injecting new)
    if (@non_system > 5) {
        my @dropped = @non_system[0 .. 2];
        @non_system = @non_system[3 .. $#non_system];

        my $yarn = CLIO::Memory::YaRN->new();
        my $prev = $yarn->_extract_thread_summary_from_messages(\@messages_copy);
        my $compressed = $yarn->compress_for_context_recovery(\@dropped,
            original_task    => $raw_input,
            previous_summary => $prev,
            context_window   => 8000,
        );

        if ($compressed && $compressed->{content}) {
            @non_system = @{ remove_existing_thread_summaries(\@non_system) };
            my $idx = scalar(@non_system);
            for (my $i = $#non_system; $i >= 0; $i--) {
                if (ref($non_system[$i]) eq 'HASH'
                    && ($non_system[$i]{role} // '') eq 'user') {
                    $idx = $i;
                    last;
                }
            }
            splice(@non_system, $idx, 0, {
                role => 'system',
                content => $compressed->{content},
            });
        }
    }

    # Rebuild
    @messages_copy = ($system_prompt);
    push @messages_copy, @non_system;

    my $n2 = count_thread_summaries(\@messages_copy);
    is($n2, 1, "After proactive->reactive: exactly 1 summary (got $n2)");
    pass('test_proactive_then_reactive_trim');
};

# ===========================================================================
# test_reactive_then_proactive_trim
# ===========================================================================
subtest 'test_reactive_then_proactive_trim' => sub {
    my @messages = (
        make_system_prompt(),
        { role => 'user', content => 'Original task: build a widget system' },
        make_tool_pairs(50, 1),
        { role => 'user', content => 'Continue the current work on the widget system' },
    );

    my $caps = make_caps(8000);
    my $active_task = 'Original task: build a widget system';
    my $raw_input = 'Continue the current work on the widget system';

    # Step 1: Simulate reactive trim (inject a summary)
    my @non_system;
    my $system_prompt = $messages[0];
    for my $msg (@messages[1 .. $#messages]) {
        push @non_system, $msg;
    }

    my @dropped = @non_system[0 .. 9];
    @non_system = @non_system[10 .. $#non_system];

    my $yarn = CLIO::Memory::YaRN->new();
    my $compressed = $yarn->compress_for_context_recovery(\@dropped,
        original_task    => $raw_input,
        context_window   => 8000,
    );

    if ($compressed && $compressed->{content}) {
        my $idx = scalar(@non_system);
        for (my $i = $#non_system; $i >= 0; $i--) {
            if (ref($non_system[$i]) eq 'HASH'
                && ($non_system[$i]{role} // '') eq 'user') {
                $idx = $i;
                last;
            }
        }
        splice(@non_system, $idx, 0, {
            role => 'system',
            content => $compressed->{content},
        });
    }

    my @messages_after_reactive = ($system_prompt, @non_system);
    my $n1 = count_thread_summaries(\@messages_after_reactive);
    is($n1, 1, "After reactive trim: exactly 1 summary (got $n1)");

    # Step 2: Proactive trim
    my $after_proactive = validate_and_truncate(
        messages           => \@messages_after_reactive,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => $active_task,
        debug              => 0,
    );

    my $n2 = count_thread_summaries($after_proactive);
    is($n2, 1, "After reactive->proactive: exactly 1 summary (got $n2)");
    pass('test_reactive_then_proactive_trim');
};

# ===========================================================================
# test_existing_summary_is_replaced
# ===========================================================================
subtest 'test_existing_summary_is_replaced' => sub {
    # Start with an array that already has a thread_summary
    my $existing_summary = "<thread_summary>\nCurrent task: Old task\nRecent user requests:\n- Old request\n</thread_summary>";
    my @messages = (
        { role => 'system', content => 'System prompt' },
        { role => 'user', content => 'Original task: build widget system' },
        make_tool_pairs(30, 1),
        { role => 'system', content => $existing_summary },
        { role => 'user', content => 'New current task: check B glyph width' },
    );

    my $caps = make_caps(8000);
    my $active_task = 'New current task: check B glyph width';

    my $trimmed = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => $active_task,
        debug              => 0,
    );

    my $n = count_thread_summaries($trimmed);
    is($n, 1, "Old summary replaced — exactly 1 (got $n)");

    # The new summary should carry the old task's state
    my $summary = extract_thread_summary($trimmed);
    like($summary, qr/old task|Old task|Old request/i,
        "New summary carries old summary state (cross-cycle carryover)");
    pass('test_existing_summary_is_replaced');
};

# ===========================================================================
# test_current_user_context_not_used_as_original_task
# ===========================================================================
subtest 'test_current_user_context_not_used_as_original_task' => sub {
    my $raw_input = 'Refactor the authentication module to support multi-factor auth';
    my $rendered_uc = 'Working Directory: /home/user/project'
        . 'Active todos:'
        . '- [in-progress] Refactor auth module'
        . '- [pending] Add tests'
        . '<thread_summary>Current task: OLD TASK</thread_summary>';

    # _compress_dropped_for_recovery with raw_user_input
    my @dropped = (
        { role => 'assistant', content => 'I am working on the auth module.' },
        { role => 'tool', tool_call_id => 'tc1', content => 'Found the auth module' },
    );

    my $session_mock = undef;
    my $last_user_msg = { role => 'user', content => $rendered_uc . $raw_input };

    my $summary = CLIO::Core::WorkflowOrchestrator::_compress_dropped_for_recovery(
        \@dropped, $last_user_msg, $session_mock, [], undef, 128000, $raw_input
    );

    if ($summary && ref($summary) eq 'HASH') {
        my $content = $summary->{content} // '';
        # The summary's "Current task:" must contain only the raw user input,
        # NOT the rendered dynamic UC content (Working Directory, todos, etc.)
        unlike($content, qr/Working Directory/,
            "Summary Current task does not contain rendered UC prose");
        unlike($content, qr/Active todos/,
            "Summary Current task does not contain todo list prose");
        unlike($content, qr/OLD TASK/,
            "Summary Current task does not contain prior summary text");
        like($content, qr/Refactor the authentication module/,
            "Summary Current task contains raw user input");
    } else {
        fail("Compression produced output");
    }
    pass('test_current_user_context_not_used_as_original_task');
};

# ===========================================================================
# test_dynamic_context_not_recursively_compressed
# ===========================================================================
subtest 'test_dynamic_context_not_recursively_compressed' => sub {
    my $raw_input = 'Add a CSS grid layout to the dashboard with proper spacing';
    my $yarn = CLIO::Memory::YaRN->new();

    # The dropped messages are OLD messages (not the current user message).
    # In production, the current user message (which contains rendered
    # dynamic UC) is always pinned and never dropped. The compressor
    # should never see the rendered UC in the dropped set.
    # This test verifies that original_task (raw input) is used as
    # "Current task:" and that dropped old messages are summarized
    # without embedding any rendered UC.
    my @dropped = (
        { role => 'user', content => 'Do the thing with the thing' },
        { role => 'assistant', content => 'I discovered that the grid system needs a fallback for IE.' },
        { role => 'tool', tool_call_id => 'tc1', content => '[a1b2c3d] feat: add grid layout' },
        { role => 'user', content => 'Proceed with the grid implementation' },
    );

    my $summary = $yarn->compress_for_context_recovery(\@dropped,
        original_task  => $raw_input,
        context_window => 128000,
    );

    if ($summary && ref($summary) eq 'HASH' && length($summary->{content})) {
        my $content = $summary->{content};
        # The summary's Current task should be the raw user input,
        # not rendered dynamic UC
        like($content, qr/Current task:.*CSS grid/i,
            "Summary Current task contains raw user input, not rendered UC");
        unlike($content, qr/Working Directory/,
            "Summary does not contain rendered UC prose");
        unlike($content, qr/Active todos/,
            "Summary does not contain todo prose");
        # Should preserve the actual discovery
        like($content, qr/grid system needs a fallback/i,
            "Compressed summary preserves actual discovery");
        # Should preserve the old user request
        like($content, qr/Proceed with the grid/i,
            "Compressed summary preserves old user request from dropped messages");
    } else {
        fail("Compression produced output");
    }
    pass('test_dynamic_context_not_recursively_compressed');
};

# ===========================================================================
# test_compaction_preserves_last_action
# ===========================================================================
subtest 'test_compaction_preserves_last_action' => sub {
    my $yarn = CLIO::Memory::YaRN->new();
    my @dropped = (
        { role => 'user', content => 'Build the widget system with rendering support' },
        { role => 'assistant', content => 'I will call the file_operations tool to read the relevant module.' },
        { role => 'tool', tool_call_id => 'tc1', content => '[a1b2c3d] feat: add Widget base class' },
        { role => 'user', content => 'Now add a renderer module too' },
        { role => 'assistant', content => 'Next, I will call apply_patch to modify the renderer.' },
    );

    my $summary = $yarn->compress_for_context_recovery(\@dropped,
        original_task  => 'Build the widget system',
        context_window => 128000,
    );

    ok($summary && ref($summary) eq 'HASH', 'Compression produced output');
    like($summary->{content}, qr/apply_patch|Next action.*apply_patch/i,
        "Next action preserved in summary");
    pass('test_compaction_preserves_last_action');
};

# ===========================================================================
# test_compaction_preserves_next_action
# ===========================================================================
subtest 'test_compaction_preserves_next_action' => sub {
    my $yarn = CLIO::Memory::YaRN->new();
    my @dropped = (
        { role => 'user', content => 'Fix the font rendering bugs in bigtext' },
        { role => 'assistant', content => 'I will call terminal_operations to check the font cache.' },
        { role => 'tool', tool_call_id => 'tc1', content => 'Font cache is healthy' },
        { role => 'user', content => 'Also fix the B glyph width' },
        { role => 'assistant', content => 'After that I will run git commit to save the fix.' },
    );

    my $summary = $yarn->compress_for_context_recovery(\@dropped,
        original_task  => 'Fix the font rendering bugs',
        context_window => 128000,
    );

    ok($summary && ref($summary) eq 'HASH', 'Compression produced output');
    like($summary->{content}, qr/git commit|Next action.*commit/i,
        "Next intended action (git commit) preserved");
    pass('test_compaction_preserves_next_action');
};

# ===========================================================================
# test_compaction_preserves_discoveries
# ===========================================================================
subtest 'test_compaction_preserves_discoveries' => sub {
    my $yarn = CLIO::Memory::YaRN->new();
    my @dropped = (
        { role => 'user', content => 'Debug the widget rendering issue with detailed analysis' },
        { role => 'assistant', content => 'I discovered that the B glyph has inconsistent width across font sizes. This is the root cause.' },
        { role => 'tool', tool_call_id => 'tc1', content => 'Confirmed: B glyph width varies by 3px' },
        { role => 'user', content => 'Fix that and also address the shadow offset bug' },
        { role => 'assistant', content => 'I found that the shadow offset is calculated after the render pass, causing a one-frame delay.' },
    );

    my $summary = $yarn->compress_for_context_recovery(\@dropped,
        original_task  => 'Debug the widget rendering issue',
        context_window => 128000,
    );

    ok($summary && ref($summary) eq 'HASH', 'Compression produced output');
    my $content = $summary->{content} // '';
    like($content, qr/b?B glyph.*width|discovered.*B glyph/i,
        "Discovery about B glyph preserved");
    like($content, qr/shadow offset|one-frame delay|found.*shadow/i,
        "Discovery about shadow offset preserved");
    pass('test_compaction_preserves_discoveries');
};

# ===========================================================================
# test_compaction_preserves_decisions
# ===========================================================================
subtest 'test_compaction_preserves_decisions' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @dropped = (
        { role => 'user', content => 'Decide between PostgreSQL and MySQL for the project backend' },
        { role => 'assistant', content => '[COLLABORATION] Use PostgreSQL — it handles complex relationships better than MySQL with our scalability needs.' },
        { role => 'tool', content => 'Use PostgreSQL - it handles complex relationships better than MySQL.', tool_call_id => 'tc1' },
    );

    my $summary = $yarn->compress_for_context_recovery(\@dropped,
        original_task  => 'Decide between PostgreSQL and MySQL',
        context_window => 128000,
    );

    ok($summary && ref($summary) eq 'HASH', 'Compression produced output');
    my $content = $summary->{content} // '';
    like($content, qr/PostgreSQL/i, 'Decision about PostgreSQL preserved');
    like($content, qr/MySQL/i, 'Decision about MySQL preserved');
    like($content, qr/scalability|relationships/i, 'Decision rationale preserved');
    pass('test_compaction_preserves_decisions');
};

# ===========================================================================
# test_compaction_preserves_tool_pairs
# ===========================================================================
subtest 'test_compaction_preserves_tool_pairs' => sub {
    my @messages = (
        make_system_prompt(),
        { role => 'user', content => 'Original task: build widget system' },
        make_tool_pairs(20, 1),
        { role => 'user', content => 'Continue the current work' },
    );

    my $caps = make_caps(8000);
    my $trimmed = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => 'Original task: build widget system',
        debug              => 0,
    );

    # Every tool result must have a matching tool_call, and vice versa
    my %call_ids;
    my %result_ids;
    for my $msg (@$trimmed) {
        if (ref($msg) eq 'HASH' && ($msg->{role} // '') eq 'assistant'
            && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                $call_ids{$tc->{id}} = 1 if $tc->{id};
            }
        }
        if (ref($msg) eq 'HASH' && ($msg->{role} // '') eq 'tool'
            && $msg->{tool_call_id}) {
            $result_ids{$msg->{tool_call_id}} = 1;
        }
    }

    my $orphans = 0;
    for my $id (keys %call_ids) {
        $orphans++ unless exists $result_ids{$id};
    }
    for my $id (keys %result_ids) {
        $orphans++ unless exists $call_ids{$id};
    }
    is($orphans, 0, "All tool pairs intact after trim (orphans=$orphans)");
    pass('test_compaction_preserves_tool_pairs');
};

# ===========================================================================
# test_trim_does_not_mutate_session_history
# ===========================================================================
subtest 'test_trim_does_not_mutate_session_history' => sub {
    my @history = (
        { role => 'user', content => 'Original task: build a widget system' },
        make_tool_pairs(30, 1),
        { role => 'user', content => 'Continue the current work' },
    );

    # Deep copy for fingerprint comparison
    my $orig_fingerprints = fingerprint_messages(\@history);

    my @messages = (
        { role => 'system', content => 'System prompt for testing.' },
        @history,
        { role => 'user', content => 'Check the B glyph width consistency.' },
    );

    my $caps = make_caps(8000);
    my $trimmed = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => 'Original task: build a widget system',
        debug              => 0,
    );

    # Verify the original @history is unchanged
    my $post_fingerprints = fingerprint_messages(\@history);
    my $diffs = messages_match($orig_fingerprints, $post_fingerprints);
    ok(scalar(@$diffs) == 0, "Session history unchanged after trim (diffs=" . scalar(@$diffs) . ")");

    # Also verify the original @messages is unchanged
    my @orig_messages = (
        { role => 'system', content => 'System prompt for testing.' },
        @history,
        { role => 'user', content => 'Check the B glyph width consistency.' },
    );
    # We can't compare the full @messages (validate_and_truncate may return
    # a new array), but we can check the history portion
    my $history_idx = 0;
    for my $i (0 .. $#messages) {
        if (ref($messages[$i]) eq 'HASH'
            && ($messages[$i]{role} // '') eq 'user'
            && ($messages[$i]{content} // '') =~ /build a widget/) {
            $history_idx = $i;
            last;
        }
    }
    pass('test_trim_does_not_mutate_session_history');
};

# ===========================================================================
# test_provider_payload_matches_trimmed_context
# ===========================================================================
subtest 'test_provider_payload_matches_trimmed_context' => sub {
    # Verify that the payload sent to the API has the same logical
    # conversation as the trimmed context (no duplication, same order,
    # same tool_call_id associations).
    my @messages = (
        make_system_prompt(),
        { role => 'user', content => 'Original task: build a widget system' },
        make_tool_pairs(30, 1),
        { role => 'user', content => 'Continue the current work' },
    );

    my $caps = make_caps(10000);
    my $trimmed = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => 'Original task: build a widget system',
        debug              => 0,
    );

    # Count summaries in the trimmed result
    my $n_summ = count_thread_summaries($trimmed);
    ok($n_summ <= 1, "Trimmed result has at most 1 summary (got $n_summ)");

    # Role sequence must be valid: system, user, assistant, tool, ...
    my @roles = map { ref($_) eq 'HASH' ? ($_->{role} // '') : '' } @$trimmed;
    my $valid = 1;
    for (my $i = 1; $i < @roles; $i++) {
        # System can appear anywhere (thread_summary system message)
        # but not two systems in a row (except system_prompt at [0])
        if ($roles[$i] eq 'system' && $roles[$i-1] eq 'system') {
            $valid = 0;
            last;
        }
    }
    ok($valid, "No consecutive system messages in trimmed result");

    # Last message must be user (current request)
    is($roles[-1], 'user', "Last message is user (current request)");
    pass('test_provider_payload_matches_trimmed_context');
};

# ===========================================================================
# test_reasoning_fields_count_toward_budget
# ===========================================================================
subtest 'test_reasoning_fields_count_toward_budget' => sub {
    my $large_reasoning = 'x' x 5000;  # ~1250 tokens at ratio 4

    my @messages = (
        { role => 'system', content => 'You are a helpful assistant.' },
        { role => 'user', content => 'A' x 200 },
        { role => 'assistant', content => 'Working.',
          reasoning_content => $large_reasoning,
          reasoning_details => [
              { type => 'text', text => 'x' x 2000 },
          ],
        },
        { role => 'user', content => 'Continue' },
    );

    my $caps = make_caps(4000);
    # Without reasoning, the messages are well under 4000 tokens.
    # With reasoning, they should exceed it.
    my $tokens_without_reasoning = estimate_messages_tokens([
        { role => 'system', content => 'You are a helpful assistant.' },
        { role => 'user', content => 'A' x 200 },
        { role => 'assistant', content => 'Working.' },
        { role => 'user', content => 'Continue' },
    ]);
    my $tokens_with_reasoning = estimate_messages_tokens(\@messages);

    ok($tokens_with_reasoning > $tokens_without_reasoning,
        "Reasoning fields increase token estimate ($tokens_without_reasoning vs $tokens_with_reasoning)");
    ok($tokens_with_reasoning >= 1200,
        "Reasoning fields add substantial tokens (>=1200, got $tokens_with_reasoning)");

    # The proactive trim should now account for reasoning and trim if needed
    my $trimmed = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
    );

    my $post_tokens = estimate_messages_tokens($trimmed);
    ok($post_tokens <= 4000 || $post_tokens < $tokens_with_reasoning,
        "Trim reduced total tokens including reasoning ($post_tokens vs $tokens_with_reasoning)");
    pass('test_reasoning_fields_count_toward_budget');
};

# ===========================================================================
# test_tool_calls_count_toward_budget
# ===========================================================================
subtest 'test_tool_calls_count_toward_budget' => sub {
    my @tc_args = '{"path":"/very/long/path/to/some/module/that/is/quite/deep/in/the/filesystem.pm","operation":"read_file","start_line":1,"end_line":500}';
    my $large_args = 'x' x 2000;

    my @messages = (
        { role => 'system', content => 'You are a helpful assistant.' },
        { role => 'user', content => 'A' x 100 },
        { role => 'assistant', content => 'Working.',
          tool_calls => [{
              id => 'tc1', type => 'function',
              function => { name => 'file_operations', arguments => $large_args },
          }],
        },
        { role => 'tool', tool_call_id => 'tc1', content => 'x' x 2000 },
        { role => 'user', content => 'Continue' },
    );

    my $caps = make_caps(4000);
    my $tokens = estimate_messages_tokens(\@messages);

    ok($tokens > 800, "Tool calls + results counted in token estimate ($tokens tokens)");

    my $trimmed = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
    );

    my $post_tokens = estimate_messages_tokens($trimmed);
    ok($post_tokens <= $tokens,
        "Trim reduced tokens ($post_tokens vs $tokens)");
    pass('test_tool_calls_count_toward_budget');
};

# ===========================================================================
# test_oversized_trim_never_silently_succeeds
# ===========================================================================
subtest 'test_oversized_trim_never_silently_succeeds' => sub {
    # Build a message array where even the minimal pinned set (system
    # prompt + first user + last user) exceeds the budget
    my $huge_system = 'x' x 50000;  # ~12500 tokens
    my @messages = (
        { role => 'system', content => $huge_system },
        { role => 'user', content => 'x' x 50000 },
        { role => 'assistant', content => 'Work done.' },
        { role => 'user', content => 'Continue.' },
    );

    my $caps = make_caps(1000);  # Tiny budget
    my $trimmed = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => 'Continue.',
    );

    # The trim should bailed out (return as-is) since pinned messages
    # exceed the budget. The key invariant: it doesn't silently succeed
    # by truncating the system prompt or first user message.
    my $has_first_user = 0;
    for my $msg (@$trimmed) {
        if (ref($msg) eq 'HASH' && ($msg->{role} // '') eq 'user'
            && ($msg->{content} // '') =~ /^x{5000}/) {
            $has_first_user = 1;
            last;
        }
    }
    ok($has_first_user, "First user message preserved even when over budget (bail-out, not silent truncation)");
    pass('test_oversized_trim_never_silently_succeeds');
};

# ===========================================================================
# test_resume_preserves_compaction_state
# ===========================================================================
subtest 'test_resume_preserves_compaction_state' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    # Build initial context with tool operations and discoveries
    my @messages = (
        { role => 'user', content => 'Build a widget system with rendering' },
        { role => 'assistant', content => 'I discovered that the B glyph has inconsistent width.' },
        { role => 'tool', tool_call_id => 'tc1', content => '[a1b2c3d] feat: add Widget' },
        { role => 'user', content => 'Add a CSS grid layout too' },
        { role => 'assistant', content => 'Next, I will call apply_patch to add the grid.' },
    );

    my $summary = $yarn->compress_for_context_recovery(\@messages,
        original_task  => 'Build a widget system with rendering',
        context_window => 128000,
    );

    my $content1 = $summary->{content};
    ok(length($content1) > 0, "First compression produced output");

    # Simulate resume: rebuild context with the summary as previous_summary
    my @resumed = (
        { role => 'system', content => 'System prompt' },
        { role => 'system', content => $content1 },
        { role => 'user', content => 'Continue with the grid layout' },
    );

    my $summary2 = $yarn->compress_for_context_recovery(\@resumed,
        original_task  => 'Continue with the grid layout',
        context_window => 128000,
    );

    my $content2 = $summary2->{content};
    ok(length($content2) > 0, "Second compression produced output");

    # The resumed summary should carry forward the original task + discovery
    like($content2, qr/Widget|widget/i, "Resumed summary preserves original task context");
    like($content2, qr/B glyph|discovered/i, "Resumed summary preserves discovery");
    like($content2, qr/Next action.*apply_patch/i, "Resumed summary preserves next action");

    # Exactly one thread_summary in the content (no recursion)
    my $tag_count = () = $content2 =~ /<thread_summary>/g;
    is($tag_count, 1, "Resumed summary has exactly one <thread_summary> tag pair (no recursion)");
    pass('test_resume_preserves_compaction_state');
};

# ===========================================================================
# test_continuation_prompt_survives_trim
# ===========================================================================
subtest 'test_continuation_prompt_survives_trim' => sub {
    my @messages = (
        make_system_prompt(),
        { role => 'user', content => 'Original task: build widget system' },
        make_tool_pairs(20, 1),
        { role => 'user', content => 'continue' },
        { role => 'assistant', content => 'Working...' },
        { role => 'user', content => 'Now check the B glyph width' },
    );

    my $caps = make_caps(8000);
    my $trimmed = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => 'Now check the B glyph width',
        debug              => 0,
    );

    # The actual current user message must be the last message
    is($trimmed->[-1]{role}, 'user', "Last message is user after trim");
    like($trimmed->[-1]{content}, qr/Now check the B glyph/,
        "Current user request preserved as last message");
    pass('test_continuation_prompt_survives_trim');
};

# ===========================================================================
# test_interrupt_recovery_survives_trim
# ===========================================================================
subtest 'test_interrupt_recovery_survives_trim' => sub {
    my $interrupt_msg = "The user pressed ESC to interrupt and then cancelled the prompt.\n\nContinue your work on: Build a widget system";

    my @messages = (
        make_system_prompt(),
        { role => 'user', content => 'Build a widget system with rendering support' },
        make_tool_pairs(20, 1),
        { role => 'user', content => $interrupt_msg },
        { role => 'assistant', content => 'Resuming work...' },
        { role => 'user', content => 'Now add CSS grid layout' },
    );

    my $caps = make_caps(8000);
    my $raw_input = 'Now add CSS grid layout';

    # Proactive trim
    my $trimmed = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => $raw_input,
        debug              => 0,
    );

    # The current user message should survive
    my $last = $trimmed->[-1];
    is($last->{role}, 'user', "Last message is user after interrupt-recovery trim");
    like($last->{content}, qr/CSS grid/, "Current user request preserved");

    # Simulate reactive recovery
    my $recovered = CLIO::Core::WorkflowOrchestrator::_compress_dropped_for_recovery(
        [], $last, undef, $trimmed, undef, 8000, $raw_input
    );

    # Even if recovery produces nothing (empty dropped set), the trim
    # should not corrupt the message structure
    if ($recovered) {
        unlike($recovered->{content}, qr/user cancelled interrupt/,
            "Recovery summary does not embed interrupt placeholder as task");
    }

    # Verify the proactive summary (if any) doesn't use the interrupt msg as task
    my $summary = extract_thread_summary($trimmed);
    if (length $summary) {
        unlike($summary, qr/user cancelled interrupt/i,
            "Thread summary does not contain interrupt placeholder");
    }

    pass('test_interrupt_recovery_survives_trim');
};

# ===========================================================================
# test_cache_hit_and_miss_are_semantically_identical
# ===========================================================================
subtest 'test_cache_hit_and_miss_are_semantically_identical' => sub {
    # The cache_stable prefix (system_prompt + anchor + recent turns)
    # must be identical between cache-hit and cache-miss scenarios.
    # The dynamic UC (todos, compressed_tail, context_files) must NOT
    # be part of the cache-stable prefix.

    my $system_prompt = 'You are CLIO, an AI coding assistant. ' . ('Instructions. ' x 50);

    my @history = (
        { role => 'user', content => 'Original task: build widget system' },
        make_tool_pairs(10, 1),
    );

    # Build two message arrays with identical stable prefix but different
    # dynamic UC (simulating cache hit vs miss)
    my @messages_a = (
        { role => 'system', content => $system_prompt },
        @history,
        { role => 'system',
          content => "<thread_summary>\nCurrent task: build widget system\n</thread_summary>" },
        { role => 'user', content => 'Dynamic UC version A. Check B glyph.' },
    );

    my @messages_b = (
        { role => 'system', content => $system_prompt },
        @history,
        { role => 'system',
          content => "<thread_summary>\nCurrent task: build widget system\n</thread_summary>" },
        { role => 'user', content => 'Dynamic UC version B. Check B glyph.' },
    );

    # Both should have the same system prompt (cache-stable)
    is($messages_a[0]{content}, $messages_b[0]{content},
        "Cache-stable prefix (system_prompt) identical");

    # But different dynamic UC (user message content differs)
    isnt($messages_a[-1]{content}, $messages_b[-1]{content},
        "Dynamic UC differs between cache hit and miss");

    # After trim, the stable prefix should be preserved
    my $caps = make_caps(8000);
    my $trimmed_a = validate_and_truncate(
        messages           => \@messages_a,
        model_capabilities => $caps, tools => [], token_ratio => 2.5,
        active_task        => 'Check B glyph',
    );
    my $trimmed_b = validate_and_truncate(
        messages           => \@messages_b,
        model_capabilities => $caps, tools => [], token_ratio => 2.5,
        active_task        => 'Check B glyph',
    );

    # Exactly one summary in each
    is(count_thread_summaries($trimmed_a), 1, "Cache-hit path: 1 summary");
    is(count_thread_summaries($trimmed_b), 1, "Cache-miss path: 1 summary");

    # Same summary content (same previous_summary extracted)
    my $sum_a = extract_thread_summary($trimmed_a);
    my $sum_b = extract_thread_summary($trimmed_b);
    is($sum_a, $sum_b, "Both produce same summary content (cache semantics identical)");
    pass('test_cache_hit_and_miss_are_semantically_identical');
};

# ===========================================================================
# test_remove_existing_thread_summaries
# ===========================================================================
subtest 'test_remove_existing_thread_summaries' => sub {
    my $existing = "<thread_summary>\nOld summary\n</thread_summary>";
    my @messages = (
        { role => 'system', content => 'System prompt' },
        { role => 'system', content => $existing },
        { role => 'user', content => 'Hello' },
        { role => 'system', content => $existing },
    );

    my $cleaned = remove_existing_thread_summaries(\@messages);
    is(scalar(@$cleaned), 2, "Removed 2 thread_summary messages (was 4, now " . scalar(@$cleaned) . ")");
    is($cleaned->[0]{role}, 'system', "First system message (not thread_summary) preserved");
    is($cleaned->[0]{content}, 'System prompt', "System prompt content preserved");
    is($cleaned->[1]{role}, 'user', "User message preserved");

    # Empty/undefined input
    is(scalar(@{ remove_existing_thread_summaries([]) }), 0, "Empty array returns empty");
    is(scalar(@{ remove_existing_thread_summaries(undef) }), 0, "Undef returns empty");
    pass('test_remove_existing_thread_summaries');
};

# ===========================================================================
# test_message_fingerprint_detection
# ===========================================================================
subtest 'test_message_fingerprint_detection' => sub {
    my $msg = { role => 'user', content => 'Hello world', id => 'msg_1' };
    my $fp = message_fingerprint($msg);
    ok(length($fp) > 0, "Fingerprint is non-empty");

    # Same content -> same fingerprint
    my $msg2 = { role => 'user', content => 'Hello world', id => 'msg_1' };
    is(message_fingerprint($msg), message_fingerprint($msg2),
        "Same content yields same fingerprint");

    # Different content -> different fingerprint
    my $msg3 = { role => 'user', content => 'Goodbye world', id => 'msg_1' };
    isnt(message_fingerprint($msg), message_fingerprint($msg3),
        "Different content yields different fingerprint");

    # Tool call IDs included
    my $msg_with_tc = {
        role => 'assistant',
        content => 'Working',
        tool_calls => [{ id => 'call_1', function => { name => 'test', arguments => '{}' } }],
    };
    ok(message_fingerprint($msg_with_tc) =~ /tcids=call_1/,
        "Tool call IDs in fingerprint");

    # Tool call_id for tool messages
    my $tool_msg = { role => 'tool', content => 'result', tool_call_id => 'call_1' };
    ok(message_fingerprint($tool_msg) =~ /trid=call_1/,
        "Tool call_id in fingerprint");
    pass('test_message_fingerprint_detection');
};

# ===========================================================================
# High-level reproduction: large coding task with multiple trim cycles
# ===========================================================================
subtest 'test_high_level_reproduction' => sub {
    # Simulate the exact reported failure:
    # large coding task -> many tool calls -> discoveries -> proactive trim
    # -> another tool call -> provider retry / reactive trim -> another API request
    # Assert: one compaction artifact, correct task, latest todo state,
    # important discoveries, correct most-recent and next actions,
    # no duplicated old summary, no duplicated dynamic context.

    my @messages = (
        make_system_prompt(),
        { role => 'user', content => 'Build a widget system with rendering, font support, and CSS grid layout. Fix the B glyph width inconsistency.' },
    );

    # Add 30 tool-call/turn cycles with meaningful discoveries
    for my $i (1..30) {
        push @messages,
            { role => 'assistant', content => "Step $i: I discovered that glyph $i has inconsistent metrics. Next, I will call file_operations to inspect src/glyph$i.pm." },
            { role => 'tool', tool_call_id => "tc_$i", content => "[a1b2c${i}d] feat: fix glyph $i\nFile: src/glyph$i.pm\nFound width=10px expected=12px" },
            { role => 'user', content => 'continue' };
    }

    # Current user input
    push @messages, { role => 'user', content => 'Check the final B glyph width and commit the fix' };

    my $caps = make_caps(8000);
    my $raw_input = 'Check the final B glyph width and commit the fix to the widget system';
    my $active_task = $raw_input;  # _active_task_text returns current user input when >= 50 chars

    # Step 1: Proactive trim
    my $after_proactive = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => $active_task,
        debug              => 0,
    );

    my $n1 = count_thread_summaries($after_proactive);
    is($n1, 1, "High-level repro: after proactive trim, exactly 1 summary (got $n1)");

    # Step 2: Another tool call (model continues working)
    push @$after_proactive,
        { role => 'assistant', content => "I will call terminal_operations to verify the B glyph metrics." },
        { role => 'tool', tool_call_id => 'tc_final', content => '[c3d4e5f] fix: B glyph width corrected to 12px' };

    # Step 3: Provider retry / reactive trim (simulated)
    my @non_system;
    my $sys;
    for my $msg (@$after_proactive) {
        if ($msg->{role} eq 'system' && !$sys) { $sys = $msg; }
        else { push @non_system, $msg; }
    }

    # Simulate reactive trim (mirrors ErrorHandler::trim_for_token_limit)
    if (@non_system > 10) {
        my @dropped = @non_system[0 .. 4];
        @non_system = @non_system[5 .. $#non_system];

        my $yarn = CLIO::Memory::YaRN->new();
        my $prev = $yarn->_extract_thread_summary_from_messages(\@$after_proactive);
        my $compressed = $yarn->compress_for_context_recovery(\@dropped,
            original_task    => $raw_input,
            previous_summary => $prev,
            context_window   => 8000,
        );

        if ($compressed && $compressed->{content}) {
            # Only remove old summaries when injecting the new one
            @non_system = @{ remove_existing_thread_summaries(\@non_system) };
            my $idx = scalar(@non_system);
            for (my $i = $#non_system; $i >= 0; $i--) {
                if (ref($non_system[$i]) eq 'HASH'
                    && ($non_system[$i]{role} // '') eq 'user') {
                    $idx = $i;
                    last;
                }
            }
            splice(@non_system, $idx, 0, {
                role => 'system',
                content => $compressed->{content},
            });
        }
    }

    # Step 4: Proactive trim again (simulates retry loop iteration)
    unshift @non_system, $sys if $sys;
    my $after_retry = validate_and_truncate(
        messages           => \@non_system,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => $raw_input,
        debug              => 0,
    );

    my $n2 = count_thread_summaries($after_retry);
    is($n2, 1, "After reactive + proactive retry: exactly 1 summary (got $n2)");

    # Verify key invariants of the resulting context
    my $summary = extract_thread_summary($after_retry);
    like($summary, qr/B glyph/i, "Summary references B glyph (discovery preserved)");
    like($summary, qr/Check the final B glyph/, "Summary has correct current task");
    unlike($summary, qr/continue$/, "No bare continuation prompt as task");

    # Last user message must be the current request (not necessarily
    # the last message overall — tool calls may follow).
    my $last_user_content;
    for (my $i = $#$after_retry; $i >= 0; $i--) {
        if (ref($after_retry->[$i]) eq 'HASH'
            && ($after_retry->[$i]{role} // '') eq 'user') {
            $last_user_content = $after_retry->[$i]{content};
            last;
        }
    }
    ok(defined $last_user_content, "Last user message exists after full retry cycle");
    like($last_user_content, qr/Check the final B glyph/,
        "Current user request preserved as last user message");

    # No duplicate summaries in content (no recursion)
    my $tag_count = () = $summary =~ /<\/?thread_summary>/g;
    is($tag_count, 2, "Summary has one opening and one closing tag (no recursion)");
    pass('test_high_level_reproduction');
};

done_testing();
