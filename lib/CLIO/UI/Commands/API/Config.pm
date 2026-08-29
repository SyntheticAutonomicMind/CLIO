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
        my $thinking_key = 'show_thinking';
        if ($session_only) {
            $self->_write_session_override($thinking_key, $enabled);
        } else {
            $self->{config}->set($thinking_key, $enabled);
            $self->{config}->save();
        }
        my $state_label = $enabled ? "enabled" : "disabled";
        $self->display_system_message("Thinking/reasoning display $state_label" . ($session_only ? " (session only)" : " (saved)"));
    }
    elsif ($setting eq 'thinking_effort') {
        my $level = lc($value // '');
        # Validate against the current provider's allowed values.
        # Each provider's reasoning_schema (from provider-defaults.json)
        # lists its accepted values; we validate before setting so the
        # user gets immediate feedback rather than a deferred API error.
        my $schema = $self->_get_current_provider_schema();
        my $valid;
        if ($schema && $schema->{values} && ref($schema->{values}) eq 'ARRAY') {
            $valid = { map { $_ => 1 } @{$schema->{values}} };
        }
        # Fall back to the broad set if no schema is available
        $valid = { map { $_ => 1 } qw(low medium high xhigh max) } unless $valid;

        unless ($valid->{$level}) {
            $self->display_error_message("Invalid thinking_effort value: '$value'");
            if ($schema && $schema->{values} && ref($schema->{values}) eq 'ARRAY') {
                my $vals = join(', ', @{$schema->{values}});
                $self->writeline("Valid values for this provider: $vals", markdown => 0);
            } else {
                $self->writeline("Valid values: low, medium, high, xhigh, max (xhigh and max require Anthropic 4.6+ adaptive)", markdown => 0);
            }
            return;
        }
        if ($session_only) {
            $self->_write_session_override('thinking_effort', $level);
        } else {
            $self->{config}->set('thinking_effort', $level);
            $self->{config}->save();
        }
        $self->display_system_message("Thinking effort set to '$level'" . ($session_only ? " (session only)" : " (saved)"));
    }
    elsif ($setting eq 'thinking_mode') {
        my $mode = lc($value // '');
        # thinking_mode controls how the harness decides whether to send
        # thinking params. auto is the default and the recommended choice
        # for Anthropic (sends adaptive thinking without requiring
        # show_thinking). enabled forces thinking ON regardless of
        # show_thinking. disabled forces thinking OFF - may be overridden
        # to adaptive for models that require it (Fable 5, Mythos 5,
        # Mythos Preview) with a warning.
        unless ($mode =~ /^(auto|enabled|disabled)$/) {
            $self->display_error_message("Invalid thinking_mode value: '$value'");
            $self->writeline("Valid values: auto, enabled, disabled", markdown => 0);
            $self->writeline("  auto:    Recommended. Sends adaptive thinking for Anthropic models,", markdown => 0);
            $self->writeline("           other providers gate on show_thinking as before.", markdown => 0);
            $self->writeline("  enabled: Force thinking ON regardless of show_thinking.", markdown => 0);
            $self->writeline("  disabled: Force thinking OFF. May 400 on Fable 5/Mythos 5/", markdown => 0);
            $self->writeline("            Mythos Preview (overridden to adaptive with warning).", markdown => 0);
            return;
        }

        # Warn when enabling thinking on a provider that doesn't support it
        if ($mode eq 'enabled') {
            my $schema = $self->_get_current_provider_schema();
            if ($schema && $schema->{mode} eq 'disabled') {
                $self->display_warning_message(
                    "Provider does not support reasoning params. "
                    . "thinking_mode=enabled has no effect on local inference servers "
                    . "(llama.cpp, LM Studio, Ollama, SAM). Set show_thinking=1 instead "
                    . "to display the model's built-in thinking output."
                );
            }
        }

        if ($session_only) {
            $self->_write_session_override('thinking_mode', $mode);
        } else {
            $self->{config}->set('thinking_mode', $mode);
            $self->{config}->save();
        }
        $self->display_system_message("Thinking mode set to '$mode'" . ($session_only ? " (session only)" : " (saved)"));
    }
    elsif ($setting =~ /^(temperature|top_p|top_k)$/) {
        my $key = "sampling_$setting";
        if (!defined $value || $value eq '' || $value =~ /^(reset|default|off)$/i) {
            # Clear override - revert to provider defaults
            if ($session_only) {
                $self->_write_session_override($key, 0);
            } else {
                $self->{config}->set($key, '');
                $self->{config}->save();
            }
            $self->display_system_message("$setting reset to provider default" . ($session_only ? " (session only)" : " (saved)"));
        } else {
            unless ($value =~ /^\d+(\.\d+)?$/) {
                $self->display_error_message("Invalid $setting value: '$value' (must be a number)");
                return;
            }
            if ($session_only) {
                $self->_write_session_override($key, $value + 0);
            } else {
                $self->{config}->set($key, $value + 0);
                $self->{config}->save();
            }
            $self->display_system_message("$setting set to $value" . ($session_only ? " (session only)" : " (saved)"));
        }
    }
    elsif ($setting eq 'context_window' || $setting eq 'max_output' || $setting eq 'max_prompt') {
        $self->_set_capability_cap($setting, $value, $session_only);
    }
    elsif ($setting eq 'tools' || $setting eq 'vision' || $setting eq 'reasoning') {
        $self->_set_capability_force($setting, $value, $session_only);
    }
    else {
        $self->display_error_message("Unknown setting: $setting");
        $self->writeline("Valid settings: model, provider, base, key, thinking, thinking_effort, thinking_mode, temperature, top_p, top_k, github_pat, serpapi_key, search_engine, search_provider, context_window, max_output, max_prompt, tools, vision, reasoning", markdown => 0);
    }
}

=head2 handle_route

Handle /api route commands for named model routing profiles.

Commands:
  /api route add <name> <model1> [model2 model3 ...]
  /api route list
  /api route use <name>
  /api route remove <name>

=cut

sub handle_route {
    my ($self, @args) = @_;

    my $action = shift @args || '';
    $action = lc($action // '');

    unless ($action) {
        $self->display_error_message("Usage: /api route <add|list|use|remove> [name] [models...]");
        return;
    }

    if ($action eq 'add') {
        $self->_route_add(@args);
    }
    elsif ($action eq 'list') {
        $self->_route_list();
    }
    elsif ($action eq 'use') {
        $self->_route_use(@args);
    }
    elsif ($action eq 'remove' || $action eq 'rm') {
        $self->_route_remove(@args);
    }
    else {
        $self->display_error_message("Unknown route action: $action");
        $self->writeline("Valid actions: add, list, use, remove", markdown => 0);
    }
}

=head2 _route_add($name, @models)

Save a named model routing profile.

  /api route add <name> <model1> [model2 model3 ...]

Example:
  /api route add laguna-free openrouter/poolside/laguna-s-2.1:free kilo/poolside/laguna-s-2.1:free vercel/poolside/laguna-s-2.1-free

=cut

sub _route_add {
    my ($self, $name, @models) = @_;

    unless ($name && length($name)) {
        $self->display_error_message("Usage: /api route add <name> <model1> [model2 ...]");
        return;
    }

    @models = grep { defined && length } @models;
    unless (@models >= 1) {
        $self->display_error_message("Must specify at least one model");
        $self->writeline("Example: /api route add laguna-free openrouter/foo:free kilo/bar:free", markdown => 0);
        return;
    }

    # Validate each model has a valid provider prefix
    for my $m (@models) {
        my ($provider, $api_model) = $self->_resolve_model_details($m);
        if ($provider eq ($self->{config}->get('provider') || '')) {
            # Same provider - fine
        } else {
            my ($has_auth, $auth_error) = $self->_check_provider_auth($provider);
            unless ($has_auth) {
                $self->display_error_message($auth_error);
                $self->display_system_message("Set it with: /api set provider $provider && /api set key <your-key>");
                return;
            }
        }
    }

    $self->{config}->set_model_route($name, \@models);
    if ($self->{config}->save()) {
        $self->display_system_message("Route '$name' saved with " . scalar(@models) . " models");
    } else {
        $self->display_system_message("Route '$name' saved (warning: failed to save)");
    }
    $self->_get_auth_helper()->reinit_api_manager();
}

=head2 _route_list

List all saved routing profiles.

=cut

sub _route_list {
    my ($self) = @_;
    my %routes = $self->{config}->list_model_routes();

    unless (%routes) {
        $self->display_system_message("No routing profiles saved. Create one with:");
        $self->writeline("  /api route add <name> <model1> [model2 model3 ...]", markdown => 0);
        return;
    }

    $self->display_command_header("ROUTING PROFILES");
    for my $name (sort keys %routes) {
        my $models = $routes{$name};
        my $display = join(", ", @$models);
        $self->display_key_value($name, $display);
    }
}

=head2 _route_use($name)

Activate a named routing profile.

  /api route use <name>

=cut

sub _route_use {
    my ($self, $name) = @_;

    unless ($name && length($name)) {
        $self->display_error_message("Usage: /api route use <name>");
        return;
    }

    my $routes = { $self->{config}->list_model_routes() };
    unless (exists $routes->{lc($name)}) {
        $self->display_error_message("Route '$name' not found. Create one with /api route add");
        # Try to list available routes
        if (%$routes) {
            $self->writeline("Available routes: " . join(", ", sort keys %$routes), markdown => 0);
        }
        return;
    }

    my $models = $self->{config}->get_model_route($name);
    $self->{config}->set_model_candidates($models);
    $self->{config}->set_model_routing_index(0);

    # Set the first model as active
    my ($full_model, $display_model, $target_provider, $api_model) =
        $self->_resolve_model_details($models->[0]);

    $self->_set_api_setting('model', $full_model, 0);
    $self->{config}->save();

    $self->display_system_message("Route '$name' activated (" . scalar(@$models) . " models)");
    $self->display_system_message("Active model: $display_model");
    $self->display_system_message("On API errors, CLIO will automatically try the next model");

    $self->_get_auth_helper()->reinit_api_manager();
    $self->_update_billing_state($full_model, $target_provider);
    $self->_post_set_model_validation($full_model, $api_model);
}

=head2 _route_remove($name)

Remove a named routing profile.

  /api route remove <name>

=cut

sub _route_remove {
    my ($self, $name) = @_;

    unless ($name && length($name)) {
        $self->display_error_message("Usage: /api route remove <name>");
        return;
    }

    my $deleted = $self->{config}->delete_model_route($name);
    unless ($deleted) {
        $self->display_error_message("Route '$name' not found");
        return;
    }

    $self->{config}->save();
    $self->display_system_message("Route '$name' removed");
    $self->_get_auth_helper()->reinit_api_manager();
}

=head2 _get_current_provider_schema

Build the endpoint config for the current provider and return its
reasoning_schema (propagated from provider-defaults.json via
build_endpoint_config). Returns undef if the provider has no schema.

=cut

sub _get_current_provider_schema {
    my ($self) = @_;
    my $provider = $self->{config}->get('provider') || 'openai';
    my $api_key = $self->{config}->get('api_key') || '';
    require CLIO::Providers;
    my $endpoint_config = CLIO::Providers::build_endpoint_config($provider, $api_key);
    return $endpoint_config->{reasoning_schema};
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

    # Normalize the URL for local inference providers (llama.cpp, lmstudio,
    # sam). These providers expose an OpenAI-compatible /v1/chat/completions
    # endpoint and are configured with path_suffix => '' in Providers.pm,
    # meaning CLIO does not append any suffix - the user must provide the
    # full URL. A bare host like http://nimo:9090 silently produces a 404
    # ("File Not Found") from the server because the request hits the
    # server root instead of the chat endpoint. Normalize so the user
    # doesn't have to memorize the convention.
    my $current_provider = $self->{config}->get('provider') || '';
    my ($normalized, $normalize_msg) = $self->_normalize_local_inference_url($value, $current_provider);
    if ($normalize_msg) {
        $value = $normalized;
        $self->display_system_message($normalize_msg);
    }

    # Store per-provider when setting globally
    unless ($session_only) {
        if ($current_provider) {
            $self->{config}->set_provider_base($current_provider, $value);
        }
    }

    $self->_set_api_setting('api_base', $value, $session_only);
    $self->display_system_message("API base set to: $value" . ($session_only ? " (session only)" : " (saved)"));
    $self->_get_auth_helper()->reinit_api_manager();
}

=head2 _normalize_local_inference_url($url, $provider)

Auto-append the OpenAI-compatible chat completions path for local inference
providers (llama.cpp, lmstudio, sam). These servers expose the chat
endpoint at /v1/chat/completions and are configured with path_suffix => ''
in CLIO::Providers, so the user must provide the full URL. Normalize the
common mistake of providing a bare host (http://nimo:9090) by appending
the path automatically, with a one-line note about what changed.

Arguments:
- $url: User-supplied URL
- $provider: Current provider name

Returns: ($url, $note)
- $url: Possibly-normalized URL (unchanged if no normalization was needed)
- $note: Undef if no change. Otherwise a short system message describing
  the normalization so the user can verify the URL was rewritten correctly.

=cut

sub _normalize_local_inference_url {
    my ($self, $url, $provider) = @_;

    require CLIO::Providers;
    return ($url, undef) unless CLIO::Providers::is_local_inference($provider);

    # Already a chat completions URL - leave alone.
    return ($url, undef) if $url =~ m{/chat/completions/?$};

    # Bare /v1 or /v1/ - append chat/completions.
    if ($url =~ m{/v1/?$}) {
        (my $rewritten = $url) =~ s{/v1/?$}{/chat/completions};
        return ($rewritten, "Normalized: appended /chat/completions to existing /v1");
    }

    # Anything else (bare host or non-/v1 path) - append /v1/chat/completions.
    (my $clean = $url) =~ s{/+$}{};
    my $rewritten = "${clean}/v1/chat/completions";
    return ($rewritten,
        "Normalized: appended /v1/chat/completions. Local inference servers (llama.cpp, "
        . "LM Studio, SAM) expect the full chat completions path. Pass a bare host "
        . "like http://localhost:8080 and we'll fill in the rest; pass a custom "
        . "path and it will be left alone.");
}

=head2 _set_model_candidates($models, $session_only)

Handle /api set model with multiple space-separated models for routing.
Stores the list as model_candidates and sets the first as the active model.

Arguments:
  $models       - Arrayref of model strings (e.g. ["openrouter/foo", "kilo/bar"])
  $session_only - If true, store as session-only override

=cut

sub _set_model_candidates {
    my ($self, $models, $session_only) = @_;

    my @candidates;
    for my $m (@$models) {
        next unless $m && length($m);
        my $resolved = $self->{config}->get_model_alias($m);
        push @candidates, $resolved || $m;
    }

    unless (@candidates) {
        $self->display_error_message("No valid models provided");
        return;
    }

    # Validate each model has a valid provider
    my @validated;
    for my $m (@candidates) {
        my ($full_model, $display_model, $target_provider, $api_model) =
            $self->_resolve_model_details($m);

        if ($target_provider ne ($self->{config}->get('provider') || '')) {
            my ($has_auth, $auth_error) = $self->_check_provider_auth($target_provider);
            unless ($has_auth) {
                $self->display_error_message($auth_error);
                $self->display_system_message("Set it with: /api set provider $target_provider && /api set key <your-key>");
                return;
            }
        }

        if ($target_provider eq 'github_copilot') {
            my ($valid, $error) = $self->_validate_github_copilot_model($api_model);
            unless ($valid) {
                $self->display_error_message($error);
                return;
            }
        }

        push @validated, $full_model;
    }

    # Store candidates and set first as active
    if ($session_only) {
        if ($self->{session} && $self->{session}->can('state')) {
            my $state = $self->{session}->state();
            $state->{api_config} ||= {};
            $state->{api_config}{model_candidates} = \@validated;
            $state->{api_config}{model_routing_index} = 0;
            $self->{session}->save();
        }
    } else {
        $self->{config}->set_model_candidates(\@validated);
        $self->{config}->set_model_routing_index(0);
        $self->{config}->save();
    }

    $self->display_system_message("Model routing enabled with " . scalar(@validated) . " models:");
    for my $i (0 .. $#validated) {
        my $marker = ($i == 0) ? ' (active)' : '';
        $self->display_system_message("  [$i] $validated[$i]$marker");
    }
    $self->display_system_message("Active model: $validated[0]" . ($session_only ? " (session only)" : " (saved)"));
    $self->display_system_message("On API errors, CLIO will automatically try the next model in the list");

    $self->_set_api_setting('model', $validated[0], $session_only);
    $self->_get_auth_helper()->reinit_api_manager();

    my ($first_provider, $first_model) = $self->_resolve_model_details($validated[0]);
    $self->_update_billing_state($validated[0], $first_provider);
    $self->_post_set_model_validation($validated[0], $first_model);
}

sub _set_model {
    my ($self, $value, $session_only) = @_;

    # Handle multiple space-separated models for routing:
    #   /api set model "openrouter/foo kilo/bar vercel/baz"
    my @model_list = split(/\s+/, $value);
    if (@model_list > 1) {
        $self->_set_model_candidates(\@model_list, $session_only);
        return;
    }

    # Resolve model aliases
    my $resolved = $self->{config}->get_model_alias($value);
    if ($resolved) {
        $self->display_system_message("Alias '$value' -> $resolved");
        $value = $resolved;
    }

    my ($full_model, $display_model, $target_provider, $api_model) = 
        $self->_resolve_model_details($value);

    # Validate that the target provider has credentials configured.
    # Skipped when the target provider is already the current one (no switch implied).
    if ($target_provider ne ($self->{config}->get('provider') || '')) {
        my ($has_auth, $auth_error) = $self->_check_provider_auth($target_provider);
        unless ($has_auth) {
            $self->display_error_message($auth_error);
            $self->display_system_message("Set it with: /api set provider $target_provider && /api set key <your-key>");
            return;
        }
    }

    # Validate model for GitHub Copilot
    if ($target_provider eq 'github_copilot') {
        my ($valid, $error) = $self->_validate_github_copilot_model($api_model);
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
    $self->_post_set_model_validation($full_model, $api_model);
}

=head2 _resolve_model_details

Resolve model details including provider prefix, full model name, and target provider.

Returns: ($full_model, $display_model, $target_provider, $api_model)

=cut

sub _resolve_model_details {
    my ($self, $value) = @_;

    require CLIO::Providers;
    my $current_provider = $self->{config}->get('provider') || '';
    my $full_model = $value;
    my $display_model = $value;
    my $has_provider_prefix = 0;
    my $target_provider = $current_provider;
    my $api_model = $value;

    if ($value =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i) {
        my ($prefix, $rest) = ($1, $2);
        if (CLIO::Providers::provider_exists($prefix)) {
            $has_provider_prefix = 1;
            $target_provider = $prefix;
            $api_model = $rest;
            $full_model = $value;
            $display_model = $value;
        }
    }

    if (!$has_provider_prefix && $current_provider) {
        $full_model = "$current_provider/$value";
        $display_model = $full_model;
    }

    return ($full_model, $display_model, $target_provider, $api_model);
}

=head2 _check_provider_auth

Check whether the given provider has credentials configured.
Returns ($has_auth, $error_message). $has_auth is 1 when credentials
are present OR when the provider does not require explicit credentials
(e.g. github_copilot with device flow, sam, llama.cpp, lmstudio).

=cut

sub _check_provider_auth {
    my ($self, $provider) = @_;

    # Providers that don't need an API key in CLIO config
    my %NO_KEY_NEEDED = map { $_ => 1 } qw(
        github_copilot
        sam
        llama.cpp
        lmstudio
    );

    return (1, '') if $NO_KEY_NEEDED{$provider};

    my $provider_key = $self->{config}->get_provider_key($provider);
    if ($provider_key) {
        return (1, '');
    }

    return (0, "Provider '$provider' has no API key configured.");
}

=head2 _validate_github_copilot_model

Validate a model for GitHub Copilot provider.

Returns: ($valid, $error_message)

=cut

sub _validate_github_copilot_model {
    my ($self, $api_model) = @_;

    require CLIO::Core::ModelRegistry;
    my $registry_args = {};
    eval {
        require CLIO::Core::GitHubCopilotModelsAPI;
        my $models_api = CLIO::Core::GitHubCopilotModelsAPI->new(debug => $self->{debug});
        $registry_args->{github_copilot_api} = $models_api;
    };

    my $registry = CLIO::Core::ModelRegistry->new(%$registry_args);
    return $registry->validate_model($api_model);
}

=head2 _post_set_model_validation

Post-set validation for model capabilities.

=cut

sub _post_set_model_validation {
    my ($self, $full_model, $api_model) = @_;

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

=head2 _parse_token_count($value)

Parse a token count value with optional k/M suffix into a raw integer.
Supports formats like "128000", "128k", "1M", "256K".
May be called as instance method or class method.

Returns: integer token count, or undef if invalid.

=cut

sub _parse_token_count {
    my $value;
    if (@_ == 2) {
        # Called as instance/class method: ($self, $value)
        $value = $_[1];
    } else {
        # Called as function: ($value)
        $value = $_[0];
    }
    return undef unless defined $value && $value ne '';

    # Strip whitespace
    $value =~ s/^\s+|\s+$//g;

    # Pure integer
    if ($value =~ /^(\d+)$/) {
        return $1 + 0;
    }

    # Integer with k/K or m/M suffix (with optional decimals)
    if ($value =~ /^(\d+(?:\.\d+)?)\s*([kKmM])$/) {
        my ($num, $suffix) = ($1, lc($2));
        my $multiplier = ($suffix eq 'k') ? 1000 : 1000000;
        return int($num * $multiplier);
    }

    return undef;
}

=head2 _format_token_count($count)

Format a token count for display (e.g. 128000 -> "128k", 1000000 -> "1.0M").
May be called as instance method or class method.

Returns: formatted string.

=cut

sub _format_token_count {
    my $count;
    if (@_ == 2) {
        # Called as instance/class method: ($self, $count)
        $count = $_[1];
    } else {
        # Called as function: ($count)
        $count = $_[0];
    }
    return '0' unless defined $count && $count > 0;
    if ($count >= 1000000) {
        my $m = $count / 1000000;
        return $m == int($m) ? int($m) . 'M' : sprintf('%.1fM', $m);
    }
    elsif ($count >= 1000) {
        my $k = $count / 1000;
        return $k == int($k) ? int($k) . 'k' : sprintf('%.1fk', $k);
    }
    return $count . '';
}

=head2 _humanize_cap_name($cap)

Convert capability cap setting names to user-friendly labels.
Examples: context_window -> Context window, max_output -> Max output,
max_prompt -> Max prompt.

=cut

sub _humanize_cap_name {
    my ($cap) = @_;
    return 'Context window' if $cap eq 'context_window';
    return 'Max output' if $cap eq 'max_output';
    return 'Max prompt' if $cap eq 'max_prompt';
    return $cap;
}

=head2 _set_capability_cap($setting, $value, $session_only)

Handle /api set context_window|max_output|max_prompt <value>.

Caps the model's reported value. Use this to save tokens by limiting
the effective context/output/prompt budget below the model's maximum.

Accepts token counts in raw form (128000) or with k/M suffix (128k, 1M).
Pass 'reset', 'default', or '0' to clear the cap and use the model's value.

=cut

sub _set_capability_cap {
    my ($self, $setting, $value, $session_only) = @_;

    my $config_key = "cap_$setting";

    if (!defined $value || $value eq '' || $value =~ /^(reset|default|off|0)$/i) {
        if ($session_only) {
            $self->_write_session_override($config_key, 0);
        } else {
            $self->{config}->set($config_key, 0);
            $self->{config}->save();
        }
        $self->display_system_message("$setting cap cleared (using model default)" . ($session_only ? " (session only)" : " (saved)"));
        return;
    }

    my $tokens = _parse_token_count($value);
    unless ($tokens && $tokens > 0) {
        $self->display_error_message("Invalid $setting value: '$value'");
        $self->writeline("Use raw tokens (128000) or suffixed form (128k, 1M), or 'reset' to clear", markdown => 0);
        return;
    }

    unless ($tokens >= 1000) {
        $self->display_error_message("$setting cap too small: $tokens (minimum 1000 tokens)");
        return;
    }

    if ($session_only) {
        $self->_write_session_override($config_key, $tokens);
    } else {
        $self->{config}->set($config_key, $tokens);
        $self->{config}->save();
    }
    $self->display_system_message(
        sprintf("%s capped at %s%s",
            $setting,
            _format_token_count($tokens),
            ($session_only ? " (session only)" : " (saved)")
        )
    );
}

=head2 _write_session_override($config_key, $value)

Store a session-only override for a setting (mirrors _set_api_setting
semantics). The session value takes effect immediately; the global
config is left untouched so disk state stays clean. Used by capability
cap and force handlers that share the api_config session namespace.

Arguments:
    $config_key - The config key (e.g. 'cap_context_window', 'force_tools')
    $value      - The override value (0 or '' to clear the override)

=cut

sub _write_session_override {
    my ($self, $config_key, $value) = @_;

    return unless $self->{session} && $self->{session}->can('state');
    my $state = $self->{session}->state();
    $state->{api_config} ||= {};

    # Treat 0 and '' as "clear the session override"
    my $clearing = (!defined $value) || $value eq '' || $value == 0;
    if ($clearing) {
        delete $state->{api_config}{$config_key};
    } else {
        $state->{api_config}{$config_key} = $value;
    }

    $self->{session}->save() if $self->{session}->can('save');
}

=head2 _set_capability_force($setting, $value, $session_only)

Handle /api set tools|vision|reasoning <on|off|auto>.

Force a capability on or off regardless of what the model reports.
Use 'auto' (or 'reset') to clear the override and use the model's value.

=cut

sub _set_capability_force {
    my ($self, $setting, $value, $session_only) = @_;

    my $config_key = "force_$setting";
    my $normalized = lc($value // '');

    # Clear triggers - these explicitly ask to revert to model default
    if ($normalized =~ /^(auto|reset|default|'')$/) {
        if ($session_only) {
            $self->_write_session_override($config_key, 0);
        } else {
            $self->{config}->set($config_key, '');
            $self->{config}->save();
        }
        $self->display_system_message("$setting override cleared (using model default)" . ($session_only ? " (session only)" : " (saved)"));
        return;
    }

    # Boolean force values
    unless ($normalized =~ /^(on|off|true|false|enabled|disabled)$/) {
        $self->display_error_message("Invalid $setting value: '$value'");
        $self->writeline("Valid values: on, off, auto (use model default)", markdown => 0);
        return;
    }

    my $forced = ($normalized =~ /^(on|true|enabled)$/) ? 'on' : 'off';
    if ($session_only) {
        $self->_write_session_override($config_key, $forced);
    } else {
        $self->{config}->set($config_key, $forced);
        $self->{config}->save();
    }
    $self->display_system_message("$setting forced: $forced" . ($session_only ? " (session only)" : " (saved)"));
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
    # trims at the correct threshold for the model's context window.
    # Also update max_output_tokens so the new prompt-budget formula
    # (compute_prompt_budget) can reserve the actual output cap
    # rather than the 25% SAFE_CONTEXT_PERCENT heuristic.
    if ($model) {
        eval {
            my $api_manager = $self->{api_manager};
            if ($api_manager && $api_manager->can('get_model_capabilities')) {
                my $caps = $api_manager->get_model_capabilities($model);
                if ($caps && $caps->{max_context_window_tokens}) {
                    $state->{max_tokens} = $caps->{max_context_window_tokens};
                    log_debug('Config', "Updated session max_tokens to $caps->{max_context_window_tokens} (model context window)");
                }
                if ($caps && $caps->{max_output_tokens}) {
                    $state->{max_output_tokens} = $caps->{max_output_tokens};
                    log_debug('Config', "Updated session max_output_tokens to $caps->{max_output_tokens} (model output cap)");
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
    my $mode      = $self->{config}->get('thinking_mode') // 'auto';
   $self->display_key_value("Thinking", $thinking, 16);
   $self->display_key_value("Think Effort", $effort, 16);
   $self->display_key_value("Think Mode", $mode, 16);

    # Show reasoning mode from model capabilities (how the model handles thinking)
    my $reasoning_mode = undef;
    if ($self->{ai_agent} && $self->{ai_agent}->{api}) {
        my $api_manager = $self->{ai_agent}->{api};
        if ($api_manager->can('get_model_capabilities')) {
            my $caps = eval {
                $api_manager->get_model_capabilities($model)
            };
            $reasoning_mode = $caps->{reasoning_mode} if $caps;
        }
    }

    # Show provider reasoning schema (data-driven param format)
    my $schema = $self->_get_current_provider_schema();
    my $schema_mode = $schema->{mode} // 'N/A';
    my $schema_label = "unknown";
    if ($schema_mode eq 'disabled') {
        $schema_label = 'disabled (local inference - no reasoning params)';
    } elsif ($schema_mode eq 'native') {
        $schema_label = 'native (handled by provider API)';
    } elsif ($schema_mode eq 'effort') {
        $schema_label = "effort ($schema->{param})";
    } elsif ($schema_mode eq 'nested') {
        $schema_label = "nested ($schema->{param})" . ($schema->{values} ? " values: " . join(',', @{$schema->{values}}) : "");
    } elsif ($schema_mode eq 'think_object') {
        $schema_label = "think_object ($schema->{think_param})";
    } elsif ($schema_mode eq 'mixed') {
        $schema_label = "mixed ($schema->{think_param} + $schema->{effort_param})";
    }
    $self->display_key_value("Reasoning Schema", $schema_label, 16);

    if ($reasoning_mode) {
        $self->display_key_value("Reason Mode", $reasoning_mode, 16);
    }

    # Show search configuration
    my $serpapi_key = $self->{config}->get('serpapi_key') || '';
    my $display_serpapi = $serpapi_key
        ? substr($serpapi_key, 0, 8) . '...' . substr($serpapi_key, -4)
        : 'not set';
    my $search_engine   = $self->{config}->get('search_engine')   || 'auto';
    my $search_provider = $self->{config}->get('search_provider') || 'auto';
    $self->display_key_value("SerpAPI Key", $display_serpapi, 16);
    $self->display_key_value("Search Engine", $search_engine, 16);
    $self->display_key_value("Search Provider", $search_provider, 16);

    # Show GitHub PAT (only when set)
    my $github_pat = $self->{config}->get('github_pat') || '';
    if ($github_pat) {
        my $display_pat = substr($github_pat, 0, 8) . '...' . substr($github_pat, -4);
        $self->display_key_value("GitHub PAT", $display_pat, 16);
    }

   # Show sampling overrides (only when set)
    for my $param (qw(temperature top_p top_k)) {
        my $val = $self->{config}->get("sampling_$param");
        if (defined $val && $val ne '') {
            $self->display_key_value(ucfirst($param), $val . " (override)", 16);
        }
    }

    # Show capability cap overrides (only when set)
    for my $cap (qw(context_window max_output max_prompt)) {
        my $val = $self->{config}->get("cap_$cap");
        if (defined $val && $val && $val > 0) {
            my $model_default = $self->_get_model_default_for_cap($cap);
            my $suffix = $model_default
                ? sprintf(" (cap %s, model: %s)", _format_token_count($val), _format_token_count($model_default))
                : " (override)";
            $self->display_key_value(
                _humanize_cap_name($cap) . " cap",
                _format_token_count($val) . $suffix,
                16
            );
        }
    }

    # Show capability force overrides (only when set)
    for my $cap (qw(tools vision reasoning)) {
        my $val = $self->{config}->get("force_$cap");
        if (defined $val && $val ne '') {
            $self->display_key_value(
                "Force $cap",
                $val,
                16
            );
        }
    }

    if (keys %session_overrides) {
        $self->writeline("", markdown => 0);
        $self->display_system_message("(session) = session-only override, use /api set <key> <value> to save globally");
    }

    $self->writeline("", markdown => 0);
}

=head2 _get_model_default_for_cap($cap)

Look up the model's actual default value for a capability cap (context_window,
max_output, max_prompt). Used by /api show to display what the model reports
versus what is currently capped.

Returns: integer token count, or undef if not available.

=cut

sub _get_model_default_for_cap {
    my ($self, $cap) = @_;

    return undef unless $self->{ai_agent} && $self->{ai_agent}->{api};

    my $caps = eval { $self->{ai_agent}->{api}->get_model_capabilities() };
    return undef unless $caps && ref($caps) eq 'HASH';

    my $key = $cap eq 'context_window' ? 'max_context_window_tokens'
           : $cap eq 'max_output'     ? 'max_output_tokens'
           : $cap eq 'max_prompt'     ? 'max_prompt_tokens'
           : undef;

    return undef unless $key;
    return undef unless defined $caps->{$key} && $caps->{$key} > 0;
    return $caps->{$key};
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
    } elsif ($api_base =~ m{^https?://[^/]+:8080/}i) {
        # SAM conventionally listens on 8080. Use the user-supplied base URL
        # directly so LAN deployments (e.g. http://max:8080) work.
        my $base_url = $api_base;
        $base_url =~ s{/chat/completions$}{};
        $base_url =~ s{/v1$}{};
        $base_url =~ s{/+$}{};
        return ('sam', "$base_url/v1/models");
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
