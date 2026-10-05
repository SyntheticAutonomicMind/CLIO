#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Manual integration test: Verify OpenRouter prompt cache behavior.
#
# Requires: CLIO_LIVE_CACHE_TEST=1 env var set (never runs automatically).
# Requires: A valid OpenRouter API key configured in CLIO.
# Requires: An OpenRouter account with billing enabled.
#
# This test sends two controlled API requests to OpenRouter and verifies
# that cached_tokens > 0 on the second request, proving that the stable
# session_id + stable system prompt prefix produces a cache hit.
#
# Usage:
#   CLIO_LIVE_CACHE_TEST=1 perl tests/manual/live_cache_test.pl
#
# Non-sensitive diagnostics are printed to STDOUT. No prompt content
# or secrets are logged.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);

# Never auto-run — this hits a live paid API.
die "Set CLIO_LIVE_CACHE_TEST=1 to run this test (it charges OpenRouter credits)\n"
    unless $ENV{CLIO_LIVE_CACHE_TEST};

use CLIO::Core::Config;
use CLIO::Core::APIManager;
use CLIO::Session::Manager;
use CLIO::Core::PromptBuilder;
use CLIO::Core::ContextBuilder;
use CLIO::Core::MessageHistory qw(messages_to_prose_dynamic);
use CLIO::Util::JSON qw(encode_json decode_json);
use CLIO::Util::PathResolver;

print "=== CLIO Live Cache Diagnostic ===\n\n";

# Load config
my $config = CLIO::Core::Config->new();
my $provider = $config->get('provider') || 'openrouter';
my $model = $config->get('model') || die "No model configured\n";
my $api_key = $config->get('api_key') || $config->get('api_keys')->{$provider} || die "No API key for $provider\n";

print "Provider: $provider\n";
print "Model:    $model\n";
print "API Key:  " . substr($api_key, 0, 4) . "..." . substr($api_key, -4) . " (redacted)\n\n";

# Create a session
my $session = CLIO::Session::Manager->create(working_directory => '/tmp', debug => 0);
my $session_id = $session->id();
print "Session UUID: $session_id\n";
print "OpenRouter session_id that will be sent: clio:$session_id\n";
print "  (length: " . (5 + length($session_id)) . " chars, limit: 256)\n\n";

# Build system prompt
my $pb = CLIO::Core::PromptBuilder->new(debug => 0);
my $system_prompt = $pb->build_system_prompt();
my $system_hash = substr(sha256_hex(encode_utf8($system_prompt)), 0, 16);
print "System prompt fingerprint (SHA-256 first 16): $system_hash\n";
print "System prompt length: " . length($system_prompt) . " chars\n\n";

# --- Request 1: Send a simple prompt, warm the cache ---
print "--- Request 1: Warming cache ---\n";

my $messages1 = [
    { role => 'system',  content => $system_prompt },
    { role => 'user',    content => 'Explain the significance of the Turing test in 3 sentences.' },
];

my $p1 = $session;  # pass session to APIManager
my $api1 = CLIO::Core::APIManager->new(
    config => $config,
    session => $p1,
    debug => 1,
);

# We need to capture the response. Let's use send_request_streaming
# which accumulates tokens and returns a result hash.
my $result1 = $api1->send_request_streaming($messages1, $model);

my $usage1 = $result1->{usage} || {};
my $cached1 = $usage1->{prompt_tokens}->{prompt_tokens_details}->{cached_tokens} // 0;
my $cache_write1 = $usage1->{prompt_tokens}->{prompt_tokens_details}->{cache_write_tokens} // 0;

print "  finish_reason: " . ($usage1->{finish_reason} // 'unknown') . "\n";
print "  prompt_tokens: " . ($usage1->{prompt_tokens} // 0) . "\n";
print "  cached_tokens: $cached1 (expected ~0 on first request)\n";
print "  cache_write_tokens: $cache_write1 (expected >0 on first request)\n\n";

# --- Request 2: Same session, same system prompt, DIFFERENT user query ---
# This should get a cache hit because session_id is stable and the system
# prompt prefix is identical.
print "--- Request 2: Verifying cache hit ---\n";

my $messages2 = [
    { role => 'system',  content => $system_prompt },
    { role => 'user',    content => 'What is the capital of France? Answer in 1 sentence.' },
];

my $api2 = CLIO::Core::APIManager->new(
    config => $config,
    session => $p1,  # SAME session
    debug => 1,
);

my $result2 = $api2->send_request_streaming($messages2, $model);

my $usage2 = $result2->{usage} || {};
my $cached2 = $usage2->{prompt_tokens}->{prompt_tokens_details}->{cached_tokens} // 0;
my $cache_write2 = $usage2->{prompt_tokens}->{prompt_tokens_details}->{cache_write_tokens} // 0;

print "  finish_reason: " . ($usage2->{finish_reason} // 'unknown') . "\n";
print "  prompt_tokens: " . ($usage2->{prompt_tokens} // 0) . "\n";
print "  cached_tokens: $cached2 (expected >0 on second request)\n";
print "  cache_write_tokens: $cache_write2\n\n";

# --- Summary ---
print "=== Summary ===\n";
print "Session ID (stable): clio:$session_id\n";
print "System prompt hash:   $system_hash (unchanged between requests)\n";

if ($cached2 > 0) {
    print "RESULT: PASS — cached_tokens = $cached2 on request 2\n";
    print "The stable session_id + stable system prompt produced a cache hit.\n";
    exit 0;
} else {
    print "RESULT: CHECK — cached_tokens = 0 on request 2\n";
    print "This could be due to:\n";
    print "  - Cache TTL expiry (OpenRouter cache window)\n";
    print "  - Model/provider caching not enabled for this model\n";
    print "  - Minimum cache length not met (prompt too short)\n";
    print "  - Provider routing differences\n";
    print "\nCheck --debug output for CacheDiag fingerprints.\n";
    exit 1;
}
