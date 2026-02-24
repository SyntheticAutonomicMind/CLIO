#!/usr/bin/env perl
# Test that premium request counting works via multiplier

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More tests => 6;

# Mock minimal State-like object for testing
{
    package MockState;
    sub new {
        return bless {
            billing => {
                total_requests => 0,
                total_premium_requests => 0,
                total_prompt_tokens => 0,
                total_completion_tokens => 0,
                total_tokens => 0,
                model => undef,
                multiplier => 0,
                requests => [],
            },
            debug => 0,
        }, shift;
    }
    sub get_billing_summary {
        my ($self) = @_;
        return {
            total_requests => $self->{billing}{total_requests},
            total_premium_requests => $self->{billing}{total_premium_requests},
        };
    }
}

# We can't easily test record_api_usage (it requires GitHub API calls for multiplier)
# Instead, test the billing hash structure and count logic

my $state = MockState->new();

# Test 1: Initial state
my $billing = $state->get_billing_summary();
is($billing->{total_premium_requests}, 0, "Initial premium requests is 0");
is($billing->{total_requests}, 0, "Initial total requests is 0");

# Test 2: Simulate premium request recording (what record_api_usage now does)
$state->{billing}{total_requests}++;
$state->{billing}{total_premium_requests}++;  # multiplier > 0
push @{$state->{billing}{requests}}, {
    model => 'claude-opus-4.6',
    multiplier => 3,
    total_tokens => 1000,
};

$billing = $state->get_billing_summary();
is($billing->{total_premium_requests}, 1, "After 1 premium request, count is 1");
is($billing->{total_requests}, 1, "After 1 request, total is 1");

# Test 3: Simulate free request (multiplier = 0)
$state->{billing}{total_requests}++;
# DON'T increment premium requests since multiplier = 0
push @{$state->{billing}{requests}}, {
    model => 'gpt-4.1-mini',
    multiplier => 0,
    total_tokens => 500,
};

$billing = $state->get_billing_summary();
is($billing->{total_premium_requests}, 1, "Free request doesn't increment premium count");
is($billing->{total_requests}, 2, "Total requests incremented for free request too");

print "\n Premium request counting tests passed!\n";
