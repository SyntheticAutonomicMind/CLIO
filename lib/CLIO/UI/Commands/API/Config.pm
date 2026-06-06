# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Commands::API::Config;

use strict;
use warnings;
use utf8;
use parent 'CLIO::UI::Commands::Base';

use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug log_warning);
use CLIO::Util::JSON qw(decode_json);
use CLIO::Providers qw(provider_exists);

=head1 NAME

CLIO::UI::Commands::API::Config - API configuration and settings commands

=head1 DESCRIPTION

Handles /api set, /api show, /api providers, /api alias, and related
configuration operations. Extracted from CLIO::UI::Commands::API.

=cut

sub new {
    my ($class, %args) = @_;
    my $self = $class->SUPER::new(%args);
    $self->{config}    = $args{config};
    $self->{session}   = $args{session};
    $self->{ai_agent}  = $args{ai_agent};
    return $self;
}

# Shared helper: caller passes in Auth module for reinit
sub _get_auth_helper {
    my ($self) = @_;
    require CLIO::UI::Commands::API::Auth;
    return CLIO::UI::Commands::API::Auth->new(
        chat => $self->{chat}, config => $self->{config},
        session => $self->{session}, ai_agent => $self->{ai_agent},
        debug => $self->{debug},
    );
}

sub handle_set {
    my ($self, $setting, $value, $session_only) = @_;

    $setting = lc($setting || '');

    unless ($setting) {
        $self->display_error_message("Usage: /api set <setting> <value>");
        $self->writeline("Settings: model, provider, base, key, serpapi_key, search_engine, search_provider", markdown => 0);
        return;
    }

    unless (defined $value && $value ne '') {
        $self->display_error_message("Usage: /api set $setting <value>");
        return;
    }

    if ($setting eq 'key') {
        $self->_set_key($value, $session_only);
    }
    elsif ($setting eq 'serpapi_key' || $setting eq 'serpapi') {
        $self->_set_serpapi_key($value, $session_only);
    }
    elsif ($setting eq 'search_engine') {
        $self->_set_search_engine($value);
    }
    elsif ($setting eq 'search_provider') {
        $self->_set_search_provider($value);
    }
    elsif ($setting eq 'github_pat') {
        $self->_set_github_pat($value, $session_only);
    }
    elsif ($setting eq 'base') {
        $self->_set_base($value, $session_only);
    }
    elsif ($setting eq 'model') {
        $self->_set_model($value, $session_only);
    }
    elsif ($setting eq 'provider') {
        $self->_set_provider($value, $session_only);
    }
    elsif ($setting eq 'thinking') {
        my $enabled = ($value =~ /^(on|true|1|yes|enabled)$/i) ? 1 : 0;
        $self->{config}->set('show_thinking', $enabled);
        $self->{config}->save();
        my $state_label = $enabled ? "enabled" : "disabled";
        $self->display_system_message("Thinking/reasoning display $state_label" . ($session_only ? " (session only)" : " (saved)"));
    }
    elsif ($setting eq 'thinking_effort') {
        my $level = lc($value // '');
        unless ($level =~ /^(low|medium|high)$/) {
            $self->display_error_message("Invalid thinking_effort value: '$value'");
            $self->writeline("Valid values: low, medium, high", markdown => 0);
            return;
        }
        $self->{config}->set('thinking_effort', $level);
        $self->{config}->save() unless $session_only;
        $self->display_system_message("Thinking effort set to '$level'" . ($session_only ? " (session only)" : " (saved)"));
    }
    elsif ($setting =~ /^(temperature|top_p|top_k)$/) {
        my $key = "sampling_$setting";
        if (!defined $value || $value eq '' || $value =~ /^(reset|default|off)$/i) {
            # Clear override - revert to provider defaults
            $self->{config}->set($key, '');
            $self->{config}->save() unless $session_only;
            $self->display_system_message("$setting reset to provider default" . ($session_only ? " (session only)" : " (saved)"));
        } else {
            unless ($value =~ /^\d+(\.\d+)?$/) {
                $self->display_error_message("Invalid $setting value: '$value' (must be a number)");
                return;
            }
            $self->{config}->set($key, $value + 0);
            $self->{config}->save() unless $session_only;
            $self->display_system_message("$setting set to $value" . ($session_only ? " (session only)" : " (saved)"));
        }
    }
    else {
        $self->display_error_message("Unknown setting: $setting");
        $self->writeline("Valid settings: model, provider, base, key, thinking, thinking_effort, temperature, top_p, top_k, github_pat, serpapi_key, search_engine, search_provider", markdown => 0);
    }
}

sub _set_key {
    my ($self, $value, $session_only) = @_;

    if ($session_only) {
        $self->display_system_message("Note: API key is always global (ignoring --session)");
    }

    my ($valid, $error) = $self->_validate_api_key($value, 1);
    unless ($valid) {
        $self->display_error_message($error);
        return;
    }

    my $current_provider = $self->{config}->get('provider');
    $self->{config}->set_provider_key($current_provider, $value);
    $self->{config}->set('api_key', $value);

    if ($self->{config}->save()) {
        $self->display_system_message("API key set and saved for provider: $current_provider");
    } else {
        $self->display_system_message("API key set (warning: failed to save)");
    }

    $self->_get_auth_helper()->reinit_api_manager();
}

sub _set_serpapi_key {
    my ($self, $value, $session_only) = @_;

    if ($session_only) {
        $self->display_system_message("Note: API keys are always global (ignoring --session)");
    }

    my ($valid, $error) = $self->_validate_api_key($value, 1);
    unless ($valid) {
        $self->display_error_message($error);
        return;
    }

    $self->{config}->set('serpapi_key', $value);

    if ($self->{config}->save()) {
        my $display_key = substr($value, 0, 8) . '...' . substr($value, -4);
        $self->display_system_message("SerpAPI key set: $display_key (saved)");
        $self->display_system_message("Web search will now use SerpAPI for reliable results");
    } else {
        $self->display_system_message("SerpAPI key set (warning: failed to save)");
    }
}

sub _set_search_engine {
    my ($self, $value) = @_;

    require CLIO::Util::InputHelpers;
    my @valid_engines = _get_search_engines();
    my ($valid, $result) = CLIO::Util::InputHelpers::validate_enum($value, \@valid_engines);
    unless ($valid) {
        $self->display_error_message($result);
        return;
    }

    $self->{config}->set('search_engine', lc($result));

    if ($self->{config}->save()) {
        $self->display_system_message("Search engine set to: " . lc($result) . " (saved)");
    } else {
        $self->display_system_message("Search engine set (warning: failed to save)");
    }
}

sub _set_search_provider {
    my ($self, $value) = @_;

    require CLIO::Util::InputHelpers;
    my @valid_providers = _get_search_providers();
    my ($valid, $result) = CLIO::Util::InputHelpers::validate_enum($value, \@valid_providers);
    unless ($valid) {
        $self->display_error_message($result);
        return;
    }

    $self->{config}->set('search_provider', lc($result));

    if ($self->{config}->save()) {
        $self->display_system_message("Search provider set to: " . lc($result) . " (saved)");
    } else {
        $self->display_system_message("Search provider set (warning: failed to save)");
    }
}

sub _set_github_pat {
    my ($self, $value, $session_only) = @_;

    if ($session_only) {
        $self->display_system_message("Note: GitHub PAT is always global (ignoring --session)");
    }

    unless ($value && $value =~ /^(ghp_|ghu_|github_pat_)/) {
        $self->display_error_message("Invalid GitHub PAT format. Must start with 'ghp_', 'ghu_', or 'github_pat_'");
        return;
    }

    $self->{config}->set('github_pat', $value);

    if ($self->{config}->save()) {
        my $display_key = substr($value, 0, 8) . '...' . substr($value, -4);
        $self->display_system_message("GitHub PAT set: $display_key (saved)");
        $self->display_system_message("Extended model access enabled for GitHub Copilot");
    } else {
        $self->display_system_message("GitHub PAT set (warning: failed to save)");
    }

    $self->_get_auth_helper()->reinit_api_manager();
}

sub _set_base {
    my ($self, $value, $session_only) = @_;

    my ($valid, $error) = $self->_validate_url($value);
    unless ($valid) {
        $self->display_error_message($error);
        return;
    }

    # Store per-provider when setting globally
    unless ($session_only) {
        my $current_provider = $self->{config}->get('provider');
        if ($current_provider) {
            $self->{config}->set_provider_base($current_provider, $value);
        }
    }

    $self->_set_api_setting('api_base', $value, $session_only);
    $self->display_system_message("API base set to: $value" . ($session_only ? " (session only)" : " (saved)"));
    $self->_get_auth_helper()->reinit_api_manager();
}

sub _set_model {
    my ($self, $value, $session_only) = @_;

    # Resolve model aliases
    my $resolved = $self->{config}->get_model_alias($value);
    if ($resolved) {
        $self->display_system_message("Alias '$value' -> $resolved");
        $value = $resolved;
    }

    require CLIO::Providers;
    my $current_provider = $self->{config}->get('provider') || '';
    my $full_model = $value;
    my $display_model = $value;

    my $has_provider_prefix = 0;
    if ($value =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i) {
        my ($prefix, $rest) = ($1, $2);
        if (CLIO::Providers::provider_exists($prefix)) {
            $has_provider_prefix = 1;

            my $provider_key = $self->{config}->get_provider_key($prefix);
            my $has_auth = $provider_key
                || $prefix eq 'github_copilot'
                || $prefix eq 'sam'
                || $prefix eq 'llama.cpp'
                || $prefix eq 'lmstudio';

            unless ($has_auth) {
                $self->display_error_message("Provider '$prefix' has no API key configured.");
                $self->display_system_message("Set it with: /api set provider $prefix && /api set key <your-key>");
                return;
            }
        }
    }

    if (!$has_provider_prefix && $current_provider) {
        $full_model = "$current_provider/$value";
        $display_model = $full_model;
    }

    # Extract API model name for validation
    my $api_model = $value;
    my $target_provider = $current_provider;
    if ($full_model =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i) {
        my ($prefix, $rest) = ($1, $2);
        if (CLIO::Providers::provider_exists($prefix)) {
            $target_provider = $prefix;
            $api_model = $rest;
        }
    }

    # Validate model for GitHub Copilot
    if ($target_provider eq 'github_copilot') {
        require CLIO::Core::ModelRegistry;
        my $registry_args = {};
        eval {
            require CLIO::Core::GitHubCopilotModelsAPI;
            my $models_api = CLIO::Core::GitHubCopilotModelsAPI->new(debug => $self->{debug});
            $registry_args->{github_copilot_api} = $models_api;
        };

        my $registry = CLIO::Core::ModelRegistry->new(%$registry_args);
        my ($valid, $error) = $registry->validate_model($api_model);

        unless ($valid) {
            $self->display_error_message($error);
            return;
        }
    }

    $self->_set_api_setting('model', $full_model, $session_only);

    $self->display_system_message("Model set to: $display_model" . ($session_only ? " (session only)" : " (saved)"));
    $self->_get_auth_helper()->reinit_api_manager();

    # Update billing state for /usage
    $self->_update_billing_state($full_model, $target_provider);

    # Post-set validation
    if ($self->{ai_agent} && $self->{ai_agent}->{api}) {
        eval {
            my $caps = $self->{ai_agent}->{api}->get_model_capabilities($full_model);
            if ($caps && defined $caps->{supports_tools} && !$caps->{supports_tools}) {
                $self->display_system_message("Note: Model '$api_model' does not support function calling. CLIO tools will be disabled.");
            }
        };
    }
}

sub _set_provider {
    my ($self, $value, $session_only) = @_;

    require CLIO::Providers;
    my ($valid, $error) = CLIO::Providers::validate_provider($value);
    unless ($valid) {
        $self->display_error_message($error);
        return;
    }

    if ($session_only) {
        if ($self->{session} && $self->{session}->state()) {
            my $state = $self->{session}->state();
            $state->{api_config} ||= {};
            $state->{api_config}{provider} = $value;

            # Load the provider's api_base (per-provider stored or default) and api_key
            # so the session can actually use this provider
            my $stored_base = $self->{config}->get_provider_base($value);
            my $provider_config = CLIO::Providers::get_provider($value);
            if ($provider_config) {
                $state->{api_config}{api_base} = $stored_base || $provider_config->{api_base};
                # Load per-provider API key
                my $provider_key = $self->{config}->get_provider_key($value);
                if ($provider_key) {
                    $state->{api_config}{api_key} = $provider_key;
                }
            }

            $self->{session}->save();
            $self->display_system_message("Provider set to: $value (session only)");
        }
    } else {
        if ($self->{config}->set_provider($value)) {
            my $config = $self->{config}->get_all();
            my $has_stored_base = $self->{config}->get_provider_base($value);
            my $base_source = $has_stored_base ? "stored" : "provider default";

            if ($self->{config}->save()) {
                $self->display_system_message("Switched to provider: $value (saved)");
                $self->display_system_message("  API Base: " . $config->{api_base} . " (from $base_source)");
                $self->display_system_message("  Model: " . $config->{model} . " (from provider)");
            } else {
                $self->display_system_message("Switched to provider: $value (warning: failed to save)");
            }

            # Clear any session-only provider/api_base/api_key overrides
            # so the new global values take effect immediately
            if ($self->{session} && $self->{session}->state()) {
                my $state = $self->{session}->state();
                if ($state->{api_config}) {
                    delete $state->{api_config}{provider};
                    delete $state->{api_config}{api_base};
                    delete $state->{api_config}{api_key};
                    delete $state->{api_config}{model};
                    $self->{session}->save();
                }
            }

            if ($value eq 'github_copilot') {
                $self->_get_auth_helper()->check_github_auth();
            }
        }
    }
    $self->_get_auth_helper()->reinit_api_manager();

    # Update billing state for /usage
    my $new_model = $self->{config}->get('model') || '';
    $self->_update_billing_state($new_model, $value);
}

sub _set_api_setting {
    my ($self, $key, $value, $session_only) = @_;

    if ($session_only) {
        # Session-only: store in session state only (not global config)
        if ($self->{session} && $self->{session}->state()) {
            my $state = $self->{session}->state();
            $state->{api_config} ||= {};
            $state->{api_config}{$key} = $value;
            $self->{session}->save();
        }
    } else {
        # Global: save to config file only - do NOT write to session state.
        # Session state should only contain explicit session-only overrides,
        # not copies of global config (which creates stale values on resume).
        $self->{config}->set($key, $value);
        $self->{config}->save();

        # If this key previously had a session-only override, clear it
        # so the global value takes effect immediately
        if ($self->{session} && $self->{session}->state()) {
            my $state = $self->{session}->state();
            if ($state->{api_config} && exists $state->{api_config}{$key}) {
                delete $state->{api_config}{$key};
                $self->{session}->save();
            }
        }
    }
}

# Update session billing state when provider or model changes mid-session.
# Ensures /usage shows correct model name and quota without restart.
# Also updates max_tokens so State::add_message trims at the correct threshold.
sub _update_billing_state {
    my ($self, $model, $provider) = @_;

    return unless $self->{session};
    my $state = $self->{session}->can('state') ? $self->{session}->state() : undef;
    return unless $state && $state->{billing};

    # Update model name
    $state->{billing}{model} = $model if $model;

    # Reset multiplier (will be re-fetched below for copilot)
    $state->{billing}{multiplier} = 0;

    # Update selected_provider for Billing.pm's _get_active_provider()
    $state->{selected_provider} = $provider if $provider;

    # Update max_tokens from model capabilities so State::add_message
    # trims at the correct threshold for the model's context window
    if ($model) {
        eval {
            my $api_manager = $self->{api_manager};
            if ($api_manager && $api_manager->can('get_model_capabilities')) {
                my $caps = $api_manager->get_model_capabilities($model);
                if ($caps && $caps->{max_context_window_tokens}) {
                    $state->{max_tokens} = $caps->{max_context_window_tokens};
                    log_debug('Config', "Updated session max_tokens to $caps->{max_context_window_tokens} (model context window)");
                }
            }
        };
    }

    # Fetch billing multiplier for GitHub Copilot models
    if ($provider && $provider eq 'github_copilot' && $model) {
        eval {
            require CLIO::Core::GitHubCopilotModelsAPI;
            my $models_api = CLIO::Core::GitHubCopilotModelsAPI->new(debug => $self->{debug});

            # Strip provider prefix for API lookup
            my $api_model = $model;
            if ($api_model =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i && provider_exists($1)) {
                $api_model = $2;
            }

            my $billing = $models_api->get_model_billing($api_model);
            if ($billing && defined $billing->{multiplier}) {
                $state->{billing}{multiplier} = $billing->{multiplier};
                log_debug('Config', "Updated billing: $api_model -> $billing->{multiplier}x");
            }
            if ($billing && $billing->{category}) {
                $state->{billing}{category} = $billing->{category};
            }
            if ($billing && $billing->{vendor}) {
                $state->{billing}{vendor} = $billing->{vendor};
            }
        };
    }

    # Refresh quota for GitHub Copilot
    if ($provider && $provider eq 'github_copilot') {
        eval {
            require CLIO::Core::CopilotUserAPI;
            my $user_api = CLIO::Core::CopilotUserAPI->new(debug => $self->{debug});
            my $user_data = $user_api->get_cached_user();

            if ($user_data) {
                my $premium = $user_data->get_premium_quota();
                if ($premium) {
                    $state->{quota} = {
                        entitlement       => $premium->{entitlement},
                        used              => $premium->{used},
                        available         => $premium->{entitlement} - $premium->{used},
                        percent_remaining => $premium->{percent_remaining},
                        overage_used      => $premium->{overage_count} || 0,
                        overage_permitted => $premium->{overage_permitted},
                        reset_date        => $user_data->{quota_reset_date_utc} || 'unknown',
                        last_updated      => time(),
                    };
                }

                $state->{copilot_user} = {
                    login            => $user_data->{login},
                    copilot_plan     => $user_data->{copilot_plan},
                    access_type_sku  => $user_data->{access_type_sku},
                };
            }
        };
    }
}

sub display_config {
    my ($self) = @_;

    $self->display_command_header("API Configuration");

    my $provider = $self->{config}->get('provider') || 'not set';
    my $model    = $self->{config}->get('model')    || 'not set';
    my $api_base = $self->{config}->get('api_base') || 'not set';
    my $api_key  = $self->{config}->get('api_key')  || '';

    my $display_key = $api_key
        ? substr($api_key, 0, 8) . '...' . substr($api_key, -4)
        : 'not set';

    # Check for session-only overrides
    my %session_overrides;
    if ($self->{session} && $self->{session}->state()) {
        my $state = $self->{session}->state();
        if ($state->{api_config}) {
            for my $key (qw(provider model api_base api_key)) {
                $session_overrides{$key} = 1 if exists $state->{api_config}{$key};
            }
        }
    }

    my $session_tag = sub { $session_overrides{$_[0]} ? $self->colorize(" (session)", 'SYSTEM') : "" };

    $self->display_key_value("Provider", $provider . $session_tag->('provider'), 16);
    $self->display_key_value("Model",    $model . $session_tag->('model'),       16);
    $self->display_key_value("API Base", $api_base . $session_tag->('api_base'), 16);
    $self->display_key_value("API Key",  $display_key . $session_tag->('api_key'), 16);

    # Show thinking settings
    my $thinking = $self->{config}->get('show_thinking') ? 'on' : 'off';
    my $effort    = $self->{config}->get('thinking_effort') // 'medium';
    $self->display_key_value("Thinking", $thinking, 16);
    $self->display_key_value("Think Effort", $effort, 16);

    # Show sampling overrides (only when set)
    for my $param (qw(temperature top_p top_k)) {
        my $val = $self->{config}->get("sampling_$param");
        if (defined $val && $val ne '') {
            $self->display_key_value(ucfirst($param), $val . " (override)", 16);
        }
    }

    if (keys %session_overrides) {
        $self->writeline("", markdown => 0);
        $self->display_system_message("(session) = session-only override, use /api set <key> <value> to save globally");
    }

    $self->writeline("", markdown => 0);
}

sub display_providers {
    my ($self, @args) = @_;

    require CLIO::Providers;

    my $detail_name = $args[0] || '';

    if ($detail_name) {
        $self->_show_provider_details($detail_name);
        return;
    }

    $self->display_command_header("Available Providers");

    my @providers = CLIO::Providers::list_providers();
    my $current = $self->{config}->get('provider') || '';

    for my $name (@providers) {
        my $provider = CLIO::Providers::get_provider($name);
        next unless $provider;

        my $display = $provider->{name} || $name;
        my $marker = ($name eq $current) ? $self->colorize(" (active)", 'PROMPT') : '';

        my $has_key = $self->{config}->get_provider_key($name) ? 1 : 0;
        if ($name eq 'github_copilot') {
            eval {
                require CLIO::Core::GitHubAuth;
                my $auth = CLIO::Core::GitHubAuth->new(debug => 0);
                $has_key = $auth->is_authenticated() ? 1 : 0;
            };
        }

        my $auth_status = $has_key
            ? $self->colorize("\x{2713} ", 'SUCCESS')
            : $self->colorize("  ", 'DIM');

        my $auth_req = $self->_format_auth_requirement($provider);

        # Pad name first (plain text), then colorize, to avoid ANSI codes breaking alignment
        my $padded_name = sprintf("%-18s", $name);
        $self->writeline("  " . $auth_status . $self->colorize($padded_name, 'USER') . " " . $self->colorize($auth_req, 'DIM') . $marker, markdown => 0);
    }

    $self->writeline("", markdown => 0);
    $self->display_system_message("Use: /api providers <name> for setup instructions");
}

sub _show_provider_details {
    my ($self, $name) = @_;

    require CLIO::Providers;
    my $provider = CLIO::Providers::get_provider($name);

    unless ($provider) {
        $self->display_error_message("Unknown provider: $name");
        $self->display_system_message("Use /api providers to see available providers");
        return;
    }

    $self->display_command_header("Provider: " . ($provider->{name} || $name));

    $self->display_section_header("INFO");
    $self->display_key_value("Name",     $provider->{name}     || $name,      16);
    $self->display_key_value("API Base", $provider->{api_base} || 'N/A',      16);
    $self->display_key_value("Default Model", $provider->{default_model} || 'N/A', 16);

    my $auth_req = $self->_format_auth_requirement($provider);
    $self->display_key_value("Auth", $auth_req, 16);

    $self->writeline("", markdown => 0);
    $self->display_section_header("SETUP");
    $self->writeline("  " . $self->colorize("/api set provider $name", 'USER'), markdown => 0);

    if ($provider->{auth} && $provider->{auth}{type} eq 'oauth_device') {
        $self->writeline("  " . $self->colorize("/api login", 'USER'), markdown => 0);
    } elsif ($provider->{auth} && $provider->{auth}{type} eq 'api_key') {
        $self->writeline("  " . $self->colorize("/api set key <your-api-key>", 'USER'), markdown => 0);
        if ($provider->{auth}{url}) {
            $self->writeline("", markdown => 0);
            $self->writeline("  Get your key: " . $self->colorize($provider->{auth}{url}, 'THEME'), markdown => 0);
        }
    }

    if ($provider->{notes}) {
        $self->writeline("", markdown => 0);
        $self->display_section_header("NOTES");
        for my $note (@{$provider->{notes}}) {
            $self->writeline("  - $note", markdown => 0);
        }
    }

    $self->writeline("", markdown => 0);
}

sub _format_auth_requirement {
    my ($self, $provider) = @_;

    my $req = $provider->{requires_auth} || '';
    return 'API Key'        if $req eq 'apikey';
    return 'OAuth (GitHub)' if $req eq 'copilot';
    return 'None'           if $req eq 'none';
    return 'API Key';  # default for unknown
}

sub handle_alias {
    my ($self, @args) = @_;

    my $name = shift @args;

    unless ($name) {
        my %aliases = $self->{config}->list_model_aliases();

        unless (%aliases) {
            $self->display_system_message("No model aliases defined");
            $self->writeline("", markdown => 0);
            $self->display_system_message("Create one: /api alias <name> <model>");
            $self->display_system_message("Example:    /api alias fast gpt-5-mini");
            return;
        }

        $self->display_command_header("MODEL ALIASES");

        my $max_name_len = 0;
        for my $n (keys %aliases) {
            $max_name_len = length($n) if length($n) > $max_name_len;
        }
        $max_name_len = 12 if $max_name_len < 12;

        for my $n (sort keys %aliases) {
            $self->display_command_row($n, $aliases{$n}, $max_name_len + 4);
        }
        $self->writeline("", markdown => 0);
        return;
    }

    unless ($name =~ /^[a-zA-Z][a-zA-Z0-9_-]*$/) {
        $self->display_error_message("Invalid alias name: '$name'");
        $self->display_system_message("Alias names must start with a letter and contain only letters, numbers, hyphens, underscores");
        return;
    }

    my $value = shift @args;

    if ($value && $value eq '--delete') {
        if ($self->{config}->delete_model_alias($name)) {
            $self->{config}->save();
            $self->display_system_message("Alias '$name' removed");
        } else {
            $self->display_error_message("Alias '$name' not found");
        }
        return;
    }

    unless (defined $value && $value ne '') {
        my $existing = $self->{config}->get_model_alias($name);
        if ($existing) {
            $self->display_system_message("$name -> $existing");
        } else {
            $self->display_error_message("Alias '$name' not found");
            $self->display_system_message("Create it: /api alias $name <model>");
        }
        return;
    }

    $self->{config}->set_model_alias($name, $value);
    $self->{config}->save();
    $self->display_system_message("Alias set: $name -> $value");

=head2 handle_remove(@args)

Handle /api remove <provider> - Remove a provider's stored credentials and custom base.

Removes stored API key, custom base URL, and if the provider is the current one,
resets to the default provider.

=cut

sub handle_remove {
    my ($self, @args) = @_;

    my $provider = shift @args // '';

    unless ($provider && $provider !~ /^\s*$/) {
        $self->display_error_message("Usage: /api remove <provider>");
        $self->display_system_message("Removes stored credentials and custom base for a provider");

        # Show which providers have stored data
        my @stored = $self->{config}->list_provider_keys();
        if (@stored) {
            $self->writeline("", markdown => 0);
            $self->display_system_message("Providers with stored keys: " . join(', ', @stored));
        }
        return;
    }

    # Validate provider exists in registry
    require CLIO::Providers;
    unless (CLIO::Providers::provider_exists($provider)) {
        $self->display_error_message("Unknown provider: $provider");
        my @providers = CLIO::Providers::list_providers();
        $self->display_system_message("Available: " . join(', ', @providers));
        return;
    }

    my $removed = 0;

    # Remove stored API key
    {
        my $api_keys = $self->{config}{config}{api_keys} // {};
        if (exists $api_keys->{$provider}) {
            delete $api_keys->{$provider};
            $removed++;
            $self->display_system_message("Removed API key for '$provider'");
        }
    }

    # Remove stored API base
    {
        my $api_bases = $self->{config}{config}{api_bases} // {};
        if (exists $api_bases->{$provider}) {
            delete $api_bases->{$provider};
            $removed++;
            $self->display_system_message("Removed custom API base for '$provider'");
        }
    }

    unless ($removed) {
        $self->display_system_message("No stored credentials or custom base found for '$provider'");
        return;
    }

    # If the removed provider is the current one, switch to default
    my $current = $self->{config}->get('provider');
    if ($current && $current eq $provider) {
        require CLIO::Providers;
        my $default = 'github_copilot';
        # Don't switch to the provider being removed
        $default = 'openai' if $default eq $provider;
        $self->{config}->set_provider($default);
        $self->{config}->save();
        $self->display_system_message("Switched to default provider '$default' (was current)");
    } else {
        $self->{config}->save();
    }
}

}

# Validation helpers

sub _detect_api_type {
    my ($self, $api_base) = @_;

    my %api_configs = (
        'github-copilot' => ['github-copilot', 'https://api.githubcopilot.com/models'],
        'openai'         => ['openai', 'https://api.openai.com/v1/models'],
        'dashscope-cn'   => ['dashscope', 'https://dashscope.aliyuncs.com/compatible-mode/v1/models'],
        'dashscope-intl' => ['dashscope', 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models'],
        'sam'            => ['sam', 'http://localhost:8080/v1/models'],
    );

    if (exists $api_configs{$api_base}) {
        return @{$api_configs{$api_base}};
    }

    if ($api_base =~ m{githubcopilot\.com}i) {
        return ('github-copilot', 'https://api.githubcopilot.com/models');
    } elsif ($api_base =~ m{openai\.com}i) {
        return ('openai', 'https://api.openai.com/v1/models');
    } elsif ($api_base =~ m{dashscope.*\.aliyuncs\.com}i) {
        my $base_url = $api_base;
        $base_url =~ s{/+$}{};
        $base_url =~ s{/compatible-mode/v1.*$}{};
        return ('dashscope', "$base_url/compatible-mode/v1/models");
    } elsif ($api_base =~ m{localhost:8080}i) {
        return ('sam', 'http://localhost:8080/v1/models');
    }

    if ($api_base =~ m{^https?://}) {
        my $models_url = $api_base;
        $models_url =~ s{/+$}{};

        if ($models_url =~ m{/chat/completions$}) {
            $models_url =~ s{/chat/completions$}{/models};
        }
        elsif ($models_url =~ m{/v1$}) {
            $models_url .= "/models";
        } elsif ($models_url !~ m{/models$}) {
            $models_url .= "/models";
        }

        return ('generic', $models_url);
    }

    return (undef, undef);
}

sub _validate_url {
    my $self = shift;
    my ($url) = @_;

    unless (defined $url && length($url)) {
        return (0, "URL cannot be empty");
    }

    if ($url =~ m{^https?://[^\s]+$}) {
        return (1, '');
    }

    if ($url =~ m{^[a-z][a-z0-9+\-.]*://[^\s]+$}i) {
        if ($url =~ m{^ws://}i) {
            log_debug('API', "Warning: Using insecure WebSocket (ws://). Consider using wss:// instead.");
        }
        return (1, '');
    }

    return (0, "Invalid URL format: '$url'. Must be a valid URL (e.g., http://example.com)");
}

sub _validate_api_key {
    my $self = shift;
    my ($key, $min_length) = @_;
    $min_length ||= 1;

    unless (defined $key && length($key)) {
        return (0, "API key cannot be empty");
    }

    if (length($key) < $min_length) {
        return (0, "API key too short (minimum $min_length characters)");
    }

    if ($key =~ /^\s+$/) {
        return (0, "API key cannot be only whitespace");
    }

    return (1, '');
}

sub _get_search_engines {
    return qw(google bing duckduckgo);
}

sub _get_search_providers {
    return qw(auto serpapi duckduckgo_direct);
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut

1;
