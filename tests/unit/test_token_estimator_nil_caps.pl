#!/usr/bin/env perl
# Test: compute_prompt_budget falls back to DEFAULT_CONTEXT_WINDOW
# when $caps is undef, instead of returning 1000.

use strict;
use warnings;
use Test::More;

use lib 'lib';
require CLIO::Memory::TokenEstimator;
require CLIO::Core::Defaults;

# Test 1: undef caps should return a reasonable budget (not 1000)
{
    my $budget = CLIO::Memory::TokenEstimator::compute_prompt_budget(undef);
    my $ctx = CLIO::Core::Defaults::DEFAULT_CONTEXT_WINDOW();
    my $buf = CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER()
            + int($ctx * CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER_PCT());
    $buf = CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER_MAX() if $buf > CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER_MAX();
    my $expected = $ctx - CLIO::Core::Defaults::DEFAULT_MAX_OUTPUT_TOKENS() - $buf;
    $expected = 1000 if $expected < 1000;
    ok($budget > 1000, "undef caps budget ($budget) > 1000 (prevents aggressive trimming)");
    ok($budget == $expected, "undef caps returns same budget as DEFAULT_CONTEXT_WINDOW-based calculation ($budget)");
}

# Test 2: empty hashref caps should also return reasonable budget
{
    my $budget = CLIO::Memory::TokenEstimator::compute_prompt_budget({});
    # 128000 - 16384 - max(8192+6400, 51200) = 128000 - 16384 - 14592 = 97024
    my $ctx = CLIO::Core::Defaults::DEFAULT_CONTEXT_WINDOW();
    my $buf = CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER()
            + int($ctx * CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER_PCT());
    $buf = CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER_MAX() if $buf > CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER_MAX();
    my $expected = $ctx - CLIO::Core::Defaults::DEFAULT_MAX_OUTPUT_TOKENS() - $buf;
    $expected = 1000 if $expected < 1000;
    ok($budget == $expected, "empty hashref caps returns expected budget ($budget)");
}

# Test 3: Normal caps with explicit values still works
{
    my $caps = {
        max_context_window_tokens => 100000,
        max_output_tokens => 32000,
    };
    my $budget = CLIO::Memory::TokenEstimator::compute_prompt_budget($caps);
    ok($budget > 0, "normal caps returns positive budget");
    ok($budget < 100000, "normal caps budget < context window (output reserve applied)");
}

done_testing();
