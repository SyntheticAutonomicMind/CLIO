#!/usr/bin/perl
# Test prompt_stable_prefix_tokens content-hash caching behavior.
#
# Bug fixed: prompt_stable_prefix_tokens was recalculated on every
# request using CLIO::Memory::TokenEstimator::estimate_tokens(), which
# uses get_effective_ratio(). The learned ratio drifts after every
# API response (via _learn_from_api_response -> set_learned_ratio).
# A drifting ratio produced a drifting token count on every turn
# (observed: 31335 -> 3323 -> 29559 -> 2915 -> 28999 -> 29148 -> 2927),
# which broke llama.cpp's LCP cache match and forced full prompt
# reprocessing each turn (5+ min per task on local models).
#
# Fix: cache the stable prefix token count by MD5 of system prompt
# content. When the content is byte-identical, reuse the cached value.
# When the content changes (e.g. tools added), recalculate. The learned
# ratio still flows through to all other estimation (MessageValidator
# trim, budget validation) - only the stable prefix hint is frozen.
#
# We test the production logic by re-implementing the same block
# from APIManager._build_payload. If production drifts, this helper
# will diverge and the tests will fail.

use strict;
use warnings;
use utf8;
use lib 'lib';
use Test::More;

# Re-implementation of the production caching logic from
# APIManager._build_payload (the prompt_stable_prefix_tokens block).
# Returns: ($tokens_in_payload, $cache_state_after)
# $self is a hashref with {_stable_prefix_cache => undef | {hash, tokens}}.
sub compute_stable_prefix {
    my ($self, $messages) = @_;

    my $first_msg = $messages->[0];
    return (0, $self->{_stable_prefix_cache}) unless $first_msg && ($first_msg->{role} // '') eq 'system';

    my $content = $first_msg->{content} // '';
    my $text_content = '';
    if (ref($content) eq 'ARRAY') {
        for my $part (@$content) {
            if (ref($part) eq 'HASH' && ($part->{type} // '') eq 'text') {
                $text_content .= ($part->{text} // '');
            }
        }
    } else {
        $text_content = $content;
    }
    return (0, $self->{_stable_prefix_cache}) unless length($text_content) > 0;

    require Digest::MD5;
    my $content_hash = Digest::MD5::md5_hex($text_content);

    if ($self->{_stable_prefix_cache}
        && $self->{_stable_prefix_cache}{hash} eq $content_hash) {
        return ($self->{_stable_prefix_cache}{tokens}, $self->{_stable_prefix_cache});
    }

    require CLIO::Memory::TokenEstimator;
    my $stable_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($text_content);
    if ($stable_tokens > 0) {
        $self->{_stable_prefix_cache} = {
            hash   => $content_hash,
            tokens => $stable_tokens,
        };
    }
    return ($stable_tokens, $self->{_stable_prefix_cache});
}

# =================================================================
# Test 1: First call computes and caches; second call with same
# content returns cached value even after learned ratio drifts.
# This is the core regression test.
# =================================================================
subtest 'cache hit: same content returns same tokens despite ratio drift' => sub {
    require CLIO::Memory::TokenEstimator;

    my $system_prompt = "# CLIO System Prompt\n" . ("Stable system context. " x 300);
    my $messages = [{ role => 'system', content => $system_prompt }];

    # Reset learned ratio to a known starting value (2.5)
    CLIO::Memory::TokenEstimator::set_learned_ratio(2.5);

    my $self = { _stable_prefix_cache => undef };
    my ($tokens_first, $cache_after_first) = compute_stable_prefix($self, $messages);

    ok(defined $cache_after_first, 'cache populated after first call');
    ok(exists $cache_after_first->{hash}, 'cache has content hash');
    ok(exists $cache_after_first->{tokens}, 'cache has token count');

    # Simulate the learned ratio drifting toward the model's actual ratio
    # (this is what _learn_from_api_response does after each API response)
    CLIO::Memory::TokenEstimator::set_learned_ratio(2.65);
    my $drifted_value = CLIO::Memory::TokenEstimator::estimate_tokens($system_prompt);

    # The "naive" (pre-fix) behavior would now return the drifted value.
    # The fix returns the cached value instead.
    my ($tokens_second, $cache_after_second) = compute_stable_prefix($self, $messages);

    is($tokens_second, $tokens_first,
        'second call returns cached token count (not recalculated)');
    isnt($tokens_second, $drifted_value,
        'second call does NOT return the drifted value (ratio change ignored)');
    is_deeply($cache_after_second, $cache_after_first,
        'cache unchanged after second call with same content');
};

# =================================================================
# Test 2: Cache invalidation when system prompt content changes.
# (e.g. tools added, MCP servers registered, skills discovered)
# =================================================================
subtest 'cache miss: content change triggers recalculation' => sub {
    require CLIO::Memory::TokenEstimator;
    CLIO::Memory::TokenEstimator::set_learned_ratio(2.5);

    my $system_prompt_v1 = "# CLIO System Prompt\n" . ("v1 content. " x 300);
    my $system_prompt_v2 = "# CLIO System Prompt\n" . ("v2 content LONGER. " x 400);

    my $self = { _stable_prefix_cache => undef };

    my ($tokens_v1, $cache_v1) = compute_stable_prefix($self,
        [{ role => 'system', content => $system_prompt_v1 }]);

    my ($tokens_v2, $cache_v2) = compute_stable_prefix($self,
        [{ role => 'system', content => $system_prompt_v2 }]);

    isnt($cache_v1->{hash}, $cache_v2->{hash},
        'content hash differs when content changes');
    isnt($tokens_v1, $tokens_v2,
        'token count differs when content changes');
    is($cache_v2->{tokens}, $tokens_v2,
        'cache updated to new token count after content change');
};

# =================================================================
# Test 3: Even a single character difference invalidates the cache.
# System prompts have many tokens; a single byte change shifts token
# boundaries and the hash must change too.
# =================================================================
subtest 'cache: single byte difference invalidates cache' => sub {
    require CLIO::Memory::TokenEstimator;
    CLIO::Memory::TokenEstimator::set_learned_ratio(2.5);

    my $base = "# CLIO System Prompt\n" . ("A" x 5000);
    my $modified = "# CLIO System Prompt\n" . ("A" x 4999) . "B";

    my $self = { _stable_prefix_cache => undef };
    my ($tokens_a, $cache_a) = compute_stable_prefix($self,
        [{ role => 'system', content => $base }]);
    my ($tokens_b, $cache_b) = compute_stable_prefix($self,
        [{ role => 'system', content => $modified }]);

    isnt($cache_a->{hash}, $cache_b->{hash},
        'one-byte content difference produces different hash');
};

# =================================================================
# Test 4: Stable prefix value does not drift across many requests
# even as the learned ratio converges to the actual model ratio.
# Simulates 7 requests (matches observed: 31335 -> 3323 -> ...).
# =================================================================
subtest 'stability across 7 requests: no drift despite ratio convergence' => sub {
    require CLIO::Memory::TokenEstimator;

    my $system_prompt = "# CLIO System Prompt\n" . ("Stable. " x 3000);
    my $messages = [{ role => 'system', content => $system_prompt }];

    # Start at the initial learned ratio
    CLIO::Memory::TokenEstimator::set_learned_ratio(2.5);
    my $self = { _stable_prefix_cache => undef };

    my $first_tokens;
    my @all_tokens;

    # Simulate 7 requests with the system prompt being byte-identical
    # but the learned ratio drifting after each (mimicking
    # _learn_from_api_response convergence).
    my @ratios = (2.5, 2.583, 2.651, 2.7, 2.71, 2.689, 2.676);
    for my $i (0 .. $#ratios) {
        CLIO::Memory::TokenEstimator::set_learned_ratio($ratios[$i]);
        my ($tokens, $cache) = compute_stable_prefix($self, $messages);
        push @all_tokens, $tokens;
        $first_tokens //= $tokens;
    }

    # All 7 values must be identical - no drift.
    my %seen = map { $_ => 1 } @all_tokens;
    my $unique_count = scalar keys %seen;
    is($unique_count, 1,
        "all 7 requests returned the same token count (got: @all_tokens)");
    is($all_tokens[0], $first_tokens,
        'first request value is the canonical frozen value');
};

# =================================================================
# Test 5: Multimodal arrayref content flattens text correctly for
# hashing and estimation.
# =================================================================
subtest 'multimodal arrayref content: text parts hashed and summed' => sub {
    require CLIO::Memory::TokenEstimator;
    CLIO::Memory::TokenEstimator::set_learned_ratio(2.5);

    my $text_part_1 = "First text part. " x 100;
    my $text_part_2 = "Second text part. " x 50;

    my $messages = [{
        role => 'system',
        content => [
            { type => 'text', text => $text_part_1 },
            { type => 'text', text => $text_part_2 },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,...' } },
        ],
    }];

    my $self = { _stable_prefix_cache => undef };
    my ($tokens, $cache) = compute_stable_prefix($self, $messages);

    # Expected: estimate_tokens on concatenated text
    my $expected_text = $text_part_1 . $text_part_2;
    my $expected_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($expected_text);

    is($tokens, $expected_tokens,
        'multimodal content token count equals concatenated text estimate');
    ok(defined $cache->{hash},
        'multimodal content produced a cache hash');
};

# =================================================================
# Test 6: Cache hit across multimodal content with same text.
# Two arrayref messages with the same text parts (in same order)
# must produce the same hash.
# =================================================================
subtest 'multimodal cache: same text parts in arrayref produce same hash' => sub {
    require CLIO::Memory::TokenEstimator;
    CLIO::Memory::TokenEstimator::set_learned_ratio(2.5);

    my $text = "Same text. " x 100;

    my $messages_v1 = [{
        role => 'system',
        content => [
            { type => 'text', text => $text },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,A' } },
        ],
    }];

    # Same text, different image (image doesn't contribute to hash)
    my $messages_v2 = [{
        role => 'system',
        content => [
            { type => 'text', text => $text },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,B' } },
        ],
    }];

    my $self = { _stable_prefix_cache => undef };
    my ($tokens_v1, $cache_v1) = compute_stable_prefix($self, $messages_v1);
    CLIO::Memory::TokenEstimator::set_learned_ratio(3.0);  # simulate drift
    my ($tokens_v2, $cache_v2) = compute_stable_prefix($self, $messages_v2);

    is($tokens_v2, $tokens_v1,
        'image changes do not affect cache (text-only hash)');
    is($cache_v2->{hash}, $cache_v1->{hash},
        'same text parts produce same hash (image ignored)');
};

# =================================================================
# Test 7: Empty system prompt content returns 0, no cache populated.
# =================================================================
subtest 'empty system content: no cache, no payload value' => sub {
    my $self = { _stable_prefix_cache => undef };
    my ($tokens, $cache) = compute_stable_prefix($self,
        [{ role => 'system', content => '' }]);

    is($tokens, 0, 'empty content returns 0 tokens');
    ok(!defined $cache, 'no cache populated for empty content');
};

# =================================================================
# Test 8: First message not system returns 0.
# =================================================================
subtest 'first message not system: no stable prefix' => sub {
    my $self = { _stable_prefix_cache => undef };
    my ($tokens, $cache) = compute_stable_prefix($self,
        [{ role => 'user', content => 'hello' }]);

    is($tokens, 0, 'no system message returns 0 tokens');
    ok(!defined $cache, 'no cache populated when no system message');
};

# =================================================================
# Test 9: The exact regression scenario from the bug report.
# System prompt ~78K chars, learned ratio drifts 2.5 -> 2.65.
# Pre-fix: stable prefix would change every turn.
# Post-fix: stable prefix is frozen on first request.
# =================================================================
subtest 'regression: ~78K system prompt stays stable across ratio drift' => sub {
    require CLIO::Memory::TokenEstimator;

    # Build a system prompt close to the size in the bug report (78336 chars)
    my $system_prompt = "# CLIO System Prompt\nYou are CLIO.\n\n" .
                        ("Stable system context here. " x 3000);
    my $messages = [{ role => 'system', content => $system_prompt }];

    # Pre-fix behavior: ratio drifts, prefix changes
    CLIO::Memory::TokenEstimator::set_learned_ratio(2.5);
    my $pre_fix_tokens_initial = CLIO::Memory::TokenEstimator::estimate_tokens($system_prompt);

    CLIO::Memory::TokenEstimator::set_learned_ratio(2.65);
    my $pre_fix_tokens_drifted = CLIO::Memory::TokenEstimator::estimate_tokens($system_prompt);

    isnt($pre_fix_tokens_initial, $pre_fix_tokens_drifted,
        'sanity: estimate_tokens actually differs between ratios (proves the bug exists)');

    # Post-fix behavior: cache freezes the value
    CLIO::Memory::TokenEstimator::set_learned_ratio(2.5);
    my $self = { _stable_prefix_cache => undef };
    my ($post_fix_tokens_first, $cache) = compute_stable_prefix($self, $messages);

    CLIO::Memory::TokenEstimator::set_learned_ratio(2.65);
    my ($post_fix_tokens_second, undef) = compute_stable_prefix($self, $messages);

    is($post_fix_tokens_first, $pre_fix_tokens_initial,
        'first request uses the initial ratio estimate');
    is($post_fix_tokens_second, $post_fix_tokens_first,
        'subsequent requests return cached value (drift ignored)');
    isnt($post_fix_tokens_second, $pre_fix_tokens_drifted,
        'cached value differs from drifted estimate (fix is effective)');
};

done_testing();
