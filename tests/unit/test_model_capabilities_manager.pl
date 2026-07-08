#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_model_capabilities_manager.pl - Unit test for ModelCapabilitiesManager

=head1 SYNOPSIS

    perl -I./lib tests/unit/test_model_capabilities_manager.pl

=cut

use strict;
use warnings;
use utf8;
use Test::More;
use CLIO::Core::ModelCapabilitiesManager;

my $mcm = CLIO::Core::ModelCapabilitiesManager->new(debug => 1);

# Test constructor
ok($mcm, 'Constructor returned object');
isa_ok($mcm, 'CLIO::Core::ModelCapabilitiesManager');

# Test get_capabilities returns hashref for github_copilot (may be undef if no auth)
# We test the infrastructure, not the specific provider API
ok($mcm->can('get_capabilities'), 'Method get_capabilities exists');
ok($mcm->can('supports_feature'), 'Method supports_feature exists');
ok($mcm->can('get_model_info'), 'Method get_model_info exists');
ok($mcm->can('refresh_capabilities'), 'Method refresh_capabilities exists');
ok($mcm->can('clear_cache'), 'Method clear_cache exists');

# Test _format_tokens
my $formatted = $mcm->_format_tokens(204800);
is($formatted, '205k', '_format_tokens formats 204800 as 205k (204.8 rounded)');

$formatted = $mcm->_format_tokens(1000000);
is($formatted, '1.0M', '_format_tokens formats 1000000 as 1.0M');

$formatted = $mcm->_format_tokens(128000);
is($formatted, '128k', '_format_tokens formats 128000 as 128k');

$formatted = $mcm->_format_tokens(500);
is($formatted, '500', '_format_tokens formats 500 as 500');

# DeepSeek static capability map
for my $model (qw(deepseek-v4-flash deepseek-v4-pro)) {
    $mcm->clear_cache();
    my $caps = $mcm->get_capabilities('deepseek', $model);
    ok($caps, "DeepSeek caps returned for $model");
    is($caps->{context_window}, 1048576, "$model context_window=1M");
    is($caps->{max_output_tokens}, 32768, "$model max_output=32K");
    ok($caps->{supports_tools}, "$model supports_tools");
    ok($caps->{supports_reasoning}, "$model supports_reasoning");
    is($caps->{supports_vision}, 0, "$model supports_vision=0");
}

# Unknown model returns undef
$mcm->clear_cache();
my $unknown = $mcm->get_capabilities('deepseek', 'deepseek-v99-unknown');
is($unknown, undef, 'Unknown deepseek model returns undef');


# =============================================================================
# set_reasoning_mode - learned mode persistence
# =============================================================================
# The self-correcting retry path uses set_reasoning_mode to persist
# the correct mode extracted from an API error message. Subsequent
# get_capabilities calls for the same model should return the learned
# mode WITHOUT hitting the network or the name heuristic. This avoids
# the round-trip cost AND works for any future model name that doesn't
# match the heuristic patterns.

# Use a fresh MCM with a tmp cache so we don't pollute the real cache
use File::Temp;
my $tmp_cache = File::Temp->new(SUFFIX => '.json');
my $mcm_learned = CLIO::Core::ModelCapabilitiesManager->new(
    cache_file => $tmp_cache->filename,
    cache_ttl  => 3600,
);

subtest 'set_reasoning_mode - basic adaptive' => sub {
    my $ok = $mcm_learned->set_reasoning_mode('anthropic', 'Generic-Model-A', 'adaptive');
    is($ok, 1, 'set_reasoning_mode returns 1 on success');

    my $caps = $mcm_learned->get_capabilities('anthropic', 'Generic-Model-A');
    ok($caps, 'Caps returned for learned model');
    is($caps->{reasoning_mode}, 'adaptive',
        'Learned mode is adaptive');
    is($caps->{supports_reasoning}, 1,
        'Learned entry has supports_reasoning=1');
    is($caps->{supports_adaptive_thinking}, 1,
        'Learned entry has supports_adaptive_thinking=1 (data-driven flag)');
};

subtest 'set_reasoning_mode - basic enabled' => sub {
    my $ok = $mcm_learned->set_reasoning_mode('anthropic', 'Some-3-x-Model', 'enabled');
    is($ok, 1, 'set_reasoning_mode returns 1 on success');

    my $caps = $mcm_learned->get_capabilities('anthropic', 'Some-3-x-Model');
    is($caps->{reasoning_mode}, 'enabled',
        'Learned mode is enabled');
    is($caps->{supports_enabled_thinking}, 1,
        'Learned entry has supports_enabled_thinking=1');
    ok(!$caps->{supports_adaptive_thinking},
        'Did NOT set supports_adaptive_thinking for enabled mode');
};

subtest 'set_reasoning_mode - rejects invalid mode' => sub {
    my $ok = $mcm_learned->set_reasoning_mode('anthropic', 'Some-Model', 'unknown_mode');
    is($ok, 0, 'Unknown mode rejected (returns 0)');
    my $caps = $mcm_learned->get_capabilities('anthropic', 'Some-Model');
    ok(!$caps, 'Invalid mode did not create an entry');
};

subtest 'set_reasoning_mode - rejects empty args' => sub {
    is($mcm_learned->set_reasoning_mode(undef, 'model', 'adaptive'), 0, 'No provider: rejected');
    is($mcm_learned->set_reasoning_mode('anthropic', undef, 'adaptive'), 0, 'No model: rejected');
    is($mcm_learned->set_reasoning_mode('anthropic', 'model', undef), 0, 'No mode: rejected');
    is($mcm_learned->set_reasoning_mode('anthropic', 'model', ''), 0, 'Empty mode: rejected');
};

subtest 'set_reasoning_mode - data-driven flag beats heuristic' => sub {
    # A model name that would normally hit the heuristic, but the
    # learned entry sets supports_adaptive_thinking=1 so _ensure_reasoning_mode
    # returns adaptive from the data path (first check) instead of the
    # heuristic. This is the key behavior - no guessing on subsequent calls.
    my $tmp_cache2 = File::Temp->new(SUFFIX => '.json');
    my $mcm2 = CLIO::Core::ModelCapabilitiesManager->new(
        cache_file => $tmp_cache2->filename,
        cache_ttl  => 3600,
    );

    # A 4.5 model name (heuristic says "enabled"). But we learn it
    # actually supports adaptive via API feedback.
    $mcm2->set_reasoning_mode('anthropic', 'Generic-Model-B', 'adaptive');

    my $caps = $mcm2->get_capabilities('anthropic', 'Generic-Model-B');
    is($caps->{reasoning_mode}, 'adaptive',
        'Learned adaptive beats heuristic enabled for 4.5 alias');
};

subtest 'set_reasoning_mode - updates existing entry' => sub {
    # If there was already an entry (e.g., from a real /v1/models fetch
    # that didn't disambiguate the mode), set_reasoning_mode should
    # update it without wiping out the other fields.
    my $tmp_cache3 = File::Temp->new(SUFFIX => '.json');
    my $mcm3 = CLIO::Core::ModelCapabilitiesManager->new(
        cache_file => $tmp_cache3->filename,
        cache_ttl  => 3600,
    );

    # Seed an entry by hand
    $mcm3->{cache}{'anthropic:test-model:'} = {
        provider           => 'anthropic',
        model              => 'Test-Model',
        context_window     => 200000,
        supports_tools     => 1,
        supports_reasoning => 1,
        _cached_at         => time,
    };

    # Now learn the mode
    $mcm3->set_reasoning_mode('anthropic', 'Test-Model', 'adaptive');

    my $caps = $mcm3->get_capabilities('anthropic', 'Test-Model');
    is($caps->{context_window}, 200000,
        'Existing context_window preserved after set_reasoning_mode');
    is($caps->{supports_tools}, 1,
        'Existing supports_tools preserved');
    is($caps->{reasoning_mode}, 'adaptive',
        'New reasoning_mode applied');
};

subtest 'set_reasoning_mode - persists across MCM instances' => sub {
    my $tmp_cache4 = File::Temp->new(SUFFIX => '.json');
    my $cache_path = $tmp_cache4->filename;

    my $mcm_first = CLIO::Core::ModelCapabilitiesManager->new(
        cache_file => $cache_path,
        cache_ttl  => 3600,
    );
    $mcm_first->set_reasoning_mode('anthropic', 'Persist-Test', 'adaptive');

    # New instance, same cache file
    my $mcm_second = CLIO::Core::ModelCapabilitiesManager->new(
        cache_file => $cache_path,
        cache_ttl  => 3600,
    );
    my $caps = $mcm_second->get_capabilities('anthropic', 'Persist-Test');
    ok($caps, 'Caps loaded from disk cache by second instance');
    is($caps->{reasoning_mode}, 'adaptive',
        'Learned mode persists across MCM instances');
};

done_testing();
