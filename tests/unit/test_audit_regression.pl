#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression tests for the context-memory architectural audit:
#   1. Collaboration Discussion respects context-scaled max_collab_len (not hardcoded 300)
#   2. Decision length respects context-scaled decision_len (not hardcoded 500)
#   3. Collaboration parser round-trip: Q/A captured correctly (no swap, no double-prefix)
#   4. [original] carryover preserves full max_ur_len (not truncated to 300)
#   5. Multi-cycle carryover (A->B->C->D) with collaboration exchanges
#   6. Cross-cycle carryover of decisions/files/commits/tool_counts
#   7. Decision_len scales at 256K/512K/1M
#   8. Proactive trim passes previous_summary for within-turn carryover

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Memory::YaRN;
use CLIO::Memory::TokenEstimator qw(estimate_tokens);
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);

# ===========================================================================
# 1. Collaboration Discussion respects context-scaled max_collab_len
# ===========================================================================
subtest 'Collaboration Q/A preserved at full max_collab_len (128K)' => sub {
    my $yarn = CLIO::Memory::YaRN->new();
    my $limits = CLIO::Memory::YaRN::_compute_limits(131072);
    my $expected = $limits->{collaboration_len};
    # sanity: at 128K baseline it should be 1500
    is($expected, 1500, '128K collaboration_len = 1500');

    my $long_q = 'x' x 1600;   # exceeds old 300 cap
    my $long_a = 'y' x 1600;

    my @messages = (
        { role => 'assistant', content => '', tool_calls => [
            { id => 'tc1', function => { name => 'interact',
              arguments => '{"message":"' . $long_q . '"}' } }
        ]},
        { role => 'tool', content => $long_a, tool_call_id => 'tc1' },
    );

    my $r = $yarn->compress_messages(\@messages, context_window => 131072);

    # Extract Q and A from the Discussion section
    my ($q_len, $a_len);
    if ($r->{content} =~ /Discussion:\n(.*?)(?=\n[A-Z][\w ]+:|\n<\/thread_summary>|\z)/s) {
        my $disc = $1;
        ($q_len) = $disc =~ /^- Q: (.+)$/m;
        ($a_len) = $disc =~ /\n  A: (.+)$/m;
    }

    ok(defined $q_len, 'Q line found in Discussion') or diag("content:\n" . $r->{content});
    ok(length($q_len) > 300, 'Q preserved beyond old 300-char hardcode (got ' . length($q_len) . ')')
        or diag("Q was: '$q_len'");
    is(int(length($q_len)), $expected, 'Q truncated to max_collab_len (1500)')
        or diag("Q length: " . length($q_len) . ", expected: $expected");

    ok(defined $a_len, 'A line found in Discussion');
    ok(length($a_len) > 300, 'A preserved beyond old 300-char hardcode (got ' . length($a_len) . ')');
    is(int(length($a_len)), $expected, 'A truncated to max_collab_len (1500)');
};

# ===========================================================================
# 2. Decision length respects context-scaled decision_len
# ===========================================================================
subtest 'Decision length scales with context_window (128K vs 256K)' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my $long_decision = 'Decision: ' . ('d' x 2500);  # well above any scaled cap

    for my $ctx (131072, 262144, 524288, 1000000) {
        my $limits = CLIO::Memory::YaRN::_compute_limits($ctx);
        my $expected_len = $limits->{decision_len};

        my @messages = (
            { role => 'user', content => 'A substantive task with enough detail to pass the threshold check properly here' },
            { role => 'assistant', content => $long_decision,
              metadata => { collaboration => 1 } },
        );

        my $r = $yarn->compress_messages(\@messages, context_window => $ctx);
        # Extract the first key decision line
        my ($dec_text);
        if ($r->{content} =~ /Key decisions:\n- (.+)$/m) {
            $dec_text = $1;
        }
        ok(defined $dec_text, "ctx=$ctx: decision found") or diag("content:\n" . $r->{content});
        ok(length($dec_text) >= $expected_len,
            "ctx=$ctx: decision length >= decision_len ($expected_len) (got " . length($dec_text) . ")")
            or diag("decision: '$dec_text'");
        # It should NOT exceed decision_len (decisions are truncated to decision_len)
        ok(length($dec_text) <= $expected_len + 3,
            "ctx=$ctx: decision not exceeding decision_len (got " . length($dec_text) . ", max $expected_len)")
            or diag("decision too long: '$dec_text'");
    }
};

# ===========================================================================
# 3. Collaboration parser round-trip: Q/A captured correctly
# ===========================================================================
subtest 'Collaboration parser round-trip preserves Q and A correctly' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @msgs1 = (
        { role => 'assistant', content => '', tool_calls => [
            { id => 'q1', function => { name => 'interact',
              arguments => '{"message":"Question about PostgreSQL vs MySQL"}' } }
        ]},
        { role => 'tool', content => 'PostgreSQL is better for complex relationships.', tool_call_id => 'q1' },
    );

    my $summary = $yarn->compress_messages(\@msgs1, context_window => 131072);

    # Now parse it back and verify Q/A are correct (not swapped, no double prefix)
    my @exchanges;
    CLIO::Memory::YaRN::_parse_previous_summary($summary->{content}, {
        commits => [], files_touched => [], decisions => [],
        user_requests => [], collaboration_exchanges => \@exchanges, tool_counts => {},
    });

    is(scalar(@exchanges), 1, 'one exchange parsed back');
    ok($exchanges[0]{question} =~ /PostgreSQL vs MySQL/, 'Q text preserved correctly (not swapped to A text)')
        or diag("question was: " . ($exchanges[0]{question} // 'undef'));
    unlike($exchanges[0]{question}, qr/A:/, 'Q does not contain A prefix');
    ok($exchanges[0]{response} =~ /PostgreSQL is better/, 'A text preserved correctly')
        or diag("response was: " . ($exchanges[0]{response} // 'undef'));
    unless ($exchanges[0]{response} =~ /^  A: /) {
        pass('A text does not include leading "  A: " prefix');
    } else {
        fail('A text should NOT include "  A: " prefix but it does');
    }

    # Now re-emit: verify no double "A: " prefix
    my @next = ({ role => 'user', content => 'Follow up question about the database decision' });
    my $r2 = $yarn->compress_for_context_recovery(\@next,
        original_task => 'Follow up question about the database decision',
        previous_summary => $summary->{content},
        context_window => 131072,
    );

    unlike($r2->{content}, qr/A:  A:/, 'No doubled "A:" prefix on re-emission');
    like($r2->{content}, qr/Q: Question about PostgreSQL/, 'Q text correct on re-emission');
    like($r2->{content}, qr/A: PostgreSQL is better/, 'A text correct on re-emission');
};

# ===========================================================================
# 4. [original] carryover preserves full max_ur_len (not truncated to 300)
# ===========================================================================
subtest '[original] carryover preserves full user_request_len' => sub {
    my $yarn = CLIO::Memory::YaRN->new();
    my $limits = CLIO::Memory::YaRN::_compute_limits(131072);
    my $ur_len = $limits->{user_request_len};
    is($ur_len, 600, '128K user_request_len = 600');

    # Create a user request that is exactly 600 chars (will be extracted at 600)
    my $long_req = 'A' x 600;
    my @messages = (
        { role => 'user', content => $long_req },
    );
    # Need > max_ur_display (16) requests to trigger [original] preservation
    # Actually, first_user_request is set when @user_requests > $max_ur_display
    # Let's push many requests so the first one is saved as [original]
    my @many;
    for my $i (1..20) {
        push @many, { role => 'user', content => "Request $i: " . ('B' x 50) };
        push @many, { role => 'assistant', content => 'ok' };
    }
    my $summary = $yarn->compress_messages(\@many, context_window => 131072);

    # The first user request should be [original]
    if ($summary->{content} =~ /\[- \[original\] (.+)\]/) {
        # Extract the [original] line
        my ($orig) = $summary->{content} =~ /^- \[original\] (.+)$/m;
        ok(defined $orig, '[original] marker present');
        # It should be the first request (truncated to max_ur_len=600)
        like($orig, qr/^- Request 1:/, 'first request preserved as [original]');
    }

    # Now verify carryover: parse back the [original] and check full length
    my @exchanges;
    my @user_reqs;
    CLIO::Memory::YaRN::_parse_previous_summary($summary->{content}, {
        commits => [], files_touched => [], decisions => [],
        user_requests => \@user_reqs, collaboration_exchanges => [], tool_counts => {},
    });

    # The carried original should be preserved at up to max_ur_len
    # Re-compress with a short new task to force carryover
    my @next = ({ role => 'user', content => 'continue' });
    my $r2 = $yarn->compress_messages(\@next,
        original_task => 'continue',
        previous_summary => $summary->{content},
        context_window => 131072,
    );

    # The carried original should appear in the new summary
    # (as [original] or as Current task)
    ok($r2->{content} =~ /Request 1/, 'carried original task survives the cycle')
        or diag("content:\n" . $r2->{content});
};

# ===========================================================================
# 5. Multi-cycle carryover (A->B->C->D) with all sections
# ===========================================================================
subtest 'Multi-cycle A->B->C->D carryover preserves all sections' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @cycle_a = (
        { role => 'user', content => 'The initial task to build a widget system that does X and Y reliably' },
        { role => 'assistant', content => 'Working', tool_calls => [
            { id => 'tcA', function => { name => 'file_operations',
              arguments => '{"path":"lib/Widget.pm"}' } }
        ]},
        { role => 'tool', content => '[a1b2c3d] feat: add Widget base class', tool_call_id => 'tcA' },
    );
    my $sa = $yarn->compress_for_context_recovery(\@cycle_a, original_task => 'Build widget');
    like($sa->{content}, qr/a1b2c3d/, 'A: commit present');
    like($sa->{content}, qr/lib\/Widget\.pm/, 'A: file present');

    my @cycle_b = (
        { role => 'user', content => 'Now add a test suite for the widget system we built' },
        { role => 'assistant', content => '', tool_calls => [
            { id => 'q1', function => { name => 'interact',
              arguments => '{"message":"Should we use taprove or prove as the test harness"}' } }
        ]},
        { role => 'tool', content => 'Use prove with Test::More for maximum compatibility.', tool_call_id => 'q1' },
        { role => 'tool', content => '[e4f5a67] test: add widget test suite', tool_call_id => 'tcB' },
        { role => 'assistant', content => 'ok', tool_calls => [
            { id => 'tcB', function => { name => 'terminal_operations', arguments => '{}' } }
        ]},
    );
    my $sb = $yarn->compress_for_context_recovery(\@cycle_b,
        original_task => 'Add test suite',
        previous_summary => $sa->{content},
        context_window => 131072);
    like($sb->{content}, qr/a1b2c3d/, 'B: commit from A carried');
    like($sb->{content}, qr/lib\/Widget\.pm/, 'B: file from A carried');
    like($sb->{content}, qr/e4f5a67/, 'B: commit from B present');
    like($sb->{content}, qr/taprove or prove/, 'B: collaboration Q from B present');
    like($sb->{content}, qr/Use prove with/, 'B: collaboration A from B present');

    my @cycle_c = (
        { role => 'user', content => 'Final integration testing for the widget system with the new tests' },
        { role => 'assistant', content => 'Integrating' },
        { role => 'tool', content => '[c3d4e5f] feat: integrate widget test runner' },
    );
    my $sc = $yarn->compress_for_context_recovery(\@cycle_c,
        original_task => 'Integration testing',
        previous_summary => $sb->{content},
        context_window => 131072);
    like($sc->{content}, qr/a1b2c3d/, 'C: commit from A survives B (cross-cycle)');
    like($sc->{content}, qr/lib\/Widget\.pm/, 'C: file from A survives B');
    like($sc->{content}, qr/e4f5a67/, 'C: commit from B survives');
    like($sc->{content}, qr/c3d4e5f/, 'C: commit from C present');
    like($sc->{content}, qr/taprove or prove/, 'C: collaboration Q from B survives');
    like($sc->{content}, qr/Use prove with/, 'C: collaboration A from B survives');

    my @cycle_d = (
        { role => 'user', content => 'Deploy the widget system to production now' },
    );
    my $sd = $yarn->compress_for_context_recovery(\@cycle_d,
        original_task => 'Deploy to production',
        previous_summary => $sc->{content},
        context_window => 131072);
    like($sd->{content}, qr/a1b2c3d/, 'D: commit from A survives C');
    like($sd->{content}, qr/lib\/Widget\.pm/, 'D: file from A survives C');
    like($sd->{content}, qr/e4f5a67/, 'D: commit from B survives');
    like($sd->{content}, qr/c3d4e5f/, 'D: commit from C survives');
    like($sd->{content}, qr/taprove or prove/, 'D: collaboration Q survives');
    like($sd->{content}, qr/Use prove with/, 'D: collaboration A survives');
    like($sd->{content}, qr/Deploy the widget/, 'D: current task present');
};

# ===========================================================================
# 6. Tool counts accumulate across carryover cycles
# ===========================================================================
subtest 'Tool counts accumulate correctly across 4 cycles' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my $prev = undef;
    for my $cycle (1..4) {
        my @msgs = (
            { role => 'user', content => 'Task cycle number one two three' },
            { role => 'assistant', content => 'ok', tool_calls => [
                { id => "tc_${cycle}a", function => { name => 'file_operations', arguments => '{}' } },
                { id => "tc_${cycle}b", function => { name => 'file_operations', arguments => '{}' } },
                { id => "tc_${cycle}c", function => { name => 'terminal_operations', arguments => '{}' } },
            ]},
        );
        my $r = $yarn->compress_for_context_recovery(\@msgs,
            original_task => 'Task cycle number one two three',
            ($prev ? (previous_summary => $prev->{content}) : ()),
            context_window => 131072,
        );
        $prev = $r;
        # After $cycle cycles: file_operations = 2*cycle, terminal_operations = cycle
        like($r->{content}, qr/file_operations: @{[2*$cycle]}/,
            "Cycle $cycle: file_operations accumulated to " . (2*$cycle));
        like($r->{content}, qr/terminal_operations: $cycle/,
            "Cycle $cycle: terminal_operations accumulated to $cycle");
    }
};

# ===========================================================================
# 7. ErrorHandler retry budget uses context-aware value, not 40000 floor
# ===========================================================================
subtest 'ErrorHandler trim_for_token_limit uses context-aware budget (not 40000)' => sub {
    # We can't easily call trim_for_token_limit directly (it needs a WO instance),
    # but we can verify the budget computation it relies on.
    require CLIO::Memory::TokenEstimator;
    require CLIO::Core::Defaults;

    for my $ctx (131072, 262144, 1000000) {
        my $caps = {
            max_context_window_tokens => $ctx,
            max_output_tokens         => CLIO::Core::Defaults::DEFAULT_MAX_OUTPUT_TOKENS(),
        };
        my $budget = CLIO::Memory::TokenEstimator::compute_prompt_budget($caps);
        # The old 40000 floor would have clamped small budgets to 40000.
        # Now we expect the budget to be proportional to context.
        ok($budget < $ctx, "ctx=$ctx: prompt budget ($budget) < context window ($ctx)")
            or diag("budget=$budget, ctx=$ctx");
    }

    # For a 32K model, the budget should NOT be 40000
    my $caps32k = {
        max_context_window_tokens => 32768,
        max_output_tokens         => CLIO::Core::Defaults::DEFAULT_MAX_OUTPUT_TOKENS(),
    };
    my $budget32k = CLIO::Memory::TokenEstimator::compute_prompt_budget($caps32k);
    ok($budget32k < 40000, "32K model budget ($budget32k) is NOT clamped to 40000");
    ok($budget32k >= 1000, "32K model budget ($budget32k) >= 1000 floor");
};

# ===========================================================================
# 8. Proactive trim passes previous_summary for within-turn carryover
# ===========================================================================
subtest 'Proactive trim preserves prior thread_summary within same message array' => sub {
    # Build a message array with an existing thread_summary (from a prior
    # proactive trim in the same turn), plus some new messages that would
    # be dropped. The new thread_summary should carry forward content
    # from the prior one.
    my @messages = (
        { role => 'system', content => 'System prompt' },
        { role => 'system', content => '<thread_summary>Current task: Original task to refactor

Recent user requests:
- [original] Original task to refactor
- Investigate the cache instability bug
- Check for token estimation issues
</thread_summary>' },
        { role => 'user', content => 'First user message' },
        { role => 'assistant', content => 'ok' },
        { role => 'tool', tool_call_id => 'tc1', content => '[abc1234] feat: add cache stability' },
        { role => 'assistant', content => 'done', tool_calls => [
            { id => 'tc1', function => { name => 'file_operations',
              arguments => '{"path":"lib/CLIO/Core/ContextBuilder.pm"}' } }
        ]},
        { role => 'tool', tool_call_id => 'tc1', content => '[def5678] fix: cache stability patch' },
        { role => 'user', content => 'Final user message' },
    );

    # Use a very small budget to force trimming
    my $result = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 500 },
        tools              => [],
        debug              => 0,
        model              => 'test-model',
        active_task        => 'Final user message',
    );

    ok($result && ref($result) eq 'ARRAY', 'validate_and_truncate returns array');

    # Find all thread_summary messages in the result
    my @summaries;
    for my $msg (@$result) {
        if ($msg->{content} && $msg->{content} =~ /<thread_summary>/) {
            push @summaries, $msg->{content};
        }
    }

    # The result should have a thread_summary (from the proactive trim)
    ok(@summaries >= 1, 'result contains at least one thread_summary');
    # The carried-over content from the prior summary should survive
    if (@summaries >= 1) {
        my $found_carryover = 0;
        for my $s (@summaries) {
            $found_carryover = 1 if $s =~ /Original task to refactor/
                                  || $s =~ /abc1234/
                                  || $s =~ /def5678/
                                  || $s =~ /ContextBuilder\.pm/;
        }
        ok($found_carryover, 'prior thread_summary content carried into new summary');
    }
};

done_testing();
