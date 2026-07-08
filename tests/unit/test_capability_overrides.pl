#!/usr/bin/env perl
# Test /api set capability overrides (context_window, max_output, max_prompt,
# tools, vision, reasoning) and APIManager override application.
#
# Covers:
# - Token count parsing (128k, 1M, raw integers, edge cases)
# - Token count formatting (128000 -> "128k")
# - _set_capability_cap (context_window, max_output, max_prompt)
# - _set_capability_force (tools, vision, reasoning)
# - APIManager _apply_capability_overrides (numeric caps + boolean forces)
# - APIManager _caps_with_overrides (cache stores raw, returns post-override)
# - Session override precedence over global config

use strict;
use warnings;
use lib './lib';
use Test::More;

use CLIO::UI::Commands::API::Config;
use CLIO::Core::APIManager;
use CLIO::Core::Config;

# =============================================================================
# Helpers
# =============================================================================

# Create a fresh Config and stub AI agent for API::Config handler tests.
sub make_api_config_cmd {
    my $config = CLIO::Core::Config->new(config_dir => '/tmp/clio_cap_test_' . int(rand(1e9)));
    $config->{config} = {};
    $config->{user_set} = {};
    $config->{config}{provider} = 'github_copilot';
    $config->{user_set}{provider} = 1;

    # Stub chat for output capture
    my $chat = bless {
        output => [],
    }, 'FakeChat';

    # Stub AI agent (display_config reads caps from $self->{ai_agent}->{api})
    my $ai = bless { api => undef }, 'FakeAI';

    my $cmd = CLIO::UI::Commands::API::Config->new(
        chat => $chat,
        config => $config,
        session => undef,
        ai_agent => $ai,
        debug => 0,
    );
    return ($cmd, $config);
}

sub _make_config_with_provider {
    my $dir = '/tmp/clio_cap_mgr_' . int(rand(1e9));
    mkdir $dir;
    my $cfg = "$dir/config.json";
    open(my $fh, '>', $cfg) or die "Cannot create config: $!";
    print $fh q({"provider": "github_copilot"});
    close $fh;
    return CLIO::Core::Config->new(config_dir => $dir);
}
# Fake chat that captures output for assertions.
package FakeChat;
sub new { bless { output => [] }, shift }
sub display_command_header  { my ($s, $t) = @_; push @{$s->{output}}, "HEADER:$t" }
sub display_section_header  { my ($s, $t) = @_; push @{$s->{output}}, "SECTION:$t" }
sub display_command_row     { my ($s, $a, $b, $c) = @_; push @{$s->{output}}, "ROW:$a|$b" }
sub display_key_value       { my ($s, $a, $b, $c) = @_; push @{$s->{output}}, "KV:$a|$b" }
sub display_system_message  { my ($s, $t) = @_; push @{$s->{output}}, "SYS:$t" }
sub display_success_message { my ($s, $t) = @_; push @{$s->{output}}, "OK:$t" }
sub display_error_message   { my ($s, $t) = @_; push @{$s->{output}}, "ERR:$t" }
sub writeline               { push @{$_[0]->{output}}, "WL:" . ($_[1] // '') }
sub colorize                { my ($s, $t, $c) = @_; return $t }
sub _format_tokens          { $_[1] // 0 }

package FakeAI;
sub new { bless { api => $_[1] // undef }, shift }
sub api { $_[0]->{api} }

package FakeSession;
sub new { bless { state_fn => $_[1] }, shift }
sub state { my $s = shift; return $s->{state} ? $s->{state}->() : $s->{state_fn}->() }
sub can  { 1 }

package main;

# =============================================================================
# Test: _parse_token_count
# =============================================================================

subtest '_parse_token_count handles plain integers' => sub {
    is(CLIO::UI::Commands::API::Config::_parse_token_count('128000'), 128000,
        'plain integer parsed');
    is(CLIO::UI::Commands::API::Config::_parse_token_count('0'), 0,
        'zero parsed');
    is(CLIO::UI::Commands::API::Config::_parse_token_count('1'), 1,
        'one parsed');
    is(CLIO::UI::Commands::API::Config::_parse_token_count('1000000'), 1000000,
        'million parsed');
};

subtest '_parse_token_count handles k suffix' => sub {
    is(CLIO::UI::Commands::API::Config::_parse_token_count('128k'), 128000,
        '128k -> 128000');
    is(CLIO::UI::Commands::API::Config::_parse_token_count('128K'), 128000,
        '128K (uppercase) -> 128000');
    is(CLIO::UI::Commands::API::Config::_parse_token_count('1.5k'), 1500,
        '1.5k -> 1500');
    is(CLIO::UI::Commands::API::Config::_parse_token_count('256k'), 256000,
        '256k -> 256000');
};

subtest '_parse_token_count handles M suffix' => sub {
    is(CLIO::UI::Commands::API::Config::_parse_token_count('1M'), 1000000,
        '1M -> 1000000');
    is(CLIO::UI::Commands::API::Config::_parse_token_count('2m'), 2000000,
        '2m (lowercase) -> 2000000');
    is(CLIO::UI::Commands::API::Config::_parse_token_count('1.5M'), 1500000,
        '1.5M -> 1500000');
};

subtest '_parse_token_count rejects invalid input' => sub {
    is(CLIO::UI::Commands::API::Config::_parse_token_count(undef), undef,
        'undef -> undef');
    is(CLIO::UI::Commands::API::Config::_parse_token_count(''), undef,
        'empty string -> undef');
    is(CLIO::UI::Commands::API::Config::_parse_token_count('abc'), undef,
        'non-numeric -> undef');
    is(CLIO::UI::Commands::API::Config::_parse_token_count('128g'), undef,
        'unsupported suffix -> undef');
    is(CLIO::UI::Commands::API::Config::_parse_token_count('k128'), undef,
        'misplaced suffix -> undef');
};

subtest '_parse_token_count strips whitespace' => sub {
    is(CLIO::UI::Commands::API::Config::_parse_token_count('  128k  '), 128000,
        'leading/trailing whitespace stripped');
};

# =============================================================================
# Test: _format_token_count
# =============================================================================

subtest '_format_token_count formats values correctly' => sub {
    is(CLIO::UI::Commands::API::Config::_format_token_count(128000), '128k',
        '128000 -> 128k');
    is(CLIO::UI::Commands::API::Config::_format_token_count(1000000), '1M',
        '1000000 -> 1M');
    is(CLIO::UI::Commands::API::Config::_format_token_count(1500000), '1.5M',
        '1500000 -> 1.5M');
    is(CLIO::UI::Commands::API::Config::_format_token_count(1500), '1.5k',
        '1500 -> 1.5k');
    is(CLIO::UI::Commands::API::Config::_format_token_count(0), '0',
        '0 -> 0');
    is(CLIO::UI::Commands::API::Config::_format_token_count(undef), '0',
        'undef -> 0');
    is(CLIO::UI::Commands::API::Config::_format_token_count(500), '500',
        '500 -> 500 (no suffix)');
};

# =============================================================================
# Test: _humanize_cap_name
# =============================================================================

subtest '_humanize_cap_name produces user-friendly labels' => sub {
    is(CLIO::UI::Commands::API::Config::_humanize_cap_name('context_window'),
        'Context window', 'context_window -> Context window');
    is(CLIO::UI::Commands::API::Config::_humanize_cap_name('max_output'),
        'Max output', 'max_output -> Max output');
    is(CLIO::UI::Commands::API::Config::_humanize_cap_name('max_prompt'),
        'Max prompt', 'max_prompt -> Max prompt');
    is(CLIO::UI::Commands::API::Config::_humanize_cap_name('unknown'),
        'unknown', 'unknown -> unknown (passthrough)');
};

# =============================================================================
# Test: _set_capability_cap (context_window, max_output, max_prompt)
# =============================================================================

subtest '_set_capability_cap sets context_window with k suffix' => sub {
    my ($cmd, $config) = make_api_config_cmd();
    $cmd->_set_capability_cap('context_window', '128k', 0);
    is($config->get('cap_context_window'), 128000,
        'cap_context_window set to 128000');
    like(join('', @{$cmd->{chat}{output}}), qr/capped at 128k/,
        'success message shown');
};

subtest '_set_capability_cap sets context_window with M suffix' => sub {
    my ($cmd, $config) = make_api_config_cmd();
    $cmd->_set_capability_cap('context_window', '1M', 0);
    is($config->get('cap_context_window'), 1000000,
        'cap_context_window set to 1000000');
};

subtest '_set_capability_cap sets max_output' => sub {
    my ($cmd, $config) = make_api_config_cmd();
    $cmd->_set_capability_cap('max_output', '16k', 0);
    is($config->get('cap_max_output'), 16000,
        'cap_max_output set to 16000');
};

subtest '_set_capability_cap sets max_prompt' => sub {
    my ($cmd, $config) = make_api_config_cmd();
    $cmd->_set_capability_cap('max_prompt', '200k', 0);
    is($config->get('cap_max_prompt'), 200000,
        'cap_max_prompt set to 200000');
};

subtest '_set_capability_cap rejects too-small values' => sub {
    my ($cmd, $config) = make_api_config_cmd();
    # Save prior value to confirm it wasn't changed
    my $prior = $config->get('cap_context_window') // 0;
    $cmd->_set_capability_cap('context_window', '500', 0);
    is($config->get('cap_context_window') // 0, $prior,
        'cap not changed for sub-1000 value');
    like(join('', @{$cmd->{chat}{output}}), qr/too small/i,
        'error message shown');
};

subtest '_set_capability_cap rejects invalid input' => sub {
    my ($cmd, $config) = make_api_config_cmd();
    my $prior = $config->get('cap_context_window') // 0;
    $cmd->_set_capability_cap('context_window', 'abc', 0);
    is($config->get('cap_context_window') // 0, $prior,
        'cap not changed for invalid input');
    like(join('', @{$cmd->{chat}{output}}), qr/Invalid/i,
        'error message shown');
};

subtest '_set_capability_cap reset clears the cap' => sub {
    my ($cmd, $config) = make_api_config_cmd();
    $config->set('cap_context_window', 128000);
    $cmd->_set_capability_cap('context_window', 'reset', 0);
    is($config->get('cap_context_window'), 0,
        'cap cleared by reset');
    like(join('', @{$cmd->{chat}{output}}), qr/cleared/i,
        'cleared message shown');
};

subtest '_set_capability_cap default also clears the cap' => sub {
    my ($cmd, $config) = make_api_config_cmd();
    $config->set('cap_context_window', 128000);
    $cmd->_set_capability_cap('context_window', 'default', 0);
    is($config->get('cap_context_window'), 0,
        'cap cleared by default');
};

subtest '_set_capability_cap zero also clears the cap' => sub {
    my ($cmd, $config) = make_api_config_cmd();
    $config->set('cap_context_window', 128000);
    $cmd->_set_capability_cap('context_window', '0', 0);
    is($config->get('cap_context_window'), 0,
        'cap cleared by 0');
};

# =============================================================================
# Test: _set_capability_force (tools, vision, reasoning)
# =============================================================================

subtest '_set_capability_force sets tools on' => sub {
    my ($cmd, $config) = make_api_config_cmd();
    $cmd->_set_capability_force('tools', 'on', 0);
    is($config->get('force_tools'), 'on',
        'force_tools set to on');
};

subtest '_set_capability_force sets tools off' => sub {
    my ($cmd, $config) = make_api_config_cmd();
    $cmd->_set_capability_force('tools', 'off', 0);
    is($config->get('force_tools'), 'off',
        'force_tools set to off');
};

subtest '_set_capability_force accepts synonyms' => sub {
    my ($cmd, $config) = make_api_config_cmd();
    $cmd->_set_capability_force('vision', 'enabled', 0);
    is($config->get('force_vision'), 'on',
        'enabled normalized to on');
    $cmd->_set_capability_force('vision', 'disabled', 0);
    is($config->get('force_vision'), 'off',
        'disabled normalized to off');
    $cmd->_set_capability_force('reasoning', 'true', 0);
    is($config->get('force_reasoning'), 'on',
        'true normalized to on');
    $cmd->_set_capability_force('reasoning', 'false', 0);
    is($config->get('force_reasoning'), 'off',
        'false normalized to off');
};

subtest '_set_capability_force auto clears the force' => sub {
    my ($cmd, $config) = make_api_config_cmd();
    $config->set('force_tools', 'on');
    $cmd->_set_capability_force('tools', 'auto', 0);
    is($config->get('force_tools'), '',
        'force cleared by auto');
};

subtest '_set_capability_force reset clears the force' => sub {
    my ($cmd, $config) = make_api_config_cmd();
    $config->set('force_tools', 'on');
    $cmd->_set_capability_force('tools', 'reset', 0);
    is($config->get('force_tools'), '',
        'force cleared by reset');
};

subtest '_set_capability_force rejects invalid input' => sub {
    my ($cmd, $config) = make_api_config_cmd();
    $cmd->_set_capability_force('tools', 'maybe', 0);
    is($config->get('force_tools'), undef,
        'force not set for invalid input');
    like(join('', @{$cmd->{chat}{output}}), qr/Invalid/i,
        'error message shown');
};

# =============================================================================
# Test: APIManager _apply_capability_overrides
# =============================================================================

subtest '_apply_capability_overrides caps context_window' => sub {
    my $config = _make_config_with_provider();
    $config->set('cap_context_window', 128000);

    my $mgr = CLIO::Core::APIManager->new(config => $config, debug => 0);
    my $caps = {
        max_context_window_tokens => 1000000,
        max_output_tokens         => 16384,
        max_prompt_tokens         => 1000000,
        supports_tools            => 1,
        supports_vision           => 0,
        supports_reasoning        => 1,
    };

    $mgr->_apply_capability_overrides($caps);
    is($caps->{max_context_window_tokens}, 128000,
        'context_window capped from 1M to 128k');
    is($caps->{max_output_tokens}, 16384,
        'max_output unchanged');
    is($caps->{supports_tools}, 1,
        'supports_tools unchanged');
};

subtest '_apply_capability_overrides does not raise when override exceeds model' => sub {
    my $config = _make_config_with_provider();
    $config->set('cap_context_window', 2000000);  # 2M override

    my $mgr = CLIO::Core::APIManager->new(config => $config, debug => 0);
    my $caps = {
        max_context_window_tokens => 1000000,  # 1M model
        max_output_tokens         => 16384,
        max_prompt_tokens         => 1000000,
    };

    $mgr->_apply_capability_overrides($caps);
    is($caps->{max_context_window_tokens}, 1000000,
        'context_window stays at 1M (override exceeds model, no cap applied)');
};

subtest '_apply_capability_overrides caps max_output' => sub {
    my $config = _make_config_with_provider();
    $config->set('cap_max_output', 8192);

    my $mgr = CLIO::Core::APIManager->new(config => $config, debug => 0);
    my $caps = {
        max_context_window_tokens => 1000000,
        max_output_tokens         => 16384,
        max_prompt_tokens         => 1000000,
    };

    $mgr->_apply_capability_overrides($caps);
    is($caps->{max_output_tokens}, 8192,
        'max_output capped from 16384 to 8192');
};

subtest '_apply_capability_overrides caps max_prompt' => sub {
    my $config = _make_config_with_provider();
    $config->set('cap_max_prompt', 200000);

    my $mgr = CLIO::Core::APIManager->new(config => $config, debug => 0);
    my $caps = {
        max_context_window_tokens => 1000000,
        max_output_tokens         => 16384,
        max_prompt_tokens         => 1000000,
    };

    $mgr->_apply_capability_overrides($caps);
    is($caps->{max_prompt_tokens}, 200000,
        'max_prompt capped from 1M to 200k');
};

subtest '_apply_capability_overrides context_window cap also caps max_prompt' => sub {
    # Regression: cap_context_window used to only cap max_context_window_tokens,
    # but MessageValidator's budget reads max_prompt_tokens. The cap was
    # effectively dead for the validator. Verify the cap also caps the
    # prompt field so the user's intent (limit budget to N) is honored.
    my $config = _make_config_with_provider();
    $config->set('cap_context_window', 128000);

    my $mgr = CLIO::Core::APIManager->new(config => $config, debug => 0);
    my $caps = {
        max_context_window_tokens => 1000000,
        max_output_tokens         => 16384,
        max_prompt_tokens         => 1000000,
    };

    $mgr->_apply_capability_overrides($caps);
    is($caps->{max_context_window_tokens}, 128000,
        'context_window capped at 128k');
    is($caps->{max_prompt_tokens}, 128000,
        'max_prompt also capped at 128k (MessageValidator budget honored)');
};

subtest '_apply_capability_overrides context_window cap also populates max_prompt fallback' => sub {
    # When the provider did not report max_prompt_tokens at all, the cap should
    # populate it so MessageValidator has something concrete to budget against
    # instead of falling through to DEFAULT_CONTEXT_WINDOW.
    my $config = _make_config_with_provider();
    $config->set('cap_context_window', 64000);

    my $mgr = CLIO::Core::APIManager->new(config => $config, debug => 0);
    my $caps = {
        max_context_window_tokens => 1000000,
        max_output_tokens         => 16384,
        # max_prompt_tokens is undef (provider didn't report it)
    };

    $mgr->_apply_capability_overrides($caps);
    is($caps->{max_prompt_tokens}, 64000,
        'undef max_prompt populated with cap value as fallback');
};

subtest '_apply_capability_overrides forces tools on' => sub {
    my $config = _make_config_with_provider();
    $config->set('force_tools', 'on');

    my $mgr = CLIO::Core::APIManager->new(config => $config, debug => 0);
    my $caps = {
        max_context_window_tokens => 1000000,
        max_output_tokens         => 16384,
        supports_tools            => 0,  # Model says no tools
        supports_vision           => 0,
        supports_reasoning        => 0,
    };

    $mgr->_apply_capability_overrides($caps);
    is($caps->{supports_tools}, 1,
        'supports_tools forced on');
    is($caps->{supports_vision}, 0,
        'supports_vision unchanged (no override)');
};

subtest '_apply_capability_overrides forces tools off' => sub {
    my $config = _make_config_with_provider();
    $config->set('force_tools', 'off');

    my $mgr = CLIO::Core::APIManager->new(config => $config, debug => 0);
    my $caps = {
        supports_tools => 1,  # Model says tools
    };

    $mgr->_apply_capability_overrides($caps);
    is($caps->{supports_tools}, 0,
        'supports_tools forced off');
};

subtest '_apply_capability_overrides forces vision' => sub {
    my $config = _make_config_with_provider();
    $config->set('force_vision', 'on');

    my $mgr = CLIO::Core::APIManager->new(config => $config, debug => 0);
    $mgr->_apply_capability_overrides({ supports_vision => 0 });
    is($mgr->_caps_with_overrides({ supports_vision => 0 })->{supports_vision}, 1,
        'force_vision on applied via _caps_with_overrides');
};

subtest '_apply_capability_overrides forces reasoning' => sub {
    my $config = _make_config_with_provider();
    $config->set('force_reasoning', 'off');

    my $mgr = CLIO::Core::APIManager->new(config => $config, debug => 0);
    my $caps = { supports_reasoning => 1 };
    $mgr->_apply_capability_overrides($caps);
    is($caps->{supports_reasoning}, 0,
        'supports_reasoning forced off');
};

subtest '_apply_capability_overrides applies multiple overrides at once' => sub {
    my $config = _make_config_with_provider();
    $config->set('cap_context_window', 128000);
    $config->set('cap_max_output', 8192);
    $config->set('force_tools', 'off');
    $config->set('force_vision', 'on');

    my $mgr = CLIO::Core::APIManager->new(config => $config, debug => 0);
    my $caps = {
        max_context_window_tokens => 1000000,
        max_output_tokens         => 16384,
        max_prompt_tokens         => 1000000,
        supports_tools            => 1,
        supports_vision           => 0,
        supports_reasoning        => 1,
    };

    $mgr->_apply_capability_overrides($caps);
    is($caps->{max_context_window_tokens}, 128000,
        'context_window capped');
    is($caps->{max_output_tokens}, 8192,
        'max_output capped');
    is($caps->{supports_tools}, 0,
        'tools forced off');
    is($caps->{supports_vision}, 1,
        'vision forced on');
    is($caps->{supports_reasoning}, 1,
        'reasoning unchanged (no override)');
};

# =============================================================================
# Test: _caps_with_overrides immutability (cache stores raw)
# =============================================================================

subtest '_caps_with_overrides does not mutate input' => sub {
    my $config = _make_config_with_provider();
    $config->set('cap_context_window', 128000);

    my $mgr = CLIO::Core::APIManager->new(config => $config, debug => 0);
    my $raw = { max_context_window_tokens => 1000000 };
    my $result = $mgr->_caps_with_overrides($raw);

    is($raw->{max_context_window_tokens}, 1000000,
        'original input unchanged after _caps_with_overrides');
    is($result->{max_context_window_tokens}, 128000,
        'returned copy has override applied');
    isnt($result, $raw,
        'result is a different hashref (copy, not ref)');
};

# =============================================================================
# Test: Session override precedence over global config
# =============================================================================

subtest 'session override takes precedence over global config' => sub {
    my $config = _make_config_with_provider();
    $config->set('cap_context_window', 256000);  # Global: 256k

    # Fake session with state
    my $state = { api_config => { cap_context_window => 64000 } };  # Session: 64k
    my $session = bless {
        state => sub { return $state },
    }, 'FakeSession';

    my $mgr = CLIO::Core::APIManager->new(config => $config, session => $session, debug => 0);
    my $caps = { max_context_window_tokens => 1000000 };
    $mgr->_apply_capability_overrides($caps);

    is($caps->{max_context_window_tokens}, 64000,
        'session override (64k) takes precedence over global (256k)');
};

# =============================================================================
# Test: Config defaults exist
# =============================================================================

subtest 'Config has all capability override defaults' => sub {
    my $config = CLIO::Core::Config->new(config_dir => '/tmp/clio_cap_def_' . int(rand(1e9)));
    is($config->get('cap_context_window'), 0,
        'cap_context_window default is 0');
    is($config->get('cap_max_output'), 0,
        'cap_max_output default is 0');
    is($config->get('cap_max_prompt'), 0,
        'cap_max_prompt default is 0');
    is($config->get('force_tools'), '',
        'force_tools default is empty');
    is($config->get('force_vision'), '',
        'force_vision default is empty');
    is($config->get('force_reasoning'), '',
        'force_reasoning default is empty');
};

# =============================================================================
# Cleanup
# =============================================================================

END {
    system('rm -rf /tmp/clio_cap_test_* /tmp/clio_cap_mgr_* /tmp/clio_cap_def_*');
}

done_testing();