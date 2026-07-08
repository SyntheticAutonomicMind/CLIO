#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Regression: _lookup_static_model was being called as a method but its
# signature treated the first arg as the map ref, so it always returned undef.
# Verify exact, prefix-stripped, and case-insensitive lookups all work when
# invoked through the public get_capabilities entry points.

use Test::More;
use CLIO::Core::ModelCapabilitiesManager;

my $mcm = CLIO::Core::ModelCapabilitiesManager->new();

# Direct _lookup_static_model calls (as the fetchers use them)
my %test_map = (
    'MiniMax-M3' => { context_window => 1000000 },
    'glm-5'      => { context_window => 200000 },
);

# Exact match
my $hit = $mcm->_lookup_static_model(\%test_map, 'MiniMax-M3', 'minimax', 'minimaxai');
ok($hit && $hit->{context_window} == 1000000, 'exact match works');

# Provider prefix strip
$hit = $mcm->_lookup_static_model(\%test_map, 'minimax/MiniMax-M3', 'minimax', 'minimaxai');
ok($hit && $hit->{context_window} == 1000000, 'prefix-stripped match works');

# Case-insensitive fallback
$hit = $mcm->_lookup_static_model(\%test_map, 'minimax-m3', 'minimax', 'minimaxai');
ok($hit && $hit->{context_window} == 1000000, 'case-insensitive match works');

# Unknown model returns undef
$hit = $mcm->_lookup_static_model(\%test_map, 'no-such-model', 'minimax');
ok(!defined $hit, 'unknown model returns undef');

# Full get_capabilities path - MiniMax
my $caps = $mcm->get_capabilities('minimax', 'MiniMax-M3');
ok($caps && $caps->{context_window} == 1000000, 'get_capabilities(MiniMax-M3) returns 1M');

# Full path - prefixed model name (real-world use: model_config + /api set)
$caps = $mcm->get_capabilities('minimax', 'minimax/minimax-m3');
ok($caps && $caps->{context_window} == 1000000, 'get_capabilities(minimax/minimax-m3) returns 1M (mixed case slug)');

# Full path - DeepSeek V4
$caps = $mcm->get_capabilities('deepseek', 'deepseek-v4-pro');
ok($caps && $caps->{context_window} == 1048576, 'get_capabilities(deepseek-v4-pro) returns 1M');

# Full path - Z.AI
$caps = $mcm->get_capabilities('zai', 'glm-5.1');
ok($caps && $caps->{context_window} == 200000, 'get_capabilities(zai/glm-5.1) returns 200K');

done_testing();
