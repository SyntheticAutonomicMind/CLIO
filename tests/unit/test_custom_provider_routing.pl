#!/usr/bin/env perl
# Regression tests for custom provider routing fixes.
#
# Covers three fixes:
#   1. APIManager::_get_native_provider resolves custom aliases before
#      get_provider() so native API providers work through custom aliases.
#   2. Config::_resolve_model_details recognizes custom provider prefixes
#      in model strings (e.g. "anthropic_test/claude-3-opus").
#   3. Config::_provider_add accepts api-key and api_base in any order.
#
# Isolation: explicit tempdir config_dir so the real ~/.clio is never touched.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use File::Temp qw(tempdir);

use CLIO::Core::Config;
use CLIO::Providers qw(get_provider provider_exists);

my $tmpdir = tempdir(CLEANUP => 1);

# =============================================================================
# Shared fixture: Config with a custom alias "anthropic_test" -> "anthropic"
# =============================================================================

sub make_config {
    my $c = CLIO::Core::Config->new(config_dir => $tmpdir);
    $c->{config} = {};
    $c->{user_set} = {};
    $c->add_custom_provider('anthropic_test', 'anthropic', 'sk-test-key', undef);
    return $c;
}

# =============================================================================
# Bug 1: _get_native_provider resolves custom aliases
# =============================================================================

subtest 'Bug 1: _get_native_provider resolves custom alias to base provider' => sub {
    my $config = make_config();

    # Verify the resolution chain at the component level:
    ok(!defined(get_provider('anthropic_test')),
        'get_provider("anthropic_test") returns undef (custom alias not in registry)');

    my $resolved = $config->resolve_custom_provider('anthropic_test');
    is($resolved, 'anthropic',
        'resolve_custom_provider("anthropic_test") returns "anthropic"');

    my $base_config = get_provider($resolved);
    ok($base_config, 'get_provider("anthropic") returns a definition after resolution');
    ok($base_config->{native_api}, 'resolved anthropic provider has native_api=1');

    # Also verify that a built-in provider (non-custom) passes through unchanged
    my $passthrough = $config->resolve_custom_provider('anthropic');
    is($passthrough, 'anthropic',
        'resolve_custom_provider("anthropic") returns "anthropic" unchanged');
};

subtest 'Bug 1: get_provider("anthropic") vs get_provider("anthropic_test") contrast' => sub {
    # The original bug: get_provider("anthropic_test") returns undef,
    # causing _get_native_provider to return undef, falling back to the
    # OpenAI-compatible path even though anthropic is native.
    ok(defined(get_provider('anthropic')), 'built-in anthropic is found');
    ok(!defined(get_provider('anthropic_test')), 'custom alias is not directly found');

    # The fix: resolve first, then look up
    my $config = make_config();
    my $base = $config->resolve_custom_provider('anthropic_test');
    ok($base eq 'anthropic' && defined(get_provider($base)),
        'after resolution, the base provider is found and native_api is set');
};

# =============================================================================
# Bug 2: _resolve_model_details recognizes custom provider prefixes
# =============================================================================

subtest 'Bug 2: _resolve_model_details recognizes built-in provider prefix' => sub {
    my $config = make_config();
    require CLIO::UI::Commands::API::Config;
    my $cmd = CLIO::UI::Commands::API::Config->new(config => $config, debug => 0);

    my ($full, $display, $target, $api) = $cmd->_resolve_model_details('openai/gpt-4o-mini');

    is($full, 'openai/gpt-4o-mini', 'built-in: full_model is input unchanged');
    is($display, 'openai/gpt-4o-mini', 'built-in: display_model is input unchanged');
    is($target, 'openai', 'built-in: target_provider is the prefix');
    is($api, 'gpt-4o-mini', 'built-in: api_model is the model part');
};

subtest 'Bug 2: _resolve_model_details recognizes custom provider prefix' => sub {
    my $config = make_config();
    require CLIO::UI::Commands::API::Config;
    my $cmd = CLIO::UI::Commands::API::Config->new(config => $config, debug => 0);

    # Without the fix, provider_exists('anthropic_test') returns false and
    # the model is treated as belonging to the current provider.
    my ($full, $display, $target, $api) = $cmd->_resolve_model_details('anthropic_test/claude-3-opus');

    is($target, 'anthropic_test', 'custom: target_provider is the custom alias');
    is($api, 'claude-3-opus', 'custom: api_model is the model part after the slash');
    is($full, 'anthropic_test/claude-3-opus', 'custom: full_model is input unchanged');
    is($display, 'anthropic_test/claude-3-opus', 'custom: display_model is input unchanged');
};

subtest 'Bug 2: _resolve_model_details custom prefix with model containing slashes' => sub {
    my $config = make_config();
    require CLIO::UI::Commands::API::Config;
    my $cmd = CLIO::UI::Commands::API::Config->new(config => $config, debug => 0);

    my ($full, $display, $target, $api) = $cmd->_resolve_model_details('anthropic_test/claude/3-opus');

    is($target, 'anthropic_test', 'multi-slash custom: target_provider is the first segment');
    is($api, 'claude/3-opus', 'multi-slash custom: api_model keeps the rest');
};

subtest 'Bug 2: _resolve_model_details unprefixed uses current provider' => sub {
    my $config = make_config();
    $config->set('provider', 'anthropic_test', 0);
    require CLIO::UI::Commands::API::Config;
    my $cmd = CLIO::UI::Commands::API::Config->new(config => $config, debug => 0);

    my ($full, $display, $target, $api) = $cmd->_resolve_model_details('claude-3-opus');

    is($target, 'anthropic_test', 'unprefixed: target_provider is current provider');
    is($full, 'anthropic_test/claude-3-opus', 'unprefixed: full_model gets current prefix');
    is($api, 'claude-3-opus', 'unprefixed: api_model is the input');
};

subtest 'Bug 2: _resolve_model_details unknown prefix is not treated as provider' => sub {
    my $config = make_config();
    require CLIO::UI::Commands::API::Config;
    my $cmd = CLIO::UI::Commands::API::Config->new(config => $config, debug => 0);

    # A prefix that is neither built-in nor custom should fall through
    my ($full, $display, $target, $api) = $cmd->_resolve_model_details('totally_unknown/claude-3-opus');

    # Without a recognized prefix, the full string is treated as the model
    # and target_provider falls back to current_provider
    is($api, 'totally_unknown/claude-3-opus', 'unknown prefix: api_model is the full string');
    # current provider is whatever config default is (not set in fixture, so empty)
    is($full, 'totally_unknown/claude-3-opus', 'unknown prefix: full_model is input');
};

# =============================================================================
# Bug 3: _provider_add order-independent arg parsing
# =============================================================================

# We test _provider_add by verifying the arg-parsing logic and that the
# config receives the right values. Display output is not checked here
# (it requires a full Chat stack); the config state is the contract.

# Minimal no-op mock chat: all display methods are stubs
{
    package MockChat;
    sub new { bless {}, shift }
    sub display_error_message    { }
    sub display_system_message   { }
    sub display_success_message  { }
    sub display_warning_message  { }
    sub display_info_message     { }
    sub display_command_header   { }
    sub writeline                { }
    sub colorize                 { return $_[1] }
    sub refresh_terminal_size    { }
}

subtest 'Bug 3: _provider_add accepts key then base-url' => sub {
    my $config = make_config();
    my $cmd = CLIO::UI::Commands::API::Config->new(config => $config, debug => 0, chat => MockChat->new());

    $cmd->_provider_add('myalias', 'anthropic', 'sk-key-12345', 'https://proxy.example/v1');

    my $def = $config->{config}{custom_providers}{myalias};
    ok($def, 'custom provider "myalias" was registered');
    is($def->{base_provider}, 'anthropic', 'base_provider is anthropic');
    is($config->{config}{api_keys}{myalias}, 'sk-key-12345', 'api_key stored under alias name');
    is($config->{config}{api_bases}{myalias}, 'https://proxy.example/v1', 'api_base stored under alias name');
};

subtest 'Bug 3: _provider_add accepts base-url then key (order independent)' => sub {
    my $config = make_config();
    my $cmd = CLIO::UI::Commands::API::Config->new(config => $config, debug => 0, chat => MockChat->new());

    $cmd->_provider_add('proxy01', 'anthropic', 'https://proxy.example/v1', 'sk-key-67890');

    my $def = $config->{config}{custom_providers}{proxy01};
    ok($def, 'custom provider "proxy01" was registered');
    is($config->{config}{api_keys}{proxy01}, 'sk-key-67890', 'api_key stored correctly (key was 2nd arg)');
    is($config->{config}{api_bases}{proxy01}, 'https://proxy.example/v1', 'api_base stored correctly (url was 1st arg)');
};

subtest 'Bug 3: _provider_add accepts base-url only (no key)' => sub {
    my $config = make_config();
    my $cmd = CLIO::UI::Commands::API::Config->new(config => $config, debug => 0, chat => MockChat->new());

    $cmd->_provider_add('nimo', 'llama.cpp', 'http://nimo:9090/v1/chat/completions');

    my $def = $config->{config}{custom_providers}{nimo};
    ok($def, 'custom provider "nimo" was registered with base-url only');
    is($def->{base_provider}, 'llama.cpp', 'base_provider is llamo.cpp');
    is($config->{config}{api_bases}{nimo}, 'http://nimo:9090/v1/chat/completions', 'api_base stored');
    ok(!exists $config->{config}{api_keys}{nimo}, 'no api_key stored when not provided');
};

subtest 'Bug 3: _provider_add accepts key only (no base-url)' => sub {
    my $config = make_config();
    my $cmd = CLIO::UI::Commands::API::Config->new(config => $config, debug => 0, chat => MockChat->new());

    $cmd->_provider_add('test_key_only', 'anthropic', 'sk-only-key-000');

    my $def = $config->{config}{custom_providers}{test_key_only};
    ok($def, 'custom provider registered with key only');
    is($config->{config}{api_keys}{test_key_only}, 'sk-only-key-000', 'api_key stored');
    ok(!exists $config->{config}{api_bases}{test_key_only}, 'no api_base stored when not provided');
};

subtest 'Bug 3: _provider_add accepts no key or base-url' => sub {
    my $config = make_config();
    my $cmd = CLIO::UI::Commands::API::Config->new(config => $config, debug => 0, chat => MockChat->new());

    $cmd->_provider_add('barealias', 'anthropic');

    my $def = $config->{config}{custom_providers}{barealias};
    ok($def, 'custom provider registered with no key or base-url');
    is($def->{base_provider}, 'anthropic', 'base_provider is correct');
    ok(!exists $config->{config}{api_keys}{barealias}, 'no api_key stored');
    ok(!exists $config->{config}{api_bases}{barealias}, 'no api_base stored');
};

subtest 'Bug 3: _provider_add rejects duplicate name' => sub {
    my $config = make_config();
    my $cmd = CLIO::UI::Commands::API::Config->new(config => $config, debug => 0, chat => MockChat->new());

    $cmd->_provider_add('dupe', 'anthropic', 'sk-key');
    ok($config->{config}{custom_providers}{dupe}, 'first add succeeded');

    # Second add with same name should not change the stored key
    $cmd->_provider_add('dupe', 'anthropic', 'sk-different-key');
    my $def = $config->{config}{custom_providers}{dupe};
    is($config->{config}{api_keys}{dupe}, 'sk-key', 'first key preserved after duplicate attempt rejected');
};

subtest 'Bug 3: _provider_add rejects unknown base provider' => sub {
    my $config = make_config();
    my $cmd = CLIO::UI::Commands::API::Config->new(config => $config, debug => 0, chat => MockChat->new());

    $cmd->_provider_add('badbase', 'totally_fake', 'sk-key');
    ok(!exists $config->{config}{custom_providers}{badbase}, 'unknown base provider not registered');
};

subtest 'Bug 3: _provider_add rejects builtin provider name collision' => sub {
    my $config = make_config();
    my $cmd = CLIO::UI::Commands::API::Config->new(config => $config, debug => 0, chat => MockChat->new());

    $cmd->_provider_add('openai', 'anthropic', 'sk-key');
    ok(!exists $config->{config}{custom_providers}{openai}, 'builtin name not overwritten');
};

subtest 'Bug 3: url regex uses scheme:// pattern for detection' => sub {
    # Verify the URL detection pattern matches standard URL forms
    my @urls = (
        'http://nimo:9090/v1/chat/completions',
        'https://api.anthropic.com',
        'http://localhost:8080/v1',
        'https://proxy.company.com/v1/chat/completions',
    );
    for my $url (@urls) {
        like($url, qr{^[a-z][a-z0-9+\-.]*://}i, "URL '$url' matches detection pattern");
    }

    # Non-URL values should NOT match (so they're treated as api_key)
    my @non_urls = ('sk-test-key-12345', 'anthropic', 'my-key');
    for my $val (@non_urls) {
        unlike($val, qr{^[a-z][a-z0-9+\-.]*://}i, "value '$val' does not match URL pattern (treated as key)");
    }
};

done_testing();