#!/usr/bin/env perl

use strict;
use warnings;
use lib 'lib';

# Disable buffering
$| = 1;

use CLIO::Memory::TokenEstimator;
use CLIO::Util::JSON;

print "Token JSON Encoding Test\n";
print "=========================\n\n";

# Test 1: estimate_tokens returns a value that JSON::XS encodes as number, not string
my $text = "Hello, world! This is a test of the token estimator.";
my $tokens = CLIO::Memory::TokenEstimator::estimate_tokens($text);
print "Test 1: estimate_tokens returns numeric JSON type\n";

my $json = CLIO::Util::JSON::encode_json({ prompt_stable_prefix_tokens => $tokens });
print "  JSON: " . $json . "\n";

if ($json =~ /"prompt_stable_prefix_tokens":\d+/) {
    print "  PASS: Encoded as number\n\n";
} else {
    print "  FAIL: Encoded as string - llama.cpp will reject with type_error.302\n\n";
    exit 1;
}

# Test 2: Simulate the cache hit scenario from APIManager
# This reproduces the exact bug: log_debug stringifies $stable_tokens,
# then it gets stored in cache, then retrieved on next turn
print "Test 2: Cache hit scenario (stored after log, retrieved for payload)\n";
my $stable_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($text);
if ($stable_tokens > 0) {
    # Simulate log_debug string interpolation (this sets POK flag on $stable_tokens)
    my $log_msg = "Including prompt_stable_prefix_tokens: $stable_tokens (cached)";
    # Store in cache with 0+ (the fix)
    my $cache = { tokens => 0 + $stable_tokens };
    # Simulate next turn: retrieve from cache and put in payload with 0+
    my $payload = { prompt_stable_prefix_tokens => 0 + $cache->{tokens} };
    my $json2 = CLIO::Util::JSON::encode_json($payload);
    print "  Log message: " . $log_msg . "\n";
    print "  JSON from cache: " . $json2 . "\n";

    if ($json2 =~ /"prompt_stable_prefix_tokens":\d+/) {
        print "  PASS: Cache hit produces numeric JSON\n\n";
    } else {
        print "  FAIL: Cache hit produces string JSON\n\n";
        exit 1;
    }
}

# Test 3: Without the 0+ fix (simulate the old buggy behavior)
print "Test 3: Without 0+ fix (old behavior - should fail)\n";
my $stable_tokens_old = CLIO::Memory::TokenEstimator::estimate_tokens($text);
my $log_msg_old = "Including prompt_stable_prefix_tokens: $stable_tokens_old (cached)";
my $cache_old = { tokens => $stable_tokens_old };  # No 0+
my $payload_old = { prompt_stable_prefix_tokens => $cache_old->{tokens} };  # No 0+
my $json3 = CLIO::Util::JSON::encode_json($payload_old);
print "  JSON without fix: " . $json3 . "\n";

if ($json3 !~ /"prompt_stable_prefix_tokens":\d+/) {
    print "  PASS: Old behavior correctly produces string JSON (confirming bug exists)\n\n";
} else {
    print "  NOTE: Old behavior also produces numeric JSON (unexpected)\n\n";
}

# Test 4: estimate_tokens with arrayref content
print "Test 4: estimate_tokens with arrayref (multimodal)\n";
my $multimodal = [{ type => 'text', text => 'Hello world' }];
my $multi_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($multimodal);
my $json4 = CLIO::Util::JSON::encode_json({ prompt_stable_prefix_tokens => $multi_tokens });
print "  JSON: " . $json4 . "\n";

if ($json4 =~ /"prompt_stable_prefix_tokens":\d+/) {
    print "  PASS: Multimodal result encoded as number\n\n";
} else {
    print "  FAIL: Multimodal result encoded as string\n\n";
    exit 1;
}

print "All tests passed!\n";
exit 0;