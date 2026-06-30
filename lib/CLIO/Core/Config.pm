# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::Config;

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use CLIO::UI::Terminal qw(box_char);
use CLIO::Core::Logger qw(should_log log_debug log_error log_warning);
use CLIO::Util::ConfigPath qw(get_config_dir);
use CLIO::Providers qw(get_provider list_providers provider_exists);
use CLIO::Util::JSON qw(encode_json decode_json);
use File::Path qw(make_path);
use File::Spec;

=head1 NAME

CLIO::Core::Config - Configuration management for CLIO

=head1 DESCRIPTION

Manages configuration for API settings, model selection, and provider selection.
Config file location: ~/.clio/config.json (or ~/Documents/.clio on iOS)

Only user-explicitly-set values are saved to config file.
Provider defaults come from CLIO::Providers and are applied dynamically.

Priority: User-set values > Provider defaults > System defaults

=cut

# Log level constants
use constant LOG_LEVEL => {
    ERROR => 0,
    WARNING => 1,
    INFO => 2,
    DEBUG => 3,
};

# Config keys scoped per model (provider/model ID). When switching models,
# these values are saved to model_configs and restored on switch back.
use constant MODEL_SCOPED_KEYS => [
    qw(cap_context_window cap_max_output cap_max_prompt
       show_thinking thinking_effort
       sampling_temperature sampling_top_p sampling_top_k
       force_tools force_vision force_reasoning)
];


# Default configuration (system-level defaults only)
# Provider-specific defaults come from CLIO::Providers
use constant DEFAULT_CONFIG => {
    model_configs => {},  # Per-model scoped config
    api_key => '',
    api_keys => {},  # Per-provider API keys: { google => 'AIza...', minimax => '...' }
    api_bases => {},  # Per-provider API base URLs: { 'llama.cpp' => 'http://localhost:9090/...' }
    provider => undef,  # No default - must be configured by user
    editor => $ENV{EDITOR} || $ENV{VISUAL} || 'vim',  # Default editor
    log_level => 'WARNING',  # Default log level: ERROR, WARNING, INFO, DEBUG
    # Web search configuration (SerpAPI)
    serpapi_key => '',  # SerpAPI key for reliable web search
    search_engine => 'google',  # SerpAPI engine: google, bing, duckduckgo
    search_provider => 'auto',  # auto | serpapi | duckduckgo_direct
    # Terminal operations configuration
    terminal_passthrough => 0,  # Force passthrough mode for all commands (default: off, use auto-detect)
    terminal_autodetect => 1,   # Auto-detect interactive commands and use passthrough (default: on)
    # Session auto-pruning configuration
    session_auto_prune => 0,    # Enable automatic session pruning on startup (default: off)
    session_prune_days => 30,   # Delete sessions older than this many days (default: 30)
    # Security configuration
    redact_level => 'pii',      # Redaction level: strict, standard, api_permissive, pii, off (default: pii)
    # Command security analysis level
    security_level => 'standard',  # Command security: relaxed, standard, strict (default: standard)
    # Text sanitizer mode: strict (warn on invisible char injection), relaxed (filter silently)
    sanitize_mode => 'strict',
    # File/directory creation umask (controls default permissions)
    # Value is octal as integer: 0077 (restrictive), 0022 (standard), 0000 (permissive)
    # Setting this to 0077 ensures files are only readable/writable by owner
    file_umask => 0022,  # Default: 0022 (owner read/write, group/other read)
    # HTTP proxy for API requests and update checks
    # Supports: http://, https://, socks5://, socks5h://, socks4://
    # Falls back to HTTPS_PROXY, HTTP_PROXY, ALL_PROXY environment variables
    http_proxy => '',
    # Reasoning/thinking display
    show_thinking => 0,         # Show model's reasoning/thinking output (default: off)
    thinking_effort => 'medium', # Reasoning effort level: low, medium, high (default: medium)
    # Sampling parameter overrides (empty string = use model/provider defaults)
    sampling_temperature => '',  # Override temperature (e.g. 0.7); empty = use provider default
    sampling_top_p => '',        # Override top_p (e.g. 0.9); empty = use provider default
    sampling_top_k => '',        # Override top_k (e.g. 40); empty = use provider default
    # Capability overrides (cap_* caps model value, force_* overrides boolean)
    cap_context_window => 0,     # Cap model's context window (0 = no cap, e.g. 128000 for DeepSeek 1M -> 128k)
    cap_max_output => 0,         # Cap model's max output tokens (0 = no cap)
    cap_max_prompt => 0,         # Cap model's max prompt tokens (0 = no cap)
    force_tools => '',           # Force tools on/off ('', 'on', 'off')
    force_vision => '',          # Force vision on/off ('', 'on', 'off')
    force_reasoning => '',       # Force reasoning on/off ('', 'on', 'off')
    # Agent iteration limit (0 = unlimited)
    max_iterations => 0,
    # Feature switches (tools available to agent)
    enable_subagents => 1,  # Enable agent_operations tool (sub-agent spawning)
    enable_remote => 1,     # Enable remote_execution tool (SSH remote tasks)
    # Auto-discover installed skills in the system prompt and expose skill_operations tool
    # Off = no skill catalog injected, tool not registered (current behavior)
    auto_discover_skills => 1,
    # Tool filtering (persistent version of --enable/--disable flags)
    enabled_tools => '',    # Comma-separated allowlist of tools (empty = all)
    disabled_tools => '',   # Comma-separated blocklist of tools (empty = none)
    # GitHub Copilot API version headers (update to match latest vscode-copilot-chat)
    editor_version => 'vscode/2.0.0',  # Editor version for API requests
    plugin_version => 'copilot-chat/0.38.0',  # Plugin version for API requests
    copilot_language_server_version => '1.378.1799',  # Completions core version
    github_api_version => '2025-05-01',  # GitHub API version for requests
};

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug => $args{debug} || 0,
        config_dir => $args{config_dir} || get_config_dir(),
        config_file => undef,  # Will be set in _get_config_path
        config => {},
        user_set => {},  # Track which values user explicitly configured
    };
    
    bless $self, $class;
    
    $self->{config_file} = $self->_get_config_path();
    $self->load();
    
    return $self;
}

=head2 _get_config_path

Get the full path to the config file

=cut

sub _get_config_path {
    my ($self) = @_;
    
    return File::Spec->catfile($self->{config_dir}, 'config.json');
}

=head2 load

Load configuration from file and apply provider defaults

Only user-explicitly-set values are loaded from file.
Provider defaults (api_base, model) come from CLIO::Providers dynamically.

=cut

sub load {
    my ($self) = @_;
    
    # Check if we have a cached config for the current provider
    my $current_provider = $self->{config}->{provider} // 'github_copilot';
    my $cache_key = $current_provider;
    
    if ($self->{_provider_cache} && $self->{_provider_cache}{provider} eq $cache_key) {
        # Return cached config merged with user-set values
        my %config = %{DEFAULT_CONFIG()};
        %config = (%config, %{$self->{_provider_cache}{config}});
        
        # Apply user-set values on top of cached provider defaults
        if ($self->{config_file} && -f $self->{config_file}) {
            eval {
                open my $fh, '<', $self->{config_file} or croak "Cannot open: $!";
                my $json = do { local $/; <$fh> };
                close $fh;
                
                my $file_config = decode_json($json);
                
                # Load user-set values and mark them as user-set
                for my $key (keys %$file_config) {
                    $config{$key} = $file_config->{$key};
                    $self->{user_set}->{$key} = 1;  # Mark as user-explicitly-set
                }
            };
        }
        
        $self->{config} = \%config;
        return $self->{config};
    }
    
    # Start with system defaults
    my %config = %{DEFAULT_CONFIG()};
    
    # Reset user_set tracking
    $self->{user_set} = {};
    
    # Try to load user-explicitly-set values from file
    if (-f $self->{config_file}) {
        eval {
            open my $fh, '<', $self->{config_file} or croak "Cannot open: $!";
            my $json = do { local $/; <$fh> };
            close $fh;
            
            my $file_config = decode_json($json);
            
            # Load user-set values and mark them as user-set
            for my $key (keys %$file_config) {
                $config{$key} = $file_config->{$key};
                $self->{user_set}->{$key} = 1;  # Mark as user-explicitly-set
            }
            
            log_debug('Config', "Loaded user config from $self->{config_file}");
            log_debug('Config', "User-set keys: " . join(', ', sort keys %{$self->{user_set}}));
        };
        
        if ($@) {
            log_warning('Config', "Failed to load config file: $@");
        }
    } else {
        log_debug('Config', "No config file found at $self->{config_file}");
    }
    
    # Apply provider defaults if provider is set and user hasn't overridden
    if ($config{provider}) {
        my $provider_config = get_provider($config{provider});
        if ($provider_config) {
            # Apply provider's api_base unless user explicitly set it
            unless ($self->{user_set}->{api_base}) {
                # Check per-provider stored base URL first
                my $api_bases = $config{api_bases} || {};
                my $stored_base = $api_bases->{$config{provider}};
                if ($stored_base) {
                    $config{api_base} = $stored_base;
                    log_debug('Config', "Using stored api_base for provider '$config{provider}': $config{api_base}");
                } elsif ($config{provider} eq 'github_copilot') {
                    # Check if a static PAT is configured for this provider
                    # ghu_ tokens are fine-grained PATs that work with individual endpoint
                    my $api_keys = $config{api_keys} || {};
                    my $provider_key = $api_keys->{$config{provider}};
                    my $direct_key = $config{api_key};
                    my $static_pat = $provider_key || $direct_key;
                    
                    if ($static_pat && $static_pat =~ /^ghu_/) {
                        # Fine-grained PAT (ghu_) - use individual endpoint directly
                        $config{api_base} = 'https://api.individual.githubcopilot.com';
                        log_debug('Config', "Using individual endpoint for fine-grained PAT");
                    } else {
                        # For GitHub Copilot, try to get user-specific API endpoint
                        my $user_api_base = $self->_get_copilot_user_api_endpoint();
                        if ($user_api_base) {
                            $config{api_base} = $user_api_base;
                            log_debug('Config', "Using user-specific GitHub Copilot API: $config{api_base}");
                        } else {
                            $config{api_base} = $provider_config->{api_base};
                            log_debug('Config', "Using default GitHub Copilot API: $config{api_base}");
                        }
                    }
                } else {
                    $config{api_base} = $provider_config->{api_base};
                    log_debug('Config', "Using api_base from provider '$config{provider}': $config{api_base}");
                }
            }
            
            # Apply provider's model unless user explicitly set it
            unless ($self->{user_set}->{model}) {
                my $default_model = $provider_config->{model};
                if (defined $default_model) {
                    # Use the saved model if it's already properly prefixed (has "/"),
                    # otherwise apply the provider's default
                    unless ($config{model} && $config{model} =~ m{/}) {
                        $config{model} = $default_model;
                    }
                    log_debug('Config', "Using model from provider '$config{provider}': $config{model}");
                } else {
                    require CLIO::Providers;
                    $config{model} = $config{model} || CLIO::Providers::DEFAULT_MODEL();
                    log_debug('Config', "Provider '$config{provider}' has no default model, using: $config{model}");
                }
            }
            
            # Load the provider's api_key if one exists in the api_keys store
            # Note: Use local %config hash directly - $self->{config} isn't set until later
            my $api_keys = $config{api_keys} || {};
            my $provider_key = $api_keys->{$config{provider}};
            if ($provider_key) {
                $config{api_key} = $provider_key;
                log_debug('Config', "Loaded api_key for provider '$config{provider}'");
            }
            
            # Cache the provider config (without user-set values)
            my %provider_defaults = %config;
            # Remove user-set values from cache
            for my $key (keys %{$self->{user_set}}) {
                delete $provider_defaults{$key};
            }
            $self->{_provider_cache} = {
                provider => $cache_key,
                config => \%provider_defaults,
            };
        } else {
            log_warning('Config', "Unknown provider '$config{provider}', using defaults");
        }
    } else {
        # No provider set
        # Note: Provider should be set via user configuration.
        # The clio executable will prompt the user if no provider is configured.
        # If we reach here, the user has already configured a provider.
        log_debug('Config', 'No provider set - waiting for user configuration');
    }
    
    # Note: Log level is now controlled by CLIO_LOG_LEVEL environment variable
    # which is set by the --debug flag in the main clio script
    


    # Restore per-model scoped config for the current model (if resolved).
    # Migration: if model_configs is empty but scoped keys have non-default
    # values, migrate them into model_configs for the current model.
    {
        my $model = $self->{config}->{model};
        my $model_configs = $self->{config}->{model_configs} ||= {};
        
        if ($model && $model =~ m{/}) {
            # If no stored config for this model yet, check for migration
            if (!exists $model_configs->{$model} || !%{$model_configs->{$model}}) {
                my $has_migration = 0;
                my $entry = $model_configs->{$model} ||= {};
                for my $key (@{MODEL_SCOPED_KEYS()}) {
                    my $val = $self->{config}->{$key};
                    my $default = DEFAULT_CONFIG->{$key};
                    # Only migrate if value differs from default
                    if (defined $val && (!defined $default || $val ne $default)) {
                        $entry->{$key} = $val;
                        $has_migration = 1;
                    }
                }
                if ($has_migration) {
                    log_debug('Config', "Migrated existing scoped config values to model_configs{$model}");
                }
            }
            # Restore scoped config from model_configs if available
            if ($model_configs->{$model}) {
                for my $key (@{MODEL_SCOPED_KEYS()}) {
                    if (exists $model_configs->{$model}{$key}) {
                        $self->{config}->{$key} = $model_configs->{$model}{$key};
                    }
                }
                log_debug('Config', "Restored model config for '$model'");
            }
        }
    }
    $self->{config} = \%config;
    
    return 1;
}

=head2 save

Save ONLY user-explicitly-set values to file

Provider defaults (api_base, model from provider) are NOT saved.
Only saves what user explicitly configured via /api commands.

=cut

sub save {
    my ($self) = @_;
    
    # Ensure config directory exists with secure permissions
    unless (-d $self->{config_dir}) {
        make_path($self->{config_dir}, { mode => 0700 }) or croak "Cannot create config dir: $!";
    }
    
   # Build config to save - ONLY user-explicitly-set values
   my %config_to_save;
   for my $key (keys %{$self->{user_set}}) {
       $config_to_save{$key} = $self->{config}->{$key};
   }
    $config_to_save{model_configs} = $self->{config}->{model_configs}
        if $self->{config}->{model_configs} && %{$self->{config}->{model_configs}};
   
   # Log what we're saving
    if (should_log('DEBUG')) {
        log_debug('Config', "Saving user-set values: " . join(', ', sort keys %config_to_save));
    }
    
    # Save config with secure permissions (contains API keys)
    eval {
        open my $fh, '>', $self->{config_file} or croak "Cannot write: $!";
        print $fh encode_json(\%config_to_save);
        close $fh;
        chmod 0600, $self->{config_file};
        
        log_debug('Config', "Saved to $self->{config_file}");
    };
    
    if ($@) {
        log_error('Config', "Failed to save config: $@");
        return 0;
    }
    
    return 1;
}

=head2 get

Get a configuration value

=cut

sub get {
    my ($self, $key) = @_;
    
    return $self->{config}->{$key};
}

=head2 set

Set a configuration value (marks as user-explicitly-set)

When called via /api commands, marks the value as user-set so it gets saved.

=cut

sub set {
   my ($self, $key, $value, $mark_user_set) = @_;
   
    # When model changes, save old scoped config and restore new one
    if ($key eq 'model' && defined $value && $value ne ''
        && $self->{config}->{model} && $self->{config}->{model} ne $value)
    {
        my $old_model = $self->{config}->{model};
        # Save old model config if it was resolved (has "/")
        $self->_save_model_config($old_model) if $old_model =~ m{/};
        $self->{config}->{$key} = $value;
       # Restore new model config if it is resolved (has "/")
       $self->_restore_model_config($value) if $value =~ m{/};
        # Persist scoped config immediately to avoid data loss on exit
        $self->save() if $old_model =~ m{/};
   } else {
   $self->{config}->{$key} = $value;
    }
   
   # Mark as user-set unless explicitly told not to (default: mark as user-set)
   if (!defined $mark_user_set || $mark_user_set) {
       $self->{user_set}->{$key} = 1;
       log_debug('Config', "Marked '$key' as user-set");
   }
   
    # If this is a model-scoped key, update model_configs immediately
    if (grep { $_ eq $key } @{MODEL_SCOPED_KEYS()}) {
        my $model = $self->{config}->{model};
        if ($model && $model =~ m{/}) {
            $self->{config}->{model_configs} ||= {};
            $self->{config}->{model_configs}{$model} ||= {};
            $self->{config}->{model_configs}{$model}{$key} = $value;
        }
    }
    return 1;
}


=head2 _save_model_config($model_id)

Save current per-model scoped config values to model_configs{$model_id}.
Called automatically when switching models via set('model', ...).

=cut

sub _save_model_config {
    my ($self, $model_id) = @_;
    return unless $model_id;
    
    $self->{config}->{model_configs} ||= {};
    my $entry = $self->{config}->{model_configs}{$model_id} ||= {};
    
    for my $key (@{MODEL_SCOPED_KEYS()}) {
        my $val = $self->{config}->{$key};
        $entry->{$key} = $val if defined $val;
    }
    
    log_debug('Config', "Saved model config for '$model_id': " . scalar(keys %$entry) . " keys");
}

=head2 _restore_model_config($model_id)

Restore per-model scoped config values from model_configs{$model_id}.
Falls back to DEFAULT_CONFIG values if no stored config exists for this model.
Called automatically when switching models via set('model', ...).

=cut

sub _restore_model_config {
    my ($self, $model_id) = @_;
    return unless $model_id;
    
    $self->{config}->{model_configs} ||= {};
    my $entry = $self->{config}->{model_configs}{$model_id};
    
    for my $key (@{MODEL_SCOPED_KEYS()}) {
        if ($entry && exists $entry->{$key}) {
            $self->{config}->{$key} = $entry->{$key};
        } else {
            # Use system default - but don't mark as user-set
            $self->{config}->{$key} = DEFAULT_CONFIG->{$key};
        }
    }
    
    if ($entry && %$entry) {
        log_debug('Config', "Restored model config for '$model_id': " . scalar(keys %$entry) . " keys");
    } else {
        log_debug('Config', "No stored config for '$model_id' - using defaults");
    }
}

=head2 set_provider

Switch to a provider (applies provider defaults from CLIO::Providers)

Provider defaults (api_base, model) are NOT marked as user-set.
Only the provider name itself is marked as user-set.
User can override individual settings later.

=cut

sub set_provider {
    my ($self, $provider) = @_;
    
    # Check if provider exists in Providers.pm
    unless (provider_exists($provider)) {
        log_error('Config', "Unknown provider: $provider");
        log_error('Config', "Available providers: " . join(', ', list_providers()));
        return 0;
    }
    
    # Save outgoing provider's custom api_base before switching
    # If the user had set a custom api_base for the current provider,
    # preserve it in per-provider storage so it survives the switch
    my $old_provider = $self->get('provider');
    if ($old_provider && $self->{user_set}->{api_base}) {
        my $current_base = $self->{config}->{api_base};
        if ($current_base) {
            $self->set_provider_base($old_provider, $current_base);
            log_debug('Config', "Saved custom api_base for outgoing provider '$old_provider'");
        }
    }
    
    my $provider_config = get_provider($provider);
    
    # Set provider name (this IS user-set - they chose the provider)
    $self->set('provider', $provider, 1);  # Mark as user-set
    
    # Load the incoming provider's stored api_base, or fall back to provider default
    my $provider_base = $self->get_provider_base($provider);
    if ($provider_base) {
        $self->{config}->{api_base} = $provider_base;
        log_debug('Config', "Loaded custom api_base for provider '$provider' from api_bases");
    } else {
        $self->{config}->{api_base} = $provider_config->{api_base};
    }
    
    # Store default model with provider prefix
    # If provider has no default model (undef), we'll use the first available model from the API
    my $default_model = $provider_config->{model};
    if (defined $default_model) {
        if ($default_model =~ m{^\Q$provider\E/}) {
            $self->set("model", $default_model, 0);
        } else {
            $self->set("model", "$provider/$default_model", 0);
        }
    } else {
        # No default model for this provider - keep existing model if it's
        # already set and is a real model (not a provider-name placeholder).
        # If nothing is set, use DEFAULT_MODEL as fallback.
        my $existing = $self->get('model');
        if ($existing && length($existing) && $existing ne $provider && $existing ne '') {
            log_debug('Config', "Keeping existing model for provider '$provider': $existing");
        } else {
            require CLIO::Providers;
            $self->set("model", CLIO::Providers::DEFAULT_MODEL(), 0);
            log_debug('Config', "No default model for '$provider', using global fallback: " . CLIO::Providers::DEFAULT_MODEL());
        }
    }
    
    # When switching providers, load the per-provider API key if available
    # Switching between providers with stored keys
    my $provider_key = $self->get_provider_key($provider);
    if ($provider_key) {
        $self->{config}->{api_key} = $provider_key;
        log_debug('Config', "Loaded API key for provider '$provider' from api_keys");
    }
    # When no per-provider key exists, keep existing api_key.
    # It may be valid for the new provider. Providers that use other
    # auth (GitHub Copilot OAuth) will handle that in APIManager.
    
    # Remove api_base and model from user_set if they were there
    # (user is now using provider defaults, not custom values)
    delete $self->{user_set}->{api_base};
    delete $self->{user_set}->{model};
    
    log_debug('Config', "Switched to provider: $provider");
    log_debug('Config', "api_base: " . $self->{config}->{api_base} . " (from " . ($provider_base ? "stored" : "provider") . ")");
    log_debug('Config', "model: " . ($provider_config->{model} // '(no default - will fetch from API)') . " (from provider)");
    
    return 1;
}

=head2 get_provider_key($provider)

Get the API key for a specific provider from per-provider storage.

Arguments:
- $provider: Provider name (e.g., 'google', 'minimax')

Returns: API key string or undef if not set

=cut

sub get_provider_key {
    my ($self, $provider) = @_;
    
    return unless $provider;
    
    my $api_keys = $self->{config}->{api_keys} || {};
    return $api_keys->{$provider};
}

=head2 set_provider_key($provider, $key)

Set the API key for a specific provider.
This stores the key in per-provider storage and also sets it as current
if the provider matches the current provider.

Arguments:
- $provider: Provider name (e.g., 'google', 'minimax')
- $key: API key value

Returns: 1 on success

=cut

sub set_provider_key {
    my ($self, $provider, $key) = @_;
    
    # Initialize api_keys hash if needed
    $self->{config}->{api_keys} //= {};
    
    # Store the key
    $self->{config}->{api_keys}{$provider} = $key;
    $self->{user_set}->{api_keys} = 1;
    
    # If this is the current provider, also set api_key
    my $current_provider = $self->get('provider');
    if ($current_provider && $current_provider eq $provider) {
        $self->{config}->{api_key} = $key;
        $self->{user_set}->{api_key} = 1;
    }
    
    log_debug('Config', "Stored API key for provider '$provider'");
    
    # Save config (keys are sensitive, save immediately)
    $self->save();
    
    return 1;
}

=head2 list_provider_keys()

List all providers that have stored API keys.

Returns: Array of provider names

=cut

sub list_provider_keys {
    my ($self) = @_;
    
    my $api_keys = $self->{config}->{api_keys} || {};
    return sort keys %$api_keys;
}

=head2 get_provider_base($provider)

Get the API base URL for a specific provider from per-provider storage.

Arguments:
- $provider: Provider name (e.g., 'llama.cpp', 'sam')

Returns: API base URL string or undef if not set

=cut

sub get_provider_base {
    my ($self, $provider) = @_;
    
    return unless $provider;
    
    my $api_bases = $self->{config}->{api_bases} || {};
    return $api_bases->{$provider};
}

=head2 set_provider_base($provider, $url)

Set the API base URL for a specific provider.
This stores the URL in per-provider storage and also sets it as current
if the provider matches the current provider.

Arguments:
- $provider: Provider name (e.g., 'llama.cpp', 'sam')
- $url: API base URL value

Returns: 1 on success

=cut

sub set_provider_base {
    my ($self, $provider, $url) = @_;
    
    # Initialize api_bases hash if needed
    $self->{config}->{api_bases} //= {};
    
    # Store the base URL
    $self->{config}->{api_bases}{$provider} = $url;
    $self->{user_set}->{api_bases} = 1;
    
    # Clear the flat api_base from user_set so it doesn't get saved as a
    # top-level key and override per-provider api_bases on next load.
    # The per-provider storage in api_bases is the authoritative source.
    delete $self->{user_set}->{api_base};
    
    # If this is the current provider, also set api_base
    my $current_provider = $self->get('provider');
    if ($current_provider && $current_provider eq $provider) {
        $self->{config}->{api_base} = $url;
    }
    
    log_debug('Config', "Stored API base for provider '$provider': $url");
    
    return 1;
}

=head2 get_model_alias($name)

Get the model value for a given alias name. Returns undef if not found.

=cut

sub get_model_alias {
    my ($self, $name) = @_;
    
    my $aliases = $self->{config}->{model_aliases} || {};
    return $aliases->{lc($name)};
}

=head2 set_model_alias($name, $model)

Set a model alias. Stores in config and marks for saving.

=cut

sub set_model_alias {
    my ($self, $name, $model) = @_;
    
    $self->{config}->{model_aliases} ||= {};
    $self->{config}->{model_aliases}{lc($name)} = $model;
    $self->{user_set}->{model_aliases} = 1;
    
    return 1;
}

=head2 delete_model_alias($name)

Remove a model alias. Returns 1 if deleted, 0 if not found.

=cut

sub delete_model_alias {
    my ($self, $name) = @_;
    
    my $aliases = $self->{config}->{model_aliases} || {};
    return 0 unless exists $aliases->{lc($name)};
    
    delete $aliases->{lc($name)};
    $self->{user_set}->{model_aliases} = 1;
    
    return 1;
}

=head2 list_model_aliases

Return hash of all model aliases (name => model).

=cut

sub list_model_aliases {
    my ($self) = @_;
    
    return %{$self->{config}->{model_aliases} || {}};
}

=head2 get_all

Get the entire configuration hash

=cut

sub get_all {
    my ($self) = @_;
    
    return $self->{config};
}

=head2 agent_name

Return the agent display name. Defaults to "CLIO" unless overridden
by the CLIO_AGENT_NAME environment variable (used by host applications
to rebrand the interface).

=cut

sub agent_name {
    return $ENV{CLIO_AGENT_NAME} || 'CLIO';
}

=head2 display

Display current configuration (with masked API key)

Shows current provider, settings, and which values are user-set vs provider defaults.

=cut

sub display {
    my ($self) = @_;
    
    my $config = $self->{config};
    
    my @lines;
    
    push @lines, "Current Configuration:";
    push @lines, box_char('hhorizontal') x 54;
    
    my $current_provider = $config->{provider} || 'openai';
    my $key = $config->{api_key};
    my $key_display = '(not set)';
    
    # Check for GitHub token
    if ($current_provider eq 'github_copilot') {
        # Check for GitHub Copilot token
        require CLIO::Core::GitHubAuth;
        my $gh_auth = CLIO::Core::GitHubAuth->new(debug => $self->{debug});
        if ($gh_auth->is_authenticated()) {
            my $token = $gh_auth->get_copilot_token();
            $key_display = $token ? 
                substr($token, 0, 8) . '...' . substr($token, -4) : 
                '(GitHub authenticated)';
        }
    } elsif ($key) {
        $key_display = substr($key, 0, 8) . '...' . substr($key, -4);
    }
    
    push @lines, sprintf("API Key:   %s%s", 
        $key_display,
        $self->{user_set}->{api_key} ? ' (user-set)' : '');
    
    # API Base - show if user-set or from provider
    push @lines, sprintf("API Base:  %s%s", 
        $config->{api_base} || '(not set)',
        $self->{user_set}->{api_base} ? ' (user-set)' : ' (from provider)');
    
    # Model - show if user-set or from provider
    push @lines, sprintf("Model:     %s%s", 
        $config->{model} || '(not set)',
        $self->{user_set}->{model} ? ' (user-set)' : ' (from provider)');
    
    # Log Level
    push @lines, sprintf("Log Level: %s", $config->{log_level} || 'WARNING');
    
    # Current Provider
    push @lines, sprintf("Provider:  %s%s", 
        $current_provider,
        $self->{user_set}->{provider} ? ' (user-set)' : ' (default)');
    
    # Available providers from Providers.pm
    push @lines, "";
    push @lines, "Available Providers:";
    push @lines, box_char('hhorizontal') x 54;
    
    for my $provider (list_providers()) {
        my $provider_config = get_provider($provider);
        my $marker = ($provider eq $current_provider) ? '* ' : '  ';
        push @lines, sprintf("%s%-15s  %s", 
            $marker,
            $provider, 
            $provider_config->{api_base}
        );
    }
    
    return join("\n", @lines);
}

=head2 _get_copilot_user_api_endpoint

Get the user-specific GitHub Copilot API endpoint from CopilotUserAPI.
This ensures we use the correct endpoint (e.g., api.individual.githubcopilot.com)
instead of the generic api.githubcopilot.com.

Returns:
- String: User-specific API endpoint URL
- undef: If unable to fetch or not applicable

=cut

sub _get_copilot_user_api_endpoint {
    my ($self) = @_;
    
    my $endpoint;
    eval {
        require CLIO::Core::CopilotUserAPI;
        my $user_api = CLIO::Core::CopilotUserAPI->new(debug => $self->{debug} || 0);
        
        # Try cached data first (no API call), fall back to fresh fetch
        my $user_data = $user_api->get_cached_user() || $user_api->fetch_user();
        if ($user_data) {
            $endpoint = $user_data->get_api_endpoint();
        }
    };
    if ($@) {
        log_debug('Config', "Could not get user-specific Copilot endpoint: $@");
    }
    
    return $endpoint;
}

1;

__END__

=head1 USAGE

    use CLIO::Core::Config;
    
    my $config = CLIO::Core::Config->new(debug => 1);
    
    # Get values
    my $api_key = $config->get('api_key');
    my $model = $config->get('model');
    
    # Set values
    $config->set('model', 'gpt-4-turbo');
    $config->set_provider('openai');  # Quick switch
    
    # Save to file
    $config->save();
    
    # Display
    print $config->display();

=head1 AUTHOR

Fewtarius

=cut

1;
