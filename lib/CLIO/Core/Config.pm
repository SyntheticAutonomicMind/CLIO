package CLIO::Core::Config;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use CLIO::Util::ConfigPath qw(get_config_dir);
use CLIO::Providers qw(get_provider list_providers provider_exists);
use JSON::PP qw(encode_json decode_json);
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

# Default configuration (system-level defaults only)
# Provider-specific defaults come from CLIO::Providers
use constant DEFAULT_CONFIG => {
    api_key => '',
    api_keys => {},  # Per-provider API keys: { anthropic => 'sk-ant-...', google => 'AIza...' }
    provider => 'github_copilot',  # Default provider
    editor => $ENV{EDITOR} || $ENV{VISUAL} || 'vim',  # Default editor
    log_level => 'INFO',  # Default log level: ERROR, WARNING, INFO, DEBUG
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
    
    # Start with system defaults
    my %config = %{DEFAULT_CONFIG()};
    
    # Reset user_set tracking
    $self->{user_set} = {};
    
    # Try to load user-explicitly-set values from file
    if (-f $self->{config_file}) {
        eval {
            open my $fh, '<', $self->{config_file} or die "Cannot open: $!";
            my $json = do { local $/; <$fh> };
            close $fh;
            
            my $file_config = decode_json($json);
            
            # Load user-set values and mark them as user-set
            for my $key (keys %$file_config) {
                $config{$key} = $file_config->{$key};
                $self->{user_set}->{$key} = 1;  # Mark as user-explicitly-set
            }
            
            print STDERR "[DEBUG][Config] Loaded user config from $self->{config_file}\n" if should_log('DEBUG');
            print STDERR "[DEBUG][Config] User-set keys: " . join(', ', sort keys %{$self->{user_set}}) . "\n" if should_log('DEBUG') && %{$self->{user_set}};
        };
        
        if ($@) {
            print STDERR "[WARN]Config] Failed to load config file: $@\n";
        }
    } else {
        print STDERR "[DEBUG][Config] No config file found at $self->{config_file}\n" if should_log('DEBUG');
    }
    
    # Apply provider defaults if provider is set and user hasn't overridden
    if ($config{provider}) {
        my $provider_config = get_provider($config{provider});
        if ($provider_config) {
            # Apply provider's api_base unless user explicitly set it
            unless ($self->{user_set}->{api_base}) {
                # For GitHub Copilot, try to get user-specific API endpoint
                if ($config{provider} eq 'github_copilot') {
                    my $user_api_base = $self->_get_copilot_user_api_endpoint();
                    if ($user_api_base) {
                        $config{api_base} = $user_api_base;
                        print STDERR "[DEBUG][Config] Using user-specific GitHub Copilot API: $config{api_base}\n" if should_log('DEBUG');
                    } else {
                        $config{api_base} = $provider_config->{api_base};
                        print STDERR "[DEBUG][Config] Using default GitHub Copilot API: $config{api_base}\n" if should_log('DEBUG');
                    }
                } else {
                    $config{api_base} = $provider_config->{api_base};
                    print STDERR "[DEBUG][Config] Using api_base from provider '$config{provider}': $config{api_base}\n" if should_log('DEBUG');
                }
            }
            
            # Apply provider's model unless user explicitly set it
            unless ($self->{user_set}->{model}) {
                $config{model} = $provider_config->{model};
                print STDERR "[DEBUG][Config] Using model from provider '$config{provider}': $config{model}\n" if should_log('DEBUG');
            }
        } else {
            print STDERR "[WARN]Config] Unknown provider '$config{provider}', using defaults\n" if should_log('WARNING');
        }
    } else {
        # No provider set - use openai defaults
        my $provider_config = get_provider('openai');
        if ($provider_config) {
            $config{api_base} = $provider_config->{api_base} unless $self->{user_set}->{api_base};
            $config{model} = $provider_config->{model} unless $self->{user_set}->{model};
        }
    }
    
    # Note: Log level is now controlled by CLIO_LOG_LEVEL environment variable
    # which is set by the --debug flag in the main clio script
    
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
    
    # Ensure config directory exists
    unless (-d $self->{config_dir}) {
        make_path($self->{config_dir}) or die "Cannot create config dir: $!";
    }
    
    # Build config to save - ONLY user-explicitly-set values
    my %config_to_save;
    for my $key (keys %{$self->{user_set}}) {
        $config_to_save{$key} = $self->{config}->{$key};
    }
    
    # Log what we're saving
    if (should_log('DEBUG')) {
        print STDERR "[DEBUG][Config] Saving user-set values: " . join(', ', sort keys %config_to_save) . "\n";
    }
    
    # Save config
    eval {
        open my $fh, '>', $self->{config_file} or die "Cannot write: $!";
        print $fh encode_json(\%config_to_save);
        close $fh;
        
        print STDERR "[DEBUG][Config] Saved to $self->{config_file}\n" if should_log('DEBUG');
    };
    
    if ($@) {
        print STDERR "[ERROR][Config] Failed to save config: $@\n" if should_log('ERROR');
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
    
    $self->{config}->{$key} = $value;
    
    # Mark as user-set unless explicitly told not to (default: mark as user-set)
    if (!defined $mark_user_set || $mark_user_set) {
        $self->{user_set}->{$key} = 1;
        print STDERR "[DEBUG][Config] Marked '$key' as user-set\n" if should_log('DEBUG');
    }
    
    return 1;
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
        print STDERR "[ERROR][Config] Unknown provider: $provider\n" if should_log('ERROR');
        print STDERR "[ERROR][Config] Available providers: " . join(', ', list_providers()) . "\n" if should_log('ERROR');
        return 0;
    }
    
    my $provider_config = get_provider($provider);
    
    # Set provider name (this IS user-set - they chose the provider)
    $self->set('provider', $provider, 1);  # Mark as user-set
    
    # Apply provider defaults (these are NOT user-set - they come from provider definition)
    $self->{config}->{api_base} = $provider_config->{api_base};
    
    # Store default model with provider prefix (e.g., "github_copilot/claude-haiku-4.5")
    my $default_model = $provider_config->{model};
    $self->{config}->{model} = "$provider/$default_model";
    
    # When switching providers, load the per-provider API key if available
    # This enables seamless switching between providers with stored keys
    my $provider_key = $self->get_provider_key($provider);
    if ($provider_key) {
        $self->{config}->{api_key} = $provider_key;
        print STDERR "[DEBUG][Config] Loaded API key for provider '$provider' from api_keys\n" if should_log('DEBUG');
    } else {
        # Clear old API key when switching providers (no stored key)
        # Each provider has its own authentication mechanism
        # (SAM uses api_key, GitHub Copilot uses OAuth tokens, etc.)
        delete $self->{config}->{api_key};
        delete $self->{user_set}->{api_key};
        print STDERR "[DEBUG][Config] No stored API key for provider '$provider'\n" if should_log('DEBUG');
    }
    
    # Remove api_base and model from user_set if they were there
    # (user is now using provider defaults, not custom values)
    delete $self->{user_set}->{api_base};
    delete $self->{user_set}->{model};
    
    print STDERR "[DEBUG][Config] Switched to provider: $provider\n" if should_log('DEBUG');
    print STDERR "[DEBUG][Config]   api_base: $provider_config->{api_base} (from provider)\n" if should_log('DEBUG');
    print STDERR "[DEBUG][Config]   model: $provider_config->{model} (from provider)\n" if should_log('DEBUG');
    
    return 1;
}

=head2 get_provider_key($provider)

Get the API key for a specific provider from per-provider storage.

Arguments:
- $provider: Provider name (e.g., 'anthropic', 'google')

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
- $provider: Provider name (e.g., 'anthropic', 'google')
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
    
    print STDERR "[DEBUG][Config] Stored API key for provider '$provider'\n" if should_log('DEBUG');
    
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

=head2 get_all

Get the entire configuration hash

=cut

sub get_all {
    my ($self) = @_;
    
    return $self->{config};
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
    push @lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━";
    
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
    push @lines, sprintf("Log Level: %s", $config->{log_level} || 'INFO');
    
    # Current Provider
    push @lines, sprintf("Provider:  %s%s", 
        $current_provider,
        $self->{user_set}->{provider} ? ' (user-set)' : ' (default)');
    
    # Available providers from Providers.pm
    push @lines, "";
    push @lines, "Available Providers:";
    push @lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━";
    
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
        print STDERR "[DEBUG][Config] Could not get user-specific Copilot endpoint: $@\n"
            if should_log('DEBUG');
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
