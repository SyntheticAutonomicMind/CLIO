#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
#
# Test: an output reserve that fills the context window is treated as
# missing, in both places that resolve it.
#
# Some OpenAI-compatible providers publish their context length in the
# output field. Synap's /v1/models reports gpt-oss-20b with
# context_length 65536 and top_provider.max_completion_tokens 65536.
# Reserving the whole window for output leaves the prompt nothing, so
# compute_prompt_budget floors at 1000 tokens - smaller than the system
# prompt, which makes the trim path bail out and lets long sessions
# overflow the window.
#
# Two code paths resolve the reserve and must agree:
#   ModelCapabilitiesManager::_sanitize_token_limits  (capability resolution)
#   TokenEstimator::compute_prompt_budget             (direct callers, e.g.
#                                                      ErrorHandler retry)

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;

use CLIO::Core::ModelCapabilitiesManager;
use CLIO::Memory::TokenEstimator qw(compute_prompt_budget);
use CLIO::Core::Defaults qw(DEFAULT_MAX_OUTPUT_TOKENS DEFAULT_CONTEXT_WINDOW);

my $mcm = bless {}, 'CLIO::Core::ModelCapabilitiesManager';

# ============================================================================
# _sanitize_token_limits: reserve filling the window is reset
# ============================================================================
{
    my $caps = $mcm->_sanitize_token_limits({
        context_window    => 65536,
        max_output_tokens => 65536,
    });
    cmp_ok($caps->{max_output_tokens}, '<', 65536,
        'reserve equal to context window is reset below it');
    is($caps->{max_output_tokens}, DEFAULT_MAX_OUTPUT_TOKENS(),
        'reset lands on DEFAULT_MAX_OUTPUT_TOKENS for a 64K window');
}

# The old code clamped an oversized reserve down to the context window,
# which still filled it and still collapsed the budget.
{
    my $caps = $mcm->_sanitize_token_limits({
        context_window    => 128000,
        max_output_tokens => 131072,
    });
    cmp_ok($caps->{max_output_tokens}, '<', 128000,
        'reserve above context window is reset, not clamped to the window');
}

# Models too small to hold DEFAULT_MAX_OUTPUT_TOKENS get half the window.
{
    my $caps = $mcm->_sanitize_token_limits({
        context_window    => 16384,
        max_output_tokens => 16384,
    });
    is($caps->{max_output_tokens}, 8192,
        'small model falls back to half the window');
}

# ============================================================================
# _sanitize_token_limits: reported values below the window are untouched
# ============================================================================
{
    my @untouched = (
        [ 200000, 64000  ],
        [ 128000, 16384  ],
        [ 1048576, 131072 ],
        [ 32768,  8192   ],
    );
    for my $case (@untouched) {
        my ($ctx, $out) = @$case;
        my $caps = $mcm->_sanitize_token_limits({
            context_window    => $ctx,
            max_output_tokens => $out,
        });
        is($caps->{max_output_tokens}, $out,
            "ctx=$ctx out=$out passes through unchanged");
    }
}

# The hard ceiling still applies before the window check.
{
    my $caps = $mcm->_sanitize_token_limits({
        context_window    => 2000000,
        max_output_tokens => 943717,
    });
    cmp_ok($caps->{max_output_tokens}, '<=', 131072,
        'implausibly large reserve still clamped to MAX_MODEL_OUTPUT_TOKENS');
}

# Unknown output still falls back to the default.
{
    my $caps = $mcm->_sanitize_token_limits({ context_window => 65536 });
    is($caps->{max_output_tokens}, DEFAULT_MAX_OUTPUT_TOKENS(),
        'undefined output falls back to DEFAULT_MAX_OUTPUT_TOKENS');
}

# ============================================================================
# compute_prompt_budget: the Synap shape yields a usable budget
# ============================================================================
{
    my $budget = compute_prompt_budget({
        context_window    => 65536,
        max_output_tokens => 65536,
    });
    cmp_ok($budget, '>', 1000,
        "65536/65536 budget ($budget) is above the 1000-token floor");
    cmp_ok($budget, '>', 8000,
        "65536/65536 budget ($budget) clears a typical system prompt");
}

{
    my $budget = compute_prompt_budget({
        context_window    => 128000,
        max_output_tokens => 131072,
    });
    cmp_ok($budget, '>', 1000,
        "128000/131072 budget ($budget) is above the 1000-token floor");
}

# ============================================================================
# Both paths agree, so the budget does not depend on which caller resolves it
# ============================================================================
{
    my @shapes = (
        [ 65536,   65536   ],
        [ 128000,  131072  ],
        [ 16384,   16384   ],
        [ 32768,   32768   ],
        [ 200000,  64000   ],
        [ 1048576, 131072  ],
        [ 1048576, 16384   ],
    );
    for my $case (@shapes) {
        my ($ctx, $out) = @$case;
        my $resolved = $mcm->_sanitize_token_limits({
            context_window    => $ctx,
            max_output_tokens => $out,
        });
        my $via_mcm  = compute_prompt_budget($resolved);
        my $direct   = compute_prompt_budget({
            context_window    => $ctx,
            max_output_tokens => $out,
        });
        is($via_mcm, $direct,
            "ctx=$ctx out=$out: sanitized and direct budgets agree ($via_mcm)");
        cmp_ok($via_mcm, '>=', 1000,
            "ctx=$ctx out=$out: budget respects the floor");
        cmp_ok($via_mcm, '<=', $ctx,
            "ctx=$ctx out=$out: budget does not exceed the window");
    }
}

# ============================================================================
# Regression guard: every provider default resolves to a usable budget
# ============================================================================
# provider-defaults.json is only a fallback - the live feed is authoritative
# for non-Anthropic providers - so a bad entry there must not be the only
# thing standing between a user and a collapsed budget.
{
    require CLIO::Providers;
    for my $name (CLIO::Providers::list_providers()) {
        my $ctx = CLIO::Providers::default_context_window($name);
        next unless $ctx;
        my $resolved = $mcm->_sanitize_token_limits({
            context_window    => $ctx,
            max_output_tokens => $ctx,
        });
        my $budget = compute_prompt_budget($resolved);
        cmp_ok($budget, '>=', 1000,
            "$name (ctx $ctx) worst-case reserve still leaves a usable budget");
    }
}

done_testing();
