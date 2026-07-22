#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-or-later
# Unit tests for the Anthropic input-token throttle layer in APIManager.
#
# These methods are independent of network and configuration:
#   - _model_input_token_throttle_record()
#   - _sliding_window_input_tokens()
#   - _model_input_token_throttle_check() (snapshot + learned layers)
#   - _apply_anthropic_rate_limit_headers()
#   - _learn_input_token_limit() (lower-only policy)
#
# They live on APIManager.pm, so we instantiate the class directly and call
# methods without running through the constructor's broader wiring.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use lib "$RealBin/../lib";
use Test::More;

use CLIO::Core::APIManager;

# Minimal instance - methods under test don't touch session/config/last_request_time.
my $api = bless { _model_input_token_window => {}, _model_input_token_limits => {}, _anthropic_rate_limits => {} }, 'CLIO::Core::APIManager';

# =============================================================================
# Section 1: _model_input_token_throttle_record + window sum
# =============================================================================
subtest 'record + sliding window sum' => sub {
    $api->_model_input_token_throttle_record('claude-sonnet-4-20250514', 5000);
    $api->_model_input_token_throttle_record('claude-sonnet-4-20250514', 3000);
    is($api->_sliding_window_input_tokens('claude-sonnet-4-20250514'), 8000,
        "Two records sum to 8000 in window");
    is($api->_sliding_window_input_tokens('unknown-model'), 0,
        "Unknown model returns 0");
};

# =============================================================================
# Section 2: _learn_input_token_limit is lower-only
# =============================================================================
subtest 'learn is lower-only for header-supplied and observed limits' => sub {
    $api->_learn_input_token_limit('claude-sonnet-4-20250514', undef, 250000);
    is($api->{_model_input_token_limits}{'claude-sonnet-4-20250514'}, 250000,
        "First seeded limit stored as-is");

    # A higher reported limit must NOT raise the learned floor (we only ever
    # get the API-reported limit when the response was successful, and we
    # only trust it when there's no lower observation).
    $api->_learn_input_token_limit('claude-sonnet-4-20250514', undef, 500000);
    is($api->{_model_input_token_limits}{'claude-sonnet-4-20250514'}, 250000,
        "Higher reported limit does not raise learned floor");

    # A lower observed total (from a 429) lowers the limit.
    $api->_learn_input_token_limit('claude-sonnet-4-20250514', 200001, undef);
    is($api->{_model_input_token_limits}{'claude-sonnet-4-20250514'}, 200000,
        "Observed (count-1) lowers the learned limit");

    # The header-supplied path wins over observation when both are passed.
    $api->_learn_input_token_limit('claude-sonnet-4-20250514', 999999, 100000);
    is($api->{_model_input_token_limits}{'claude-sonnet-4-20250514'}, 100000,
        "Header-supplied limit is preferred over observation");
};

# =============================================================================
# Section 3: snapshot-driven throttle check
# =============================================================================
subtest 'snapshot-driven throttle check' => sub {
    # Fresh instance to avoid state pollution from earlier subtests.
    my $a = bless { _model_input_token_window => {}, _model_input_token_limits => {}, _anthropic_rate_limits => {} }, 'CLIO::Core::APIManager';

    my $model = 'claude-test-snap';
    # Recorded usage: 200000 of 250000 ITPM consumed.
    $a->_model_input_token_throttle_record($model, 200000);

    # Snapshot says 250000 ITPM, 50000 remaining, resets in 30s.
    my %snap = (
        input_tokens => {
            limit       => 250000,
            remaining   => 50000,
            reset_in    => 30,
            observed_at => time(),
        },
    );
    $a->{_anthropic_rate_limits}{$model} = \%snap;

    # A pending request of 40000 (200000 + 40000 = 240000 of 250000 = 96%) ->
    # ratio = 0.96, > 0.7, expect spread delay.
    my $delay = $a->_model_input_token_throttle_check($model, 40000);
    cmp_ok($delay, '>', 0,    'Returns positive delay when over 70% threshold (snapped)');
    cmp_ok($delay, '<=', 10,  'Delay is clamped to 10s in the spread layer');

    # A pending request of 10000 (200000 + 10000 = 210000 = 84%) -> still > 70%
    # but small, expect a delay proportional to gap (84000 - 175000 = err,
    # actually 210000 - 175000 = 35000, divided by refill_per_sec ~4166 = ~8.4s.
    # Just check it's > 0 and <= 10.)
    $delay = $a->_model_input_token_throttle_check($model, 10000);
    cmp_ok($delay, '>', 0, 'Small pending still triggers throttle under snap pressure');
    cmp_ok($delay, '<=', 10, 'Delay stays within hard ceiling');

    # At or over the bucket -> wait for the reset_in moment.
    # Record enough tokens that (used + pending) > limit.
    $a->_model_input_token_throttle_record($model, 251000);
    my $over_snap = {
        input_tokens => {
            limit       => 250000,
            remaining   => 0,
            reset_in    => 12,
            observed_at => time(),
        },
    };
    $a->{_anthropic_rate_limits}{$model} = $over_snap;
    $delay = $a->_model_input_token_throttle_check($model, 0);
    cmp_ok($delay, '>=', 12, 'At-the-cap delay waits for reset_in (+1 padding)');
    cmp_ok($delay, '<=', 14, 'At-the-cap delay does not exceed reset_in+padding');
};

# =============================================================================
# Section 4: snapshot stale -> learned layer takes over
# =============================================================================
subtest 'stale snapshot falls back to learned layer' => sub {
    my $a = bless { _model_input_token_window => {}, _model_input_token_limits => {}, _anthropic_rate_limits => {} }, 'CLIO::Core::APIManager';
    my $model = 'claude-test-stale';

    # Snapshot 5 minutes old -> ignored.
    $a->{_anthropic_rate_limits}{$model} = {
        input_tokens => {
            limit       => 250000,
            remaining   => 50000,
            reset_in    => 30,
            observed_at => time() - 300,
        },
    };
    # Learned limit just below current usage.
    $a->_learn_input_token_limit($model, 220000, undef);

    # Currently at 200k tokens in window.
    $a->_model_input_token_throttle_record($model, 200000);

    # Snap stale => layer 1 returns undef. Learned layer fires (>70% of 220000).
    my $delay = $a->_model_input_token_throttle_check($model, 0);
    cmp_ok($delay, '>', 0, 'Learned layer produces delay when snapshot is stale');
};

# =============================================================================
# Section 5: _apply_anthropic_rate_limit_headers
# =============================================================================
subtest '_apply_anthropic_rate_limit_headers stashes ITPM/OTPM/RPM snapshot' => sub {
    my $a = bless { _model_input_token_window => {}, _model_input_token_limits => {}, _anthropic_rate_limits => {} }, 'CLIO::Core::APIManager';
    my $model = 'claude-headers';

    # Mock inputs with all 4 Anthropic buckets present.
    my $info = {
        anthropic_requests_limit        => '1000',
        anthropic_requests_remaining    => '950',
        anthropic_requests_reset        => POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', localtime(time() + 30)),
        anthropic_input_tokens_limit    => '250000',
        anthropic_input_tokens_remaining => '75000',
        anthropic_input_tokens_reset    => POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', localtime(time() + 45)),
        anthropic_output_tokens_limit   => '50000',
        anthropic_output_tokens_remaining => '47000',
        anthropic_output_tokens_reset   => POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', localtime(time() + 25)),
    };

    $a->_apply_anthropic_rate_limit_headers($model, $info);

    my $snap = $a->{_anthropic_rate_limits}{$model};
    ok(ref($snap) eq 'HASH', 'Snapshot stored');
    is($snap->{input_tokens}{limit}, 250000, 'ITPM limit captured');
    is($snap->{input_tokens}{remaining}, 75000, 'ITPM remaining captured');
    ok(defined $snap->{input_tokens}{reset_in}, 'ITPM reset_in captured');
    is($snap->{requests}{limit}, 1000, 'RPM limit captured');
    is($snap->{output_tokens}{limit}, 50000, 'OTPM limit captured');

    # ITPM snapshot fed into the learned limit
    is($a->{_model_input_token_limits}{$model}, 250000,
        'ITPM limit also seeded into _model_input_token_limits');
};

# =============================================================================
# Section 6: missing input_tokens -> no layer returns a delay
# =============================================================================
subtest 'no signal = no delay' => sub {
    my $a = bless { _model_input_token_window => {}, _model_input_token_limits => {}, _anthropic_rate_limits => {} }, 'CLIO::Core::APIManager';
    is($a->_model_input_token_throttle_check('claude-cold-start', 10000), 0,
        'No snapshot, no learned limit -> 0 delay (cold start)');
};

done_testing();
