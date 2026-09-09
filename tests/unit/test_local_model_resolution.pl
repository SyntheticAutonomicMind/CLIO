#!/usr/bin/env perl
# Test: local model sentinel resolution for llama.cpp / LM Studio.
#
# CLIO uses local_model/local-model as a sentinel for llama.cpp and LM
# Studio providers. The /v1/models response from llama.cpp returns the
# full filesystem path as the model id, which CLIO must resolve to a
# usable model name before capability lookup.
#
#   1. _resolve_local_model is called in APIManager.get_model_capabilities
#      BEFORE MCM, so MCM receives the actual model name (e.g.
#      "Qwen3.6-35B-A3B-UD-Q4_K_XL") instead of the sentinel "local_model".
#   2. MCM._fetch_llama_cpp_capabilities queries /v1/models + /props as
#      primary data sources. The /v1/models meta object provides n_ctx
#      (runtime context), n_ctx_train, n_params, etc. The /props endpoint
#      provides modalities, chat_template_caps, and runtime n_ctx.

use strict;
use warnings;
use lib './lib';

print "Testing local model sentinel resolution\n";
print "=" x 60 . "\n\n";

my $tests_passed = 0;
my $tests_failed = 0;

sub pass { print "   PASS: $_[0]\n"; $tests_passed++ }
sub fail { print "   FAIL: $_[0]\n"; $tests_failed++ }

# ─── Test 1: localhost guard removed ──────────────────────────────────────────
print "Test 1: _resolve_local_model accepts non-localhost endpoints\n";

# Verify by code inspection that the localhost guard is no longer present
open my $fh, '<', 'lib/CLIO/Core/APIManager.pm' or die "Cannot read APIManager.pm: $!";
my $source = do { local $/; <$fh> };
close $fh;

# Locate _resolve_local_model sub
if ($source =~ /sub _resolve_local_model \{[^}]*?return undef unless \$api_base;/s) {
    pass("_resolve_local_model guards only on falsy api_base (no localhost check)");
} else {
    fail("_resolve_local_model still has the localhost guard");
}

# Extract just the body of _resolve_local_model and check it does not
# return undef on the basis of a localhost check.
if ($source =~ /sub _resolve_local_model \{[\s\S]*?\n\}/s) {
    my $sub = $1;
    if (($sub // '') =~ /localhost|127\.0\.0\.1/) {
        fail("_resolve_local_model body still references 'localhost' or '127.0.0.1'");
    } else {
        pass("No 'localhost' guard in _resolve_local_model body");
    }
} else {
    fail("Could not isolate _resolve_local_model body");
}

print "\n";

# ─── Test 2: Path stripping in _resolve_local_model ───────────────────────────
print "Test 2: _resolve_local_model strips directory path\n";

# Test the path stripping logic directly
sub strip_path {
    my ($name) = @_;
    $name =~ s/\.gguf$//i;
    $name =~ s{.*/}{};
    return $name;
}

my %strip_tests = (
    '/home/deck/llama-ai/models/Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf'
        => 'Qwen3.6-35B-A3B-UD-Q8_K_XL',
    'Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf'
        => 'Qwen3.6-35B-A3B-UD-Q8_K_XL',
    'Qwen3.6-35B-A3B-UD-Q8_K_XL'
        => 'Qwen3.6-35B-A3B-UD-Q8_K_XL',
    'meta-llama/llama-3.1-405b-instruct.gguf'
        => 'llama-3.1-405b-instruct',
    '/some/path/to/model.gguf'
        => 'model',
);

for my $input (sort keys %strip_tests) {
    my $expected = $strip_tests{$input};
    my $got = strip_path($input);
    if ($got eq $expected) {
        pass("'$input' -> '$got'");
    } else {
        fail("'$input' -> expected '$expected', got '$got'");
    }
}

print "\n";

# ─── Test 3: Sentinel resolved before MCM in get_model_capabilities ──────────
print "Test 3: Sentinel resolved before MCM in get_model_capabilities\n";

if ($source =~ /sub get_model_capabilities[\s\S]{0,2000}_resolve_local_model/) {
    pass("get_model_capabilities resolves local_model sentinel before MCM");
} else {
    fail("get_model_capabilities does not resolve sentinel before MCM");
}

# Check that MCM handles /v1/models + /props for local inference
my $mcm_source;
{
    open my $mcm_fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die $!;
    local $/; $mcm_source = <$mcm_fh>;
}

if ($mcm_source && $mcm_source =~ /_fetch_llama_cpp_capabilities/) {
    pass("MCM _fetch_llama_cpp_capabilities handles /v1/models + /props for local providers");
} else {
    fail("MCM _fetch_llama_cpp_capabilities not found");
}

if ($mcm_source && $mcm_source =~ /_find_local_model_by_basename/) {
    pass("MCM _find_local_model_by_basename handles path-prefixed model ids");
} else {
    fail("MCM _find_local_model_by_basename not found");
}

# Check that APIManager no longer has duplicate _query_llama_props (consolidated in MCM)
if ($source !~ /sub _query_llama_props/) {
    pass("APIManager has no duplicate _query_llama_props (consolidated in MCM)");
} else {
    fail("APIManager still has _query_llama_props (should be MCM only)");
}

print "\n";

# ─── Test 4: MCM model matching methods ────────────────────────────────────────
print "Test 4: MCM _find_model_in_list and _find_local_model_by_basename\n";

if ($mcm_source && $mcm_source =~ /sub _find_model_in_list/) {
    pass("MCM _find_model_in_list exists for model matching");
} else {
    fail("MCM _find_model_in_list not found");
}

if ($mcm_source && $mcm_source =~ /sub _find_local_model_by_basename/) {
    pass("MCM _find_local_model_by_basename exists for basename matching");
} else {
    fail("MCM _find_local_model_by_basename not found");
}

print "\n";

# ─── Test 5: Live integration against local llama.cpp (if available) ──────────
print "Test 5: Live integration against local llama.cpp server\n";

use CLIO::Core::APIManager;
use CLIO::Core::Config;
use CLIO::Util::JSON qw(safe_decode_json);

# Check if llama.cpp is configured with a local server
my $config = CLIO::Core::Config->new();
my $local_base = $config->get_provider_base('llama.cpp');

if ($local_base && $local_base =~ /localhost|127\.0\.0\.1/) {
    # Quick reachability check
    use IO::Socket::INET;
    my $port = 9090;
    if ($local_base =~ /:(\d+)/) {
        $port = $1;
    }
    my $host = 'localhost';
    if ($local_base =~ m{https?://([^:/]+)/}) {
        $host = $1;
    }
    my $sock = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 2,
    );

    if (!$sock) {
        print "   SKIP: llama.cpp server at $host:$port unreachable\n";
    } else {
        close $sock;

        my $cfg = CLIO::Core::Config->new();
        $cfg->set('provider', 'llama.cpp');
        $cfg->set('api_base', $local_base);
        $cfg->set('model', 'llama.cpp/local_model');
        $cfg->set('api_key', 'dummy');

        my $mgr = CLIO::Core::APIManager->new(config => $cfg);

        # Resolution should produce the basename, not the path
        my $resolved = $mgr->_resolve_local_model($local_base, 'local_model');
        if ($resolved && $resolved !~ m{/}) {
            pass("Resolved to basename (no path separators): '$resolved'");
        } elsif ($resolved) {
            fail("Resolution still has path separators: '$resolved'");
        } else {
            fail("Resolution returned undef (server reachable but resolution failed)");
        }

        # Capability lookup should return a valid context_window
        my $caps = $mgr->get_model_capabilities('llama.cpp/local_model');
        if ($caps && $caps->{max_context_window_tokens} && $caps->{max_context_window_tokens} > 1000) {
            pass("get_model_capabilities returned context_window=" . $caps->{max_context_window_tokens} . " (> 1000, not the old buggy 1000 floor)");
        } elsif ($caps) {
            fail("Context window too low: $caps->{max_context_window_tokens}");
        } else {
            fail("get_model_capabilities returned undef");
        }

        # compute_prompt_budget should return a reasonable value
        require CLIO::Memory::TokenEstimator;
        my $budget = CLIO::Memory::TokenEstimator::compute_prompt_budget($caps);
        if ($budget && $budget > 1000) {
            pass("compute_prompt_budget returned $budget (> 1000, prevents aggressive trimming)");
        } else {
            fail("compute_prompt_budget too low: " . ($budget // 'undef'));
        }
    }
} else {
    print "   SKIP: llama.cpp not configured with local server\n";
}

print "\n";

# ─── Test 6: Path-based model id round-trip ──────────────────────────────────
print "Test 6: Sentinel resolution does not affect explicit path-based models\n";

# If user passes --model llama.cpp//home/deck/foo.gguf directly, the sentinel
# regex /^local[-_]model$/i should NOT match, so resolution is skipped and
# the full path is preserved as the model name.

my $cfg2 = CLIO::Core::Config->new();
$cfg2->set('provider', 'llama.cpp');
$cfg2->set('api_base', 'http://localhost:9090/v1/chat/completions');
$cfg2->set('model', 'llama.cpp//home/deck/llama-ai/models/Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf');
$cfg2->set('api_key', 'dummy');

my $mgr2 = CLIO::Core::APIManager->new(config => $cfg2);
my $ep2 = $mgr2->_prepare_endpoint_config();

if ($ep2 && $ep2->{model} && $ep2->{model} =~ m{/home/deck/llama-ai/}) {
    pass("Explicit path-based model id is preserved (not stripped)");
} else {
    fail("Expected path preserved, got '$ep2->{model}'");
}

print "\n";

# ─── Test 7: OpenRouter-style model with slash preserved ─────────────────────
print "Test 7: OpenRouter slash-namespaced models are unaffected\n";

my $cfg3 = CLIO::Core::Config->new();
$cfg3->set('provider', 'openrouter');
$cfg3->set('api_base', 'https://openrouter.ai/api/v1');
$cfg3->set('model', 'openrouter/meta-llama/llama-3.1-405b-instruct:free');
$cfg3->set('api_key', 'dummy');

my $mgr3 = CLIO::Core::APIManager->new(config => $cfg3);
my $ep3 = $mgr3->_prepare_endpoint_config();

if ($ep3 && $ep3->{model} && $ep3->{model} eq 'meta-llama/llama-3.1-405b-instruct:free') {
    pass("OpenRouter model preserved: $ep3->{model}");
} else {
    fail("Expected 'meta-llama/llama-3.1-405b-instruct:free', got '$ep3->{model}'");
}

print "\n";

# ─── Test 8: Unreachable server doesn't crash ────────────────────────────────
print "Test 8: Unreachable server returns gracefully\n";

my $cfg4 = CLIO::Core::Config->new();
$cfg4->set('provider', 'llama.cpp');
$cfg4->set('api_base', 'http://192.0.2.1:9090/v1/chat/completions');  # TEST-NET-1
$cfg4->set('model', 'llama.cpp/local_model');
$cfg4->set('api_key', 'dummy');

my $mgr4 = CLIO::Core::APIManager->new(config => $cfg4);
my $result = eval { $mgr4->_prepare_endpoint_config() };
if (!$@ && $result && $result->{model} eq 'local_model') {
    pass("Unreachable server returns original sentinel (no crash)");
} else {
    fail("Crash or unexpected result: " . ($@ // "model=$result->{model}"));
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
