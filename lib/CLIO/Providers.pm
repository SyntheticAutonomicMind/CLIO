# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Providers;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(
    get_provider list_providers provider_exists
    build_endpoint_config DEFAULT_MODEL provider_from_url
    is_local_inference exposes_props default_context_window
    capability_fetcher default_reasoning_mode
    quota_handler
);

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
        model => undef,  # No default - user must specify (local inference)
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        max_context_tokens => 32000,
        slow_api => 1,  # Local inference is significantly slower than cloud APIs
        llama_user_id_supported => 1,
        # Provider-feature flags (replaces scattered `provider =~ /^sam$/`
        # checks in MessageValidator/APIManager/MCM). See the helper
        # functions is_local_inference() and exposes_props() below for
        # usage and the per-flag rationale.
        local_inference => 1,
        exposes_props => 1,
        url_detection_patterns => [ qr{^https?://[^/]+:8080/}i ],
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
        model => 'claude-sonnet-4.6',  # Default fallback - copilot_models fetches dynamic list at startup
        requires_auth => 'copilot',
        supports_tools => 1,
        supports_streaming => 1,
        supports_reasoning => 1,  # Claude 4, GPT-5, o-series exposed via /chat/completions
        supports_cache_control => 1,  # Passes cache_control through to upstream Claude/GPT models
        chat_endpoint_suffix => '/chat/completions',
        copilot_models => 1,
        # Capability fetcher dispatch (replaces `provider =~ /^...$/i`
        # chain in ModelCapabilitiesManager._fetch_provider_capabilities).
        # The fetcher method name is `_fetch_<value>_capabilities`.
        capability_fetcher => 'github_copilot',
        # Copilot exposes a /user/quota endpoint via the CopilotUserAPI.
        # /billing surfaces the result. UI/Commands/API/Auth::handle_quota
        # dispatches by this name to a provider-specific handler method.
        # Centralises the old `provider eq 'github_copilot'` check.
        has_quota_api => 1,
        quota_handler => 'copilot',
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
        supports_cache_control => 1,  # OpenAI prompt caching on gpt-4o/o1/o3/etc.
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
        supports_reasoning => 1,
        max_context_tokens => 1048576,
        max_output_tokens => 32768,
        capability_map => 1,
        static_models => 1,
        # DeepSeek's /v1/models endpoint doesn't return full capability
        # metadata; the MCM static map is authoritative. Flagged so
        # /api models display can pull from MCM instead.
        lacks_models_metadata => 1,
        capability_fetcher => 'deepseek',
        default_reasoning_mode => 'effort',  # DeepSeek uses reasoning_effort parameter
        # DeepSeek uses CONCURRENCY limits (not RPM) per their docs at
        # https://api-docs.deepseek.com/quick_start/rate_limit. Different
        # models have different caps:
        #   deepseek-v4-pro:   500 concurrent connections per account
        #   deepseek-v4-flash: 2500 concurrent connections per account
        # These are wired into RateLimiter via configure_rate_limiter().
        model_concurrency => {
            'deepseek-v4-pro'   => 500,
            'deepseek-v4-flash' => 2500,
        },
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
        # Per-session SSD cache directory on the inference server. CLIO
        # injects the session_id as llama_user_id so each session gets
        # its own ssd-cache/u/<hash>/ dir, preventing cross-session
        # checkpoint contamination (all CLIO sessions with the same
        # model share the same conv_hash, so continuation matching
        # would otherwise pull checkpoints from unrelated sessions).
        llama_user_id_supported => 1,
        local_inference => 1,
        exposes_props => 1,
        capability_fetcher => 'llama_cpp',
        # No url_detection_patterns - llama.cpp's port is freely configurable
        # (the server binds to whatever --port flag was passed), so we can't
        # safely auto-detect. Users explicitly register as --provider llama.cpp.
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
            sampling_defaults => { temperature => 1.0, top_p => 0.95, top_k => 20 },
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
        llama_user_id_supported => 1,
        local_inference => 1,
        exposes_props => 1,
        url_detection_patterns => [ qr{^https?://[^/]+:1234/}i ],
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
            sampling_defaults => { temperature => 1.0, top_p => 0.95, top_k => 20 },
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
        supports_cache_control => 1,  # OpenRouter passes cache_control through to upstream
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
            openrouter => 1,
            # OpenRouter uses its own `reasoning: {enabled, effort}` param,
            # not OpenAI's `reasoning_effort`. The flag tells APIManager
            # to skip the OpenAI-compat reasoning_effort injection.
            native_thinking_format => 1,
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
        capability_fetcher => 'google',
        default_reasoning_mode => 'enabled',  # Gemini uses thinkingBudget (enabled) per its native API
        endpoint => {
            path_suffix => '/openai/chat/completions',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
            google => 1,
            # Google's Gemini handles thinking via its own native API
            # (temperature settings + thought tokens), not via OpenAI's
            # `reasoning_effort`. Skip the OpenAI-compat injection.
            native_thinking_format => 1,
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
        # MiniMax exposes a /v1/token_plan/quota endpoint for the
        # Token Plan variant. /billing surfaces a hint to use it.
        has_quota_api => 1,
        # UI/Commands/API/Auth::handle_quota dispatches by this name
        # to a provider-specific handler method on the UI command
        # class. Centralising here removes the old
        # `provider =~ /^minimax/i` check.
        quota_handler => 'minimax',
        # MiniMax's /v1/models response lacks capability metadata.
        # The MCM static map is authoritative. Flagged so /api models
        # display can pull from MCM instead.
        lacks_models_metadata => 1,
        capability_fetcher => 'minimax',
        # MiniMax reasoning_mode is decided per-model by the M3 vs M2.x
        # name pattern (M3 adaptive, M2.x enabled). The M3 vs M2.x split
        # is a model-family property, not a provider-level default.
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
            minimax => 1,
            # MiniMax handles thinking via its own `thinking: {type}`
            # param + `reasoning_split: true` flag. Skip the OpenAI-compat
            # reasoning_effort injection to avoid double-sending.
            native_thinking_format => 1,
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
        has_quota_api => 1,
        # Token Plan shares the minimax quota handler (same /v1/token_plan/usage
        # endpoint). The dispatch field on this entry points at the same
        # handler so the UI doesn't need a second method.
        quota_handler => 'minimax',
        lacks_models_metadata => 1,
        capability_fetcher => 'minimax',  # Token Plan uses the same fetcher as the standard provider
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
            minimax => 1,
            native_thinking_format => 1,
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
        capability_fetcher => 'zai',
        default_reasoning_mode => 'enabled',  # GLM uses thinking: {type} thinking mode (enabled by default)
        endpoint => {
            path_suffix => '/chat/completions',
            temperature_range => [0.0, 1.0],
            top_p_default => 0.95,
            supports_tools => 1,
            zai => 1,
            reasoning_field => 'reasoning_content',
            # Z.AI handles thinking via its own `thinking: {type}` param.
            # Skip the OpenAI-compat reasoning_effort injection.
            native_thinking_format => 1,
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
        capability_fetcher => 'zai',  # Coding plan uses same fetcher
        endpoint => {
            path_suffix => '/chat/completions',
            temperature_range => [0.0, 1.0],
            top_p_default => 0.95,
            supports_tools => 1,
            zai => 1,
            reasoning_field => 'reasoning_content',
            native_thinking_format => 1,
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
        # Claude 4.5/4.6 default output is 64K per platform.claude.com
        # Models overview (verified 2026-07-31). Haiku 4.5 is also 64K.
        # Sonnet 5+/Fable 5/Opus 5 default is 128K. With the
        # `output-128k-2025-02-19` beta header Claude 4.5 reaches 128K,
        # and with `output-300k-2026-03-24` the latest models reach
        # 300K. The Anthropic native API exposes per-model max via
        # /v1/models/{id}; when reachable, MCM uses that exact value
        # instead of this 64K default.
        max_output_tokens => 64000,
        native_api => 1,
        provider_module => 'CLIO::Providers::Anthropic',
        capability_fetcher => 'anthropic',
        default_reasoning_mode => 'adaptive',  # most Anthropic models now use adaptive thinking; family heuristic handles per-version
        endpoint => {
            path_suffix => '',
            temperature_range => [0.0, 1.0],
            supports_tools => 1,
            anthropic => 1,
            # Anthropic handles thinking via its own `thinking: {type}`
            # param (native API). Skip the OpenAI-compat reasoning_effort
            # injection.
            native_thinking_format => 1,
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
        native_api => 1,  # Has dedicated capability fetcher (static map + heuristics)
        supports_tools => 1,
        supports_streaming => 1,
        supports_reasoning => 1,  # Many NIM models support reasoning (DeepSeek V4, Nemotron Ultra, etc.)
        supports_cache_control => 1,  # NIM OpenAI-compat accepts cache_control; some models use it
        keep_model_prefix => 1,  # NVIDIA model IDs include "nvidia/" namespace prefix
        # NVIDIA's /v1/models response omits most capability fields
        # (context_window, max_output_tokens). The NIM static map in
        # ModelCapabilitiesManager is the source of truth. Flagged so
        # /api models display can pull from MCM.
        lacks_models_metadata => 1,
        capability_fetcher => 'nvidia',
        endpoint => {
            path_suffix => '/chat/completions',
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
            nvidia => 1,  # Marker for APIManager.adapt_request_for_endpoint
            extra_headers => {
                'Accept' => 'text/event-stream',
            },
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
    
    # Merge JSON defaults if available
    my $json_defaults = _get_json_provider_defaults($name);
    if ($json_defaults) {
        # JSON defaults take precedence for overlapping keys
        %provider = (%provider, %$json_defaults);
    }
    
    return \%provider;
}

=head2 _get_json_provider_defaults

Load provider defaults from JSON file (cached).

=cut

my $_json_provider_defaults_cache;
sub _get_json_provider_defaults {
    my ($name) = @_;
    return unless $name;
    
    unless ($_json_provider_defaults_cache) {
        eval {
            require CLIO::Core::ModelDataLoader;
            my $loader = CLIO::Core::ModelDataLoader->new();
            # Call a method to trigger lazy loading
            $_json_provider_defaults_cache = $loader->get_provider_defaults('openai') ? $loader->{_cache}{provider_defaults} || {} : {};
        };
        if ($@) {
            # Silently ignore if ModelDataLoader not available
            $_json_provider_defaults_cache = {};
        }
    }
    
    return $_json_provider_defaults_cache->{$name};
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
    # Propagate supports_cache_control so APIManager can place cache_control
    # markers on the stable-anchor system messages for prompt caching
    # (OpenAI gpt-4o/o-series, OpenRouter passthrough, GitHub Copilot Claude/GPT,
    # NVIDIA NIM). The marker anchors the LCP cache to the stable anchor
    # [0..2] = system_prompt + summary + context_files.
    if ($provider && $provider->{supports_cache_control}) {
        $endpoint->{supports_cache_control} = 1;
    }
    # Propagate llama_user_id_supported so APIManager can inject the
    # session_id as llama_user_id for SSD-backed local inference servers.
    if ($provider && $provider->{llama_user_id_supported}) {
        $endpoint->{llama_user_id_supported} = 1;
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

=head2 is_local_inference($provider_name)

Returns 1 if the named provider is a local-inference server (sam,
llama.cpp, lmstudio, ...), 0 otherwise.

Centralizes the "is this a local inference server?" check that used to
live as `provider =~ /^(sam|llama\.cpp|lmstudio)$/i` scattered across
MessageValidator.pm and APIManager.pm. Adding a new local inference
provider now requires setting the C<local_inference> flag in the
provider's registry entry - no other code changes.

Local inference is flagged when:
- The server runs the model in-process (i.e. on a host the user owns)
  rather than forwarding tokens to a third-party API. Local servers
  are RAM-limited, so DEFAULT_LOCAL_CONTEXT_WINDOW is the safe fallback
  when the /v1/models endpoint doesn't report a context.
- Server-defined extras (llama_user_id, conservative timeout) apply.

Arguments:
- $provider_name: provider key (e.g. 'sam', 'llama.cpp')

Returns: 1 if local inference, 0 otherwise (including unknown providers).

=cut

sub is_local_inference {
    my ($provider_name) = @_;
    my $p = get_provider($provider_name);
    return 0 unless $p;
    return $p->{local_inference} ? 1 : 0;
}

=head2 exposes_props($provider_name)

Returns 1 if the named provider's HTTP server exposes the llama.cpp-style
C</props> endpoint (default_generation_settings.n_ctx), 0 otherwise.

Centralizes the "try /props to discover runtime context window" gating
that used to live as C<$api_type =~ /^(generic|sam|lmstudio|llama\.cpp)$/i>
in ModelCapabilitiesManager.pm.

/props is reported by llama.cpp and compatible servers (LM Studio,
SAM forks) as the runtime C<n_ctx>, which is set with C<--ctx-size> on
server start and may differ from the model's training context
(n_ctx_train) reported by /v1/models. For other servers the endpoint
returns 404 or malformed JSON, so we only query it when the flag is set.

Arguments:
- $provider_name: provider key

Returns: 1 if the provider's server supports /props, 0 otherwise.

=cut

sub exposes_props {
    my ($provider_name) = @_;
    my $p = get_provider($provider_name);
    return 0 unless $p;
    return $p->{exposes_props} ? 1 : 0;
}

=head2 default_context_window($provider_name)

Returns the right DEFAULT context-window fallback for a provider.
Local inference servers (C<is_local_inference>) get
DEFAULT_LOCAL_CONTEXT_WINDOW (smaller) because the model's max context
is bounded by host RAM. Everything else gets DEFAULT_CONTEXT_WINDOW.

Previously implemented as a ternary on a hardcoded regex list in
MessageValidator.pm and APIManager.pm's _extract_model_capabilities.

Now uses the unified JSON model data via ModelDataLoader, with
CLIO::Core::Defaults constants as fallback.

Arguments:
- $provider_name: provider key

Returns: integer token count

=cut

sub default_context_window {
    my ($provider_name) = @_;
    
    # Try JSON defaults first
    my $json_defaults = _get_json_provider_defaults($provider_name);
    if ($json_defaults && $json_defaults->{max_context_tokens}) {
        return $json_defaults->{max_context_tokens};
    }
    
    # Fallback to constants
    require CLIO::Core::Defaults;
    if (is_local_inference($provider_name)) {
        return CLIO::Core::Defaults::DEFAULT_LOCAL_CONTEXT_WINDOW();
    }
    return CLIO::Core::Defaults::DEFAULT_CONTEXT_WINDOW();
}

=head2 capability_fetcher($provider_name)

Returns the name of the ModelCapabilitiesManager fetcher method to call
for this provider (e.g. C<'anthropic'> means C<_fetch_anthropic_capabilities>).
Returns undef for providers without a dedicated fetcher (callers fall
back to the generic OpenAI-compatible fetcher).

Centralizes the `provider =~ /^...$/i` chain previously used in
ModelCapabilitiesManager._fetch_provider_capabilities. Adding a new
provider with a dedicated fetcher now means setting one field in the
registry; the dispatcher doesn't change.

Arguments:
- $provider_name: provider key (e.g. 'anthropic', 'minimax')

Returns: string with the fetcher suffix, or undef if no fetcher
         is declared for the provider.

=cut

sub capability_fetcher {
    my ($provider_name) = @_;
    my $p = get_provider($provider_name);
    return undef unless $p;
    return $p->{capability_fetcher};
}

=head2 default_reasoning_mode($provider_name)

Returns the registry-declared default reasoning_mode for the named
provider, or undef if the provider doesn't declare one. Callers
(typically MCM::_ensure_reasoning_mode) layer this with other
signals (data-driven flags, model-name heuristics) to decide the
final mode.

Centralizes the `provider =~ /^minimax/i` / `provider =~ /^zai/i`
cascade previously in MCM._ensure_reasoning_mode.

Arguments:
- $provider_name: provider key (e.g. 'zai', 'google')

Returns: 'adaptive' | 'enabled' | 'effort' | undef.

=cut

sub default_reasoning_mode {
    my ($provider_name) = @_;
    my $p = get_provider($provider_name);
    return undef unless $p;
    return $p->{default_reasoning_mode};
}

=head2 quota_handler($provider_name)

Returns the name of the UI/Commands/API/Auth handler method to call
for this provider's quota API, or undef if the provider doesn't
provide one.

Centralizes the `provider =~ /^minimax/i` and `provider eq
'github_copilot'` chain previously used in
CLIO::UI::Commands::API::Auth::handle_quota. Each provider with a
quota API declares a quota_handler in its registry; the UI layer
locates the handler by name without knowing provider names.

For backwards-compatibility the returned suffix is intended to match
an existing C<_handle_<suffix>_quota> method on the UI command class.
Current suffixes used: 'minimax' (covers minimax + minimax_token)
and 'copilot' (github_copilot).

Arguments:
- $provider_name: provider key

Returns: handler suffix string, or undef if no quota API.

=cut

sub quota_handler {
    my ($provider_name) = @_;
    my $p = get_provider($provider_name);
    return undef unless $p;
    return undef unless $p->{has_quota_api};
    return $p->{quota_handler};
}

=head2 provider_from_url($url)

Detect provider name from an API base URL.

Cloud providers are matched against well-known domain patterns (e.g.
api.anthropic.com). Local inference providers are matched against the
C<url_detection_patterns> declared on their own provider entry -
this way, adding a new local server only requires touching the
registry, not this function.

Arguments
  $url - API base URL (e.g., 'https://api.githubcopilot.com')

Returns:
  Provider name string, or undef if no match

=cut

sub provider_from_url {
    my ($url) = @_;
    return unless defined $url;

    # Standard API providers - well-known domain patterns. Hardcoded
    # by name because the host portion of the URL is the primary key
    # (not a port or path we could confuse with another provider).
    return 'github-copilot' if $url =~ m{githubcopilot\.com}i;
    return 'openai'         if $url =~ m{api\.openai\.com}i;
    return 'google'         if $url =~ m{generativelanguage\.googleapis\.com}i;
    return 'openrouter'     if $url =~ m{openrouter\.ai}i;
    return 'minimax'        if $url =~ m{api\.minimax\.io}i;
    return 'ollama-cloud'   if $url =~ m{ollama\.com}i;
    return 'deepseek'       if $url =~ m{api\.deepseek\.com}i;
    return 'anthropic'      if $url =~ m{api\.anthropic\.com}i;
    return 'zai-coding'     if $url =~ m{api\.z\.ai.*coding}i;
    return 'zai'            if $url =~ m{api\.z\.ai}i;
    return 'nvidia'         if $url =~ m{integrate\.api\.nvidia\.com}i;

    # DashScope variants (unified under 'dashscope' provider)
    return 'dashscope' if $url =~ m{dashscope.*\.aliyuncs\.com}i;

    # Provider-declared URL detection patterns. Iterates each provider
    # that opts in by listing url_detection_patterns -> [qr{}, ...].
    # Useful for local servers where hostname/port identifies the
    # service (e.g. lmstudio on :1234, sam on :8080). llama.cpp
    # intentionally has no entries because its port is freely
    # configurable - users must register it explicitly.
    for my $name (list_providers()) {
        my $p = $PROVIDERS{$name};
        next unless $p && ref($p->{url_detection_patterns}) eq 'ARRAY';
        for my $pat (@{$p->{url_detection_patterns}}) {
            return $name if $url =~ $pat;
        }
    }

    return;
}


=head2 configure_rate_limiter

Configure the RateLimiter singleton with provider-specific model concurrency
limits declared in the provider registry. Should be called once at startup
so per-model concurrency caps (e.g. DeepSeek's 500 for v4-pro) take effect
before the first request.

Currently configures:
- DeepSeek: model_concurrency map from Providers.pm
- Other providers: defaults from DEFAULT_MAX_CONCURRENT in RateLimiter

Arguments:
- $rate_limiter: Optional CLIO::Core::RateLimiter instance. If omitted,
                 uses the RateLimiter singleton.

Returns: Number of model concurrency entries configured (for logging).

=cut

sub configure_rate_limiter {
    my ($rate_limiter) = @_;

    # Lazy-load RateLimiter to avoid circular deps (Providers.pm is loaded
    # before RateLimiter.pm in some startup paths).
    unless ($rate_limiter) {
        require CLIO::Core::RateLimiter;
        $rate_limiter = CLIO::Core::RateLimiter->get_instance();
    }

    my $count = 0;
    for my $provider_name (list_providers()) {
        my $provider = $PROVIDERS{$provider_name};
        next unless $provider && $provider->{model_concurrency};

        for my $model (keys %{$provider->{model_concurrency}}) {
            my $max = $provider->{model_concurrency}{$model};
            $rate_limiter->set_model_concurrency($provider_name, $model, $max);
            $count++;
        }
    }
    return $count;
}

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0-only

=cut

1;
