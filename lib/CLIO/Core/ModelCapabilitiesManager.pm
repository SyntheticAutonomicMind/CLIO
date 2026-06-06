# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::ModelCapabilitiesManager;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_debug log_info log_warning log_error);
use CLIO::Util::ConfigPath qw(get_config_file);
use CLIO::Util::JSON qw(encode_json decode_json);
use CLIO::Compat::HTTP;
use Fcntl qw(LOCK_EX LOCK_UN LOCK_NB);

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
        debug      => $args{debug} || 0,
        cache_file => $args{cache_file} || $cache_file,
        cache_ttl  => $args{cache_ttl} || 3600,
        cache      => undef,  # Lazily loaded
        http       => undef,  # Lazily created
    };
    
    bless $self, $class;
    return $self;
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
    
    # Check cache first
    my $cache_key = "${provider}:${model}";
    if (my $cached = $self->_get_cached($cache_key)) {
        log_debug('ModelCapabilitiesManager', "Cache hit for $cache_key");
        return $cached;
    }
    
    log_debug('ModelCapabilitiesManager', "Cache miss for $cache_key, fetching");
    
    # Fetch from provider
    my $capabilities = $self->_fetch_provider_capabilities($provider, $model);
    
    if ($capabilities) {
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
    
    my $cache_key = "${provider}:${model}";
    my $capabilities = $self->_fetch_provider_capabilities($provider, $model);
    
    if ($capabilities) {
        $self->_set_cached($cache_key, $capabilities);
    }
    
    return $capabilities;
}

=head2 clear_cache

Clear all cached capabilities.

=cut

sub clear_cache {
    my ($self) = @_;
    
    $self->{cache} = {};
    
    if (-f $self->{cache_file}) {
        unlink $self->{cache_file} or log_warning('ModelCapabilitiesManager', "Failed to clear cache: $!");
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
                $self->{cache} = decode_json($data) if $data;
            }
        };
        if ($@) {
            log_warning('ModelCapabilitiesManager', "Failed to load cache: $@");
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
        print $fh encode_json($self->{cache});
        close $fh;
        
        rename($temp, $self->{cache_file}) or die "Cannot rename cache: $!";
    };
    
    if ($@) {
        log_warning('ModelCapabilitiesManager', "Failed to save cache: $@");
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
    
    require CLIO::Providers;
    my $provider_def = CLIO::Providers::get_provider($provider);
    
    if ($provider_def->{copilot_models}) {
        return $self->_fetch_github_copilot_capabilities($model);
    }
    elsif ($provider_def->{native_api}) {
        # Route native_api providers to their specific fetchers
        return $self->_fetch_anthropic_capabilities($model) if $provider =~ /^anthropic$/i;
        return $self->_fetch_google_capabilities($model) if $provider =~ /^google$/i;
        return $self->_fetch_nvidia_capabilities($model) if $provider =~ /^nvidia$/i;
    }
    elsif ($provider_def->{capability_map}) {
        return $self->_fetch_zai_capabilities($model) if $provider =~ /^zai/;
        return $self->_fetch_minimax_capabilities($model) if $provider =~ /^minimax/;
    }
    elsif ($provider_def->{requires_auth} && $provider_def->{requires_auth} eq 'apikey') {
        return $self->_fetch_openai_compatible_capabilities($provider, $model);
    }
    
    log_warning('ModelCapabilitiesManager', "No capability fetcher for provider: $provider");
    return undef;
}

=head2 _fetch_github_copilot_capabilities

Fetch capabilities from GitHub Copilot /models API.

Arguments:
- $model: Model identifier

Returns:
- Hashref with capability data

=cut

sub _fetch_github_copilot_capabilities {
    my ($self, $model) = @_;
    
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
        log_warning('ModelCapabilitiesManager', "Failed to fetch GitHub Copilot capabilities: $@");
    }
    
    return $caps;
}

=head2 _fetch_anthropic_capabilities

Fetch capabilities from Anthropic API.

Arguments:
- $model: Model identifier (e.g. 'claude-sonnet-4-20250514')

Returns:
- Hashref with capability data

=cut

sub _fetch_anthropic_capabilities {
    my ($self, $model) = @_;
    
    # Anthropic /v1/models/{model_id} endpoint
    # Response format (from Anthropic SDK):
    #   { id, display_name, created_at, type: "model",
    #     max_input_tokens, max_tokens,
    #     capabilities: { thinking: { supported, types: { adaptive, enabled } },
    #                     effort: { supported, ... },
    #                     image_input: { supported }, ... } }
    my $api_base = 'https://api.anthropic.com/v1/models';
    
    # Get API key for Anthropic
    my $api_key;
    eval {
        require CLIO::Core::Config;
        my $config = CLIO::Core::Config->new();
        $api_key = $config->get_provider_key('anthropic');
    };
    
    return undef unless $api_key;
    
    my $http = $self->get_http();
    my $url = "$api_base/$model";
    
    my $resp = $http->get($url, headers => {
        'x-api-key' => $api_key,
        'anthropic-version' => '2023-06-01',
        'Accept' => 'application/json',
    });
    
    unless ($resp->{success}) {
        log_debug('ModelCapabilitiesManager', "Anthropic models API failed for $model: HTTP $resp->{status}");
        return undef;
    }
    
    my $data;
    eval {
        $data = decode_json($resp->{content});
    };
    if ($@) {
        log_debug('ModelCapabilitiesManager', "Failed to parse Anthropic response: $@");
        return undef;
    }
    
    return undef unless $data && $data->{id};
    
    # Extract capabilities from the API response
    my $caps = $data->{capabilities} || {};
    my $thinking = $caps->{thinking} || {};
    my $effort = $caps->{effort} || {};
    my $image_input = $caps->{image_input} || {};
    
    # max_tokens from the API is the maximum value for the max_tokens parameter
    # (i.e., max output tokens). max_input_tokens is the context window.
    my $max_output = $data->{max_tokens};
    my $context_window = $data->{max_input_tokens};
    
    # Fallback to provider-level defaults if API doesn't provide specifics
    require CLIO::Providers;
    my $pdef = CLIO::Providers::get_provider('anthropic');
    $max_output //= $pdef->{max_output_tokens} if $pdef;
    $context_window //= $pdef->{max_context_tokens} if $pdef;
    
    return {
        provider              => 'anthropic',
        model                 => $data->{id} // $model,
        context_window        => $context_window,
        max_prompt_tokens     => $context_window,
        max_output_tokens     => $max_output,
        supports_tools        => 1,  # All Claude models support tools
        supports_streaming    => 1,
        supports_vision       => ($image_input->{supported} ? 1 : 0),
        supports_reasoning    => ($thinking->{supported} ? 1 : 0),
        supports_adaptive_thinking => ($thinking->{types} && $thinking->{types}{adaptive} && $thinking->{types}{adaptive}{supported} ? 1 : 0),
        supports_enabled_thinking  => ($thinking->{types} && $thinking->{types}{enabled} && $thinking->{types}{enabled}{supported} ? 1 : 0),
        embeddings_dimension  => undef,
        architecture          => 'claude',
        quantization          => undef,
        parameters            => undef,
        capabilities          => [],
        size_bytes            => undef,
        raw                   => $data,
    };
}

=head2 _fetch_google_capabilities

Fetch capabilities from Google Gemini API.

Arguments:
- $model: Model identifier

Returns:
- Hashref with capability data

=cut

sub _fetch_google_capabilities {
    my ($self, $model) = @_;
    
    my $api_base = 'https://generativelanguage.googleapis.com/v1beta';
    
    # Get API key for Google
    my $api_key;
    eval {
        require CLIO::Core::Config;
        my $config = CLIO::Core::Config->new();
        $api_key = $config->get_provider_key('google');
    };
    
    return undef unless $api_key;
    
    my $http = $self->get_http();
    my $models_url = "$api_base/models?key=$api_key";
    
    my $resp = $http->get($models_url, headers => { 'Accept' => 'application/json' });
    
    unless ($resp->{success}) {
        log_warning('ModelCapabilitiesManager', "Google models API failed: HTTP " . $resp->{status});
        return undef;
    }
    
    my $data;
    eval {
        $data = decode_json($resp->{content});
    };
    if ($@) {
        log_warning('ModelCapabilitiesManager', "Failed to parse Google response: $@");
        return undef;
    }
    
    # Find the specific model
    for my $m (@{$data->{models} || []}) {
        my $model_id = $m->{name};
        $model_id =~ s{^models/}{};
        
        next unless $model_id eq $model;
        
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
    my ($self, $model) = @_;
    
    # NVIDIA NIM models static capability map
    # Based on NVIDIA NIM API documentation and known models
    my %nvidia_models = (
        'nemotron-3-ultra-550b-a55b' => {
            context_window => 128000,
            max_output_tokens => 8192,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 0,
        },
        'nemotron-3-ultra' => {
            context_window => 128000,
            max_output_tokens => 8192,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 0,
        },
        'nemotron-3-8b' => {
            context_window => 128000,
            max_output_tokens => 8192,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 0,
        },
        'nemotron-4-340b' => {
            context_window => 128000,
            max_output_tokens => 8192,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 0,
        },
        'llama-3.1-405b' => {
            context_window => 128000,
            max_output_tokens => 8192,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 0,
        },
        'llama-3.1-70b' => {
            context_window => 128000,
            max_output_tokens => 8192,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 0,
        },
        'llama-3.1-8b' => {
            context_window => 128000,
            max_output_tokens => 8192,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 0,
        },
        'mistral-large' => {
            context_window => 128000,
            max_output_tokens => 8192,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 0,
        },
        'mixtral-8x7b' => {
            context_window => 32768,
            max_output_tokens => 8192,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 0,
        },
    );
    
    # Try exact match first
    my $model_data = $nvidia_models{$model};
    
    # Try without nvidia/ prefix
    if (!$model_data && $model =~ s{^nvidia/}{}) {
        $model_data = $nvidia_models{$model};
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

=head2 _fetch_zai_capabilities

Fetch capabilities from Z.AI API.

Arguments:
- $model: Model identifier

Returns:
- Hashref with capability data

=cut

sub _fetch_zai_capabilities {
    my ($self, $model) = @_;
    
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
    
    my $model_data = $zai_models{$model};
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
    my ($self, $model) = @_;
    
    # MiniMax models static capability map
    my %minimax_models = (
        'MiniMax-M3' => {
            context_window => 1000000,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 1,
            supports_reasoning => 1,
        },
        'MiniMax-M2.7' => {
            context_window => 204800,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
        },
        'MiniMax-M2.7-highspeed' => {
            context_window => 204800,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
        },
        'MiniMax-M2.5' => {
            context_window => 204800,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
        },
        'MiniMax-M2.5-highspeed' => {
            context_window => 204800,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
        },
        'MiniMax-M2.1' => {
            context_window => 204800,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
        },
        'MiniMax-M2.1-highspeed' => {
            context_window => 204800,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
        },
        'MiniMax-M2' => {
            context_window => 204800,
            max_output_tokens => 131072,
            supports_tools => 1,
            supports_streaming => 1,
            supports_vision => 0,
            supports_reasoning => 1,
        },
    );
    
    my $model_data = $minimax_models{$model};
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
    
    my $api_base = $provider_def->{api_base};
    $api_base =~ s{/+$}{};
    
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
    
    my $resp = $http->get($models_url, 
        headers => { 
            'Authorization' => "Bearer $api_key",
            'Accept' => 'application/json',
        }
    );
    
    unless ($resp->{success}) {
        log_warning('ModelCapabilitiesManager', "${provider} models API failed: HTTP " . $resp->{status});
        return undef;
    }
    
    my $data;
    eval {
        $data = decode_json($resp->{content});
    };
    if ($@) {
        log_warning('ModelCapabilitiesManager', "Failed to parse ${provider} response: $@");
        return undef;
    }
    
    # Find the specific model
    my $models = $data->{data} || $data->{models} || [];
    for my $m (@$models) {
        my $model_id = $m->{id};
        
        next unless $model_id eq $model;
        
        my $permuted_model = $m->{permuted_model} || undef;
        
        # Extract context window
        my $context_window = $m->{context_window}
            || $m->{max_tokens}
            || $m->{max_context_tokens}
            || undef;
        
        # OpenAI-compatible often provides max_tokens as total context
        if (!$context_window && $permuted_model && $permuted_model->{context_window}) {
            $context_window = $permuted_model->{context_window};
        }
        
        # For local llama.cpp servers, /v1/models only exposes n_ctx_train (training context),
        # not the server's actual --ctx-size runtime value. Query /props to get the real n_ctx.
        if (!$context_window || $api_base =~ m{localhost:|127\.0\.0\.1:}i) {
            my $props_ctx = $self->_query_llama_props($api_base);
            if ($props_ctx && $props_ctx > 0) {
                $context_window = $props_ctx;
                log_debug('ModelCapabilitiesManager', "llama.cpp /props n_ctx=$props_ctx for $model (overriding training context)");
            }
        }
        
        # Get max completion tokens
        my $output_tokens = $m->{max_completion_tokens}
            || $m->{max_output_tokens}
            || $permuted_model->{max_output_tokens}
            || undef;
        
        return {
            provider              => $provider,
            model                 => $model,
            context_window        => $context_window,
            max_prompt_tokens     => $context_window,  # Approximation
            max_output_tokens     => $output_tokens,
            supports_tools        => $m->{supports_tools} || $m->{function_call} || 0,
            supports_streaming    => 1,  # Most OpenAI-compatible support streaming
            supports_vision       => $m->{vision} || $m->{supports_vision} || 0,
            supports_reasoning    => 0,
            embeddings_dimension  => undef,
            architecture          => undef,
            quantization          => $m->{quantization} || undef,
            parameters           => $m->{parameters} || $m->{parameter_count} || undef,
            capabilities         => [],
            size_bytes           => undef,
            raw                  => $m,
        };
    }
    
    return undef;
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

Only called for local OpenAI-compatible servers (localhost/127.0.0.1).

=cut

sub _query_llama_props {
    my ($self, $api_base) = @_;
    
    # Derive the /props URL from the api_base
    # e.g. http://localhost:9090/v1/chat/completions -> http://localhost:9090/props
    my $props_url = $api_base;
    $props_url =~ s{/+$}{};       # strip trailing slashes
    $props_url =~ s{/v1(/.*)?$}{};  # strip /v1 and anything after it
    $props_url .= '/props';
    
    my $ua = $self->get_http();
    my $resp = eval { $ua->get($props_url) };
    if ($@ || !$resp || !$resp->{success}) {
        log_debug('ModelCapabilitiesManager', "llama.cpp /props not available at $props_url");
        return undef;
    }
    
    my $data = eval { decode_json($resp->{content}) };
    if ($@) {
        log_debug('ModelCapabilitiesManager', "llama.cpp /props parse error: $@");
        return undef;
    }
    
    # /props exposes: default_generation_settings.n_ctx (actual runtime context window)
    # This reflects the --ctx-size / -c value passed at server startup, not the model's
    # training context (n_ctx_train) which is what /v1/models exposes.
    my $n_ctx = $data->{default_generation_settings}{n_ctx}
             || $data->{n_ctx};   # some older versions may expose it at top level
    
    return $n_ctx if $n_ctx && $n_ctx > 0;
    return undef;
}

1;

=head1 SEE ALSO

L<CLIO::Core::GitHubCopilotModelsAPI>, L<CLIO::Core::APIManager>

=cut
