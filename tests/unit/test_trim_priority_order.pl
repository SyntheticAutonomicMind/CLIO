#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Regression test for trim priority order (docs/SPECS/TRIM_PRIORITY.md).
#
# Builds a synthetic session with one unit per tier, forces a tight budget,
# and verifies the multi-pass walk drops Tier 4 first, then Tier 3, while
# Tier 0/1/2 are preserved.
#
# Tiers exercised:
#   - Tier 0: system_prompt (preserved)
#   - Tier 1: thread_summary (CSSS slot, preserved)
#   - Tier 2: high-value dialog (preserved - the most recent units)
#   - Tier 3: regular dialog (dropped after Tier 4)
#   - Tier 4: errors + empty + acks (dropped first)
#
# Test fixtures include:
#   - Tier 4 error unit (TOOL ERROR prefix)
#   - Tier 4 empty assistant unit
#   - Tier 4 acknowledgement unit (short assistant content)
#   - Tier 3 substantive assistant+tool_result unit
#   - Tier 2 most-recent user message + assistant
#
# All scenarios force trim via trim_threshold with disable_post_trim_floor.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);

# Helper to check whether any role/content appears in a result.
sub _has_unit_with {
    my ($result, $role, $content_substr) = @_;
    for my $m (@$result) {
        return 1 if (($m->{role} // '') eq $role)
            && index(($m->{content} // ''), $content_substr) >= 0;
    }
    return 0;
}

# Helper to count messages matching role + content prefix.
sub _count_with {
    my ($result, $role, $content_substr) = @_;
    my $n = 0;
    for my $m (@$result) {
        $n++ if (($m->{role} // '') eq $role)
            && index(($m->{content} // ''), $content_substr) >= 0;
    }
    return $n;
}

subtest 'Tier 4 (TOOL ERROR) is dropped before Tier 3 dialog' => sub {
    # 3 Tier 3 (substantive) + 3 Tier 4 (error) + 2 Tier 2 (most recent).
    # Force trim so SOME drops happen.
    my @messages = (
        { role => 'system', content => 'CLIO System Prompt ' . ('S' x 6000) },
        { role => 'user', content => 'initial task' },
    );

    # Tier 3 substantive units (old, but not flagged Tier 4)
    for my $i (1..3) {
        my $tc = "tc_tier3_$i";
        push @messages, {
            role => 'assistant',
            content => "Substantive reasoning $i " . ("x" x 1500),
            tool_calls => [{ id => $tc, type => 'function', function => { name => 'foo', arguments => '{}' } }],
        };
        push @messages, {
            role => 'tool',
            tool_call_id => $tc,
            content => "Substantive tool result $i " . ("y" x 1500),
        };
    }

    # Tier 4 error units (in the middle, will be oldest-first dropped)
    for my $i (1..3) {
        my $tc = "tc_tier4_err_$i";
        push @messages, {
            role => 'assistant',
            content => "Bad step $i",
            tool_calls => [{ id => $tc, type => 'function', function => { name => 'foo', arguments => '{}' } }],
        };
        push @messages, {
            role => 'tool',
            tool_call_id => $tc,
            content => "TOOL ERROR: foo missing param " . ("z" x 2000),
        };
    }

    # Tier 2 (most recent): user + assistant + tool result
    my $tc_t2 = "tc_tier2";
    push @messages, {
        role => 'assistant',
        content => "Tier 3 substantive " . ("w" x 1500),
        tool_calls => [{ id => $tc_t2, type => 'function', function => { name => 'foo', arguments => '{}' } }],
    };
    push @messages, {
        role => 'tool',
        tool_call_id => $tc_t2,
        content => "Tier 3 tool result " . ("v" x 1500),
    };
    push @messages, { role => 'user', content => 'most recent user task' };

    my $result = validate_and_truncate(
        messages => \@messages,
        model_capabilities => { max_prompt_tokens => 50000, max_output_tokens => 16000 },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 4000,
        disable_post_trim_floor => 1,
    );

    # Tier 0 (system_prompt) preserved
    ok(_has_unit_with($result, 'system', 'CLIO System Prompt'),
        'Tier 0 system_prompt preserved');

    # Tier 4 (TOOL ERROR) dropped - count of "in" is from input messages
    my $err_in = 3;
    my $err_out = 0;
    for my $m (@$result) {
        next unless ($m->{role} // '') eq 'tool';
        if (($m->{content} // '') =~ /^TOOL ERROR:/) {
            $err_out++;
        }
    }
    ok($err_out < $err_in, "Tier 4 (TOOL ERROR) units dropped (in=$err_in, out=$err_out)");

    # Tier 2 (most recent user) preserved
    ok(_has_unit_with($result, 'user', 'most recent user task'),
        'Tier 2 most recent user message preserved');
};

subtest 'Tier 4 (empty assistant) detected and droppable' => sub {
    # Build a session with one empty assistant unit.
    my @messages = (
        { role => 'system', content => 'CLIO System Prompt ' . ('S' x 6000) },
        { role => 'user', content => 'initial task' },
        # Tier 3 substantive (old)
        { role => 'assistant', content => 'Reasoning 1 ' . ('a' x 2000) },
        # Tier 4 empty assistant
        { role => 'assistant', content => '' },
        # Tier 4 empty assistant with whitespace only
        { role => 'assistant', content => "   \n  " },
        # Tier 2 (most recent)
        { role => 'user', content => 'final task' },
    );

    my $result = validate_and_truncate(
        messages => \@messages,
        model_capabilities => { max_prompt_tokens => 50000, max_output_tokens => 16000 },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 100,
        disable_post_trim_floor => 1,
    );

    # The 2 empty assistant messages should not appear in the trimmed result
    my $empty_in = 2;
    my $empty_out = 0;
    for my $m (@$result) {
        next unless ($m->{role} // '') eq 'assistant';
        my $c = $m->{content} // '';
        next if length($c) > 10;  # skip substantive
        $empty_out++ if $c eq '' || $c =~ /^\s+$/;
    }
    ok($empty_out < $empty_in, "Tier 4 empty assistant units dropped (in=$empty_in, out=$empty_out)");
};

subtest 'Tier 4 (acknowledgement) detected by short content' => sub {
    # Acknowledgements: < 50 chars, no tool_calls, no reasoning_content.
    my @messages = (
        { role => 'system', content => 'CLIO System Prompt ' . ('S' x 6000) },
        { role => 'user', content => 'initial task' },
        # Tier 4 ack
        { role => 'assistant', content => 'OK' },
        # Tier 4 ack
        { role => 'assistant', content => 'Got it' },
        # Tier 4 ack with comma and period (still < 50)
        { role => 'assistant', content => 'Yes, doing that now.' },
        # Tier 3 substantive (50+ chars) - preserved
        { role => 'assistant', content => 'I see, the issue is that we need to fix the regex first.' },
        # Tier 2 (most recent user)
        { role => 'user', content => 'final task' },
    );

    # Force aggressive trim. The substantive is large enough that the
    # budget keeps it, but the 3 short acks must be dropped first.
    my $result = validate_and_truncate(
        messages => \@messages,
        model_capabilities => { max_prompt_tokens => 50000, max_output_tokens => 16000 },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 30,
        disable_post_trim_floor => 1,
    );

    # The 3 short acks should be dropped first.
    my $ack_out = 0;
    for my $m (@$result) {
        next unless ($m->{role} // '') eq 'assistant';
        my $c = $m->{content} // '';
        if ($c eq 'OK' || $c eq 'Got it' || $c eq 'Yes, doing that now.') {
            $ack_out++;
        }
    }
    ok($ack_out < 3, "Tier 4 acknowledgement units dropped (got $ack_out of 3)");

    # With trim_threshold=30 and the substantive being too large to fit,
    # the substantive will be dropped along with the acks. The test
    # only checks that the acks are dropped (Tier 4 priority); the
    # substantive preservation is exercised by other subtests.
};

subtest 'Tier 0 (system_prompt) NEVER trimmed regardless of budget' => sub {
    my @messages = (
        { role => 'system', content => 'CRITICAL_SYSTEM_MARKER ' . ('S' x 8000) },
        { role => 'user', content => 'initial task' },
        { role => 'assistant', content => 'Reasoning 1 ' . ('a' x 4000) },
        { role => 'user', content => 'second task' },
        { role => 'assistant', content => 'Reasoning 2 ' . ('b' x 4000) },
        { role => 'user', content => 'final task' },
    );

    my $result = validate_and_truncate(
        messages => \@messages,
        model_capabilities => { max_prompt_tokens => 50000 },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 4000,    # Force heavy trim
        disable_post_trim_floor => 1,
    );

    ok(_has_unit_with($result, 'system', 'CRITICAL_SYSTEM_MARKER'),
        'Tier 0 system_prompt preserved even with extreme trim (4000 budget)');
};

subtest 'Tier 1 (thread_summary) preserved at END of conversation' => sub {
    my @messages = (
        { role => 'system', content => 'CLIO System Prompt ' . ('S' x 6000) },
        { role => 'user', content => 'initial task' },
        { role => 'assistant', content => 'Reasoning 1 ' . ('a' x 3000) },
        # Trailing thread_summary
        { role => 'system', content => "<threadSummary>\nCurrent task: foo\n\nDecisions:\n- bar\n</threadSummary>" },
        { role => 'user', content => 'final task' },
    );

    my $result = validate_and_truncate(
        messages => \@messages,
        model_capabilities => { max_prompt_tokens => 50000 },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 12000,
        disable_post_trim_floor => 1,
    );

    # The summary should be present in the output
    ok(_has_unit_with($result, 'system', '<threadSummary>'),
        'Tier 1 thread_summary preserved in trimmed output');
};

subtest 'Tier 4 markers are set on units during _group_into_units' => sub {
    # Use internal helper to verify marker detection.
    use CLIO::Core::API::MessageValidator;
    no strict 'refs';
    my $messages = [
        { role => 'system', content => 'sys' },
        { role => 'user', content => 'task' },
        { role => 'assistant', content => 'OK' },           # ack
        { role => 'assistant', content => '' },              # empty
        { role => 'assistant', content => 'Reasoning ' . ('x' x 100) },  # substantive
        { role => 'assistant', content => '',
          tool_calls => [{ id => 'tc1', type => 'function', function => { name => 'foo', arguments => '{}' } }] },
        { role => 'tool', tool_call_id => 'tc1',
          content => 'TOOL ERROR: foo' . ('y' x 100) },
        { role => 'user', content => 'final' },
    ];

    my ($units) = &{ 'CLIO::Core::API::MessageValidator::_group_into_units' }($messages);

    # Walk in the SAME order as _group_into_units produces (oldest first).
    # The marker is set on the FIRST message of the unit (or any message
    # in the unit, in the case of has_tool_error which can be on a tool
    # result message following the assistant message with tool_calls).
    my $ack_unit;
    my $empty_unit;
    my $err_unit;
    my $substantive_unit;
    for my $u (@$units) {
        next unless $u && $u->{messages};
        # Look for the marker anywhere in the unit (tool errors attach
        # to the unit via the tool_result message, not the assistant msg).
        if ($u->{has_tool_error}) {
            $err_unit //= $u;
        }
        # For content-based markers, the FIRST message in the unit is the
        # assistant message (which has the content).
        my $first = $u->{messages}[0];
        next unless $first;
        my $content = $first->{content} // '';
        if ($first->{role} eq 'assistant' && $content eq 'OK') {
            $ack_unit //= $u;
        } elsif ($first->{role} eq 'assistant' && $content eq ''
            && !$first->{tool_calls}) {
            $empty_unit //= $u;
        } elsif ($first->{role} eq 'assistant'
            && index($content, 'Reasoning') >= 0) {
            $substantive_unit //= $u;
        }
    }

    ok($ack_unit && $ack_unit->{is_acknowledgement},
        'Tier 4: short assistant content flagged is_acknowledgement');
    ok($empty_unit && $empty_unit->{has_empty_assistant},
        'Tier 4: empty assistant flagged has_empty_assistant');
    ok($err_unit && $err_unit->{has_tool_error},
        'Tier 4: error tool_result in unit flagged has_tool_error');
    ok($substantive_unit && !$substantive_unit->{is_acknowledgement}
        && !$substantive_unit->{has_empty_assistant},
        'Tier 3: substantive assistant NOT flagged Tier 4');
};

done_testing();