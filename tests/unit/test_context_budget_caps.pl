#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for capability and budget values that decide when context is trimmed.
#
# 1. An OpenAI-compatible model listing that reports `max_tokens` (an
#    output cap) but no context field must not be read as a tiny context
#    window. Reading it that way made a 1M-context model look like an 8K
#    model.
# 2. MessageValidator must default the chars/token ratio to the
#    estimator's ratio, not a hardcoded 2.5. 2.5 under-estimates prompt
#    size and lets oversized requests reach the provider.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use JSON::PP;

use CLIO::Core::ModelCapabilitiesManager;
use CLIO::Memory::TokenEstimator;
use CLIO::Core::API::MessageValidator;

# ---------------------------------------------------------------------------
# A stub HTTP client: returns a canned /models response.
# ---------------------------------------------------------------------------

{
    package StubHTTP;

    sub new {
        my ($class, $body) = @_;
        return bless { body => $body }, $class;
    }

    sub get {
        return {
            success => 1,
            status  => 200,
            content => $_[0]->{body},
        };
    }
}

sub fetch_with_listing {
    my ($model) = @_;

    my $body = encode_json({
        data => [ $model ],
    });

    my $mcm = CLIO::Core::ModelCapabilitiesManager->new(debug => 0);
    $mcm->{http} = StubHTTP->new($body);
    $mcm->{cache} = {};

    require CLIO::Providers;
    return $mcm->_fetch_openai_compatible_capabilities(
        'openrouter', 'vendor/test-model', 'https://example.invalid/v1/chat/completions',
    );
}

subtest 'max_tokens is not read as a context window' => sub {
    for my $token_ratio (1, 2, 3) {
        local $ENV{CLIO_API_KEY} = 'test-key';
        my $caps = fetch_with_listing({
            id             => 'vendor/test-model',
            max_tokens     => 8192,
            context_length => undef,
        });
        ok($caps, "listing returned caps (attempt $token_ratio)");
        isnt($caps->{context_window}, 8192,
            'output cap is not mistaken for the context window');
    }
};

subtest 'context_length still wins when present' => sub {
    local $ENV{CLIO_API_KEY} = 'test-key';
    my $caps = fetch_with_listing({
        id             => 'vendor/test-model',
        context_length => 1048576,
        max_tokens     => 8192,
    });
    ok($caps, 'listing returned caps');
    is($caps->{context_window}, 1048576, 'context window from context_length');
    is($caps->{max_prompt_tokens}, 1048576, 'prompt limit follows the context window');
};

subtest 'OpenRouter top_provider limit is used when top-level is absent' => sub {
    local $ENV{CLIO_API_KEY} = 'test-key';
    my $caps = fetch_with_listing({
        id           => 'vendor/test-model',
        top_provider => { context_length => 262144, max_completion_tokens => 32768 },
    });
    ok($caps, 'listing returned caps');
    is($caps->{context_window}, 262144, 'context window from top_provider');
    is($caps->{max_output_tokens}, 32768, 'output cap from top_provider');
};

# ---------------------------------------------------------------------------
# Ratio default
# ---------------------------------------------------------------------------

subtest 'validator defaults to the estimator ratio' => sub {
    my @msgs = (
        { role => 'system', content => 's' x 4000 },
        { role => 'user',   content => 'u' x 4000 },
    );

    CLIO::Memory::TokenEstimator::set_learned_ratio(3.5);

    my $plan = {};
    CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => \@msgs,
        model_capabilities => { max_context_window_tokens => 200000, max_output_tokens => 16000 },
        tools              => [],
        # token_ratio deliberately omitted
        context_plan       => $plan,
    );

    is($plan->{ratio}, 3.5, 'learned ratio used when caller passes none');

    # With no learned ratio the estimator's documented default (4.0) applies.
    CLIO::Memory::TokenEstimator::set_learned_ratio(0);  # ignored (<= 0)
    my $plan2 = {};
    CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => \@msgs,
        model_capabilities => { max_context_window_tokens => 200000, max_output_tokens => 16000 },
        tools              => [],
        context_plan       => $plan2,
    );
    is($plan2->{ratio}, CLIO::Memory::TokenEstimator::get_effective_ratio(),
        'default ratio is whatever the estimator reports');
    cmp_ok($plan2->{ratio}, '>', 2.5, 'default is not the old 2.5 under-estimate');
};

done_testing();
