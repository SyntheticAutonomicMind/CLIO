#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_context_command_display.pl - /context renders the enforced budget

The memory view used to derive its own threshold from SAFE_CONTEXT_PERCENT
and label max_prompt_tokens as the context window. It now renders the
recorded per-request plan, so the displayed budget is the budget that was
enforced. These tests pin that behaviour.

=cut

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;

use CLIO::Session::State;
use CLIO::UI::Commands::Context;

# ---------------------------------------------------------------------------
# Fake chat: capture everything the command writes.
# ---------------------------------------------------------------------------

{
    package FakeChat;

    sub new { return bless { lines => [] }, shift }

    sub writeline {
        my ($self, $text, %opts) = @_;
        push @{$self->{lines}}, defined $text ? $text : '';
        return;
    }

    sub colorize {
        my ($self, $text) = @_;
        return defined $text ? $text : '';
    }

    sub lines { return @{ $_[0]{lines} } }

    package FakeSession;

    sub new { return bless { state => $_[1] }, shift }
    sub state { return $_[0]{state} }
}

sub rendered {
    my ($state) = @_;
    my $chat = FakeChat->new();
    my $cmd = CLIO::UI::Commands::Context->new(
        chat    => $chat,
        session => FakeSession->new($state),
    );
    $cmd->_display_memory_stats();
    return join("\n", $chat->lines());
}

sub make_state {
    my $state = CLIO::Session::State->new(session_id => 'test-context-display');
    $state->{history} = [ { role => 'user', content => 'hi' } ];
    return $state;
}

subtest 'renders the enforced plan' => sub {
    my $state = make_state();
    $state->record_context_stats({
        timestamp => time(),
        model     => 'openrouter/vendor/model',
        budget    => {
            context_window  => 1048576,
            prompt_budget   => 866304,
            tool_tokens     => 18996,
            effective_limit => 847308,
            trim_target     => 635481,
            estimated_after => 240000,
            trimmed         => 0,
            breakdown       => {
                messages => 10,
                total    => 240000,
                roles    => {
                    system    => { messages => 1, total => 14577, content => 14577, tool_calls => 0, reasoning => 0 },
                    assistant => { messages => 4, total => 79247, content => 3219, tool_calls => 75935, reasoning => 90 },
                    tool      => { messages => 4, total => 137297, content => 136948, tool_calls => 0, reasoning => 0 },
                    user      => { messages => 1, total => 926, content => 923, tool_calls => 0, reasoning => 0 },
                },
                tool_call_tokens => 75935,
                reasoning_tokens => 90,
            },
        },
        projection => {
            recent_turns => 3, recent_messages => 347,
            dropped_messages => 0, compressed_tail_chars => 0,
        },
        usage_prompt_tokens     => 244703,
        usage_completion_tokens => 395,
        usage_cached_tokens     => 240000,
    });

    my $out = rendered($state);
    like($out, qr/Context window:\s+1\.0M/, 'context window shown in full');
    like($out, qr/Effective limit:\s+847K/, 'effective limit shown');
    like($out, qr/Trim target:\s+635K/, 'trim target shown');
    like($out, qr/244\.7K|245K/, 'provider-reported prompt tokens shown');
    like($out, qr/Composition:/, 'composition section rendered');
    like($out, qr/Healthy/, 'status healthy under the trim target');

    $state->cleanup();
};

subtest 'reports an over-budget state' => sub {
    my $state = make_state();
    $state->record_context_stats({
        timestamp => time(),
        model     => 'openrouter/vendor/model',
        budget    => {
            context_window  => 100000,
            prompt_budget   => 80000,
            tool_tokens     => 5000,
            effective_limit => 75000,
            trim_target     => 56250,
            estimated_after => 90000,
            trimmed         => 0,
        },
        usage_prompt_tokens => 0,
    });

    my $out = rendered($state);
    like($out, qr/OVER BUDGET/, 'over-budget state is explicit');

    $state->cleanup();
};

subtest 'renders with no recorded request' => sub {
    my $state = make_state();
    my $out = rendered($state);
    like($out, qr/Status:/, 'status rendered without a plan');
    unlike($out, qr/Effective limit:/, 'plan fields omitted when no request was recorded');
    $state->cleanup();
};

done_testing();
