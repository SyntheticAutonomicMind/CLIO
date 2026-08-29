# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::APIManager;

=head1 NAME

CLIO::Core::APIManager - AI provider API communication and request orchestration

=head1 DESCRIPTION

Manages communication with AI model providers (GitHub Copilot, Google, MiniMax, etc.).
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
use CLIO::Core::Logger qw(should_log log_debug log_error log_info log_warning);
use CLIO::Core::ErrorContext qw(classify_error format_error);
use CLIO::Util::ConfigPath qw(get_config_dir);
use CLIO::Providers qw(get_provider list_providers provider_from_url);
use POSIX ":sys_wait_h"; # For WNOHANG
use Time::HiRes qw(time sleep);  # High resolution time and sleep
use CLIO::Util::JSON qw(encode_json decode_json safe_decode_json safe_encode_json);
use Carp qw(croak);
use CLIO::Compat::HTTP;
BEGIN { require CLIO::Compat::HTTP; CLIO::Compat::HTTP->import(); }
use Scalar::Util qw(blessed looks_like_number);
use CLIO::Core::PerformanceMonitor;
use CLIO::Core::API::MessageValidator qw(
    validate_and_truncate
    validate_tool_message_pairs
    preflight_validate
);
use CLIO::Core::API::PayloadSanitizer qw(sanitize_payload);
use CLIO::Core::API::ResponseHandler;
use CLIO::Util::TextSanitizer qw(sanitize_text);
use CLIO::UI::Terminal qw(ui_char);
use CLIO::Core::RateLimiter;
use CLIO::Util::CABundle;
use CLIO::Core::Defaults qw(DEFAULT_MAX_OUTPUT_TOKENS DEFAULT_CONTEXT_WINDOW DEFAULT_LOCAL_CONTEXT_WINDOW DEFAULT_MAX_RESPONSE_TOKENS);

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

# No external dependencies, only core Perl

# Generate a UUID v4 for request tracking headers
sub _generate_uuid {
    # Self-contained entropy pool using xorshift32 seeded from time/PID/counter.
    # Avoids Perl's rand() entirely: a stray srand() call elsewhere in the
    # process (e.g. from a module that seeds for reproducibility) would
    # otherwise poison UUID randomness without us knowing.
    our $UUID_COUNTER = 0;
    $UUID_COUNTER++;
    my $entropy = (Time::HiRes::time() * 1_000_000) ^ $$ ^ (0 + \$UUID_COUNTER) ^ ($UUID_COUNTER * 0x9E3779B9);

    my @hex = ('0'..'9', 'a'..'f');
    my $uuid = '';
    for my $i (1..32) {
        # xorshift32 step to mix entropy per character
        $entropy ^= ($entropy << 13) & 0xFFFFFFFF;
        $entropy ^= ($entropy >> 17) & 0xFFFFFFFF;
        $entropy ^= ($entropy << 5)  & 0xFFFFFFFF;
        $uuid .= $hex[$entropy & 0xF];
        $uuid .= '-' if $i == 8 || $i == 12 || $i == 16 || $i == 20;
    }
    # Set version (4) and variant (8, 9, a, or b)
    substr($uuid, 14, 1) = '4';
    substr($uuid, 19, 1) = $hex[8 + ($entropy & 0x3)];
    return $uuid;
}

# Create an HTTP client with proxy config from CLIO config
sub _create_http_client {
    my ($self, %opts) = @_;
    my $proxy = $self->{config} ? ($self->{config}->get('http_proxy') || '') : '';
    $opts{proxy} = $proxy if $proxy;
    return CLIO::Compat::HTTP->new(%opts);
}

# Get or create a shared HTTP client for connection pooling
# Reuses the same client for multiple requests to enable keep-alive
sub _get_shared_http_client {
    my ($self, %opts) = @_;
    
    # Create a cache key based on options that affect connection behavior
    my $cache_key = join('|', 
        $opts{timeout} || 300,
        $opts{proxy} || '',
        $opts{agent} || '',
        $opts{ssl_opts} ? _ssl_opts_key($opts{ssl_opts}) : 'no_ssl'
    );
    
    $self->{_http_client_cache} ||= {};
    
    unless ($self->{_http_client_cache}{$cache_key}) {
        my $proxy = $self->{config} ? ($self->{config}->get('http_proxy') || '') : '';
        $opts{proxy} = $proxy if $proxy && !$opts{proxy};
        $self->{_http_client_cache}{$cache_key} = CLIO::Compat::HTTP->new(%opts);
        log_debug('APIManager', "Created new shared HTTP client (cache_key=$cache_key)");
    }
    
    return $self->{_http_client_cache}{$cache_key};
}

# Build a stable cache key from ssl_opts hashref. Keys are sorted so the
# key is order-independent. Used to differentiate HTTP clients configured
# with different TLS verification settings.
sub _ssl_opts_key {
    my ($opts) = @_;
    return 'ssl:empty' unless ref($opts) eq 'HASH' && keys %$opts;
    my @pairs;
    for my $k (sort keys %$opts) {
        my $v = $opts->{$k};
        $v = defined $v ? $v : '\undef';
        push @pairs, "$k=$v";
    }
    return 'ssl:' . join(',', @pairs);
}

# Check if a model supports reasoning/thinking parameters via models API
# Falls back to pattern matching if API data unavailable
sub _model_supports_reasoning {
    my ($self, $model) = @_;
    return 0 unless $model;

    # Use get_model_capabilities which applies user overrides and caches raw caps
    my $caps = $self->get_model_capabilities($model);
    if ($caps && defined $caps->{supports_reasoning}) {
        return $caps->{supports_reasoning};
    }

    # Pattern-based fallback for known reasoning models
    # MiniMax M2.x and M3 models support interleaved thinking natively
    if ($model =~ /^MiniMax-M[23]/i) {
        return 1;
    }
    # Check provider registry for reasoning support (via endpoint_config if available on self)
    # This is a last-resort fallback - prefer endpoint_config->{supports_reasoning} in callers
    if ($self->{_current_endpoint_config} && $self->{_current_endpoint_config}{supports_reasoning}) {
        return 1;
    }

    # Default: don't send reasoning params for unknown models
    return 0;
}

=head2 _get_reasoning_mode($model)

Get the reasoning mode from model capabilities.
Returns 'effort', 'enabled', 'adaptive', or undef.

=cut

sub _get_reasoning_mode {
    my ($self, $model) = @_;
    return undef unless $model;
    
    my $caps = $self->get_model_capabilities($model);
    return undef unless $caps && $caps->{supports_reasoning};
    return $caps->{reasoning_mode};
}

# Recursive sanitization of data structures before JSON encoding
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
            print "[" . ui_char("check") . "] GitHub Copilot: Authenticated as $username\n";
        } else {
            print "[" . ui_char("cross_mark") . "] GitHub Copilot: Not authenticated (use /login)\n";
        }
    };
    
    # API configuration from Config object
    if ($config && $config->can('get')) {
        my $provider = $config->get('provider') || 'openai';
        my $api_base = $config->get('api_base') || '(not set)';
        my $model = $config->get('model') || '(not set)';
        my $api_key = $config->get('api_key');
        
        print "[" . ui_char("check") . "] Provider: $provider\n";
        print "[" . ui_char("check") . "] API Base: $api_base\n";
        print "[" . ui_char("check") . "] Model: $model\n";
        
        if ($api_key) {
            my $key_display = substr($api_key, 0, 8) . '...' . substr($api_key, -4);
            print "[" . ui_char("check") . "] API Key: $key_display\n";
        } else {
            print "[ ] API Key: NOT SET (required unless using GitHub auth)\n";
        }
    } else {
        print "[" . ui_char("check") . "] Config object not available\n";
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
    unless ($config && blessed($config) && $config->can('get')) {
        croak "APIManager requires Config object (got: " . (ref($config) // 'undef') . ")";
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
        
        # Cache for prompt_stable_prefix_tokens keyed on MD5 of system
        # prompt content. The stable prefix token count must NOT change
        # between requests when the system prompt is byte-identical, even
        # though the learned char/token ratio drifts. A changing value
        # breaks llama.cpp's LCP cache match and forces full prompt
        # reprocessing every turn (5+ min on local models).
        _stable_prefix_cache => undef,

        # Rate limiter for concurrent request limiting
        rate_limiter => CLIO::Core::RateLimiter->get_instance(),

        %args,
    };
    bless $self, $class;

    # Configure RateLimiter with provider-specific model concurrency limits
    # (e.g. DeepSeek's 500 concurrent for v4-pro, 2500 for v4-flash).
    # Must run AFTER the RateLimiter singleton is created and BEFORE the
    # first request so model-specific caps are in place.
    eval {
        CLIO::Providers::configure_rate_limiter($self->{rate_limiter});
    };
    if ($@) {
        log_warning('APIManager', "configure_rate_limiter failed: $@");
    }

    # Initialize response handler for rate limiting, error handling, quota tracking
    $self->{response_handler} = CLIO::Core::API::ResponseHandler->new(
        session       => $args{session},
        broker_client => $args{broker_client},
        debug         => $args{debug} // 0,
    );
    # Give ResponseHandler a reference back to us for throttle learning
    # triggers (e.g. OpenAI "Slow Down" 503 -> report_rate_limit_for_model).
    $self->{response_handler}->set_apimanager($self);
    
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
    
    # Determine if this is a GitHub Copilot provider (check both api_base URL and provider name)
    my $is_copilot_provider = 0;
    my $detected = provider_from_url($self->{api_base} // '');
    if ($detected && $detected eq 'github-copilot') {
        $is_copilot_provider = 1;
    }
    if (!$is_copilot_provider && $self->{config} && $self->{config}->can('get')) {
        my $provider = $self->{config}->get('provider') || '';
        require CLIO::Providers;
        my $pdef = CLIO::Providers::get_provider($provider);
        $is_copilot_provider = 1 if $pdef && $pdef->{requires_auth} && $pdef->{requires_auth} eq 'copilot';
    }
    
    # Step 1: Try a simple refresh (re-exchange existing GitHub token)
    if ($is_copilot_provider) {
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
    # Must check BOTH api_base URL AND provider name because users may override
    # api_base to a proxy (e.g. http://flip:9090) while still using GitHub auth.
    my $is_copilot_provider = 0;
    my $detected_provider = provider_from_url($self->{api_base} // '');
    if ($detected_provider && $detected_provider eq 'github-copilot') {
        $is_copilot_provider = 1;
    }
    # Also check by provider name (handles custom api_base proxies)
    if (!$is_copilot_provider && $self->{config} && $self->{config}->can('get')) {
        my $provider = $self->{config}->get('provider') || '';
        require CLIO::Providers;
        my $pdef = CLIO::Providers::get_provider($provider);
        $is_copilot_provider = 1 if $pdef && $pdef->{requires_auth} && $pdef->{requires_auth} eq 'copilot';
    }
    
    if ($is_copilot_provider) {
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
        
        # GitHub Copilot not authenticated via GitHub - will fall through to check static key
        log_info('APIManager', "GitHub Copilot not authenticated via GitHub, checking for static key");
    }
    
    # Priority 2: Config api_key (fallback for GitHub Copilot or primary for other providers)
    if ($self->{config} && $self->{config}->can('get')) {
        my $key = $self->{config}->get('api_key');
        if ($key && length($key) > 0) {
            log_debug('APIManager', "Using API key from Config");
            # Set using_exchanged_token so Editor-Version header is sent
            # This is needed for github_copilot to recognize the PAT properly
            $self->{using_exchanged_token} = 1 if $is_copilot_provider;
            return $key;
        }
    }
    
    # Priority 3: Environment variable (for remote execution and CI/CD)
    if ($ENV{CLIO_API_KEY} && length($ENV{CLIO_API_KEY}) > 0) {
        log_debug('APIManager', "Using API key from CLIO_API_KEY environment variable");
        $self->{using_exchanged_token} = 1 if $is_copilot_provider;
        return $ENV{CLIO_API_KEY};
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
    
    # Priority 1: Explicit model set on this instance (e.g., sub-agent model)
    # This takes precedence over Config, which may contain the parent session's model.
    if ($self->{model}) {
        return $self->{model};
    }
    
    # Priority 2: Config is the authority for the main session
    if ($self->{config} && $self->{config}->can('get')) {
       my $model = $self->{config}->get('model');
       if ($model) {
            # If model is just a provider name (no "/"), resolve it to a real model
            if ($model !~ m{/}) {
                my $resolved = $self->_resolve_model_placeholder($model);
                if ($resolved && $resolved ne $model) {
                    $model = $resolved;
                    $self->{config}->set('model', $model, 0);
                    eval { $self->{config}->save(); };
                    log_warning('APIManager', "Failed to persist resolved model '$model' to config: $@") if $@;
                }
            }
           return $model;
       }
    }
    
    # Fallback (should never happen if config is properly initialized)
   log_warning('APIManager', "No model in config, using default");
   require CLIO::Providers;
   return CLIO::Providers::DEFAULT_MODEL();
}

# Resolve a model placeholder (provider name only, e.g. "deepseek")
# into a real model like "deepseek/deepseek-v4-pro" by querying /v1/models.
sub _resolve_model_placeholder {
    my ($self, $placeholder) = @_;
    
    return $placeholder unless $placeholder;

# Cycle to the next model in the routing candidates list.
# Used by model routing: when an API error occurs, this switches to the
# next provider/model in the candidates list so the next request uses
# a different upstream. The _prepare_endpoint_config method resolves the
# provider/api_base/api_key from the model's prefix on each call, so
# updating the config model is sufficient for cross-provider routing.
#
# Arguments: none
# Returns: ($new_model, $old_model) or (undef, undef) if no candidates

sub cycle_model {
    my ($self) = @_;

    my $candidates = $self->{config}->get_model_candidates()
        if $self->{config} && $self->{config}->can('get_model_candidates');
    return (undef, undef) unless $candidates && ref($candidates) eq 'ARRAY' && @$candidates > 1;

    my $idx = $self->{config}->get_model_routing_index() // 0;
    $idx = ($idx + 1) % scalar(@$candidates);
    $self->{config}->set_model_routing_index($idx)
        if $self->{config}->can('set_model_routing_index');

    my $old_model = $self->get_current_model();
    my $new_model = $candidates->[$idx];
    $self->{config}->set('model', $new_model, 0);  # 0 = don't mark as user_set (temp override)
    $self->{model} = $new_model;  # Also set on instance for immediate use

    # Reset learned state for the new model
    $self->{_model_capabilities_cache} = undef;

    log_info('APIManager', "Model routing: switched from '$old_model' to '$new_model' (index $idx)");

    return ($new_model, $old_model);
}

# Check if model routing is active (candidates list has more than 1 model).
# Returns the number of candidates, or 0 if routing is not active.

sub model_routing_active {
    my ($self) = @_;
    return 0 unless $self->{config} && $self->{config}->can('get_model_candidates');
    my $candidates = $self->{config}->get_model_candidates();
    return 0 unless $candidates && ref($candidates) eq 'ARRAY' && @$candidates > 1;
    return scalar(@$candidates);
}
    
    require CLIO::Providers;
    return $placeholder unless CLIO::Providers::provider_exists($placeholder);
    
    $self->{_model_placeholder_cache} ||= {};
    return $self->{_model_placeholder_cache}{$placeholder}
        if exists $self->{_model_placeholder_cache}{$placeholder};
    
    my $provider_def = CLIO::Providers::get_provider($placeholder);
    my $api_base = $provider_def->{api_base};
    
    if ($self->{config}) {
        my $stored_base = $self->{config}->get_provider_base($placeholder);
        $api_base = $stored_base if $stored_base;
    }
    
    my ($api_type, $models_url) = $self->_detect_api_type_and_url($api_base);
    unless ($models_url) {
        log_debug('APIManager', "Cannot resolve model for $placeholder: no models endpoint");
        return $placeholder;
    }
    
   my $needs_auth = $provider_def->{requires_auth} && $provider_def->{requires_auth} ne 'none';
    my $api_key = $needs_auth ? $self->_get_api_key() : '';
   unless (!$needs_auth || $api_key) {
        return $placeholder;
    }
    
    my $ua = $self->_create_http_client(timeout => 10);
    my %headers = ('Authorization' => "Bearer $api_key");
    $headers{'Editor-Version'} = 'CLIO/1.0' if $api_type eq 'github-copilot';
    
    if ($api_type eq 'google') {
        $models_url .= "?key=$api_key";
        delete $headers{'Authorization'};
    }
    
    my $resp = eval { $ua->get($models_url, headers => \%headers) };
    unless ($resp && $resp->is_success) {
        log_debug('APIManager', "Model discovery failed for placeholder '$placeholder' ($models_url): "
            . ($@ ? "eval: $@" : ($resp ? $resp->status_line : 'no response')));
        return $placeholder;
    }
    
    my $data = safe_decode_json($resp->decoded_content);
    return $placeholder if $@ || !$data;
    
    my @model_ids;
    if ($api_type eq 'google' && $data->{models}) {
        @model_ids = map { (my $n = ($_->{name} || '')) =~ s{^models/}{}; $n } @{$data->{models}};
    } elsif ($data->{data}) {
        @model_ids = map { $_->{id} || () } @{$data->{data}};
    }
    
    for my $id (@model_ids) {
        next if $id =~ m{^/} || $id =~ m{\.gguf$}i;
        my $resolved = "$placeholder/$id";
        log_info('APIManager', "Resolved model $placeholder -> $resolved");
        return $self->{_model_placeholder_cache}{$placeholder} = $resolved;
    }
    
    if (@model_ids) {
        my $id = $model_ids[0];
        $id =~ s{.*/}{};
        $id =~ s{\.gguf$}{}i;
        my $resolved = "$placeholder/$id";
        return $self->{_model_placeholder_cache}{$placeholder} = $resolved;
    }
    
    return $placeholder;
}

# Get current provider - reads from Config (PUBLIC method)
sub get_current_provider {
    my ($self) = @_;
    
    # Config is the authority (set_provider configures this correctly)
    if ($self->{config} && $self->{config}->can('get')) {
        my $provider = $self->{config}->get('provider');
        if ($provider) {
            return $provider;
        }
    }
    
    # Fallback: infer provider from model prefix (e.g., "minimax/MiniMax-M3")
    if ($self->{model} && $self->{model} =~ m{^([a-z][a-z0-9_.-]*)/}i) {
        require CLIO::Providers;
        if (CLIO::Providers::provider_exists($1)) {
            return $1;
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

# Token-aware throttling for Anthropic ITPM/OTPM.
#
# Anthropic enforces per-model per-minute token caps in addition to RPM
# (ITPM = input tokens per minute, OTPM = output tokens per minute). The
# request-count throttle above is unchanged, but it can ship a small number
# of large requests that still blow ITPM. Track a sliding 60-second window
# of input tokens consumed per model so the preflight delay grows as we
# approach the ITPM bucket's limit.
#
# Two layers:
#   1. Snapshot - last seen `anthropic-ratelimit-input-tokens-*` values.
#      Used to compute an exact delay against the API-reported remaining
#      capacity and reset window. Most precise signal; resets after the
#      bucket refills.
#   2. Learned limit - the model's ITPM observed at the moment of a 429.
#      Used as fallback when we don't yet have a fresh snapshot.
#
# Both layers feed `_model_input_token_throttle_check($model, $pending)`,
# which returns seconds to wait before sending the next request.

sub _model_input_token_throttle_record {
    my ($self, $model, $tokens) = @_;
    return unless defined $model && length $model;
    return unless defined $tokens && $tokens > 0;

    $self->{_model_input_token_window} //= {};
    my $window = $self->{_model_input_token_window}{$model} //= [];
    my $now = time();
    @$window = grep { $_->{t} > $now - 60 } @$window;
    push @$window, { t => $now, tokens => int($tokens) };
}

sub _model_input_token_throttle_check {
    my ($self, $model, $pending_tokens) = @_;
    return 0 unless $model;
    return 0 if $self->{broker_client};

    $pending_tokens //= 0;
    $self->{_model_input_token_window} //= {};
    $self->{_model_input_token_limits} //= {};
    my $window = $self->{_model_input_token_window}{$model} //= [];
    my $now    = time();
    @$window   = grep { $_->{t} > $now - 60 } @$window;
    my $used   = 0;
    $used += $_->{tokens} for @$window;

    # Layer 1: API-reported snapshot. Most accurate when fresh.
    my $snap = $self->{_anthropic_rate_limits}{$model};
    my $snap_delay;
    if ($snap && $snap->{input_tokens} && $snap->{input_tokens}{limit} > 0) {
        my $itpm = $snap->{input_tokens};
        if (($now - ($itpm->{observed_at} // 0)) <= 90) {
            my $would = $used + $pending_tokens;
            my $ratio = $would / $itpm->{limit};
            if ($ratio >= 1.0) {
                # The snapshot's reset_in is computed relative to its observed_at.
                # Adjust for elapsed time since the header was received so we don't
                # wait longer than the bucket actually needs to refill.
                my $elapsed        = $now - ($itpm->{observed_at} // $now);
                my $effective_reset = ($itpm->{reset_in} // 0) - $elapsed;
                $effective_reset   = 0 if $effective_reset < 0;
                $snap_delay = $effective_reset > 0 ? ($effective_reset + 1) : 0.5;
            }
            elsif ($ratio >= 0.7) {
                my $gap = $would - 0.7 * $itpm->{limit};
                # Same elapsed-time adjustment as the >= 1.0 branch.
                my $elapsed        = $now - ($itpm->{observed_at} // $now);
                my $reset_in       = (($itpm->{reset_in} // 60) - $elapsed);
                $reset_in          = 0 if $reset_in < 0;
                my $refill_per_sec = $itpm->{limit} / 60;
                my $delay = ($gap > 0 && $refill_per_sec > 0)
                    ? ($gap / $refill_per_sec)
                    : 0;
                $delay = 0.5 if $delay > 0 && $delay < 0.5;
                $delay = $reset_in if $delay > $reset_in;
                $delay = 10    if $delay > 10;
                $snap_delay = $delay;
            }
        }
    }

    # Layer 2: learned ITPM. Used when we have no snapshot, or it is stale.
    my $learned_delay;
    my $limit = $self->{_model_input_token_limits}{$model};
    if (defined $limit && $limit > 0) {
        my $would = $used + $pending_tokens;
        my $pct = $would / $limit;
        if ($pct >= 1.0) {
            my $oldest = $window->[0]{t} // $now;
            my $window_remaining = 60 - ($now - $oldest);
            $learned_delay = ($window_remaining > 0) ? ($window_remaining + 1) : 2;
        }
        elsif ($pct >= 0.7) {
            my $oldest = $window->[0]{t} // $now;
            my $window_remaining = 60 - ($now - $oldest);
            my $gap = $would - 0.7 * $limit;
            my $refill_per_sec = $limit / 60;
            my $delay = ($gap > 0 && $refill_per_sec > 0)
                ? ($gap / $refill_per_sec)
                : 0;
            $delay = 0.5 if $delay > 0 && $delay < 0.5;
            $delay = $window_remaining + 1 if $delay > $window_remaining + 1;
            $learned_delay = $delay;
        }
    }

    return $snap_delay    if defined $snap_delay    && defined $learned_delay && $snap_delay >= $learned_delay;
    return $learned_delay if defined $learned_delay;
    return $snap_delay    if defined $snap_delay;
    return 0;
}

sub _apply_anthropic_rate_limit_headers {
    my ($self, $model, $rl_info) = @_;
    return unless ref($rl_info) eq 'HASH' && $model;

    $self->{_anthropic_rate_limits} //= {};
    my $snapshot = $self->{_anthropic_rate_limits}{$model} = {};
    my $any;
    my $now = time();

    require CLIO::Util::RateLimit;

    for my $bucket (qw(requests tokens input_tokens output_tokens)) {
        my $limit_key = "anthropic_${bucket}_limit";
        my $rem_key   = "anthropic_${bucket}_remaining";
        my $reset_key = "anthropic_${bucket}_reset";
        next unless defined $rl_info->{$limit_key} && defined $rl_info->{$rem_key};
        my $limit     = 0 + ($rl_info->{$limit_key} // 0);
        my $remaining = 0 + ($rl_info->{$rem_key}   // 0);
        my $reset_in  = CLIO::Util::RateLimit::parse_anthropic_reset_timestamp($rl_info->{$reset_key});
        $snapshot->{$bucket} = {
            limit       => $limit,
            remaining   => $remaining,
            reset_in    => $reset_in,
            observed_at => $now,
        };
        $any++;
    }

    if ($snapshot->{input_tokens} && $snapshot->{input_tokens}{limit} > 0) {
        $self->_learn_input_token_limit($model, undef, $snapshot->{input_tokens}{limit});
    }

    delete $self->{_anthropic_rate_limits}{$model} unless $any;
}

sub _learn_input_token_limit {
    my ($self, $model, $observed_tokens, $explicit_limit) = @_;
    return unless $model;

    $self->{_model_input_token_limits} //= {};
    my $existing = $self->{_model_input_token_limits}{$model};

    if (defined $explicit_limit && $explicit_limit > 0) {
        if (!defined $existing || $explicit_limit < $existing) {
            $self->{_model_input_token_limits}{$model} = int($explicit_limit);
            log_info('APIManager', sprintf(
                "Anthropic ITPM limit for %s seeded from headers: %d tokens/60s (was %s)",
                $model, int($explicit_limit), $existing // 'unknown'));
        }
        return;
    }

    return unless defined $observed_tokens && $observed_tokens > 0;
    my $new_limit = $observed_tokens > 1 ? int($observed_tokens - 1) : 1;
    if (!defined $existing || $new_limit < $existing) {
        $self->{_model_input_token_limits}{$model} = $new_limit;
        log_info('APIManager', "Learned input token limit for $model: $new_limit tokens/60s (was " . ($existing // 'unknown') . ")");
    }
}

sub _sliding_window_input_tokens {
    my ($self, $model) = @_;
    return 0 unless $model;
    my $window = $self->{_model_input_token_window}{$model} // return 0;
    my $now = time();
    my $sum = 0;
    $sum += $_->{tokens} for grep { $_->{t} > $now - 60 } @$window;
    return $sum;
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
        # Use model_supports_tools (goes through get_model_capabilities which
        # applies user overrides from /api set tools).
        if (!$self->model_supports_tools($model)) {
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
    
    # Data-driven reasoning parameter injection.
    # Driven by reasoning_schema from provider-defaults.json (propagated
    # via build_endpoint_config). Replaces the 5 provider-specific
    # if-blocks (OpenRouter, OpenAI-compat, MiniMax, Z.AI, DeepSeek)
    # with a unified dispatcher handling all param formats: effort,
    # nested, think_object, mixed, disabled, native.
    $self->_inject_reasoning_params($payload, $endpoint_config);

    # Sampling parameter priority (highest to lowest):
    #   1. Caller opts (already in $payload from _build_payload)
    #   2. User /api set sampling_temperature|top_p|top_k config
    #   3. Provider endpoint sampling_defaults (registry-recommended values)
    # User config must run BEFORE provider defaults so the
    # `next if exists $payload->{$param}` skip doesn't drop user values
    # that the provider default would otherwise have filled in.
    if ($self->{config}) {
        for my $param (qw(temperature top_p top_k)) {
            my $val = $self->{config}->get("sampling_$param");
            next unless defined $val && $val ne '';
            next if exists $payload->{$param};  # caller opts win
            $payload->{$param} = $val + 0;
        }
    }

    # Provider-recommended sampling defaults fill in any param the caller
    # and user config both left unset.
    if (my $sd = $endpoint_config->{sampling_defaults}) {
        for my $param (qw(temperature top_p top_k)) {
            next unless defined $sd->{$param};
            next if exists $payload->{$param};
            $payload->{$param} = $sd->{$param};
        }
    }

    return $payload;
}

=head2 _inject_reasoning_params($payload, $endpoint_config)

Data-driven reasoning parameter injection.

Reads reasoning_schema from endpoint_config (propagated from
provider-defaults.json via build_endpoint_config) and injects the
appropriate thinking/reasoning parameters into $payload.

Schema modes:
  disabled     - Never send reasoning params (llama.cpp, LM Studio,
                 Ollama, SAM). Models that support reasoning think
                 automatically; no param is needed.
  native       - Handled by provider's native API (Anthropic, Google).
                 Skip OpenAI-compat injection here.
  effort       - Top-level string param (OpenAI, DeepSeek, NVIDIA,
                 GitHub Copilot). Sets $payload->{reasoning_effort}.
  nested       - Nested object (OpenRouter). Sets
                 $payload->{reasoning} = {enabled, effort}.
  think_object - MiniMax-style thinking object. Sets
                 $payload->{thinking} = {type, budget_tokens}.
                 Always sends a thinking param when the model
                 supports reasoning (type=disabled when the user
                 hasn't opted in).
  mixed        - Z.AI-style: thinking object + top-level effort. Sets
                 $payload->{thinking} = {type: enabled} and
                 $payload->{reasoning_effort} = value.

Side-effect flags (always applied regardless of thinking gate):
  delete_stream_options  - Remove stream_options from payload
  max_tokens_rename       - Rename max_tokens to specified param
  reasoning_split         - Add reasoning_split => true
  message_transform       - Apply message format transform (e.g. "minimax")
  coding_plan_peak        - Track Z.AI peak-hour pricing multiplier

=cut

sub _inject_reasoning_params {
    my ($self, $payload, $endpoint_config) = @_;

    my $schema = $endpoint_config->{reasoning_schema};
    return unless $schema && ref($schema) eq 'HASH';

    my $mode = $schema->{mode} || 'disabled';

    # --- Side-effect adaptations (always applied) ---

    if ($schema->{delete_stream_options}) {
        delete $payload->{stream_options};
    }

    if ($schema->{max_tokens_rename} && exists $payload->{max_tokens}) {
        $payload->{$schema->{max_tokens_rename}} = delete $payload->{max_tokens};
    }

    if ($schema->{reasoning_split}) {
        $payload->{reasoning_split} = \1;
    }

    if ($schema->{message_transform} && $schema->{message_transform} eq 'minimax') {
        if ($payload->{messages} && ref($payload->{messages}) eq 'ARRAY') {
            $payload->{messages} = _transform_messages_for_minimax($payload->{messages});
        }
    }

    # Peak-hour tracking for Z.AI Coding Plan (GLM-5.x costs 3x
    # 14:00-18:00 CST / 06:00-10:00 UTC)
    if ($schema->{coding_plan_peak} && $endpoint_config->{coding_plan} && $payload->{model}) {
        my $model_lc = lc($payload->{model});
        if ($model_lc =~ /^glm-5/) {
            my @now = gmtime(time());
            my $utc_hour = $now[2];
            my $cst_hour = ($utc_hour + 8) % 24;
            if ($self->{session}) {
                my $state = $self->{session}->can('state') ? $self->{session}->state() : $self->{session};
                if ($cst_hour >= 14 && $cst_hour < 18) {
                    $state->{zai_peak_hour} = 1;
                    $state->{zai_peak_multiplier} = 3;
                    log_debug('APIManager', "Z.AI Coding Plan: Peak hours active (CST 14:00-18:00), GLM-5.x costs 3x quota");
                } else {
                    $state->{zai_peak_hour} = 0;
                    $state->{zai_peak_multiplier} = 2;
                }
            }
        }
    }

    # --- Param injection (gated on mode + user config) ---

    # Skip param injection for providers that opt out or use native API
    return if $mode eq 'disabled' || $mode eq 'native';
    return if $endpoint_config->{requires_no_reasoning};

    # Read user config for thinking control
    my $show_thinking = $self->{config} ? $self->{config}->get('show_thinking') : 0;
    my $thinking_mode = $self->{config} ? ($self->{config}->get('thinking_mode') // 'auto') : 'auto';
    my $model = $payload->{model} // '';

    # Determine if the model supports reasoning
    my $reasoning_mode = $model ? $self->_get_reasoning_mode($model) : undef;
    my $model_supports;
    if ($mode eq 'nested') {
        # OpenRouter: endpoint-level supports_reasoning OR model-level
        $model_supports = $endpoint_config->{supports_reasoning}
            || ($model && $self->_model_supports_reasoning($model));
    } else {
        # effort / think_object / mixed: check model-level reasoning_mode
        $model_supports = $reasoning_mode ? 1 : 0;
    }

    # Unified gate (same for all modes):
    # thinking_mode=enabled: force ON (requires model support)
    # thinking_mode=auto:    gate on show_thinking (requires model support)
    # thinking_mode=disabled: never send reasoning params
    my $send = ($thinking_mode eq 'enabled' && $model_supports)
        || ($thinking_mode eq 'auto' && $show_thinking && $model_supports);

    # For think_object mode, the model always expects a thinking param
    # (even type=disabled) when it supports reasoning. The unified
    # $send gate above is the user-intent check; model_supports gates
    # whether we send at all.
    if ($mode eq 'think_object' && $model_supports && !$send) {
        $payload->{$schema->{think_param}} = { type => $schema->{disabled_type} // 'disabled' };
        log_debug('APIManager', "Added $schema->{think_param}={type:disabled} (thinking off, model supports it)");
        return;
    }

    return unless $send;

    # Resolve and validate the effort value
    my $effort = $self->{config}
        ? ($self->{config}->get('thinking_effort') // $schema->{default_effort})
        : $schema->{default_effort};

    # Apply value mapping (e.g. Z.AI xhigh -> max, turbo -> high)
    if ($schema->{value_map} && exists $schema->{value_map}{$effort}) {
        $effort = $schema->{value_map}{$effort};
    }

    # Validate against allowed values
    if ($schema->{values} && ref($schema->{values}) eq 'ARRAY') {
        my %valid = map { $_ => 1 } @{$schema->{values}};
        unless ($valid{$effort}) {
            $effort = $schema->{invalid_effort_default} || $schema->{default_effort};
        }
    }

    # Dispatch on mode for param injection
    if ($mode eq 'effort') {
        $payload->{$schema->{param}} = $effort;
        log_debug('APIManager', "Added $schema->{param}=$effort for $model");
    }
    elsif ($mode eq 'nested') {
        $payload->{$schema->{param}} = {
            $schema->{enabled_field} => \1,
            $schema->{effort_field}  => $effort,
        };
        log_debug('APIManager', "Added $schema->{param}={$schema->{enabled_field}:true, $schema->{effort_field}:$effort}");
    }
    elsif ($mode eq 'think_object') {
        # MiniMax: thinking.type depends on reasoning_mode
        my $thinking_type;
        if ($thinking_mode eq 'enabled') {
            $thinking_type = ($reasoning_mode eq 'adaptive') ? 'adaptive' : 'enabled';
        } elsif ($reasoning_mode eq 'adaptive') {
            $thinking_type = 'adaptive';
        } else {
            $thinking_type = 'enabled';
        }

        # MiniMax thinking object: type only, no budget_tokens.
        # The model uses its default thinking budget when type=adaptive.
        # budget_tokens can be re-enabled per-model by adding
        # send_budget_tokens => 1 to the schema when a specific model
        # requires an explicit thinking budget.
        my $thinking = { type => $thinking_type };
        if ($schema->{send_budget_tokens}) {
            my $budget_map = $schema->{budget_map} || {};
            $thinking->{budget_tokens} = $budget_map->{lc($effort)} // $schema->{default_budget};
        }
        $payload->{$schema->{think_param}} = $thinking;
        log_debug('APIManager', "Added $schema->{think_param}={type:$thinking_type}");
    }
    elsif ($mode eq 'mixed') {
        # Z.AI: thinking object + reasoning_effort
        # Build thinking object from schema's think_value (data-driven)
        my $thinking = {};
        if ($schema->{think_value} && ref($schema->{think_value}) eq 'HASH') {
            for my $k (keys %{$schema->{think_value}}) {
                $thinking->{$k} = $schema->{think_value}{$k};
            }
        } else {
            $thinking->{type} = 'enabled';
        }
        $payload->{$schema->{think_param}} = $thinking;
        $payload->{$schema->{effort_param}} = $effort;
        log_debug('APIManager', "Added $schema->{think_param}={type:enabled}, $schema->{effort_param}=$effort");
    }

    return;
}
# Handles <think>, <thinking>, [think], [thinking] and their partial
# forms (e.g. <, <t, <th, <thi, <thin, <think, <thinki, <thinkin,
# <thinking and the [ bracket variants).
# Does NOT match arbitrary < or [ followed by other characters
# (e.g. <a, <b, <div).
sub _has_partial_open_think_suffix {
    my ($text) = @_;
    return 0 unless length($text);
    return $text =~ /(?:<think(?:ing|in|i)?|<thin|<thi|<th|<t|<|\[think(?:ing|in|i)?|\[thin|\[thi|\[th|\[t|\[)$/;
}

# Check if string ends with a valid partial think-tag close prefix.
# Handles </think>, </thinking>, [/think], [/thinking] and their
# partial forms (e.g. <, </, </t, </th, </thi, </thin, </think, </thinki,
# </thinkin, </thinking and the [ bracket variants).
sub _has_partial_close_think_suffix {
    my ($text) = @_;
    return 0 unless length($text);
    return $text =~ /(?:<\/think(?:ing|in|i)?|<\/thin|<\/thi|<\/th|<\/t|<\/|<|\[\/think(?:ing|in|i)?|\[\/thin|\[\/thi|\[\/th|\[\/t|\[\/|\[)$/;
}

# Return the index of the rightmost '<' or '[' in a string. Used to find
# the start of a partial think-tag prefix for buffering across chunks.
sub _last_tag_marker_index {
    my ($text) = @_;
    my $lt = rindex($text, '<');
    my $br = rindex($text, '[');
    return $lt > $br ? $lt : $br;
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

    # Use get_model_capabilities which applies user overrides and caches raw caps
    my $caps = $self->get_model_capabilities($model);
    if ($caps && defined $caps->{supports_tools}) {
        return $caps->{supports_tools};
    }

    # Default: assume tools are supported (don't break existing behavior)
    return 1;
}

sub model_supports_vision {
    my ($self, $model) = @_;
    $model ||= $self->get_current_model();

    # Use get_model_capabilities which applies user overrides and caches raw caps
    my $caps = $self->get_model_capabilities($model);
    if ($caps && defined $caps->{supports_vision}) {
        return $caps->{supports_vision};
    }
    
    # Default: assume no vision support (safe fallback)
    return 0;
}

sub get_model_capabilities {
    my ($self, $model) = @_;
    
    $model ||= $self->get_current_model();
    
    # Parse provider prefix from model name
    my ($target_provider, $api_model) = $self->_parse_model_provider($model);
    
    # Check cache first (cache by full model name including provider prefix)
    if ($self->{_model_capabilities_cache} &&
        $self->{_model_capabilities_cache}{$model}) {
        log_debug('APIManager', "Model caps for $model (cached): prompt=" . ($self->{_model_capabilities_cache}{$model}{max_prompt_tokens} // 'undef') . ", ctx_window=" . ($self->{_model_capabilities_cache}{$model}{max_context_window_tokens} // 'undef'));
        # Cache holds raw caps; apply user overrides so runtime config changes
        # (e.g. /api set context_window) are reflected without cache invalidation.
        return $self->_caps_with_overrides($self->{_model_capabilities_cache}{$model});
    }
    
    # Use ModelCapabilitiesManager for providers with static capability maps
    # or native APIs that have their own capability fetcher (Anthropic, Google)
    my $eff_provider = $target_provider || ($self->{config} ? ($self->{config}->get('provider') || '') : '');
    
    my $use_mcm = 0;
    if ($eff_provider) {
        eval {
            require CLIO::Providers;
            my $pdef = CLIO::Providers::get_provider($eff_provider);
            # Use MCM for providers with static maps, native APIs, OR custom capability fetchers
            $use_mcm = ($pdef && ($pdef->{capability_map} || $pdef->{native_api} || $pdef->{capability_fetcher})) ? 1 : 0;
        };
    }
    
    if ($use_mcm) {
        my $normalized = eval {
            require CLIO::Core::ModelCapabilitiesManager;
            my $mcm = CLIO::Core::ModelCapabilitiesManager->new(debug => $self->{debug});
            my $caps = $mcm->get_capabilities($eff_provider, $api_model);
            log_debug('APIManager', "MCM get_capabilities for $eff_provider/$api_model: " . ($caps ? "found" : "undef"));
            if ($caps) {
                # Cache stores RAW caps (without overrides). Overrides applied
                # at get_model_capabilities return point so runtime changes
                # to overrides are reflected immediately.
                my $n = {
                    max_prompt_tokens          => $caps->{max_prompt_tokens} || $caps->{context_window},
                    max_output_tokens          => $caps->{max_output_tokens},
                    max_context_window_tokens  => $caps->{context_window},
                    supports_tools              => $caps->{supports_tools},
                    supports_streaming          => $caps->{supports_streaming},
                    supports_vision             => $caps->{supports_vision},
                    supports_reasoning          => $caps->{supports_reasoning},
                    # Pass through reasoning_mode so _get_reasoning_mode() can
                    # classify models as 'effort'|'enabled'|'adaptive'. Without
                    # this field, _get_reasoning_mode always returned undef,
                    # silently disabling every adapt_request_for_endpoint code
                    # path that gates payload construction on it (OpenAI-compat
                    # reasoning_effort, MiniMax thinking.type, Z.AI thinking).
                    reasoning_mode              => $caps->{reasoning_mode},
                };
                $self->{_model_capabilities_cache} ||= {};
                $self->{_model_capabilities_cache}{$model} = $n;
                log_debug('APIManager', "MCM capability for $model: ctx=$caps->{context_window}, tools=$caps->{supports_tools}");
                return $self->_caps_with_overrides($n);
            }
            return undef;
        };
        if ($@) {
            log_debug('APIManager', "MCM failed for $model: $@");
        }
        return undef unless $normalized;
        return $normalized;
    }
    
    # Determine API base for the model's provider
    my $api_base;
    if ($target_provider) {
        my $current_provider = $self->{config} ? ($self->{config}->get('provider') || '') : '';
        if ($target_provider eq $current_provider) {
            # Same provider as currently configured - use user's api_base (may be overridden)
            $api_base = $self->{api_base};
        } else {
            # Different provider - check per-provider stored base, then provider default
            my $stored_base = $self->{config} ? $self->{config}->get_provider_base($target_provider) : undef;
            if ($stored_base) {
                $api_base = $stored_base;
            } else {
                require CLIO::Providers;
                my $provider_def = CLIO::Providers::get_provider($target_provider);
                $api_base = $provider_def ? $provider_def->{api_base} : $self->{api_base};
            }
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
        my $ua = $self->_create_http_client(timeout => 30);
        # Use the per-provider API key when querying a different provider's models endpoint
        my $lookup_key = $self->{api_key};
        if ($target_provider && $target_provider ne ($self->{config} ? ($self->{config}->get('provider') || '') : '')) {
            my $per_provider_key = $self->{config} ? $self->{config}->get_provider_key($target_provider) : undef;
            $lookup_key = $per_provider_key if $per_provider_key;
        }
        my %headers = (
            'Authorization' => "Bearer $lookup_key",
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
                        max_output_tokens          => $pdef->{max_output_tokens} || CLIO::Core::Defaults::DEFAULT_MAX_OUTPUT_TOKENS(),
                        max_context_window_tokens  => $ctx,
                    };
                    $self->{_model_capabilities_cache} ||= {};
                    $self->{_model_capabilities_cache}{$model} = $capabilities;
                    log_debug('APIManager', "Using provider fallback for $model: context=$ctx (models endpoint unavailable)");
                    return $self->_caps_with_overrides($capabilities);
                }
            }
            log_info('APIManager', "Models endpoint unavailable ($models_url), using fallback token limits");
            return undef;
        }
        
        my $data = safe_decode_json($resp->decoded_content);
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
    
    # Find our model and extract capabilities
    for my $model_info (@$models) {
        # Match by id or aliases. llama.cpp populates both with the full
        # filesystem path, but other OpenAI-compatible servers may use
        # aliases for short names. Accept either.
        my $id_match = ($model_info->{id} && $model_info->{id} eq $api_model);
        my $alias_match = 0;
        if (!$id_match && $model_info->{aliases} && ref($model_info->{aliases}) eq 'ARRAY') {
            for my $alias (@{$model_info->{aliases}}) {
                if ($alias && $alias eq $api_model) {
                    $alias_match = 1;
                    last;
                }
            }
        }
        next unless $id_match || $alias_match;

        # For local OpenAI-compatible servers (generic api_type), enrich model_info
        # with the actual running context window from the llama.cpp /props endpoint.
        # The /v1/models response only has n_ctx_train (model's training context), not
        # the server's actual -c value. /props exposes default_generation_settings.n_ctx
        # which reflects exactly what was passed with --ctx-size / -c at startup.
        if ($api_type eq 'generic' && !$model_info->{context_window}) {
            my $props_ctx = $self->_query_llama_props($api_base);
            if ($props_ctx) {
                $model_info->{context_window} = $props_ctx;
                log_debug('APIManager', "llama.cpp /props n_ctx=$props_ctx for $api_model");
            }
        }

        my $capabilities = $self->_extract_model_capabilities($model_info, $api_type, $target_provider);
        $self->{_model_capabilities_cache} ||= {};
        $self->{_model_capabilities_cache}{$model} = $capabilities;

        log_debug('APIManager', "Model caps for $model: prompt=$capabilities->{max_prompt_tokens}, output=$capabilities->{max_output_tokens}, ctx_window=$capabilities->{max_context_window_tokens}");
        return $self->_caps_with_overrides($capabilities);
    }
    
    log_debug('APIManager', "Model $api_model not found in /models response, falling back to default context window");

    # Restore /props fallback for local providers when /v1/models doesn't
    # match. Common cause: llama.cpp returns the full path as the id but
    # _resolve_local_model returned the basename (stripped to match aliases
    # and id paths consistently), so the eq comparison above misses. /props
    # exposes the runtime n_ctx (e.g. 196608 from --ctx-size) which is the
    # ground truth for context budgeting.
    if ($api_type =~ /^(generic|sam|lmstudio)$/i) {
        require CLIO::Core::Defaults;
        my $props_ctx = $self->_query_llama_props($api_base);
        if ($props_ctx && $props_ctx > 0) {
            my $capabilities = {
                max_prompt_tokens          => $props_ctx,
                max_output_tokens          => CLIO::Core::Defaults::DEFAULT_MAX_OUTPUT_TOKENS(),
                max_context_window_tokens  => $props_ctx,
            };
            $self->{_model_capabilities_cache} ||= {};
            $self->{_model_capabilities_cache}{$model} = $capabilities;
            log_debug('APIManager', "llama.cpp /props fallback n_ctx=$props_ctx for $api_model");
            return $self->_caps_with_overrides($capabilities);
        }
    }

    log_debug('APIManager', "get_model_capabilities returning undef for $model");
    return undef;
}

=head2 _extract_model_capabilities($model_info, $api_type, $target_provider)

Extract normalized capabilities hash from a model info record.
Handles GitHub Copilot, Google, OpenRouter, SAM, and standard OpenAI formats.

=cut

sub _extract_model_capabilities {
    my ($self, $info, $api_type, $target_provider) = @_;

    require CLIO::Core::Defaults;
    my $limits = ($info->{capabilities} && $info->{capabilities}{limits}) || {};

    # Local models: conservative context to avoid OOM
    require CLIO::Providers;
    my $fallback_ctx = CLIO::Providers::default_context_window($api_type);

    # Provider-level output fallback
    my $provider_max_output;
    my $eff_provider = $target_provider || ($self->{config} ? ($self->{config}->get('provider') || '') : '');
    if ($eff_provider) {
        require CLIO::Providers;
        my $pdef = CLIO::Providers::get_provider($eff_provider);
        $provider_max_output = $pdef->{max_output_tokens} if $pdef;
    }

    my $caps = {
        max_prompt_tokens => $info->{max_request_tokens}
            || $limits->{max_prompt_tokens} || $limits->{max_context_window_tokens}
            || $info->{context_length} || $info->{context_window} || $fallback_ctx,
        max_output_tokens => $info->{max_completion_tokens}
            || $limits->{max_output_tokens} || $limits->{max_completion_tokens}
            || $provider_max_output || CLIO::Core::Defaults::DEFAULT_MAX_OUTPUT_TOKENS(),
        max_context_window_tokens => $info->{context_window}
            || $limits->{max_context_window_tokens} || $limits->{context_window}
            || $info->{context_length} || $fallback_ctx,
    };

    # Per-model tool support (GitHub Copilot)
    if ($info->{capabilities} && $info->{capabilities}{supports}) {
        $caps->{supports_tools} = $info->{capabilities}{supports}{tool_calls} ? 1 : 0;
    }

    # Google: supportedGenerationMethods
    if ($api_type eq 'google' && $info->{supportedGenerationMethods}) {
        $caps->{supports_tools} = (grep { $_ eq 'generateContent' } @{$info->{supportedGenerationMethods}}) ? 1 : 0;
    }

    # OpenRouter: reasoning support
    if ($info->{supported_parameters} && ref($info->{supported_parameters}) eq 'ARRAY') {
        $caps->{supports_reasoning} = (grep { $_ eq 'reasoning' } @{$info->{supported_parameters}}) ? 1 : 0;
    }

    # Returns RAW caps (without user overrides). Overrides applied at
    # get_model_capabilities return point via _caps_with_overrides so runtime
    # changes to overrides are reflected immediately without cache invalidation.
    return $caps;
}

=head2 _apply_capability_overrides($caps)

Apply user-configured capability overrides from config to a caps hashref.
Modifies $caps in place.

Numeric caps (cap_context_window, cap_max_output, cap_max_prompt) cap the
model's reported value: effective = min(model_value, override) when override > 0.
cap_context_window additionally caps max_prompt_tokens so the prompt budget
enforced by MessageValidator honors the user's intent (otherwise the cap
only affects State::trim_context via max_context_window_tokens and the
validator still uses the uncapped model value).
When the model's value is undef (provider did not report it, or the
ModelCapabilitiesManager lookup failed) and the override is > 0, the override
is used as the value rather than allowing the chain of DEFAULT_* fallbacks to
win below.

Boolean forces (force_tools, force_vision, force_reasoning) replace the
model's reported value when set to 'on' or 'off'.

Session-only overrides (state->{api_config}{cap_*}) take precedence over
global config values.

=cut

sub _apply_capability_overrides {
    my ($self, $caps) = @_;
    return $caps unless ref($caps) eq 'HASH';

    # Resolve effective values (session override > global config)
    my %effective;
    for my $key (qw(cap_context_window cap_max_output cap_max_prompt
                    force_tools force_vision force_reasoning)) {
        my $val;
        if ($self->{session} && $self->{session}->can('state')) {
            my $state = $self->{session}->state();
            if ($state && $state->{api_config} && exists $state->{api_config}{$key}) {
                $val = $state->{api_config}{$key};
            }
        }
        unless (defined $val) {
            $val = $self->{config} ? $self->{config}->get($key) : undef;
        }
        $effective{$key} = $val;
    }

    # Apply numeric caps (also act as fallbacks when provider value is undef)
    if ($effective{cap_context_window} && $effective{cap_context_window} > 0) {
        my $cap = $effective{cap_context_window};
        my $current = $caps->{max_context_window_tokens};
        if (!defined $current) {
            log_debug('APIManager', sprintf(
                "Applying context_window fallback (no provider value): undef -> %d", $cap
            ));
            $caps->{max_context_window_tokens} = $cap;
        }
        elsif ($current > $cap) {
            log_debug('APIManager', sprintf(
                "Capping context_window: %d -> %d", $current, $cap
            ));
            $caps->{max_context_window_tokens} = $cap;
        }
        # Also cap max_prompt_tokens so MessageValidator's budget honors the cap.
        # max_prompt_tokens is what the validator actually uses; if the cap only
        # touches max_context_window_tokens (the field State::trim_context reads),
        # the user's intent is half-honored and prompts balloon back to model max.
        if (!defined $caps->{max_prompt_tokens} || $caps->{max_prompt_tokens} > $cap) {
            log_debug('APIManager', sprintf(
                "Capping max_prompt (from context_window cap): %s -> %d",
                defined $caps->{max_prompt_tokens} ? $caps->{max_prompt_tokens} : 'undef',
                $cap
            ));
            $caps->{max_prompt_tokens} = $cap;
        }
    }

    if ($effective{cap_max_output} && $effective{cap_max_output} > 0) {
        my $cap = $effective{cap_max_output};
        my $current = $caps->{max_output_tokens};
        if (!defined $current) {
            log_debug('APIManager', sprintf(
                "Applying max_output fallback (no provider value): undef -> %d", $cap
            ));
            $caps->{max_output_tokens} = $cap;
        }
        elsif ($current > $cap) {
            log_debug('APIManager', sprintf(
                "Capping max_output: %d -> %d", $current, $cap
            ));
            $caps->{max_output_tokens} = $cap;
        }
    }

    if ($effective{cap_max_prompt} && $effective{cap_max_prompt} > 0) {
        my $cap = $effective{cap_max_prompt};
        my $current = $caps->{max_prompt_tokens};
        if (!defined $current) {
            log_debug('APIManager', sprintf(
                "Applying max_prompt fallback (no provider value): undef -> %d", $cap
            ));
            $caps->{max_prompt_tokens} = $cap;
        }
        elsif ($current > $cap) {
            log_debug('APIManager', sprintf(
                "Capping max_prompt: %d -> %d", $current, $cap
            ));
            $caps->{max_prompt_tokens} = $cap;
        }
    }

    # Apply boolean forces
    for my $cap_name (qw(tools vision reasoning)) {
        my $force = $effective{"force_$cap_name"};
        next unless defined $force && $force ne '';

        my $forced_bool = ($force eq 'on') ? 1 : 0;
        my $key = "supports_$cap_name";
        if (defined $caps->{$key} && $caps->{$key} != $forced_bool) {
            log_debug('APIManager', sprintf(
                "Forcing %s: %s -> %s",
                $cap_name,
                $caps->{$key} ? 'on' : 'off',
                $force
            ));
        }
        $caps->{$key} = $forced_bool;
    }

    return $caps;
}

=head2 _caps_with_overrides($caps)

Return a copy of $caps with user-configured capability overrides applied.
Used to ensure all callers see the post-override values consistently even
when overrides change at runtime. Cache stores raw caps; this method applies
overrides on every read.

=cut

sub _caps_with_overrides {
    my ($self, $caps) = @_;
    return undef unless ref($caps) eq 'HASH';
    my $copy = { %$caps };
    return $self->_apply_capability_overrides($copy);
}

=head2 _resolve_local_model($api_base, $api_id)

Query /v1/models from a local llama.cpp server to resolve the actual
model name from the local_model/local-model sentinel.

When the user specifies C<llama.cpp/local_model> (or C<local-model>), the
real model name is unknown until the server is queried. This method hits
C</v1/models> and returns the first model's ID, stripping the C<.gguf>
extension if present.

Only queries localhost addresses to avoid hitting remote servers.

Returns: resolved model name string, or undef if resolution fails.

=cut

sub _resolve_local_model {
    my ($self, $api_base, $api_id) = @_;

    # No localhost guard: the local_model sentinel only matches llama.cpp and
    # LM Studio defaults, so resolution is only triggered for local-style
    # providers. LAN-hosted llama.cpp servers (e.g. http://max:9090) work
    # the same as localhost for capability lookup.
    return undef unless $api_base;

    my $models_url = $api_base;
    $models_url =~ s{/+$}{};
    $models_url =~ s{/v1(/.*)?$}{};
    $models_url .= '/v1/models';

    my $ua = $self->_get_shared_http_client(timeout => 5);
    my $resp = eval { $ua->get($models_url) };
    unless ($resp && $resp->is_success) {
        log_debug('APIManager', "_resolve_local_model fetch failed ($models_url): "
            . ($@ ? "eval: $@" : ($resp ? $resp->status_line : 'no response')));
        return undef;
    }

    my $data = safe_decode_json($resp->decoded_content);
    return undef unless $data;

    my $models = $data->{data} || [];
    return undef unless @$models;

    # Prefer a non-path-shaped id (basename only) so we can match it against
    # the /v1/models response during capability lookup. llama.cpp returns the
    # full filesystem path as the model id; using the basename lets us match
    # the same path-stripped value in get_model_capabilities.
    my $model_name = $models->[0]{id};
    return undef unless $model_name;

    $model_name =~ s/\.gguf$//i;
    $model_name =~ s{.*/}{};  # Strip any directory path (llama.cpp quirk)

    log_debug('APIManager', "Resolved local_model to: $model_name");
    return $model_name;
}

=head2 _query_llama_props($api_base)

Query the llama.cpp /props endpoint to retrieve the actual running context window size.

Returns the integer n_ctx value on success, or undef if the endpoint is unavailable
or the response does not contain context information. This is used to supplement
the /v1/models response which only exposes n_ctx_train (training context), not the
server's runtime --ctx-size value.

Only called for C<generic> api_type providers (local OpenAI-compatible servers).

=cut

sub _query_llama_props {
    my ($self, $api_base) = @_;

    # Derive the /props URL from the api_base
    # e.g. http://localhost:9090/v1/chat/completions -> http://localhost:9090/props
    my $props_url = $api_base;
    $props_url =~ s{/+$}{};       # strip trailing slashes
    $props_url =~ s{/v1(/.*)?$}{};  # strip /v1 and anything after it
    $props_url .= '/props';

    my $ua = $self->_get_shared_http_client(timeout => 5);
    my $resp = eval { $ua->get($props_url) };
    if ($@ || !$resp || !$resp->is_success) {
        log_debug('APIManager', "llama.cpp /props not available at $props_url");
        return undef;
    }

    my $data = safe_decode_json($resp->decoded_content);
    if ($@) {
        log_debug('APIManager', "llama.cpp /props parse error: $@");
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
        'ollama-cloud'   => ['ollama-cloud', 'https://ollama.com/v1/models'],
        'openrouter'     => ['openrouter', 'https://openrouter.ai/api/v1/models'],
        'orca'           => ['orca', 'https://api.orcarouter.ai/v1/models'],
        'kilo'           => ['kilo', 'https://api.kilo.ai/api/gateway/models'],
    );
    
    # Check if it's a known logical name
    if (exists $api_configs{$api_base}) {
        return @{$api_configs{$api_base}};
    }
    
    # Try to detect provider from URL pattern using centralized registry
    my $provider_name = provider_from_url($api_base);

    # Map provider names to (api_type, models_url). Note: the models_url here
    # is only used as a fallback when the api_base supplied by the user lacks
    # a discernible URL pattern. For LAN-local SAM/LM Studio deployments the
    # user-supplied api_base (e.g. http://max:8080/...) takes precedence and
    # these localhost URLs are not used.
    my %provider_models_urls = (
        'github-copilot' => ['github-copilot', 'https://api.githubcopilot.com/models'],
        'openai'         => ['openai', 'https://api.openai.com/v1/models'],
        'google'         => ['google', 'https://generativelanguage.googleapis.com/v1beta/models'],
        'openrouter'     => ['openrouter', 'https://openrouter.ai/api/v1/models'],
        'orca'           => ['orca', 'https://api.orcarouter.ai/v1/models'],
        'kilo'           => ['kilo', 'https://api.kilo.ai/api/gateway/models'],
        'minimax'        => ['minimax', 'https://api.minimax.io/v1/models'],
        'ollama-cloud'   => ['ollama-cloud', 'https://ollama.com/v1/models'],
        'lmstudio'       => ['lmstudio', 'http://localhost:1234/v1/models'],
        'sam'            => ['sam', 'http://localhost:8080/v1/models'],
    );

    if ($provider_name && exists $provider_models_urls{$provider_name}) {
        return @{$provider_models_urls{$provider_name}};
    }

    # Handle DashScope variants (unified under 'dashscope' provider)
    if ($api_base =~ m{dashscope.*\.aliyuncs\.com}i) {
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

    # Always compute the SAME drift-aware threshold as the proactive trim
    # in WorkflowOrchestrator.process_input (which calls
    # _compute_drift_aware_threshold). Previously this only computed the
    # threshold when drift >= 1.2, leaving trim_threshold undef for
    # well-calibrated models (Qwen3.6, Llama-3, etc.). The resulting
    # fallback to effective_limit = prompt_budget - tool_tokens (~96K)
    # was ~21K LOWER than the proactive threshold (117964), causing a
    # double-trim: proactive trim at 117K dropped units, then reactive trim
    # at 96K dropped more — structurally changing the prompt on every turn
    # after the first trim. With unit-based trim (no deinterleave), the
    # only layout change is dropped units, not reordering, but the double-
    # trim still wastes computation and reduces context.
    # Fix: always pass the same drift-aware threshold so both trims agree.
    my $ctx_window = $caps->{max_context_window_tokens} // DEFAULT_CONTEXT_WINDOW;
    my $trim_threshold = $self->_compute_drift_aware_threshold($ctx_window, $self->{session});

    log_debug('APIManager', sprintf(
        "Reactive trim threshold: ctx=%d, drift-aware=%d (matches proactive trim in process_input)",
        $ctx_window, $trim_threshold));

    return validate_and_truncate(
        messages           => $messages,
        model_capabilities => $caps,
        tools              => $tools,
        token_ratio        => $self->{learned_token_ratio},
        config             => $self->{config},
        api_base           => $self->{api_base},
        debug              => $self->{debug},
        model              => $model,
        trim_threshold     => $trim_threshold,
    );
}

=head2 _compute_drift_aware_threshold($ctx_window, $session)

Compute a drift-aware trim threshold (mirrors WorkflowOrchestrator's
version, needed here so validate_and_truncate_messages uses the SAME
threshold as the proactive trim). For well-calibrated models (drift <= 1.0),
returns int(ctx * 0.90). For high-drift models (drift >= 1.2, saved
within the last hour), tightens proportionally to avoid sending oversized
payloads that the server rejects with HTTP 400.

=cut

sub _compute_drift_aware_threshold {
    my ($self, $ctx_window, $session) = @_;

    my $raw_threshold = int($ctx_window * 0.90);

    my $drift_ratio = 1.0;
    if ($session && $session->can('state')) {
        my $state = $session->state();
        if (ref($state) && $state->{last_api_metadata}
            && $state->{last_api_metadata}{estimate_drift_ratio}) {
            my $saved = $state->{last_api_metadata}{estimate_drift_ratio};
            if ($saved >= 1.2) {
                my $age = time() - ($state->{last_api_metadata}{saved_at} // 0);
                if ($age < 3600) {
                    $drift_ratio = $saved;
                }
            } elsif ($saved && $saved > 0 && $saved < 1.2) {
                $drift_ratio = $saved;
            }
        }
    }

    my $adjusted_threshold = $raw_threshold;
    if ($drift_ratio > 1.0) {
        $adjusted_threshold = int($raw_threshold / $drift_ratio);
    }

    return $adjusted_threshold;
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
    my ($self, $usage, $messages, $tools) = @_;

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

    # Include tool DEFINITION tokens in the estimate.
    # The API's usage.prompt_tokens counts the entire prompt, including
    # the tools array (schema descriptions, parameter definitions). The
    # char-based estimate above only counts message content + tool_call
    # JSON. Without this correction, the drift ratio is inflated by the
    # tool definition size (CLIO has 16+ tools, each with detailed schemas
    # totaling ~20-40K tokens). At the 4.0 drift clamp ceiling, this
    # tightens the trim threshold from ~115K to ~29K, trimming the dialog
    # to ~22K and collapsing the cache prefix to ~25K (the 24,992 value
    # observed in the OpenRouter/Poolside session on 2026-08-22).
    if ($tools && ref($tools) eq 'ARRAY' && @$tools) {
        my $tool_ratio = CLIO::Memory::TokenEstimator::get_effective_ratio();
        for my $tool (@$tools) {
            my $tool_json = CLIO::Util::JSON::safe_encode_json($tool);
            if (defined $tool_json && length($tool_json) > 0) {
                $total_chars += length($tool_json);
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

    # ALSO compute and store the drift ratio (actual_tokens / estimated_tokens)
    # so the resume fast path can tighten its threshold for THIS model. Without
    # this, a model whose tokenizer produces very different tokens than the
    # chars/token heuristic assumes will keep failing the resume fast path
    # every cycle until something else forces a fallback (the CachyLLama bug
    # on 2026-08-20: 104K estimated, 163K actual, ratio 1.56x).
    #
    # Each model's tokenizer behaves differently — observed:
    #   Qwen3.x:        ratio ~3.5 (chars/token, estimate matches)
    #   Llama-3:        ratio ~3.0
    #   llama.cpp UD-Q5_K_XL Quant: ratio ~1.5-1.6 (estimate undercounts!)
    # We can't predict this without a successful API response, so save it on
    # success and apply on resume.
    if ($self->{session} && $self->{session}->can('state')) {
        my $state = $self->{session}->state();
        if (ref($state)) {
           require CLIO::Memory::TokenEstimator;
           my $estimated_tokens = 0;
           for my $msg (@$messages) {
               $estimated_tokens += CLIO::Memory::TokenEstimator::estimate_tokens($msg->{content} || '');
               if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                   for my $tc (@{$msg->{tool_calls}}) {
                       my $json = encode_json($tc);
                       $estimated_tokens += CLIO::Memory::TokenEstimator::estimate_tokens($json);
                   }
               }
           }

            # Include tool DEFINITION tokens in the estimate.
            # The API's usage.prompt_tokens counts the entire prompt, including
            # the tools[] array (schema descriptions, parameter definitions).
            # The message-content estimate above only covers message content +
            # tool_call JSON. Without tool definitions, the drift ratio is
            # inflated by their size — CLIO has 16+ tools with detailed
            # schemas totaling ~20-40K tokens. A 130K-token prompt with 30K of
            # tool defs produces drift = 160K / 130K = 1.23, which tightens the
            # trim threshold from ~115K to ~93K, triggering unnecessary trims
            # that break LCP cache stability. Including tool def tokens gives
            # a drift ratio that reflects pure tokenizer drift (the actual
            # goal), not the tool definition overhead.
            if ($tools && ref($tools) eq 'ARRAY' && @$tools) {
                for my $tool (@$tools) {
                    my $tool_json = CLIO::Util::JSON::safe_encode_json($tool);
                    if (defined $tool_json && length($tool_json) > 0) {
                        $estimated_tokens += CLIO::Memory::TokenEstimator::estimate_tokens($tool_json);
                    }
                }
            }

            if ($estimated_tokens > 0 && $actual_tokens > 0) {
                my $drift = $actual_tokens / $estimated_tokens;
                # Clamp at the same 4.0 ceiling used for the chars/token ratio
                # to prevent outliers (a single bad sample, signature-whitespace
                # anomalies, etc.) from poisoning subsequent resumes.
                $drift = 4.0 if $drift > 4.0;
                $drift = 1.0 if $drift < 1.0;

                if ($state->{last_api_metadata}) {
                    $state->{last_api_metadata}{actual_tokens}        = int($actual_tokens);
                    $state->{last_api_metadata}{estimate_drift_ratio} = $drift;
                }
                if ($self->{debug}) {
                    log_debug('APIManager', sprintf(
                        "Drift ratio learned: estimated=%d, actual=%d, drift=%.3f (saved to state for next resume)",
                        $estimated_tokens, $actual_tokens, $drift));
                }
            }
        }
    }

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
    return 0 unless $provider;
    require CLIO::Providers;
    my $pdef = CLIO::Providers::get_provider($provider);
    return 0 unless $pdef && $pdef->{requires_auth} && $pdef->{requires_auth} eq 'copilot';
    
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
    require CLIO::Core::Defaults;
    my $max = ($caps && $caps->{max_output_tokens}) ? $caps->{max_output_tokens} : CLIO::Core::Defaults::DEFAULT_MAX_OUTPUT_TOKENS();
    # Force numeric context with +0 so JSON::XS encodes as integer (not string)
    # when the value came from a JSON-decoded cache file.
    return $max + 0;
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
    my @pending_tc = ();

    my $flush_tc = sub {
        push @input, map {{
            type => 'function_call', name => $_->{function}{name},
            arguments => $_->{function}{arguments} // '{}', call_id => $_->{id},
        }} @pending_tc;
        @pending_tc = ();
    };

    for my $msg (@$messages) {
        my $role = $msg->{role} || 'user';
        my $content = $msg->{content} || '';

        if ($role eq 'system') {
            push @input, { role => 'developer', content => [{ type => 'input_text', text => $content }] };
        }
        elsif ($role eq 'user') {
            my @parts;
            if (ref($content) eq 'ARRAY') {
                # Multimodal content: array of text/image parts
                for my $part (@$content) {
                    if ($part->{type} eq 'text') {
                        push @parts, { type => 'input_text', text => $part->{text} };
                    }
                    elsif ($part->{type} eq 'image_url') {
                        push @parts, { type => 'input_image', image_url => $part->{image_url}{url} };
                    }
                }
            } else {
                push @parts, { type => 'input_text', text => $content };
            }
            push @input, { role => 'user', content => \@parts };
        }
        elsif ($role eq 'assistant') {
            $flush_tc->() if @pending_tc;
            @pending_tc = @{$msg->{tool_calls}} if $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY';

            # Round-trip reasoning items. The Responses API requires the
            # complete reasoning item (with encrypted_content) be sent back
            # as input on the next turn so the model can resume from the same
            # reasoning state. We accept two shapes on the assistant message:
            #   1. reasoning_blocks (arrayref of native provider blocks -
            #      Anthropic thinking, Google thought, etc.)
            #   2. responses_reasoning_items (arrayref of pre-shaped Responses
            #      API items captured from response.output_item.done)
            if ($msg->{responses_reasoning_items} && ref($msg->{responses_reasoning_items}) eq 'ARRAY') {
                for my $ri (@{$msg->{responses_reasoning_items}}) {
                    next unless ref($ri) eq 'HASH';
                    next unless ($ri->{type} // '') eq 'reasoning';
                    next unless defined $ri->{encrypted_content};
                    # Phase field (commentary/final_answer) must be preserved
                    # verbatim. This is what the Responses API uses to
                    # distinguish preambles before tool calls from final
                    # answers after the last tool result.
                    my $item = {
                        type              => 'reasoning',
                        encrypted_content => $ri->{encrypted_content},
                    };
                    $item->{id}      = $ri->{id}      if $ri->{id};
                    $item->{summary} = $ri->{summary} if $ri->{summary};
                    $item->{phase}   = $ri->{phase}   if defined $ri->{phase};
                    push @input, $item;
                }
            }
            elsif ($msg->{reasoning_blocks} && ref($msg->{reasoning_blocks}) eq 'ARRAY') {
                # If the model returns thinking blocks from a native provider
                # (Anthropic, Google), we don't have an encrypted_content
                # blob to send back, so we skip them for Responses API. The
                # reasoning.effort setting will be re-instructed on the next
                # turn via the reasoning param.
            }

            if (defined $content && length($content)) {
                push @input, {
                    role => 'assistant', type => 'message', id => 'msg_placeholder', status => 'completed',
                    content => [{ type => 'output_text', text => $content, annotations => [] }],
                };
            }
        }
        elsif ($role eq 'tool') {
            $flush_tc->() if @pending_tc;
            push @input, { type => 'function_call_output', call_id => $msg->{tool_call_id} || '', output => $content };
        }
    }
    $flush_tc->() if @pending_tc;
    
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
        my $thinking_mode = $self->{config} ? ($self->{config}->get('thinking_mode') // 'auto') : 'auto';
        # thinking_mode=auto: gate on show_thinking (legacy).
        # thinking_mode=enabled: force ON.
        # thinking_mode=disabled: skip the reasoning parameter entirely.
        if ($thinking_mode eq 'disabled') {
            # Skip - Responses API has no "disabled" type, only "enabled"
            # with effort. Omitting reasoning means no reasoning happens.
        }
        elsif ($thinking_mode eq 'enabled'
            || ($thinking_mode eq 'auto' && $show_thinking)) {
            my $thinking_effort = $self->{config} ? ($self->{config}->get('thinking_effort') // 'medium') : 'medium';
            my $reasoning_config = { effort => $thinking_effort };
            # summary: auto makes the model return reasoning text; only set
            # when the user actually wants to see it. With thinking_mode=auto
            # and show_thinking=0, or thinking_mode=enabled, we still
            # configure effort but skip the visible summary.
            if ($show_thinking) {
                $reasoning_config->{summary} = 'auto';
            }
            $payload->{reasoning} = $reasoning_config;
        }
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
    # Billing continuity - subsequent turns not re-charged
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
    $payload = sanitize_payload($payload);
    
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
        
        # Check per-provider stored base, then provider default
        my $stored_base = $self->{config} ? $self->{config}->get_provider_base($target_provider) : undef;
        if ($stored_base) {
            $endpoint = $stored_base;
        } else {
            require CLIO::Providers;
            my $provider_def = CLIO::Providers::get_provider($target_provider);
            $endpoint = $provider_def ? $provider_def->{api_base} : $self->{api_base};
        }
    } else {
        # Use current provider config
        $endpoint_config = $self->get_endpoint_config();
        $endpoint = $self->{api_base};
    }
    
    # Resolve local_model/local-model sentinel for llama.cpp and LM Studio providers.
    # These providers use a placeholder model name; the real name comes from /v1/models.
    if ($target_provider && $api_model =~ /^local[-_]model$/i) {
        my $resolved = $self->_resolve_local_model($endpoint, $api_model);
        if ($resolved) {
            $api_model = $resolved;
            my $full_resolved = "$target_provider/$resolved";
            # Update config so get_current_model() returns the resolved name
            # Do NOT mark as user-set: the resolved name is dynamic and should
            # re-resolve if the server restarts with a different model.
            if ($self->{config} && $self->{config}->can('set')) {
                $self->{config}->set('model', $full_resolved, 0);
            }
            # Update session for persistence across restarts
            if ($self->{session}) {
                $self->{session}{selected_model} = $full_resolved;
            }
            log_debug('APIManager', "Resolved local_model to: $full_resolved");
        }
    }
    
    return {
        config => $endpoint_config,
        endpoint => $endpoint,
        model => $api_model,
        target_provider => $target_provider // $self->{config}->get('provider'),
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
            # Some providers (NVIDIA NIM) use the provider name as part of the
            # genuine model ID namespace (e.g., "nvidia/llama-3.1-nemotron-nano-8b-v1").
            # For these providers, don't strip the prefix - return the full model name.
            my $provider_def = CLIO::Providers::get_provider($prefix);
            if ($provider_def && $provider_def->{keep_model_prefix}) {
                return ($prefix, $model);
            }
           return ($prefix, $rest);
       }
   }
    
    # No explicit provider prefix - caller uses current provider
    return (undef, $model);
}

=head2 _get_endpoint_config_for_provider($provider_name)

Get endpoint configuration for a specific provider (used for cross-provider routing).

=cut

sub _get_endpoint_config_for_provider {
    my ($self, $provider_name) = @_;
    
    # Resolve API key for the target provider
    my $api_key = $self->{config}->get_provider_key($provider_name);
    
    # For copilot auth providers, use OAuth token
    require CLIO::Providers;
    my $provider_def = CLIO::Providers::get_provider($provider_name);
    if ($provider_def && $provider_def->{requires_auth} && $provider_def->{requires_auth} eq 'copilot' && !$api_key) {
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
        max_tokens => $max_tokens,
    };

    # Only include sampling parameters when explicitly set. Letting the
    # provider (or the user via sampling_* config) decide avoids sending
    # unsolicited defaults like temperature=0.2 to APIs that reject them.
    $payload->{temperature} = $opts{temperature} if defined $opts{temperature};
    $payload->{top_p}       = $opts{top_p}       if defined $opts{top_p};
    
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
    if ($endpoint_config->{requires_copilot_headers}) {
        # copilot_thread_id and previous_response_id are GitHub Copilot billing fields.
        # They are deleted for non-Copilot providers (see adapt_request_for_endpoint).
        # Only warn about their absence when using Copilot, where they affect billing.
        if ($self->{session} && $self->{session}{session_id}) {
            $payload->{copilot_thread_id} = $self->{session}{session_id};
            log_debug('APIManager', "Including copilot_thread_id: $payload->{copilot_thread_id}");
        } else {
            log_warning('APIManager', "NO copilot_thread_id - session will be treated as NEW (charges AI Credits!)");
            log_debug('APIManager', "session=" . (defined $self->{session} ? "defined" : "undef") .
                         ", session_id=" . (defined $self->{session}{session_id} ? $self->{session}{session_id} : "undef"));
        }
    }

    # Cache control marker: anchor the LCP cache to the stable anchor
    # [0..2] = system_prompt + summary + context_files for providers that
    # support OpenAI-style prompt caching (OpenAI gpt-4o/o-series,
    # OpenRouter passthrough, GitHub Copilot Claude/GPT, NVIDIA NIM).
    # The marker is placed on the FIRST leading system message (the system
    # prompt itself), so everything from [0] up to and including that
    # message is cached. When [1] summary or [2] context_files is
    # regenerated, the LCP break moves to that section (only that
    # section's tokens are reprocessed), but the rest of the cache hit
    # is preserved.
    #
    # Anthropic has its own cache_control handling in Anthropic.pm's
    # build_request (concatenates all system messages into one
    # system[] block with cache_control on the entry). llama.cpp uses
    # prompt_stable_prefix_tokens below instead of cache_control.
    if ($endpoint_config->{supports_cache_control} && $messages && @$messages) {
        # Anchor cache_control on the FIRST leading system message (the system
        # prompt). The LAST leading system message is whichever volatile
        # section lives at position [1] - context_files pre-trim (dropped by
        # trim_conversation_for_api) or thread_summary post-trim (regenerated
        # by CSSS). Anchoring to a volatile section causes the cache to
        # invalidate on every trim and every CSSS regeneration.
        my $first_system_idx;
        for my $i (0 .. $#$messages) {
            if ($messages->[$i] && ($messages->[$i]{role} // '') eq 'system') {
                $first_system_idx = $i;
                last;
            } else {
                last;
            }
        }
        if (defined $first_system_idx) {
            my $msgs = $messages;
            $msgs->[$first_system_idx]{cache_control} = { type => 'ephemeral' };
            log_debug('APIManager',
                "Placed cache_control marker on system prompt at index $first_system_idx");
        }
    }

    # Inject llama_user_id for local SSD-backed inference servers (llama.cpp,
    # LM Studio, SAM). Each CLIO session gets its own SSD cache directory
    # on the server (ssd-cache/u/<hash>/), preventing cross-session
    # checkpoint contamination. All CLIO sessions with the same model share
    # the same conv_hash, so anonymous continuation matching would otherwise
    # pull checkpoints from unrelated sessions. Stripped of UUID hyphens
    # for cleaner filenames and to fit the 64-char limit comfortably.
    if ($endpoint_config->{llama_user_id_supported}
        && $self->{session}
        && $self->{session}{session_id}) {
        my $uid = $self->{session}{session_id};
        $uid =~ s/-//g;  # strip UUID hyphens
        $payload->{llama_user_id} = $uid;
        log_debug('APIManager', "Including llama_user_id: $uid (session-isolated SSD cache)");
    }

    # prompt_stable_prefix_tokens: tell the llama.cpp LCP matcher how many
    # leading tokens form a stable prefix. Static leading system messages
    # are included (system_prompt + thread_summary + context_files) because
    # they only change on rare events: tools/MCP registration, CSSS
    # regeneration, or context_files added/removed. Dialog at [3]+ changes
    # every turn and tool_results at [4] shift with trimming - both are
    # AFTER the stable prefix so they never invalidate the cache hint.
    #
    # user_context (<userContext>/<dynamicContext>/<sessionGoals>) is EXCLUDED
    # even when it appears at a leading position (session start, or after
    # proactive trim drops dialog). It contains date/time + LTM snapshots
    # that change every minute/turn; including it makes the hint drift and
    # permanently collapses the LCP cache (server.log: stable_prefix went
    # 29032 -> 24168 on minute rollover, sim_best 0.973 -> 0.240 forever).
    #
    # When this hint matches the cached slot's actual prefix length, the
    # LCP matcher reports sim_best=1.0 because every cached token still
    # matches. When trim causes the cached slot to be reprocessed (because
    # sim_best dropped below --slot-prompt-similarity 0.20), CachyLLama builds
    # a new slot. Without the hint covering summary+context_files, the OLD
    # cached slot keeps matching against the truncated prompt and sim_best
    # collapses to ~0.57 forever - the reprocessed slot never wins the LCP
    # race (observed in scratch/run.log: sim_best dropped from 0.997 to
    # 0.566 after a single trim and stayed there for 50+ subsequent turns).
    if ($endpoint_config->{llama_user_id_supported} && $messages && @$messages) {
        # Collect every leading system message EXCEPT user_context.
        # Static leading systems: system_prompt, thread_summary, context_files.
        # user_context must be skipped even if it appears at a leading position
        # (session start: [sys][user_ctx][user_input], or post-trim when
        #  dialog is dropped: [sys][user_ctx][user_input][summary]).
        # user_context contains date/time + LTM snapshots that change every
        # minute/turn. Including it in the stable prefix makes the hint
        # drift -> cache hash mismatch -> sim_best collapses -> LRU fallback
        # -> full prompt reprocessing every turn (server.log: 97.44s permanent
        # collapse at stable_prefix=29032 -> 24168 when minute ticked over).
        my @leading_system;
        my $skipped_user_context = 0;
        for my $msg (@$messages) {
            last unless ($msg->{role} // '') eq 'system';
            my $content = $msg->{content} // '';
            if (ref($content) eq 'ARRAY') {
                # Flatten arrayref content (multimodal) for tag detection
                my $flat = '';
                for my $part (@$content) {
                    if (ref($part) eq 'HASH' && ($part->{type} // '') eq 'text') {
                        $flat .= ($part->{text} // '');
                    } elsif (!ref($part)) {
                        $flat .= $part;
                    }
                }
                $content = $flat;
            }
            if ($content =~ /^\s*<(?:userContext|dynamicContext|sessionGoals)[\s>]/) {
                $skipped_user_context++;
                next;
            }
            push @leading_system, $msg;
        }
        if ($skipped_user_context && should_log('DEBUG')) {
            log_debug('APIManager',
                "Stable prefix: excluded $skipped_user_context user_context message(s) "
                . "from prompt_stable_prefix_tokens (dynamic content at leading "
                . "position). Retained " . scalar(@leading_system) . " static "
                . "leading system msg(s). Prevents LCP collapse on minute rollover.");
        }
        if (@leading_system) {
            # Flatten to a single text blob for hashing and token estimation.
            # arrayref content only contributes text parts; non-text parts
            # (images) have no token budget in the LCP stable prefix.
            my $combined_text = '';
            for my $msg (@leading_system) {
                my $content = $msg->{content} // '';
                if (ref($content) eq 'ARRAY') {
                    for my $part (@$content) {
                        if (ref($part) eq 'HASH' && ($part->{type} // '') eq 'text') {
                            $combined_text .= ($part->{text} // '') . "\n";
                        }
                    }
                } else {
                    $combined_text .= $content . "\n";
                }
            }
            if (length($combined_text) > 0) {
                # Cache the stable prefix token count by content signature.
                # CLIO::Memory::TokenEstimator::estimate_tokens uses
                # get_effective_ratio() which returns the learned char/token
                # ratio. That ratio drifts after every API response (via
                # _learn_from_api_response -> set_learned_ratio). A drifting
                # ratio produces a drifting prompt_stable_prefix_tokens on
                # every turn (observed: 31335 -> 3323 -> 29559 -> 2915 ->
                # 28999 -> 29148 -> 2927), which breaks llama.cpp's LCP cache
                # match and forces the server to reprocess the entire prompt
                # each turn.
                #
                # Caching on a signature of the combined content freezes the
                # stable prefix token count for byte-identical leading system
                # messages. The learned ratio still flows through to all
                # other estimation (MessageValidator trim, budget validation)
                # - only the stable prefix hint is frozen. When any leading
                # system message changes (tools added, CSSS regeneration,
                # context_files added/removed), the hash differs and we
                # recalculate.
                #
                # Signature strategy: try Digest::MD5 first (core Perl module),
                # fall back to Digest::SHA (also core), fall back to a
                # pure-Perl fingerprint (length + prefix + suffix). The cache
                # key only needs to detect changes in the leading system
                # messages, not be cryptographically secure.
                my $content_hash;
                my $hash_source = 'fallback';
                eval {
                    require Digest::MD5;
                    $content_hash = Digest::MD5::md5_hex($combined_text);
                    $hash_source = 'md5';
                    1;
                } or do {
                    eval {
                        require Digest::SHA;
                        $content_hash = Digest::SHA::sha1_hex($combined_text);
                        $hash_source = 'sha1';
                        1;
                    };
                };
                if (!defined $content_hash) {
                    $content_hash = sprintf("%d:%s:%s",
                        length($combined_text),
                        substr($combined_text, 0, 32),
                        substr($combined_text, -32));
                    $hash_source = 'fallback';
                }
                if ($self->{_stable_prefix_cache}
                    && $self->{_stable_prefix_cache}{hash} eq $content_hash) {
                    $payload->{prompt_stable_prefix_tokens} = 0 + $self->{_stable_prefix_cache}{tokens};
                    log_debug('APIManager', "Including prompt_stable_prefix_tokens: $self->{_stable_prefix_cache}{tokens} (cached, leading system messages unchanged, "
                        . scalar(@leading_system) . " msg(s) covered)");
                } else {
                    require CLIO::Memory::TokenEstimator;
                    my $stable_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($combined_text);
                    if ($stable_tokens > 0) {
                        $payload->{prompt_stable_prefix_tokens} = 0 + $stable_tokens;
                        # Cache miss diagnostic: log when the stable prefix changes
                        # between turns. This is the CLIO-side signal that corresponds
                        # to the server-side LCP collapse observed in server.log:
                        #   - stable prefix unchanged -> sim_best stays ~1.0 (cache hit)
                        #   - stable prefix CHANGED  -> sim_best collapses to ~0.2-0.5 (cache miss)
                        # Between turns. This is a debug-level diagnostic - a cache
                        # miss is an internal implementation detail. Users don't
                        # need to see it in normal operation; --debug reveals it.
                        my $old_tokens = $self->{_stable_prefix_cache}{tokens} // 0;
                        if ($old_tokens > 0) {
                            log_debug('APIManager',
                                "CACHE MISS: prompt_stable_prefix_tokens changed " .
                                "$old_tokens -> $stable_tokens (" .
                                ($stable_tokens - $old_tokens) . " tokens delta). " .
                                "Leading system content hash changed - llama.cpp LCP cache " .
                                "will not match the existing slot. " .
                                scalar(@leading_system) . " static leading system msg(s) covered.");
                        }
                        log_debug('APIManager', "Including prompt_stable_prefix_tokens: $stable_tokens (leading system messages changed, recalculated, "
                            . scalar(@leading_system) . " msg(s) covered)");
                        $self->{_stable_prefix_cache} = {
                            hash   => $content_hash,
                            tokens => 0 + $stable_tokens,
                        };
                    }
                }
            }
        }
    }

    # Add previous_response_id for GitHub Copilot billing continuity
    # Skip if model has rejected previous_response_id (flagged by ResponseHandler)
    if ($endpoint_config->{requires_copilot_headers} && !$self->{response_handler}{_no_previous_response_id}) {
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
    $payload = sanitize_payload($payload);
    
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
            my $preview;
            if (ref($msg->{content}) eq 'ARRAY') {
                # Multimodal content: show text parts + image count
                my @text_parts = grep { $_->{type} eq 'text' } @{$msg->{content}};
                my $image_count = scalar(grep { $_->{type} eq 'image_url' } @{$msg->{content}});
                $preview = join(' ', map { $_->{text} // '' } @text_parts);
                $preview .= " [$image_count image(s)]" if $image_count > 0;
            } else {
                $preview = $msg->{content} // '';
            }
            $preview = substr($preview, 0, 60);
            $preview =~ s/\n/ /g;
            log_debug('APIManager', sprintf("  [%d] %s: %s%s",
                $i, $msg->{role}, $preview,
                (length($preview) >= 60 ? '...' : '')));
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
        my $request_id = uuid_v4();
        
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
        $req->header('HTTP-Referer' => 'https://github.com/SyntheticAutonomicMind/CLIO');
        $req->header('X-Title' => 'CLIO');
    }
    
    # Apply provider extra headers (e.g., anthropic-version for Anthropic-compatible proxies)
    if ($endpoint_config && $endpoint_config->{extra_headers} && ref($endpoint_config->{extra_headers}) eq 'HASH') {
        for my $header (keys %{$endpoint_config->{extra_headers}}) {
            $req->header($header => $endpoint_config->{extra_headers}{$header});
        }
    }
    
    $req->content($json);
    
    return ($req, $final_endpoint);
}

=head2 _check_connectivity

Check if we can reach the API endpoint after a network error.

Based on VSCode's approach: ping CAPI to verify network is working before retrying.
This avoids hammering a struggling server when the network itself is the problem.

Uses exponential backoff delays: [1s, 10s, 10s] between checks.

Arguments:
- $endpoint: The API endpoint URL to check

Returns: 1 if connectivity is restored, 0 otherwise

=cut

sub _check_connectivity {
    my ($self, $endpoint) = @_;

    # Quick connectivity check with short delays - we retry regardless
    my @check_delays = (1, 2);

    for my $i (0 .. $#check_delays) {
        # Wait before this check (skip first one)
        if ($i > 0) {
            log_info('APIManager', "Waiting ${check_delays[$i]}s before connectivity check...");
            sleep($check_delays[$i]);
        }

        log_debug('APIManager', "Checking connectivity to API endpoint...");

        my $ua = $self->_create_http_client(timeout => 10);
        my %headers = (
            'Authorization' => "Bearer $self->{api_key}",
        );

        # Add GitHub-specific headers if using Copilot
        my $detected = provider_from_url($self->{api_base} // '');
        if ($detected && $detected eq 'github-copilot') {
            $headers{'Editor-Version'} = 'CLIO/1.0';
        }

        # Try a lightweight request - models list or health check
        my $check_url = $endpoint;
        $check_url =~ s{/chat/completions.*$}{};
        $check_url =~ s{/completions.*$}{};
        $check_url .= '/models';

        my $resp = eval { $ua->get($check_url, headers => \%headers) };

        if ($resp && $resp->is_success) {
            log_info('APIManager', "Connectivity restored - API endpoint responding");
            return 1;
        }

        my $err = $@ // 'unknown';
        my $status = $resp ? $resp->code : 'no response';
        log_debug('APIManager', "Connectivity check failed: $status ($err)");
    }

    log_warning('APIManager', "Connectivity check failed after " . scalar(@check_delays) . " attempts");
    return 0;
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
        # Pass the resolved model + estimated pending input tokens so the
        # broker's per-model ITPM sliding window (aggregated across all
        # connected agents) can gate this slot. Without model/pending the
        # broker only sees RPM-style pressure and cannot prevent
        # UserByModelByMinuteUncachedInputTokens errors when multiple
        # agents share an account.
        my $pending_for_broker = 0;
        eval {
            require CLIO::Memory::TokenEstimator;
            $pending_for_broker = CLIO::Memory::TokenEstimator::estimate_messages_tokens($self->{_pending_messages_for_broker} // []);
        };
        my $model_for_broker = $self->{_pending_model_for_broker};
        my %slot_opts;
        $slot_opts{model}          = $model_for_broker if defined $model_for_broker;
        $slot_opts{pending_tokens} = $pending_for_broker if $pending_for_broker > 0;
        my $slot_result = $self->{broker_client}->wait_for_api_slot(120, %slot_opts);
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

# Shared pre-request pipeline for send_request and send_request_streaming.
#
# Handles: rate limiting, endpoint config, throttling, message preparation,
# validation/truncation, native provider dispatch, payload building, JSON
# encoding, preflight validation, and HTTP request construction.
#
# Args:
#   $input   - User input text
#   %opts    - Request options (messages, tools, model, etc.)
#              is_streaming => 1/0 (required)
#              on_chunk, on_tool_call, on_thinking => callbacks (streaming only)
#
# Returns hashref:
#   On native provider dispatch: { native_result => $result }
#   On error: { error_result => $result }
#   On success: { req, final_endpoint, endpoint_config, model, messages,
#                 json, payload, provider_label, use_responses_api }
#
sub _prepare_api_request {
    my ($self, $input, %opts) = @_;

    my $is_streaming = delete $opts{is_streaming} || 0;

    # Get endpoint-specific configuration
    my $ep = $self->_prepare_endpoint_config(%opts);
    my $endpoint_config = $ep->{config};
    my $endpoint = $ep->{endpoint};
    my $model = $ep->{model};
    my $target_provider = $ep->{target_provider};

    # Prepare and trim messages so the broker ITPM check sees a realistic
    # pending token estimate (post-trim, not the raw user input).
    my $messages = $self->_prepare_messages($input, %opts);

    # Expose context for _apply_rate_limiting -> broker wait_for_api_slot.
    # The broker uses these to compute ITPM-aware slot delay across all
    # connected agents (prevents sub-agent fanout from blowing
    # UserByModelByMinuteUncachedInputTokens).
    $self->{_pending_messages_for_broker} = $messages;
    $self->{_pending_model_for_broker}    = $model;

    eval { $self->_apply_rate_limiting(); };
    if ($@) {
        log_warning('APIManager', "_apply_rate_limiting failed: $@");
    }
    # Record the resolved model so release_broker_slot can forward
    # anthropic-ratelimit-* headers to the broker's per-model snapshot.
    $self->{response_handler}->set_last_request_model($model) if $self->{response_handler};

    # Proactive per-model throttle
    if (my $throttle_delay = $self->_model_throttle_check($model)) {
        log_info('APIManager', sprintf("Proactive rate throttle for %s: %.1fs", $model, $throttle_delay));
        for (my $i = int($throttle_delay); $i > 0; $i--) { sleep(1); }
    }
    $self->_model_throttle_record($model);

    # Token-aware throttle (Anthropic ITPM/OTPM). Estimate the input tokens
    # for the upcoming request and let the input-token layer pace it.
    # Composes with the request-count throttle above - whichever wants the
    # bigger delay wins. Estimate is intentionally conservative; TokenEstimator
    # uses learned ratios fed from real API responses, and we leave a 70%
    # safety margin in `_model_input_token_throttle_check`.
    {
        my $pending_tokens = 0;
        eval {
            require CLIO::Memory::TokenEstimator;
            $pending_tokens = CLIO::Memory::TokenEstimator::estimate_messages_tokens($messages);
        };
        if ($@) {
            log_debug('APIManager', "TokenEstimator unavailable for input-token throttle check: $@");
            $pending_tokens = 0;
        }
        if (my $token_delay = $self->_model_input_token_throttle_check($model, $pending_tokens)) {
            log_info('APIManager', sprintf("Proactive token throttle for %s: %.1fs (pending~%d tokens)",
                $model, $token_delay, $pending_tokens));
            for (my $i = int($token_delay); $i > 0; $i--) { sleep(1); }
        }
    }

    # Check for native provider (non-OpenAI-compatible API)
    my $native_provider = $self->_get_native_provider($target_provider);
    if ($native_provider) {
        my $result = $self->_send_native_streaming(
            $native_provider,
            $messages,
            $opts{tools},
            on_chunk     => $opts{_on_chunk},
            on_tool_call => $opts{_on_tool_call},
            on_thinking  => $opts{_on_thinking},
            model        => $model,
            %opts
        );
        return { native_result => $result };
    }

    # Strip non-standard 'name' field from tool messages (OpenAI rejects it)
    for my $msg (@$messages) {
        delete $msg->{name} if $msg->{role} && $msg->{role} eq 'tool' && exists $msg->{name};
    }

    if ($self->{debug}) {
        my $label = $is_streaming ? "Streaming to" : "Sending request to";
        log_debug('APIManager', "$label $endpoint");
        log_debug('APIManager', "Model: $model");
    }

    if (!$self->{api_key}) {
        return { error_result => {
            success => 0,
            error => "Missing API key. Please configure a provider with /api provider <name> or set key with /api key <value>"
        }};
    }

    # Validate and truncate messages against model token limits
    my $full_model_for_caps = $self->get_current_model();
    my $pre_trim_count = scalar(@$messages);
    $messages = $self->validate_and_truncate_messages($messages, $full_model_for_caps, $opts{tools});

    # Store trimmed messages for orchestrator sync
    my $post_trim_count = scalar(@$messages);
    if ($post_trim_count < $pre_trim_count) {
        $self->{_last_trimmed_messages} = $messages;
        log_info('APIManager', "Proactive trim: $pre_trim_count -> $post_trim_count messages");
    } else {
        $self->{_last_trimmed_messages} = undef;
    }

    # Strip non-standard 'name' field again (truncation may re-introduce messages)
    for my $msg (@$messages) {
        delete $msg->{name} if $msg->{role} && $msg->{role} eq 'tool' && exists $msg->{name};
    }

    # Check if model uses Responses API (codex models, etc.)
    my $use_responses_api = $self->_model_uses_responses_api($model);
    $self->{_current_request_uses_responses} = $use_responses_api;

    # Build request payload
    my $payload;
    if ($use_responses_api) {
        log_info('APIManager', ($is_streaming ? "Streaming: " : "") . "Using Responses API for model: $model");
        $payload = $self->_build_responses_api_payload($messages, $model, $endpoint_config, %opts, stream => ($is_streaming ? 1 : 0));
    } else {
        $payload = $self->_build_payload($messages, $model, $endpoint_config, %opts, stream => ($is_streaming ? 1 : 0));
    }

    # Debug: dump payload summary
    if ($self->{debug}) {
        my $msg_key = $use_responses_api ? 'input' : 'messages';
        my $msg_count = scalar(@{$payload->{$msg_key} || []});
        my $tool_count = $payload->{tools} ? scalar(@{$payload->{tools}}) : 0;
        log_debug('APIManager', sprintf("Payload: %s %s, %d %s, %d tools -> %s",
            $payload->{model}, ($use_responses_api ? 'Responses' : 'ChatCompletions'),
            $msg_count, $msg_key, $tool_count, $endpoint));
    }

    # Clean up internal metadata fields from tool_calls (Chat Completions only)
    if (!$use_responses_api && $payload->{messages}) {
        for my $msg (@{$payload->{messages}}) {
            if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                for my $tc (@{$msg->{tool_calls}}) {
                    delete $tc->{_name_complete} if exists $tc->{_name_complete};
                }
            }
        }
    }

    # Pre-flight validation (Chat Completions only)
    if (!$use_responses_api) {
        my $preflight_errors = $self->_preflight_validate_messages($payload->{messages});
        if ($preflight_errors && @$preflight_errors) {
            my $error_summary = join('; ', @$preflight_errors);
            log_debug('APIManager', "Pre-flight validation failed: $error_summary");

            log_info('APIManager', "Attempting auto-repair of message structure");
            $payload->{messages} = $self->_validate_tool_message_pairs($payload->{messages});

            my $post_repair_errors = $self->_preflight_validate_messages($payload->{messages});
            if ($post_repair_errors && @$post_repair_errors) {
                return { error_result => {
                    success => 0,
                    error => "Message structure validation failed after repair: " . join('; ', @$post_repair_errors),
                    retryable => 1,
                    retry_after => 0,
                    error_type => 'message_structure_error'
                }};
            }
            log_info('APIManager', "Message structure repaired successfully");
        }
    }

    # Debug: dump tool_calls in payload
    if ($self->{debug} && $payload->{messages}) {
        for my $i (0 .. $#{$payload->{messages}}) {
            if ($payload->{messages}[$i]{tool_calls}) {
                require Data::Dumper;
                log_debug('APIManager', "Message $i tool_calls: " . Data::Dumper::Dumper($payload->{messages}[$i]{tool_calls}));
            }
        }
    }

    # Encode and validate JSON payload
    my $json = $self->_encode_payload_json($payload, $is_streaming);
    return { error_result => $json } if ref($json) eq 'HASH' && !$json->{success};

    # Create HTTP client with extended timeout for slow local inference (llama.cpp, SAM, LM Studio)
    # Use shared client for connection pooling (keep-alive)
    my $default_timeout = 300;  # Fast API (cloud) default
    my $slow_timeout = 600;      # Slow API (local inference) default
    my $ua_timeout = $endpoint_config->{slow_api} ? $slow_timeout : $default_timeout;
    my $ua = $self->_get_shared_http_client(
        timeout  => $ua_timeout,
        agent    => 'GitHubCopilotChat/0.22.4',
        ssl_opts => { verify_hostname => 1 }
    );

    # Build HTTP request with headers
    my ($req, $final_endpoint) = $self->_build_request($endpoint, $endpoint_config, $json, $is_streaming, \%opts);

    # Determine provider label for logging
    my $provider_label = $endpoint_config->{minimax} ? 'MiniMax' :
                         $endpoint_config->{requires_copilot_headers} ? 'GitHub Copilot' :
                         $endpoint_config->{openrouter} ? 'OpenRouter' :
                         $endpoint_config->{google} ? 'Google' :
                         $endpoint_config->{anthropic} ? 'Anthropic' :
                         $endpoint_config->{nvidia} ? 'NVIDIA' : 'API';

    # Log full request to debug log
    $self->_log_api_request($req, $final_endpoint, $provider_label, $model, $json, $is_streaming, $use_responses_api);

    return {
        req              => $req,
        ua               => $ua,
        final_endpoint   => $final_endpoint,
        endpoint_config  => $endpoint_config,
        model            => $model,
        messages         => $messages,
        json             => $json,
        payload          => $payload,
        provider_label   => $provider_label,
        use_responses_api => $use_responses_api,
    };
}

# Log JSON encoding/validation errors to /tmp/clio_json_errors.log
=head2 _encode_payload_json($payload, $is_streaming)

Encode payload hash to JSON, validate round-trip. Returns JSON string on success
or error hashref on failure.

=cut

sub _encode_payload_json {
    my ($self, $payload, $is_streaming) = @_;

    my $json;
    eval { $json = encode_json($payload); };
    if ($@) {
        $self->_log_json_error("JSON Encoding Failure", $@, $payload);
        my $err = "Failed to encode request as JSON: $@";
        return $is_streaming ? { success => 0, error => $err }
                             : $self->_error($err);
    }

    eval { decode_json($json); };
    if ($@) {
        $self->_log_json_error("JSON Validation Failure", $@, undef, $json);
        my $err = "Generated invalid JSON: $@";
        return $is_streaming ? { success => 0, error => $err }
                             : $self->_error($err);
    }

    return $json;
}

# Log JSON encoding/validation errors to /tmp/clio_json_errors.log
sub _log_json_error {
    my ($self, $label, $error, $payload, $json_str) = @_;
    if (open my $fh, '>>', '/tmp/clio_json_errors.log') {
        print $fh "\n" . "=" x 80 . "\n";
        print $fh "[" . scalar(localtime) . "] $label\n";
        print $fh "Error: $error\n";
        if ($payload) {
            require Data::Dumper;
            print $fh "Payload structure:\n";
            print $fh Data::Dumper::Dumper($payload);
        }
        if ($json_str) {
            print $fh "Generated JSON:\n$json_str\n";
        }
        close $fh;
    }
}

# Log full API request to debug log (and /tmp/clio_api_debug.log when --debug)
sub _log_api_request {
    my ($self, $req, $final_endpoint, $provider_label, $model, $json, $is_streaming, $use_responses_api) = @_;
    my $stream_label = $is_streaming ? "STREAMING " : "";

    log_debug('APIManager', "=" x 80);
    log_debug('APIManager', "[$provider_label ${stream_label}REQUEST] Endpoint: $final_endpoint");
    log_debug('APIManager', "[$provider_label ${stream_label}REQUEST] Model: $model");
    if ($self->{debug}) {
        eval {
            my $p = decode_json($json);
            log_debug('APIManager', "[$provider_label ${stream_label}REQUEST] max_tokens: " . ($p->{max_tokens} || 'NOT SET'));
            log_debug('APIManager', "[$provider_label ${stream_label}REQUEST] tools: " . (ref($p->{tools}) eq 'ARRAY' ? scalar(@{$p->{tools}}) . " tools" : 'none'));
            log_debug('APIManager', "[$provider_label ${stream_label}REQUEST] messages: " . (ref($p->{messages}) eq 'ARRAY' ? scalar(@{$p->{messages}}) . " messages" : 'none'));
            # Per-message summary: role, content size, first ~100 chars of text content
            if (ref($p->{messages}) eq 'ARRAY') {
                for (my $i = 0; $i < @{$p->{messages}}; $i++) {
                    my $msg = $p->{messages}[$i];
                    my $role = $msg->{role} // 'unknown';
                    my $size_info = '';
                    my $preview = '';
                    if (ref($msg->{content}) eq 'ARRAY') {
                        # Multimodal content: count text/image parts
                        my @text_parts = grep { ref($_) eq 'HASH' && ($_->{type} // '') eq 'text' } @{$msg->{content}};
                        my $image_count = scalar(grep { ref($_) eq 'HASH' && ($_->{type} // '') eq 'image_url' } @{$msg->{content}});
                        my $text_bytes = 0;
                        for my $part (@text_parts) {
                            $text_bytes += length($part->{text} // '');
                        }
                        $size_info = "multimodal: " . scalar(@text_parts) . " text + $image_count image ($text_bytes text bytes)";
                        $preview = $text_parts[0]{text} // '';
                    } elsif (defined $msg->{content}) {
                        $size_info = length($msg->{content}) . " chars";
                        $preview = $msg->{content};
                    }
                    # Tool call summary for assistant messages
                    my $tc_info = '';
                    if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY' && @{$msg->{tool_calls}}) {
                        my @tc_names = map { $_->{function}{name} // 'unknown' } @{$msg->{tool_calls}};
                        $tc_info = ", tool_calls=[" . join(',', @tc_names) . "]";
                    }
                    # Tool result summary
                    my $tr_info = '';
                    if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{name}) {
                        $tr_info = ", tool_name=$msg->{name}";
                    }
                    my $preview_trim = $preview;
                    $preview_trim =~ s/\s+/ /g;
                    $preview_trim = substr($preview_trim, 0, 100);
                    $preview_trim .= '...' if length($preview) > 100;
                    log_debug('APIManager', sprintf("[%s %sREQUEST]   msg[%d] %s (%s)%s%s%s",
                        $provider_label, $stream_label, $i, $role, $size_info, $tc_info, $tr_info,
                        $preview_trim ? ": \"$preview_trim\"" : ''));
                }
            }
            # Tool definitions being sent
            if (ref($p->{tools}) eq 'ARRAY') {
                my @tool_names = map { $_->{function}{name} // $_->{name} // 'unknown' } @{$p->{tools}};
                log_debug('APIManager', "[$provider_label ${stream_label}REQUEST] tool_names: " . join(', ', @tool_names));
            }
            # Input items for Responses API (alternative to messages)
            if (ref($p->{input}) eq 'ARRAY') {
                log_debug('APIManager', "[$provider_label ${stream_label}REQUEST] input_items: " . scalar(@{$p->{input}}));
                for (my $i = 0; $i < @{$p->{input}}; $i++) {
                    my $item = $p->{input}[$i];
                    my $type = $item->{type} // 'unknown';
                    my $role = $item->{role} // '';
                    my $content = $item->{content};
                    my $size_info = '';
                    my $preview = '';
                    if (ref($content) eq 'ARRAY') {
                        my @text_parts = grep { ref($_) eq 'HASH' && ($_->{type} // '') eq 'input_text' } @$content;
                        $size_info = scalar(@text_parts) . " text parts";
                        $preview = $text_parts[0]{text} // '' if @text_parts;
                    } elsif (defined $content) {
                        $size_info = length($content) . " chars";
                        $preview = $content;
                    }
                    my $preview_trim = $preview;
                    $preview_trim =~ s/\s+/ /g;
                    $preview_trim = substr($preview_trim, 0, 100);
                    $preview_trim .= '...' if length($preview) > 100;
                    my $role_str = $role ? " $role" : '';
                    log_debug('APIManager', sprintf("[%s %sREQUEST]   input[%d]%s %s (%s)%s",
                        $provider_label, $stream_label, $i, $role_str, $type, $size_info,
                        $preview_trim ? ": \"$preview_trim\"" : ''));
                }
            }
            # Total payload size for capacity planning
            log_debug('APIManager', "[$provider_label ${stream_label}REQUEST] payload_size: " . length($json) . " bytes");
        };
    }
    if ($self->{debug} && open my $fh, '>>', '/tmp/clio_api_debug.log') {
        print $fh "\n" . "=" x 80 . "\n";
        print $fh "[" . scalar(localtime) . "] $provider_label ${stream_label}REQUEST\n";
        print $fh "Endpoint: $final_endpoint\n";
        print $fh "Model: $model\n";
        # Structured summary before raw JSON body
        eval {
            my $p = decode_json($json);
            print $fh "Payload size: " . length($json) . " bytes\n";
            if (ref($p->{messages}) eq 'ARRAY') {
                print $fh "Messages (" . scalar(@{$p->{messages}}) . "):\n";
                for (my $i = 0; $i < @{$p->{messages}}; $i++) {
                    my $msg = $p->{messages}[$i];
                    my $role = $msg->{role} // 'unknown';
                    my $content_len = 0;
                    if (ref($msg->{content}) eq 'ARRAY') {
                        for my $part (@{$msg->{content}}) {
                            $content_len += length($part->{text} // '') if ref($part) eq 'HASH';
                        }
                    } else {
                        $content_len = length($msg->{content} // '');
                    }
                    my $tc_str = '';
                    if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY' && @{$msg->{tool_calls}}) {
                        my @tc_names = map { my $n = $_->{function}{name}; $n //= '?'; $n } @{$msg->{tool_calls}};
                        $tc_str = " tool_calls=[" . join(',', @tc_names) . "]";
                    }
                    printf $fh "  [%d] %s (%d chars)%s\n", $i, $role, $content_len, $tc_str;
                }
            }
            if (ref($p->{tools}) eq 'ARRAY') {
                print $fh "Tools (" . scalar(@{$p->{tools}}) . "):\n";
                for my $t (@{$p->{tools}}) {
                    print $fh "  - " . ($t->{function}{name} // $t->{name} // 'unknown') . "\n";
                }
            }
            if (ref($p->{input}) eq 'ARRAY') {
                print $fh "Input items (" . scalar(@{$p->{input}}) . "):\n";
                for (my $i = 0; $i < @{$p->{input}}; $i++) {
                    my $item = $p->{input}[$i];
                    my $type = $item->{type} // '?';
                    my $role = $item->{role} // '';
                    print $fh "  [$i] $role $type\n";
                }
            }
            print $fh "\n";
        };
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
}

# Log API response to debug log and file
sub _log_api_response {
    my ($self, $resp, $provider_label, $is_error) = @_;
    my $status = $resp->status_line;
    my $body = $resp->decoded_content // '';
    my $label = $is_error ? "RESPONSE ERROR" : "RESPONSE";

    log_debug('APIManager', "[$provider_label $label] Status: $status");
    log_debug('APIManager', "[$provider_label $label] Body: " . substr($body, 0, 1500)) unless $is_error;

    if ($self->{debug} && open my $fh, '>>', '/tmp/clio_api_debug.log') {
        print $fh "\n" . "-"x80 . "\n";
        print $fh "[" . scalar(localtime) . "] $provider_label $label\n";
        print $fh "Status: $status\n";
        unless ($is_error) {
            print $fh "Headers:\n";
            for my $h ($resp->headers->header_field_names) {
                print $fh "  $h: " . $resp->header($h) . "\n";
            }
        }
        print $fh "\nBody:\n" . substr($body, 0, ($is_error ? 2000 : length($body))) . "\n";
        close $fh;
    }
}

sub send_request {
    my ($self, $input, %opts) = @_;

    my $ctx = $self->_prepare_api_request($input, %opts, is_streaming => 0);
    
    # Check rate limiter before making request (provider_label may be undefined for early returns)
    my $provider = lc($ctx->{provider_label} // 'unknown');
    my $wait = $self->{rate_limiter}->check_and_wait($provider);
    if ($wait > 0) {
        log_info('APIManager', "Rate limited by $provider, waiting ${wait}s...");
        sleep($wait);
    }
    
    # Acquire slot in rate limiter
    unless ($self->{rate_limiter}->acquire($provider, $ctx->{model})) {
        return { 
            success => 0, 
            error => "Concurrency limit reached for $provider, please try again",
            retryable => 1,
            retry_after => 1,
            error_type => 'concurrency_limit'
        };
    }
    
    # Release slot and return early for cached/pre-computed results (no HTTP request needed)
    if ($ctx->{native_result}) {
        $self->{rate_limiter}->release($provider);
        return $ctx->{native_result};
    }
    if ($ctx->{error_result}) {
        $self->{rate_limiter}->release($provider);
        return $ctx->{error_result};
    }

    my $perf_start_time = time();

    my $resp;
    eval {
        $resp = $ctx->{ua}->request($ctx->{req});
        if ($self->{debug}) {
            log_debug('APIManager', sprintf("Response status: %s", $resp->status_line));
            log_debug('APIManager', sprintf("Error response: %s", $resp->decoded_content)) if !$resp->is_success;
        }
    };

    return $self->_process_non_streaming_response($resp, $@, $perf_start_time, $ctx, \%opts);
}

=head2 _process_non_streaming_response($resp, $eval_error, $perf_start_time, $ctx, $opts)

Process the HTTP response from a non-streaming API request.
Handles error detection, JSON decoding, content extraction (Chat Completions,
Responses API, and fallback formats), stateful marker tracking, performance
recording, and result construction.

Returns the final result hashref suitable for the caller.

=cut

sub _process_non_streaming_response {
    my ($self, $resp, $eval_error, $perf_start_time, $ctx, $opts) = @_;

    my $model           = $ctx->{model};
    my $endpoint_config = $ctx->{endpoint_config};
    my $provider_label  = $ctx->{provider_label};
    my $messages        = $ctx->{messages};
    my $json            = $ctx->{json};
    my $use_responses_api = $ctx->{use_responses_api};

    # Handle request-level failure ($@ from eval around ua->request)
    if ($eval_error) {
        $self->{performance_monitor}->record_api_call($self->{api_base}, $model,
            { start_time => $perf_start_time, end_time => time(), success => 0, error => "Request failed: $eval_error" });
        $self->{response_handler}->release_broker_slot(undef, 599);
        return { success => 0, error => "Request failed: $eval_error", retryable => 1, retry_after => 2, error_type => 'server_error' };
    }

    # Handle HTTP error status
    if (!$resp->is_success) {
        $self->_log_api_response($resp, $provider_label, 1);
        $self->{response_handler}->release_broker_slot($resp, $resp->code);
        $self->{rate_limiter}->release(lc($provider_label));
        return $self->{response_handler}->handle_error_response($resp, $json, 0,
            attempt_token_recovery => sub { $self->_attempt_token_recovery() },
            headers => $resp->headers);
    }

    # Successful response
    my $rate_limit_info = $self->{response_handler}->process_rate_limit_headers($resp->headers);
    if (ref($rate_limit_info) eq 'HASH' && ref($rate_limit_info->{rate_limit_info}) eq 'HASH') {
        # Feed Anthropic headers (when present) into the token-bucket
        # throttle. Without this the input-token layer stays ignorant of
        # the API's declared ITPM/OTPM/RPM and falls back to learner-only.
        $self->_apply_anthropic_rate_limit_headers($model, $rate_limit_info->{rate_limit_info});
    }
    $self->{rate_limiter}->update_from_headers(lc($provider_label), $resp->headers);
    $self->{rate_limiter}->release(lc($provider_label));
    $self->_log_api_response($resp, $provider_label, 0);

    my $data = safe_decode_json($resp->decoded_content);
    if ($@) {
        log_error('APIManager', "[$provider_label] Invalid response: $@");
        return $self->_error("Invalid response format: $@");
    }

    # Log key fields
    eval {
        my $c = $data->{choices}[0] || {};
        log_debug('APIManager', sprintf("[$provider_label] finish=%s tools=%d content=%d usage=%d/%d",
            $c->{finish_reason} || '?', ($c->{message}{tool_calls} ? scalar @{$c->{message}{tool_calls}} : 0),
            length($c->{message}{content} || ''), $data->{usage}{prompt_tokens} || 0, $data->{usage}{completion_tokens} || 0));
    };

    $self->_extract_stateful_markers($data, $opts);
    $self->{response_handler}->process_quota_headers($resp->headers, $data->{id}) if $endpoint_config->{requires_copilot_headers};

    # Parse copilot_usage from response body (June 2026+ AI Credit billing)
    if ($endpoint_config->{requires_copilot_headers} && $data->{copilot_usage}) {
        $self->_process_copilot_usage($data->{copilot_usage}, $data->{model});
    }

    # Extract content
    my ($content, $tool_calls, $reasoning_details, $responses_reasoning_items) =
        $self->_extract_response_content($data, $use_responses_api, $opts);
    my ($tokens_in, $tokens_out) = $self->_extract_usage_tokens($data, $use_responses_api);

    # Post-process content
    if (defined $content && length($content)) {
        # Strip inline thinking tags from any provider's non-streaming
        # response. Mirrors the provider-agnostic streaming extraction in
        # _process_think_tags: any chat template that emits thinking inline
        # (llama.cpp + Qwen3, DeepSeek-R1 distills, MiniMax M2.x) hits this
        # path. Providers using a separate reasoning_content field never put
        # think tags in their content, so this is a no-op for them. Accepts
        # all known tag variants: <think>, <thinking>, [think], [thinking]
        # and their matching closes.
        if ($content =~ /(?:<think>|<thinking>|\[think\]|\[thinking\])/) {
            $content =~ s{(?:<think>|<thinking>|\[think\]|\[thinking\])(.*?)(?:</think>|</thinking>|\[/think\]|\[/thinking\])\n*}{}sg;
            $content =~ s{(?:</?think>|</?thinking>|\[/?think\]|\[/?thinking\])}{}g;
            $content =~ s/^\n+//;
        }
        $content = "[conversation]$content\[/conversation]" unless $content =~ m{\[conversation\].*?\[/conversation\]}s;

        if ($data->{usage}) {
            $tokens_in  ||= $data->{usage}{prompt_tokens} || $data->{usage}{input_tokens} || 0;
            $tokens_out ||= $data->{usage}{completion_tokens} || $data->{usage}{output_tokens} || 0;
            $self->_learn_from_api_response($data->{usage}, $messages, $opts->{tools});
        }

        $self->{performance_monitor}->record_api_call($self->{api_base}, $model,
            { start_time => $perf_start_time, end_time => time(), success => 1, tokens_in => $tokens_in, tokens_out => $tokens_out });

        my $result = { content => $content, usage => $data->{usage} };
        $result->{tool_calls} = $tool_calls if $tool_calls;
        $result->{reasoning_details} = $reasoning_details if $reasoning_details;
        $result->{responses_reasoning_items} = $responses_reasoning_items if $responses_reasoning_items;
        $self->{response_handler}->release_broker_slot($resp, 200);
        return $result;
    }

    # Tool-calls-only (no text)
    if ($tool_calls && @$tool_calls) {
        $self->{response_handler}->release_broker_slot($resp, 200);
        my $tc_result = { content => '', tool_calls => $tool_calls, usage => $data->{usage} };
        $tc_result->{responses_reasoning_items} = $responses_reasoning_items if $responses_reasoning_items;
        return $tc_result;
    }

    log_error('APIManager', "No message content in response") if $self->{debug};
    $self->{response_handler}->release_broker_slot($resp, 200);
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

    # Extract callbacks before passing opts to _prepare_api_request
    my $on_chunk     = delete $opts{on_chunk};
    my $on_tool_call = delete $opts{on_tool_call};
    my $on_thinking  = delete $opts{on_thinking};

    my $ctx = $self->_prepare_api_request($input, %opts,
        is_streaming => 1,
        _on_chunk     => $on_chunk,
        _on_tool_call => $on_tool_call,
        _on_thinking  => $on_thinking,
    );
    
    # Check rate limiter before making request (provider_label may be undefined for early returns)
    my $provider = lc($ctx->{provider_label} // 'unknown');
    my $wait = $self->{rate_limiter}->check_and_wait($provider);
    if ($wait > 0) {
        log_info('APIManager', "Rate limited by $provider, waiting ${wait}s...");
        sleep($wait);
    }
    
    # Acquire slot in rate limiter
    unless ($self->{rate_limiter}->acquire($provider, $ctx->{model})) {
        return { 
            success => 0, 
            error => "Concurrency limit reached for $provider, please try again",
            retryable => 1,
            retry_after => 1,
            error_type => 'concurrency_limit'
        };
    }
    
    # Release slot and return early for cached/pre-computed results (no HTTP request needed)
    if ($ctx->{native_result}) {
        $self->{rate_limiter}->release($provider);
        return $ctx->{native_result};
    }
    if ($ctx->{error_result}) {
        $self->{rate_limiter}->release($provider);
        return $ctx->{error_result};
    }
    
    my $model             = $ctx->{model};
    my $endpoint_config   = $ctx->{endpoint_config};
    my $provider_label    = $ctx->{provider_label};
    my $messages          = $ctx->{messages};
    my $json              = $ctx->{json};
    my $use_responses_api = $ctx->{use_responses_api};

    # Streaming state - shared between callback and post-processing
    my $ss = {
        accum_content    => '',
        accum_reasoning  => '',
        tool_calls_acc   => {},
        streaming_usage  => undef,
        token_count      => 0,
        first_token_time => undef,
        start_time       => time(),
        reasoning_active => 0,
        in_think_tag     => 0,
        think_buffer     => '',
        use_responses_api => $use_responses_api,
        model            => $model,
        on_chunk         => $on_chunk,
        on_tool_call     => $on_tool_call,
        on_thinking      => $on_thinking,
        opts             => \%opts,
    };

    my $buffer = '';
    my $raw_response_body = '';
    my $resp;
    my $streaming_headers;

    log_debug('APIManager', "send_request_streaming: HTTP client " . ref($ctx->{ua}));

    eval {
        $resp = $ctx->{ua}->request($ctx->{req}, sub {
            my ($chunk, $response, $protocol) = @_;

            # Capture headers on first chunk
            if (!$streaming_headers && $response) {
                $streaming_headers = $response->headers->clone;
                log_debug('APIManager', "Streaming response HTTP status: " . $response->code . " " . ($response->message // ''));
            }

            $raw_response_body .= $chunk;
            $buffer .= $chunk;
            $buffer =~ s/\r\n/\n/g;

            # Process complete SSE lines (ending with \n\n)
            while ($buffer =~ s/^(.*?)\n\n//s) {
                my $sse_chunk = $1;
                next unless $sse_chunk =~ /\S/;

                # Check for user interrupt (ESC) after each SSE event.
                # This is the PRIMARY interrupt detection point for streaming.
                # It's called from regular code (not signal context), so
                # Interrupt::check() can safely do the 50ms escape-sequence
                # disambiguation. Checking here - between SSE events, not
                # just between HTTP chunks - ensures we catch interrupts
                # even when the ALRM handler hasn't fired yet or when
                # chunks are large and infrequent.
                if (eval { CLIO::Core::Interrupt::pending(session => $self->{session}) }
                    || eval { CLIO::Core::Interrupt::check(session => $self->{session}) }) {
                    log_info('APIManager', "Interrupt detected in SSE stream, aborting");
                    $ss->{_user_interrupted} = 1;
                    # Throw to break out of HTTP::Tiny/curl streaming loop.
                    # For HTTP::Tiny this propagates through data_callback;
                    # for curl the exception is caught by _request_via_curl_streaming's
                    # own eval{}. Both cases set _interrupt_pending via the
                    # orchestrator's on_chunk chain, and the post-streaming
                    # check in send_request_streaming detects the abort.
                    die "__CLIO_INTERRUPT_ABORT__\n";
                }

                my $event_type = '';
                for my $line (split /\n/, $sse_chunk) {
                    if ($line =~ /^event:\s*(.+)$/) {
                        $event_type = $1;
                        next;
                    }
                    next unless $line =~ /^data:\s*(.+)$/;
                    my $data_json = $1;
                    next if $data_json eq '[DONE]';

                    my $data = safe_decode_json($data_json);
                    if ($@) {
                        log_warning('APIManager', "Failed to parse SSE chunk: $@");
                        next;
                    }
                    # Skip null/non-object payloads (e.g. JSON `null`, scalar) - they
                    # have no fields to dispatch on and would crash _process_sse_data
                    # which dereferences $data unconditionally.
                    next unless ref($data) eq 'HASH';

                   $event_type = $data->{type} if !$event_type && $data->{type};
                    $self->_process_sse_data($data, $event_type, $ss);
                }
            }
        });
    };
    
    # Check if the user interrupted streaming. Two paths can trigger this:
    # 1. The HTTP::Tiny data_callback threw __CLIO_INTERRUPT_ABORT__ when
    #    Interrupt::pending() was true (HTTP::Tiny path, no curl).
    # 2. The curl streaming loop killed the curl process and broke when
    #    Interrupt::pending() was true (curl path, native + fallback).
    # In both cases the ALRM handler set the global flag, and the SSE
    # processing callback's on_chunk chain set _interrupt_pending on the
    # orchestrator. Release rate-limiter/broker slots and return early
    # with interrupted=1 so the orchestrator goes straight to _handle_interrupt.
    my $http_error = $@;
    my $user_interrupted = ($http_error && $http_error =~ /__CLIO_INTERRUPT_ABORT__/)
        || (eval { CLIO::Core::Interrupt::pending(session => $self->{session}) });
    if ($user_interrupted) {
        log_info('APIManager', "Streaming interrupted by user (ESC)");
        $self->{rate_limiter}->release($provider) if $provider && $provider ne 'unknown';
        if ($self->{response_handler}) {
            $self->{response_handler}->release_broker_slot($resp, 200);
        }
        # Do NOT clear the interrupt flag here - the orchestrator's
        # _handle_interrupt / _check_and_handle_interrupt will detect it
        # via Interrupt::pending() and clear it when the user is prompted.
        # Clearing early would cause the flag to be missed by the
        # orchestrator's post-API-check, and the ESC byte was already
        # consumed by the ALRM handler, so check() could not re-detect it.
        return {
            success => 0,
            error => 'Interrupted by user',
            interrupted => 1,
            retryable => 0,       # Do not auto-retry an interrupt
            error_type => 'user_interrupt',
            # Return any content streamed so far so the UI can show partial output
            content => $ss->{accum_content},
            ($ss->{tool_calls_acc} && keys(%{$ss->{tool_calls_acc}}) ? (tool_calls => [sort { $a <=> $b } values %{$ss->{tool_calls_acc}}]) : ()),
        };
    }
    
    # Restore $@ so _finalize_streaming_response sees the original HTTP error
    # (if any). The eval{ pending() } above may have cleared $@ on success.
    $@ = $http_error;
    
    # Post-streaming cleanup
    $self->_cleanup_streaming_state($ss);

    # Ensure streaming_headers is populated from $resp if not captured in callback
    # (needed for curl streaming where headers are parsed after streaming completes)
    unless ($streaming_headers && ref($streaming_headers) && $streaming_headers->can('header')) {
        if ($resp && ref($resp) && $resp->can('headers')) {
            $streaming_headers = $resp->headers;
            log_debug('APIManager', "Using headers from response object (callback didn't capture)");
        }
    }

    return $self->_finalize_streaming_response(
        resp                  => $resp,
        error                 => $@,
        buffer                => $buffer,
        raw_response_body     => $raw_response_body,
        accumulated_content   => $ss->{accum_content},
        accumulated_reasoning => $ss->{accum_reasoning},
        streaming_usage       => $ss->{streaming_usage},
        streaming_headers     => $streaming_headers,
        token_count           => $ss->{token_count},
        start_time            => $ss->{start_time},
        first_token_time      => $ss->{first_token_time},
        tool_calls_accumulator => $ss->{tool_calls_acc},
        endpoint_config       => $endpoint_config,
        provider_label        => $provider_label,
        messages              => $messages,
        input                 => $input,
        json                  => $json,
        _finish_reason        => $ss->{_finish_reason},
        _sse_error            => $ss->{_sse_error},
    );
}

=head2 _process_sse_data($data, $event_type, $ss)

Process a single parsed SSE data chunk during streaming.
Updates the streaming state hash ($ss) with accumulated content,
tool calls, reasoning, usage, and stateful markers.

=cut

sub _process_sse_data {
    my ($self, $data, $event_type, $ss) = @_;

    if (should_log('DEBUG')) {
        my @fields = keys %$data;
        log_debug('APIManager', "SSE chunk fields: " . join(', ', @fields));
        log_debug('APIManager', "Chunk has id: " . substr($data->{id}, 0, 30) . "...") if $data->{id};
    }

    # Capture SSE error-only chunks. Two patterns to handle:
    #   1. Chat Completions / OpenAI-compat: {"error":{"message":"...","code":"..."}}
    #      (no `choices` field - NVIDIA NIM hits this when upstream provider fails)
    #   2. Responses API: {"type":"error","message":"...","code":"..."}
    #      (delivered as an SSE event with `type: error`)
    # Both end up with no content or tool_calls produced. Without this, the error
    # is silently swallowed and the workflow exits with an empty response.
    # Stash on streaming state so _finalize_streaming_response can surface it as
    # a retryable error.
    my $_err_hash;
    if (ref($data->{error}) eq 'HASH') {
        $_err_hash = $data->{error};
    } elsif ($event_type eq 'error' || (defined $data->{type} && $data->{type} eq 'error')) {
        $_err_hash = $data;
    }
    if ($_err_hash) {
        my $msg = $_err_hash->{message} // $_err_hash->{msg} // 'unknown';
        my $code = $_err_hash->{code} // $_err_hash->{type} // '';
        log_warning('APIManager', "SSE error chunk: code=$code message=$msg");
        $ss->{_sse_error} = { message => $msg, code => $code };
        return;  # No content/tool_calls to extract from this chunk
    }

    # Extract stateful_marker for billing session continuity
    if ($data->{stateful_marker}) {
        my $iteration = ($ss->{opts} && $ss->{opts}{tool_call_iteration}) || 1;
        $self->{response_handler}->store_stateful_marker($data->{stateful_marker}, $ss->{model}, $iteration);
    }
    # Only store response_id when it changes (not every chunk)
    if ($data->{id} && $self->{session} &&
        (!defined($self->{session}{lastGitHubCopilotResponseId}) ||
         $self->{session}{lastGitHubCopilotResponseId} ne $data->{id})) {
        $self->{session}{lastGitHubCopilotResponseId} = $data->{id};
        if (should_log('DEBUG')) {
            log_debug('APIManager', "Stored response_id fallback: " . substr($data->{id}, 0, 30) . "...");
        }
    }

    # Capture real usage from final streaming chunk
    if ($data->{usage}) {
        $ss->{streaming_usage} = {
            prompt_tokens     => $data->{usage}{prompt_tokens} || $data->{usage}{input_tokens} || 0,
            completion_tokens => $data->{usage}{completion_tokens} || $data->{usage}{output_tokens} || 0,
            total_tokens      => $data->{usage}{total_tokens} || 0,
        };
        $ss->{streaming_usage}{total_tokens} ||=
            $ss->{streaming_usage}{prompt_tokens} + $ss->{streaming_usage}{completion_tokens};
        log_debug('APIManager', "Streaming usage: prompt=$ss->{streaming_usage}{prompt_tokens}, completion=$ss->{streaming_usage}{completion_tokens}");
    }

    # Capture copilot_usage from final streaming chunk (June 2026+ AI Credit billing)
    if ($data->{copilot_usage}) {
        $ss->{copilot_usage} = $data->{copilot_usage};
        $ss->{model} //= $data->{model};
    }

    # Extract content delta and tool_calls delta
    my ($content_delta, $tool_calls_delta);

    if ($ss->{use_responses_api} && $event_type) {
        ($content_delta, $tool_calls_delta) = $self->_process_responses_api_event($data, $event_type, $ss);
    }
    elsif ($data->{choices} && @{$data->{choices}}) {
        ($content_delta, $tool_calls_delta) = $self->_process_chat_completions_delta($data, $ss);
    }

    # Accumulate tool_calls
    $self->_accumulate_tool_calls_delta($tool_calls_delta, $ss) if $tool_calls_delta;

    # Track metrics and invoke chunk callback
    if (defined($content_delta) && length($content_delta)) {
        $ss->{first_token_time} //= time();
        $ss->{token_count} += int(length($content_delta) / 4) || 1;
        $ss->{accum_content} .= $content_delta;

        if ($ss->{on_chunk}) {
            my $duration = time() - $ss->{start_time};
            my $ttft = $ss->{first_token_time} ? ($ss->{first_token_time} - $ss->{start_time}) : undef;
            my $tps  = ($duration > 0 && $ss->{token_count} > 0) ? ($ss->{token_count} / $duration) : 0;
            $ss->{on_chunk}->($content_delta, {
                token_count => $ss->{token_count},
                ttft        => $ttft,
                tps         => $tps,
                duration    => $duration,
            });
        }
    }
}

=head2 _process_responses_api_event($data, $event_type, $ss)

Process a Responses API streaming event (codex models, etc.).
Returns ($content_delta, $tool_calls_delta).

=cut

sub _process_responses_api_event {
    my ($self, $data, $event_type, $ss) = @_;

    my $content_delta = undef;

    if ($event_type eq 'response.output_text.delta') {
        $content_delta = $data->{delta} if defined $data->{delta};
        if ($ss->{reasoning_active} && $ss->{on_thinking}) {
            $ss->{on_thinking}->(undef, 'end');
            $ss->{reasoning_active} = 0;
        }
    }
    elsif ($event_type eq 'response.output_item.added') {
        my $item = $data->{item} || {};
        my $item_type = $item->{type} || '';

        if ($item_type eq 'function_call') {
            my $idx = $data->{output_index} // 0;
            $ss->{tool_calls_acc}{$idx} = {
                id       => $item->{call_id} || '',
                type     => 'function',
                function => { name => $item->{name} || '', arguments => '' },
                _name_complete => 0,
            };
            if ($ss->{on_tool_call} && $item->{name}) {
                $ss->{tool_calls_acc}{$idx}{_name_complete} = 1;
                $ss->{on_tool_call}->($item->{name});
            }
            log_debug('APIManager', "Responses API: function_call started: " . ($item->{name} || '?'));
        }
        elsif ($item_type eq 'reasoning') {
            $ss->{reasoning_active} = 1;
            # Capture the reasoning item id so we can correlate subsequent
            # encrypted_content/phase fields to the same item.
            $ss->{_last_reasoning_idx} = $data->{output_index};
            log_debug('APIManager', "Responses API: reasoning started (idx=" . $data->{output_index} . ")");
        }
    }
    elsif ($event_type eq 'response.function_call_arguments.delta') {
        my $idx = $data->{output_index} // 0;
        if ($ss->{tool_calls_acc}{$idx}) {
            $ss->{tool_calls_acc}{$idx}{function}{arguments} .= ($data->{delta} // '');
        }
    }
    elsif ($event_type eq 'response.reasoning.delta') {
        # Raw reasoning text delta. Responses API streams reasoning text
        # in this event for models without summary mode, or alongside
        # summary for verbose models. We accumulate it and surface it
        # to on_thinking so the UI displays it like summary deltas.
        if ($ss->{on_thinking} && defined $data->{delta} && length $data->{delta}) {
            $ss->{reasoning_active} = 1;
            $ss->{on_thinking}->($data->{delta});
            $ss->{accum_reasoning} .= $data->{delta};
        }
    }
    elsif ($event_type eq 'response.output_item.done') {
        my $item = $data->{item} || {};
        my $item_type = $item->{type} || '';

        if ($item_type eq 'function_call') {
            my $idx = $data->{output_index} // 0;
            if ($ss->{tool_calls_acc}{$idx}) {
                $ss->{tool_calls_acc}{$idx}{id} = $item->{call_id} || $ss->{tool_calls_acc}{$idx}{id};
                $ss->{tool_calls_acc}{$idx}{function}{name} = $item->{name} || $ss->{tool_calls_acc}{$idx}{function}{name};
                my $final_args = $item->{arguments} // $ss->{tool_calls_acc}{$idx}{function}{arguments};
                $final_args = safe_encode_json($final_args, '{}') if ref($final_args);
                $ss->{tool_calls_acc}{$idx}{function}{arguments} = $final_args;
            }
            log_debug('APIManager', "Responses API: function_call completed: " . ($item->{name} || '?'));
        }
        elsif ($item_type eq 'reasoning') {
            if ($ss->{on_thinking} && $ss->{reasoning_active}) {
                $ss->{on_thinking}->(undef, 'end');
            }
            $ss->{reasoning_active} = 0;
            # Capture encrypted_content + summary + phase for round-trip on the
            # next turn. Per Responses API docs, the complete reasoning item
            # (including encrypted_content) must be sent back as input so the
            # model can resume from the same reasoning state. The phase field
            # distinguishes 'commentary' (preamble) from 'final_answer' parts.
            if (defined $item->{encrypted_content} && length $item->{encrypted_content}) {
                $ss->{_reasoning_items} ||= [];
                push @{$ss->{_reasoning_items}}, {
                    type              => 'reasoning',
                    id                => $item->{id},
                    encrypted_content => $item->{encrypted_content},
                    summary           => $item->{summary} || [],
                    phase             => $item->{phase} // 'commentary',
                };
            }
        }
    }
    elsif ($event_type eq 'response.reasoning_summary_text.delta') {
        if ($ss->{on_thinking} && defined $data->{delta}) {
            $ss->{reasoning_active} = 1;
            $ss->{on_thinking}->($data->{delta});
            $ss->{accum_reasoning} .= $data->{delta};
        }
    }
    elsif ($event_type eq 'response.completed') {
        my $resp_data = $data->{response} || {};
        if ($resp_data->{id} && $self->{session}) {
            my $iteration = ($ss->{opts} && $ss->{opts}{tool_call_iteration}) || 1;
            $self->{response_handler}->store_stateful_marker($resp_data->{id}, $ss->{model}, $iteration);
            $self->{session}{lastGitHubCopilotResponseId} = $resp_data->{id};
        }
        if ($resp_data->{usage}) {
            $ss->{streaming_usage} = {
                prompt_tokens     => $resp_data->{usage}{input_tokens} || 0,
                completion_tokens => $resp_data->{usage}{output_tokens} || 0,
                total_tokens      => ($resp_data->{usage}{input_tokens} || 0) + ($resp_data->{usage}{output_tokens} || 0),
            };
        }
        # Track completion so _finalize_streaming_response can distinguish a
        # legitimate stream end (response.completed -> finish_reason=stop or
        # tool_calls) from a mid-stream truncation. Mirror of the
        # choices[].finish_reason capture in _process_chat_completions_delta.
        my $status = $resp_data->{status} // '';
        if ($status eq 'completed') {
            $ss->{_finish_reason} = 'stop';
        } elsif (length $status) {
            $ss->{_finish_reason} = $status;
        }
        log_debug('APIManager', "Responses API: stream completed, status=" . ($resp_data->{status} || '?'));
    }
    elsif ($event_type eq 'error') {
        log_warning('APIManager', "Responses API error: [" . ($data->{code} || 'unknown') . "] " . ($data->{message} || 'Unknown'));
    }

    return ($content_delta, undef);
}

=head2 _process_chat_completions_delta($data, $ss)

Process a Chat Completions streaming delta (OpenAI/GitHub Copilot format).
Handles content, tool_calls, reasoning (multiple formats), and MiniMax think tags.
Returns ($content_delta, $tool_calls_delta).

=cut

sub _process_chat_completions_delta {
    my ($self, $data, $ss) = @_;

    my $choice = $data->{choices}[0];
    my $delta  = $choice->{delta} || return (undef, undef);

    # Capture finish_reason / stop_reason from the choice so
    # _finalize_streaming_response can distinguish a legitimate stream end
    # (`"stop"` or `"tool_calls"`) from a mid-stream SSE error chunk. Without
    # this the finalizer cannot tell "the model finished its turn" apart from
    # "the connection died halfway through" - both look like an empty
    # choices[].finish_reason on the next-to-last delta.
    # MiniMax and similar OpenAI-compat providers emit finish_reason on the
    # same delta as the last tool_call/content fragment, then send a final
    # [DONE] marker; some skip the [DONE] when the stream truncates.
    if (defined $choice->{finish_reason} && length $choice->{finish_reason}) {
        $ss->{_finish_reason} = $choice->{finish_reason};
    }

    my $content_delta    = undef;
    my $tool_calls_delta = undef;

    # Stateful marker in delta
    if ($delta->{stateful_marker}) {
        my $iteration = ($ss->{opts} && $ss->{opts}{tool_call_iteration}) || 1;
        $self->{response_handler}->store_stateful_marker($delta->{stateful_marker}, $ss->{model}, $iteration);
    }

    # Content extraction
    if (defined($delta->{content}) && length($delta->{content})) {
        $content_delta = $delta->{content};

        # Inline thinking-tag extraction. Provider-agnostic: models running
        # through llama.cpp (Qwen3, DeepSeek-R1 distills), MiniMax M2.x,
        # and any other chat template that emits thinking inline in
        # delta.content all hit this path. Providers that use a separate
        # reasoning_content field (DeepSeek API, OpenRouter, NVIDIA) never
        # put think tags in delta.content, so this is a no-op for them.
        if (defined $content_delta) {
            $content_delta = $self->_process_think_tags($content_delta, $ss);
            $content_delta = undef unless defined($content_delta) && length($content_delta);
        }

        # Signal end of reasoning when regular content starts
        if (defined($content_delta) && length($content_delta) && $ss->{reasoning_active} && $ss->{on_thinking}) {
            $ss->{on_thinking}->(undef, 'end');
            $ss->{reasoning_active} = 0;
        }
    }

    # Reasoning content extraction (multiple formats, emit once per chunk)
    my $emitted = 0;

    # 1. reasoning_content (DeepSeek, some OpenAI-compat)
    if (!$emitted && $delta->{reasoning_content} && $ss->{on_thinking}) {
        $ss->{reasoning_active} = 1;
        $ss->{accum_reasoning} .= $delta->{reasoning_content};
        $ss->{on_thinking}->($delta->{reasoning_content});
        $emitted = 1;
    }

    # 2. reasoning_details array (OpenRouter, MiniMax)
    if (!$emitted && $delta->{reasoning_details} && ref($delta->{reasoning_details}) eq 'ARRAY' && $ss->{on_thinking}) {
        for my $detail (@{$delta->{reasoning_details}}) {
            next unless ref($detail) eq 'HASH';
            my $type = $detail->{type} || '';
            my $text = ($type eq 'reasoning.summary') ? $detail->{summary}
                     : $detail->{text};
            if (defined $text && (!$type || $type =~ /^reasoning\.(text|summary)$/ || !$type)) {
                $ss->{reasoning_active} = 1;
                $ss->{accum_reasoning} .= $text;
                $ss->{on_thinking}->($text);
                $emitted = 1;
            }
        }
    }

    # 3. Legacy reasoning string
    if (!$emitted && $delta->{reasoning} && !ref($delta->{reasoning}) && $ss->{on_thinking}) {
        $ss->{reasoning_active} = 1;
        $ss->{accum_reasoning} .= $delta->{reasoning};
        $ss->{on_thinking}->($delta->{reasoning});
    }

    # Tool calls delta
    $tool_calls_delta = $delta->{tool_calls} if $delta->{tool_calls} && ref($delta->{tool_calls}) eq 'ARRAY';

    return ($content_delta, $tool_calls_delta);
}

=head2 _accumulate_tool_calls_delta($deltas, $ss)

Accumulate incremental tool_calls deltas into the streaming state accumulator.

=cut

sub _accumulate_tool_calls_delta {
    my ($self, $deltas, $ss) = @_;

    for my $tc_delta (@$deltas) {
        my $index = $tc_delta->{index} // 0;

        if (!$ss->{tool_calls_acc}{$index}) {
            my $raw_id = $tc_delta->{id} // '';
            my $norm_id = ($raw_id =~ /^function-call-(\d+)$/)
                ? 'call_' . substr($1, -24)
                : $raw_id;
            $ss->{tool_calls_acc}{$index} = {
                id       => $norm_id,
                type     => $tc_delta->{type} // 'function',
                function => { name => '', arguments => '' },
                _name_complete => 0,
            };
        }

        if ($tc_delta->{function}) {
            if ($tc_delta->{function}{name} && !$ss->{tool_calls_acc}{$index}{function}{name}) {
                $ss->{tool_calls_acc}{$index}{function}{name} = $tc_delta->{function}{name};
            }
            if (!$ss->{tool_calls_acc}{$index}{_name_complete} &&
                $ss->{tool_calls_acc}{$index}{function}{name} =~ /\w/) {
                $ss->{tool_calls_acc}{$index}{_name_complete} = 1;
                $ss->{on_tool_call}->($ss->{tool_calls_acc}{$index}{function}{name}) if $ss->{on_tool_call};
            }
            if (defined $tc_delta->{function}{arguments}) {
                my $args_chunk = $tc_delta->{function}{arguments};
                # Some servers send arguments as a parsed object; re-encode
                $args_chunk = safe_encode_json($args_chunk, '')
                    if ref($args_chunk);
                $ss->{tool_calls_acc}{$index}{function}{arguments} .= $args_chunk;
            }
        }

        log_debug('APIManager', "Tool call delta: index=$index, name=" .
            ($tc_delta->{function}{name} // '') . ", args_chunk=" .
            length($tc_delta->{function}{arguments} // '') . " bytes");
    }
}

=head2 _process_think_tags($content_delta, $ss)

Provider-agnostic thinking-tag state machine. Strips think tags from content
and routes thinking content to the on_thinking callback. Used by MiniMax
M2.x, llama.cpp servers running Qwen3 / DeepSeek-R1 distills, and any other
chat template that emits thinking inline in delta.content.

Models are inconsistent about the exact tag spelling. We accept all known
variants for the open tag - <think>, <thinking>, [think], [thinking] - and
their matching closes - </think>, </thinking>, [/think], [/thinking]. In
particular Qwen3.6 frequently closes with </thinking> or [/thinking] instead
of </think>, which would otherwise leave the state machine stuck in thinking
mode and swallow the real response into the thinking channel.

Returns the filtered content_delta (may be empty string).

=cut

sub _process_think_tags {
    my ($self, $content_delta, $ss) = @_;

    # Default undef fields - callers that exercise _finalize_streaming_response
    # with a synthetic $ss (e.g. tests/unit/test_sse_error_surfacing.pl
    # test 10) do not populate every key, so unguarded concatenation here
    # would emit "Use of uninitialized value in concatenation (.) or string"
    # under `perl -W`.
    my $think_buffer = $ss->{think_buffer} // '';
    my $delta        = $content_delta // '';

    my $work = $think_buffer . $delta;
    $ss->{think_buffer} = '';
    my $output = '';

    while (length($work)) {
        if ($ss->{in_think_tag}) {
            if ($work =~ s{^(.*?)(?:</think>|</thinking>|\[/think\]|\[/thinking\])}{}s) {
                my $think_text = $1;
                if (length($think_text) && $ss->{on_thinking}) {
                    $ss->{reasoning_active} = 1;
                    $ss->{accum_reasoning} .= $think_text;
                    $ss->{on_thinking}->($think_text);
                }
                $ss->{in_think_tag} = 0;
                $work =~ s/^\n+//;
            }
            elsif (_has_partial_close_think_suffix($work)) {
                my $idx = _last_tag_marker_index($work);
                my $before = substr($work, 0, $idx);
                if (length($before) && $ss->{on_thinking}) {
                    $ss->{reasoning_active} = 1;
                    $ss->{accum_reasoning} .= $before;
                    $ss->{on_thinking}->($before);
                }
                $ss->{think_buffer} = substr($work, $idx);
                $work = '';
            }
            else {
                if ($ss->{on_thinking}) {
                    $ss->{reasoning_active} = 1;
                    $ss->{accum_reasoning} .= $work;
                    $ss->{on_thinking}->($work);
                }
                $work = '';
            }
        }
        else {
            if ($work =~ s{^(.*?)(?:<think>|<thinking>|\[think\]|\[thinking\])}{}s) {
                $output .= $1;
                $ss->{in_think_tag} = 1;
            }
            elsif (_has_partial_open_think_suffix($work)) {
                my $idx = _last_tag_marker_index($work);
                $output .= substr($work, 0, $idx);
                $ss->{think_buffer} = substr($work, $idx);
                $work = '';
            }
            else {
                # Strip stale close tags without matching open tags
                $work =~ s{(?:</think>|</thinking>|\[/think\]|\[/thinking\])}{}g;
                $output .= $work;
                $work = '';
            }
        }
    }

    return $output;
}

=head2 _cleanup_streaming_state($ss)

Post-streaming cleanup: signal end of reasoning, flush think buffers,
strip residual think tags from accumulated content.

=cut

sub _cleanup_streaming_state {
    my ($self, $ss) = @_;

    # Signal end of reasoning if still active
    if ($ss->{reasoning_active} && $ss->{on_thinking}) {
        $ss->{on_thinking}->(undef, 'end');
        $ss->{reasoning_active} = 0;
    }

    # Strip residual think tags from accumulated content. Mirrors the
    # provider-agnostic think-tag extraction in _process_think_tags -
    # any provider whose chat template emits inline think tags may leave
    # a partial residue here if the stream ends inside a tag. Accepts all
    # known tag variants: <think>, <thinking>, [think], [thinking] and
    # their matching closes.
    if (length($ss->{accum_content}) && $ss->{accum_content} =~ /(?:<\/?think>|<\/?thinking>|\[\/?think\]|\[\/?thinking\])/) {
        while ($ss->{accum_content} =~ s{(?:<think>|<thinking>|\[think\]|\[thinking\])(.*?)(?:</think>|</thinking>|\[/think\]|\[/thinking\])\n*}{}sg) {
            my $residual = $1;
            if (length($residual)) {
                $ss->{accum_reasoning} .= $residual;
                $ss->{on_thinking}->($residual) if $ss->{on_thinking};
            }
        }
        $ss->{accum_content} =~ s{(?:</?think>|</?thinking>|\[/?think\]|\[/?thinking\])}{}g;
        $ss->{accum_content} =~ s/^\n+//;
        log_debug('APIManager', "Cleaned residual think tags from streaming content");
    }

    # Flush remaining think_buffer (provider-agnostic; see _process_think_tags).
    if (length($ss->{think_buffer})) {
        if (!$ss->{in_think_tag}) {
            $ss->{accum_content} .= $ss->{think_buffer};
        }
        elsif ($ss->{on_thinking}) {
            $ss->{accum_reasoning} .= $ss->{think_buffer};
            $ss->{on_thinking}->($ss->{think_buffer});
            $ss->{on_thinking}->(undef, 'end');
        }
        $ss->{think_buffer} = '';
    }
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
        log_debug('APIManager', "Streaming request failed: $s{error}");
        $self->{response_handler}->release_broker_slot(undef, 599);
        # Release rate limiter slot - send_request_streaming acquired it before
        # the eval that produced $s{error}, and the success path at the end of
        # this sub is unreachable here. Without this release the slot leaks and
        # every subsequent request to the same provider sees a permanently
        # occupied concurrency slot.
        $self->{rate_limiter}->release(lc($s{provider_label})) if $s{provider_label};
        return {
            success => 0, error => "Streaming request failed: $s{error}",
            retryable => 1, retry_after => 2, error_type => 'server_error',
        };
    }

    my $resp = $s{resp};

    # Determine status - handle both object and hash-style response objects
    my $status = eval { $resp->{status} } // eval { $resp->code } // 0;

    # Check success - use status code directly
    my $is_error = defined($status) && $status !~ /^(2\d{2})$/;

    # Set streaming headers BEFORE error check so rate limit detection can use them.
    # The streaming callback captures headers from a preliminary response stub (curl
    # streaming passes a stub with headers => {} before the real -D header file is
    # parsed). If the captured headers turned out to be empty, fall back to the
    # real response object's headers so Retry-After / x-ratelimit-* are not lost.
    if ($resp->can('headers')) {
        my $captured = $s{streaming_headers};
        my $has_fields = 0;
        if (ref($captured)) {
            if ($captured->can('header_field_names')) {
                $has_fields = scalar($captured->header_field_names());
            } elsif ($captured->can('header')) {
                # HTTP::Headers-style: header_field_names may not exist
                $has_fields = 1;  # assume populated; _handle_streaming_http_error re-checks
            }
        }
        unless ($has_fields) {
            $s{streaming_headers} = $resp->headers;
            log_debug('APIManager', "Replaced empty streaming_headers with real response headers");
        }
    }

    # Surface SSE error chunks captured during streaming. Three cases:
    #   1. Error on first chunk (no content/tool_calls streamed) - the
    #      previous NVIDIA-style case. Always treat as retryable error.
    #   2. Error mid-stream after content/tool_calls streamed, AND no
    #      finish_reason received - the stream was truncated. Treat as
    #      retryable error (the retry will regenerate the full response).
    #   3. Error mid-stream after content/tool_calls streamed, AND a
    #      finish_reason was received - the response ended legitimately
    #      and the SSE error chunk is spurious noise. Ignore it.
    # Without case (2) the MiniMax-style silent work-stop bug returns: the
    # model streams LTM writes, the connection dies, _finalize returns
    # success with no further content, and the orchestrator hangs waiting
    # for the agent to do something it never gets to. With (2) the broken
    # response is rejected and the orchestrator retries.
    if ($s{_sse_error}
        && (!$s{accumulated_content} && !keys(%{$s{tool_calls_accumulator}})
            || !$s{_finish_reason})) {
        my $sse_err = $s{_sse_error};
        $self->{response_handler}->release_broker_slot($resp, 200);
        # Release rate limiter slot - the success path below owns the release,
        # but this SSE-error early-return bypasses it. Leaked slots pinned the
        # per-provider concurrency counter at the limit, making every retry
        # hit "Concurrency limit reached for $provider" and exhaust the 3-retry
        # budget on what was originally a transient provider rate limit.
        $self->{rate_limiter}->release(lc($s{provider_label})) if $s{provider_label};
        my $code = $sse_err->{code} // '';
        my $msg = $sse_err->{message} // '';
        # Default to retryable - upstream errors usually resolve themselves.
        # Explicit non-retryable set is reserved for client-side errors (4xx-class)
        # that we explicitly identify here.
        my $is_retryable = 1;
        my $error_type = 'server_error';
        my $retry_after = 5;
        if ($code =~ /rate.?lim/i || $msg =~ /rate.?lim/i || $msg =~ /ResourceExhausted|Worker.*limit|quota|too many requests/i) {
            $error_type = 'rate_limit';
            $retry_after = 30;  # Longer wait for rate limits - 30s gives the provider time to recover
            # Teach the throttle to learn this model's limit so future requests are paced
            $self->report_rate_limit_for_model($s{model});
        } elsif ($code =~ /timeout/i) {
            $error_type = 'timeout';
        } elsif ($code =~ /overload|busy|throttle/i) {
            $error_type = 'overloaded';
            # Overloaded errors often signal we're pushing the provider too hard.
            # Teach the throttle so future requests proactively slow down.
            $self->report_rate_limit_for_model($s{model});
        } elsif ($code =~ /auth|forbidden|unauthor/i) {
            $is_retryable = 0;
            $error_type = 'auth_error';
        } elsif ($code =~ /invalid|bad.?request/i) {
            $is_retryable = 0;
            $error_type = 'bad_request';
        } elsif ($code =~ /^5\d{2}$/) {
            # Generic 5xx in SSE stream - likely upstream capacity issue.
            # Trigger throttle learning so the next request is paced.
            $self->report_rate_limit_for_model($s{model});
        }
        return {
            success => 0,
            error => "SSE error from provider: " . ($sse_err->{message} // 'unknown') . " (code=$code)",
            retryable => $is_retryable,
            retry_after => $is_retryable ? $retry_after : 0,
            error_type => $error_type,
        };
    }

    # Detect truncated stream: content/tool_calls were streamed but no
    # finish_reason was ever captured. The OpenAI Chat Completions spec
    # requires `choices[].finish_reason` on the final delta, so its absence
    # means the connection died (or was closed) before the provider could
    # emit the stop marker. Without this guard the finalizer returns
    # success with the partial response, and the orchestrator treats the
    # truncated text as a final answer - the agent then "just stops"
    # mid-workflow, exactly the MiniMax silent-stop bug 62f7976 attempted
    # to fix for the SSE-error case but only addressed when the provider
    # also emitted an explicit `data: {"error":...}` chunk. MiniMax and
    # other OpenAI-compat providers frequently drop the connection
    # without sending an error chunk at all.
    #
    # Only fire when we have something to lose (content or tool_calls
    # accumulated) - a stream that produced nothing yet has no
    # `finish_reason` is still treated as a no-op by the orchestrator's
    # premature-stop heuristic, which has the right context to decide
    # whether to nudge the model.
    if (!$s{_finish_reason}
        && (length($s{accumulated_content}) || keys(%{$s{tool_calls_accumulator}}))) {
        my $content_len = length($s{accumulated_content} // '');
        my $tc_count    = scalar keys %{$s{tool_calls_accumulator}};
        log_warning('APIManager',
            "Truncated stream detected: no finish_reason, content=$content_len chars, "
            . "tool_calls=$tc_count - surfacing as retryable");
        $self->{response_handler}->release_broker_slot($resp, 200);
        $self->{rate_limiter}->release(lc($s{provider_label})) if $s{provider_label};
        return {
            success     => 0,
            error       => "Stream truncated: provider ended response without finish_reason "
                         . "(content=$content_len chars, tool_calls=$tc_count). "
                         . "The connection dropped before the model could complete its turn.",
            retryable   => 1,
            retry_after => 5,
            error_type  => 'truncated',
        };
    }

    # Handle HTTP error responses based on status code
    if ($is_error) {
        # Pass streaming headers to error handler for rate limit header parsing
        return $self->_handle_streaming_http_error($resp, \%s);
    }

    # Check for API errors returned as HTTP 200 with error body (Google/OpenRouter)
    my $body_error = $self->_check_200_body_error($resp, \%s);
    return $body_error if $body_error;

    # Calculate final metrics
    my $duration = time() - $s{start_time};
    my $ttft = $s{first_token_time} ? ($s{first_token_time} - $s{start_time}) : undef;
    my $tps = ($duration > 0 && $s{token_count} > 0) ? ($s{token_count} / $duration) : 0;

    log_debug('APIManager', sprintf("Streaming complete - TTFT: %.2fs, TPS: %.1f, Tokens: %d, Duration: %.2fs",
        $ttft // 0, $tps, $s{token_count}, $duration));

    # Persist session for response_id continuity
    if ($self->{session} && $self->{session}{lastGitHubCopilotResponseId}) {
        if (ref($self->{session}) && blessed($self->{session}) && $self->{session}->can('save')) {
            $self->{session}->save();
        }
    }

    # Process rate limit and quota headers
    my $headers = $s{streaming_headers} || $resp->headers;
    my $rate_limit_info = $self->{response_handler}->process_rate_limit_headers($headers) if $headers;
    if (ref($rate_limit_info) eq 'HASH' && ref($rate_limit_info->{rate_limit_info}) eq 'HASH' && $s{model}) {
        $self->_apply_anthropic_rate_limit_headers($s{model}, $rate_limit_info->{rate_limit_info});
    }

    if ($s{endpoint_config}{requires_copilot_headers} && $headers) {
        my $response_id = $self->{session}{lastGitHubCopilotResponseId} || 'unknown';
        $self->{response_handler}->process_quota_headers($headers, $response_id);
    }

    # Parse copilot_usage from streaming response body (June 2026+ AI Credit billing)
    if ($s{endpoint_config}{requires_copilot_headers} && $s{copilot_usage}) {
        $self->_process_copilot_usage($s{copilot_usage}, $s{model});
    }

    # Resolve or estimate usage for billing
    my $usage = $self->_resolve_streaming_usage(\%s);

    # Record actual input-token usage against the sliding window so the
    # preflight throttle sees accurate numbers on the next request. Per
    # Anthropic docs the ITPM bucket only sees uncached input tokens
    # (input_tokens + cache_creation_input_tokens) - cache reads do NOT
    # count. Native providers may report cache_creation_input_tokens in
    # the SSE usage event; OpenAI-compatible providers (including some
    # Anthropic proxies) may surface it via streaming_usage. Sum them
    # so any source gets credit for the ITPM-relevant portion of input.
    if ($s{model} && $usage && ($usage->{prompt_tokens} || $usage->{cache_creation_input_tokens})) {
        my $recorded = ($usage->{prompt_tokens}                // 0)
                     + ($usage->{cache_creation_input_tokens} // 0);
        $self->_model_input_token_throttle_record($s{model}, $recorded) if $recorded > 0;
        # Report to broker so its cross-agent ITPM sliding window sees
        # this request. Fire-and-forget so a slow broker can't stall the
        # agent. Broker only does ITPM coordination when broker_client is
        # present (sub-agents), but the call is safe for the parent too
        # - the broker ignores reports that don't match a known agent.
        if ($self->{broker_client} && $recorded > 0) {
            eval {
                local $SIG{PIPE} = 'IGNORE';
                $self->{broker_client}->report_api_tokens(
                    model                        => $s{model},
                    input_tokens                 => ($usage->{prompt_tokens}                  // 0),
                    cache_creation_input_tokens  => ($usage->{cache_creation_input_tokens}   // 0),
                );
            };
        }
    }

    # Convert accumulated tool_calls hash to sorted array
    my $tool_calls;
    if (keys %{$s{tool_calls_accumulator}}) {
        $tool_calls = [ map { $s{tool_calls_accumulator}{$_} }
                        sort { $a <=> $b } keys %{$s{tool_calls_accumulator}} ];
        log_debug('APIManager', "Accumulated " . scalar(@$tool_calls) . " tool calls");
    }

    # Build response
    my $response = {
        success => 1,
        content => $s{accumulated_content},
        metrics => { ttft => $ttft, tps => $tps, tokens => $s{token_count}, duration => $duration },
        usage   => $usage,
    };

    $response->{tool_calls} = $tool_calls if $tool_calls;

    if (length($s{accumulated_reasoning} // '')) {
        $response->{reasoning_details} = [{ type => 'reasoning.text', text => $s{accumulated_reasoning} }];
        # Also set reasoning_content for DeepSeek API compatibility
        # Also set reasoning_content (DeepSeek API format)
        $response->{reasoning_content} = $s{accumulated_reasoning};
        # Also pass accumulated_reasoning as a string for easier downstream handling
        # (ConversationManager and other consumers can use whichever format they prefer)
        $response->{accumulated_reasoning} = $s{accumulated_reasoning};
    }

    # Persist captured Responses API reasoning items (with encrypted_content
    # + phase) so they can be round-tripped on the next turn. The caller
    # should attach this to the assistant message and pass it back through
    # _build_responses_api_payload on the following request.
    if ($s{_reasoning_items} && ref($s{_reasoning_items}) eq 'ARRAY' && @{$s{_reasoning_items}}) {
        $response->{responses_reasoning_items} = $s{_reasoning_items};
    }

    $self->_log_streaming_response($response, $s{provider_label}, $tool_calls);
    $self->{response_handler}->release_broker_slot($resp, 200);
    
    # Update rate limit state and release slot (use lowercase for consistency with acquire)
    my $rl_headers = $s{streaming_headers};
    unless (defined $rl_headers) {
        $rl_headers = $resp->headers if $resp->can('headers');
    }
    my $rate_limiter_provider = lc($s{provider_label});
    $self->{rate_limiter}->update_from_headers($rate_limiter_provider, $rl_headers) if $rl_headers;
    $self->{rate_limiter}->release($rate_limiter_provider);

    return $response;
}

=head2 _handle_streaming_http_error($resp, $s)

Handle HTTP error responses from streaming requests.

=cut

sub _handle_streaming_http_error {
    my ($self, $resp, $s) = @_;

    $self->{response_handler}->release_broker_slot($resp, $resp->code);
    
    # Release rate limiter slot on error
    $self->{rate_limiter}->release(lc($s->{provider_label}));

    # For streaming errors, the body may be in accumulated_content (captured by SSE callback)
    # or in raw_response_body/buffer (raw HTTP response)
    my $body = $resp->decoded_content;
    $body = $s->{accumulated_content} unless $body && $body =~ /\S/;
    $body = $s->{raw_response_body} unless $body && $body =~ /\S/;
    $body = $s->{buffer} unless $body && $body =~ /\S/;
    $body //= '';

    log_debug('APIManager', "[$s->{provider_label} STREAMING ERROR] " . $resp->status_line .
        " Body: " . substr($body, 0, 500));

    # Ensure body is available for error handler
    if ($body && $body =~ /\S/ && (!$resp->decoded_content || $resp->decoded_content !~ /\S/)) {
        $resp->{content} = $body;
    }

    # Use streaming headers if available (passed from _finalize_streaming_response).
    # Belt-and-suspenders: also fall back to the real response headers when the
    # captured streaming_headers has no fields (curl streaming stub fallback).
    my $headers = $s->{streaming_headers};
    my $headers_empty = 0;
    if ($headers && ref($headers) && $headers->can('header_field_names')) {
        $headers_empty = 1 unless scalar($headers->header_field_names());
    }
    if (!$headers || $headers_empty) {
        my $fallback = $resp->can('headers') ? $resp->headers : undef;
        log_debug('APIManager', "Using real response headers (streaming_headers was " .
            (!$headers ? 'undef' : 'empty') . ")") if $fallback;
        $headers = $fallback if $fallback;
    }

    # Debug: log ALL headers from the response to see what's actually available
    if ($headers && ref($headers) && $headers->can('header')) {
        my @header_names = $headers->header_field_names();
        if (@header_names) {
            my $all_headers_str = join(", ", map { "$_=" . (defined($headers->header($_)) ? "'" . $headers->header($_) . "'" : 'undef') } @header_names);
            log_debug('APIManager', "All response headers (${\scalar(@header_names)}): $all_headers_str");
        } else {
            log_debug('APIManager', "Headers object exists but has NO fields - headers hash dump:");
            # Dump the internal hash directly to see what it actually contains
            if (ref($headers) eq 'CLIO::Compat::HTTP::Headers') {
                my %h = %{$headers->{headers}} if ref($headers->{headers}) eq 'HASH';
                while (my ($k, $v) = each %h) {
                    log_debug('APIManager', "  header[$k] = $v");
                }
            }
        }
    } else {
        log_debug('APIManager', "Headers object: " . (defined($headers) ? (ref($headers) || $headers) : 'undef'));
    }
    
    # Also check what streaming_headers contains
    if ($s->{streaming_headers}) {
        log_debug('APIManager', "streaming_headers ref: " . ref($s->{streaming_headers}));
    } else {
        log_debug('APIManager', "streaming_headers is undef");
    }

    log_debug('APIManager', "handle_error_response returned, sending to error handler");
    my $error_result = eval {
        $self->{response_handler}->handle_error_response($resp, $s->{json}, 1,
            attempt_token_recovery => sub { $self->_attempt_token_recovery() },
            headers => $headers);
    };
    if ($@) {
        log_error('APIManager', "_handle_streaming_http_error: handle_error_response threw: $@");
        warn "_handle_streaming_http_error EXCEPTION: $@\n";  # Force to stderr
        $error_result = { success => 0, error => "Error handler exception: $@", retryable => 0 };
    }
    return $error_result;
}

=head2 _check_200_body_error($resp, $s)

Check for API errors returned as HTTP 200 with error body (Google/OpenRouter).
Returns error hashref if found, undef otherwise.

=cut

sub _check_200_body_error {
    my ($self, $resp, $s) = @_;

    # Only ignore the body-level error if the response is legitimately
    # complete. If the provider sent content/tool_calls but never emitted a
    # finish_reason (e.g. MiniMax truncation case) the error structure in the
    # body IS the truncation - return it so the orchestrator can retry.
    # finish_reason was captured in _process_chat_completions_delta and
    # _process_responses_api_event during streaming.
    return undef if $s->{_finish_reason}
        && ($s->{accumulated_content} || keys(%{$s->{tool_calls_accumulator}}));

    my $body = $s->{raw_response_body} || $s->{buffer} || '';
    $body =~ s/^\s+|\s+$//g;
    return undef unless $body;

    my ($error_msg, $error_code);

    # Provider error bodies sometimes arrive as SSE-framed JSON:
    #   data: {"error":{"message":"...","code":"..."}}\n\n
    # (NVIDIA NIM wraps non-streaming errors in SSE framing even when
    # Content-Type is text/event-stream). Try plain JSON first (Google/OpenRouter),
    # then strip SSE framing and retry.
    my $parsed;
    my @candidates = ($body);
    if ($body =~ /\Adata:|\n\n/m || $body =~ /\Aevent:/) {
        my $clean = $body;
        $clean =~ s/^data:\s*//mg;
        $clean =~ s/^event:\s*\S+\s*$//mg;
        $clean =~ s/\s+\z//;
        push @candidates, $clean if $clean ne $body && length($clean);
    }
    for my $candidate (@candidates) {
        my $p = eval { decode_json($candidate) };
        if (ref($p) eq 'HASH' || (ref($p) eq 'ARRAY' && @$p)) {
            $parsed = $p;
            last;
        }
    }
    return undef unless $parsed;

    my $err = (ref($parsed) eq 'ARRAY' && @$parsed) ? $parsed->[0]{error}
            : (ref($parsed) eq 'HASH')              ? $parsed->{error}
            : undef;
    if ($err) {
        $error_msg  = ref($err) eq 'HASH' ? $err->{message} : $err;
        $error_code = ref($err) eq 'HASH' ? $err->{code}    : undef;
    }
    return undef unless $error_msg;

    log_debug('APIManager', "Error in 200 body: $error_msg");
    $self->{response_handler}->release_broker_slot($resp, 200);

    if ($error_code && $error_code =~ /rate.lim/i) {
        log_info('APIManager', "Rate limit in 200 body (code=$error_code), treating as 429");
        $self->{response_handler}{rate_limit_until} = time() + 60;
        return { success => 0, error => $error_msg, retryable => 1, retry_after => 60, error_type => 'rate_limit' };
    }

    return { success => 0, error => $error_msg, retryable => 0 };
}

=head2 _resolve_streaming_usage($s)

Resolve real streaming usage or estimate from accumulated data.

=cut

sub _resolve_streaming_usage {
    my ($self, $s) = @_;

    if ($s->{streaming_usage}) {
        log_debug('APIManager', "Real usage: prompt=$s->{streaming_usage}{prompt_tokens}, completion=$s->{streaming_usage}{completion_tokens}");
        $self->_learn_from_api_response($s->{streaming_usage}, $s->{messages}, $s->{opts}{tools});
        return $s->{streaming_usage};
    }

    my $prompt_tokens = 0;
    if ($s->{messages} && ref($s->{messages}) eq 'ARRAY') {
        $prompt_tokens += int(length($_->{content} || '') / 4) for @{$s->{messages}};
    } elsif ($s->{input}) {
        $prompt_tokens = int(length($s->{input}) / 4);
    }

    log_debug('APIManager', "Estimated usage: prompt~$prompt_tokens, completion~$s->{token_count}");
    return {
        prompt_tokens     => $prompt_tokens,
        completion_tokens => $s->{token_count},
        total_tokens      => $prompt_tokens + $s->{token_count},
    };
}

=head2 _log_streaming_response($response, $provider_label, $tool_calls)

Log streaming response details at debug level.

=cut

sub _log_streaming_response {
    my ($self, $response, $label, $tool_calls) = @_;

    log_debug('APIManager', "[$label COMPLETE] content=" . length($response->{content}) .
        " tool_calls=" . ($tool_calls ? scalar(@$tool_calls) : 0));

    if ($self->{debug} && $tool_calls) {
        for my $tc (@$tool_calls) {
            log_debug('APIManager', "  tool: " . ($tc->{function}{name} || '?') .
                " args=" . length($tc->{function}{arguments} || '') . "b");
        }
    }
}

# Async API methods
sub send_request_async {
    my ($self, $input) = @_;
    
    # Prevent multiple concurrent requests
    if (($self->{request_state} // 0) == REQUEST_PENDING) {
        log_debug('APIManager', "Request already pending");
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
        log_error('APIManager', "Request failed: $@");
        return 0;
    }
    
    # Process completed successfully
    if ($response && $response->{content}) {
        $self->{response} = $response;
        $self->{request_state} = REQUEST_COMPLETE;
        log_debug('APIManager', "Request completed with response");
        return 1;
    }
    
    # No valid response
    $self->{error} = "Invalid response format";
    $self->{request_state} = REQUEST_ERROR;
    log_error('APIManager', "Invalid response format");
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
        log_debug('APIManager', sprintf("Request complete: State=%s%s",
            $self->{request_state},
            $self->{error} ? " Error=$self->{error}" : ""
        ));
    }
}

=head2 _extract_stateful_markers($data, $opts)

Extract and store stateful_marker / response_id from the decoded API response
for GitHub Copilot billing session continuity.

=cut

sub _extract_stateful_markers {
    my ($self, $data, $opts) = @_;

    my $model = $self->{model} || '';
    my $iteration = ($opts && $opts->{tool_call_iteration}) || 1;

    # Top-level stateful_marker
    if ($data->{stateful_marker}) {
        $self->{response_handler}->store_stateful_marker($data->{stateful_marker}, $model, $iteration);
    }

    # stateful_marker inside message (SAM approach)
    if ($data->{choices} && @{$data->{choices}} &&
        $data->{choices}[0]{message} &&
        $data->{choices}[0]{message}{stateful_marker}) {
        $self->{response_handler}->store_stateful_marker(
            $data->{choices}[0]{message}{stateful_marker}, $model, $iteration);
    }

    # Fallback: store response id (guard log behind debug check)
    if ($data->{id} && $self->{session}) {
        $self->{session}{lastGitHubCopilotResponseId} = $data->{id};
        if (should_log('DEBUG')) {
            log_debug('APIManager', "Stored response_id fallback: " . substr($data->{id}, 0, 30) . "...");
        }
    }
}

=head2 _extract_response_content($data, $use_responses_api, $opts)

Extract message content, tool_calls, reasoning_details, and Responses API
reasoning items from a decoded API response hash. Handles Responses API,
Chat Completions, text completion, direct content, message array, and
nested response formats.

Returns: ($content, $tool_calls_aref_or_undef, $reasoning_details_aref_or_undef, $responses_reasoning_items_aref_or_undef)
  - $content                          : extracted text
  - $tool_calls                       : arrayref of tool calls (Chat Completions shape)
  - $reasoning_details                : arrayref of OpenRouter/MiniMax reasoning_details
  - $responses_reasoning_items        : arrayref of Responses API reasoning items with
                                        encrypted_content + phase for round-trip

=cut

sub _extract_response_content {
    my ($self, $data, $use_responses_api, $opts) = @_;

    my $content = '';
    my $tool_calls = undef;
    my $reasoning_details = undef;
    my $responses_reasoning_items = undef;

    return ($content, $tool_calls, $reasoning_details, $responses_reasoning_items) unless ref $data eq 'HASH';

    # Responses API format (codex models, etc.)
    if ($use_responses_api && $data->{output} && ref($data->{output}) eq 'ARRAY') {
        log_debug('APIManager', "Parsing Responses API format (output items: " . scalar(@{$data->{output}}) . ")");

        my @text_parts;
        my @resp_tool_calls;
        my @reasoning_items;

        for my $item (@{$data->{output}}) {
            my $type = $item->{type} || '';

            if ($type eq 'message' && $item->{content} && ref($item->{content}) eq 'ARRAY') {
                for my $part (@{$item->{content}}) {
                    push @text_parts, $part->{text}
                        if ($part->{type} || '') eq 'output_text' && defined $part->{text};
                }
            }
            elsif ($type eq 'function_call') {
                my $func_args = $item->{arguments} // '{}';
                $func_args = safe_encode_json($func_args, '{}') if ref($func_args);
                push @resp_tool_calls, {
                    id   => $item->{call_id} || '',
                    type => 'function',
                    function => {
                        name      => $item->{name}      || '',
                        arguments => $func_args,
                    },
                };
            }
            elsif ($type eq 'reasoning') {
                # Per Responses API docs, the model emits reasoning items that
                # may carry encrypted_content (opaque blob representing the
                # model's internal state). When include: ['reasoning.encrypted_content']
                # is set, this is populated and MUST be sent back on the next
                # turn to preserve reasoning continuity. The phase field
                # distinguishes 'commentary' from 'final_answer' parts.
                if (defined $item->{encrypted_content} && length $item->{encrypted_content}) {
                    push @reasoning_items, {
                        type              => 'reasoning',
                        id                => $item->{id},
                        encrypted_content => $item->{encrypted_content},
                        summary           => $item->{summary} || [],
                        phase             => $item->{phase} // 'commentary',
                    };
                }
            }
        }

        $content    = join('', @text_parts)    if @text_parts;
        $tool_calls = \@resp_tool_calls        if @resp_tool_calls;
        my $resp_reasoning_items = \@reasoning_items if @reasoning_items;

        # Store response.id as stateful marker for billing continuity
        if ($data->{id} && $self->{session}) {
            my $iteration = ($opts && $opts->{tool_call_iteration}) || 1;
            $self->{response_handler}->store_stateful_marker($data->{id}, $self->{model} || '', $iteration);
            $self->{session}{lastGitHubCopilotResponseId} = $data->{id};
        }

        log_debug('APIManager', "Responses API: content=" . length($content) . " chars, tool_calls=" . scalar(@{$tool_calls || []}) . ", reasoning_items=" . scalar(@{$resp_reasoning_items || []}));

        return ($content, $tool_calls, undef, $resp_reasoning_items);
    }
    # Chat Completions format
    elsif ($data->{choices} && @{$data->{choices}} && $data->{choices}[0]{message}) {
        my $message = $data->{choices}[0]{message};
        $content = $message->{content};

        if ($message->{tool_calls} && ref($message->{tool_calls}) eq 'ARRAY') {
            $tool_calls = $message->{tool_calls};
            # Normalize tool call IDs and arguments format
            for my $tc (@$tool_calls) {
                if ($tc->{id} && $tc->{id} =~ /^function-call-(\d+)$/) {
                    $tc->{id} = 'call_' . substr($1, -24);
                }
                # Some servers (e.g., llama.cpp) send arguments as a parsed
                # object instead of a JSON string - re-encode if needed
                if ($tc->{function} && ref($tc->{function}{arguments})) {
                    $tc->{function}{arguments} = safe_encode_json($tc->{function}{arguments}, '{}');
                }
            }
        }

        if ($message->{reasoning_details} && ref($message->{reasoning_details}) eq 'ARRAY') {
            $reasoning_details = $message->{reasoning_details};
            log_debug('APIManager', "Extracted " . scalar(@$reasoning_details) . " reasoning_details");
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
    # Message array format
    elsif ($data->{messages} && @{$data->{messages}}) {
        $content = $data->{messages}[-1]{content};
    }
    # Nested response format
    elsif ($data->{response} && $data->{response}{content}) {
        $content = $data->{response}{content};
    }

    return ($content, $tool_calls, $reasoning_details, $responses_reasoning_items);
}

=head2 _extract_usage_tokens($data, $use_responses_api)

Extract input/output token counts from a decoded API response.
Handles both Chat Completions (prompt_tokens/completion_tokens) and
Responses API (input_tokens/output_tokens) formats.

Returns: ($tokens_in, $tokens_out)

=cut

sub _extract_usage_tokens {
    my ($self, $data, $use_responses_api) = @_;

    return (0, 0) unless $data->{usage};

    if ($use_responses_api) {
        return (
            $data->{usage}{input_tokens}  || 0,
            $data->{usage}{output_tokens} || 0,
        );
    }

    return (
        $data->{usage}{prompt_tokens}     || $data->{usage}{input_tokens}  || 0,
        $data->{usage}{completion_tokens} || $data->{usage}{output_tokens} || 0,
    );
}

=head2 _process_copilot_usage

Process copilot_usage from GitHub Copilot response body.
As of June 2026, GitHub Copilot returns per-token billing data in the
response body via the copilot_usage field, replacing the legacy
premium request unit (PRU) quota headers.

Arguments:
- $copilot_usage: Hashref from response body {token_details => [...], total_nano_aiu => int}
- $model: Model identifier string

=cut

sub _process_copilot_usage {
    my ($self, $copilot_usage, $model) = @_;

    return unless $copilot_usage && ref($copilot_usage) eq 'HASH';

    my $total_nano_aiu = $copilot_usage->{total_nano_aiu} || 0;
    my $token_details  = $copilot_usage->{token_details} || [];

    # Convert nano AI units to AI credits and USD
    # 1 nano AIU = 10^-9 AI credits, 1 AI credit = $0.01 USD
    my $ai_credits = $total_nano_aiu / 1_000_000_000.0;
    my $cost_usd   = $ai_credits * 0.01;

    # Parse token details
    my %token_info;
    for my $detail (@$token_details) {
        my $token_type  = $detail->{token_type} || 'unknown';
        my $token_count = $detail->{token_count} || 0;
        my $batch_size  = $detail->{batch_size} || 0;
        my $cost_per_batch = $detail->{cost_per_batch} || 0;

        $token_info{$token_type} = {
            count         => $token_count,
            batch_size    => $batch_size,
            cost_per_batch => $cost_per_batch,
        };

        # Calculate price per million tokens in USD
        if ($batch_size > 0 && $cost_per_batch > 0) {
            my $price_per_m = ($cost_per_batch / 1_000_000_000.0) * 0.01 * (1_000_000.0 / $batch_size);
            $token_info{$token_type}{price_per_m_usd} = $price_per_m;
        }
    }

    my $state = $self->{session}->can('state') ? $self->{session}->state() : $self->{session};

    return unless $state && ref($state);

    # Store in session billing
    if ($state->{billing}) {
        $state->{billing}{copilot_usage} = {
            total_nano_aiu => $total_nano_aiu,
            ai_credits     => $ai_credits,
            cost_usd       => $cost_usd,
            token_details  => \%token_info,
            model          => $model,
            timestamp      => time(),
        };

        # Accumulate session totals
        $state->{billing}{total_ai_credits} //= 0;
        $state->{billing}{total_ai_credits} += $ai_credits;

        $state->{billing}{total_cost_usd} //= 0;
        $state->{billing}{total_cost_usd} += $cost_usd;
    }

    # Log the usage
    my $input_tokens  = $token_info{input}{count}  || 0;
    my $output_tokens = $token_info{output}{count} || 0;
    my $cached_tokens = $token_info{cache_read}{count} || 0;

    log_info('APIManager', sprintf("Copilot AI Credits [%.6f credits, \$%.6f]: %d in, %d out, %d cached",
        $ai_credits, $cost_usd, $input_tokens, $output_tokens, $cached_tokens));

    # Persist session
    if (blessed($state) && $state->can('save')) {
        $state->save();
    }
}

sub _error {
    my ($self, $msg) = @_;
    log_error('APIManager', $msg);
    return { error => 1, message => $msg };
}

=head2 _endpoint_supports_thinking()

Check if the current provider endpoint supports thinking/reasoning natively.
Used to decide whether to pass a `thinking` option to the provider's
build_request. Returns true for native providers (Anthropic, Google) that
have first-class thinking support, and for endpoints with the
`supports_reasoning` flag.

=cut

sub _endpoint_supports_thinking {
    my ($self) = @_;

    # The provider lives on the config object, not on $self. Reading
    # $self->{provider} always returned empty and disabled thinking
    # entirely; reading through config matches every other provider
    # check in this file.
    my $provider_name = $self->{config} ? ($self->{config}->get('provider') // '') : '';

    # Resolve via provider registry. Anthropic, Google, MiniMax, Z.AI,
    # NVIDIA, OpenAI, DeepSeek, GitHub Copilot, OpenRouter - all declare
    # supports_reasoning in Providers.pm when they have any thinking
    # capability. This includes native-API providers (Anthropic, Google,
    # NVIDIA) and OpenAI-compat providers. Adding a new provider with
    # thinking support is a one-flag edit in Providers.pm; no change
    # needed here.
    if ($provider_name) {
        my $provider_config = get_provider($provider_name);
        return 1 if $provider_config && $provider_config->{supports_reasoning};
    }

    # Fall back to endpoint config if available.
    if ($self->{_current_endpoint_config} && $self->{_current_endpoint_config}{supports_reasoning}) {
        return 1;
    }

    return 0;
}

=head2 _get_native_provider($target_provider)

Check if the provider uses a native (non-OpenAI-compatible) API
and return the provider handler instance if so.

Arguments:
  $target_provider - Provider name to use (from _prepare_endpoint_config).
                     Falls back to config provider, then $self->{provider}.

Returns: Provider instance if native, undef if OpenAI-compatible

=cut

sub _get_native_provider {
    my ($self, $target_provider) = @_;

    # Determine which provider to check. Priority:
    # 1. $target_provider from _prepare_endpoint_config (cross-provider routing)
    # 2. Config provider
    # 3. $self->{provider} from sub-agents
    my $provider_name = $target_provider;
    $provider_name //= $self->{config} ? $self->{config}->get('provider') : undef;
    $provider_name //= $self->{provider};
    my $provider_config = get_provider($provider_name);
    
    return undef unless $provider_config;
    return undef unless $provider_config->{native_api};
    
    log_debug('APIManager', "_get_native_provider: provider=$provider_name, native_api=1");
    
    my $module = $provider_config->{provider_module};
    return undef unless $module;
    
    # Load and instantiate the provider module
    eval { (my $f = "$module.pm") =~ s{::}{/}g; require $f };
    if ($@) {
        log_error('APIManager', "Failed to load native provider $module: $@");
        return undef;
    }
    
    # Use the target provider's default api_base when doing cross-provider routing,
    # otherwise fall back to the user-configured api_base (which may differ from
    # the provider default, e.g., for proxies).
    my $effective_api_base;
    if ($target_provider) {
        # Cross-provider routing: use the target provider's default base,
        # but allow user overrides via per-provider stored base.
        my $stored_base = $self->{config} ? $self->{config}->get_provider_base($target_provider) : undef;
        $effective_api_base = $stored_base // $provider_config->{api_base};
    } else {
        $effective_api_base = $self->{api_base} // $provider_config->{api_base};
    }
    
    # Build custom headers from endpoint config (e.g., Anthropic's anthropic-version)
    my %custom_headers;
    if ($provider_config->{endpoint} && $provider_config->{endpoint}{extra_headers}) {
        %custom_headers = %{$provider_config->{endpoint}{extra_headers}};
    }
    
    log_debug('APIManager', "Creating native provider $module with custom_headers: " . encode_json(\%custom_headers));
    
    # Resolve API key for the native provider. When routing cross-provider
    # (e.g., using a NVIDIA model while the main provider is GitHub Copilot),
    # $self->{api_key} contains the main provider's key, not the target's.
    # Load the target provider's key from config.
    my $native_api_key = $self->{api_key};
    if ($target_provider && $self->{config}) {
        my $target_key = $self->{config}->get_provider_key($target_provider);
        $native_api_key = $target_key if $target_key;
    }
    
    my $provider = $module->new(
        api_key => $native_api_key,
        api_base => $effective_api_base,
        model => $self->get_current_model(),
        debug => $self->{debug},
        custom_headers => \%custom_headers,
    );
    
    log_debug('APIManager', "Using native provider: $module");
    
    return $provider;
}

=head2 _send_native_streaming($provider, $messages, $tools, %opts)

Send a streaming request using a native provider implementation.

Arguments:
- $provider: Native provider instance (e.g., CLIO::Providers::Google)
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

    # Hoist thinking_effort to outer scope so the self-correcting retry
    # block (inside the 400 error handler, ~150 lines below) can use it.

    # Hoist thinking_mode (auto|enabled|disabled). Resolved once so both
    # the initial send and the self-correcting retry use the same value.
    my $thinking_mode = $self->{config} ? ($self->{config}->get('thinking_mode') // 'auto') : 'auto';
    my $effort = $self->{config} ? ($self->{config}->get('thinking_effort') // 'medium') : 'medium';

    # Build thinking config for providers that support it. The harness
    # knows the user's preference (show_thinking, thinking_effort) and the
    # endpoint config (which provider we're talking to). The provider's
    # build_request translates this into the native format.
    my $thinking_opt;
    if ($self->_endpoint_supports_thinking()) {
        # If a previous request flagged that reasoning/thinking is not supported
        # by this model, don't send thinking params again.
        my $reasoning_blocked = $self->{response_handler} && $self->{response_handler}{_no_reasoning};
        my $show_thinking = $self->{config} ? $self->{config}->get('show_thinking') : 0;
        my $full_model_for_caps = $opts{model} // $self->{model} // $self->get_current_model();
        my $provider_supports = $self->_model_supports_reasoning($full_model_for_caps);
        my $caps = $full_model_for_caps ? $self->get_model_capabilities($full_model_for_caps) : undef;
        my $requires_adaptive = ($caps && $caps->{requires_adaptive_thinking}) ? 1 : 0;
        # Fallback when MCM has no data (no API key, network failure, brand
        # new model not yet in the cache). Match the well-known families
        # that REQUIRE adaptive - this is the safety net for the Fable 5 /
        # Mythos 5 / Mythos Preview case where the API rejects
        # {type:"disabled"} with HTTP 400. Detection is model-name based,
        # not provider-name based: the Anthropic family naming tokens
        # (fable/mythos) are unique enough to Anthropic that a regex
        # against the model name catches both native Anthropic and any
        # Anthropic-compatible proxy (Azure Foundry, internal deployments)
        # that registers under a different provider name.
        if (!$requires_adaptive && defined $full_model_for_caps) {
            my $bare = $full_model_for_caps;
            $bare =~ s{^[^/]+/}{};  # Strip provider/ prefix if present.
            $requires_adaptive = 1 if $bare =~ /-(?:fable|mythos)-5(?:-|$|\b)/i;
            $requires_adaptive = 1 if $bare =~ /^claude-mythos-preview(?:-|$|\b)/i;
        }

        # Three-way decision via thinking_mode (default: auto).
        # auto:     Anthropic -> send adaptive (recommended by Anthropic;
        #           happens regardless of show_thinking - the model decides
        #           whether to actually think). Other providers: gate on
        #           show_thinking to preserve current behavior.
        # enabled:  Force thinking ON. Uses the model's native mode
        #           (adaptive for current Anthropic, enabled for legacy).
        # disabled: Omit thinking. Overridden to adaptive with a warning
        #           for models that REQUIRE adaptive (Fable 5, Mythos 5,
        #           Mythos Preview) because the API rejects
        #           {type:"disabled"} on those with HTTP 400.
        if ($reasoning_blocked) {
            # Model rejected reasoning params on a previous request - disable.
            $thinking_opt = { enabled => 0 };
        }
        elsif ($thinking_mode eq 'disabled') {
            if ($requires_adaptive) {
                # Override: this model rejects {type:"disabled"} with HTTP 400.
                log_warning('APIManager', "thinking_mode=disabled ignored for $full_model_for_caps: model requires adaptive thinking (API rejects {type:disabled})");
                $thinking_opt = {
                    enabled => 1,
                    effort  => $effort,
                    mode    => 'adaptive',
                };
            }
            else {
                $thinking_opt = { enabled => 0 };
            }
        }
        elsif ($thinking_mode eq 'enabled' && $provider_supports) {
            my $reasoning_mode = $full_model_for_caps ? $self->_get_reasoning_mode($full_model_for_caps) : undef;
            $thinking_opt = {
                enabled => 1,
                effort  => $effort,
                ($reasoning_mode ? (mode => $reasoning_mode) : ()),
            };
        }
        elsif ($thinking_mode eq 'auto') {
            my $provider_name = $self->{provider} // '';
            if ($provider_name eq 'anthropic' && $provider_supports) {
                $thinking_opt = {
                    enabled => 1,
                    effort  => $effort,
                    mode    => 'adaptive',
                };
            }
            elsif ($show_thinking && $provider_supports) {
                my $reasoning_mode = $full_model_for_caps ? $self->_get_reasoning_mode($full_model_for_caps) : undef;
                $thinking_opt = {
                    enabled => 1,
                    effort  => $effort,
                    ($reasoning_mode ? (mode => $reasoning_mode) : ()),
                };
            }
            elsif (!$show_thinking) {
                $thinking_opt = { enabled => 0 };
            }
        }
        # When show_thinking is on but model doesn't support reasoning,
        # don't pass any thinking option (provider will skip it).
    }

    # Build the request using the native provider
    # Use get_current_model() for full model ID with prefix (required by native providers like NVIDIA)
    my $full_model = $self->get_current_model();
    # Only pass temperature when explicitly set; native providers already
    # gate on `defined $options->{temperature}` and will omit it otherwise.
    my %build_opts = (
        model => $full_model,
        max_tokens => $opts{max_tokens} // $self->_get_max_output_tokens($full_model),
        ($thinking_opt ? (thinking => $thinking_opt) : ()),
    );
    $build_opts{temperature} = $opts{temperature} if defined $opts{temperature};
    my $request = $provider->build_request($messages, $tools, \%build_opts);
    
    # Initialize tracking
    my $start_time = time();
    my $first_token_time;
    my $accumulated_content = '';
    my @tool_calls;
    my $current_tool_call;
    my $token_count = 0;
    my $buffer = '';
    my %usage_tracking = (
        input_tokens                => 0,
        output_tokens               => 0,
        cache_creation_input_tokens => 0,
    );

    # State hash for native streaming (mirrors $ss in OpenAI-compatible path)
    # Allows stashing SSE errors for proper handling after streaming completes
    my %ns = (
        _sse_error => undef,
        model => $full_model,
    );
    
    # Create HTTP client
    my $ua = $self->_get_shared_http_client(
        timeout => 300,
        agent => 'CLIO/1.0',
        ssl_opts => { verify_hostname => 1 },
    );
    
    log_debug('APIManager', "Native request to: $request->{url}");
    
    # Make streaming request using curl-based streaming (no HTTP::Request dependency)
    my $response;
    eval {
        $response = $ua->_request_via_curl_streaming(
            $request->{method},
            $request->{url},
            $request->{headers},
            $request->{body},
            sub {
                my ($chunk, $resp, $proto) = @_;
                
                $buffer .= $chunk;
            
            # Normalize CRLF to LF for providers that use \r\n line endings
            $buffer =~ s/\r\n/\n/g;
            
            # Process complete SSE events
            while ($buffer =~ s/^(.*?)\n//s) {
                # Check for user interrupt after each SSE event.
                # Uses the same two-tier check as send_request_streaming:
                # pending() fast path (ALRM handler set the flag), then
                # check() with a non-blocking ReadKey for active detection.
                if (eval { CLIO::Core::Interrupt::pending(session => $self->{session}) }
                    || eval { CLIO::Core::Interrupt::check(session => $self->{session}) }) {
                    log_info('APIManager', "Interrupt detected in native SSE stream, aborting");
                    last;
                }
                my $event = $provider->parse_stream_event($1);
                next unless $event;

                my $type = $event->{type};
                if ($type eq 'text') {
                    $first_token_time //= time();
                    $token_count++;
                    $accumulated_content .= $event->{content};
                    $on_chunk->($event->{content}) if $on_chunk;
                }
                elsif ($type =~ /^thinking/) {
                    if ($on_thinking) {
                        $type eq 'thinking'         ? $on_thinking->($event->{content})
                      : $type eq 'thinking_start'   ? $on_thinking->(undef, 'start')
                      : $type eq 'thinking_end'     ? $on_thinking->(undef, 'end')
                      : $type eq 'thinking_redacted' ? $on_thinking->(undef, 'redacted')
                      :                               $on_thinking->(undef, 'end');
                    }
                }
                elsif ($type eq 'tool_start') {
                    $current_tool_call = { id => $event->{id}, type => 'function',
                        function => { name => $event->{name}, arguments => '' } };
                }
                elsif ($type eq 'tool_args' && $current_tool_call) {
                    $current_tool_call->{function}{arguments} .= $event->{content};
                    # NVIDIA sends finish_reason alongside the last tool_calls delta.
                    # The provider sets also_tool_end to signal that this event
                    # completes the tool call - finalize it immediately.
                    if ($event->{also_tool_end}) {
                        push @tool_calls, $current_tool_call;
                        $on_tool_call->($current_tool_call->{function}{name}) if $on_tool_call;
                        $current_tool_call = undef;
                    }
                }
                elsif ($type eq 'tool_end') {
                    # Google sends complete tool calls as single tool_end (no prior tool_start)
                    if (!$current_tool_call && $event->{name}) {
                        $current_tool_call = { id => $event->{id}, type => 'function',
                            function => { name => $event->{name}, arguments => '' } };
                    }
                    if ($current_tool_call) {
                        $current_tool_call->{function}{arguments} = encode_json($event->{arguments})
                            if $event->{arguments};
                        push @tool_calls, $current_tool_call;
                        $on_tool_call->($current_tool_call->{function}{name}) if $on_tool_call;
                        $current_tool_call = undef;
                    }
                }
                elsif ($type eq 'error') {
                    # Stash SSE error instead of croaking - the eval wrapper
                    # around curl streaming will catch and log it, but we need
                    # to surface it properly via _finalize_streaming_response
                    $ns{_sse_error} = {
                        code    => $event->{code} // $event->{type} // 'overloaded',
                        message => $event->{message} // 'Overloaded',
                    };
                    return;  # No content/tool_calls to extract from this chunk
                }
                elsif ($type eq 'usage') {
                    # Track token usage from native providers (Anthropic, Google)
                    $usage_tracking{input_tokens} += ($event->{input_tokens} // 0);
                    $usage_tracking{output_tokens} += ($event->{output_tokens} // 0);
                    # Anthropic ITPM counts cache_creation_input_tokens as uncached
                    # input. Track it separately so the ITPM record below can
                    # include it. Cache reads are not counted toward ITPM and
                    # don't need to be tracked here.
                    $usage_tracking{cache_creation_input_tokens} += ($event->{cache_creation_input_tokens} // 0);
                }
            }
        });
    };

    # Check for user interrupt during native streaming. The curl streaming
    # loop in CLIO::Compat::HTTP kills the curl process and breaks when
    # Interrupt::pending() is true (set by the ALRM handler). Detect it
    # here and return an interrupted result instead of treating the
    # killed-process response as an HTTP error.
    if (eval { CLIO::Core::Interrupt::pending(session => $self->{session}) }) {
        log_info('APIManager', "Native streaming interrupted by user (ESC)");
        my $native_provider_label = undef;
        if ($self->{_current_endpoint_config}) {
            $native_provider_label = $self->{_current_endpoint_config}{requires_copilot_headers} ? 'GitHub Copilot'
                            : $self->{_current_endpoint_config}{google} ? 'Google'
                            : $self->{_current_endpoint_config}{anthropic} ? 'Anthropic'
                            : $self->{_current_endpoint_config}{nvidia} ? 'NVIDIA'
                            : 'API';
        }
        my $np = $native_provider_label ? lc($native_provider_label) : 'unknown';
        $self->{rate_limiter}->release($np) if $self->{rate_limiter};
        if ($self->{response_handler}) {
            $self->{response_handler}->release_broker_slot($response, 200);
        }
        # Do NOT clear the interrupt flag here - let the orchestrator
        # detect it via Interrupt::pending() and handle it.
        return {
            success => 0,
            error => 'Interrupted by user',
            interrupted => 1,
            retryable => 0,
            error_type => 'user_interrupt',
            content => $accumulated_content,
            ( @tool_calls ? (tool_calls => \@tool_calls) : () ),
        };
    }
    
    if ($@) {
        log_error('APIManager', "Native streaming failed: $@");
        return { success => 0, error => $@ };
    }

    # Check for stashed SSE error (mirrors _finalize_streaming_response pattern)
    if ($ns{_sse_error}) {
        my $sse_err = $ns{_sse_error};
        log_debug('APIManager', "Native streaming SSE error: code=$sse_err->{code} msg=$sse_err->{message}");
        # Teach the throttle the same way the OpenAI-compatible path does.
        # Without this, native providers (Anthropic, Google, NVIDIA-native) miss
        # out on proactive pacing after capacity errors.
        my $error_type = ($sse_err->{code} =~ /rate.?lim/i || $sse_err->{message} =~ /rate.?lim|ResourceExhausted|Worker.*limit|quota|too many requests/i) ? 'rate_limit'
                         : ($sse_err->{code} =~ /overload|busy|throttle/i || $sse_err->{message} =~ /overload|busy|throttle/i) ? 'overloaded'
                         : 'server_error';
        $self->report_rate_limit_for_model($ns{model}) if $error_type eq 'rate_limit'
                                                       || $error_type eq 'overloaded'
                                                       || ($sse_err->{code} =~ /^5\d{2}$/);
        return {
            success => 0,
            error => "SSE error from provider: " . ($sse_err->{message} // 'unknown') . " (code=$sse_err->{code})",
            retryable => 1,
            retry_after => 30,
            error_type => $error_type,
        };
    }

    if (!$response->is_success) {
        my $status = $response->code;
        my $error_body = $response->decoded_content // '';
        log_error('APIManager', "Native API error $status: $error_body");

        # Parse the JSON error body to extract structured error info.
        # Without this, 429 responses from Anthropic proxies return a bare
        # "HTTP 429" string with no error_type or retry_after, causing
        # ResponseHandler to treat them as generic server errors (max 3 retries,
        # 2s delay) instead of rate limits (infinite retries, proper backoff).
        my $result = { success => 0, error => "HTTP $status", retryable => ($status == 429 || $status >= 500) };

        if ($status == 429) {
           $result->{error_type} = 'rate_limit';
           # Try to extract retry_after from the error body.
           # Anthropic proxy format: {"error": {"code": "RateLimitReached", "message": "Please wait 38 seconds..."}}
           my $error_obj = safe_decode_json($error_body);
           if ($@ || ref($error_obj) ne 'HASH') {
               $error_obj = undef;
           }
           my $err_msg = '';
           if ($error_obj) {
               # Navigate to the error message (various formats)
               if (ref($error_obj->{error}) eq 'HASH') {
                   $err_msg = $error_obj->{error}{message} // '';
               } else {
                   $err_msg = ($error_obj->{error} // '') . ($error_obj->{message} // '');
               }
           }
            # Check Retry-After header first (authoritative for Azure APIM proxies),
            # then fall back to body text extraction.
            my $resp_headers = $response->can("headers") ? $response->headers : undef;
            my $header_retry;
            if (ref($resp_headers) eq 'HASH') {
                $header_retry = $resp_headers->{'retry-after'};
            } elsif ($resp_headers && $resp_headers->can("header")) {
                $header_retry = $resp_headers->header("Retry-After");
            }
            if ($header_retry && $header_retry =~ /^([\d.]+)$/) {
                $result->{retry_after} = int($1) + 1;
            }
            # Fall back to body text if header didn't provide retry_after
            elsif ($err_msg =~ /(?:please\s+wait|retry\s+in)\s+([\d.]+)\s*s(?:econds?)?/i) {
                $result->{retry_after} = int($1) + 1;
            }
            # Also check Retry-After header via response object (fallback)
            elsif (my $retry_after_header = $response->header('Retry-After')) {
                $result->{retry_after} = int($retry_after_header) + 1;
            }
            else {
                $result->{retry_after} = 60;  # Default backoff
            }
            # Process rate limit headers from 429 responses too
            if ($self->{response_handler} && $resp_headers) {
                my $rate_limit_info = $self->{response_handler}->process_rate_limit_headers($resp_headers);
                # Anthropic 429 surfaces the most-correct ITPM/OTPM/RPM
                # numbers we will see. Seed the throttle snapshot AND the
                # learned limit so future requests throttle proactively.
                if (ref($rate_limit_info) eq 'HASH' && ref($rate_limit_info->{rate_limit_info}) eq 'HASH') {
                    $self->_apply_anthropic_rate_limit_headers($ns{model}, $rate_limit_info->{rate_limit_info});
                }
                # Also report as a rate-limit event so request-count
                # learning still kicks in for proxies that hide the
                # anthropic-ratelimit-* headers.
                $self->report_rate_limit_for_model($ns{model});
            }
        }
        elsif ($status == 400) {
            # Parse 400 errors for structured error info
            my $error_obj = safe_decode_json($error_body);
            if ($@ || ref($error_obj) ne 'HASH') {
                $error_obj = undef;
            }
            my $err_msg = '';
            if ($error_obj) {
                if (ref($error_obj->{error}) eq 'HASH') {
                    $err_msg = $error_obj->{error}{message} // '';
                } else {
                    $err_msg = ($error_obj->{error} // '') . ($error_obj->{message} // '');
                }
            }
            # Use the full error message for better diagnostics
            $result->{error} = $err_msg || "HTTP 400";

            # Check if ResponseHandler detected a self-describing
            # mode-mismatch error and stashed the correct mode. If so,
            # this is NOT a hard failure - we can retry immediately with
            # the corrected mode AND persist the learning so future
            # requests for this model get it right the first time.
            #
            # The API itself tells us the right mode in its error
            # message (e.g. "Use thinking.type.adaptive"). This is
            # naming-convention agnostic: works for any current or
            # future Anthropic model - we never look at the name,
            if ($self->{response_handler} && $self->{response_handler}{_correct_reasoning_mode}) {
                my $correct_mode = delete $self->{response_handler}{_correct_reasoning_mode};
                my $full_model = $opts{model} // $self->{model} // $self->get_current_model();
                my ($provider_name, $api_model) = $self->_parse_model_provider($full_model);
                $provider_name //= ($self->{config} ? ($self->{config}->get('provider') || '') : '');

                # Persist the learning to MCM cache so subsequent
                # requests don't have to repeat the failed round-trip.
                # This is the "self-correcting" part - once learned,
                # always learned (until cache TTL expires).
                if ($provider_name && $api_model) {
                    eval {
                        require CLIO::Core::ModelCapabilitiesManager;
                        my $mcm = CLIO::Core::ModelCapabilitiesManager->new(debug => $self->{debug});
                        $mcm->set_reasoning_mode($provider_name, $api_model, $correct_mode);
                    };
                    if ($@) {
                        log_warning('APIManager', "Failed to persist learned reasoning_mode: $@");
                    }
                }

                # Also clear APIManager's per-request capability cache
                # for this model so the next lookup re-reads from MCM
                # and gets the corrected mode immediately.
                delete $self->{_model_capabilities_cache}{$full_model};

                log_info('APIManager', "Self-correcting retry with reasoning_mode=$correct_mode for $full_model");

                # Rebuild the request with the corrected mode.
                my $thinking_opt_corrected = {
                    enabled => 1,
                    effort  => $effort,
                    mode    => $correct_mode,
                };
                my %build_opts_retry = (
                    model      => $full_model,
                    max_tokens => $opts{max_tokens} // $self->_get_max_output_tokens($full_model),
                    thinking   => $thinking_opt_corrected,
                );
                $build_opts_retry{temperature} = $opts{temperature} if defined $opts{temperature};
                my $request_retry = $provider->build_request($messages, $tools, \%build_opts_retry);

                # Track second attempt metrics
                my $retry_start_time = time();
                my $retry_first_token_time;
                my $retry_accumulated_content = '';
                my @retry_tool_calls;
                my $retry_current_tool_call;
                my $retry_token_count = 0;
                my $retry_buffer = '';
                my %retry_usage_tracking = (
                        input_tokens                => 0,
                        output_tokens               => 0,
                        cache_creation_input_tokens => 0,
                    );

                my $retry_response;
                eval {
                    $retry_response = $ua->_request_via_curl_streaming(
                        $request_retry->{method},
                        $request_retry->{url},
                        $request_retry->{headers},
                        $request_retry->{body},
                        sub {
                            my ($chunk, $resp, $proto) = @_;

                            $retry_buffer .= $chunk;
                            $retry_buffer =~ s/\r\n/\n/g;

                            while ($retry_buffer =~ s/^(.*?)\n//s) {
                                my $event = $provider->parse_stream_event($1);
                                next unless $event;

                                my $type = $event->{type};
                                if ($type eq 'text') {
                                    $retry_first_token_time //= time();
                                    $retry_token_count++;
                                    $retry_accumulated_content .= $event->{content};
                                    $on_chunk->($event->{content}) if $on_chunk;
                                }
                                elsif ($type =~ /^thinking/) {
                                    if ($on_thinking) {
                                        $type eq 'thinking'         ? $on_thinking->($event->{content})
                                      : $type eq 'thinking_start'   ? $on_thinking->(undef, 'start')
                                      : $type eq 'thinking_end'     ? $on_thinking->(undef, 'end')
                                      : $type eq 'thinking_redacted' ? $on_thinking->(undef, 'redacted')
                                      :                               $on_thinking->(undef, 'end');
                                    }
                                }
                                elsif ($type eq 'tool_start') {
                                    $retry_current_tool_call = { id => $event->{id}, type => 'function',
                                        function => { name => $event->{name}, arguments => '' } };
                                }
                                elsif ($type eq 'tool_args' && $retry_current_tool_call) {
                                    $retry_current_tool_call->{function}{arguments} .= $event->{content};
                                }
                                elsif ($type eq 'tool_end') {
                                    if (!$retry_current_tool_call && $event->{name}) {
                                        $retry_current_tool_call = { id => $event->{id}, type => 'function',
                                            function => { name => $event->{name}, arguments => '' } };
                                    }
                                    if ($retry_current_tool_call) {
                                        $retry_current_tool_call->{function}{arguments} = encode_json($event->{arguments})
                                            if $event->{arguments};
                                        push @retry_tool_calls, $retry_current_tool_call;
                                        $on_tool_call->($retry_current_tool_call->{function}{name}) if $on_tool_call;
                                        $retry_current_tool_call = undef;
                                    }
                                }
                                elsif ($type eq 'error') {
                                    # Stash SSE error instead of croaking - same pattern as initial request
                                    $ns{_sse_error} = {
                                        code    => $event->{code} // $event->{type} // 'overloaded',
                                        message => $event->{message} // 'Overloaded',
                                    };
                                    return;  # No content/tool_calls to extract from this chunk
                                }
                                elsif ($type eq 'usage') {
                                    $retry_usage_tracking{input_tokens} += ($event->{input_tokens} // 0);
                                    $retry_usage_tracking{output_tokens} += ($event->{output_tokens} // 0);
                                    $retry_usage_tracking{cache_creation_input_tokens} += ($event->{cache_creation_input_tokens} // 0);
                                }
                            }
                        });
                };

                if ($@) {
                    log_error('APIManager', "Self-correcting retry failed: $@");
                    return { success => 0, error => "Self-correcting retry failed: $@", retryable => 0 };
                }

                if (!$retry_response->is_success) {
                    my $retry_status = $retry_response->code;
                    my $retry_error_body = $retry_response->decoded_content // '';
                    log_error('APIManager', "Self-correcting retry still failed: HTTP $retry_status: $retry_error_body");
                    # Surface the original 400 error so the user knows
                    # what happened, plus a note about the retry.
                    return {
                        success => 0,
                        error => "$result->{error} (self-correcting retry with mode=$correct_mode also failed: HTTP $retry_status)",
                        retryable => ($retry_status == 429 || $retry_status >= 500),
                    };
                }

                # Retry succeeded - emit results as if the original request
                # worked, with usage/metrics tracked from the retry.
                my $retry_duration = time() - $retry_start_time;
                my $retry_result = {
                    success => 1,
                    content => $retry_accumulated_content,
                    metrics => {
                        ttft => ($retry_first_token_time ? $retry_first_token_time - $retry_start_time : $retry_duration),
                        tps => ($retry_duration > 0 ? $retry_token_count / $retry_duration : 0),
                        tokens => $retry_token_count,
                        duration => $retry_duration,
                    },
                    usage => {
                        prompt_tokens                => $retry_usage_tracking{input_tokens} || 0,
                        completion_tokens             => $retry_usage_tracking{output_tokens} || $retry_token_count,
                        cache_creation_input_tokens   => $retry_usage_tracking{cache_creation_input_tokens} || 0,
                        total_tokens                  => ($retry_usage_tracking{input_tokens} || 0) + ($retry_usage_tracking{output_tokens} || $retry_token_count),
                    },
                    finish_reason => (@retry_tool_calls ? 'tool_calls' : 'stop'),
                    _self_corrected_mode => $correct_mode,  # marker for callers/debugging
                };
                $retry_result->{tool_calls} = \@retry_tool_calls if @retry_tool_calls;

                # Capture thinking blocks from retry
                if ($provider->can('get_thinking_blocks')) {
                    my $blocks = $provider->get_thinking_blocks();
                    if ($blocks && ref($blocks) eq 'ARRAY' && @$blocks) {
                        $retry_result->{reasoning_blocks} = $blocks;
                    }
                    $provider->clear_thinking_blocks() if $provider->can('clear_thinking_blocks');
                }

                return $retry_result;
            }
        }

        return $result;
   }

    # Process rate limit headers on successful responses too (proactive token quota tracking)
    if ($self->{response_handler}) {
        my $resp_headers = $response->can("headers") ? $response->headers : undef;
        my $rate_limit_info = $self->{response_handler}->process_rate_limit_headers($resp_headers) if $resp_headers;
        if (ref($rate_limit_info) eq 'HASH' && ref($rate_limit_info->{rate_limit_info}) eq 'HASH') {
            $self->_apply_anthropic_rate_limit_headers($ns{model}, $rate_limit_info->{rate_limit_info});
        }
    }

    # Record this turn's real input tokens against the sliding window so
    # next request's preflight throttle sees accurate numbers. Without
    # this the window stays empty and we only ever learn from 429 events.
    # Per Anthropic docs, ITPM counts (input_tokens + cache_creation_input_tokens).
    # Cache reads do NOT count, so we don't include them. Without adding
    # cache_creation, the first request of a session (or any request after
    # cache TTL expiry) under-counts its real ITPM consumption by the size
    # of the cached prefix (system prompt + tools, often 30-80K tokens).
    if ($ns{model}) {
        my $recorded_input = ($usage_tracking{input_tokens}                // 0)
                           + ($usage_tracking{cache_creation_input_tokens} // 0);
        $self->_model_input_token_throttle_record($ns{model}, $recorded_input) if $recorded_input > 0;
        # Report to broker (sub-agent case) so cross-agent ITPM tracking
        # sees this request's contribution. Fire-and-forget.
        if ($self->{broker_client} && $recorded_input > 0) {
            eval {
                local $SIG{PIPE} = 'IGNORE';
                $self->{broker_client}->report_api_tokens(
                    model                        => $ns{model},
                    input_tokens                 => ($usage_tracking{input_tokens}                // 0),
                    cache_creation_input_tokens  => ($usage_tracking{cache_creation_input_tokens} // 0),
                );
            };
        }
    }

    # Anthropic may emit stop_reason + usage in a single message_delta event.
    # parse_stream_event only returns one event per call, so the usage is
    # stashed on the provider. Recover it here for accurate billing.
    if ($provider->can('get_final_usage')) {
        my $final_usage = $provider->get_final_usage();
        if ($final_usage && $final_usage->{output_tokens}) {
            if (!$usage_tracking{output_tokens} || $usage_tracking{output_tokens} < $final_usage->{output_tokens}) {
                $usage_tracking{output_tokens} = $final_usage->{output_tokens};
                log_debug('APIManager', sprintf("Recovered final usage from provider: %d output tokens", $final_usage->{output_tokens}));
            }
        }
    }

    # Check for stashed SSE error (mirrors _finalize_streaming_response pattern)
    if ($ns{_sse_error}) {
        my $sse_err = $ns{_sse_error};
        log_debug('APIManager', "Native streaming SSE error: code=$sse_err->{code} msg=$sse_err->{message}");
        # Teach the throttle the same way the OpenAI-compatible path does.
        # Self-correcting retry path - same throttle learning logic.
        my $error_type = ($sse_err->{code} =~ /rate.?lim/i || $sse_err->{message} =~ /rate.?lim|ResourceExhausted|Worker.*limit|quota|too many requests/i) ? 'rate_limit'
                         : ($sse_err->{code} =~ /overload|busy|throttle/i || $sse_err->{message} =~ /overload|busy|throttle/i) ? 'overloaded'
                         : 'server_error';
        $self->report_rate_limit_for_model($ns{model}) if $error_type eq 'rate_limit'
                                                       || $error_type eq 'overloaded'
                                                       || ($sse_err->{code} =~ /^5\d{2}$/);
        return {
            success => 0,
            error => "SSE error from provider: " . ($sse_err->{message} // 'unknown') . " (code=$sse_err->{code})",
            retryable => 1,
            retry_after => 30,
            error_type => $error_type,
        };
    }

    # Build result
    my $duration = time() - $start_time;
    my $result = {
        success => 1, content => $accumulated_content,
        metrics => { ttft => ($first_token_time ? $first_token_time - $start_time : $duration),
                     tps => ($duration > 0 ? $token_count / $duration : 0),
                     tokens => $token_count, duration => $duration },
        usage => {
            prompt_tokens                => $usage_tracking{input_tokens} || 0,
            completion_tokens              => $usage_tracking{output_tokens} || $token_count,
            cache_creation_input_tokens    => $usage_tracking{cache_creation_input_tokens} || 0,
            total_tokens                   => ($usage_tracking{input_tokens} || 0) + ($usage_tracking{output_tokens} || $token_count),
        },
        finish_reason => (@tool_calls ? 'tool_calls' : 'stop'),
    };
    $result->{tool_calls} = \@tool_calls if @tool_calls;

    # Capture thinking blocks (with signature / redacted_thinking / thoughtSignature)
    # from the provider so the caller can persist them to the assistant message
    # for multi-turn round-trip.
    if ($provider->can('get_thinking_blocks')) {
        my $blocks = $provider->get_thinking_blocks();
        if ($blocks && ref($blocks) eq 'ARRAY' && @$blocks) {
            $result->{reasoning_blocks} = $blocks;
        }
        $provider->clear_thinking_blocks() if $provider->can('clear_thinking_blocks');
    }

    return $result;
}

1;
