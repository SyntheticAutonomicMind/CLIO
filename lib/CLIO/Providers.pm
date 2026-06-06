# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Providers;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(get_provider list_providers provider_exists build_endpoint_config DEFAULT_MODEL);

# Fallback model when no model is configured anywhere.
# This should rarely be reached - Config and provider defaults take priority.
use constant DEFAULT_MODEL => 'gpt-4.1';

=head1 NAME

CLIO::Providers - Central provider registry for CLIO

=head1 DESCRIPTION

Single source of truth for all API provider configurations.
Defines default settings for each provider (api_base, model, capabilities).
Users can override any setting via /api commands, but these are the defaults.

=head1 SYNOPSIS

    use CLIO::Providers qw(get_provider list_providers);
    
    my $provider = get_provider('sam');
    # Returns: { name => 'SAM', api_base => 'http://localhost:8080/api/chat/completions', ... }
    
    my @providers = list_providers();
    # Returns: ('sam', 'github_copilot', 'openai', ...)

=cut

# THE SINGLE SOURCE OF TRUTH FOR PROVIDER CONFIGURATIONS
# Each provider has:
#   - name: Display name
#   - api_base: Base URL for API requests
#   - model: Default model to use
#   - requires_auth: Authentication method (optional, copilot/apikey/none)
#   - supports_tools: Whether provider supports function calling
#   - supports_streaming: Whether provider supports streaming responses
#   - chat_endpoint_suffix: Path to append to api_base for chat (if not already in api_base)
#   - slow_api: Flag for local inference providers requiring longer HTTP timeouts (default: 300s, slow_api: 600s)

my %PROVIDERS = (
    sam => {
        name => 'SAM (Local)',
        api_base => 'http://localhost:8080/v1/chat/completions',
        model => 'github_copilot/gpt-4.1',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        max_context_tokens => 32000,
        slow_api => 1,  # Local inference is significantly slower than cloud APIs
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
            requires_sam_config => 1,
        },
    },
    
    github_copilot => {
        name => 'GitHub Copilot',
        api_base => 'https://api.githubcopilot.com',
        model => 'claude-haiku-4.5',
        requires_auth => 'copilot',
        supports_tools => 1,
        supports_streaming => 1,
        supports_reasoning => 1,  # Claude 4, GPT-5, o-series exposed via /chat/completions
        chat_endpoint_suffix => '/chat/completions',
        copilot_models => 1,
        priority_display => 1,
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 1.0],
            supports_tools => 1,
            requires_copilot_headers => 1,
        },
    },
    
    openai => {
        name => 'OpenAI',
        api_base => 'https://api.openai.com/v1/chat/completions',
        model => 'gpt-4.1',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        supports_reasoning => 1,  # o-series and gpt-5 accept reasoning_effort
        endpoint => {
            path_suffix => '/chat/completions',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
            openai => 1,  # Marker for APIManager.adapt_request_for_endpoint
        },
    },
    
    deepseek => {
        name => 'DeepSeek',
        api_base => 'https://api.deepseek.com/v1',
        model => 'deepseek-v4-pro',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        chat_endpoint_suffix => '/chat/completions',
        endpoint => {
            path_suffix => '/chat/completions',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
        },
    },
    
    'llama.cpp' => {
        name => 'llama.cpp (Local)',
        api_base => 'http://localhost:8080/v1/chat/completions',
        model => 'local-model',
        requires_auth => 'none',
        supports_tools => 1,
        supports_streaming => 1,
        max_context_tokens => 32000,
        slow_api => 1,  # Local inference is significantly slower than cloud APIs
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
        },
    },
    
    lmstudio => {
        name => 'LM Studio',
        api_base => 'http://localhost:1234/v1/chat/completions',
        model => 'local-model',
        requires_auth => 'none',
        supports_tools => 1,
        supports_streaming => 1,
        max_context_tokens => 32000,
        slow_api => 1,  # Local inference is significantly slower than cloud APIs
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
        },
    },
    
    ollama_cloud => {
        name => 'Ollama Cloud',
        api_base => 'https://ollama.com/v1/chat/completions',
        model => 'gemma4:31b',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        max_context_tokens => 128000,
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
        },
    },
    
    openrouter => {
        name => 'OpenRouter',
        api_base => 'https://openrouter.ai/api/v1/chat/completions',
        model => 'meta-llama/llama-3.1-405b-instruct:free',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
            openrouter => 1,
        },
    },
    
    google => {
        name => 'Google Gemini',
        api_base => 'https://generativelanguage.googleapis.com/v1beta',
        model => 'gemini-2.5-flash',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        supports_reasoning => 1,
        native_api => 1,
        provider_module => 'CLIO::Providers::Google',
        max_context_tokens => 1048576,
        endpoint => {
            path_suffix => '/openai/chat/completions',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
            google => 1,
        },
    },
    
    minimax => {
        name => 'MiniMax',
        api_base => 'https://api.minimax.io/v1/chat/completions',
        model => 'MiniMax-M3',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        supports_reasoning => 1,
        supports_vision => 1,
        max_context_tokens => 1000000,
        max_output_tokens => 131072,
        capability_map => 1,
        static_models => 1,
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
            minimax => 1,
            # Recommended sampling params per MiniMax model card
            sampling_defaults => { temperature => 1.0, top_p => 0.95, top_k => 40 },
        },
    },
    
    minimax_token => {
        name => 'MiniMax Token Plan',
        api_base => 'https://api.minimax.io/v1/chat/completions',
        model => 'MiniMax-M3',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        supports_reasoning => 1,
        supports_vision => 1,
        max_context_tokens => 1000000,
        max_output_tokens => 131072,
        capability_map => 1,
        static_models => 1,
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
            minimax => 1,
            sampling_defaults => { temperature => 1.0, top_p => 0.95, top_k => 40 },
        },
    },
    
    zai => {
        name => 'Z.AI (Chat)',
        api_base => 'https://api.z.ai/api/paas/v4',
        model => 'glm-5.1',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        supports_reasoning => 1,
        supports_vision => 1,
        max_context_tokens => 200000,
        max_output_tokens => 131072,
        capability_map => 1,
        static_models => 1,
        endpoint => {
            path_suffix => '/chat/completions',
            temperature_range => [0.0, 1.0],
            top_p_default => 0.95,
            supports_tools => 1,
            zai => 1,
            reasoning_field => 'reasoning_content',
            sampling_defaults => { temperature => 1.0, top_p => 0.95 },
        },
    },
    
    zai_coding => {
        name => 'Z.AI (Coding)',
        api_base => 'https://api.z.ai/api/coding/paas/v4',
        model => 'glm-5.1',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        supports_reasoning => 1,
        supports_vision => 1,
        max_context_tokens => 200000,
        max_output_tokens => 131072,
        capability_map => 1,
        static_models => 1,
        endpoint => {
            path_suffix => '/chat/completions',
            temperature_range => [0.0, 1.0],
            top_p_default => 0.95,
            supports_tools => 1,
            zai => 1,
            reasoning_field => 'reasoning_content',
            coding_plan => 1,
        sampling_defaults => { temperature => 1.0, top_p => 0.95 },
        },
    },
    
    anthropic => {
        name => 'Anthropic',
        api_base => 'https://api.anthropic.com/v1/messages',
        model => 'claude-sonnet-4-20250514',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        supports_reasoning => 1,
        supports_vision => 1,
        max_context_tokens => 200000,
        max_output_tokens => 16384,
        native_api => 1,
        provider_module => 'CLIO::Providers::Anthropic',
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 1.0],
            supports_tools => 1,
            anthropic => 1,
            auth_header => 'x-api-key',
            auth_value_format => '{api_key}',
            extra_headers => {
                'anthropic-version' => '2023-06-01',
            },
        },
    },
    
    nvidia => {
        name => 'NVIDIA NIM',
        api_base => 'https://integrate.api.nvidia.com/v1',
        model => 'nvidia/nemotron-3-ultra-550b-a55b',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        supports_reasoning => 0,  # NVIDIA NIM doesn't expose reasoning_effort parameter
        native_api => 1,
        provider_module => 'CLIO::Providers::NVIDIA',
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
            nvidia => 1,  # Marker for APIManager.adapt_request_for_endpoint
        },
    },
);

=head2 get_provider

Get provider configuration by name

Arguments:
  $name - Provider name (e.g. 'sam', 'openai')

Returns:
  Hashref with provider config, or undef if not found

=cut

sub get_provider {
    my ($name) = @_;
    
    return unless defined $name;
    return unless exists $PROVIDERS{$name};
    
    # Return copy so caller can't modify the registry
    my %provider = %{$PROVIDERS{$name}};
    return \%provider;
}

=head2 list_providers

Get list of all provider names

Returns:
  Array of provider names in alphabetical order

=cut

sub list_providers {
    return sort keys %PROVIDERS;
}

=head2 provider_exists

Check if a provider exists

Arguments:
  $name - Provider name to check

Returns:
  1 if provider exists, 0 otherwise

=cut

sub provider_exists {
    my ($name) = @_;
    
    return 0 unless defined $name;
    return exists $PROVIDERS{$name} ? 1 : 0;
}

=head2 build_endpoint_config($provider_name, $api_key)

Build endpoint configuration for a provider with the given API key.

Combines the static endpoint config from the provider registry with
the dynamic auth value. This is the single source of truth for endpoint
config - APIManager delegates here instead of maintaining its own hashes.

Arguments:
  $provider_name - Provider name (e.g. 'google', 'openrouter')
  $api_key       - API key/token to use for auth

Returns:
  Hashref with: auth_header, auth_value, path_suffix, temperature_range,
  supports_tools, and any provider-specific flags (openrouter, requires_copilot_headers, etc.)

=cut

sub build_endpoint_config {
    my ($provider_name, $api_key) = @_;
    $api_key //= '';

    my $provider = $PROVIDERS{$provider_name};

    # Default config for unknown providers
    my $defaults = {
        path_suffix => '/chat/completions',
        temperature_range => [0.0, 2.0],
        supports_tools => 1,
    };

    my $endpoint = ($provider && $provider->{endpoint})
        ? { %{$provider->{endpoint}} }
        : { %$defaults };

    # Propagate top-level provider flags into endpoint config for APIManager
    if ($provider && $provider->{supports_reasoning}) {
        $endpoint->{supports_reasoning} //= $provider->{supports_reasoning};
    }

    # Add dynamic auth
    $endpoint->{auth_header} = 'Authorization';
    $endpoint->{auth_value}  = "Bearer $api_key";

    # Handle Anthropic-specific auth (x-api-key header instead of Bearer)
    if ($endpoint->{anthropic}) {
        $endpoint->{auth_header} = 'x-api-key';
        $endpoint->{auth_value}  = $api_key;
        # Merge extra_headers into endpoint config for APIManager
        if ($provider && $provider->{endpoint} && $provider->{endpoint}{extra_headers}) {
            $endpoint->{extra_headers} = { %{$provider->{endpoint}{extra_headers}} };
        }
    }

    return $endpoint;
}

=head2 validate_provider

Validate that a provider exists.

Arguments:
  - provider_name: Provider identifier (e.g., 'openai')

Returns:
  - (1, '') if valid
  - (0, error_message) if invalid

=cut

sub validate_provider {
    my ($provider_name) = @_;
    
    unless (defined $provider_name && length($provider_name)) {
        return (0, "Provider name cannot be empty");
    }
    
    if (provider_exists($provider_name)) {
        return (1, '');
    }
    
    my @providers = list_providers();
    my $providers_str = join(', ', @providers);
    return (0, "Provider '$provider_name' not found. Available: $providers_str");
}

1;

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0-only

=cut

1;
