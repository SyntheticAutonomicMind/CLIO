# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::ModelCapabilitiesManager;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_debug log_warning log_error);
use CLIO::Util::ConfigPath qw(get_config_file);
use CLIO::Util::JSON qw(encode_json decode_json safe_decode_json);
use CLIO::Compat::HTTP;
use Fcntl qw(LOCK_EX LOCK_UN LOCK_NB);

# Bump this when the capability schema or data sources change to
# invalidate stale cache entries from a previous version of CLIO.
use constant CACHE_VERSION => 2;

=head1 NAME

CLIO::Core::ModelCapabilitiesManager - Centralized model capability fetching and caching

=head1 DESCRIPTION

Fetches and caches model capabilities from multiple AI providers, providing a unified
interface for agents to query model features like context window, tool support,
vision support, and other provider-specific capabilities.

Inspired by the Ollama Cloud model capability fetching pattern, but generalized
to work with any provider that exposes model metadata via API.

=head1 CAPABILITY SCHEMA

Each capability record contains:

    {
        provider          => Provider name (e.g., 'github_copilot', 'ollama_cloud'),
        model             => Model ID (e.g., 'gpt-4.1', 'llama3.1:8b'),
        context_window    => Total context window in tokens,
        max_prompt_tokens => Maximum prompt tokens (may be less than context_window),
        max_output_tokens => Maximum completion tokens,
        supports_tools    => Boolean - function calling / tool use,
        supports_streaming => Boolean - streaming responses,
        supports_vision   => Boolean - image input support,
        supports_reasoning => Boolean - extended thinking / reasoning,
        reasoning_mode    => String - thinking mode: 'effort', 'enabled', 'adaptive' (or undef),
                             Determines what param format to use within the provider's API:
                               'effort'   -> reasoning_effort / effort parameter
                               'enabled'  -> thinking with budget_tokens
                               'adaptive' -> thinking with automatic budget, effort hint only
        embeddings_dimension => Integer - embedding vector size (or undef),
        architecture      => String - model architecture (e.g., 'llama', 'gpt-4'),
        quantization      => String - quantization level (e.g., 'Q4_K_M'),
        parameters        => Integer - parameter count (or undef),
        capabilities      => Arrayref - list of capability flags,
        size_bytes        => Integer - model size in bytes (if available),
        raw               => Hashref - original provider-specific data,
    }

=head1 SYNOPSIS

    use CLIO::Core::ModelCapabilitiesManager;
    
    my $mcm = CLIO::Core::ModelCapabilitiesManager->new(
        debug => 1,
        cache_file => '/path/to/cache.json',
        cache_ttl => 3600,  # 1 hour default TTL
    );
    
    # Fetch capabilities for a specific model
    my $caps = $mcm->get_capabilities('github_copilot', 'gpt-4.1');
    
    # Check if model supports a feature
    if ($mcm->supports_feature('github_copilot', 'gpt-4.1', 'tools')) {
        # Use tools with this model
    }
    
    # Refresh cached capabilities
    $mcm->refresh_capabilities('ollama_cloud', 'llama3.1:8b');

=cut

=head2 new

Create a new ModelCapabilitiesManager.

Arguments:
- debug: Enable debug output (optional, default: 0)
- cache_dir: Cache directory path (optional, default: from ConfigPath)
- cache_ttl: Default cache TTL in seconds (optional, default: 3600)

=cut

sub new {
    my ($class, %args) = @_;

    my $cache_file = get_config_file('model_capabilities_cache.json');

    my $self = {
        debug               => $args{debug} || 0,
        cache_file          => $args{cache_file} || $cache_file,
        cache_ttl           => $args{cache_ttl} || 3600,
        cache               => undef,  # Lazily loaded
        cache_version       => $args{cache_version} || CACHE_VERSION,
        http                => undef,  # Lazily created
        model_data_loader   => undef,  # Lazily created ModelDataLoader
    };

    bless $self, $class;
    return $self;
}

=head2 _model_data_loader

Get or create the ModelDataLoader instance.

=cut

sub _model_data_loader {
    my ($self) = @_;
    unless ($self->{model_data_loader}) {
        eval {
            require CLIO::Core::ModelDataLoader;
            $self->{model_data_loader} = CLIO::Core::ModelDataLoader->new(debug => $self->{debug});
        };
        if ($@) {
            log_debug('ModelCapabilitiesManager', "Failed to create ModelDataLoader: $@");
        }
    }
    return $self->{model_data_loader};
}

=head2 get_capabilities

Get capabilities for a specific model, fetching from provider if needed.

Arguments:
- $provider: Provider name (e.g., 'github_copilot', 'ollama_cloud')
- $model: Model identifier

Returns:
- Hashref with capability data (schema above), or undef if not available

=cut

sub get_capabilities {
    my ($self, $provider, $model) = @_;

    return undef unless $provider && $model;

    $self->_ensure_cache_loaded();

    # Cache key includes the model's normalized form AND the current
    # api_base for the provider. This means:
    # - Same model with different casings/prefixes (e.g. "MiniMax-M3",
    #   "minimax-m3", "minimax/MiniMax-M3") share a cache entry
    # - /api set base changes produce a new cache key, so the old
    #   entry is unreachable and expires after TTL. Without this, the
    #   cached entry from the previous api_base would be served for
    #   up to 1 hour, which is wrong when the user has switched proxies
    #   or hosts.
    my $cache_key = $self->_build_cache_key($provider, $model);

    # Local inference providers (llama.cpp, SAM, LM Studio) always hit the
    # live server — their --ctx-size and loaded model can change between
    # sessions, making the on-disk cache stale. APIManager already caches
    # results in-memory for within-session deduplication.
    my $cached;
    unless (CLIO::Providers::is_local_inference($provider)) {
        $cached = $self->_get_cached($cache_key);
    }
    if ($cached) {
        log_debug('ModelCapabilitiesManager', "Cache hit for $cache_key");
        return $cached;
    }
    
    log_debug('ModelCapabilitiesManager', "Cache miss for $cache_key, fetching");
    
    # Fetch from provider
    my $capabilities = $self->_fetch_provider_capabilities($provider, $model);
    
    if ($capabilities) {
        # Post-process: ensure reasoning_mode is populated
        $self->_ensure_reasoning_mode($capabilities, $provider, $model);
        $self->_set_cached($cache_key, $capabilities);
    }
    
    return $capabilities;
}

=head2 supports_feature

Check if a model supports a specific feature.

Arguments:
- $provider: Provider name
- $model: Model identifier
- $feature: Feature name ('tools', 'streaming', 'vision', 'reasoning')

Returns:
- Boolean (1 if supported, 0 if not), or undef if model not found

=cut

sub supports_feature {
    my ($self, $provider, $model, $feature) = @_;
    
    my $caps = $self->get_capabilities($provider, $model);
    return undef unless $caps;
    
    my %feature_map = (
        tools     => 'supports_tools',
        streaming => 'supports_streaming',
        vision    => 'supports_vision',
        reasoning => 'supports_reasoning',
    );
    
    my $field = $feature_map{$feature};
    return undef unless $field;
    return $caps->{$field} ? 1 : 0;
}

=head2 get_model_info

Get a summarized info string for a model.

Arguments:
- $provider: Provider name
- $model: Model identifier

Returns:
- String with key capability highlights, or undef if not found

=cut

sub get_model_info {
    my ($self, $provider, $model) = @_;
    
    my $caps = $self->get_capabilities($provider, $model);
    return undef unless $caps;
    
    my @features;
    push @features, 'tools'     if $caps->{supports_tools};
    push @features, 'streaming' if $caps->{supports_streaming};
    push @features, 'vision'   if $caps->{supports_vision};
    push @features, 'reasoning' if $caps->{supports_reasoning};
    
    my $ctx = $caps->{context_window} 
        ? $self->_format_tokens($caps->{context_window})
        : 'unknown';
    
    my $info = "context: $ctx";
    $info .= ", " . join(', ', @features) if @features;
    
    return $info;
}

=head2 refresh_capabilities

Force refresh of cached capabilities for a model.

Arguments:
- $provider: Provider name
- $model: Model identifier

Returns:
- Hashref with new capability data, or undef on failure

=cut

sub refresh_capabilities {
    my ($self, $provider, $model) = @_;

    return undef unless $provider && $model;

    $self->_ensure_cache_loaded();

    # Same cache-key construction as get_capabilities so the refresh
    # overwrites the right entry (not a sibling that the next read
    # won't see).
    my $cache_key = $self->_build_cache_key($provider, $model);
    my $capabilities = $self->_fetch_provider_capabilities($provider, $model);

    if ($capabilities) {
        # Post-process: ensure reasoning_mode is populated
        $self->_ensure_reasoning_mode($capabilities, $provider, $model);
        $self->_set_cached($cache_key, $capabilities);
    }

    return $capabilities;
}

=head2 _build_cache_key (Internal)

Build the cache key for a (provider, model) pair. Includes the current
api_base so changes to /api set base invalidate the cached entry
implicitly (old key becomes unreachable, expires after TTL).

The model is normalized (lowercased, org/ prefix stripped) so
"MiniMax-M3", "minimax-m3", and "minimax/MiniMax-M3" share a single
cache entry instead of creating three siblings.

The api_base is included as-is (raw, untransformed). Different
fetchers may transform it differently to derive their own URLs;
what matters for cache keying is that the user's configured base
changed, which means the data the fetcher gets back is potentially
different.

Arguments:
- $provider: Provider name
- $model:    Model identifier

Returns: cache key string

=cut

sub _build_cache_key {
    my ($self, $provider, $model) = @_;

    # Normalize model: lowercase + strip a leading org/ segment.
    my $normalized_model = lc($model);
    $normalized_model =~ s{^[^/]+/}{};

    # Read the user's configured api_base (if any) so a /api set base
    # change produces a new key. The eval keeps the rest of the
    # function working even if Config is unavailable (e.g. during
    # a code path that constructs MCM before Config exists).
    my $api_base = '';
    eval {
        require CLIO::Core::Config;
        my $config = CLIO::Core::Config->new();
        my $user_base = $config->get_provider_base($provider);
        $api_base = $user_base if defined $user_base && length $user_base;
    };

    return "${provider}:${normalized_model}:${api_base}";
}

=head2 clear_cache

Clear all cached capabilities.

=cut

sub clear_cache {
    my ($self) = @_;
    
    $self->{cache} = {};
    
    if (-f $self->{cache_file}) {
        unlink $self->{cache_file} or log_debug('ModelCapabilitiesManager', "Failed to clear cache: $!");
    }
    
    log_debug('ModelCapabilitiesManager', "Cache cleared");
}

=head2 get_http

Get or create HTTP client instance.

=cut

sub get_http {
    my ($self) = @_;
    
    unless ($self->{http}) {
        $self->{http} = CLIO::Compat::HTTP->new(timeout => 60);
    }
    
    return $self->{http};
}

=head2 _ensure_cache_loaded

Lazily load cache from disk.

=cut

sub _ensure_cache_loaded {
    my ($self) = @_;
    
    return if $self->{cache};
    
    $self->{cache} = {};
    
    if (-f $self->{cache_file}) {
        eval {
            open my $fh, '<:encoding(UTF-8)', $self->{cache_file};
            if ($fh) {
                my $data = do { local $/; <$fh> };
                close $fh;
                if ($data) {
                    my $decoded = decode_json($data);
                    # Validate cache version — stale entries from a
                    # previous schema are discarded so bad data
                    # (e.g. supports_tools=0 from a bug) doesn't persist.
                    if ($decoded->{_cache_version} && $decoded->{_cache_version} eq $self->{cache_version}) {
                        $self->{cache} = $decoded;
                    } else {
                        log_debug('ModelCapabilitiesManager', "Cache version mismatch (stored: " . ($decoded->{_cache_version} // 'none') . ", expected: $self->{cache_version}), discarding cache");
                    }
                }
            }
        };
        if ($@) {
            log_debug('ModelCapabilitiesManager', "Failed to load cache: $@");
            $self->{cache} = {};
        }
    }
}

=head2 _save_cache

Persist cache to disk (atomic write).

=cut

sub _save_cache {
    my ($self) = @_;
    
    my $temp = $self->{cache_file} . '.tmp';
    
    eval {
        open my $fh, '>:encoding(UTF-8)', $temp or die "Cannot write $temp: $!";
        flock($fh, LOCK_EX | LOCK_NB) if $fh;
        # Store the cache version alongside the data so future loads
        # can detect and discard stale entries.
        $self->{cache}->{_cache_version} = $self->{cache_version};
        print $fh encode_json($self->{cache});
        close $fh;
        
        rename($temp, $self->{cache_file}) or die "Cannot rename cache: $!";
    };
    
    if ($@) {
        log_debug('ModelCapabilitiesManager', "Failed to save cache: $@");
        unlink $temp;
    }
}

=head2 _get_cached

Get a capability record from cache if not expired.

Arguments:
- $cache_key: Provider:Model string

Returns:
- Hashref if valid cached entry exists, undef otherwise

=cut

sub _get_cached {
    my ($self, $cache_key) = @_;
    
    my $entry = $self->{cache}{$cache_key};
    return undef unless $entry;
    
    # Check TTL
    my $cached_at = $entry->{_cached_at} || 0;
    my $age = time - $cached_at;
    
    if ($age > $self->{cache_ttl}) {
        log_debug('ModelCapabilitiesManager', "Cache expired for $cache_key (age: $age)s");
        return undef;
    }
    
    return $entry;
}

=head2 _set_cached

Store a capability record in cache.

Arguments:
- $cache_key: Provider:Model string
- $capabilities: Hashref of capability data

=cut

sub _set_cached {
    my ($self, $cache_key, $capabilities) = @_;
    
    $self->{cache}{$cache_key} = {
        %$capabilities,
        _cached_at => time,
    };
    
    $self->_save_cache();
}

=head2 set_reasoning_mode($provider, $model, $mode)

Persist a corrected reasoning_mode for a model. Used by the self-
correcting retry path: when the API returns HTTP 400 with a self-
describing error like

    "thinking.type.enabled" is not supported for this model.
    Use "thinking.type.adaptive" ...

APIManager extracts the correct mode ("adaptive") from the error and
calls this method so the next request for this model uses the right
mode the first time, with no wasted round-trip and no name-heuristic
guessing.

Also sets the data-driven supports_adaptive_thinking /
supports_enabled_thinking flag (whichever matches the new mode) so
_ensure_reasoning_mode's authoritative-data path wins over the
heuristic on subsequent calls, not just the persisted cache.

Arguments:
- $provider: Provider name (e.g. 'anthropic')
- $model: Model identifier (no provider prefix - the bare API name)
- $mode: 'adaptive' or 'enabled'

Returns: 1 on success, 0 on failure.

=cut

sub set_reasoning_mode {
    my ($self, $provider, $model, $mode) = @_;

    return 0 unless $provider && $model && $mode;
    return 0 unless $mode =~ /^(?:adaptive|enabled)$/;

    my $cache_key = $self->_build_cache_key($provider, $model);

    # Get existing entry (from cache or fetch fresh). If we have nothing
    # in cache, create a minimal entry with just the mode fields so the
    # learning survives even when /v1/models fetch failed entirely.
    my $entry = $self->{cache}{$cache_key};
    unless ($entry) {
        # No prior fetch - create a minimal learned entry. It won't have
        # context_window etc. (those need a real API response), but it
        # WILL have the correct mode so reasoning requests work.
        $entry = {
            provider           => $provider,
            model              => $model,
            supports_reasoning => 1,
            _cached_at         => time,
            _learned           => 1,  # Marker: this entry was learned, not fetched
        };
    }

    # Update mode and the data-driven flag. The data-driven flag is what
    # _ensure_reasoning_mode checks first; setting it ensures we don't
    # re-trigger the heuristic on subsequent calls.
    $entry->{reasoning_mode} = $mode;
    if ($mode eq 'adaptive') {
        $entry->{supports_adaptive_thinking} = 1;
    }
    elsif ($mode eq 'enabled') {
        $entry->{supports_enabled_thinking} = 1;
    }
    $entry->{supports_reasoning} = 1;
    $entry->{_learned_at} = time;

    $self->{cache}{$cache_key} = $entry;
    $self->_save_cache();

    log_debug('ModelCapabilitiesManager', "Learned reasoning_mode=$mode for $provider:$model (self-corrected from API error)");
    return 1;
}

=head2 _fetch_provider_capabilities

Route fetch to provider-specific method.

Arguments:
- $provider: Provider name
- $model: Model identifier

Returns:
- Hashref with capability data, or undef on failure

=cut

sub _fetch_provider_capabilities {
    my ($self, $provider, $model) = @_;

    log_debug('ModelCapabilitiesManager', "Fetching capabilities for ${provider}:${model}");

    my $loader = $self->_model_data_loader();
    require CLIO::Providers;
    my $provider_def = CLIO::Providers::get_provider($provider);
    my $is_local = $provider_def && CLIO::Providers::is_local_inference($provider);

    # For local inference providers (llama.php, SAM, LM Studio): the
    # JSON database is the primary source — these servers' /v1/models
    # responses are sparse (no supported_parameters, no reasoning data).
    # The /props endpoint provides the authoritative runtime context
    # window that may differ from the model's training context.
    # JSON-first + /props enrichment stays for local providers.
    if ($is_local) {
        if ($loader) {
            my $json_caps = $loader->get_model_capabilities_by_provider($provider, $model);
            if ($json_caps) {
                log_debug('ModelCapabilitiesManager', "JSON loader hit for ${provider}:${model}");
                my $caps = $self->_build_caps_from_json($json_caps, $provider, $model);

                my $props_ctx = $self->_query_llama_props_for_provider($provider);
                if ($props_ctx && $props_ctx > 0) {
                    $caps->{context_window} = $props_ctx;
                    $caps->{max_prompt_tokens} = $props_ctx;
                    log_debug('ModelCapabilitiesManager', "${provider} /props n_ctx=$props_ctx for $model (overriding training context)");
                }

                return $caps;
            }
        }

        # JSON miss: try /props-only for runtime context
        my $props_ctx = $self->_query_llama_props_for_provider($provider);
        if ($props_ctx && $props_ctx > 0) {
            log_debug('ModelCapabilitiesManager', "${provider} /props n_ctx=$props_ctx for $model (JSON miss, props-only)");
            return {
                context_window       => $props_ctx,
                max_prompt_tokens    => $props_ctx,
                max_output_tokens    => 16384,
                supports_tools       => 1,
                supports_streaming   => 1,
                supports_vision      => 0,
                supports_reasoning   => 0,
            };
        }
        log_debug('ModelCapabilitiesManager', "${provider} /props query failed for $model");
    }

    # For all other providers: the API is the source of truth. Try the
    # live API first, fall back to the static JSON database only if the
    # API is unavailable or doesn't know the model. This ensures we get
    # live context windows, supported_parameters, and tool/vision support
    # that may differ from the static JSON (e.g. OpenRouter laguna-s-2.1
    # has 1M context at runtime, not the 128K in the JSON database).
    # Static JSON data may be stale or provider-specific (e.g. a model
    # family entry lists providers: ["llama.cpp"] but the same model may
    # be available via OpenRouter with a different context window).

    # 1. Dedicated provider fetcher (Anthropic, Google, DeepSeek, NVIDIA,
    #    MiniMax, Z.AI, GitHub Copilot). These have native API endpoints
    #    that return authoritative capability data.
    if ($provider_def) {
        my $fetcher = CLIO::Providers::capability_fetcher($provider);
        if ($fetcher) {
            my $method = "_fetch_${fetcher}_capabilities";
            if ($self->can($method)) {
                log_debug('ModelCapabilitiesManager', "Using provider fetcher for ${provider}:${model}");
                my $api_caps = $self->$method($provider, $model);
                if ($api_caps) {
                    return $api_caps;
                }
                log_debug('ModelCapabilitiesManager',
                    "Provider fetcher returned no caps for ${provider}:${model}, falling back to JSON");
            } else {
                log_debug('ModelCapabilitiesManager',
                    "Provider $provider declared fetcher '$fetcher' but method $method is missing");
            }
        }
    }

    # 2. OpenAI-compatible API fetcher (OpenRouter, OpenAI, Vercel,
    #    KiloCode, OrcaRouter, Ollama Cloud). These are apikey-based
    #    providers without a dedicated fetcher — they expose an
    #    OpenAI-compatible /v1/models endpoint.
    if ($provider_def
        && $provider_def->{requires_auth}
        && $provider_def->{requires_auth} eq 'apikey') {

        # Skip the OpenAI-compatible path if we already tried a dedicated
        # fetcher above (those providers aren't OpenAI-compatible).
        my $fetcher = CLIO::Providers::capability_fetcher($provider);
        unless ($fetcher) {
            my $api_caps = $self->_fetch_openai_compatible_capabilities($provider, $model);
            if ($api_caps) {
                return $api_caps;
            }
            log_debug('ModelCapabilitiesManager',
                "OpenAI-compatible fetcher returned no caps for ${provider}:${model}, falling back to JSON");
        }
    }

    # 3. JSON loader fallback (static database). Used when the API fetch
    #    failed (network error, no auth, model not on the API) to provide
    #    a best-effort guess so the session can still proceed.
    if ($loader) {
        my $json_caps = $loader->get_model_capabilities_by_provider($provider, $model);
        if ($json_caps) {
            log_debug('ModelCapabilitiesManager', "JSON loader fallback hit for ${provider}:${model}");
            return $self->_build_caps_from_json($json_caps, $provider, $model);
        }
    }

    # 4. Heuristics (last resort). Pattern-based inference for model
    #    names that aren't in any database or API response.
    if ($loader) {
        my $heuristic_caps = $loader->match_heuristics($model);
        if ($heuristic_caps) {
            log_debug('ModelCapabilitiesManager', "Heuristic fallback for ${provider}:${model}");
            return $self->_build_caps_from_json($heuristic_caps, $provider, $model);
        }
    }

    log_debug('ModelCapabilitiesManager', "No capability source found for ${provider}:${model}");
    return undef;
}

=head2 _build_caps_from_json

Build full capabilities hash from JSON loader data.

Arguments:
- $json_caps: Capabilities hash from ModelDataLoader
- $provider: Provider name
- $model: Original model ID

Returns:
- Hashref with full capability schema

=cut

sub _build_caps_from_json {
    my ($self, $json_caps, $provider, $model) = @_;
    
    return {
        provider              => $provider,
        model                 => $model,
        context_window        => $json_caps->{context_window},
        max_prompt_tokens     => $json_caps->{max_prompt_tokens} || $json_caps->{context_window},
        max_output_tokens     => $json_caps->{max_output_tokens},
        supports_tools        => $json_caps->{supports_tools} ? 1 : 0,
        supports_streaming    => $json_caps->{supports_streaming} ? 1 : 0,
        supports_vision       => $json_caps->{supports_vision} ? 1 : 0,
        supports_reasoning    => $json_caps->{supports_reasoning} ? 1 : 0,
        reasoning_mode        => $json_caps->{reasoning_mode},
        embeddings_dimension  => undef,
        architecture          => $json_caps->{architecture},
        quantization          => undef,
        parameters            => undef,
        capabilities          => [],
        size_bytes            => undef,
        raw                   => $json_caps,
    };
}

=head2 _fetch_github_copilot_capabilities

Fetch capabilities from GitHub Copilot /models API.

Arguments:
- $model: Model identifier

Returns:
- Hashref with capability data

=cut

sub _fetch_github_copilot_capabilities {
    my ($self, $provider, $model) = @_;

    my $caps;
    eval {
        require CLIO::Core::GitHubCopilotModelsAPI;

        my $models_api = CLIO::Core::GitHubCopilotModelsAPI->new(
            debug => $self->{debug},
            cache_ttl => 0,  # Force refresh to get latest
        );

        $caps = $models_api->get_model_capabilities($model);
    };

    if ($@) {
        log_debug('ModelCapabilitiesManager', "Failed to fetch GitHub Copilot capabilities: $@");
        return undef;
    }

    return undef unless $caps;

    # Translate the GitHub Copilot-specific schema to the MCM standard
    # schema. Copilot's get_model_capabilities returns its own field
    # names (max_context_window_tokens, max_thinking_budget, etc.)
    # that are useful for the copilot-specific code paths, but MCM
    # consumers expect the standard fields (context_window,
    # supports_reasoning, reasoning_mode, etc.).
    #
    # Without this translation:
    # - supports_reasoning is undef, so _ensure_reasoning_mode below
    #   returns early without setting a mode. The result: APIManager
    #   sees reasoning_mode=undef and doesn't send reasoning_effort,
    #   even when the model actually supports it. This was the
    #   "thinking never sent for copilot models" bug.
    # - context_window is missing, so /api models shows "-" for
    #   context_window on copilot rows.
    my $supports_adaptive = $caps->{supports_adaptive_thinking} ? 1 : 0;
    # If/when GitHubCopilotModelsAPI starts extracting
    # supports_enabled_thinking, this picks it up automatically.
    my $supports_enabled = $caps->{supports_enabled_thinking} ? 1 : 0;

    return {
        provider                => 'github_copilot',
        model                   => $model,
        context_window          => $caps->{max_context_window_tokens},
        max_prompt_tokens       => $caps->{max_prompt_tokens},
        max_output_tokens       => $caps->{max_output_tokens},
        supports_tools          => $caps->{supports_tools},
        supports_streaming      => $caps->{supports_streaming},
        supports_vision         => $caps->{supports_vision},
        # supports_reasoning drives _ensure_reasoning_mode below. If
        # either adaptive or enabled thinking is supported, the model
        # can do reasoning. The mode itself is filled in by
        # _ensure_reasoning_mode from the supports_adaptive_thinking /
        # supports_enabled_thinking fields.
        supports_reasoning      => ($supports_adaptive || $supports_enabled) ? 1 : 0,
        supports_adaptive_thinking => $supports_adaptive,
        supports_enabled_thinking  => $supports_enabled,
        embeddings_dimension    => undef,
        architecture            => $caps->{family},
        quantization            => undef,
        parameters              => undef,
        capabilities            => [],
        size_bytes              => undef,
        # Preserve the copilot-specific fields the rest of the code
        # may use (max_thinking_budget, supported_endpoints, vendor,
        # category, picker_enabled, preview, reasoning_effort).
        raw                     => $caps,
    };
}

=head2 _fetch_anthropic_capabilities

Fetch capabilities from Anthropic API.

Arguments:
- $model: Model identifier (e.g. 'claude-sonnet-4-20250514')

Returns:
- Hashref with capability data

=cut

sub _fetch_anthropic_capabilities {
    my ($self, $provider, $model) = @_;

    # Anthropic exposes two related endpoints:
    #   GET /v1/models/{model_id}  - rich per-model data including
    #       capabilities.thinking.types.{adaptive,enabled} which drive
    #       reasoning_mode resolution.
    #   GET /v1/models             - list of available models, sparse by
    #       default but proxies (Azure AI Foundry, custom deployments)
    #       may add context_window/max_output_tokens.
    #
    # The Anthropic native API supports both. Anthropic-compatible proxies
    # often only support the LIST endpoint, or alias models under
    # deployment names so the per-model endpoint 404s for the configured
    # model name. Try per-model first (rich data path), fall back to LIST
    # with _find_model_in_list (case-insensitive + prefix-stripped match).
    my ($api_key, $user_api_base);
    eval {
        require CLIO::Core::Config;
        my $config = CLIO::Core::Config->new();
        $api_key = $config->get_provider_key('anthropic');
        $user_api_base = $config->get_provider_base('anthropic');
    };

    return undef unless $api_key;

    my $http = $self->get_http();
    my $api_base;
    if ($user_api_base) {
        # User set /api set base for anthropic. The chat endpoint is
        # /v1/messages; the models endpoint is /v1/models/{model_id}. Strip
        # a trailing /messages (or /messages/) so the same override can
        # supply both endpoints, then append /models.
        my $base = $user_api_base;
        $base =~ s{/+messages/?$}{};
        $api_base = "${base}/models";
        log_debug('ModelCapabilitiesManager', "Anthropic MCM using user api_base=$user_api_base (models URL=$api_base)");
    }
    else {
        $api_base = 'https://api.anthropic.com/v1/models';
    }

    # Try per-model endpoint first (/v1/models/{model_id}). This is the
    # rich data path: Anthropic native returns the full capabilities
    # structure including supports_adaptive_thinking / supports_enabled_thinking.
    my $per_model_url = "$api_base/$model";
    my $resp = $http->get($per_model_url, headers => {
        'x-api-key' => $api_key,
        'anthropic-version' => '2023-06-01',
        'Accept' => 'application/json',
    });

    if ($resp->{success}) {
        my $data = eval { decode_json($resp->{content}) };
        if (!$@ && $data && $data->{id}) {
            return $self->_parse_anthropic_per_model_response($data, $model);
        }
        log_debug('ModelCapabilitiesManager', "Anthropic per-model endpoint returned malformed response for $model, trying /v1/models list");
    }
    else {
        log_debug('ModelCapabilitiesManager', "Anthropic per-model endpoint failed for $model: HTTP $resp->{status}, trying /v1/models list");
    }

    # Fall back to LIST endpoint (/v1/models). The list endpoint is more
    # permissive about model aliases - proxies that gate by deployment
    # name (Azure AI Foundry, custom deployments) typically expose the
    # full list but 404 the per-model endpoint for arbitrary model names.
    # Use _find_model_in_list to handle case-insensitive and prefix-
    # stripped matches (response may have 'anthropic/claude-sonnet-4-6'
    # while caller passes 'claude-sonnet-4-6', or vice versa).
    my $list_resp = $http->get($api_base, headers => {
        'x-api-key' => $api_key,
        'anthropic-version' => '2023-06-01',
        'Accept' => 'application/json',
    });

    unless ($list_resp->{success}) {
        log_debug('ModelCapabilitiesManager', "Anthropic models list also failed: HTTP $list_resp->{status}");
        return undef;
    }

    my $list_data = eval { decode_json($list_resp->{content}) };
    if ($@ || !$list_data) {
        log_debug('ModelCapabilitiesManager', "Failed to parse Anthropic list response: " . ($@ // 'empty body'));
        return undef;
    }

    # Anthropic LIST returns { data: [...] }; tolerate { models: [...] }
    # for proxies that follow a different shape.
    my $entries = $list_data->{data} || $list_data->{models} || [];
    my $matched = $self->_find_model_in_list($entries, $model, 'id');
    unless ($matched) {
        log_debug('ModelCapabilitiesManager', "Anthropic model $model not found in /v1/models list response");
        return undef;
    }

    return $self->_build_anthropic_caps_from_list_entry($matched, $model);
}

=head2 _parse_anthropic_per_model_response (Internal)

Translate the rich /v1/models/{model_id} response into the MCM standard
schema. This is the path taken when Anthropic's own API (or a faithful
proxy) responds to the per-model endpoint. Only this path can populate
supports_adaptive_thinking and supports_enabled_thinking - those fields
are not in the LIST response.

Arguments:
    $data            - Decoded JSON body from /v1/models/{model_id}
    $requested_model - Model name the caller asked for (used as fallback
                       when the response omits an id field)

Returns: MCM capability hashref.

=cut

sub _parse_anthropic_per_model_response {
    my ($self, $data, $requested_model) = @_;

    my $caps = $data->{capabilities} || {};
    my $thinking = $caps->{thinking} || {};
    my $image_input = $caps->{image_input} || {};

    # max_tokens from the API is the maximum value for the max_tokens
    # parameter (i.e., max output tokens). max_input_tokens is the
    # context window.
    my $max_output = $data->{max_tokens};
    my $context_window = $data->{max_input_tokens};

    require CLIO::Providers;
    my $pdef = CLIO::Providers::get_provider('anthropic');
    $max_output //= $pdef->{max_output_tokens} if $pdef;
    $context_window //= $pdef->{max_context_tokens} if $pdef;

    my $supports_adaptive = ($thinking->{types} && $thinking->{types}{adaptive} && $thinking->{types}{adaptive}{supported} ? 1 : 0);
    my $supports_enabled  = ($thinking->{types} && $thinking->{types}{enabled}  && $thinking->{types}{enabled}{supported}  ? 1 : 0);
    my $requires_adaptive = $self->_anthropic_requires_adaptive($data->{id} // $requested_model, $thinking);

    return {
        provider              => 'anthropic',
        model                 => $data->{id} // $requested_model,
        context_window        => $context_window,
        max_prompt_tokens     => $context_window,
        max_output_tokens     => $max_output,
        supports_tools        => 1,  # All Claude models support tools
        supports_streaming    => 1,
        supports_vision       => ($image_input->{supported} ? 1 : 0),
        supports_reasoning    => ($thinking->{supported} ? 1 : 0),
        supports_adaptive_thinking => $supports_adaptive,
        supports_enabled_thinking  => $supports_enabled,
        requires_adaptive_thinking => $requires_adaptive,
        embeddings_dimension  => undef,
        architecture          => 'claude',
        quantization          => undef,
        parameters            => undef,
        capabilities          => [],
        size_bytes            => undef,
        raw                   => $data,
    };
}

=head2 _build_anthropic_caps_from_list_entry (Internal)

Translate one entry from the /v1/models LIST response into the MCM
standard schema. This is the fallback path taken when the per-model
endpoint fails (404 from a proxy that doesn't support per-model URLs,
or alias mismatch where the response id differs from the requested
model name).

LIST responses may be sparse (Anthropic native returns just id/
display_name/created_at/type) or rich (proxies like Azure Foundry
may add context_window, max_output_tokens, capabilities). Accept
whichever field names the proxy provides and fall back to the
Anthropic provider defaults from Providers.pm for anything missing.

Arguments:
    $entry           - Single hashref from /v1/models data array
    $requested_model - Model name the caller asked for

Returns: MCM capability hashref.

=cut

sub _build_anthropic_caps_from_list_entry {
    my ($self, $entry, $requested_model) = @_;

    require CLIO::Providers;
    my $pdef = CLIO::Providers::get_provider('anthropic');

    # Field-name flexibility. Anthropic native uses max_input_tokens/
    # max_tokens; OpenAI-style proxies use context_window/
    # max_completion_tokens; some proxies mix conventions. Take the
    # first defined value, in priority order.
    my $context_window = $entry->{max_input_tokens}
                       || $entry->{context_window}
                       || $entry->{context_length}
                       || ($pdef ? $pdef->{max_context_tokens} : undef);
    my $max_output = $entry->{max_tokens}
                   || $entry->{max_output_tokens}
                   || $entry->{max_completion_tokens}
                   || ($pdef ? $pdef->{max_output_tokens} : undef);

    # If the LIST response includes capabilities.thinking, surface the
    # adaptive/enabled flags so reasoning_mode resolution picks the
    # correct mode (adaptive vs enabled). Most proxies strip this; in
    # that case leave supports_adaptive_thinking / supports_enabled_thinking
    # undef and let _ensure_reasoning_mode's name heuristic run.
    my $caps_block = $entry->{capabilities} || {};
    my $thinking = $caps_block->{thinking};
    my $image_input = $caps_block->{image_input};

    my ($supports_adaptive, $supports_enabled, $supports_reasoning);
    if ($thinking && ref($thinking) eq 'HASH') {
        $supports_reasoning = $thinking->{supported} ? 1 : 0;
        # Only set adaptive/enabled when the type itself is present in the
        # response. A 'supported=>1' thinking block with no types.subfield
        # means the API didn't disambiguate; leave the flags undef so
        # _ensure_reasoning_mode's name heuristic picks the right mode.
        if ($thinking->{types} && ref($thinking->{types}) eq 'HASH') {
            $supports_adaptive = ($thinking->{types}{adaptive} && $thinking->{types}{adaptive}{supported}) ? 1 : 0;
            $supports_enabled  = ($thinking->{types}{enabled}  && $thinking->{types}{enabled}{supported})  ? 1 : 0;
        }
    }
    else {
        # No capabilities block in the LIST response. All current Claude
        # models support reasoning, but the sparse proxy response can't
        # confirm which mode. Set supports_reasoning=1 so reasoning_effort
        # gets sent, and leave adaptive/enabled undef so _ensure_reasoning_mode
        # picks the right mode via its name heuristic.
        $supports_reasoning = 1;
    }

    my $requires_adaptive = $self->_anthropic_requires_adaptive($entry->{id} // $requested_model, $thinking);

    return {
        provider              => 'anthropic',
        model                 => $entry->{id} // $requested_model,
        context_window        => $context_window,
        max_prompt_tokens     => $context_window,
        max_output_tokens     => $max_output,
        supports_tools        => 1,
        supports_streaming    => 1,
        supports_vision       => ($image_input && ref($image_input) eq 'HASH' && $image_input->{supported}) ? 1 : 0,
        supports_reasoning    => $supports_reasoning,
        supports_adaptive_thinking => $supports_adaptive,
        supports_enabled_thinking  => $supports_enabled,
        requires_adaptive_thinking => $requires_adaptive,
        embeddings_dimension  => undef,
        architecture          => 'claude',
        quantization          => undef,
        parameters            => undef,
        capabilities          => [],
        size_bytes            => undef,
        raw                   => $entry,
    };
}

=head2 _anthropic_requires_adaptive($model, $thinking_block)

Determine whether an Anthropic model REQUIRES adaptive thinking (cannot
be disabled). Returns 1 if adaptive is the only acceptable thinking
mode for this model.

Data-driven path: Anthropic's /v1/models response may include
capabilities.thinking.types.disabled.supported:false for models that
reject {type:"disabled"}. That explicit signal wins.

Fallback path: when the API response doesn't disambiguate (LIST path,
proxy stripped the disabled entry, or model is brand new and the
capabilities block is missing), the heuristic in this method handles
the known-required set: Fable 5, Mythos 5, Mythos Preview. These are
the only Anthropic model families where adaptive is mandatory as of
the docs at the time of this code.

Used by APIManager to override a user-set thinking_mode=disabled when
the model would 400. The override is logged so the user can see why
their config was ignored.

Arguments:
    $model         - Model identifier (bare name, no provider prefix)
    $thinking_block - The capabilities.thinking hashref from the API
                       response, or undef when unavailable

Returns: 1 if adaptive is required, 0 otherwise.

=cut

sub _anthropic_model_reasoning_mode {
    my ($self, $model) = @_;
    return undef unless defined $model && length $model;

    # Family detection. Anthropic family names (sonnet, opus, haiku,
    # fable, mythos) are unique to Anthropic - safe to use as the
    # family indicator regardless of provider config. This lets
    # custom Anthropic-compatible proxies (which may register under
    # a different provider name) still get the correct reasoning
    # mode. Proxy deployment aliases like "Proxy-Sonnet-5" match
    # because they contain "-sonnet-" / "-opus-" / etc.
    my $is_anthropic_family = ($model =~ /-(?:opus|sonnet|haiku|fable|mythos)-/i
                             || $model =~ /^claude-mythos/i);
    return undef unless $is_anthropic_family;

    # Adaptive-capable generations:
    #   - {family}-5, {family}-5-anything     (5-series is adaptive per docs)
    #   - {family}-4-{6,7,8,9}                (4.6+ adaptive)
    #   - {family}-4-{10..999}                (4.10+ adaptive; future-proofing)
    #   - claude-mythos*                      (any version, always adaptive)
    #
    # The (?!\d{8}) negative lookahead blocks the YYYYMMDD date-suffix
    # case: "claude-sonnet-4-20250514" must NOT classify as 4.{20250514}
    # adaptive. The lookahead sees 8 digits ahead and rejects the match.
    # (4-X dated is 4.0, which is legacy enabled mode.)
    if ($model =~ /-(?:opus|sonnet|haiku|fable|mythos)-(?:4-(?!\d{8})(?:[6-9](?:-|$|\b)|\d{2,3}(?:-|$|\b))|5(?:-|$|\b))/i
        || $model =~ /^claude-mythos/i) {
        return 'adaptive';
    }

    # Anthropic family but pre-4.6 generation -> legacy enabled mode
    # (claude-sonnet-4-20250514, claude-sonnet-4-5-20250929, claude-3-x-*, etc.)
    return 'enabled';
}

sub _anthropic_requires_adaptive {
    my ($self, $model, $thinking) = @_;

    # Data-driven path: explicit "disabled" rejection from the API.
    # The API signals models that reject {type:"disabled"} via
    # capabilities.thinking.types.disabled.supported:false.
    if ($thinking && ref($thinking) eq 'HASH'
        && $thinking->{types} && ref($thinking->{types}) eq 'HASH'
        && exists $thinking->{types}{disabled}
        && ref($thinking->{types}{disabled}) eq 'HASH'
        && defined $thinking->{types}{disabled}{supported}
        && !$thinking->{types}{disabled}{supported}) {
        return 1;
    }

    # Fallback: well-known families where adaptive is mandatory. These
    # are documented in Anthropic's adaptive-thinking docs. Keep the
    # match patterns tight so we don't accidentally force adaptive on
    # future models where it becomes optional again.
    return 1 if defined $model && $model =~ /-(?:fable|mythos)-5(?:-|$|\b)/i;
    return 1 if defined $model && $model =~ /^claude-mythos-preview(?:-|$|\b)/i;

    return 0;
}

=head2 _fetch_google_capabilities

Fetch capabilities from Google Gemini API.

Arguments:
- $model: Model identifier

Returns:
- Hashref with capability data

=cut

sub _fetch_google_capabilities {
    my ($self, $provider, $model) = @_;

    # Get API key and (optionally) a user-configured api_base for Google.
    my ($api_key, $user_api_base);
    eval {
        require CLIO::Core::Config;
        my $config = CLIO::Core::Config->new();
        $api_key = $config->get_provider_key('google');
        $user_api_base = $config->get_provider_base('google');
    };

    return undef unless $api_key;

    my $http = $self->get_http();
    # If the user has overridden the Google api_base (e.g. to point at a
    # Vertex AI proxy), honor that override. Strip a trailing slash and
    # append /models (Google's models endpoint is /v1beta/models for the
    # default public API; the proxy is expected to follow the same shape).
    my $api_base = $user_api_base ? $user_api_base : 'https://generativelanguage.googleapis.com/v1beta';
    $api_base =~ s{/+$}{};
    my $models_url = "$api_base/models?key=$api_key";
    log_debug('ModelCapabilitiesManager', "Google MCM using models_url=$models_url") if $user_api_base;
    
    my $resp = $http->get($models_url, headers => { 'Accept' => 'application/json' });
    
    unless ($resp->{success}) {
        log_debug('ModelCapabilitiesManager', "Google models API failed: HTTP " . $resp->{status});
        return undef;
    }
    
    my $data;
    eval {
        $data = decode_json($resp->{content});
    };
    if ($@) {
        log_debug('ModelCapabilitiesManager', "Failed to parse Google response: $@");
        return undef;
    }
    
    # Find the specific model. Use _find_model_in_list so case-insensitive
    # and prefix-stripped matches work (server returns "models/gemini-2.5-flash",
    # caller may pass "gemini-2.5-flash" or "google/gemini-2.5-flash").
    my $m = $self->_find_model_in_list($data->{models} || [], $model, 'name');
    if ($m) {
        my @methods = @{$m->{supportedGenerationMethods} || []};
        my $supports_tools = grep { $_ eq 'generateContent' } @methods;

        # Get token limits from model info
        my $output_tokens = $m->{outputTokenLimit} || undef;
        my $context_window = $m->{contextWindow} || $m->{maxPosition_embeddings} || undef;

        return {
            provider              => 'google',
            model                 => $model,
            context_window        => $context_window,
            max_prompt_tokens     => $context_window,
            max_output_tokens     => $output_tokens,
            supports_tools        => $supports_tools,
            supports_streaming    => 1,
            supports_vision       => $m->{visionModel} ? 1 : 0,
            supports_reasoning    => 0,
            embeddings_dimension  => undef,
            architecture          => undef,
            quantization         => undef,
            parameters           => undef,
            capabilities         => \@methods,
            size_bytes           => undef,
            raw                  => $m,
        };
    }

    return undef;
}

=head2 _fetch_nvidia_capabilities

Fetch capabilities from NVIDIA NIM API.

Arguments:
- $model: Model identifier

Returns:
- Hashref with capability data

=cut

sub _fetch_nvidia_capabilities {
    my ($self, $provider, $model) = @_;
    
    # NVIDIA NIM /v1/models returns only model IDs with no metadata.
    # This static capability map provides context windows and output limits
    # sourced from OpenRouter, build.nvidia.com specs, and model documentation.
    # Keys use the full model ID as returned by the NIM API (e.g., "deepseek-ai/deepseek-v4-flash").
    my %nvidia_models = (
        # --- DeepSeek ---
        'deepseek-ai/deepseek-v4-flash' => {
            context_window => 1048576, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        },
        'deepseek-ai/deepseek-v4-pro' => {
            context_window => 1048576, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        },
        'deepseek-ai/deepseek-coder-6.7b-instruct' => {
            context_window => 16384, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        
        # --- Google ---
        'google/gemma-2-2b-it' => {
            context_window => 8192, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'google/gemma-3-4b-it' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        },
        'google/gemma-3-12b-it' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        },
        'google/gemma-3n-e2b-it' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        },
        'google/gemma-4-31b-it' => {
            context_window => 262144, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        },
        'google/codegemma-7b' => {
            context_window => 8192, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'google/codegemma-1.1-7b' => {
            context_window => 8192, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        
        # --- IBM ---
        'ibm/granite-3.0-8b-instruct' => {
            context_window => 131072, max_output_tokens => 8192,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'ibm/granite-34b-code-instruct' => {
            context_window => 131072, max_output_tokens => 8192,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        
        # --- Meta Llama ---
        'meta/llama-3.1-8b-instruct' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'meta/llama-3.1-70b-instruct' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'meta/llama-3.2-1b-instruct' => {
            context_window => 131072, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'meta/llama-3.2-3b-instruct' => {
            context_window => 131072, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'meta/llama-3.2-11b-vision-instruct' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        },
        'meta/llama-3.2-90b-vision-instruct' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        },
        'meta/llama-3.3-70b-instruct' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'meta/llama-4-maverick-17b-128e-instruct' => {
            context_window => 1048576, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        },
        'meta/codellama-70b' => {
            context_window => 16384, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        
        # --- Microsoft ---
        'microsoft/phi-4-mini-instruct' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'microsoft/phi-4-multimodal-instruct' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        },
        'microsoft/phi-3.5-moe-instruct' => {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'microsoft/phi-3-vision-128k-instruct' => {
            context_window => 131072, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        },
        
        # --- MiniMax ---
        'minimaxai/minimax-m2.7' => {
            context_window => 1048576, max_output_tokens => 131072,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        },
        
        # --- Mistral ---
        'mistralai/mistral-large-3-675b-instruct-2512' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'mistralai/mistral-small-4-119b-2603' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'mistralai/mistral-medium-3.5-128b' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'mistralai/mistral-nemotron' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'mistralai/codestral-22b-instruct-v0.1' => {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'mistralai/ministral-14b-instruct-2512' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'mistralai/mistral-7b-instruct-v0.3' => {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'mistralai/mixtral-8x22b-v0.1' => {
            context_window => 65536, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'mistralai/mixtral-8x7b-instruct-v0.1' => {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'nv-mistralai/mistral-nemo-12b-instruct' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        
        # --- Moonshot ---
        # Kimi K2.6: 256K context, 32K default output per platform.kimi.ai
        # K2.6 quickstart docs (verified 2026-07-31). The docs explicitly
        # state: "max_tokens - optional - The maximum number of tokens to
        # generate for the chat completion. - int - Default to be 32k
        # aka 32768". Kimi K3 (not in our static map yet) defaults to
        # 131072 per platform.kimi.ai/docs/api/chat.
        'moonshotai/kimi-k2.6' => {
            context_window => 262144, max_output_tokens => 32768,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 1,
        },

        # --- NVIDIA Nemotron ---
        # Nemotron 3 Ultra/Super: 1M context, 32K output per docs.api.nvidia.com
        # NIM API reference (verified 2026-07-31 via the OpenCode example
        # config embedded in the docs, which sets "limit":{"output":32768}
        # for both Ultra and Super). The modelcard itself only states the
        # 1M context length for both input and output sections - the
        # 32K value is the practical NIM service default.
        'nvidia/nemotron-3-ultra-550b-a55b' => {
            context_window => 1048576, max_output_tokens => 32768,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        },
        'nvidia/nemotron-3-super-120b-a12b' => {
            context_window => 1048576, max_output_tokens => 32768,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        },
        'nvidia/nemotron-3-nano-30b-a3b' => {
            context_window => 262144, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning' => {
            context_window => 256000, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 1,
        },
        'nvidia/nemotron-4-340b-instruct' => {
            context_window => 131072, max_output_tokens => 8192,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'nvidia/nemotron-mini-4b-instruct' => {
            context_window => 131072, max_output_tokens => 8192,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'nvidia/nemotron-nano-12b-v2-vl' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        },
        'nvidia/nvidia-nemotron-nano-9b-v2' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        },
        
        # --- NVIDIA Nemotron (Llama-derived) ---
        'nvidia/llama-3.1-nemotron-ultra-253b-v1' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        },
        'nvidia/llama-3.3-nemotron-super-49b-v1.5' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        },
        'nvidia/llama-3.3-nemotron-super-49b-v1' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        },
        'nvidia/llama-3.1-nemotron-70b-instruct' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'nvidia/llama-3.1-nemotron-51b-instruct' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'nvidia/llama-3.1-nemotron-nano-8b-v1' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        },
        'nvidia/llama-3.1-nemotron-nano-vl-8b-v1' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 1,
        },
        'nvidia/llama3-chatqa-1.5-70b' => {
            context_window => 131072, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'nvidia/mistral-nemo-minitron-8b-8k-instruct' => {
            context_window => 8192, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'nvidia/nemotron-nano-3-30b-a3b' => {
            context_window => 262144, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'nvidia/cosmos-reason2-8b' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 0, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        },
        
        # --- OpenAI ---
        'openai/gpt-oss-120b' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'openai/gpt-oss-20b' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        
        # --- Qwen ---
        'qwen/qwen3-next-80b-a3b-instruct' => {
            context_window => 262144, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        },
        'qwen/qwen3.5-122b-a10b' => {
            context_window => 262144, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 1,
        },
        'qwen/qwen3.5-397b-a17b' => {
            context_window => 262144, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 1,
        },
        
        # --- Z.AI ---
        'z-ai/glm-5.1' => {
            context_window => 200000, max_output_tokens => 131072,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        },
        
        # --- Bytedance ---
        'bytedance/seed-oss-36b-instruct' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        
        # --- StepFun ---
        'stepfun-ai/step-3.5-flash' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'stepfun-ai/step-3.7-flash' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        
        # --- Writer ---
        'writer/palmyra-creative-122b' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'writer/palmyra-fin-70b-32k' => {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'writer/palmyra-med-70b' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        'writer/palmyra-med-70b-32k' => {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        
        # --- SarvamAI ---
        'sarvamai/sarvam-m' => {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        
        # --- 01.AI ---
        '01-ai/yi-large' => {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        
        # --- Stockmark ---
        'stockmark/stockmark-2-100b-instruct' => {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
        
        # --- Upstage ---
        'upstage/solar-10.7b-instruct' => {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        },
    );
    
    # Case-insensitive lookup (handles "minimax/MiniMax-M3", casing
    # differences between OpenRouter slugs and provider canonical ids,
    # and org/ prefix stripping).
    my $model_data = $self->_lookup_static_model(\%nvidia_models, $model, 'nvidia');

    # If no exact match, try pattern-based heuristics for model families
    if (!$model_data) {
        $model_data = $self->_nvidia_model_heuristics($model);
    }
    
    return undef unless $model_data;
    
    return {
        provider              => 'nvidia',
        model                 => $model,
        context_window        => $model_data->{context_window},
        max_prompt_tokens     => $model_data->{context_window},
        max_output_tokens     => $model_data->{max_output_tokens},
        supports_tools        => $model_data->{supports_tools},
        supports_streaming    => $model_data->{supports_streaming},
        supports_vision       => $model_data->{supports_vision},
        supports_reasoning    => $model_data->{supports_reasoning},
        embeddings_dimension  => undef,
        architecture          => 'nvidia',
        quantization          => undef,
        parameters            => undef,
        capabilities          => [],
        size_bytes            => undef,
        raw                   => $model_data,
    };
}

=head2 _nvidia_model_heuristics (Internal)

Pattern-based heuristics for NIM models not in the static map.
Infers capabilities from model ID naming conventions.

Arguments:
- $model: Model identifier (may or may not have nvidia/ prefix)

Returns:
- Hashref with capability data, or undef if no pattern matches

=cut

sub _nvidia_model_heuristics {
    my ($self, $model) = @_;
    
    # Strip nvidia/ prefix for pattern matching
    my $base = $model;
    $base =~ s{^nvidia/}{};
    $base =~ s{^nv-}{};
    
    # --- Model family patterns (ordered by specificity) ---
    
    # DeepSeek V4: 1M context, reasoning
    if ($base =~ m{deepseek.*v4}i) {
        return {
            context_window => 1048576, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        };
    }
    
    # DeepSeek V3.x: 128K context, reasoning
    if ($base =~ m{deepseek.*v3}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        };
    }
    
    # DeepSeek R1: 128K context, reasoning
    if ($base =~ m{deepseek.*r1}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        };
    }
    
    # Llama 4 Maverick: 1M context, vision
    if ($base =~ m{llama-?4.*maverick}i) {
        return {
            context_window => 1048576, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        };
    }
    
    # Llama 3.3: 128K context
    if ($base =~ m{llama-?3[._]3}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Llama 3.2 vision: 128K context, vision
    if ($base =~ m{llama-?3[._]2.*vision}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        };
    }
    
    # Llama 3.2 text: 128K context
    if ($base =~ m{llama-?3[._]2}i) {
        return {
            context_window => 131072, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Llama 3.1: 128K context
    if ($base =~ m{llama-?3[._]1}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Nemotron 3 Ultra/Super: 1M context, 32K output, reasoning
    # (Updated 2026-07-31 from 16K to 32K per docs.api.nvidia.com NIM
    # API reference - same source as the static map entries above.)
    if ($base =~ m{nemotron-?3.*(ultra|super)}i) {
        return {
            context_window => 1048576, max_output_tokens => 32768,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        };
    }
    
    # Nemotron 3 Nano: 256K context
    if ($base =~ m{nemotron-?3.*nano}i) {
        return {
            context_window => 262144, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Nemotron Nano VL: 128K context, vision
    if ($base =~ m{nemotron.*nano.*vl}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        };
    }
    
    # Nemotron Nano: 128K context
    if ($base =~ m{nemotron.*nano}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        };
    }
    
    # Nemotron 4: 128K context
    if ($base =~ m{nemotron-?4}i) {
        return {
            context_window => 131072, max_output_tokens => 8192,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Nemotron (generic): 128K context
    if ($base =~ m{nemotron}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Qwen 3.5: 256K context, reasoning
    if ($base =~ m{qwen.*3[._]5}i) {
        return {
            context_window => 262144, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 1,
        };
    }
    
    # Qwen 3: 256K context, reasoning
    if ($base =~ m{qwen.*3}i) {
        return {
            context_window => 262144, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        };
    }
    
    # Mistral Large: 128K context
    if ($base =~ m{mistral.*large}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Mistral Small/Medium: 128K context
    if ($base =~ m{mistral.*(small|medium)}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Mixtral 8x22B: 64K context
    if ($base =~ m{mixtral.*8x22}i) {
        return {
            context_window => 65536, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Mixtral 8x7B: 32K context
    if ($base =~ m{mixtral.*8x7}i) {
        return {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Mistral 7B: 32K context
    if ($base =~ m{mistral.*7b}i) {
        return {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Gemma 4: 256K context, vision
    if ($base =~ m{gemma-?4}i) {
        return {
            context_window => 262144, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        };
    }
    
    # Gemma 3/3n: 128K context, vision
    if ($base =~ m{gemma-?3}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        };
    }
    
    # Gemma 2: 8K context
    if ($base =~ m{gemma-?2}i) {
        return {
            context_window => 8192, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Phi-4: 128K context
    if ($base =~ m{phi-?4}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Phi-3: 128K context
    if ($base =~ m{phi-?3}i) {
        return {
            context_window => 131072, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Granite: 128K context
    if ($base =~ m{granite}i) {
        return {
            context_window => 131072, max_output_tokens => 8192,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # GLM-5: 200K context, reasoning
    if ($base =~ m{glm-?5}i) {
        return {
            context_window => 200000, max_output_tokens => 131072,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        };
    }
    
    # GLM-4.x: 128K context
    if ($base =~ m{glm-?4}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Kimi K2: 256K context, 32K output, reasoning, vision
    # quickstart docs, which state: "max_tokens - optional - ... -
    # Default to be 32k aka 32768". (K2.6 is the model covered by our
    # static map entry; the heuristic catches K2 family variants.)
    if ($base =~ m{kimi.*k2}i) {
        return {
            context_window => 262144, max_output_tokens => 32768,
            supports_tools => 1, supports_streaming => 1, supports_vision => 1, supports_reasoning => 1,
        };
    }
    
    # MiniMax M2: 1M context, reasoning
    if ($base =~ m{minimax.*m2}i) {
        return {
            context_window => 1048576, max_output_tokens => 131072,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 1,
        };
    }
    
    # Codestral: 32K context
    if ($base =~ m{codestral}i) {
        return {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # NVIDIA Cosmos (vision models): 128K context, vision
    if ($base =~ m{cosmos}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 0, supports_streaming => 1, supports_vision => 1, supports_reasoning => 0,
        };
    }
    
    # ChatQA: 128K context
    if ($base =~ m{chatqa}i) {
        return {
            context_window => 131072, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Mistral Nemo: 128K context
    if ($base =~ m{mistral.*nemo}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Ministral: 128K context
    if ($base =~ m{ministral}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # StepFun: 128K context
    if ($base =~ m{stepfun|step-}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Writer Palmyra: 128K context (except 32k variants)
    if ($base =~ m{palmyra.*32k}i) {
        return {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    if ($base =~ m{palmyra}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Seed/Bytedance: 128K context
    if ($base =~ m{seed-oss|bytedance}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Sarvam: 128K context
    if ($base =~ m{sarvam}i) {
        return {
            context_window => 131072, max_output_tokens => 16384,
            supports_tools => 1, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Yi: 32K context
    if ($base =~ m{/yi-}i) {
        return {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Solar/Upstage: 32K context
    if ($base =~ m{solar|upstage}i) {
        return {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # Stockmark: 32K context
    if ($base =~ m{stockmark}i) {
        return {
            context_window => 32768, max_output_tokens => 8192,
            supports_tools => 0, supports_streaming => 1, supports_vision => 0, supports_reasoning => 0,
        };
    }
    
    # No pattern matched - return undef to use system defaults
    return undef;
}

=head2 _find_model_in_list (Internal)

Locate a model entry in a list of model hashes returned by an external
API (e.g. /v1/models). Returns the matching hashref or undef.

The match handles the same normalization cases as _lookup_static_model:
exact, prefix-stripped, and case-insensitive. Server-returned model IDs
may be canonical mixed-case ("MiniMax-M3") or include an org prefix
("minimax/MiniMax-M3"); the caller's model may be lowercase without
prefix ("minimax-m3"). Any of these combinations should hit.

Arguments:
    $models   - Arrayref of model hashrefs (each must have an 'id' key,
                or a 'name' key for Google-style responses).
    $model    - Model identifier the caller is looking up.
    $id_field - Hash key to read from each model entry ('id' for
                OpenAI-compatible, 'name' for Google).

Returns: Matching model hashref, or undef if not found.

=cut

sub _find_model_in_list {
    my ($self, $models, $model, $id_field) = @_;
    $id_field //= 'id';

    return undef unless $models && ref($models) eq 'ARRAY' && $model;

    # First pass: exact match (after stripping Google-style "models/" prefix
    # from the server's name field if applicable). Fast path, no normalization.
    for my $m (@$models) {
        my $id = $m->{$id_field};
        next unless defined $id;
        $id =~ s{^models/}{} if $id_field eq 'name';
        return $m if $id eq $model;
    }

    # Second pass: case-insensitive match with optional org/ prefix strip.
    # Try the model as-is first, then with a leading org/ segment stripped
    # in case the server returned "minimax/MiniMax-M3" but the caller passed
    # "minimax-m3" (or vice versa). Both sides are stripped so either
    # direction works.
    for my $strip_prefix ('', 1) {
        my $lc_target = $strip_prefix
            ? lc((split m{/}, $model, 2)[1] // $model)
            : lc($model);
        for my $m (@$models) {
            my $id = $m->{$id_field};
            next unless defined $id;
            $id =~ s{^models/}{} if $id_field eq 'name';
            $id =~ s{^[^/]+/}{} if $strip_prefix;
            return $m if lc($id) eq $lc_target;
        }
    }

    # Third pass: basename match (path stripped, extension removed).
    # llama.cpp-compatible servers return the full filesystem path as
    # the model id (e.g. "/home/user/models/Qwen3-Q4.gguf"), but
    # _resolve_local_model strips path and .gguf before passing the name.
    # This pass bridges that gap.
    my $target_base = lc($model);
    $target_base =~ s{.*/}{};
    $target_base =~ s/\.[^.]+\z//;

    for my $m (@$models) {
        my $id = $m->{$id_field};
        next unless defined $id;
        $id =~ s{^models/}{} if $id_field eq 'name';

        my $id_base = lc($id);
        $id_base =~ s{.*/}{};
        $id_base =~ s/\.[^.]+\z//;
        return $m if $id_base eq $target_base;

        # Also try aliases
        if ($m->{aliases} && ref($m->{aliases}) eq 'ARRAY') {
            for my $alias (@{$m->{aliases}}) {
                next unless defined $alias;
                my $ab = lc($alias);
                $ab =~ s{.*/}{};
                $ab =~ s/\.[^.]+\z//;
                return $m if $ab eq $target_base;
            }
        }
    }

    return undef;
}

=head2 _lookup_static_model (Internal)

Case-insensitive lookup against a static capability map.

Handles the common miss cases for model id strings pulled from
providers: (1) the input may already include an org/ prefix that
the static map strips (e.g. "minimax/MiniMax-M3"), (2) casing may
differ because OpenRouter-style slugs are lowercase while some
providers advertise canonical mixed-case ids.

Arguments:
    $map_ref  - Hashref of model data keyed by canonical model id.
    $model    - Model identifier supplied by the caller.
    @prefixes - Zero or more org/ prefixes to strip on retry
                (e.g. "minimax", "minimaxai", "deepseek").

Returns:
    The matching hashref entry, or undef if no match is found.

=cut

sub _lookup_static_model {
    my ($self, $map_ref, $model, @prefixes) = @_;

    # Exact match first.
    my $model_data = $map_ref->{$model};

    # Strip any of the configured org/ prefixes and retry.
    if (!$model_data && @prefixes) {
        my $bare = $model;
        for my $prefix (@prefixes) {
            $bare =~ s{^\Q$prefix\E/}{};
            last if $bare ne $model;
        }
        $model_data = $map_ref->{$bare} if $bare ne $model;
    }

    # Final fallback: case-insensitive match (with prefix stripped).
    if (!$model_data) {
        my $bare = $model;
        for my $prefix (@prefixes) {
            $bare =~ s{^\Q$prefix\E/}{};
        }
        my $lc_target = lc($bare);
        for my $key (keys %$map_ref) {
            if (lc($key) eq $lc_target) {
                $model_data = $map_ref->{$key};
                last;
            }
        }
    }

    return $model_data;
}

=head2 _fetch_zai_capabilities

Fetch capabilities from Z.AI API.

Arguments:
- $model: Model identifier

Returns:
- Hashref with capability data

=cut

sub _fetch_zai_capabilities {
    my ($self, $provider, $model) = @_;
    
    # Z.AI models static capability map (derived from their API docs)
    # This could be extended to use their API endpoint if available
    my %zai_models = (
        # GLM-5 Series
        'glm-5.1' => {
            context_window => 200000,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 1,
            supports_reasoning => 1,
        },
        'glm-5' => {
            context_window => 200000,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 1,
            supports_reasoning => 1,
        },
        'glm-5-turbo' => {
            context_window => 200000,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 1,
            supports_reasoning => 1,
        },
        # GLM-4.7 Series
        'glm-4.7' => {
            context_window => 200000,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
        },
        'glm-4.7-flashx' => {
            context_window => 200000,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
        },
        'glm-4.7-flash' => {
            context_window => 200000,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
        },
        # Vision models
        'glm-5v-turbo' => {
            context_window => 200000,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 1,
            supports_reasoning => 1,
        },
        'glm-4.6v' => {
            context_window => 128000,
            max_output_tokens => 8192,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 1,
            supports_reasoning => 0,
        },
        # OCR
        'glm-ocr' => {
            context_window => 128000,
            max_output_tokens => 4096,
            supports_tools => 0,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 0,
        },
    );
    
    my $model_data = $self->_lookup_static_model(\%zai_models, $model, 'zai');
    return undef unless $model_data;

    return {
        provider              => 'zai',
        model                 => $model,
        context_window        => $model_data->{context_window},
        max_prompt_tokens     => $model_data->{context_window},
        max_output_tokens     => $model_data->{max_output_tokens},
        supports_tools        => $model_data->{supports_tools},
        supports_streaming    => $model_data->{supports_streaming},
        supports_vision       => $model_data->{supports_vision},
        supports_reasoning    => $model_data->{supports_reasoning},
        embeddings_dimension  => undef,
        architecture          => 'glm',
        quantization          => undef,
        parameters            => undef,
        capabilities          => [],
        size_bytes            => undef,
        raw                   => $model_data,
    };
}

=head2 _fetch_minimax_capabilities

Fetch capabilities from MiniMax API.

Arguments:
- $model: Model identifier

Returns:
- Hashref with capability data

=cut

sub _fetch_minimax_capabilities {
    my ($self, $provider, $model) = @_;
    
    # MiniMax models static capability map
    my %minimax_models = (
        'MiniMax-M3' => {
            context_window => 1000000,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 1,
            supports_reasoning => 1,
            supports_adaptive_thinking => 1,  # M3 uses adaptive thinking
        },
        'MiniMax-M2.7' => {
            context_window => 204800,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
            supports_enabled_thinking => 1,   # M2.x uses enabled thinking
        },
        'MiniMax-M2.7-highspeed' => {
            context_window => 204800,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
            supports_enabled_thinking => 1,
        },
        'MiniMax-M2.5' => {
            context_window => 204800,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
            supports_enabled_thinking => 1,
        },
        'MiniMax-M2.5-highspeed' => {
            context_window => 204800,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
            supports_enabled_thinking => 1,
        },
        'MiniMax-M2.1' => {
            context_window => 204800,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
            supports_enabled_thinking => 1,
        },
        'MiniMax-M2.1-highspeed' => {
            context_window => 204800,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
            supports_enabled_thinking => 1,
        },
        'MiniMax-M2' => {
            context_window => 204800,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
            supports_enabled_thinking => 1,
        },
    );
    
    my $model_data = $self->_lookup_static_model(\%minimax_models, $model, 'minimax', 'minimaxai');
    return undef unless $model_data;

    return {
        provider              => 'minimax',
        model                 => $model,
        context_window        => $model_data->{context_window},
        max_prompt_tokens     => $model_data->{context_window},
        max_output_tokens     => $model_data->{max_output_tokens},
        supports_tools        => $model_data->{supports_tools},
        supports_streaming    => $model_data->{supports_streaming},
        supports_vision       => $model_data->{supports_vision},
        supports_reasoning    => $model_data->{supports_reasoning},
        embeddings_dimension  => undef,
        architecture          => 'minimax',
        quantization          => undef,
        parameters            => undef,
        capabilities          => [],
        size_bytes            => undef,
        raw                   => $model_data,
    };
}

=head2 _fetch_deepseek_capabilities

Fetch capabilities for DeepSeek provider models using a static map.
DeepSeek's /v1/models endpoint returns only the model id with no metadata,
so we maintain a static capability map sourced from their API docs
(https://api-docs.deepseek.com/quick_start/pricing).

=cut

sub _fetch_deepseek_capabilities {
    my ($self, $provider, $model) = @_;

    # DeepSeek V4 series: 1M context, 32K max output (API allows up to 384K
    # but 32K is the practical sweet spot for typical agent loops). Both
    # Flash and Pro support thinking modes and tool calls.
    my %deepseek_models = (
        'deepseek-v4-flash' => {
            context_window => 1048576,
            max_output_tokens => 32768,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
        },
        'deepseek-v4-pro' => {
            context_window => 1048576,
            max_output_tokens => 32768,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
        },
    );

    my $model_data = $self->_lookup_static_model(\%deepseek_models, $model, 'deepseek');
    return undef unless $model_data;

    return {
        provider              => 'deepseek',
        model                 => $model,
        context_window        => $model_data->{context_window},
        max_prompt_tokens     => $model_data->{context_window},
        max_output_tokens     => $model_data->{max_output_tokens},
        supports_tools        => $model_data->{supports_tools},
        supports_streaming    => $model_data->{supports_streaming},
        supports_vision       => $model_data->{supports_vision},
        supports_reasoning    => $model_data->{supports_reasoning},
        embeddings_dimension  => undef,
        architecture          => 'deepseek',
        quantization          => undef,
        parameters            => undef,
        capabilities          => [],
        size_bytes            => undef,
        raw                   => $model_data,
    };
}


=head2 _fetch_llama_cpp_capabilities

Fetch capabilities for local inference models (llama.cpp, SAM, LM Studio)
by querying the server's /v1/models and /props endpoints.

The /v1/models response contains model metadata including C<meta.n_ctx>
(runtime context window from --ctx-size), C<meta.n_ctx_train> (training
context), C<meta.n_params>, and C<meta.size>. The /props endpoint
supplements this with C<modalities.vision>, C<chat_template_caps>
(tool support), and the definitive runtime C<n_ctx>.

Heuristics provide model-name-based metadata (C<supports_reasoning>,
C<max_output_tokens>) that neither endpoint reports.

Arguments:
- $provider: Provider name ('llama.cpp', 'sam', 'lmstudio')
- $model: Model identifier (resolved from sentinel if needed)

Returns:
- Hashref with capability data, or undef if the server is unavailable
  or the model is not found.

=cut

sub _fetch_llama_cpp_capabilities {
    my ($self, $provider, $model) = @_;
    $provider ||= 'llama.cpp';

    # Read api_base from config for this provider
    my $api_base;
    eval {
        require CLIO::Core::Config;
        my $config = CLIO::Core::Config->new();
        $api_base = $config->get_provider_base($provider);
    };
    return undef unless $api_base;

    my $http = $self->get_http();

    # Derive /v1/models URL from the api_base (same normalization as
    # _fetch_openai_compatible_capabilities: strip /chat/completions,
    # /chat, and trailing slashes before appending /models)
    my $models_url = $api_base;
    $models_url =~ s{/+$}{};
    $models_url =~ s{/chat/completions/?$}{};
    $models_url =~ s{/chat/?$}{};
    $models_url .= '/models';

    # Query /v1/models — primary data source for model metadata
    my $resp = $http->get($models_url);
    unless ($resp && $resp->{success}) {
        log_debug('ModelCapabilitiesManager', "${provider} /v1/models failed: " . ($resp ? ($resp->{status} // 'unknown') : 'no response'));
        return undef;
    }

    my $data = eval { decode_json($resp->{content}) };
    if ($@) {
        log_debug('ModelCapabilitiesManager', "Failed to parse ${provider} /v1/models: $@");
        return undef;
    }

    my $models = $data->{data} || $data->{models} || [];
    my $model_info = $self->_find_model_in_list($models, $model, 'id');

    # llama.cpp returns full filesystem paths as ids; match by basename
    # (path stripped, extension removed) so the resolved model name
    # (e.g. "Qwen3.6-35B-A3B-UD-Q4_K_XL") matches the server's id
    # (e.g. "/home/deck/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf").
    unless ($model_info) {
        $model_info = $self->_find_local_model_by_basename($models, $model);
    }

    unless ($model_info) {
        log_debug('ModelCapabilitiesManager', "Model $model not found in ${provider} /v1/models response");
        # Fall back to /props-only lookup for context window
        my $props_data = $self->_query_llama_props_data($api_base);
        if ($props_data) {
            my $props_ctx = $props_data->{default_generation_settings}{n_ctx}
                         || $props_data->{n_ctx};
            if ($props_ctx && $props_ctx > 0) {
                require CLIO::Core::Defaults;
                my $heuristic = $self->_model_data_loader()->match_heuristics($model);
                return {
                    provider              => $provider,
                    model                 => $model,
                    context_window        => $props_ctx,
                    max_prompt_tokens     => $props_ctx,
                    max_output_tokens     => $heuristic ? $heuristic->{max_output_tokens} : CLIO::Core::Defaults::DEFAULT_MAX_OUTPUT_TOKENS(),
                    supports_tools        => $props_data->{chat_template_caps} && $props_data->{chat_template_caps}{supports_tools} ? 1 : 1,
                    supports_streaming    => 1,
                    supports_vision       => ($props_data->{modalities} && $props_data->{modalities}{vision}) ? 1 : 0,
                    supports_reasoning    => $heuristic ? $heuristic->{supports_reasoning} : 0,
                    embeddings_dimension  => undef,
                    architecture          => 'llama',
                    quantization          => $props_data->{model_ftype},
                    parameters            => undef,
                    capabilities          => [],
                    size_bytes            => undef,
                    raw                   => { source => 'props', props => $props_data },
                };
            }
        }
        return undef;
    }

    # Extract metadata from /v1/models meta object
    # meta.n_ctx = runtime context window (--ctx-size at startup)
    # meta.n_ctx_train = model's training context window
    # meta.n_params = parameter count
    # meta.size = model file size
    # meta.n_vocab = vocabulary size
    my $meta = ref($model_info->{meta}) eq 'HASH' ? $model_info->{meta} : {};
    my $context_window = $meta->{n_ctx} || $meta->{n_ctx_train};

    # Query /props for runtime n_ctx override, modalities, chat_template_caps
    my $props_data = $self->_query_llama_props_data($api_base);
    if ($props_data) {
        # /props default_generation_settings.n_ctx = runtime n_ctx (--ctx-size)
        # This is the authoritative runtime value; use it to override the
        # /v1/models meta value which may reflect the model's training context
        my $props_ctx = $props_data->{default_generation_settings}{n_ctx}
                     || $props_data->{n_ctx};
        if ($props_ctx && $props_ctx > 0) {
            $context_window = $props_ctx;
        }
    }

    require CLIO::Core::Defaults;
    my $caps = {
        provider              => $provider,
        model                 => $model,
        context_window        => $context_window,
        max_prompt_tokens     => $context_window,
        max_output_tokens     => undef,  # Set from heuristics below
        supports_tools        => undef,  # Set from /props or heuristics
        supports_streaming    => 1,
        supports_vision       => undef,  # Set from /props or heuristics
        supports_reasoning    => undef,  # Set from heuristics below
        embeddings_dimension  => $meta->{n_vocab},
        architecture          => 'llama',
        quantization          => undef,
        parameters            => $meta->{n_params},
        capabilities          => [],
        size_bytes            => $meta->{size},
        raw                   => { model_info => $model_info, props => $props_data // {} },
    };

    # Enrich with /props data
    if ($props_data) {
        # /props modalities.vision -> supports_vision
        if (ref($props_data->{modalities}) eq 'HASH') {
            $caps->{supports_vision} = $props_data->{modalities}{vision} ? 1 : 0;
        }

        # /props chat_template_caps -> tool support
        if (ref($props_data->{chat_template_caps}) eq 'HASH') {
            my $ctc = $props_data->{chat_template_caps};
            $caps->{supports_tools} = $ctc->{supports_tools} if defined $ctc->{supports_tools};
        }

        # /props model_ftype -> quantization string
        $caps->{quantization} = $props_data->{model_ftype} if $props_data->{model_ftype};
    }

    # Use heuristics for fields the API doesn't report.
    # supports_reasoning and max_output_tokens are model-family properties
    # that /v1/models and /props don't expose explicitly. The //= operator
    # ensures /props values (authoritative for the running server) are
    # never overridden by heuristics — heuristics only fill gaps.
    my $heuristic = $self->_model_data_loader()->match_heuristics($model);
    if ($heuristic) {
        $caps->{max_output_tokens}   //= $heuristic->{max_output_tokens};
        $caps->{supports_reasoning}  //= $heuristic->{supports_reasoning};
        $caps->{supports_tools}      //= $heuristic->{supports_tools};
        $caps->{supports_vision}     //= $heuristic->{supports_vision};
    }

    # Final defaults for any remaining undef fields
    $caps->{max_output_tokens}   //= CLIO::Core::Defaults::DEFAULT_MAX_OUTPUT_TOKENS();
    $caps->{supports_tools}      //= 1;   # Modern llama.cpp supports tools by default
    $caps->{supports_reasoning}  //= 0;
    $caps->{supports_vision}     //= 0;

    log_debug('ModelCapabilitiesManager', "${provider} capabilities for $model: ctx=" . ($context_window // 'undef') . ", tools=$caps->{supports_tools}, vision=$caps->{supports_vision}, reasoning=$caps->{supports_reasoning}, output=$caps->{max_output_tokens}");

    return $caps;
}

=head2 _find_local_model_by_basename (Internal)

Find a model in a /v1/models response by matching basename (path stripped,
file extension removed). llama.cpp returns the full filesystem path as the
model id (e.g. "/home/user/models/Qwen3-Q4_K_M.gguf"), but
_resolve_local_model strips the path and .gguf extension before passing
the name to MCM. This bridges the two representations.

Arguments:
- $models: ArrayRef of model info hashes from /v1/models
- $model: Model name to match (basename, no path, no extension)

Returns:
- Matching model info hashref, or undef

=cut

sub _find_local_model_by_basename {
    my ($self, $models, $model) = @_;

    return undef unless $models && ref($models) eq 'ARRAY' && $model;

    my $target = lc($model);
    $target =~ s{.*/}{};       # Strip any path
    $target =~ s/\.(gguf|gge|bin|safetensors|pt|gguf)$//i;  # Strip model file extensions only

    for my $m (@$models) {
        my $id = $m->{id};
        next unless defined $id;

        my $basename = lc($id);
        $basename =~ s{.*/}{};
        $basename =~ s/\.(gguf|gge|bin|safetensors|pt)$//i;  # Strip model file extensions only

        return $m if $basename eq $target;

        # Also try aliases
        if ($m->{aliases} && ref($m->{aliases}) eq 'ARRAY') {
            for my $alias (@{$m->{aliases}}) {
                next unless defined $alias;
                my $ab = lc($alias);
                $ab =~ s{.*/}{};
                $ab =~ s/\.(gguf|gge|bin|safetensors|pt)$//i;  # Strip model file extensions only
                return $m if $ab eq $target;
            }
        }
    }

    return undef;
}
=head2 _fetch_openai_compatible_capabilities

Fetch capabilities from OpenAI-compatible APIs.

Arguments:
- $provider: Provider name
- $model: Model identifier

Returns:
- Hashref with capability data

=cut

sub _fetch_openai_compatible_capabilities {
    my ($self, $provider, $model) = @_;

    require CLIO::Providers;
    my $provider_def = CLIO::Providers::get_provider($provider);
    return undef unless $provider_def;

    # Read the user's configured api_base if any. Most local providers
    # (llama.cpp, LM Studio, SAM) and most OpenAI-compatible providers
    # have the user override api_base to point at a LAN IP, a non-default
    # port, or a proxy. MCM must honor that override; otherwise the call
    # goes to the provider's default host which the user is not actually
    # using, and returns stale data or fails silently.
    my $user_api_base;
    eval {
        require CLIO::Core::Config;
        my $config = CLIO::Core::Config->new();
        $user_api_base = $config->get_provider_base($provider);
    };

    # Use the user's override when present, otherwise fall back to the
    # provider's default. Either way, derive the models URL correctly:
    # most openai-compatible providers expose the chat endpoint at
    # /v1/chat/completions and the models endpoint at /v1/models. The
    # previous code appended /models to the full chat URL, producing
    # an invalid path like /v1/chat/completions/models.
    my $raw_api_base = $user_api_base || $provider_def->{api_base};
    my $api_base = $raw_api_base;
    $api_base =~ s{/+$}{};
    $api_base =~ s{/chat/completions/?$}{};
    $api_base =~ s{/chat/?$}{};
    my $api_type = $provider;  # Used for /props gating via CLIO::Providers::is_local_inference

    # Get API key
    my $api_key;
    eval {
        require CLIO::Core::Config;
        my $config = CLIO::Core::Config->new();
        $api_key = $config->get_provider_key($provider);
    };

    return undef unless $api_key;

    my $http = $self->get_http();
    my $models_url = "$api_base/models";
    log_debug('ModelCapabilitiesManager', "OpenAI-compatible MCM ($provider) using models_url=$models_url") if $user_api_base;
    
    my $resp = $http->get($models_url, 
        headers => { 
            'Authorization' => "Bearer $api_key",
            'Accept' => 'application/json',
        }
    );
    
    unless ($resp->{success}) {
        log_debug('ModelCapabilitiesManager', "${provider} models API failed: HTTP " . $resp->{status});
        return undef;
    }
    
    my $data;
    eval {
        $data = decode_json($resp->{content});
    };
    if ($@) {
        log_debug('ModelCapabilitiesManager', "Failed to parse ${provider} response: $@");
        return undef;
    }
    
    # Find the specific model. Use _find_model_in_list so case-insensitive
    # and prefix-stripped matches work (server may return canonical mixed-case
    # ids like "MiniMax-M3" while caller passes lowercase "minimax-m3").
    my $models = $data->{data} || $data->{models} || [];
    my $m = $self->_find_model_in_list($models, $model, 'id');
    if ($m) {
        my $permuted_model = $m->{permuted_model} || undef;
        
        # Extract context window. Different providers use different field
        # names: OpenAI uses max_tokens/context_window, Google uses
        # inputTokenLimit, OpenRouter uses context_length (top-level) and
        # also nests it inside top_provider for per-endpoint limits.
        # llama.cpp-compatible servers include n_ctx/n_ctx_train in a
        # meta sub-object (runtime vs training context).
        my $tp = ref($m->{top_provider}) eq 'HASH' ? $m->{top_provider} : {};
        my $meta = ref($m->{meta}) eq 'HASH' ? $m->{meta} : {};
        my $context_window = $m->{context_length}
            || $m->{context_window}
            || $m->{max_tokens}
            || $m->{max_context_tokens}
            || $meta->{n_ctx}          # llama.cpp runtime context (--ctx-size)
            || $meta->{n_ctx_train}     # llama.cpp training context
            || $tp->{context_length}
            || $tp->{context_window}
            || undef;
        
        # OpenAI-compatible often provides max_tokens as total context
        if (!$context_window && $permuted_model && $permuted_model->{context_window}) {
            $context_window = $permuted_model->{context_window};
        }
        # Also check permuted_model's top_provider
        if (!$context_window && $permuted_model && ref($permuted_model->{top_provider}) eq 'HASH') {
            $context_window = $permuted_model->{top_provider}{context_length}
                || $permuted_model->{top_provider}{context_window};
        }
        
        # For local inference servers, /v1/models only exposes the model's
        # training context (n_ctx_train), not the server's actual
        # runtime --ctx-size value. Query /props to get the real n_ctx.
        # Gating logic centralised through CLIO::Providers:
        #   - exposes_props() covers the named local providers
        #     (sam, llama.cpp, lmstudio) that declare this in the registry.
        #   - ai_type eq 'generic' catches unrecognised OpenAI-compatible
        #     servers we autodetected through provider_from_url. These
        #     may be local llama.cpp forks that match the same /props
        #     convention. /props query is best-effort: returns undef on
        #     404 without blocking the fetch.
        require CLIO::Providers;
        my $is_local = CLIO::Providers::is_local_inference($api_type);
        my $props_data;
        if (!$context_window || $is_local || $api_type eq 'generic') {
            $props_data = $self->_query_llama_props_data($api_base);
            if ($props_data) {
                my $props_ctx = $props_data->{default_generation_settings}{n_ctx}
                             || $props_data->{n_ctx};
                if ($props_ctx && $props_ctx > 0) {
                    $context_window = $props_ctx;
                    log_debug('ModelCapabilitiesManager', "llama.cpp /props n_ctx=$props_ctx for $model (overriding training context)");
                }
            }
        }
        
        # Get max completion tokens. Check top-level first, then
        # top_provider (where OpenRouter nests per-endpoint limits).
        my $output_tokens = $m->{max_completion_tokens}
            || $m->{max_output_tokens}
            || $tp->{max_completion_tokens}
            || $tp->{max_output_tokens}
            || ($permuted_model ? ($permuted_model->{max_output_tokens}) : undef)
            || undef;

        # Parse reasoning metadata (OpenRouter returns a 'reasoning' field)
        my $reasoning_mode;
        my $supports_reasoning_flag = 0;
        my $reasoning_mandatory = 0;
        if ($m->{reasoning} && ref($m->{reasoning}) eq 'HASH') {
            my $r = $m->{reasoning};
            # The presence of a reasoning field means the model supports
            # reasoning. OpenRouter returns this even when supported_efforts
            # is absent — in that case we infer 'effort' mode from the
            # reasoning parameter being accepted (see supported_parameters).
            $supports_reasoning_flag = 1;
            $reasoning_mandatory = $r->{mandatory} || 0;
            # Determine mode from supported_efforts if available.
            # OpenRouter uses 'reasoning.effort' parameter -> 'effort' mode.
            $reasoning_mode = 'effort' if $r->{supported_efforts};
        }
        
        # Enrich with /props data for local inference servers
        my $supports_vision = $m->{vision} || $m->{supports_vision} || 0;
        my $supports_tools = $m->{supports_tools} || $m->{function_call} || 0;
        # OpenRouter and other OpenAI-compatible APIs signal function-calling
        # support via a supported_parameters array (e.g. ["function_calls"])
        # rather than a supports_tools boolean field. Check it as a fallback.
        if (!$supports_tools && $m->{supported_parameters} && ref($m->{supported_parameters}) eq 'ARRAY') {
            for my $p (@{$m->{supported_parameters}}) {
                if (defined $p && (lc($p) eq 'function_calls' || lc($p) eq 'tools' || lc($p) eq 'function_call')) {
                    $supports_tools = 1;
                    last;
                }
            }
        }
        my $quantization = $m->{quantization};

        if ($props_data) {
            # /props modalities.vision -> supports_vision (authoritative for running server)
            if (ref($props_data->{modalities}) eq 'HASH') {
                $supports_vision = $props_data->{modalities}{vision} ? 1 : 0;
            }

            # /props chat_template_caps -> tool support
            if (ref($props_data->{chat_template_caps}) eq 'HASH') {
                my $ctc = $props_data->{chat_template_caps};
                $supports_tools = $ctc->{supports_tools} if defined $ctc->{supports_tools};
            }

            # /props model_ftype -> quantization
            $quantization //= $props_data->{model_ftype} if $props_data->{model_ftype};
        }
        
        return {
            provider              => $provider,
            model                 => $model,
            context_window        => $context_window,
            max_prompt_tokens     => $context_window,  # Approximation
            max_output_tokens     => $output_tokens,
            supports_tools        => $supports_tools,
            supports_streaming    => 1,  # Most OpenAI-compatible support streaming
            supports_vision       => $supports_vision,
            supports_reasoning    => $supports_reasoning_flag,
            reasoning_mode        => $reasoning_mode,
            embeddings_dimension  => undef,
            architecture          => undef,
            quantization          => $quantization,
            parameters           => $m->{parameters} || $m->{parameter_count} || undef,
            capabilities         => [],
            size_bytes           => undef,
            raw                  => $m,
        };
    }
    
    return undef;
}

=head2 _ensure_reasoning_mode($capabilities, $provider, $model)

Post-process capability hash to fill in reasoning_mode when not already
set. Called after fetching capabilities from any source.

Resolution order (first match wins):
1. Already-set value (returned untouched)
2. Anthropic API data: supports_adaptive_thinking / supports_enabled_thinking
   fields set by _fetch_anthropic_capabilities from /v1/models/{id}
3. Static map data: reasoning_mode field set directly in the map
4. Provider+model name heuristic (fallback for proxies that strip
   capabilities from /v1/models, or for static maps that predate the
   reasoning_mode field)

=cut

sub _ensure_reasoning_mode {
    my ($self, $capabilities, $provider, $model) = @_;

    # Already set (and defined) - keep it. NB: exists() is intentionally
    # NOT used here because _build_caps_from_json may set
    # reasoning_mode => undef when the source data lacks the field.
    # exists() returns true for a key with an undef value, which would
    # short-circuit the heuristic fallback below and leave
    # reasoning_mode as undef for models that DO support reasoning
    # (e.g. NVIDIA nemotron-3-ultra-550b-a55b matched via heuristics
    # that set reasoning_mode, but the JSON caps hash had the key
    # pre-set to undef by _build_caps_from_json).
    return if defined $capabilities->{reasoning_mode};

    # Not a reasoning model - nothing to set
    return unless $capabilities->{supports_reasoning};

    # Data-driven path 1: Anthropic /v1/models response explicitly tells
    # us which thinking types are supported. Prefer adaptive (newer
    # API) over enabled (older API) when both are available. This is
    # the only authoritative source for the exact Anthropic model
    # behavior, since the heuristic below cannot enumerate every
    # future minor version.
    if ($capabilities->{supports_adaptive_thinking}) {
        $capabilities->{reasoning_mode} = 'adaptive';
        return;
    }
    if ($capabilities->{supports_enabled_thinking}) {
        $capabilities->{reasoning_mode} = 'enabled';
        return;
    }

    # Data-driven path 2: static maps may set reasoning_mode directly.
    # (This branch is for future use; current maps only set
    # supports_reasoning. Kept here so static maps have an explicit
    # way to override the heuristic when needed.)

    # Model-name-based fallback: Anthropic-family model names get
    # Anthropic reasoning rules regardless of provider name. Custom
    # Anthropic-compatible proxies may register under a non-anthropic
    # provider name, but the model name pattern is unique to Anthropic.
    # This covers proxy aliases (e.g. "Proxy-Sonnet-5") and 5-series
    # models that the older provider-gated regex would have missed.
    #
    # Source-of-truth dispatch: each provider sets a
    # `default_reasoning_mode` in CLIO::Providers. Anthropic gets
    # 'adaptive' (most 5+ models), Gemini and Z.AI get 'enabled',
    # DeepSeek gets 'effort'. MiniMax is the notable exception: the
    # M3-vs-M2.x split is a model-name property, not a single value,
    # so it lives in the MiniMax branch below.
    require CLIO::Providers;
    my $mode;
    my $provider_default;

    if (my $family_mode = $self->_anthropic_model_reasoning_mode($model)) {
        $mode = $family_mode;
    }
    elsif ($provider_default = CLIO::Providers::default_reasoning_mode($provider)) {
        $mode = $provider_default;
    }
    # MiniMax: M3 uses adaptive, M2.x uses enabled. Specific model
    # names (M3+, future M4 etc.) should ideally set
    # supports_adaptive_thinking or reasoning_mode directly in the
    # static map rather than relying on this fallback. The provider
    # identity is matched against the registry's display name rather
    # than a hardcoded regex - the registry is the source of truth
    # for "this provider is MiniMax".
    elsif (CLIO::Providers::provider_exists($provider)) {
        my $pdef = CLIO::Providers::get_provider($provider);
        if (($pdef->{name} // '') =~ /MiniMax/i) {
            if ($model =~ /-?M3(\b|-)/i || $model =~ /M3(?:\.|$)/i) {
                $mode = 'adaptive';
            }
            else {
                $mode = 'enabled';
            }
        }
    }
    # DeepSeek, OpenAI, Copilot, NVIDIA, OpenRouter, plus any provider
    # with no registry-declared default: effort-based reasoning_effort.
    if (!$mode) {
        $mode = 'effort';
    }

    $capabilities->{reasoning_mode} = $mode if $mode;
}

=head2 _format_tokens

Format token count for human-readable output.

Arguments:
- $tokens: Token count (integer)

Returns:
- Formatted string (e.g., "128k", "200k", "1M")

=cut

sub _format_tokens {
    my ($self, $tokens) = @_;
    
    return 'N/A' unless defined $tokens && $tokens =~ /^\d+$/;
    
    if ($tokens >= 1_000_000) {
        return sprintf("%.1fM", $tokens / 1_000_000);
    }
    elsif ($tokens >= 1_000) {
        return sprintf("%.0fk", $tokens / 1_000);
    }
    else {
        return "$tokens";
    }
}

=head2 _query_llama_props

Query the llama.cpp /props endpoint to retrieve the actual running context window size.

Returns the integer n_ctx value on success, or undef if the endpoint is unavailable
or the response does not contain context information. This is used to supplement
the /v1/models response which only exposes n_ctx_train (training context), not the
server's runtime --ctx-size value.

Called for any OpenAI-compatible server with a /props endpoint. In practice this
means local inference servers (llama.cpp, LM Studio, SAM), but the host may be
localhost, a LAN hostname, or an IP address - the function does not filter by URL.

=cut

sub _query_llama_props_data {
    my ($self, $api_base) = @_;

    # Derive the /props URL from the api_base using _origin_from_url,
    # which correctly extracts scheme://host[:port] regardless of the
    # path component. The /props endpoint is always at the server root.
    my $origin = $self->_origin_from_url($api_base);
    return undef unless $origin;
    my $props_url = "${origin}/props";

    my $http = $self->get_http();
    my $resp = eval { $http->get($props_url) };
    if ($@ || !$resp || !$resp->{success}) {
        log_debug('ModelCapabilitiesManager', "llama.cpp /props not available at $props_url");
        return undef;
    }

    my $data = safe_decode_json($resp->{content});
    if ($@) {
        log_debug('ModelCapabilitiesManager', "llama.cpp /props parse error: $@");
        return undef;
    }

    return $data;
}

=head2 _query_llama_props

Query the llama.cpp /props endpoint to retrieve the actual running context window size.
Returns the integer n_ctx value on success, or undef if unavailable.

=cut

sub _query_llama_props {
    my ($self, $api_base) = @_;
    my $data = $self->_query_llama_props_data($api_base);
    return undef unless $data;

    # /props exposes: default_generation_settings.n_ctx (runtime context window)
    # This reflects the --ctx-size / -c value passed at server startup, not the
    # model's training context (n_ctx_train) which is what /v1/models exposes.
    my $n_ctx = $data->{default_generation_settings}{n_ctx}
             || $data->{n_ctx};   # some older versions may expose it at top level

    return $n_ctx if $n_ctx && $n_ctx > 0;
    return undef;
}

=head2 _origin_from_url (Internal)

Extract just the origin (protocol + host + port) from a URL, dropping
the path and any query string or fragment.

Handles the URL shapes that appear in CLIO's provider configurations:
- IPv4 host: http://192.168.1.50:8080/v1 -> http://192.168.1.50:8080
- IPv6 host: http://[::1]:8080/v1        -> http://[::1]:8080
- Hostname:  http://max.local:9090/v1     -> http://max.local:9090
- Bare host: https://api.example.com      -> https://api.example.com
- userinfo:  http://user:pass@host:8080/  -> http://user:pass@host:8080

Returns the origin string, or undef if the input isn't a recognizable URL.

=cut

sub _origin_from_url {
    my ($self, $url) = @_;
    return undef unless defined $url && length $url;

    # Match scheme://[userinfo@]host[:port] where host may be a name,
    # IPv4 address, or bracketed IPv6 address. We intentionally stop at
    # the first '/' (start of path), '?' (start of query), or '#' (start
    # of fragment).
    if ($url =~ m{^([a-z][a-z0-9+.\-]*://[^/?#]+)}i) {
        return $1;
    }

    # No scheme we recognized. /props URL derivation requires a URL
    # with a scheme, so return undef. The caller will log a debug
    # line and fall back to the next source of context_window.
    return undef;
}

=head2 _get_llama_cpp_props_ctx (Internal)

Query the llama.cpp /props endpoint to retrieve the actual running
context window size (n_ctx). Reads the user's configured api_base for
the llama.cpp provider from CLIO config.

Returns the integer n_ctx value on success, or undef if unavailable.

=cut

sub _get_llama_cpp_props_ctx {
    my ($self, $provider) = @_;
    $provider ||= 'llama.cpp';

    my $api_base;
    eval {
        require CLIO::Core::Config;
        my $config = CLIO::Core::Config->new();
        $api_base = $config->get_provider_base($provider);
    };
    return undef unless $api_base;

    return $self->_query_llama_props($api_base);
}

=head2 _query_llama_props_for_provider (Internal)

Query the /props endpoint for a local inference provider (llama.cpp, SAM, LM Studio).
Reads the user's configured api_base for the given provider from CLIO config.

Arguments:
- $provider: Provider name ('llama.cpp', 'sam', or 'lmstudio')

Returns the integer n_ctx value on success, or undef if unavailable.

=cut

sub _query_llama_props_for_provider {
    my ($self, $provider) = @_;
    
    my $api_base;
    eval {
        require CLIO::Core::Config;
        my $config = CLIO::Core::Config->new();
        $api_base = $config->get_provider_base($provider);
    };
    return undef unless $api_base;

    return $self->_query_llama_props($api_base);
}

1;

=head1 SEE ALSO

L<CLIO::Core::GitHubCopilotModelsAPI>, L<CLIO::Core::APIManager>

=cut

1;
