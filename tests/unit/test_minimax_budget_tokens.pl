#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Regression test for MiniMax budget_tokens injection in the thinking parameter.
#
# Without budget_tokens, MiniMax-M3 in interleaved thinking mode emits a brief
# planning one-liner ("Planning X", "Locating Y") instead of the full reasoning
# chain - even when show_thinking=1 and thinking_mode=enabled. With a generous
# budget, M3 emits the verbose reasoning the user asked for.
#
# These tests pin the mapping of thinking_effort (low/medium/high, defaulting
# to high when undef) to budget_tokens (2000/4000/8000) and confirm:
#   - M3 (reasoning_mode=adaptive) maps to type=adaptive with the budget
#   - M2.x (reasoning_mode=enabled) maps to type=enabled with the budget
#   - thinking_mode=disabled sends type=disabled and no budget_tokens
#   - reasoning_split stays true so thinking is separated into reasoning_details

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More tests => 9;

use CLIO::Core::APIManager;

# Stub Config object that exposes the keys adapt_request_for_endpoint reads.
package FakeConfig {
    sub new {
        my ($cls, %opts) = @_;
        return bless { %opts }, $cls;
    }
    sub get {
        my ($self, $key) = @_;
        return $self->{$key};
    }
}

package main;

# Bare-bones APIManager that bypasses new() and only seeds the fields
# adapt_request_for_endpoint touches.
my $am = bless {
    debug => 0,
    api_base => 'https://api.minimax.io/v1/chat/completions',
}, 'CLIO::Core::APIManager';

# Replace _get_reasoning_mode with a stub that returns whatever the test
# set via $reasoning_mode_override (avoids needing a live MCM/Config setup).
my $reasoning_mode_override = 'adaptive';
no warnings 'redefine';
*CLIO::Core::APIManager::_get_reasoning_mode = sub { $reasoning_mode_override };

# Helper: run adapt_request_for_endpoint with a fresh config and capture payload.
sub _run_adapt {
    my (%args) = @_;
    my $payload = $args{payload};
    my $endpoint_config = {
        minimax => 1,
        native_thinking_format => 1,
        sampling_defaults => { temperature => 1.0 },
    };
    $am->{config} = FakeConfig->new(
        thinking_effort => $args{effort},
        show_thinking => $args{show_thinking} // 1,
        thinking_mode => $args{thinking_mode},
    );
    $reasoning_mode_override = $args{reasoning_mode};
    $am->adapt_request_for_endpoint($payload, $endpoint_config);
    return $payload;
}

# Case 1: M3 + enabled + high -> adaptive + 8000 budget
{
    my $payload = { model => 'MiniMax-M3', messages => [] };
    _run_adapt(
        payload => $payload,
        reasoning_mode => 'adaptive',
        thinking_mode => 'enabled',
        effort => 'high',
    );
    is_deeply($payload->{thinking},
        { type => 'adaptive', budget_tokens => 8000 },
        'M3+enabled+high -> adaptive + 8000 budget');
    ok($payload->{reasoning_split},
        'reasoning_split stays true (separates into reasoning_details)');
}

# Case 2: M3 + enabled + low -> adaptive + 2000 budget
{
    my $payload = { model => 'MiniMax-M3', messages => [] };
    _run_adapt(
        payload => $payload,
        reasoning_mode => 'adaptive',
        thinking_mode => 'enabled',
        effort => 'low',
    );
    is_deeply($payload->{thinking},
        { type => 'adaptive', budget_tokens => 2000 },
        'M3+enabled+low -> adaptive + 2000 budget');
}

# Case 3: M3 + enabled + medium -> adaptive + 4000 budget
{
    my $payload = { model => 'MiniMax-M3', messages => [] };
    _run_adapt(
        payload => $payload,
        reasoning_mode => 'adaptive',
        thinking_mode => 'enabled',
        effort => 'medium',
    );
    is_deeply($payload->{thinking},
        { type => 'adaptive', budget_tokens => 4000 },
        'M3+enabled+medium -> adaptive + 4000 budget');
}

# Case 4: disabled -> type=disabled, no budget_tokens
{
    my $payload = { model => 'MiniMax-M3', messages => [] };
    _run_adapt(
        payload => $payload,
        reasoning_mode => 'adaptive',
        thinking_mode => 'disabled',
        effort => 'high',
    );
    is_deeply($payload->{thinking},
        { type => 'disabled' },
        'disabled -> type=disabled, no budget_tokens');
}

# Case 5: M2.x + enabled + high -> enabled + 8000 budget
{
    my $payload = { model => 'MiniMax-M2', messages => [] };
    _run_adapt(
        payload => $payload,
        reasoning_mode => 'enabled',
        thinking_mode => 'enabled',
        effort => 'high',
    );
    is_deeply($payload->{thinking},
        { type => 'enabled', budget_tokens => 8000 },
        'M2.x+enabled+high -> enabled + 8000 budget');
}

# Case 6: effort undef defaults to high budget (8000)
{
    my $payload = { model => 'MiniMax-M3', messages => [] };
    _run_adapt(
        payload => $payload,
        reasoning_mode => 'adaptive',
        thinking_mode => 'enabled',
        effort => undef,
    );
    is_deeply($payload->{thinking},
        { type => 'adaptive', budget_tokens => 8000 },
        'effort undef defaults to high (8000)');
}

# Case 7: budget_tokens keys are present even for show_thinking=0 (auto)
# when thinking_mode=enabled forces it. The whole point of the budget is
# to coax M3 into emitting verbose reasoning, so it must apply whenever
# thinking is on - not only when the user also enabled show_thinking.
{
    my $payload = { model => 'MiniMax-M3', messages => [] };
    _run_adapt(
        payload => $payload,
        reasoning_mode => 'adaptive',
        thinking_mode => 'enabled',
        effort => 'medium',
        show_thinking => 0,
    );
    is_deeply($payload->{thinking},
        { type => 'adaptive', budget_tokens => 4000 },
        'budget_tokens applied even when show_thinking=0 (thinking_mode=enabled forces it)');
}

# Case 8: unknown effort string falls back to the high default (8000)
{
    my $payload = { model => 'MiniMax-M3', messages => [] };
    _run_adapt(
        payload => $payload,
        reasoning_mode => 'adaptive',
        thinking_mode => 'enabled',
        effort => 'turbo',
    );
    is_deeply($payload->{thinking},
        { type => 'adaptive', budget_tokens => 8000 },
        'unknown effort falls back to high default');
}
