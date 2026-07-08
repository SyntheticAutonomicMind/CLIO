#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Regression: MCM._fetch_openai_compatible_capabilities and
# _fetch_google_capabilities used `$server_id eq $model` for model
# lookup. This is case-sensitive and doesn't handle org/ prefix
# differences, so:
#
# - User passes "minimax-m3" (lowercase, no prefix) but server returns
#   "MiniMax-M3" (canonical mixed-case) -> miss
# - User passes "google/gemini-2.5-flash" but server returns
#   "models/gemini-2.5-flash" -> miss
# - User passes "minimax/minimax-m3" but server returns "minimax-m3" ->
#   miss (depending on which side the prefix strip happens)
#
# Result: MCM returns undef for valid models, user sees fallback
# context_window instead of the real value.
#
# Fix: new _find_model_in_list helper does two-pass lookup:
# 1. Exact match (fast path, no normalization)
# 2. Case-insensitive match with optional leading org/ segment strip
#
# This is the same normalization pattern used in _lookup_static_model.

use Test::More;

use CLIO::Core::ModelCapabilitiesManager;

my $mcm = CLIO::Core::ModelCapabilitiesManager->new();

# Test 1: Exact match (the happy path)
{
    my $models = [
        { id => 'gpt-4.1',        context_window => 1048576 },
        { id => 'claude-sonnet-4', context_window => 200000 },
    ];
    my $result = $mcm->_find_model_in_list($models, 'gpt-4.1', 'id');
    ok($result && $result->{context_window} == 1048576, 'exact match works');
}

# Test 2: Case-insensitive match (server returns mixed-case)
{
    my $models = [
        { id => 'MiniMax-M3',  context_window => 1000000 },
        { id => 'gpt-4.1',     context_window => 1048576 },
    ];
    my $result = $mcm->_find_model_in_list($models, 'minimax-m3', 'id');
    ok($result && $result->{context_window} == 1000000,
        'case-insensitive match: caller "minimax-m3" finds server "MiniMax-M3"');
}

# Test 3: Reverse case-insensitive (caller uppercase, server lowercase)
{
    my $models = [
        { id => 'minimax-m3',  context_window => 1000000 },
    ];
    my $result = $mcm->_find_model_in_list($models, 'MINIMAX-M3', 'id');
    ok($result && $result->{context_window} == 1000000,
        'case-insensitive match: caller "MINIMAX-M3" finds server "minimax-m3"');
}

# Test 4: Prefix-stripped match (server returns "minimax/MiniMax-M3",
# caller passes "minimax-m3")
{
    my $models = [
        { id => 'minimax/MiniMax-M3', context_window => 1000000 },
        { id => 'gpt-4.1',           context_window => 1048576 },
    ];
    my $result = $mcm->_find_model_in_list($models, 'minimax-m3', 'id');
    ok($result && $result->{context_window} == 1000000,
        'prefix-stripped match: caller "minimax-m3" finds server "minimax/MiniMax-M3"');
}

# Test 5: Reverse prefix-stripped (caller has prefix, server doesn't)
{
    my $models = [
        { id => 'minimax-m3', context_window => 1000000 },
    ];
    my $result = $mcm->_find_model_in_list($models, 'minimax/minimax-m3', 'id');
    ok($result && $result->{context_window} == 1000000,
        'prefix-stripped match: caller "minimax/minimax-m3" finds server "minimax-m3"');
}

# Test 6: No match returns undef
{
    my $models = [
        { id => 'gpt-4.1', context_window => 1048576 },
    ];
    my $result = $mcm->_find_model_in_list($models, 'no-such-model', 'id');
    is($result, undef, 'no match returns undef');
}

# Test 7: Google-style "models/" prefix is stripped
{
    my $models = [
        { name => 'models/gemini-2.5-flash', outputTokenLimit => 8192 },
        { name => 'models/gemini-2.5-pro',   outputTokenLimit => 8192 },
    ];
    my $result = $mcm->_find_model_in_list($models, 'gemini-2.5-flash', 'name');
    ok($result && $result->{outputTokenLimit} == 8192,
        'Google-style: caller "gemini-2.5-flash" finds server "models/gemini-2.5-flash"');
}

# Test 8: Google-style with provider prefix
{
    my $models = [
        { name => 'models/gemini-2.5-flash', outputTokenLimit => 8192 },
    ];
    my $result = $mcm->_find_model_in_list($models, 'google/gemini-2.5-flash', 'name');
    ok($result && $result->{outputTokenLimit} == 8192,
        'Google-style with org prefix: caller "google/gemini-2.5-flash" finds server "models/gemini-2.5-flash"');
}

# Test 9: Empty input
{
    my $result = $mcm->_find_model_in_list([], 'anything', 'id');
    is($result, undef, 'empty list returns undef');
    $result = $mcm->_find_model_in_list(undef, 'anything', 'id');
    is($result, undef, 'undef list returns undef');
    $result = $mcm->_find_model_in_list([{id => 'x'}], undef, 'id');
    is($result, undef, 'undef model returns undef');
}

# Test 10: First match wins (precedence: exact > case-insensitive)
# If the server has both "minimax-m3" and "minimax-m3-large", and the
# caller asks for "minimax-m3", exact match should win (not the larger one
# via prefix-stripped case-insensitive fallback).
{
    my $models = [
        { id => 'minimax-m3-large', context_window => 2000000 },
        { id => 'minimax-m3',      context_window => 1000000 },
    ];
    my $result = $mcm->_find_model_in_list($models, 'minimax-m3', 'id');
    ok($result && $result->{context_window} == 1000000,
        'exact match wins over prefix-stripped case-insensitive match');
}

# Test 11: Source-level check that openai-compatible and Google fetchers
# both use _find_model_in_list (regression guard)
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die; <$fh> };

    # The old pattern "$m->{id} eq $model" should no longer appear in
    # the openai-compatible path
    my $compat_block_start = index($src, 'sub _fetch_openai_compatible_capabilities');
    my $compat_block_end   = index($src, 'sub _ensure_reasoning_mode', $compat_block_start);
    my $compat_block = substr($src, $compat_block_start, $compat_block_end - $compat_block_start);
    unlike($compat_block, qr/\$m->\{id\}\s*eq\s*\$model/,
        'openai-compatible no longer uses "$m->{id} eq $model" (uses _find_model_in_list instead)');

    my $google_block_start = index($src, 'sub _fetch_google_capabilities');
    my $google_block_end   = index($src, 'sub _fetch_nvidia_capabilities', $google_block_start);
    my $google_block = substr($src, $google_block_start, $google_block_end - $google_block_start);
    unlike($google_block, qr/\$model_id\s*eq\s*\$model/,
        'google no longer uses "$model_id eq $model" (uses _find_model_in_list instead)');
}

done_testing();
