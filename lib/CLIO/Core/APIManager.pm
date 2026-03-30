# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::APIManager;

=head1 NAME

CLIO::Core::APIManager - AI provider API communication and request orchestration

=head1 DESCRIPTION

Manages communication with AI model providers (GitHub Copilot, Anthropic, Google).
Handles streaming responses, tool call extraction, retry logic with exponential
backoff, and token usage tracking. Central hub for all AI API interactions.

=head1 SYNOPSIS

    use CLIO::Core::APIManager;
    
    my $api = CLIO::Core::APIManager->new(config => $config);
    my $response = $api->send_message(\@messages, tools => \@tools);

=cut

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(should_log log_debug log_error log_info log_warning);
use CLIO::Core::ErrorContext qw(classify_error format_error);
use CLIO::Util::ConfigPath qw(get_config_dir);
use CLIO::Providers qw(get_provider list_providers);
use POSIX ":sys_wait_h"; # For WNOHANG
use Time::HiRes qw(time sleep);  # High resolution time and sleep
use CLIO::Util::JSON qw(encode_json decode_json);
use Carp qw(croak);
use CLIO::Compat::HTTP;
BEGIN { require CLIO::Compat::HTTP; CLIO::Compat::HTTP->import(); }
use Scalar::Util qw(blessed);
use CLIO::Core::PerformanceMonitor;
use CLIO::Core::API::MessageValidator qw(
    validate_and_truncate
    validate_tool_message_pairs
    preflight_validate
);
use CLIO::Core::API::ResponseHandler;
use CLIO::Util::TextSanitizer qw(sanitize_text);

# Define request states
use constant {
    REQUEST_NONE => 0,
    REQUEST_PENDING => 1,
    REQUEST_COMPLETE => 2,
    REQUEST_ERROR => 3,
};

# Default endpoints
use constant {
    DEFAULT_ENDPOINT => 'https://api.openai.com/v1',
};

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
BEGIN {
    unless ($ENV{PERL_LWP_SSL_CA_FILE}) {
        my @ca_candidates = (
            '/etc/ssl/cert.pem',
            '/opt/homebrew/etc/openssl@3/cert.pem',
        );
        my $ca_file;
        for my $candidate (@ca_candidates) {
            if (-e $candidate) {
                $ca_file = $candidate;
                last;
            }
        }
        if ($ca_file) {
            $ENV{PERL_LWP_SSL_CA_FILE} = $ca_file;
        } else {
            # Only warn if explicitly debugging - this is a system configuration issue
            # most users won't see this anyway since CA bundles are usually available
            log_warning('APIManager', "No CA bundle found in common locations. HTTPS requests may fail.");
        }
    }
}

# No external dependencies, only core Perl

# Generate a UUID v4 for request tracking headers
sub _generate_uuid {
    my @hex = ('0'..'9', 'a'..'f');
    my $uuid = '';
    for my $i (1..32) {
        $uuid .= $hex[int(rand(16))];
        $uuid .= '-' if $i == 8 || $i == 12 || $i == 16 || $i == 20;
    }
    # Set version (4) and variant (8, 9, a, or b)
    substr($uuid, 14, 1) = '4';
    substr($uuid, 19, 1) = $hex[8 + int(rand(4))];
    return $uuid;
}

# Check if a model supports reasoning/thinking parameters via models API
# Falls back to pattern matching if API data unavailable
sub _model_supports_reasoning {
    my ($self, $model) = @_;
    return 0 unless $model;

    # Check cached capabilities from models API (authoritative source)
    if ($self->{_model_capabilities_cache} && $self->{_model_capabilities_cache}{$model}) {
        my $caps = $self->{_model_capabilities_cache}{$model};
        return $caps->{supports_reasoning} if defined $caps->{supports_reasoning};
    }

    # Fetch capabilities (will populate cache with supports_reasoning if available)
    my $caps = $self->get_model_capabilities($model);
    if ($caps && defined $caps->{supports_reasoning}) {
        return $caps->{supports_reasoning};
    }

    # Pattern-based fallback for known reasoning models
    # MiniMax M2.x models support interleaved thinking natively
    if ($model =~ /^MiniMax-M2/i) {
        return 1;
    }

    # Default: don't send reasoning params for unknown models
    return 0;
}

# Recursive sanitization of data structures before JSON encoding
# Removes problematic UTF-8 characters (emojis, bullets, etc.) that cause API 400 errors
sub _sanitize_payload_recursive {
    my ($data) = @_;
    
    if (!defined $data) {
        return undef;
    } elsif (ref($data) eq 'HASH') {
        # Recursively sanitize hash values
        my %sanitized;
        for my $key (keys %$data) {
            $sanitized{$key} = _sanitize_payload_recursive($data->{$key});
        }
        return \%sanitized;
    } elsif (ref($data) eq 'ARRAY') {
        # Recursively sanitize array elements
        return [ map { _sanitize_payload_recursive($_) } @$data ];
    } elsif (!ref($data)) {
        # Scalar value - sanitize if it's a string
        return sanitize_text($data);
    } else {
        # Other ref types (CODE, GLOB, etc.) - return as-is
        return $data;
    }
}

# Configuration validation and display
sub validate_configuration {
    my ($class, $config) = @_;
    
    print "Current Configuration:\n";
    print "==================================\n";
    
    # Check GitHub Copilot authentication
    eval {
        require CLIO::Core::GitHubAuth;
        my $auth = CLIO::Core::GitHubAuth->new();
        if ($auth->is_authenticated()) {
            my $username = $auth->get_username() || 'unknown';
            print "✓ GitHub Copilot: Authenticated as $username\n";
        } else {
            print "✗ GitHub Copilot: Not authenticated (use /login)\n";
        }
    };
    
    # API configuration from Config object
    if ($config && $config->can('get')) {
        my $provider = $config->get('provider') || 'openai';
        my $api_base = $config->get('api_base') || '(not set)';
        my $model = $config->get('model') || '(not set)';
        my $api_key = $config->get('api_key');
        
        print "✓ Provider: $provider\n";
        print "✓ API Base: $api_base\n";
        print "✓ Model: $model\n";
        
        if ($api_key) {
            my $key_display = substr($api_key, 0, 8) . '...' . substr($api_key, -4);
            print "✓ API Key: $key_display\n";
        } else {
            print "[ ] API Key: NOT SET (required unless using GitHub auth)\n";
        }
    } else {
        print "✗ Config object not available\n";
    }
    
    print "\nSupported Providers:\n";
    for my $name (list_providers()) {
        my $provider = get_provider($name);
        print "  $name: $provider->{api_base}\n";
    }
    print "\n";
}

sub new {
    my ($class, %args) = @_;
    
    # Config object MUST be provided - it's the authority for all settings
    my $config = $args{config};
    unless ($config && $config->can('get')) {
        croak "APIManager requires Config object";
    }
    
    # Get settings from Config (NOT from ENV vars)
    my $api_base = $config->get('api_base');
    my $model = $config->get('model');
    
    # Validate the URL format
    unless ($api_base && $api_base =~ m{^https?://}) {
        croak "Invalid API base URL from config: " . ($api_base || '(not set)') . " (must start with http:// or https://)";
    }
    
    # Print debug info
    if ($args{debug}) {
        log_debug('APIManager', "Initializing:");
        log_debug('APIManager', "api_base: $api_base");
        log_debug('APIManager', "model: $model");
    }
    
    # Initialize async request state
    my $self = {
        api_base         => $api_base,
        request_state    => REQUEST_NONE,
        response         => undef,
        error            => undef,
        start_time       => 0,
        api_key          => '',  # Will be set by _get_api_key()
        config           => $config,  # Config for dynamic model lookup
        debug            => $args{debug} // 0,
        rate_limit_until => 0,  # Rate limiting support
        session          => $args{session},  # Session for statefulMarker
        broker_client    => $args{broker_client},  # Broker client for multi-agent rate limit coordination
        performance_monitor => CLIO::Core::PerformanceMonitor->new(debug => $args{debug} // 0),
        
        # Token estimation with adaptive learning
        learned_token_ratio => 2.5,  # Start with 2.5, learn from API responses
        
        %args,
    };
    bless $self, $class;
    
    # Initialize response handler for rate limiting, error handling, quota tracking
    $self->{response_handler} = CLIO::Core::API::ResponseHandler->new(
        session       => $args{session},
        broker_client => $args{broker_client},
        debug         => $args{debug} // 0,
    );
    
    # Initialize API key (check GitHub auth first, then config)

    $self->{api_key} = $self->_get_api_key();
    
    # Sync initial token ratio to the global TokenEstimator so ALL estimation
    # (MessageValidator, ConversationManager, etc.) uses the same ratio from the start.
    # Without this, TokenEstimator defaults to 4.0 chars/token while APIManager starts
    # at 2.5 - causing proactive trim to underestimate by ~40%.
    require CLIO::Memory::TokenEstimator;
    CLIO::Memory::TokenEstimator::set_learned_ratio($self->{learned_token_ratio});
    
    return $self;
}

=head2 set_session($session)

Set or change the session object for billing continuity tracking.

Arguments:
- $session: Session object (must support session_id accessor)

=cut

sub set_session {
    my ($self, $session) = @_;
    
    $self->{session} = $session;
    
    # Propagate to response handler
    if ($self->{response_handler}) {
        $self->{response_handler}->set_session($session);
    }
    
    # Clear the "warned once" flag so we log the first session association
    delete $self->{_warned_no_session_streaming};
    
    if ($self->{debug}) {
        my $sid = $session && $session->can('session_id') 
            ? $session->session_id 
            : (ref($session) eq 'HASH' ? $session->{session_id} : 'unknown');
        log_debug('APIManager', "Session set: $sid");
    }
    
    return 1;
}

=head2 refresh_api_key

Re-fetch the API key from the auth system. Called when:
- Token appears expired (401/403 from API)
- Copilot session token needs rotation (~30 min TTL)
- GitHub token has been re-authenticated

Returns: 1 if key was refreshed successfully, 0 if no new key available.

=cut

sub refresh_api_key {
    my ($self) = @_;
    
    my $old_key = $self->{api_key} || '';
    my $old_key_prefix = substr($old_key, 0, 10) . '...';
    
    log_info('APIManager', "Refreshing API key (current: $old_key_prefix)");
    
    my $new_key = $self->_get_api_key();
    
    if ($new_key && $new_key ne $old_key) {
        $self->{api_key} = $new_key;
        my $new_key_prefix = substr($new_key, 0, 10) . '...';
        log_info('APIManager', "API key refreshed successfully ($old_key_prefix -> $new_key_prefix)");
        return 1;
    }
    
    if ($new_key) {
        # Same key returned - no change needed but still valid
        log_debug('APIManager', "API key unchanged after refresh");
        return 1;
    }
    
    # No key available at all
    log_warning('APIManager', "API key refresh failed - no key available");
    return 0;
}

=head2 set_reauth_callback($callback)

Set a callback function that will be called when automatic re-authentication
is needed (e.g., GitHub token expired/revoked). The callback should initiate
the login flow and return 1 on success, 0 on failure.

Arguments:
- $callback: Code reference that handles re-authentication

=cut

sub set_reauth_callback {
    my ($self, $callback) = @_;
    $self->{reauth_callback} = $callback;
}

=head2 _attempt_token_recovery

Attempt to recover from an authentication failure:
1. Try refreshing the Copilot session token
2. Try force-refreshing via GitHubAuth
3. If all else fails, invoke the reauth callback (interactive login)

Returns: 1 if recovery succeeded, 0 if failed.

=cut

sub _attempt_token_recovery {
    my ($self) = @_;
    
    # Prevent re-entrant recovery attempts
    return 0 if $self->{_recovering_token};
    $self->{_recovering_token} = 1;
    
    log_info('APIManager', "Attempting token recovery after auth failure");
    
    # Step 1: Try a simple refresh (re-exchange existing GitHub token)
    if ($self->{api_base} && $self->{api_base} =~ /githubcopilot\.com/) {
        my $step1_success = 0;
        eval {
            require CLIO::Core::GitHubAuth;
            my $auth = CLIO::Core::GitHubAuth->new(debug => $self->{debug});
            
            my $fresh_token = $auth->force_refresh_copilot_token();
            if ($fresh_token) {
                $self->{api_key} = $fresh_token;
                $self->{using_exchanged_token} = $auth->{using_exchanged_token} || 0;
                log_info('APIManager', "Token recovery succeeded via Copilot refresh");
                $step1_success = 1;
            }
        };
        if ($step1_success) {
            $self->{_recovering_token} = 0;
            return 1;
        }
        # If force refresh failed, the GitHub token itself may be invalid
        if ($@) {
            log_warning('APIManager', "Copilot refresh failed: $@");
        }
        
        # Step 2: Validate the underlying GitHub token and try re-auth
        my $step2_success = 0;
        eval {
            require CLIO::Core::GitHubAuth;
            my $auth = CLIO::Core::GitHubAuth->new(debug => $self->{debug});
            my $validation = $auth->validate_github_token();
            
            if (!$validation->{valid}) {
                log_warning('APIManager', "GitHub token invalid: $validation->{error}");
                
                # GitHub token is bad - need full re-authentication
                if ($self->{reauth_callback}) {
                    log_info('APIManager', "Invoking re-authentication callback");
                    my $result = eval { $self->{reauth_callback}->() };
                    if ($result) {
                        # Callback succeeded - refresh our key
                        $self->{api_key} = $self->_get_api_key();
                        log_info('APIManager', "Token recovery succeeded via re-authentication");
                        $step2_success = 1;
                    }
                }
            }
        };
        if ($step2_success) {
            $self->{_recovering_token} = 0;
            return 1;
        }
    }
    
    # Step 3: Last resort - try generic key refresh
    my $refreshed = $self->refresh_api_key();
    $self->{_recovering_token} = 0;
    
    return $refreshed ? 1 : 0;
}

=head2 _get_api_key

Get API key with priority: GitHub Copilot token > Config api_key

No ENV variable fallback - config is the authority.

=cut

sub _get_api_key {
    my ($self) = @_;
    
    # Priority 1: Check for GitHub Copilot authentication
    if ($self->{api_base} && $self->{api_base} =~ /githubcopilot\.com/) {
        my $github_token;
        eval {
            require CLIO::Core::GitHubAuth;
            my $auth = CLIO::Core::GitHubAuth->new(debug => $self->{debug});
            
            # get_copilot_token() returns GitHub token if no Copilot token available
            $github_token = $auth->get_copilot_token();
            
            # Check if we're using an exchanged token (requires Editor-Version header)
            $self->{using_exchanged_token} = $auth->{using_exchanged_token} || 0;
        };
        
        if ($@) {
            log_warning('APIManager', "Failed to get GitHub token: $@");
            return '';
        }
        
        if ($github_token) {
            log_info('APIManager', "Using GitHub Copilot/GitHub token");
            return $github_token;
        }
        
        # GitHub Copilot provider requires GitHub authentication
        log_warning('APIManager', "GitHub Copilot not authenticated");
        return '';
    }
    
    # Priority 2: Config api_key (for non-GitHub Copilot providers)
    if ($self->{config} && $self->{config}->can('get')) {
        my $key = $self->{config}->get('api_key');
        if ($key && length($key) > 0) {
            log_debug('APIManager', "Using API key from Config");
            return $key;
        }
    }
    
    # No API key available - only warn if provider actually requires one
    my $provider = ($self->{config} && $self->{config}->can('get'))
        ? ($self->{config}->get('provider') || '') : '';
    if ($provider) {
        require CLIO::Providers;
        my $provider_def = CLIO::Providers::get_provider($provider);
        if ($provider_def && (!$provider_def->{requires_auth} || $provider_def->{requires_auth} eq 'none')) {
            log_debug('APIManager', "No API key set (provider '$provider' does not require auth)");
            return '';
        }
    }
    log_warning('APIManager', "No API key available (not set in config)");
    return '';
}

# Get current model - reads from Config (PUBLIC method)
sub get_current_model {
    my ($self) = @_;
    
    # Config is the authority
    if ($self->{config} && $self->{config}->can('get')) {
        my $model = $self->{config}->get('model');
        if ($model) {
            log_debug('APIManager', "Using model from Config: $model");
            return $model;
        }
    }
    
    # Fallback (should never happen if config is properly initialized)
    log_warning('APIManager', "No model in config, using default");
    require CLIO::Providers;
    return CLIO::Providers::DEFAULT_MODEL();
}

# Get current provider - reads from Config (PUBLIC method)
sub get_current_provider {
    my ($self) = @_;
    
    # Config is the authority
    if ($self->{config} && $self->{config}->can('get')) {
        my $provider = $self->{config}->get('provider');
        if ($provider) {
            log_debug('APIManager', "Using provider from Config: $provider");
            return $provider;
        }
    }
    
    # Fallback
    log_warning('APIManager', "No provider in config, using default");
    return 'openai';
}

# Endpoint-specific configuration
sub get_endpoint_config {
    my ($self) = @_;
    
    my $provider_name = $self->{config}->get('provider') || 'openai';
    
    require CLIO::Providers;
    return CLIO::Providers::build_endpoint_config($provider_name, $self->{api_key});
}

# Per-model proactive request throttle.
#
# Tracks request timestamps per model in a 60-second sliding window.
# When the count approaches the inferred rate limit, adds a pre-emptive delay
# to avoid hitting the rate limit in the first place.
#
# Limits are learned: when a rate limit fires, we record how many requests
# were in the window as the model's effective limit.

sub _model_throttle_record {
    my ($self, $model) = @_;
    return unless $model;

    $self->{_model_request_times} //= {};
    my $times = $self->{_model_request_times}{$model} //= [];

    # Prune entries older than 60 seconds
    my $now = time();
    @$times = grep { $_ > $now - 60 } @$times;

    push @$times, $now;
}

sub _model_throttle_learn {
    my ($self, $model, $count) = @_;
    return unless $model && $count && $count > 0;

    # Only lower the limit (never raise from a rate limit event - the actual limit
    # may be higher than what triggered this particular hit, but we know count-1
    # was acceptable and count was not)
    my $learned = $self->{_model_rate_limits}{$model};
    my $new_limit = ($count > 1) ? $count - 1 : 1;
    if (!defined $learned || $new_limit < $learned) {
        $self->{_model_rate_limits}{$model} = $new_limit;
        log_info('APIManager', "Learned rate limit for $model: $new_limit req/60s (was " . ($learned // 'unknown') . ")");
    }
}

sub report_rate_limit_for_model {
    my ($self, $model) = @_;
    $model ||= $self->get_current_model();
    return unless $model;
    my $times = $self->{_model_request_times}{$model} // [];
    my $now   = time();
    my $count = scalar grep { $_ > $now - 60 } @$times;
    $self->_model_throttle_learn($model, $count) if $count > 0;
}

sub _model_throttle_check {
    my ($self, $model) = @_;
    return 0 unless $model;
    return 0 if $self->{broker_client};  # Broker handles throttling centrally

    $self->{_model_request_times} //= {};
    $self->{_model_rate_limits}   //= {};

    my $times = $self->{_model_request_times}{$model} //= [];
    my $now   = time();

    # Prune to 60-second window
    @$times = grep { $_ > $now - 60 } @$times;

    my $count  = scalar @$times;
    my $limit  = $self->{_model_rate_limits}{$model};

    # No learned limit yet - no proactive throttle
    return 0 unless defined $limit && $limit > 0;

    # At 70%+ of inferred limit, add delay proportional to how close we are
    my $pct = $count / $limit;
    return 0 if $pct < 0.7;

    # Find oldest timestamp in window to estimate time-to-window-reset
    my $oldest = $times->[0] // $now;
    my $window_age = $now - $oldest;  # How old is the oldest request?
    my $window_remaining = 60 - $window_age;  # How many seconds until oldest expires?

    if ($pct >= 1.0) {
        # At or over limit - wait for the oldest request to fall out of the window
        return ($window_remaining > 0) ? $window_remaining + 1 : 2;
    }

    # 70-99%: add a proportional fractional delay to spread requests out
    # At 70%: ~1s delay. At 90%: ~3s. At 99%: spread over remaining window.
    my $spread_delay = ($pct - 0.7) / 0.3 * ($window_remaining / ($limit - $count + 1));
    $spread_delay = 1.0 if $spread_delay < 1.0;
    $spread_delay = 10.0 if $spread_delay > 10.0;
    return $spread_delay;
}

# Validate and adapt request parameters for specific endpoints
sub adapt_request_for_endpoint {
    my ($self, $payload, $endpoint_config) = @_;
    
    # Convert system messages to user messages for providers that don't support role=system
    # Flag: no_system_role in endpoint config
    if ($endpoint_config->{no_system_role} && $payload->{messages} && ref($payload->{messages}) eq 'ARRAY') {
        $payload->{messages} = _convert_system_to_user($payload->{messages});
    }
    
    # Clamp temperature to endpoint's supported range
    if (exists $payload->{temperature} && $endpoint_config->{temperature_range}) {
        my ($min_temp, $max_temp) = @{$endpoint_config->{temperature_range}};
        if ($payload->{temperature} < $min_temp) {
            $payload->{temperature} = $min_temp;
        } elsif ($payload->{temperature} > $max_temp) {
            $payload->{temperature} = $max_temp;
        }
    }
    
    # Remove tools if not supported
    if (!$endpoint_config->{supports_tools} && exists $payload->{tools}) {
        delete $payload->{tools};
        log_debug('APIManager', "Removed tools: endpoint doesn't support them");
    }
    
    # Per-model tool support check (more granular than provider-level)
    if (exists $payload->{tools} && $payload->{model}) {
        my $model = $payload->{model};
        my $caps = $self->{_model_capabilities_cache}{$model} if $self->{_model_capabilities_cache};
        if ($caps && defined $caps->{supports_tools} && !$caps->{supports_tools}) {
            delete $payload->{tools};
            log_info('APIManager', "Removed tools: model '$model' does not support function calling");
        }
    }
    
    # Add SAM config if required (for bypass_processing support)
    if ($endpoint_config->{requires_sam_config}) {
        $payload->{sam_config} = {
            bypass_processing => \1,  # JSON true via scalar reference
        };
        log_debug('APIManager', "Added sam_config with bypass_processing=true");
    }
    
    # Remove GitHub Copilot-specific fields for non-Copilot endpoints
    unless ($endpoint_config->{requires_copilot_headers}) {
        delete $payload->{copilot_thread_id};
        delete $payload->{previous_response_id};
    }
    
    # Add reasoning support for OpenRouter endpoints
    # Only enable when thinking display is on - reasoning tokens are charged as output tokens
    # Only for models known to support reasoning (deepseek-r1, qwq, etc.)
    # Adding reasoning to non-thinking models causes provider errors (e.g. Google Vertex AI)
    if ($endpoint_config->{openrouter}) {
        my $show_thinking = $self->{config} ? $self->{config}->get('show_thinking') : 0;
        if ($show_thinking && $payload->{model} && $self->_model_supports_reasoning($payload->{model})) {
            $payload->{reasoning} = { enabled => \1 };  # JSON true
        }
    }
    
    # Add reasoning_split for MiniMax to separate thinking into reasoning_details field
    if ($endpoint_config->{minimax}) {
        $payload->{reasoning_split} = \1;  # JSON true
        
        # Transform tool messages to MiniMax format
        # MiniMax requires tool results as: content => [{name, type, text}]
        # and assistant messages with tool_calls must have content => ""
        if ($payload->{messages} && ref($payload->{messages}) eq 'ARRAY') {
            $payload->{messages} = _transform_messages_for_minimax($payload->{messages});
        }
    }
    
    return $payload;
}
# Check if string ends with a valid partial <think> prefix.
# Only matches exact prefixes: <, <t, <th, <thi, <thin, <think
# Does NOT match arbitrary < followed by other characters (e.g. <a, <b, <div)
sub _has_partial_open_think_suffix {
    my ($text) = @_;
    return 0 unless length($text);
    return $text =~ /(?:<think|<thin|<thi|<th|<t|<)$/;
}

# Check if string ends with a valid partial </think> prefix.
# Only matches exact prefixes: <, </, </t, </th, </thi, </thin, </think
sub _has_partial_close_think_suffix {
    my ($text) = @_;
    return 0 unless length($text);
    return $text =~ /(?:<\/think|<\/thin|<\/thi|<\/th|<\/t|<\/|<)$/;
}


# Convert role=system messages to role=user for providers that don't support system role.
# The first system message (system prompt) gets a [System Instructions] wrapper.
# Mid-conversation system messages (error recovery, context summaries) get [System Note].
# Also merges resulting consecutive user messages to maintain alternation.
sub _convert_system_to_user {
    my ($messages) = @_;
    return $messages unless $messages && @$messages;

    my $seen_system = 0;
    my @result;
    for my $msg (@$messages) {
        if ($msg->{role} eq 'system') {
            my $prefix = $seen_system ? '[System Note]' : '[System Instructions]';
            $seen_system++;
            my $converted = {
                role => 'user',
                content => "$prefix\n$msg->{content}",
            };
            # Merge into previous user message if consecutive
            if (@result && $result[-1]{role} eq 'user' && !$result[-1]{tool_call_id}) {
                $result[-1]{content} .= "\n\n$converted->{content}";
            } else {
                push @result, $converted;
            }
        } else {
            push @result, $msg;
        }
    }

    log_debug('APIManager', "Converted $seen_system system message(s) to user role (no_system_role)");
    return \@result;
}

# Transform messages to MiniMax-compatible format
# MiniMax requires different tool message formatting:
# - Tool results: content is array of [{name => "func", type => "text", text => "result"}]
# - Assistant with tool_calls: content must be "" (empty string, not undef)
sub _transform_messages_for_minimax {
    my ($messages) = @_;
    
    # First pass: collect tool_call_id -> function_name mappings
    my %tc_id_to_name;
    for my $msg (@$messages) {
        next unless $msg->{role} eq 'assistant' && $msg->{tool_calls};
        for my $tc (@{$msg->{tool_calls}}) {
            $tc_id_to_name{$tc->{id}} = $tc->{function}{name} if $tc->{id};
        }
    }
    
    # Second pass: transform messages
    my @result;
    for my $msg (@$messages) {
        if ($msg->{role} eq 'tool') {
            # MiniMax tool message format: content is array of {name, type, text}
            my $func_name = 'unknown';
            if ($msg->{tool_call_id} && $tc_id_to_name{$msg->{tool_call_id}}) {
                $func_name = $tc_id_to_name{$msg->{tool_call_id}};
            }
            
            push @result, {
                role => 'tool',
                tool_call_id => $msg->{tool_call_id} // '',
                content => [{
                    name => $func_name,
                    type => 'text',
                    text => $msg->{content} // '',
                }],
            };
        }
        elsif ($msg->{role} eq 'assistant' && $msg->{tool_calls} && @{$msg->{tool_calls}}) {
            # Assistant with tool_calls: ensure content is empty string
            my %transformed = %$msg;
            $transformed{content} = '';
            push @result, \%transformed;
        }
        else {
            push @result, $msg;
        }
    }
    
    return \@result;
}

=head2 get_model_capabilities

Get model capabilities (token limits) from the models API.
Caches result to avoid repeated API calls.

Returns:
- Hashref with: max_prompt_tokens, max_output_tokens, max_context_window_tokens
- Returns undef if unable to fetch or model not found

=cut

sub model_supports_tools {
    my ($self, $model) = @_;
    $model ||= $self->get_current_model();
    
    # Check cached capabilities first
    if ($self->{_model_capabilities_cache} && $self->{_model_capabilities_cache}{$model}) {
        my $caps = $self->{_model_capabilities_cache}{$model};
        return $caps->{supports_tools} if defined $caps->{supports_tools};
    }
    
    # Fetch capabilities (will populate cache)
    my $caps = $self->get_model_capabilities($model);
    if ($caps && defined $caps->{supports_tools}) {
        return $caps->{supports_tools};
    }
    
    # Default: assume tools are supported (don't break existing behavior)
    return 1;
}

sub get_model_capabilities {
    my ($self, $model) = @_;
    
    $model ||= $self->get_current_model();
    
    # Parse provider prefix from model name
    my ($target_provider, $api_model) = $self->_parse_model_provider($model);
    
    # Check cache first (cache by full model name including provider prefix)
    if ($self->{_model_capabilities_cache} && 
        $self->{_model_capabilities_cache}{$model}) {
        return $self->{_model_capabilities_cache}{$model};
    }
    
    # Determine API base for the model's provider
    my $api_base;
    if ($target_provider) {
        my $current_provider = $self->{config} ? ($self->{config}->get('provider') || '') : '';
        if ($target_provider eq $current_provider) {
            # Same provider as currently configured - use user's api_base (may be overridden)
            $api_base = $self->{api_base};
        } else {
            # Different provider - look up its default api_base
            require CLIO::Providers;
            my $provider_def = CLIO::Providers::get_provider($target_provider);
            $api_base = $provider_def ? $provider_def->{api_base} : $self->{api_base};
        }
    } else {
        $api_base = $self->{api_base};
    }
    
    # Detect API type and models endpoint
    my ($api_type, $models_url) = $self->_detect_api_type_and_url($api_base);
    
    unless ($models_url) {
        log_debug('APIManager', "Unable to determine models endpoint for: $api_base (using fallback token limits)");
        return undef;
    }
    
    # For GitHub Copilot, use GitHubCopilotModelsAPI which includes supplementary models
    my $models = [];
    if ($api_type eq 'github-copilot') {
        eval {
            require CLIO::Core::GitHubCopilotModelsAPI;
            my $copilot_api = CLIO::Core::GitHubCopilotModelsAPI->new(
                api_key => $self->{api_key},
                debug => $self->{debug}
            );
            $models = $copilot_api->get_all_models() || [];
        };
        if ($@) {
            log_warning('APIManager', "GitHubCopilotModelsAPI failed: $@");
            # Fall through to direct API fetch
            $models = [];
        }
    }
    
    # If we didn't get models from GitHubCopilotModelsAPI, fetch directly
    unless (@$models) {
        my $ua = CLIO::Compat::HTTP->new(timeout => 30);
        my %headers = (
            'Authorization' => "Bearer $self->{api_key}",
        );
        $headers{'Editor-Version'} = 'CLIO/1.0' if $api_type eq 'github-copilot';
        
        # Google native models endpoint uses API key as URL parameter
        if ($api_type eq 'google') {
            $models_url .= "?key=$self->{api_key}";
            delete $headers{'Authorization'};
        }
        
        my $resp = $ua->get($models_url, headers => \%headers);
        
        unless ($resp->is_success) {
            # For local/generic providers, use provider-level fallback silently
            my $effective_provider = $target_provider || ($self->{config} ? ($self->{config}->get('provider') || '') : '');
            if ($effective_provider) {
                require CLIO::Providers;
                my $pdef = CLIO::Providers::get_provider($effective_provider);
                if ($pdef && $pdef->{max_context_tokens}) {
                    my $ctx = $pdef->{max_context_tokens};
                    my $capabilities = {
                        max_prompt_tokens          => $ctx,
                        max_output_tokens          => $pdef->{max_output_tokens} || 4096,
                        max_context_window_tokens  => $ctx,
                    };
                    $self->{_model_capabilities_cache} ||= {};
                    $self->{_model_capabilities_cache}{$model} = $capabilities;
                    log_debug('APIManager', "Using provider fallback for $model: context=$ctx (models endpoint unavailable)");
                    return $capabilities;
                }
            }
            log_info('APIManager', "Models endpoint unavailable ($models_url), using fallback token limits");
            return undef;
        }
        
        my $data = eval { decode_json($resp->decoded_content) };
        if ($@) {
            if (should_log('WARNING')) {
                log_warning('APIManager', "Failed to parse models response from $models_url");
                log_warning('APIManager', "JSON error: $@");
            }
            return undef;
        }
        
        # Google native API returns { models: [{name: "models/gemini-2.5-flash", ...}] }
        # OpenAI-compatible APIs return { data: [{id: "model-name", ...}] }
        if ($api_type eq 'google' && $data->{models}) {
            # Normalize Google format to OpenAI format
            $models = [ map {
                my $name = $_->{name} || '';
                $name =~ s{^models/}{};  # Strip "models/" prefix
                {
                    id => $name,
                    context_window => $_->{inputTokenLimit},
                    max_completion_tokens => $_->{outputTokenLimit},
                    %$_,
                }
            } @{$data->{models}} ];
        } else {
            $models = $data->{data} || [];
        }
    }
    
    # Find our model (use api_model name without CLIO provider prefix)
    for my $model_info (@$models) {
        if ($model_info->{id} eq $api_model) {
            my $limits = {};
            
            # Extract limits from capabilities (GitHub Copilot format)
            if ($model_info->{capabilities} && $model_info->{capabilities}{limits}) {
                $limits = $model_info->{capabilities}{limits};
            }
            
            # Determine fallback limits based on API type
            my $fallback_context;
            if ($api_type =~ /^(sam|lmstudio|llama\.cpp)$/i) {
                # Local models: smaller context to avoid OOM
                $fallback_context = 32000;
            } else {
                # Cloud models: modern LLMs typically have 128k+
                $fallback_context = 128000;
            }
            
            # Look up provider-level max_output_tokens for fallback
            my $provider_max_output;
            my $effective_provider = $target_provider || ($self->{config} ? ($self->{config}->get('provider') || '') : '');
            if ($effective_provider) {
                require CLIO::Providers;
                my $pdef = CLIO::Providers::get_provider($effective_provider);
                $provider_max_output = $pdef->{max_output_tokens} if $pdef;
            }
            
            # Build normalized capabilities hash
            # Priority: root-level fields (SAM/OpenAI), then capabilities.limits (GitHub Copilot), then provider-specific defaults
            my $capabilities = {
                max_prompt_tokens => $model_info->{max_request_tokens} ||
                                     $limits->{max_prompt_tokens} ||
                                     $limits->{max_context_window_tokens} ||
                                     $model_info->{context_window} ||
                                     $fallback_context,
                max_output_tokens => $model_info->{max_completion_tokens} ||
                                     $limits->{max_output_tokens} ||
                                     $limits->{max_completion_tokens} ||
                                     $provider_max_output ||
                                     4096,  # Default fallback
                max_context_window_tokens => $model_info->{context_window} ||
                                              $limits->{max_context_window_tokens} ||
                                              $limits->{context_window} ||
                                              $fallback_context,
            };
            
            # Extract per-model tool support (GitHub Copilot provides this)
            if ($model_info->{capabilities} && $model_info->{capabilities}{supports}) {
                $capabilities->{supports_tools} = $model_info->{capabilities}{supports}{tool_calls} ? 1 : 0;
            }
            
            # Google models: check supportedGenerationMethods
            if ($api_type eq 'google' && $model_info->{supportedGenerationMethods}) {
                my @methods = @{$model_info->{supportedGenerationMethods}};
                $capabilities->{supports_tools} = (grep { $_ eq 'generateContent' } @methods) ? 1 : 0;
            }
            
            # OpenRouter models: check supported_parameters for reasoning support
            if ($model_info->{supported_parameters} && ref($model_info->{supported_parameters}) eq 'ARRAY') {
                $capabilities->{supports_reasoning} = (grep { $_ eq 'reasoning' } @{$model_info->{supported_parameters}}) ? 1 : 0;
            }
            
            # Cache the result
            $self->{_model_capabilities_cache} ||= {};
            $self->{_model_capabilities_cache}{$model} = $capabilities;
            
            log_debug('APIManager', "Model capabilities for $model: " . "max_prompt=" . $capabilities->{max_prompt_tokens} . ", " .
                "max_output=" . $capabilities->{max_output_tokens} . "\n");
            
            return $capabilities;
        }
    }
    
    log_debug('APIManager', "Model $api_model not found in /models response (using fallback token limits)");
    return undef;
}

=head2 _detect_api_type_and_url

Internal method to detect API type and models URL from base URL

=cut

sub _detect_api_type_and_url {
    my ($self, $api_base) = @_;
    
    # Map of logical names to (type, models_url)
    my %api_configs = (
        'github-copilot' => ['github-copilot', 'https://api.githubcopilot.com/models'],
        'openai'         => ['openai', 'https://api.openai.com/v1/models'],
        'dashscope-cn'   => ['dashscope', 'https://dashscope.aliyuncs.com/compatible-mode/v1/models'],
        'dashscope-intl' => ['dashscope', 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models'],
        'sam'            => ['sam', 'http://localhost:8080/v1/models'],
        'lmstudio'       => ['lmstudio', 'http://localhost:1234/v1/models'],
        'openrouter'     => ['openrouter', 'https://openrouter.ai/api/v1/models'],
    );
    
    # Check if it's a known logical name
    if (exists $api_configs{$api_base}) {
        return @{$api_configs{$api_base}};
    }
    
    # Try to detect from URL pattern
    if ($api_base =~ m{githubcopilot\.com}i) {
        return ('github-copilot', 'https://api.githubcopilot.com/models');
    } elsif ($api_base =~ m{openai\.com}i) {
        return ('openai', 'https://api.openai.com/v1/models');
    } elsif ($api_base =~ m{generativelanguage\.googleapis\.com}i) {
        # Google Gemini: models endpoint uses the native API format with API key as URL param
        return ('google', 'https://generativelanguage.googleapis.com/v1beta/models');
    } elsif ($api_base =~ m{openrouter\.ai}i) {
        return ('openrouter', 'https://openrouter.ai/api/v1/models');
    } elsif ($api_base =~ m{api\.minimax\.io}i) {
        return ('minimax', 'https://api.minimax.io/v1/models');
    } elsif ($api_base =~ m{localhost:1234}i || $api_base =~ m{127\.0\.0\.1:1234}i) {
        # LM Studio running locally
        return ('lmstudio', 'http://localhost:1234/v1/models');
    } elsif ($api_base =~ m{localhost:8080}i || $api_base =~ m{127\.0\.0\.1:8080}i) {
        # SAM or llama.cpp running locally
        return ('sam', 'http://localhost:8080/v1/models');
    } elsif ($api_base =~ m{dashscope.*\.aliyuncs\.com}i) {
        my $base_url = $api_base;
        $base_url =~ s{/+$}{};
        $base_url =~ s{/compatible-mode/v1.*$}{};
        return ('dashscope', "$base_url/compatible-mode/v1/models");
    }
    
    # Generic OpenAI-compatible API
    if ($api_base =~ m{^https?://}) {
        my $models_url = $api_base;
        $models_url =~ s{/+$}{};
        # Strip known chat/completions suffixes to get the base
        $models_url =~ s{/chat/completions$}{};
        $models_url =~ s{/completions$}{};
        if ($models_url =~ m{/v1$}) {
            $models_url .= "/models";
        } elsif ($models_url !~ m{/models$}) {
            $models_url .= "/models";
        }
        return ('generic', $models_url);
    }
    
    return (undef, undef);
}

=head2 validate_and_truncate_messages

Validates messages and truncates to fit within model token limits.
Delegates to CLIO::Core::API::MessageValidator.

=cut

sub validate_and_truncate_messages {
    my ($self, $messages, $model, $tools) = @_;
    
    $model ||= $self->get_current_model();
    my $caps = $self->get_model_capabilities($model);
    
    return validate_and_truncate(
        messages           => $messages,
        model_capabilities => $caps,
        tools              => $tools,
        token_ratio        => $self->{learned_token_ratio},
        config             => $self->{config},
        api_base           => $self->{api_base},
        debug              => $self->{debug},
        model              => $model,
    );
}

=head2 get_last_trimmed_messages

Returns the messages array from the most recent proactive trim, or undef
if no trimming occurred on the last API call. Used by WorkflowOrchestrator
to sync its @messages array with the trimmed version, preventing unbounded
growth that leads to aggressive reactive trimming.

=cut

sub get_last_trimmed_messages {
    my ($self) = @_;
    return $self->{_last_trimmed_messages};
}

=head2 _validate_tool_message_pairs

Validates tool call/result pairing. Delegates to MessageValidator.

=cut

sub _validate_tool_message_pairs {
    my ($self, $messages) = @_;
    return validate_tool_message_pairs($messages);
}

=head2 _preflight_validate_messages

Lightweight pre-flight validation. Delegates to MessageValidator.

=cut

sub _preflight_validate_messages {
    my ($self, $messages) = @_;
    return preflight_validate($messages);
}


sub _learn_from_api_response {
    my ($self, $usage, $messages) = @_;
    
    return unless $usage && $messages;
    return unless $usage->{prompt_tokens};
    
    my $actual_tokens = $usage->{prompt_tokens};
    
    # Calculate total character count of messages
    my $total_chars = 0;
    for my $msg (@$messages) {
        $total_chars += length($msg->{content} || '');
        
        # Include tool_calls size
        if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                my $json = encode_json($tc);
                $total_chars += length($json);
            }
        }
    }
    
    return if $total_chars == 0;  # Avoid division by zero
    
    # Calculate actual char/token ratio from this response
    my $actual_ratio = $total_chars / $actual_tokens;
    
    # Weighted average: 80% old ratio + 20% new observation
    # This smooths out variance while still adapting to patterns
    my $old_ratio = $self->{learned_token_ratio};
    my $new_ratio = ($old_ratio * 0.8) + ($actual_ratio * 0.2);
    
    # Clamp ratio to reasonable bounds (1.5 to 4.0)
    # Prevents outliers from skewing too far
    $new_ratio = 1.5 if $new_ratio < 1.5;
    $new_ratio = 4.0 if $new_ratio > 4.0;
    
    if ($self->{debug}) {
        printf STDERR "[DEBUG][APIManager] Token learning: actual=%d, chars=%d, ratio=%.2f, old_learned=%.2f, new_learned=%.2f\n",
            $actual_tokens, $total_chars, $actual_ratio, $old_ratio, $new_ratio;
    }
    
    $self->{learned_token_ratio} = $new_ratio;
    
    # Propagate learned ratio to TokenEstimator so ALL token estimation
    # across the codebase (ConversationManager trim, State trim, etc.)
    # benefits from the API feedback, not just MessageValidator
    require CLIO::Memory::TokenEstimator;
    CLIO::Memory::TokenEstimator::set_learned_ratio($new_ratio);
    
    return $new_ratio;
}

=head2 _model_uses_responses_api($model)

Check if a model should use the OpenAI Responses API (/responses) instead of
Chat Completions API (/chat/completions).

Uses the supported_endpoints data from the GitHub Copilot /models API.
Results are cached for efficiency.

Returns 1 if model uses Responses API, 0 otherwise.

=cut

sub _model_uses_responses_api {
    my ($self, $model) = @_;
    return 0 unless $model;
    
    # Only applies to GitHub Copilot provider
    my $provider = $self->{config} ? $self->{config}->get('provider') : '';
    return 0 unless $provider && $provider eq 'github_copilot';
    
    # Cache the result per model to avoid repeated API lookups
    $self->{_responses_api_cache} ||= {};
    if (exists $self->{_responses_api_cache}{$model}) {
        return $self->{_responses_api_cache}{$model};
    }
    
    my $result = 0;
    eval {
        require CLIO::Core::GitHubCopilotModelsAPI;
        # Cache the models API instance for efficiency
        $self->{_copilot_models_api} ||= CLIO::Core::GitHubCopilotModelsAPI->new(
            api_key => $self->{api_key},
            debug => $self->{debug}
        );
        $result = $self->{_copilot_models_api}->model_uses_responses_api($model) ? 1 : 0;
    };
    if ($@) {
        log_warning('APIManager', "Failed to check Responses API support for $model: $@");
        $result = 0;
    }
    
    $self->{_responses_api_cache}{$model} = $result;
    log_debug('APIManager', "Model $model uses " . ($result ? "Responses" : "Chat Completions") . " API");
    return $result;
}

# Get max output tokens for a model from capabilities, with sensible fallback
sub _get_max_output_tokens {
    my ($self, $model) = @_;
    my $caps = $self->get_model_capabilities($model);
    my $max = ($caps && $caps->{max_output_tokens}) ? $caps->{max_output_tokens} : 16384;
    # Enforce a minimum of 32768 to avoid unusably low limits
    return $max < 32768 ? 32768 : $max;
}

=head2 _build_responses_api_payload($messages, $model, $endpoint_config, %opts)

Build a payload for the OpenAI Responses API format.
This is fundamentally different from the Chat Completions API:
- Uses 'input' array instead of 'messages'
- System messages become role 'developer'
- Tool results use 'function_call_output' type
- Assistant tool calls use 'function_call' type
- Uses max_output_tokens instead of max_tokens
- Includes reasoning, truncation, store, include fields

=cut

sub _build_responses_api_payload {
    my ($self, $messages, $model, $endpoint_config, %opts) = @_;
    
    my $stream = $opts{stream} || 0;
    
    # Convert messages to Responses API input format
    my @input = ();
    my @pending_tool_calls = ();
    
    for my $msg (@$messages) {
        my $role = $msg->{role} || 'user';
        my $content = $msg->{content} || '';
        
        if ($role eq 'system') {
            # System messages become developer role in Responses API
            push @input, {
                role => 'developer',
                content => [{ type => 'input_text', text => $content }],
            };
        }
        elsif ($role eq 'user') {
            push @input, {
                role => 'user',
                content => [{ type => 'input_text', text => $content }],
            };
        }
        elsif ($role eq 'assistant') {
            # Flush any pending tool calls first
            if (@pending_tool_calls) {
                for my $tc (@pending_tool_calls) {
                    push @input, {
                        type => 'function_call',
                        name => $tc->{function}{name},
                        arguments => $tc->{function}{arguments} || '{}',
                        call_id => $tc->{id},
                    };
                }
                @pending_tool_calls = ();
            }
            
            # If assistant message has tool_calls, queue them
            if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                @pending_tool_calls = @{$msg->{tool_calls}};
                
                # Also add the text content if present
                if (defined $content && length($content)) {
                    push @input, {
                        role => 'assistant',
                        content => [{ type => 'output_text', text => $content, annotations => [] }],
                        id => 'msg_placeholder',
                        status => 'completed',
                        type => 'message',
                    };
                }
            }
            else {
                # Plain assistant text message
                if (defined $content && length($content)) {
                    push @input, {
                        role => 'assistant',
                        content => [{ type => 'output_text', text => $content, annotations => [] }],
                        id => 'msg_placeholder',
                        status => 'completed',
                        type => 'message',
                    };
                }
            }
        }
        elsif ($role eq 'tool') {
            # Flush pending tool calls before tool result
            if (@pending_tool_calls) {
                for my $tc (@pending_tool_calls) {
                    push @input, {
                        type => 'function_call',
                        name => $tc->{function}{name},
                        arguments => $tc->{function}{arguments} || '{}',
                        call_id => $tc->{id},
                    };
                }
                @pending_tool_calls = ();
            }
            
            # Tool results become function_call_output
            push @input, {
                type => 'function_call_output',
                call_id => $msg->{tool_call_id} || '',
                output => $content,
            };
        }
    }
    
    # Flush any remaining pending tool calls
    if (@pending_tool_calls) {
        for my $tc (@pending_tool_calls) {
            push @input, {
                type => 'function_call',
                name => $tc->{function}{name},
                arguments => $tc->{function}{arguments} || '{}',
                call_id => $tc->{id},
            };
        }
    }
    
    # Build the Responses API payload
    my $payload = {
        model => $model,
        input => \@input,
        stream => $stream ? \1 : \0,
        max_output_tokens => $opts{max_output_tokens} || $self->_get_max_output_tokens($model),
        store => \0,
        truncation => 'disabled',
        include => ['reasoning.encrypted_content'],
    };
    
    # Configure reasoning - only for models that support it
    # ResponseHandler flags _no_reasoning when model rejects reasoning params
    if (!$self->{response_handler}{_no_reasoning}) {
        my $show_thinking = $self->{config} ? $self->{config}->get('show_thinking') : 0;
        my $reasoning_config = { effort => 'medium' };
        if ($show_thinking) {
            $reasoning_config->{summary} = 'auto';
        }
        $payload->{reasoning} = $reasoning_config;
    }
    
    # Add tools if provided - convert to Responses API format
    if ($opts{tools} && ref($opts{tools}) eq 'ARRAY' && @{$opts{tools}}) {
        my @resp_tools = ();
        for my $tool (@{$opts{tools}}) {
            if ($tool->{type} eq 'function') {
                push @resp_tools, {
                    type => 'function',
                    name => $tool->{function}{name},
                    description => $tool->{function}{description},
                    strict => \0,
                    parameters => $tool->{function}{parameters} || {},
                };
            }
        }
        $payload->{tools} = \@resp_tools if @resp_tools;
        log_debug('APIManager', "Responses API: Adding " . scalar(@resp_tools) . " tools");
    }
    
    # Responses API uses previous_response_id from the stateful marker (response.id)
    # This enables billing continuity - subsequent turns in same conversation are not re-charged
    # Skip if model has rejected previous_response_id (flagged by ResponseHandler)
    if (!$self->{response_handler}{_no_previous_response_id}) {
        my $prev_resp_id = $self->{response_handler}->get_stateful_marker_for_model($model);
        if (!$prev_resp_id && $self->{session} && $self->{session}{lastGitHubCopilotResponseId}) {
            $prev_resp_id = $self->{session}{lastGitHubCopilotResponseId};
        }
        if ($prev_resp_id) {
            $payload->{previous_response_id} = $prev_resp_id;
            log_debug('APIManager', "Responses API: previous_response_id=" . substr($prev_resp_id, 0, 30) . "...");
        }
    }
    
    # Sanitize the payload
    $payload = _sanitize_payload_recursive($payload);
    
    log_debug('APIManager', "Responses API payload: model=$model, input_items=" . scalar(@input) . ", stream=$stream");
    
    return $payload;
}

# Helper: Prepare endpoint configuration and model
sub _prepare_endpoint_config {
    my ($self, %opts) = @_;
    
    my $model = $opts{model} // $self->get_current_model();
    
    # Parse provider prefix from model name (e.g., "github_copilot/gpt-4.1")
    my ($target_provider, $api_model) = $self->_parse_model_provider($model);
    
    my $endpoint_config;
    my $endpoint;
    
    if ($target_provider && $target_provider ne ($self->{config}->get('provider') || '')) {
        # Model specifies a different provider - resolve its config
        $endpoint_config = $self->_get_endpoint_config_for_provider($target_provider);
        
        require CLIO::Providers;
        my $provider_def = CLIO::Providers::get_provider($target_provider);
        $endpoint = $provider_def ? $provider_def->{api_base} : $self->{api_base};
    } else {
        # Use current provider config
        $endpoint_config = $self->get_endpoint_config();
        $endpoint = $self->{api_base};
    }
    
    return {
        config => $endpoint_config,
        endpoint => $endpoint,
        model => $api_model,
    };
}

=head2 _parse_model_provider($model)

Parse provider prefix from a model name.

Handles formats:
  - "github_copilot/gpt-4.1" -> ("github_copilot", "gpt-4.1")
  - "openrouter/deepseek/deepseek-r1" -> ("openrouter", "deepseek/deepseek-r1")
  - "gpt-4.1" -> (undef, "gpt-4.1")

Returns: ($provider, $api_model_name)

=cut

sub _parse_model_provider {
    my ($self, $model) = @_;
    
    return (undef, $model) unless $model;
    
    # Check if model starts with a known CLIO provider name
    require CLIO::Providers;
    
    if ($model =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i) {
        my ($prefix, $rest) = ($1, $2);
        
        if (CLIO::Providers::provider_exists($prefix)) {
            return ($prefix, $rest);
        }
    }
    
    # No explicit provider prefix - try to detect from model name
    my $detected = CLIO::Providers::detect_provider_for_model($model);
    return ($detected, $model) if $detected;
    
    # No provider detected - use current provider
    return (undef, $model);
}

=head2 _get_endpoint_config_for_provider($provider_name)

Get endpoint configuration for a specific provider (used for cross-provider routing).

=cut

sub _get_endpoint_config_for_provider {
    my ($self, $provider_name) = @_;
    
    # Resolve API key for the target provider
    my $api_key = $self->{config}->get_provider_key($provider_name);
    
    # For github_copilot, use OAuth token
    if ($provider_name eq 'github_copilot' && !$api_key) {
        eval {
            require CLIO::Core::GitHubAuth;
            my $auth = CLIO::Core::GitHubAuth->new(debug => $self->{debug});
            $api_key = $auth->get_copilot_token();
            # Track if using exchanged token for header requirements
            $self->{using_exchanged_token} = $auth->{using_exchanged_token};
        };
    }
    
    $api_key ||= '';
    
    require CLIO::Providers;
    return CLIO::Providers::build_endpoint_config($provider_name, $api_key);
}

# Helper: Prepare and trim messages
sub _prepare_messages {
    my ($self, $input, %opts) = @_;
    
    # Accept messages array override
    my $messages = $opts{messages};
    if (!$messages) {
        $messages = [ { role => 'user', content => $input } ];
    }
    
    # Trim message content (GitHub Copilot requirement)
    if ($messages && ref($messages) eq 'ARRAY') {
        for my $msg (@$messages) {
            if ($msg->{content}) {
                $msg->{content} =~ s/\s+$//;  # Remove trailing whitespace
            }
        }
    }
    
    return $messages;
}

# Helper: Build request payload
sub _build_payload {
    my ($self, $messages, $model, $endpoint_config, %opts) = @_;
    
    # Extract stream parameter (default false for non-streaming)
    my $stream = $opts{stream} || 0;
    
    # Determine max_tokens from capabilities or provider config
    my $max_tokens = $opts{max_tokens} || $self->_get_max_output_tokens($model);
    
    # Build base payload
    my $payload = {
        model => $model,
        messages => $messages,
        temperature => $opts{temperature} // 0.2,
        top_p => $opts{top_p} // 0.95,
        max_tokens => $max_tokens,
    };
    
    # Add stream flag if streaming
    if ($stream) {
        $payload->{stream} = \1;  # JSON true
        $payload->{stream_options} = { include_usage => \1 };
    }
    
    # Save currently used model to session for persistence
    # Use the full prefixed model (e.g., "minimax/MiniMax-M2.7") so that
    # --resume correctly routes to the right provider, not the stripped
    # API model name which loses the provider prefix.
    my $full_model = $self->get_current_model() || $model;
    if ($self->{session} && (!$self->{session}{selected_model} || $self->{session}{selected_model} ne $full_model)) {
        $self->{session}{selected_model} = $full_model;
        log_debug('APIManager', "Saving model to session: $full_model");
    }
    
    # Add copilot_thread_id for session continuity (GitHub Copilot requirement)
    if ($self->{session} && $self->{session}{session_id}) {
        $payload->{copilot_thread_id} = $self->{session}{session_id};
        log_debug('APIManager', "Including copilot_thread_id: $payload->{copilot_thread_id}");
    } else {
        log_warning('APIManager', "NO copilot_thread_id - session will be treated as NEW (charges premium quota!)");
        log_debug('APIManager', "session=" . (defined $self->{session} ? "defined" : "undef") .
                     ", session_id=" . (defined $self->{session}{session_id} ? $self->{session}{session_id} : "undef"));
    }
    
    # Add previous_response_id for GitHub Copilot billing continuity
    # Skip if model has rejected previous_response_id (flagged by ResponseHandler)
    if (!$self->{response_handler}{_no_previous_response_id}) {
        my $previous_response_id = $self->{response_handler}->get_stateful_marker_for_model($model);
        
        if ($previous_response_id) {
            $payload->{previous_response_id} = $previous_response_id;
            log_debug('APIManager', "Including previous_response_id (stateful_marker): " . substr($previous_response_id, 0, 20) . "...");
        } else {
            # FALLBACK: Try old lastGitHubCopilotResponseId if stateful_marker not found
            if ($self->{session} && $self->{session}{lastGitHubCopilotResponseId}) {
                $previous_response_id = $self->{session}{lastGitHubCopilotResponseId};
                $payload->{previous_response_id} = $previous_response_id;
                log_debug('APIManager', "Using response_id (lastGitHubCopilotResponseId): " . substr($previous_response_id, 0, 30) . "...");
            } else {
                # Only warn if this is NOT the first request AND we have no fallback
                my $is_first_request = scalar(grep { $_->{role} ne 'system' } @$messages) <= 1;
                if (!$is_first_request) {
                    log_warning('APIManager', "NO previous_response_id on turn 2+ - this will be charged as NEW request");
                    log_debug('APIManager', "FALLBACK not available: session=" . (defined $self->{session} ? "defined" : "undef") .
                                 ", lastGitHubCopilotResponseId=" .
                                 (defined $self->{session}{lastGitHubCopilotResponseId} ? $self->{session}{lastGitHubCopilotResponseId} : "undef") . "\n");
                }
            }
        }
    }
    # Add tools if provided
    if ($opts{tools} && ref($opts{tools}) eq 'ARRAY' && @{$opts{tools}}) {
        $payload->{tools} = $opts{tools};
        log_debug('APIManager', "Adding " . scalar(@{$opts{tools}}) . " tools to request");
    }
    
    # Adapt payload for specific endpoint
    $payload = $self->adapt_request_for_endpoint($payload, $endpoint_config);
    
    # Sanitize entire payload to remove problematic UTF-8 characters
    $payload = _sanitize_payload_recursive($payload);
    
    # Log session continuity fields for billing tracking
    if ($self->{debug}) {
        log_debug('APIManager', "BILLING CONTINUITY CHECK:");
        log_debug('APIManager', "copilot_thread_id: " . ($payload->{copilot_thread_id} || "NOT SET"));
        log_debug('APIManager', "previous_response_id: " . ($payload->{previous_response_id} || "NOT SET"));
        if (!$payload->{previous_response_id}) {
            log_debug('APIManager', "session ref: " . (ref($self->{session}) || "NOT AN OBJECT"));
            log_debug('APIManager', "lastGitHubCopilotResponseId: " . ($self->{session} ? ($self->{session}{lastGitHubCopilotResponseId} || "NOT SET") : "NO SESSION"));
        }
    }
    
    # DEBUG: Log last few messages
    if ($self->{debug} && $payload->{messages}) {
        my $msg_count = scalar(@{$payload->{messages}});
        my $stream_label = $stream ? "Streaming" : "Non-streaming";
        log_debug('APIManager', "$stream_label: Sending $msg_count messages");
        my $start = $msg_count > 4 ? $msg_count - 4 : 0;
        for (my $i = $start; $i < $msg_count; $i++) {
            my $msg = $payload->{messages}[$i];
            my $preview = substr($msg->{content} || '', 0, 60);
            $preview =~ s/\n/ /g;
            log_debug('APIManager', sprintf("  [%d] %s: %s%s",
                $i, $msg->{role}, $preview,
                (length($msg->{content} || '') > 60 ? '...' : '')));
            if ($msg->{tool_calls}) {
                log_debug('APIManager', sprintf("       HAS %d tool_calls", scalar(@{$msg->{tool_calls}})));
            }
            if ($msg->{tool_call_id}) {
                log_debug('APIManager', sprintf("       tool_call_id=%s", substr($msg->{tool_call_id}, 0, 20)));
            }
        }
    }
    
    return $payload;
}

# Helper: Build HTTP request with headers
sub _build_request {
    my ($self, $endpoint, $endpoint_config, $json, $is_streaming, $opts) = @_;
    $opts ||= {};
    
    # Construct final endpoint URL
    my $final_endpoint = $endpoint;
    
    # GitHub Copilot: Route to correct API endpoint based on model capabilities
    if ($endpoint_config->{requires_copilot_headers}) {
        # Check if model uses Responses API (codex models, etc.)
        my $use_responses = $self->{_current_request_uses_responses} || 0;
        my $path = $use_responses ? '/responses' : '/chat/completions';
        $final_endpoint =~ s{/$}{};
        $final_endpoint .= $path;
        
        if ($self->{debug}) {
            my $stream_label = $is_streaming ? "streaming" : "non-streaming";
            my $api_type = $use_responses ? "Responses API" : "Chat Completions";
            log_debug('APIManager', "GitHub Copilot $stream_label $api_type endpoint: $final_endpoint");
        }
    } elsif ($endpoint_config->{path_suffix} && 
             $endpoint !~ m{\Q$endpoint_config->{path_suffix}\E$}) {
        $final_endpoint .= $endpoint_config->{path_suffix};
    }
    
    my $req = HTTP::Request->new('POST', $final_endpoint);
    
    # Set authentication header using endpoint-specific configuration
    $req->header($endpoint_config->{auth_header} => $endpoint_config->{auth_value});
    $req->header('Content-Type' => 'application/json');
    
    # Streaming requests need Accept header
    if ($is_streaming) {
        $req->header('Accept' => '*/*');
    }
    
    # Add GitHub Copilot-specific headers
    if ($endpoint_config->{requires_copilot_headers}) {
        my $tool_call_iteration = $opts->{tool_call_iteration} || 1;
        my $initiator = $tool_call_iteration <= 1 ? 'user' : 'agent';
        $req->header('x-initiator' => $initiator);
        
        # Generate per-request UUID for tracking
        my $request_id = _generate_uuid();
        
        # Required headers per VS Code Copilot Chat reference
        $req->header('X-GitHub-Api-Version' => '2025-05-01');
        $req->header('X-Request-Id' => $request_id);
        $req->header('User-Agent' => 'GitHubCopilotChat/0.38.0');
        $req->header('OpenAI-Intent' => 'conversation-agent');
        $req->header('X-Interaction-Type' => 'conversation-agent');
        $req->header('X-Agent-Task-Id' => $request_id);
        
        # Editor-Version is REQUIRED for exchanged tokens
        $req->header('Editor-Version' => 'vscode/2.0.0') if $self->{using_exchanged_token};
        
        log_debug('APIManager', "Copilot headers: initiator=$initiator, request_id=$request_id");
    }
    
    # Add OpenRouter-specific headers
    # Required for app identification (prevents 401 errors)
    if ($final_endpoint =~ m{openrouter\.ai}i) {
        $req->header('HTTP-Referer' => 'https://github.com/fewtarius/CLIO');
        $req->header('X-Title' => 'CLIO');
    }
    
    $req->content($json);
    
    return ($req, $final_endpoint);
}

# Apply rate limiting: broker coordination, local delay, and cooldown.
#
# Shared preamble for send_request and send_request_streaming.
# Handles broker slot acquisition, inter-request delay, and rate limit cooldown.
# Sets response_handler broker_request_id for later release.
#
sub _apply_rate_limiting {
    my ($self) = @_;

    # Broker-based rate limiting coordination (for multi-agent scenarios)
    my $broker_request_id;
    if ($self->{broker_client}) {
        local $SIG{PIPE} = 'IGNORE';
        my $slot_result = $self->{broker_client}->wait_for_api_slot(120);
        $broker_request_id = $slot_result->{request_id};

        if (!$slot_result->{success}) {
            log_warning('APIManager', "Broker rate limit timeout after $slot_result->{waited}s, proceeding anyway");
        } elsif ($slot_result->{waited} > 0) {
            log_debug('APIManager', "Broker granted API slot after waiting " . sprintf("%.2f", $slot_result->{waited}) . "s");
        }
    }

    # Local rate limit prevention when broker not available
    if (!$self->{broker_client} && defined $self->{last_request_time}) {
        my $now = Time::HiRes::time();
        my $elapsed = $now - $self->{last_request_time};
        my $min_delay = $self->{response_handler}{_dynamic_min_delay} // 1.0;

        if ($elapsed < $min_delay) {
            my $wait = $min_delay - $elapsed;
            log_debug('APIManager', "Rate limit prevention: waiting " . sprintf("%.3f", $wait) . "s");
            Time::HiRes::sleep($wait);
        }
    }

    # Record timestamp BEFORE request
    $self->{last_request_time} = Time::HiRes::time();

    # Store broker_request_id for later release
    $self->{response_handler}->set_broker_request_id($broker_request_id);

    # Local rate limit cooldown (only when NOT using broker)
    if (!$self->{broker_client} && time() < ($self->{response_handler}{rate_limit_until} // 0)) {
        my $wait = int($self->{response_handler}{rate_limit_until} - time()) + 1;
        log_debug('APIManager', "Rate limited. Waiting ${wait}s before retry...");
        for (my $i = $wait; $i > 0; $i--) {
            log_debug('APIManager', "Retrying in ${i}s...") if !($i % 5);
            sleep(1);
        }
        log_debug('APIManager', "Rate limit cleared. Sending request...");
    }
}

sub send_request {
    my ($self, $input, %opts) = @_;
    
    $self->_apply_rate_limiting();

    # Get endpoint-specific configuration
    my $ep = $self->_prepare_endpoint_config(%opts);
    my $endpoint_config = $ep->{config};
    my $endpoint = $ep->{endpoint};
    my $model = $ep->{model};

    # Proactive per-model throttle
    if (my $throttle_delay = $self->_model_throttle_check($model)) {
        log_info('APIManager', sprintf("Proactive rate throttle for %s: %.1fs", $model, $throttle_delay));
        for (my $i = int($throttle_delay); $i > 0; $i--) { sleep(1); }
    }
    $self->_model_throttle_record($model);

    # Prepare and trim messages
    my $messages = $self->_prepare_messages($input, %opts);
    
    # Debug logging if enabled
    if ($self->{debug}) {
        warn "[DEBUG] Sending request to $endpoint\n";
        warn sprintf("[DEBUG] Using model: %s\n", $model);
        warn sprintf("[DEBUG] API key status: %s\n", $self->{api_key} ? '[SET]' : '[MISSING]');
        warn "[DEBUG] Endpoint config: " . (ref($endpoint_config) eq 'HASH' ? 'loaded' : 'missing') . "\n";
    }
    
    if (!$self->{api_key}) {
        return $self->_error("Missing API key. Please configure a provider with /api provider <name> or set key with /api key <value>");
    }
    
    # Validate and truncate messages against model token limits (pass tools for accurate budget)
    # Use full model name (with CLIO provider prefix) so get_model_capabilities correctly
    # identifies the provider. Without this, model names like 'deepseek/deepseek-r1' (from
    # OpenRouter) get misinterpreted as 'deepseek' provider + 'deepseek-r1' model.
    my $full_model_for_caps = $self->get_current_model();
    my $pre_trim_count = scalar(@$messages);
    $messages = $self->validate_and_truncate_messages($messages, $full_model_for_caps, $opts{tools});
    
    # Store trimmed messages for orchestrator sync
    # When proactive trimming occurs, the orchestrator should update its @messages
    # to match, preventing unbounded growth and reducing reactive trim severity
    my $post_trim_count = scalar(@$messages);
    if ($post_trim_count < $pre_trim_count) {
        $self->{_last_trimmed_messages} = $messages;
        log_info('APIManager', "Proactive trim: $pre_trim_count -> $post_trim_count messages");
    } else {
        $self->{_last_trimmed_messages} = undef;
    }
    
    # Check if model uses Responses API (codex models, etc.)
    my $use_responses_api = $self->_model_uses_responses_api($model);
    $self->{_current_request_uses_responses} = $use_responses_api;
    
    # Build request payload - use Responses API format when needed
    my $payload;
    if ($use_responses_api) {
        log_info('APIManager', "Using Responses API for model: $model");
        $payload = $self->_build_responses_api_payload($messages, $model, $endpoint_config, %opts, stream => 0);
    } else {
        $payload = $self->_build_payload($messages, $model, $endpoint_config, %opts, stream => 0);
    }
    
    # PRE-FLIGHT VALIDATION: Final check for message structure integrity
    # (Only applies to Chat Completions API which uses 'messages')
    my $preflight_errors = $use_responses_api ? undef : $self->_preflight_validate_messages($payload->{messages});
    if ($preflight_errors && @$preflight_errors) {
        my $error_summary = join('; ', @$preflight_errors);
        log_debug('APIManager', "Pre-flight validation failed: $error_summary");
        
        # Attempt auto-repair
        $payload->{messages} = $self->_validate_tool_message_pairs($payload->{messages});
        
        # Re-validate after repair
        my $post_repair_errors = $self->_preflight_validate_messages($payload->{messages});
        if ($post_repair_errors && @$post_repair_errors) {
            return $self->_error("Message structure validation failed: " . join('; ', @$post_repair_errors));
        }
        log_info('APIManager', "Message structure repaired successfully");
    }
    
    # Encode payload to JSON with error handling
    my $json;
    eval {
        $json = encode_json($payload);
    };
    if ($@) {
        my $error = $@;
        log_debug('APIManager', "JSON encoding failed: $error");
        # Log the payload structure for debugging
        if (open my $fh, '>>', '/tmp/clio_json_errors.log') {
            use Data::Dumper;
            print $fh "\n" . "="x80 . "\n";
            print $fh "[" . scalar(localtime) . "] JSON Encoding Failure\n";
            print $fh "Error: $error\n";
            print $fh "Payload structure:\n";
            print $fh Dumper($payload);
            close $fh;
        }
        return $self->_error("Failed to encode request as JSON: $error");
    }
    
    # Validate the JSON by attempting to decode it
    eval {
        decode_json($json);
    };
    if ($@) {
        my $error = $@;
        log_debug('APIManager', "JSON validation failed: $error");
        # Log the actual JSON for inspection
        if (open my $fh, '>>', '/tmp/clio_json_errors.log') {
            print $fh "\n" . "="x80 . "\n";
            print $fh "[" . scalar(localtime) . "] JSON Validation Failure\n";
            print $fh "Error: $error\n";
            print $fh "Generated JSON:\n";
            print $fh $json . "\n";
            close $fh;
        }
        return $self->_error("Generated invalid JSON: $error");
    }
    
    if ($self->{debug}) {
        warn "[DEBUG] Payload: $json\n";
    }
    
    my $ua = CLIO::Compat::HTTP->new(
        timeout => 60,
        agent   => 'CLIO/1.0',
        ssl_opts => { verify_hostname => 1 }
    );

    # Build HTTP request with headers (pass opts for tool_call_iteration)
    my ($req, $final_endpoint) = $self->_build_request($endpoint, $endpoint_config, $json, 0, \%opts);

    # Log full request for debugging
    my $provider_label = $endpoint_config->{minimax} ? 'MiniMax' :
                         $endpoint_config->{requires_copilot_headers} ? 'GitHub Copilot' :
                         $endpoint_config->{openrouter} ? 'OpenRouter' : 'API';
    log_debug('APIManager', "=" x 80);
    log_debug('APIManager', "[$provider_label REQUEST] Endpoint: $final_endpoint");
    log_debug('APIManager', "[$provider_label REQUEST] Model: $model");
    log_debug('APIManager', "[$provider_label REQUEST] Headers:");
    for my $h ($req->headers->header_field_names) {
        my $val = $req->header($h);
        # Mask auth values
        $val =~ s/(Bearer\s+).{8}(.*)/${1}XXXX...${2}/ if $h =~ /auth/i;
        log_debug('APIManager', "  $h: $val");
    }
    # Pretty-print JSON for easier comparison
    my $pretty_json = $json;
    eval {
        my $decoded = decode_json($json);
        $pretty_json = encode_json($decoded);  # Re-encode compactly
    };
    # Log tool count and key payload fields
    eval {
        my $p = decode_json($json);
        log_debug('APIManager', "[$provider_label REQUEST] max_tokens: " . ($p->{max_tokens} || 'NOT SET'));
        log_debug('APIManager', "[$provider_label REQUEST] tools: " . (ref($p->{tools}) eq 'ARRAY' ? scalar(@{$p->{tools}}) . " tools" : 'none'));
        log_debug('APIManager', "[$provider_label REQUEST] messages: " . (ref($p->{messages}) eq 'ARRAY' ? scalar(@{$p->{messages}}) . " messages" : 'none'));
        log_debug('APIManager', "[$provider_label REQUEST] reasoning_split: " . ($p->{reasoning_split} ? 'true' : 'false'));
        log_debug('APIManager', "[$provider_label REQUEST] stream: " . ($p->{stream} ? 'true' : 'false'));
    };
    # Save full request to file for detailed inspection
    if (open my $fh, '>>', '/tmp/clio_api_debug.log') {
        print $fh "\n" . "="x80 . "\n";
        print $fh "[" . scalar(localtime) . "] $provider_label REQUEST\n";
        print $fh "Endpoint: $final_endpoint\n";
        print $fh "Model: $model\n\n";
        print $fh "Headers:\n";
        for my $h ($req->headers->header_field_names) {
            my $val = $req->header($h);
            $val =~ s/(Bearer\s+).{8}(.*)/${1}XXXX.../ if $h =~ /auth/i;
            print $fh "  $h: $val\n";
        }
        print $fh "\nBody:\n$pretty_json\n";
        close $fh;
    }
    log_debug('APIManager', "[$provider_label REQUEST] Body (first 800 chars): " . substr($pretty_json, 0, 800));
    log_debug('APIManager', "=" x 80);

    if ($self->{debug}) {
        warn "[DEBUG] Making $provider_label request to: $final_endpoint\n";
        warn "[DEBUG] Using auth header: $endpoint_config->{auth_header}\n";
    }
    
    # Start performance tracking
    my $perf_start_time = time();
    
    my $resp;
    eval {
        $resp = $ua->request($req);
        
        if ($self->{debug}) {
            warn sprintf("[DEBUG] Response status: %s\n", $resp->status_line);
            if (!$resp->is_success) {
                warn sprintf("[DEBUG] Error response: %s\n", $resp->decoded_content);
            }
        }
    };
    
    # End performance tracking
    my $perf_end_time = time();
    my $tokens_in = 0;
    my $tokens_out = 0;
    my $success = 0;
    my $perf_error = undef;
    
    if ($@) {
        my $error = "Request failed: $@";
        warn "[ERROR] $error\n" if $self->{debug};
        $perf_error = $error;
        
        # Record failed request
        $self->{performance_monitor}->record_api_call(
            $self->{api_base},
            $model,
            {
                start_time => $perf_start_time,
                end_time => $perf_end_time,
                success => 0,
                error => $error,
            }
        );
        
        # Release broker slot before returning
        $self->{response_handler}->release_broker_slot(undef, 599);  # 599 = network error
        
        # Network/timeout errors are transient and should be retried
        return { 
            success => 0, 
            error => $error, 
            retryable => 1,
            retry_after => 2,
            error_type => 'server_error',
        };
    }
    
    if (!$resp->is_success) {
        # Log the error response for debugging
        my $error_body = $resp->decoded_content || '';
        log_debug('APIManager', "[$provider_label RESPONSE ERROR] Status: " . $resp->status_line);
        log_debug('APIManager', "[$provider_label RESPONSE ERROR] Body: " . substr($error_body, 0, 2000));
        if (open my $fh, '>>', '/tmp/clio_api_debug.log') {
            print $fh "\n" . "-"x80 . "\n";
            print $fh "[" . scalar(localtime) . "] $provider_label RESPONSE ERROR\n";
            print $fh "Status: " . $resp->status_line . "\n";
            print $fh "Body:\n$error_body\n";
            close $fh;
        }
        
        # Release broker slot with response info before returning
        $self->{response_handler}->release_broker_slot($resp, $resp->code);
        
        return $self->{response_handler}->handle_error_response($resp, $json, 0,
            attempt_token_recovery => sub { $self->_attempt_token_recovery() });
    }
    
    # Process rate limit headers from ALL successful responses (proactive throttling)
    $self->{response_handler}->process_rate_limit_headers($resp->headers);
    
    # Log full response for debugging
    my $raw_response = $resp->decoded_content;
    log_debug('APIManager', "[$provider_label RESPONSE] Status: " . $resp->status_line);
    log_debug('APIManager', "[$provider_label RESPONSE] Body (first 1500 chars): " . substr($raw_response, 0, 1500));
    if (open my $fh, '>>', '/tmp/clio_api_debug.log') {
        print $fh "\n" . "-"x80 . "\n";
        print $fh "[" . scalar(localtime) . "] $provider_label RESPONSE\n";
        print $fh "Status: " . $resp->status_line . "\n";
        print $fh "Headers:\n";
        for my $h ($resp->headers->header_field_names) {
            print $fh "  $h: " . $resp->header($h) . "\n";
        }
        print $fh "\nBody:\n$raw_response\n";
        close $fh;
    }
    
    my $data = eval { decode_json($raw_response) };
    if ($@) {
        my $error = "Invalid response format: $@";
        log_error('APIManager', "[$provider_label] $error");
        log_debug('APIManager', "[$provider_label] Raw content: " . substr($raw_response, 0, 500));
        return $self->_error($error);
    }
    
    # Log key response fields
    eval {
        my $finish_reason = $data->{choices}[0]{finish_reason} || 'unknown';
        my $has_tool_calls = $data->{choices}[0]{message}{tool_calls} ? scalar(@{$data->{choices}[0]{message}{tool_calls}}) : 0;
        my $content_len = length($data->{choices}[0]{message}{content} || '');
        my $usage_in = $data->{usage}{prompt_tokens} || 0;
        my $usage_out = $data->{usage}{completion_tokens} || 0;
        log_debug('APIManager', "[$provider_label RESPONSE] finish_reason=$finish_reason, tool_calls=$has_tool_calls, content_len=$content_len, usage=$usage_in/$usage_out");
    };
    
    # Extract stateful_marker for session continuation (GitHub Copilot billing)
    # This is the CORRECT field to use (not 'id'!) per VS Code implementation
    # The stateful_marker is used as previous_response_id in next request
    # to signal session continuation and prevent duplicate premium charges
    if ($data->{stateful_marker}) {
        my $iteration = $opts{tool_call_iteration} || 1;
        $self->{response_handler}->store_stateful_marker($data->{stateful_marker}, $model, $iteration);
    }
    
    # Check for stateful_marker in message as well (SAM approach)
    if ($data->{choices} && @{$data->{choices}} && 
        $data->{choices}[0]{message} && 
        $data->{choices}[0]{message}{stateful_marker}) {
        my $iteration = $opts{tool_call_iteration} || 1;
        $self->{response_handler}->store_stateful_marker($data->{choices}[0]{message}{stateful_marker}, $model, $iteration);
    }
    
    # Fallback: Store response_id if stateful_marker unavailable
    if ($data->{id} && $self->{session}) {
        $self->{session}{lastGitHubCopilotResponseId} = $data->{id};
        log_debug('APIManager', "Stored response_id fallback: " . substr($data->{id}, 0, 30) . "...");
    }
    # Process GitHub Copilot quota headers for premium billing tracking
    $self->{response_handler}->process_quota_headers($resp->headers, $data->{id}) if $endpoint_config->{requires_copilot_headers};
    
    # Extract and validate the message content
    my $content = '';
    my $tool_calls = undef;  # Task 3: Extract tool_calls if present
    my $reasoning_details = undef;  # MiniMax interleaved thinking
    
    # Try to extract content based on different API response formats
    if (ref $data eq 'HASH') {
        # Responses API format (codex models, etc.)
        # Response has 'output' array with items of type 'message', 'function_call', 'reasoning'
        if ($use_responses_api && $data->{output} && ref($data->{output}) eq 'ARRAY') {
            log_debug('APIManager', "Parsing Responses API format (output items: " . scalar(@{$data->{output}}) . ")");
            
            my @text_parts = ();
            my @resp_tool_calls = ();
            
            for my $item (@{$data->{output}}) {
                my $type = $item->{type} || '';
                
                if ($type eq 'message' && $item->{content} && ref($item->{content}) eq 'ARRAY') {
                    # Extract text content from message output
                    for my $part (@{$item->{content}}) {
                        if (($part->{type} || '') eq 'output_text' && defined $part->{text}) {
                            push @text_parts, $part->{text};
                        }
                    }
                }
                elsif ($type eq 'function_call') {
                    # Convert Responses API function_call to Chat Completions tool_call format
                    push @resp_tool_calls, {
                        id => $item->{call_id} || '',
                        type => 'function',
                        function => {
                            name => $item->{name} || '',
                            arguments => $item->{arguments} || '{}',
                        },
                    };
                }
                # 'reasoning' type is ignored for content extraction
            }
            
            $content = join('', @text_parts) if @text_parts;
            $tool_calls = \@resp_tool_calls if @resp_tool_calls;
            
            # Store response.id as stateful marker for billing continuity
            if ($data->{id} && $self->{session}) {
                my $iteration = $opts{tool_call_iteration} || 1;
                $self->{response_handler}->store_stateful_marker($data->{id}, $model, $iteration);
                $self->{session}{lastGitHubCopilotResponseId} = $data->{id};
            }
            
            # Extract usage - Responses API uses input_tokens/output_tokens
            if ($data->{usage}) {
                $tokens_in = $data->{usage}{input_tokens} || 0;
                $tokens_out = $data->{usage}{output_tokens} || 0;
            }
            
            log_debug('APIManager', "Responses API: content=" . length($content) . " chars, tool_calls=" . scalar(@{$tool_calls || []}));
        }
        # OpenAI/GitHub Copilot format (Chat Completions)
        elsif ($data->{choices} && @{$data->{choices}} && $data->{choices}[0]{message}) {
            my $message = $data->{choices}[0]{message};
            $content = $message->{content};
            
            # Task 3: Extract tool_calls from message if present
            if ($message->{tool_calls} && ref($message->{tool_calls}) eq 'ARRAY') {
                $tool_calls = $message->{tool_calls};
                
                # Normalize non-OpenAI tool call IDs (e.g. Google 'function-call-NNNN')
                for my $tc (@$tool_calls) {
                    if ($tc->{id} && $tc->{id} =~ /^function-call-(\d+)$/) {
                        $tc->{id} = 'call_' . substr($1, -24);
                    }
                }
                
                if ($self->{debug}) {
                    warn "[DEBUG] Extracted " . scalar(@$tool_calls) . " tool_calls from response\n";
                }
            }
            
            # Extract reasoning_details for MiniMax interleaved thinking
            if ($message->{reasoning_details} && ref($message->{reasoning_details}) eq 'ARRAY') {
                $reasoning_details = $message->{reasoning_details};
                log_debug('APIManager', "Extracted " . scalar(@$reasoning_details) . " reasoning_details from response");
            }
        }
        # Text completion format
        elsif ($data->{choices} && @{$data->{choices}} && $data->{choices}[0]{text}) {
            $content = $data->{choices}[0]{text};
        }
        # Direct content format
        elsif ($data->{content}) {
            $content = $data->{content};
        }
        # Message array format (GitHub Copilot)
        elsif ($data->{messages} && @{$data->{messages}}) {
            $content = $data->{messages}[-1]{content};
        }
        # Nested response format
        elsif ($data->{response} && $data->{response}{content}) {
            $content = $data->{response}{content};
        }
    }
    
    # Log extracted content for debugging
    if ($self->{debug}) {
        warn "[DEBUG] Extracted content: " . ($content // '[undef]') . "\n";
        if (!defined $content) {
            require Data::Dumper;
            warn "[DEBUG] Response structure:\n" . Data::Dumper::Dumper($data);
        }
    }
    
    # Process the content if we found it
    if (defined $content && length($content)) {
        # Strip <think>...</think> tags from non-streaming responses (MiniMax)
        # MiniMax M2.x models sometimes include thinking inline even with reasoning_split
        if ($endpoint_config->{minimax} && $content =~ /<think>/) {
            # Remove complete <think>...</think> blocks
            while ($content =~ s{<think>.*?</think>\n*}{}sg) {}
            # Remove orphaned tags
            $content =~ s/<\/?think>//g;
            # Only strip leading newlines that were adjacent to removed tags
            $content =~ s/^\n+//;
            log_debug('APIManager', "Stripped <think> tags from MiniMax non-streaming response");
        }
        
        # Only wrap in conversation tags if not already wrapped
        if ($content !~ m{\[conversation\].*?\[/conversation\]}s) {
            $content = "[conversation]$content\[/conversation]";
            warn "[DEBUG] Wrapped content in conversation tags\n" if $self->{debug};
        }
        
        # Extract token usage for performance tracking
        if ($data->{usage}) {
            # Responses API uses input_tokens/output_tokens, Chat Completions uses prompt_tokens/completion_tokens
            $tokens_in ||= $data->{usage}{prompt_tokens} || $data->{usage}{input_tokens} || 0;
            $tokens_out ||= $data->{usage}{completion_tokens} || $data->{usage}{output_tokens} || 0;
            
            # Strategy #5: Learn from actual API response to improve estimation
            $self->_learn_from_api_response($data->{usage}, $messages);
        }
        
        # Record successful request performance
        $self->{performance_monitor}->record_api_call(
            $self->{api_base},
            $model,
            {
                start_time => $perf_start_time,
                end_time => $perf_end_time,
                success => 1,
                tokens_in => $tokens_in,
                tokens_out => $tokens_out,
            }
        );
        
        # Build result hashref
        my $result = { 
            content => $content, 
            usage => $data->{usage} 
        };
        
        # Task 3: Include tool_calls if present
        if ($tool_calls) {
            $result->{tool_calls} = $tool_calls;
            
            if ($self->{debug}) {
                warn "[DEBUG] Including tool_calls in result\n";
            }
        }
        
        # Include reasoning_details for MiniMax interleaved thinking
        if ($reasoning_details) {
            $result->{reasoning_details} = $reasoning_details;
        }
        # Release broker slot on success
        $self->{response_handler}->release_broker_slot($resp, 200);
        
        return $result;
    }
    
    # Task 3: Handle case where AI only returns tool_calls (no content)
    if ($tool_calls && @$tool_calls) {
        if ($self->{debug}) {
            warn "[DEBUG] Response contains only tool_calls (no text content)\n";
        }
        
        # Release broker slot on success
        $self->{response_handler}->release_broker_slot($resp, 200);
        
        return {
            content => '',  # Empty content when only tool_calls
            tool_calls => $tool_calls,
            usage => $data->{usage}
        };
    }
    
    # No valid content found
    warn "[ERROR] No message content in response\n" if $self->{debug};
    
    # Release broker slot before returning error
    $self->{response_handler}->release_broker_slot($resp, 200);  # Response was successful but content invalid
    
    return $self->_error("No message content in response");
}

=head2 send_request_streaming

Send a streaming request to the AI API and receive chunks progressively.

Arguments:
- $input: User input text (optional if messages provided)
- %opts: Options hash
  - messages: Array of message hashes
  - on_chunk: Callback function called for each content chunk
  - model: Model name override
  - temperature: Temperature setting
  - top_p: Top P setting
  - tools: Array of tool definitions

Returns: Hash with:
- success: 1 if successful, 0 if error
- content: Complete accumulated response
- metrics: Performance metrics hash
  - ttft: Time to first token (seconds)
  - tps: Tokens per second
  - tokens: Total token count
  - duration: Total request duration (seconds)
- error: Error message if failed

=cut

sub send_request_streaming {
    my ($self, $input, %opts) = @_;
    
    log_debug('APIManager', "Starting streaming request");
    
    $self->_apply_rate_limiting();

    # Extract on_chunk and on_tool_call callbacks
    my $on_chunk = $opts{on_chunk};
    my $on_tool_call = $opts{on_tool_call};
    my $on_thinking = $opts{on_thinking};
    delete $opts{on_chunk};  # Remove from opts before building payload
    delete $opts{on_tool_call};  # Remove from opts before building payload
    delete $opts{on_thinking};  # Remove from opts before building payload
    
    # Get endpoint-specific configuration
    my $ep = $self->_prepare_endpoint_config(%opts);
    my $endpoint_config = $ep->{config};
    my $endpoint = $ep->{endpoint};
    my $model = $ep->{model};

    # Proactive per-model throttle
    if (my $throttle_delay = $self->_model_throttle_check($model)) {
        log_info('APIManager', sprintf("Proactive rate throttle for %s: %.1fs", $model, $throttle_delay));
        for (my $i = int($throttle_delay); $i > 0; $i--) { sleep(1); }
    }
    $self->_model_throttle_record($model);

    # Prepare and trim messages
    my $messages = $self->_prepare_messages($input, %opts);
    
    # Check for native provider (non-OpenAI-compatible API)
    my $native_provider = $self->_get_native_provider();
    if ($native_provider) {
        # Dispatch to native provider implementation
        return $self->_send_native_streaming(
            $native_provider, 
            $messages, 
            $opts{tools},
            on_chunk => $on_chunk,
            on_tool_call => $on_tool_call,
            on_thinking => $on_thinking,
            model => $model,
            %opts
        );
    }
    
    # Continue with OpenAI-compatible implementation...
    
    # Strip non-standard fields from tool result messages before sending to OpenAI-compatible endpoints.
    # The 'name' field is stored internally so native providers (e.g. Google) can build
    # functionResponse.name, but OpenAI-spec endpoints reject it on role=tool messages.
    for my $msg (@$messages) {
        delete $msg->{name} if $msg->{role} && $msg->{role} eq 'tool' && exists $msg->{name};
    }

    # Debug logging
    if ($self->{debug}) {
        log_debug('APIManager', "Streaming to $endpoint");
        log_debug('APIManager', "Model: $model");
    }
    
    if (!$self->{api_key}) {
        return { success => 0, error => "Missing API key. Please configure a provider with /api provider <name> or set key with /api key <value>" };
    }
    
    # Validate and truncate messages against model token limits (pass tools for accurate budget)
    # Use full model name (with CLIO provider prefix) so get_model_capabilities correctly
    # identifies the provider. Without this, model names like 'deepseek/deepseek-r1' (from
    # OpenRouter) get misinterpreted as 'deepseek' provider + 'deepseek-r1' model.
    my $full_model_for_caps = $self->get_current_model();
    my $pre_trim_count = scalar(@$messages);
    $messages = $self->validate_and_truncate_messages($messages, $full_model_for_caps, $opts{tools});
    
    # Store trimmed messages for orchestrator sync
    # When proactive trimming occurs, the orchestrator should update its @messages
    # to match, preventing unbounded growth and reducing reactive trim severity
    my $post_trim_count = scalar(@$messages);
    if ($post_trim_count < $pre_trim_count) {
        $self->{_last_trimmed_messages} = $messages;
        log_info('APIManager', "Proactive trim: $pre_trim_count -> $post_trim_count messages");
    } else {
        $self->{_last_trimmed_messages} = undef;
    }

    # Strip non-standard fields before building OpenAI-compatible payload.
    # The 'name' field on role=tool messages is for native providers only.
    for my $msg (@$messages) {
        delete $msg->{name} if $msg->{role} && $msg->{role} eq 'tool' && exists $msg->{name};
    }
    
    # Check if model uses Responses API (codex models, etc.)
    my $use_responses_api = $self->_model_uses_responses_api($model);
    $self->{_current_request_uses_responses} = $use_responses_api;
    
    # Build request payload - use Responses API format when needed
    my $payload;
    if ($use_responses_api) {
        log_info('APIManager', "Streaming: Using Responses API for model: $model");
        $payload = $self->_build_responses_api_payload($messages, $model, $endpoint_config, %opts, stream => 1);
    } else {
        $payload = $self->_build_payload($messages, $model, $endpoint_config, %opts, stream => 1);
    }
    
    # DEBUG: Print EXACT request payload being sent to API
    if ($self->{debug}) {
        require Data::Dumper;
        log_debug('APIManager', "===== REQUEST PAYLOAD =====");
        log_debug('APIManager', "Endpoint: $endpoint");
        log_debug('APIManager', "Model: $payload->{model}");
        log_debug('APIManager', "API: " . ($use_responses_api ? "Responses" : "Chat Completions"));
        if ($use_responses_api) {
            log_debug('APIManager', "Input items: " . scalar(@{$payload->{input} || []}));
        } else {
            log_debug('APIManager', "Messages count: " . scalar(@{$payload->{messages} || []}));
        }
        if ($payload->{tools}) {
            log_debug('APIManager', "Tools array (" . scalar(@{$payload->{tools}}) . " tools):");
            for my $i (0 .. $#{$payload->{tools}}) {
                my $tool = $payload->{tools}[$i];
                my $tool_name = $tool->{function} ? $tool->{function}{name} : ($tool->{name} || '?');
                log_debug('APIManager', "Tool $i: $tool_name");
            }
        } else {
            log_debug('APIManager', "Tools: NONE");
        }
        log_debug('APIManager', "===== END REQUEST PAYLOAD =====");
    }
    
    # Clean up tool_calls before encoding (only for Chat Completions format)
    # Remove internal metadata fields (_name_complete, etc) that were added during streaming
    # GitHub Copilot API rejects requests with unknown fields in tool_calls
    if (!$use_responses_api && $payload->{messages}) {
    for my $msg (@{$payload->{messages}}) {
        if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                delete $tc->{_name_complete} if exists $tc->{_name_complete};
            }
        }
    }
    }
    
    # PRE-FLIGHT VALIDATION: Final check for message structure integrity
    # This catches any orphans that might have slipped through truncation/preparation
    my $preflight_errors = $self->_preflight_validate_messages($payload->{messages});
    if ($preflight_errors && @$preflight_errors) {
        my $error_summary = join('; ', @$preflight_errors);
        log_debug('APIManager', "Pre-flight validation failed: $error_summary");
        
        # Attempt auto-repair via _validate_tool_message_pairs
        log_info('APIManager', "Attempting auto-repair of message structure");
        $payload->{messages} = $self->_validate_tool_message_pairs($payload->{messages});
        
        # Re-validate after repair
        my $post_repair_errors = $self->_preflight_validate_messages($payload->{messages});
        if ($post_repair_errors && @$post_repair_errors) {
            # Repair failed - return error to trigger retry logic
            return { 
                success => 0, 
                error => "Message structure validation failed after repair: " . join('; ', @$post_repair_errors),
                retryable => 1,
                retry_after => 0,
                error_type => 'message_structure_error'
            };
        }
        log_info('APIManager', "Message structure repaired successfully");
    }
    
    # DEBUG: Dump messages with tool_calls AFTER cleanup (only when debug enabled)
    if ($self->{debug}) {
        log_debug('APIManager', "POST-CLEANUP CHECK: Dumping messages with tool_calls:");
        for my $i (0 .. $#{$payload->{messages}}) {
            my $msg = $payload->{messages}[$i];
            if ($msg->{tool_calls}) {
                use Data::Dumper;
                log_debug('APIManager', "Message $i has tool_calls:");
                log_debug('APIManager', Dumper($msg->{tool_calls}));
            }
        }
    }
    
    # Encode payload to JSON with error handling
    my $json;
    eval {
        $json = encode_json($payload);
    };
    if ($@) {
        my $error = $@;
        log_debug('APIManager', "JSON encoding failed (streaming): $error");
        # Log the payload structure for debugging
        if (open my $fh, '>>', '/tmp/clio_json_errors.log') {
            use Data::Dumper;
            print $fh "\n" . "="x80 . "\n";
            print $fh "[" . scalar(localtime) . "] JSON Encoding Failure (Streaming)\n";
            print $fh "Error: $error\n";
            print $fh "Payload structure:\n";
            print $fh Dumper($payload);
            close $fh;
        }
        return {
            success => 0,
            error => "Failed to encode request as JSON: $error"
        };
    }
    
    # Validate the JSON by attempting to decode it
    eval {
        decode_json($json);
    };
    if ($@) {
        my $error = $@;
        log_debug('APIManager', "JSON validation failed (streaming): $error");
        # Log the actual JSON for inspection
        if (open my $fh, '>>', '/tmp/clio_json_errors.log') {
            print $fh "\n" . "="x80 . "\n";
            print $fh "[" . scalar(localtime) . "] JSON Validation Failure (Streaming)\n";
            print $fh "Error: $error\n";
            print $fh "Generated JSON:\n";
            print $fh $json . "\n";
            close $fh;
        }
        return {
            success => 0,
            error => "Generated invalid JSON: $error"
        };
    }
    
    # Create HTTP client
    my $ua = CLIO::Compat::HTTP->new(
        timeout => 300,  # Longer timeout for streaming
        agent   => 'GitHubCopilotChat/0.22.4',  # Match GitHub Copilot client  
        ssl_opts => { verify_hostname => 1 }
    );
    
    # Build HTTP request with headers (pass opts for tool_call_iteration)
    my ($req, $final_endpoint) = $self->_build_request($endpoint, $endpoint_config, $json, 1, \%opts);
    
    # Log full streaming request for debugging
    my $provider_label = $endpoint_config->{minimax} ? 'MiniMax' :
                         $endpoint_config->{requires_copilot_headers} ? 'GitHub Copilot' :
                         $endpoint_config->{openrouter} ? 'OpenRouter' : 'API';
    log_debug('APIManager', "=" x 80);
    log_debug('APIManager', "[$provider_label STREAMING REQUEST] Endpoint: $final_endpoint");
    log_debug('APIManager', "[$provider_label STREAMING REQUEST] Model: $model");
    eval {
        my $p = decode_json($json);
        log_debug('APIManager', "[$provider_label STREAMING REQUEST] max_tokens: " . ($p->{max_tokens} || 'NOT SET'));
        log_debug('APIManager', "[$provider_label STREAMING REQUEST] tools: " . (ref($p->{tools}) eq 'ARRAY' ? scalar(@{$p->{tools}}) . " tools" : 'none'));
        log_debug('APIManager', "[$provider_label STREAMING REQUEST] messages: " . (ref($p->{messages}) eq 'ARRAY' ? scalar(@{$p->{messages}}) . " messages" : 'none'));
    };
    if (open my $fh, '>>', '/tmp/clio_api_debug.log') {
        print $fh "\n" . "="x80 . "\n";
        print $fh "[" . scalar(localtime) . "] $provider_label STREAMING REQUEST\n";
        print $fh "Endpoint: $final_endpoint\n";
        print $fh "Model: $model\n\n";
        print $fh "Headers:\n";
        for my $h ($req->headers->header_field_names) {
            my $val = $req->header($h);
            $val =~ s/(Bearer\s+).{8}(.*)/${1}XXXX.../ if $h =~ /auth/i;
            print $fh "  $h: $val\n";
        }
        print $fh "\nBody:\n$json\n";
        close $fh;
    }
    log_debug('APIManager', "=" x 80);
    
    # Request headers available for debugging if needed (use should_log('DEBUG'))
    
    # Initialize metrics tracking
    my $start_time = time();
    my $first_token_time = undef;
    my $token_count = 0;
    my $accumulated_content = '';
    my $buffer = '';  # Buffer for partial SSE lines
    my $tool_calls_accumulator = {};  # Accumulate tool call deltas by index
    my $reasoning_was_active = 0;  # Track if reasoning_content was being streamed
    my $accumulated_reasoning_details = '';  # Accumulate reasoning for MiniMax interleaved thinking
    my $streaming_usage = undef;  # Capture real usage from final streaming chunk
    my $raw_response_body = '';  # Preserve full response body for error detection
    
    # State machine for <think> tag handling (MiniMax M2.x inline thinking)
    my $in_think_tag = 0;       # Currently inside <think>...</think> block
    my $think_buffer = '';      # Buffer for partial tag detection at chunk boundaries
    my $is_minimax = $endpoint_config->{minimax} ? 1 : 0;
    
    # Make streaming request with callback
    my $resp;
    my $streaming_headers;  # Capture headers from streaming callback
    eval {
        $resp = $ua->request($req, sub {
            my ($chunk, $response, $protocol) = @_;
            
            # Capture headers on first chunk (they're available in $response object)
            if (!$streaming_headers && $response) {
                $streaming_headers = $response->headers->clone;
                log_debug('APIManager', "Captured headers from streaming response");
                log_debug('APIManager', "Streaming response HTTP status: " . $response->code . " " . ($response->message // ''));
            }
            
            # Preserve raw body for post-streaming error detection
            $raw_response_body .= $chunk;
            
            # Append chunk to buffer
            $buffer .= $chunk;
            
            # Normalize CRLF to LF for providers that use \r\n line endings
            $buffer =~ s/\r\n/\n/g;
            
            # Process complete SSE lines (ending with \n\n)
            while ($buffer =~ s/^(.*?)\n\n//s) {
                my $sse_chunk = $1;
                
                # Skip empty lines
                next unless $sse_chunk =~ /\S/;
                
                # Parse SSE format
                # Chat Completions: "data: {...}\n"
                # Responses API: "event: <type>\ndata: {...}\n"
                my $event_type = '';
                for my $line (split /\n/, $sse_chunk) {
                    # Capture event type (Responses API uses event: lines)
                    if ($line =~ /^event:\s*(.+)$/) {
                        $event_type = $1;
                        next;
                    }
                    next unless $line =~ /^data:\s*(.+)$/;
                    my $data_json = $1;
                    
                    # Check for stream end
                    next if $data_json eq '[DONE]';
                    
                    # Parse JSON chunk
                    my $data = eval { decode_json($data_json) };
                    if ($@) {
                        log_warning('APIManager', "Failed to parse SSE chunk: $@");
                        next;
                    }
                    
                    # Infer event type from data if not set by event: line
                    # Responses API always has a 'type' field in the data
                    if (!$event_type && $data->{type}) {
                        $event_type = $data->{type};
                    }
                    
                    # DEBUG: Log what fields are in each chunk
                    if (should_log('DEBUG')) {
                        my @fields = keys %$data;
                        log_debug('APIManager', "SSE chunk fields: " . join(', ', @fields));
                        if ($data->{id}) {
                            log_debug('APIManager', "Chunk has id: " . substr($data->{id}, 0, 30) . "...");
                        }
                    }
                    
                    # Extract stateful_marker for session continuation (GitHub Copilot billing)
                    # This is the CORRECT field to use (not 'id'!) per VS Code implementation
                    # The stateful_marker is used as previous_response_id in next request
                    # to signal session continuation and prevent duplicate premium charges
                    if ($data->{stateful_marker}) {
                        my $iteration = $opts{tool_call_iteration} || 1;
                        $self->{response_handler}->store_stateful_marker($data->{stateful_marker}, $model, $iteration);
                    }
                    
                    # Fallback: Store response id for models without stateful_marker
                    if ($data->{id} && $self->{session}) {
                        $self->{session}{lastGitHubCopilotResponseId} = $data->{id};
                        log_debug('APIManager', "Stored response_id fallback: " . substr($data->{id}, 0, 30) . "...");
                    }
                    
                    # Capture real usage from final streaming chunk
                    # When stream_options.include_usage is true, the API sends a
                    # final chunk with usage data (prompt_tokens, completion_tokens)
                    if ($data->{usage}) {
                        $streaming_usage = {
                            prompt_tokens => $data->{usage}{prompt_tokens} || $data->{usage}{input_tokens} || 0,
                            completion_tokens => $data->{usage}{completion_tokens} || $data->{usage}{output_tokens} || 0,
                            total_tokens => $data->{usage}{total_tokens} || 0,
                        };
                        $streaming_usage->{total_tokens} ||= $streaming_usage->{prompt_tokens} + $streaming_usage->{completion_tokens};
                        log_debug('APIManager', "Streaming usage captured: prompt=$streaming_usage->{prompt_tokens}, completion=$streaming_usage->{completion_tokens}");
                    }
                    
                    # Extract content delta and tool_calls from chunk
                    my $content_delta = undef;
                    my $tool_calls_delta = undef;
                    
                    # ==========================================
                    # Responses API streaming events (codex models, etc.)
                    # Event types: response.output_text.delta, response.function_call_arguments.delta,
                    #              response.output_item.added, response.output_item.done, response.completed
                    # ==========================================
                    if ($use_responses_api && $event_type) {
                        if ($event_type eq 'response.output_text.delta') {
                            # Text content delta
                            $content_delta = $data->{delta} if defined $data->{delta};
                            
                            # End reasoning if it was active
                            if ($reasoning_was_active && $on_thinking) {
                                $on_thinking->(undef, 'end');
                                $reasoning_was_active = 0;
                            }
                        }
                        elsif ($event_type eq 'response.output_item.added') {
                            my $item = $data->{item} || {};
                            my $item_type = $item->{type} || '';
                            
                            if ($item_type eq 'function_call') {
                                # Tool call starting - initialize accumulator
                                my $output_index = $data->{output_index} // 0;
                                $tool_calls_accumulator->{$output_index} = {
                                    id => $item->{call_id} || '',
                                    type => 'function',
                                    function => {
                                        name => $item->{name} || '',
                                        arguments => '',
                                    },
                                    _name_complete => 0,
                                };
                                
                                # Signal tool name to callback
                                if ($on_tool_call && $item->{name}) {
                                    $tool_calls_accumulator->{$output_index}{_name_complete} = 1;
                                    $on_tool_call->($item->{name});
                                }
                                
                                log_debug('APIManager', "Responses API: function_call started: " . ($item->{name} || '?'));
                            }
                            elsif ($item_type eq 'reasoning') {
                                # Reasoning started - but don't open THINKING box yet
                                # Wait until actual reasoning summary text arrives
                                # (handled by response.reasoning_summary_text.delta)
                                $reasoning_was_active = 1;
                                log_debug('APIManager', "Responses API: reasoning started (waiting for summary text)");
                            }
                        }
                        elsif ($event_type eq 'response.function_call_arguments.delta') {
                            # Accumulate function arguments
                            my $output_index = $data->{output_index} // 0;
                            if ($tool_calls_accumulator->{$output_index}) {
                                $tool_calls_accumulator->{$output_index}{function}{arguments} .= ($data->{delta} || '');
                                log_debug('APIManager', "Responses API: function_call args delta: " . length($data->{delta} || '') . " chars");
                            }
                        }
                        elsif ($event_type eq 'response.output_item.done') {
                            my $item = $data->{item} || {};
                            my $item_type = $item->{type} || '';
                            
                            if ($item_type eq 'function_call') {
                                # Tool call complete - finalize accumulator entry
                                my $output_index = $data->{output_index} // 0;
                                if ($tool_calls_accumulator->{$output_index}) {
                                    # Use final values from the item
                                    $tool_calls_accumulator->{$output_index}{id} = $item->{call_id} || $tool_calls_accumulator->{$output_index}{id};
                                    $tool_calls_accumulator->{$output_index}{function}{name} = $item->{name} || $tool_calls_accumulator->{$output_index}{function}{name};
                                    $tool_calls_accumulator->{$output_index}{function}{arguments} = $item->{arguments} || $tool_calls_accumulator->{$output_index}{function}{arguments};
                                }
                                log_debug('APIManager', "Responses API: function_call completed: " . ($item->{name} || '?'));
                            }
                            elsif ($item_type eq 'reasoning') {
                                # Reasoning done - only signal end if thinking was displayed
                                if ($on_thinking && $reasoning_was_active) {
                                    $on_thinking->(undef, 'end');
                                }
                                $reasoning_was_active = 0;
                            }
                        }
                        elsif ($event_type eq 'response.reasoning_summary_text.delta') {
                            # Reasoning summary text - show as thinking
                            if ($on_thinking && defined $data->{delta}) {
                                $reasoning_was_active = 1;
                                $on_thinking->($data->{delta});
                            }
                        }
                        elsif ($event_type eq 'response.completed') {
                            my $resp_data = $data->{response} || {};
                            
                            # Store response.id as stateful marker for billing continuity
                            if ($resp_data->{id} && $self->{session}) {
                                my $iteration = $opts{tool_call_iteration} || 1;
                                $self->{response_handler}->store_stateful_marker($resp_data->{id}, $model, $iteration);
                                $self->{session}{lastGitHubCopilotResponseId} = $resp_data->{id};
                                log_info('APIManager', "Responses API: Stored stateful marker for billing continuity");
                            }
                            
                            # Extract usage from completed response
                            if ($resp_data->{usage}) {
                                # Store real usage for accurate billing
                                $streaming_usage = {
                                    prompt_tokens => $resp_data->{usage}{input_tokens} || 0,
                                    completion_tokens => $resp_data->{usage}{output_tokens} || 0,
                                    total_tokens => ($resp_data->{usage}{input_tokens} || 0) + ($resp_data->{usage}{output_tokens} || 0),
                                };
                                log_debug('APIManager', "Responses API usage: " .
                                    "input=" . ($resp_data->{usage}{input_tokens} || 0) . ", " .
                                    "output=" . ($resp_data->{usage}{output_tokens} || 0));
                            }
                            
                            log_debug('APIManager', "Responses API: stream completed, status=" . ($resp_data->{status} || '?'));
                        }
                        elsif ($event_type eq 'error') {
                            # Error event from Responses API
                            my $error_msg = $data->{message} || 'Unknown error';
                            my $error_code = $data->{code} || 'unknown';
                            log_warning('APIManager', "Responses API error: [$error_code] $error_msg");
                        }
                        # else: response.created, response.in_progress, response.content_part.added,
                        #       response.content_part.done, response.output_text.done - skip silently
                    }
                    # ==========================================
                    # OpenAI/GitHub Copilot Chat Completions streaming format
                    # ==========================================
                    elsif ($data->{choices} && @{$data->{choices}}) {
                        my $choice = $data->{choices}[0];
                        my $delta = $choice->{delta};
                        
                        if ($delta) {
                            # Check for stateful_marker in delta as well
                            # (SAM implementation suggests it might be in message)
                            if ($delta->{stateful_marker}) {
                                my $iteration = $opts{tool_call_iteration} || 1;
                                $self->{response_handler}->store_stateful_marker($delta->{stateful_marker}, $model, $iteration);
                            }
                            
                            # Extract content (use defined+length to preserve "0" and whitespace-only deltas)
                            if (defined($delta->{content}) && length($delta->{content})) {
                                $content_delta = $delta->{content};
                                
                                # Handle <think> tags from MiniMax models
                                # MiniMax M2.x may send thinking inline as <think>...</think>
                                # even when reasoning_split=true. Strip tags and route
                                # thinking content to on_thinking callback.
                                if ($is_minimax && defined $content_delta) {
                                    my $work = $think_buffer . $content_delta;
                                    $think_buffer = '';
                                    $content_delta = '';
                                    
                                    while (length($work)) {
                                        if ($in_think_tag) {
                                            # Inside <think> - look for closing </think>
                                            if ($work =~ s{^(.*?)</think>}{}s) {
                                                my $think_text = $1;
                                                if (length($think_text) && $on_thinking) {
                                                    $reasoning_was_active = 1;
                                                    $accumulated_reasoning_details .= $think_text;
                                                    $on_thinking->($think_text);
                                                }
                                                $in_think_tag = 0;
                                                # Strip leading newlines after </think> to prevent blank lines
                                                $work =~ s/^\n+//;
                                            }
                                            elsif (_has_partial_close_think_suffix($work)) {
                                                # Partial </think> at end - buffer only the tag fragment
                                                my $idx = rindex($work, '<');
                                                my $before = substr($work, 0, $idx);
                                                my $fragment = substr($work, $idx);
                                                if (length($before) && $on_thinking) {
                                                    $reasoning_was_active = 1;
                                                    $accumulated_reasoning_details .= $before;
                                                    $on_thinking->($before);
                                                }
                                                $think_buffer = $fragment;
                                                $work = '';
                                            }
                                            else {
                                                # All thinking content, no closing tag yet
                                                if ($on_thinking) {
                                                    $reasoning_was_active = 1;
                                                    $accumulated_reasoning_details .= $work;
                                                    $on_thinking->($work);
                                                }
                                                $work = '';
                                            }
                                        }
                                        else {
                                            # Outside <think> - look for opening <think>
                                            if ($work =~ s{^(.*?)<think>}{}s) {
                                                my $before = $1;
                                                $content_delta .= $before;
                                                $in_think_tag = 1;
                                            }
                                            elsif (_has_partial_open_think_suffix($work)) {
                                                # Partial <think> at end - buffer only the tag fragment
                                                my $idx = rindex($work, '<');
                                                my $before = substr($work, 0, $idx);
                                                my $fragment = substr($work, $idx);
                                                $content_delta .= $before;
                                                $think_buffer = $fragment;
                                                $work = '';
                                            }
                                            else {
                                                # No think tags - pass through as content
                                                $content_delta .= $work;
                                                $work = '';
                                            }
                                        }
                                    }
                                    
                                    # If content_delta is now empty, clear it
                                    $content_delta = undef unless length($content_delta);
                                }
                                
                                # If reasoning was active and now regular content starts,
                                # signal end of thinking
                                if (defined($content_delta) && length($content_delta) && $reasoning_was_active && $on_thinking) {
                                    $on_thinking->(undef, 'end');
                                    $reasoning_was_active = 0;
                                }
                            }
                            
                            # Extract reasoning/thinking content from various formats
                            # Multiple providers use different fields - only emit once per chunk to prevent duplication
                            my $reasoning_emitted = 0;
                            
                            # 1. reasoning_content (DeepSeek direct API, some OpenAI-compat providers)
                            if (!$reasoning_emitted && $delta->{reasoning_content} && $on_thinking) {
                                $reasoning_was_active = 1;
                                $reasoning_emitted = 1;
                                $accumulated_reasoning_details .= $delta->{reasoning_content};
                                $on_thinking->($delta->{reasoning_content});
                            }
                            
                            # 2. reasoning_details (OpenRouter and MiniMax format)
                            # OpenRouter: [{type: "reasoning.text", text: "..."}, {type: "reasoning.summary", summary: "..."}]
                            # MiniMax: [{text: "..."}] (no type field, reasoning_split=true)
                            # Only check if we didn't already get content from reasoning_content
                            if (!$reasoning_emitted && $delta->{reasoning_details} && ref($delta->{reasoning_details}) eq 'ARRAY' && $on_thinking) {
                                for my $detail (@{$delta->{reasoning_details}}) {
                                    next unless ref($detail) eq 'HASH';
                                    my $type = $detail->{type} || '';
                                    
                                    if ($type eq 'reasoning.text' && defined $detail->{text}) {
                                        $reasoning_was_active = 1;
                                        $reasoning_emitted = 1;
                                        $accumulated_reasoning_details .= $detail->{text};
                                        $on_thinking->($detail->{text});
                                    }
                                    elsif ($type eq 'reasoning.summary' && defined $detail->{summary}) {
                                        $reasoning_was_active = 1;
                                        $reasoning_emitted = 1;
                                        $accumulated_reasoning_details .= $detail->{summary};
                                        $on_thinking->($detail->{summary});
                                    }
                                    # MiniMax format: no type field, just {text: "..."}
                                    elsif (!$type && defined $detail->{text}) {
                                        $reasoning_was_active = 1;
                                        $reasoning_emitted = 1;
                                        $accumulated_reasoning_details .= $detail->{text};
                                        $on_thinking->($detail->{text});
                                    }
                                    # reasoning.encrypted - skip display (redacted)
                                }
                            }
                            
                            # 3. Legacy 'reasoning' string field (some providers)
                            if (!$reasoning_emitted && $delta->{reasoning} && !ref($delta->{reasoning}) && $on_thinking) {
                                $reasoning_was_active = 1;
                                $accumulated_reasoning_details .= $delta->{reasoning};
                                $on_thinking->($delta->{reasoning});
                            }
                            
                            # Extract tool_calls delta
                            if ($delta->{tool_calls} && ref($delta->{tool_calls}) eq 'ARRAY') {
                                $tool_calls_delta = $delta->{tool_calls};
                            }
                        }
                    }
                    
                    # Process tool_calls delta (accumulate incrementally)
                    if ($tool_calls_delta) {
                        for my $tc_delta (@$tool_calls_delta) {
                            my $index = $tc_delta->{index} // 0;
                            
                            # Initialize accumulator for this index if needed
                           if (!$tool_calls_accumulator->{$index}) {
                                # Normalize non-OpenAI tool call IDs to OpenAI format.
                                # The Copilot proxy returns Google-style IDs ('function-call-NNNN')
                                # when routing to Gemini, but then rejects them on the next turn
                                # when they appear in role=tool messages. Convert to 'call_XXXXX'.
                                my $raw_id = $tc_delta->{id} // '';
                                my $norm_id = ($raw_id =~ /^function-call-(\d+)$/)
                                    ? 'call_' . substr($1, -24)
                                    : $raw_id;
                                $tool_calls_accumulator->{$index} = {
                                    id => $norm_id,
                                    type => $tc_delta->{type} // 'function',
                                    function => {
                                        name => '',
                                        arguments => '',
                                    },
                                    _name_complete => 0,  # Track if we've shown this tool name yet
                                };
                            }
                            
                            # Accumulate function name and arguments
                            if ($tc_delta->{function}) {
                                if ($tc_delta->{function}{name}) {
                                    # Set name (don't concatenate - some providers send it in every delta)
                                    if (!$tool_calls_accumulator->{$index}{function}{name}) {
                                        $tool_calls_accumulator->{$index}{function}{name} = $tc_delta->{function}{name};
                                    }
                                    
                                    # If name just became complete and we haven't shown it yet, call tool name callback
                                    if (!$tool_calls_accumulator->{$index}{_name_complete} && 
                                        $tool_calls_accumulator->{$index}{function}{name} =~ /\w/) {
                                        $tool_calls_accumulator->{$index}{_name_complete} = 1;
                                        
                                        # Call on_tool_call callback if provided
                                        if ($on_tool_call) {
                                            $on_tool_call->($tool_calls_accumulator->{$index}{function}{name});
                                        }
                                    }
                                }
                                if ($tc_delta->{function}{arguments}) {
                                    $tool_calls_accumulator->{$index}{function}{arguments} .= $tc_delta->{function}{arguments};
                                }
                            }
                            
                            log_debug('APIManager', "Tool call delta: index=$index, " . "name=" . ($tc_delta->{function}{name} // '') . ", " .
                                "args_chunk=" . (length($tc_delta->{function}{arguments} // 0)) . " bytes\n");
                        }
                    }
                    
                    # If we got content, track metrics and call callback
                    if (defined($content_delta) && length($content_delta)) {
                        # Record first token time
                        $first_token_time //= time();
                        
                        # Count tokens (rough estimate: 1 token ~= 4 chars)
                        $token_count += int(length($content_delta) / 4) || 1;
                        
                        # Accumulate content
                        $accumulated_content .= $content_delta;
                        
                        # Call chunk callback if provided
                        if ($on_chunk) {
                            my $current_time = time();
                            my $duration = $current_time - $start_time;
                            my $ttft = $first_token_time ? ($first_token_time - $start_time) : undef;
                            my $tps = ($duration > 0 && $token_count > 0) ? ($token_count / $duration) : 0;
                            
                            $on_chunk->($content_delta, {
                                token_count => $token_count,
                                ttft => $ttft,
                                tps => $tps,
                                duration => $duration,
                            });
                        }
                    }
                }
            }
        });
    };
    
    # Signal end of reasoning if it was still active when stream ended
    if ($reasoning_was_active && $on_thinking) {
        $on_thinking->(undef, 'end');
        $reasoning_was_active = 0;
    }
    
    # Post-streaming cleanup: strip residual <think> tags from accumulated content
    if ($is_minimax && length($accumulated_content) && $accumulated_content =~ /<\/?think>/) {
        while ($accumulated_content =~ s{<think>(.*?)</think>\n*}{}sg) {
            my $residual_think = $1;
            if (length($residual_think)) {
                $accumulated_reasoning_details .= $residual_think;
                if ($on_thinking) {
                    $on_thinking->($residual_think);
                }
            }
        }
        $accumulated_content =~ s/<\/?think>//g;
        $accumulated_content =~ s/^\n+//;
        log_debug('APIManager', "Cleaned residual <think> tags from streaming content");
    }
    
    # Flush any remaining think_buffer content
    if ($is_minimax && length($think_buffer)) {
        if (!$in_think_tag) {
            $accumulated_content .= $think_buffer;
        }
        elsif ($on_thinking) {
            $accumulated_reasoning_details .= $think_buffer;
            $on_thinking->($think_buffer);
            $on_thinking->(undef, 'end');
        }
        $think_buffer = '';
    }
    
    return $self->_finalize_streaming_response(
        resp                  => $resp,
        error                 => $@,
        buffer                => $buffer,
        raw_response_body     => $raw_response_body,
        accumulated_content   => $accumulated_content,
        accumulated_reasoning => $accumulated_reasoning_details,
        streaming_usage       => $streaming_usage,
        streaming_headers     => $streaming_headers,
        token_count           => $token_count,
        start_time            => $start_time,
        first_token_time      => $first_token_time,
        tool_calls_accumulator => $tool_calls_accumulator,
        endpoint_config       => $endpoint_config,
        provider_label        => $provider_label,
        messages              => $messages,
        input                 => $input,
        json                  => $json,
    );
}

# Process the result of a streaming HTTP request: handle errors, build final response.
#
# Called after the SSE streaming callback completes. Handles: network errors,
# HTTP errors, 200-body errors (Google/OpenRouter), metrics calculation,
# session persistence, rate limit headers, usage estimation, tool_calls
# conversion, and response construction.
#
# Args (hash):
#   resp                  => HTTP response object
#   error                 => $@ from eval (undef if no error)
#   buffer                => remaining SSE buffer
#   raw_response_body     => accumulated raw response
#   accumulated_content   => accumulated text content
#   accumulated_reasoning => accumulated reasoning details
#   streaming_usage       => real usage from stream (or undef)
#   streaming_headers     => captured HTTP headers (or undef)
#   token_count           => number of content tokens
#   start_time            => request start time (epoch)
#   first_token_time      => time of first token (epoch or undef)
#   tool_calls_accumulator => hashref of accumulated tool call deltas
#   endpoint_config       => endpoint configuration hash
#   provider_label        => string for logging
#   messages              => messages arrayref (for usage estimation)
#   input                 => original input string (for usage estimation)
#   json                  => encoded request JSON (for error handling)
#
# Returns: response hashref (success/error + content/tool_calls/metrics/usage)
#
sub _finalize_streaming_response {
    my ($self, %s) = @_;

    # Handle request exception ($@ from eval)
    if ($s{error}) {
        my $error = "Streaming request failed: $s{error}";
        log_debug('APIManager', "$error");
        $self->{response_handler}->release_broker_slot(undef, 599);
        return {
            success => 0,
            error => $error,
            retryable => 1,
            retry_after => 2,
            error_type => 'server_error',
        };
    }

    my $resp = $s{resp};

    # Handle HTTP error responses
    if (!$resp->is_success) {
        $self->{response_handler}->release_broker_slot($resp, $resp->code);

        my $body = $resp->decoded_content;
        if (!$body || $body !~ /\S/) {
            $body = $s{raw_response_body} // $s{buffer} // '';
        }

        log_debug('APIManager', "[$s{provider_label} STREAMING ERROR] Status: " . $resp->status_line);
        log_debug('APIManager', "[$s{provider_label} STREAMING ERROR] Body: " . substr($body, 0, 2000));
        if (open my $fh, '>>', '/tmp/clio_api_debug.log') {
            print $fh "\n" . "-"x80 . "\n";
            print $fh "[" . scalar(localtime) . "] $s{provider_label} STREAMING ERROR\n";
            print $fh "Status: " . $resp->status_line . "\n";
            print $fh "Body:\n$body\n";
            close $fh;
        }

        if ($body && $body =~ /\S/ && (!$resp->decoded_content || $resp->decoded_content !~ /\S/)) {
            $resp->{content} = $body;
        }

        return $self->{response_handler}->handle_error_response($resp, $s{json}, 1,
            attempt_token_recovery => sub { $self->_attempt_token_recovery() });
    }

    # Check for API errors returned as non-SSE body with HTTP 200
    my $check_body = $s{raw_response_body} || $s{buffer} || '';
    if (!$s{accumulated_content} && !keys(%{$s{tool_calls_accumulator}}) && $check_body =~ /\S/) {
        my $remaining = $check_body;
        $remaining =~ s/^\s+|\s+$//g;
        if ($remaining) {
            my $error_msg;
            my $error_code;
            eval {
                my $body = decode_json($remaining);
                if (ref($body) eq 'ARRAY' && @$body && $body->[0]{error}) {
                    $error_msg = $body->[0]{error}{message} || $body->[0]{error};
                    $error_code = $body->[0]{error}{code};
                }
                elsif (ref($body) eq 'HASH' && $body->{error}) {
                    $error_msg = $body->{error}{message} || $body->{error};
                    $error_code = $body->{error}{code};
                }
            };

            if ($error_msg) {
                log_debug('APIManager', "Detected error in 200 response body: $error_msg");
                my $is_rate_limit = $error_code && $error_code =~ /rate.lim/i;
                $self->{response_handler}->release_broker_slot($resp, 200);
                if ($is_rate_limit) {
                    log_info('APIManager', "Rate limit in 200 response body (code=$error_code), treating as 429");
                    $self->{response_handler}{rate_limit_until} = time() + 60;
                    return {
                        success     => 0,
                        error       => $error_msg,
                        retryable   => 1,
                        retry_after => 60,
                        error_type  => 'rate_limit',
                    };
                }
                return {
                    success => 0,
                    error => $error_msg,
                    retryable => 0,
                };
            }
        }
    }

    # Calculate final metrics
    my $end_time = time();
    my $total_duration = $end_time - $s{start_time};
    my $ttft = $s{first_token_time} ? ($s{first_token_time} - $s{start_time}) : undef;
    my $tps = ($total_duration > 0 && $s{token_count} > 0) ? ($s{token_count} / $total_duration) : 0;

    if ($self->{debug}) {
        log_debug('APIManager', sprintf(
            "[DEBUG][APIManager] Streaming complete - TTFT: %.2fs, TPS: %.1f, Tokens: %d, Duration: %.2fs\n",
            $ttft // 0, $tps, $s{token_count}, $total_duration
        ));
    }

    # Persist session if we got a response_id
    if ($self->{session} && $self->{session}{lastGitHubCopilotResponseId}) {
        if (ref($self->{session}) && blessed($self->{session}) && $self->{session}->can('save')) {
            $self->{session}->save();
        }
    }

    # Process rate limit headers
    my $headers_to_use = $s{streaming_headers} || $resp->headers;
    if ($headers_to_use) {
        $self->{response_handler}->process_rate_limit_headers($headers_to_use);
    }

    # Process quota headers for billing tracking (GitHub Copilot only)
    my $endpoint_config = $s{endpoint_config};
    log_debug('APIManager', "Checking quota header conditions: requires_copilot_headers=" .
        ($endpoint_config->{requires_copilot_headers} ? 'yes' : 'no') .
        ", has_headers=" . ($headers_to_use ? 'yes' : 'no') . "\n");

    if ($endpoint_config->{requires_copilot_headers} && $headers_to_use) {
        my $response_id = $self->{session}{lastGitHubCopilotResponseId} || 'unknown';
        log_debug('APIManager', "Calling _process_quota_headers with response_id=$response_id");
        $self->{response_handler}->process_quota_headers($headers_to_use, $response_id);
    } else {
        log_debug('APIManager', "Skipping quota header processing");
    }

    # Estimate usage for billing
    my $final_usage;
    if ($s{streaming_usage}) {
        $final_usage = $s{streaming_usage};
        log_debug('APIManager', "Using real streaming usage: prompt=$final_usage->{prompt_tokens}, completion=$final_usage->{completion_tokens}");
        $self->_learn_from_api_response($final_usage, $s{messages});
    } else {
        my $estimated_completion_tokens = $s{token_count};
        my $estimated_prompt_tokens = 0;
        my $messages = $s{messages};
        if ($messages && ref($messages) eq 'ARRAY') {
            for my $msg (@$messages) {
                if ($msg->{content}) {
                    $estimated_prompt_tokens += int(length($msg->{content}) / 4);
                }
            }
        } elsif ($s{input}) {
            $estimated_prompt_tokens = int(length($s{input}) / 4);
        }
        $final_usage = {
            prompt_tokens => $estimated_prompt_tokens,
            completion_tokens => $estimated_completion_tokens,
            total_tokens => $estimated_prompt_tokens + $estimated_completion_tokens,
        };
        log_debug('APIManager', "Using estimated streaming usage (no real data available)");
    }

    # Convert accumulated tool_calls to array
    my $tool_calls = undef;
    if (keys %{$s{tool_calls_accumulator}}) {
        $tool_calls = [
            map { $s{tool_calls_accumulator}->{$_} }
            sort { $a <=> $b }
            keys %{$s{tool_calls_accumulator}}
        ];
        log_debug('APIManager', "Accumulated " . scalar(@$tool_calls) . " tool calls from streaming");
    }

    # Build response with metrics and estimated usage
    my $response = {
        success => 1,
        content => $s{accumulated_content},
        metrics => {
            ttft => $ttft,
            tps => $tps,
            tokens => $s{token_count},
            duration => $total_duration,
        },
        usage => $final_usage,
    };

    log_debug('APIManager', "[$s{provider_label} STREAMING COMPLETE] accumulated content length: " . length($s{accumulated_content}));
    log_debug('APIManager', "[$s{provider_label} STREAMING COMPLETE] Content preview: '" . substr($s{accumulated_content}, 0, 300) . "'");

    # Add tool_calls if present
    if ($tool_calls) {
        $response->{tool_calls} = $tool_calls;
        log_debug('APIManager', "[$s{provider_label} STREAMING COMPLETE] tool_calls: " . scalar(@$tool_calls) . " calls");
        for my $tc (@$tool_calls) {
            log_debug('APIManager', "[$s{provider_label} TOOL CALL] " . ($tc->{function}{name} || 'unknown') .
                      " args_len=" . length($tc->{function}{arguments} || ''));
        }
    } else {
        log_debug('APIManager', "[$s{provider_label} STREAMING COMPLETE] NO tool_calls in response");
    }

    if (open my $fh, '>>', '/tmp/clio_api_debug.log') {
        print $fh "\n" . "-"x80 . "\n";
        print $fh "[" . scalar(localtime) . "] $s{provider_label} STREAMING RESPONSE COMPLETE\n";
        print $fh "Content length: " . length($s{accumulated_content}) . "\n";
        print $fh "Tool calls: " . ($tool_calls ? scalar(@$tool_calls) : 0) . "\n";
        if ($tool_calls) {
            for my $tc (@$tool_calls) {
                print $fh "  - " . ($tc->{function}{name} || 'unknown') . ": " . substr($tc->{function}{arguments} || '', 0, 200) . "\n";
            }
        }
        print $fh "Content:\n" . substr($s{accumulated_content}, 0, 1000) . "\n";
        close $fh;
    }

    # Include accumulated reasoning_details for MiniMax interleaved thinking
    if (length($s{accumulated_reasoning} // '')) {
        $response->{reasoning_details} = [{ type => 'reasoning.text', text => $s{accumulated_reasoning} }];
        log_debug('APIManager', "Accumulated reasoning_details: " . length($s{accumulated_reasoning}) . " chars");
    }

    # Debug response structure
    if ($self->{debug}) {
        require Data::Dumper;
        log_debug('APIManager', "===== API RESPONSE =====");
        log_debug('APIManager', "Has tool_calls: " . ($response->{tool_calls} ? "YES" : "NO"));
        if ($response->{tool_calls}) {
            log_debug('APIManager', "Tool calls count: " . scalar(@{$response->{tool_calls}}));
            log_debug('APIManager', Data::Dumper->Dump([$response->{tool_calls}], ['tool_calls']));
        }
        log_debug('APIManager', "Content length: " . length($response->{content}));
        log_debug('APIManager', "Content preview: " . substr($response->{content}, 0, 200) . "...");
        log_debug('APIManager', "===== END API RESPONSE =====");
    }

    # Release broker slot on success
    $self->{response_handler}->release_broker_slot($resp, 200);

    return $response;
}

# Async API methods
sub send_request_async {
    my ($self, $input) = @_;
    
    # Prevent multiple concurrent requests
    if (($self->{request_state} // 0) == REQUEST_PENDING) {
        warn "[DEBUG] Request already pending\n" if $self->{debug};
        return 0;
    }
    
    # Reset state
    $self->{request_state} = REQUEST_PENDING;
    $self->{response} = undef;
    $self->{error} = undef;
    $self->{start_time} = time();
    $self->{input} = $input;
    
    # Create message file (use ConfigPath for writable directory)
    my $message_dir = File::Spec->catdir(get_config_dir(), 'messages');
    mkdir $message_dir unless -d $message_dir;
    
    my $message_file = "$message_dir/$$.msg";
    $self->{message_file} = $message_file;
    
    # Make the request directly in this process
    my $response = eval { $self->send_request($input) };
    if ($@) {
        $self->{error} = $@;
        $self->{request_state} = REQUEST_ERROR;
        warn "[ERROR] Request failed: $@\n" if $self->{debug};
        return 0;
    }
    
    # Process completed successfully
    if ($response && $response->{content}) {
        $self->{response} = $response;
        $self->{request_state} = REQUEST_COMPLETE;
        warn "[DEBUG] Request completed with response\n" if $self->{debug};
        return 1;
    }
    
    # No valid response
    $self->{error} = "Invalid response format";
    $self->{request_state} = REQUEST_ERROR;
    warn "[ERROR] Invalid response format\n" if $self->{debug};
    return 0;
}

# Non-blocking event processing
sub process_events {
    my ($self) = @_;
    
    # Process any pending events
    if (($self->{request_state} // 0) == REQUEST_PENDING) {
        # Non-blocking check
        select(undef, undef, undef, 0.1);
        
        # Read response if available
        if ($self->{message_file} && -f $self->{message_file}) {
            eval {
                open(my $fh, '<', $self->{message_file}) or croak "Could not open message file: $!";
                local $/;
                my $json = <$fh>;
                close($fh);
                
                my $result = decode_json($json);
                if ($result->{error}) {
                    $self->{error} = $result->{error};
                    $self->{request_state} = REQUEST_ERROR;
                } else {
                    $self->{response} = $result->{response};
                    $self->{request_state} = REQUEST_COMPLETE;
                }
            };
            if ($@) {
                $self->{error} = "Failed to read response: $@";
                $self->{request_state} = REQUEST_ERROR;
            }
            unlink($self->{message_file});
            $self->{message_file} = undef;
        }
    }
}

sub get_request_state {
    my ($self) = @_;
    
    # Process any pending events
    $self->process_events();
    
    # Return current state
    return $self->{request_state} // REQUEST_NONE;
}

sub get_response {
    my ($self) = @_;
    
    # Update state first
    $self->get_request_state();
    
    # Return response if complete
    return $self->{response} if ($self->{request_state} // 0) == REQUEST_COMPLETE;
    return undef;
}

sub get_error {
    my ($self) = @_;
    
    # Update state first
    $self->get_request_state();
    
    # Return error if any
    return $self->{error} if ($self->{request_state} // 0) == REQUEST_ERROR;
    return undef;
}

sub has_response {
    my ($self) = @_;
    
    # Update state first
    $self->get_request_state();
    
    return ($self->{request_state} // 0) == REQUEST_COMPLETE || 
           ($self->{request_state} // 0) == REQUEST_ERROR;
}

sub _cleanup {
    my ($self) = @_;
    
    if ($self->{message_file} && -f $self->{message_file}) {
        unlink($self->{message_file});
    }
    $self->{message_file} = undef;
    $self->{pid} = undef;
    
    if ($self->{debug}) {
        warn sprintf("[DEBUG] Request complete: State=%s%s\n",
            $self->{request_state},
            $self->{error} ? " Error=$self->{error}" : ""
        );
    }
}

sub _error {
    my ($self, $msg) = @_;
    warn "[APIManager] $msg\n" if $self->{debug};
    return { error => 1, message => $msg };
}

=head2 _get_native_provider()

Check if the current provider uses a native (non-OpenAI-compatible) API
and return the provider handler instance if so.

Returns: Provider instance if native, undef if OpenAI-compatible

=cut

sub _get_native_provider {
    my ($self) = @_;
    
    # Get provider configuration
    my $provider_name = $self->{provider} // 'github_copilot';
    my $provider_config = get_provider($provider_name);
    
    return undef unless $provider_config;
    return undef unless $provider_config->{native_api};
    
    my $module = $provider_config->{provider_module};
    return undef unless $module;
    
    # Load and instantiate the provider module
    eval "require $module";
    if ($@) {
        log_error('APIManager', "Failed to load native provider $module: $@");
        return undef;
    }
    
    my $provider = $module->new(
        api_key => $self->{api_key},
        api_base => $provider_config->{api_base},
        model => $self->{model},
        debug => $self->{debug},
    );
    
    log_debug('APIManager', "Using native provider: $module");
    
    return $provider;
}

=head2 _send_native_streaming($provider, $messages, $tools, %opts)

Send a streaming request using a native provider implementation.

Arguments:
- $provider: Native provider instance (e.g., CLIO::Providers::Anthropic)
- $messages: Array of messages in OpenAI format
- $tools: Array of tool definitions in OpenAI format
- %opts: Options including callbacks (on_chunk, on_tool_call)

Returns: Same format as send_request_streaming

=cut

sub _send_native_streaming {
    my ($self, $provider, $messages, $tools, %opts) = @_;
    
    my $on_chunk = $opts{on_chunk};
    my $on_tool_call = $opts{on_tool_call};
    my $on_thinking = $opts{on_thinking};
    
    # Build the request using the native provider
    my $request = $provider->build_request($messages, $tools, {
        model => $opts{model} // $self->{model},
        max_tokens => $opts{max_tokens} // $self->_get_max_output_tokens($opts{model} // $self->{model}),
        temperature => $opts{temperature} // 0.2,
    });
    
    # Initialize tracking
    my $start_time = time();
    my $first_token_time;
    my $accumulated_content = '';
    my @tool_calls;
    my $current_tool_call;
    my $token_count = 0;
    my $buffer = '';
    
    # Create HTTP client
    my $ua = CLIO::Compat::HTTP->new(
        timeout => 300,
        agent => 'CLIO/1.0',
        ssl_opts => { verify_hostname => 1 },
    );
    
    # Build HTTP request
    require HTTP::Request;
    my $http_req = HTTP::Request->new(
        $request->{method} => $request->{url}
    );
    
    for my $header (keys %{$request->{headers}}) {
        $http_req->header($header => $request->{headers}{$header});
    }
    $http_req->content($request->{body});
    
    log_debug('APIManager', "Native request to: $request->{url}");
    
    # Make streaming request
    my $response;
    eval {
        $response = $ua->request($http_req, sub {
            my ($chunk, $resp, $proto) = @_;
            
            $buffer .= $chunk;
            
            # Normalize CRLF to LF for providers that use \r\n line endings
            $buffer =~ s/\r\n/\n/g;
            
            # Process complete SSE events
            while ($buffer =~ s/^(.*?)\n//s) {
                my $line = $1;
                
                my $event = $provider->parse_stream_event($line);
                next unless $event;
                
                my $type = $event->{type};
                
                if ($type eq 'text') {
                    # Record first token time
                    $first_token_time //= time();
                    $token_count++;
                    
                    $accumulated_content .= $event->{content};
                    
                    # Call chunk callback
                    if ($on_chunk) {
                        $on_chunk->($event->{content});
                    }
                }
                elsif ($type eq 'thinking_start' || $type eq 'thinking' || $type eq 'thinking_end') {
                    # Thinking/reasoning content from provider
                    if ($on_thinking) {
                        if ($type eq 'thinking') {
                            $on_thinking->($event->{content});
                        } elsif ($type eq 'thinking_start') {
                            $on_thinking->(undef, 'start');
                        } elsif ($type eq 'thinking_end') {
                            $on_thinking->(undef, 'end');
                        }
                    }
                }
                elsif ($type eq 'tool_start') {
                    $current_tool_call = {
                        id => $event->{id},
                        type => 'function',
                        function => {
                            name => $event->{name},
                            arguments => '',
                        },
                    };
                }
                elsif ($type eq 'tool_args') {
                    if ($current_tool_call) {
                        $current_tool_call->{function}{arguments} .= $event->{content};
                    }
                }
                elsif ($type eq 'tool_end') {
                    # Google sends complete tool calls as a single tool_end event (no preceding tool_start).
                    # Other providers stream tool args and send tool_end to finalize.
                    if (!$current_tool_call && $event->{name}) {
                        # Complete tool call in one event (Google-style)
                        $current_tool_call = {
                            id => $event->{id},
                            type => 'function',
                            function => {
                                name => $event->{name},
                                arguments => '',
                            },
                        };
                    }

                    if ($current_tool_call) {
                        # Parse arguments - either from event or already in current_tool_call
                        if ($event->{arguments}) {
                            $current_tool_call->{function}{arguments} =
                                encode_json($event->{arguments});
                        }

                        push @tool_calls, $current_tool_call;

                        if ($on_tool_call) {
                            $on_tool_call->($current_tool_call);
                        }

                        $current_tool_call = undef;
                    }
                }
                elsif ($type eq 'error') {
                    croak "API Error: $event->{message}";
                }
            }
        });
    };
    
    if ($@) {
        my $error = $@;
        log_error('APIManager', "Native streaming failed: $error");
        return {
            success => 0,
            error => $error,
        };
    }
    
    # Check HTTP status
    if (!$response->is_success) {
        my $status = $response->code;
        my $body = $response->decoded_content // '';
        
        log_error('APIManager', "Native API error $status: $body");
        
        return {
            success => 0,
            error => "HTTP $status: $body",
            retryable => ($status == 429 || $status >= 500),
        };
    }
    
    # Calculate metrics
    my $end_time = time();
    my $duration = $end_time - $start_time;
    my $ttft = $first_token_time ? ($first_token_time - $start_time) : $duration;
    my $tps = $duration > 0 ? $token_count / $duration : 0;
    
    # Build response
    my $result = {
        success => 1,
        content => $accumulated_content,
        metrics => {
            ttft => $ttft,
            tps => $tps,
            tokens => $token_count,
            duration => $duration,
        },
    };
    
    # Add estimated usage (native providers may not provide real usage)
    $result->{usage} = {
        prompt_tokens => 0,
        completion_tokens => $token_count,
        total_tokens => $token_count,
    };
    
    # Add tool calls if present
    if (@tool_calls) {
        $result->{tool_calls} = \@tool_calls;
        $result->{finish_reason} = 'tool_calls';
    } else {
        $result->{finish_reason} = 'stop';
    }
    
    return $result;
}

1;