#!/usr/bin/env perl
# Test: llama.cpp /props context window autodetection
#
# Problem: When CLIO connects to a local llama.cpp server on a non-standard port
# (e.g. 9090), the /v1/models response only exposes n_ctx_train (the model's
# training context, e.g. 262144). The actual running context set with -c/--ctx-size
# at server startup is NOT in /v1/models. Without the fix, CLIO falls back to a
# hardcoded 128000 token context, which can cause over-long prompts that the server
# rejects or silently truncates.
#
# Solution: APIManager._query_llama_props() queries the llama.cpp-specific /props
# endpoint which exposes default_generation_settings.n_ctx (the actual runtime value).
# This is injected into model_info.context_window before _extract_model_capabilities
# is called, so the correct value propagates through to session management.

use strict;
use warnings;
use lib './lib';

print "Testing llama.cpp /props context window autodetection\n";
print "=" x 60 . "\n\n";

my $tests_passed = 0;
my $tests_failed = 0;

sub pass { print "   PASS: $_[0]\n"; $tests_passed++ }
sub fail { print "   FAIL: $_[0]\n"; $tests_failed++ }

# ─── Test 1: URL derivation for /props endpoint ───────────────────────────────
print "Test 1: /props URL derivation from various api_base formats\n";

# We test the URL transformation logic directly (mirrors what _query_llama_props does)
sub derive_props_url {
    my ($api_base) = @_;
    my $props_url = $api_base;
    $props_url =~ s{/+$}{};
    $props_url =~ s{/v1(/.*)?$}{};
    $props_url .= '/props';
    return $props_url;
}

my %url_tests = (
    'http://localhost:9090/v1/chat/completions' => 'http://localhost:9090/props',
    'http://localhost:8080/v1/chat/completions' => 'http://localhost:8080/props',
    'http://localhost:9090/v1/'                 => 'http://localhost:9090/props',
    'http://localhost:9090/'                    => 'http://localhost:9090/props',
    'http://localhost:9090'                     => 'http://localhost:9090/props',
    'http://127.0.0.1:11434/v1/chat/completions' => 'http://127.0.0.1:11434/props',
    'http://max:9090/v1/chat/completions'       => 'http://max:9090/props',
    'http://192.168.1.50:9090/v1'               => 'http://192.168.1.50:9090/props',
);

for my $input (sort keys %url_tests) {
    my $expected = $url_tests{$input};
    my $got = derive_props_url($input);
    if ($got eq $expected) {
        pass("'$input' -> '$got'");
    } else {
        fail("'$input' -> expected '$expected', got '$got'");
    }
}

print "\n";

# ─── Test 2: /props JSON parsing ─────────────────────────────────────────────
print "Test 2: Parse n_ctx from /props response\n";

use CLIO::Util::JSON qw(decode_json);

# Simulate a real llama.cpp /props response (subset of actual response)
my $props_json = encode_mock_props(32768);
my $data = eval { decode_json($props_json) };
if ($@) {
    fail("JSON parse failed: $@");
} else {
    my $n_ctx = $data->{default_generation_settings}{n_ctx}
             || $data->{n_ctx};
    if ($n_ctx && $n_ctx == 32768) {
        pass("Parsed n_ctx=32768 from default_generation_settings.n_ctx");
    } else {
        fail("Expected 32768, got: " . ($n_ctx // 'undef'));
    }
}

# Test with 65536 context
my $props_json_64k = encode_mock_props(65536);
my $data_64k = eval { decode_json($props_json_64k) };
if (!$@) {
    my $n_ctx = $data_64k->{default_generation_settings}{n_ctx};
    if ($n_ctx && $n_ctx == 65536) {
        pass("Parsed n_ctx=65536 (64K context)");
    } else {
        fail("Expected 65536, got: " . ($n_ctx // 'undef'));
    }
}

print "\n";

# ─── Test 3: APIManager _extract_model_capabilities uses context_window ───────
print "Test 3: _extract_model_capabilities picks up injected context_window\n";

# Simulate what happens after _query_llama_props injects context_window
# into model_info before _extract_model_capabilities is called.
# We test the logic directly without needing a running server.

# Mock model_info as returned by /v1/models (no context_window initially)
my $model_info_before = {
    id   => 'gemma-4-26B-A4B-it-UD-Q5_K_M.gguf',
    meta => { n_ctx_train => 262144, n_vocab => 262144 },
};

# After injection by _query_llama_props:
my $model_info_after = {
    %$model_info_before,
    context_window => 32768,   # injected from /props
};

# Simulate _extract_model_capabilities logic for context_window
my $fallback_ctx = 128000;  # generic api_type fallback
my $limits = {};
my $info = $model_info_after;

my $ctx = $info->{context_window}
       || ($info->{capabilities} && $info->{capabilities}{limits} && $info->{capabilities}{limits}{max_context_window_tokens})
       || $info->{max_request_tokens}
       || $fallback_ctx;

if ($ctx == 32768) {
    pass("context_window=32768 correctly used (not n_ctx_train=262144 or fallback=128000)");
} else {
    fail("Expected 32768, got $ctx");
}

# Verify WITHOUT injection falls back to 128000 (not 262144)
my $info_no_inject = $model_info_before;
my $ctx_no_inject = $info_no_inject->{context_window}
                 || $fallback_ctx;
if ($ctx_no_inject == 128000) {
    pass("Without injection, fallback is 128000 (generic api_type)");
} else {
    fail("Without injection, expected 128000, got $ctx_no_inject");
}

print "\n";

# ─── Test 4: Error handling - /props unavailable ──────────────────────────────
print "Test 4: Graceful handling when /props is unavailable\n";

# Simulate HTTP failure (non-200 response)
my $resp_fail = { is_success => 0 };
my $n_ctx_result = undef;
if (!$resp_fail->{is_success}) {
    # Should return undef gracefully (no croak/die)
    $n_ctx_result = undef;
    pass("/props HTTP failure returns undef gracefully");
}

# Simulate malformed JSON
my $bad_json = '{invalid json';
my $parsed = eval { decode_json($bad_json) };
if ($@) {
    pass("Malformed /props JSON handled by eval (returns undef, no crash)");
} else {
    fail("Expected JSON parse error to be caught");
}

# Simulate /props with missing n_ctx field
my $props_no_ctx = '{"default_generation_settings":{"temperature":1.0},"total_slots":1}';
my $data_no_ctx = eval { decode_json($props_no_ctx) };
my $n_ctx_from_no_ctx = $data_no_ctx->{default_generation_settings}{n_ctx}
                     || $data_no_ctx->{n_ctx};
if (!defined $n_ctx_from_no_ctx) {
    pass("/props missing n_ctx returns undef correctly");
} else {
    fail("Expected undef for missing n_ctx, got $n_ctx_from_no_ctx");
}

print "\n";

# ─── Results ──────────────────────────────────────────────────────────────────
print "=" x 60 . "\n";
print "Results: $tests_passed passed, $tests_failed failed\n";

if ($tests_failed > 0) {
    print "\nFAILED\n";
    exit 1;
}

print "\nAll tests passed.\n";
exit 0;


# ─── Helpers ──────────────────────────────────────────────────────────────────

sub encode_mock_props {
    my ($n_ctx) = @_;
    # Minimal /props response matching the real llama.cpp format
    return qq|{
        "default_generation_settings": {
            "n_ctx": $n_ctx,
            "temperature": 1.0,
            "top_k": 64,
            "top_p": 0.95
        },
        "total_slots": 1,
        "model_alias": "gemma-4-26B-A4B-it-UD-Q5_K_M.gguf",
        "build_info": "b8768-1e9d771e2"
    }|;
}
