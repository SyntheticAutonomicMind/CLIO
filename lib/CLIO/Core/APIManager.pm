
package CLIO::Core::APIManager;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use CLIO::Providers qw(get_provider list_providers);
use POSIX ":sys_wait_h"; # For WNOHANG
use Time::HiRes qw(time sleep);  # High resolution time and sleep
use JSON::PP;
use CLIO::Compat::HTTP;
BEGIN { require CLIO::Compat::HTTP; CLIO::Compat::HTTP->import(); }
use CLIO::Core::PerformanceMonitor;
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

# --- SSL CA bundle setup (before any LWP or HTTPS modules are loaded) ---
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
            warn "[WARN]No CA bundle found in common locations. HTTPS requests may fail.\n";
        }
    }
}

# No external dependencies, only core Perl

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
        die "[FATAL] APIManager requires Config object\n";
    }
    
    # Get settings from Config (NOT from ENV vars)
    my $api_base = $config->get('api_base');
    my $model = $config->get('model');
    
    # Validate the URL format
    unless ($api_base && $api_base =~ m{^https?://}) {
        die "[FATAL] Invalid API base URL from config: " . ($api_base || '(not set)') . " (must start with http:// or https://)\n";
    }
    
    # Print debug info
    if ($args{debug}) {
        print STDERR "[DEBUG][APIManager] Initializing:\n";
        print STDERR "[DEBUG][APIManager]   api_base: $api_base\n";
        print STDERR "[DEBUG][APIManager]   model: $model\n";
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
        performance_monitor => CLIO::Core::PerformanceMonitor->new(debug => $args{debug} // 0),
        %args,
    };
    bless $self, $class;
    
    # Initialize API key (check GitHub auth first, then config)

    $self->{api_key} = $self->_get_api_key();
    
    return $self;
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
        };
        
        if ($@) {
            print STDERR "[WARN]APIManager] Failed to get GitHub token: $@\n" if should_log('WARNING');
            return '';
        }
        
        if ($github_token) {
            print STDERR "[INFO][APIManager] Using GitHub Copilot/GitHub token\n" if should_log('INFO');
            return $github_token;
        }
        
        # GitHub Copilot provider requires GitHub authentication
        print STDERR "[WARN]APIManager] GitHub Copilot not authenticated\n" if should_log('WARNING');
        return '';
    }
    
    # Priority 2: Config api_key (for non-GitHub Copilot providers)
    if ($self->{config} && $self->{config}->can('get')) {
        my $key = $self->{config}->get('api_key');
        if ($key && length($key) > 0) {
            print STDERR "[DEBUG][APIManager] Using API key from Config\n" if should_log('DEBUG');
            return $key;
        }
    }
    
    # No API key available
    print STDERR "[WARN]APIManager] No API key available (not set in config)\n" if should_log('WARNING');
    return '';
}

# Get current model - reads from Config (PUBLIC method)
sub get_current_model {
    my ($self) = @_;
    
    # Config is the authority
    if ($self->{config} && $self->{config}->can('get')) {
        my $model = $self->{config}->get('model');
        if ($model) {
            print STDERR "[DEBUG][APIManager] Using model from Config: $model\n" if should_log('DEBUG');
            return $model;
        }
    }
    
    # Fallback (should never happen if config is properly initialized)
    print STDERR "[WARN]APIManager] No model in config, using default\n" if should_log('WARNING');
    return 'gpt-4';
}

# Get current provider - reads from Config (PUBLIC method)
sub get_current_provider {
    my ($self) = @_;
    
    # Config is the authority
    if ($self->{config} && $self->{config}->can('get')) {
        my $provider = $self->{config}->get('provider');
        if ($provider) {
            print STDERR "[DEBUG][APIManager] Using provider from Config: $provider\n" if should_log('DEBUG');
            return $provider;
        }
    }
    
    # Fallback
    print STDERR "[WARN]APIManager] No provider in config, using default\n" if should_log('WARNING');
    return 'openai';
}

# Endpoint-specific configuration
sub get_endpoint_config {
    my ($self) = @_;
    
    # Get provider name from config
    my $provider_name = $self->{config}->get('provider') || 'openai';
    
    # Endpoint-specific configurations
    my %endpoint_configs = (
        'openai' => {
            auth_header => 'Authorization',
            auth_value => "Bearer $self->{api_key}",
            path_suffix => '/chat/completions',
            temperature_range => [0.0, 2.0],
            supports_tools => 1
        },
        'github_copilot' => {
            auth_header => 'Authorization',
            auth_value => "Bearer $self->{api_key}",
            path_suffix => '',  # Endpoint selected dynamically based on model
            temperature_range => [0.0, 1.0],
            supports_tools => 1,
            requires_copilot_headers => 1
        },
        'dashscope-cn' => {
            auth_header => 'Authorization',
            auth_value => "Bearer $self->{api_key}",
            path_suffix => '/chat/completions',
            temperature_range => [0.0, 2.0],
            supports_tools => 1
        },
        'qwen' => {
            auth_header => 'Authorization',
            auth_value => "Bearer $self->{api_key}",
            path_suffix => '/chat/completions',
            temperature_range => [0.0, 2.0],
            supports_tools => 1
        },
        'dashscope-intl' => {
            auth_header => 'Authorization',
            auth_value => "Bearer $self->{api_key}",
            path_suffix => '/chat/completions',
            temperature_range => [0.0, 2.0],
            supports_tools => 1
        },
        'sam' => {
            auth_header => 'Authorization',
            auth_value => "Bearer $self->{api_key}",
            path_suffix => '',  # Path already included in endpoint URL
            temperature_range => [0.0, 2.0],
            supports_tools => 1,
            requires_sam_config => 1
        },
        'claude' => {
            auth_header => 'Authorization',
            auth_value => "Bearer $self->{api_key}",
            path_suffix => '/messages',
            temperature_range => [0.0, 1.0],
            supports_tools => 1
        },
        'deepseek' => {
            auth_header => 'Authorization',
            auth_value => "Bearer $self->{api_key}",
            path_suffix => '/chat/completions',
            temperature_range => [0.0, 2.0],
            supports_tools => 1
        },
        'ollama' => {
            auth_header => 'Authorization',
            auth_value => "Bearer $self->{api_key}",
            path_suffix => '',  # Path already in URL
            temperature_range => [0.0, 2.0],
            supports_tools => 0
        },
    );
    
    # Return config for current provider, or generic config
    return $endpoint_configs{$provider_name} || {
        auth_header => 'Authorization',
        auth_value => "Bearer $self->{api_key}",
        path_suffix => '/chat/completions',
        temperature_range => [0.0, 2.0],
        supports_tools => 1
    };
}

# Validate and adapt request parameters for specific endpoints
sub adapt_request_for_endpoint {
    my ($self, $payload, $endpoint_config) = @_;
    
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
        warn "[DEBUG] Removed tools for endpoint that doesn't support them\n" if $self->{debug};
    }
    
    # Add SAM config if required (for bypass_processing support)
    if ($endpoint_config->{requires_sam_config}) {
        $payload->{sam_config} = {
            bypass_processing => \1,  # JSON true via scalar reference
        };
        print STDERR "[DEBUG][APIManager] Added sam_config with bypass_processing=true\n" if $self->{debug};
    }
    
    return $payload;
}

=head2 get_model_capabilities

Get model capabilities (token limits) from the models API.
Caches result to avoid repeated API calls.

Returns:
- Hashref with: max_prompt_tokens, max_output_tokens, max_context_window_tokens
- Returns undef if unable to fetch or model not found

=cut

sub get_model_capabilities {
    my ($self, $model) = @_;
    
    $model ||= $self->get_current_model();
    
    # Check cache first (cache in object for session lifetime)
    if ($self->{_model_capabilities_cache} && 
        $self->{_model_capabilities_cache}{$model}) {
        return $self->{_model_capabilities_cache}{$model};
    }
    
    # Detect API type and models endpoint
    my $api_base = $self->{api_base};
    my ($api_type, $models_url) = $self->_detect_api_type_and_url($api_base);
    
    unless ($models_url) {
        warn "[DEBUG][APIManager] Unable to determine models endpoint for: $api_base\n" if $self->{debug};
        return undef;
    }
    
    # Fetch models
    my $ua = CLIO::Compat::HTTP->new(timeout => 30);
    my %headers = (
        'Authorization' => "Bearer $self->{api_key}",
    );
    $headers{'Editor-Version'} = 'CLIO/1.0' if $api_type eq 'github-copilot';
    
    my $resp = $ua->get($models_url, headers => \%headers);
    
    unless ($resp->is_success) {
        warn "[DEBUG][APIManager] Failed to fetch models: " . $resp->code . " " . $resp->message . "\n" if $self->{debug};
        return undef;
    }
    
    my $data = eval { JSON::PP::decode_json($resp->decoded_content) };
    if ($@) {
        warn "[DEBUG][APIManager] Failed to parse models response: $@\n" if $self->{debug};
        return undef;
    }
    
    my $models = $data->{data} || [];
    
    # Find our model
    for my $model_info (@$models) {
        if ($model_info->{id} eq $model) {
            my $limits = {};
            
            # Extract limits from capabilities (GitHub Copilot format)
            if ($model_info->{capabilities} && $model_info->{capabilities}{limits}) {
                $limits = $model_info->{capabilities}{limits};
            }
            
            # Build normalized capabilities hash
            # Priority: root-level fields (SAM/OpenAI), then capabilities.limits (GitHub Copilot), then defaults
            my $capabilities = {
                max_prompt_tokens => $model_info->{max_request_tokens} ||
                                     $limits->{max_prompt_tokens} ||
                                     $limits->{max_context_window_tokens} ||
                                     $model_info->{context_window} ||
                                     128000,  # Default fallback
                max_output_tokens => $model_info->{max_completion_tokens} ||
                                     $limits->{max_output_tokens} ||
                                     $limits->{max_completion_tokens} ||
                                     4096,  # Default fallback
                max_context_window_tokens => $model_info->{context_window} ||
                                              $limits->{max_context_window_tokens} ||
                                              $limits->{context_window} ||
                                              128000,
            };
            
            # Cache the result
            $self->{_model_capabilities_cache} ||= {};
            $self->{_model_capabilities_cache}{$model} = $capabilities;
            
            print STDERR "[DEBUG][APIManager] Model capabilities for $model: " .
                "max_prompt=" . $capabilities->{max_prompt_tokens} . ", " .
                "max_output=" . $capabilities->{max_output_tokens} . "\n"
                if $self->{debug};
            
            return $capabilities;
        }
    }
    
    warn "[DEBUG][APIManager] Model $model not found in API response\n" if $self->{debug};
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
    } elsif ($api_base =~ m{localhost:8080}i || $api_base =~ m{127\.0\.0\.1:8080}i) {
        # SAM running locally
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

Validate message token count against model limits and truncate if necessary.
Estimates tokens using character count / 4 (rough approximation).

Arguments:
- $messages: Arrayref of message objects
- $model: Model name (optional, uses $self->{model} if not provided)

Returns:
- Arrayref of messages (possibly truncated)
- Logs warnings if truncation occurs

=cut

sub validate_and_truncate_messages {
    my ($self, $messages, $model) = @_;
    
    $model ||= $self->get_current_model();
    
    # Get model capabilities
    my $caps = $self->get_model_capabilities($model);
    
    unless ($caps) {
        # Can't validate without capabilities - return as-is
        return $messages;
    }
    
    my $max_prompt = $caps->{max_prompt_tokens};
    
    # Estimate current token count
    my $estimated_tokens = 0;
    for my $msg (@$messages) {
        if ($msg->{content}) {
            $estimated_tokens += int(length($msg->{content}) / 4);
        }
    }
    
    if ($estimated_tokens <= $max_prompt) {
        # Within limits - return as-is
        print STDERR "[DEBUG][APIManager] Token validation: $estimated_tokens / $max_prompt tokens (OK)\n"
            if $self->{debug};
        return $messages;
    }
    
    # Exceeds limit - need to truncate
    warn "[WARNING][APIManager] Message exceeds token limit: $estimated_tokens > $max_prompt tokens\n";
    warn "[WARNING][APIManager] Truncating oldest messages to fit within limit\n";
    
    # Strategy: Keep system message (if first), then truncate from oldest user messages
    my @truncated = ();
    my $current_tokens = 0;
    
    # Always keep system message if it's first
    if (@$messages && $messages->[0]{role} eq 'system') {
        my $sys_tokens = int(length($messages->[0]{content}) / 4);
        push @truncated, $messages->[0];
        $current_tokens += $sys_tokens;
    }
    
    # Add messages from newest to oldest until we hit the limit
    my @remaining = @$messages;
    shift @remaining if (@truncated);  # Remove system message if we added it
    
    for my $msg (reverse @remaining) {
        my $msg_tokens = int(length($msg->{content} || '') / 4);
        
        if ($current_tokens + $msg_tokens <= $max_prompt) {
            unshift @truncated, $msg;
            $current_tokens += $msg_tokens;
        } else {
            # Hit the limit - stop adding
            last;
        }
    }
    
    my $final_tokens = 0;
    for my $msg (@truncated) {
        $final_tokens += int(length($msg->{content} || '') / 4);
    }
    
    warn "[WARNING][APIManager] Truncated from " . scalar(@$messages) . " to " . scalar(@truncated) . " messages\n";
    warn "[WARNING][APIManager] Final token count: $final_tokens / $max_prompt\n";
    
    return \@truncated;
}

# Helper: Prepare endpoint configuration and model
sub _prepare_endpoint_config {
    my ($self, %opts) = @_;
    
    my $endpoint_config = $self->get_endpoint_config();
    my $endpoint = $self->{api_base};
    my $model = $opts{model} // $self->get_current_model();
    
    return {
        config => $endpoint_config,
        endpoint => $endpoint,
        model => $model,
    };
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
    
    # Build base payload
    my $payload = {
        model => $model,
        messages => $messages,
        temperature => $opts{temperature} // 0.2,
        top_p => $opts{top_p} // 0.95,
    };
    
    # Add stream flag if streaming
    if ($stream) {
        $payload->{stream} = \1;  # JSON true
    }
    
    # Save currently used model to session for persistence
    if ($self->{session} && (!$self->{session}{selected_model} || $self->{session}{selected_model} ne $model)) {
        $self->{session}{selected_model} = $model;
        print STDERR "[DEBUG][APIManager] Saving model to session: $model\n" if should_log('DEBUG');
    }
    
    # Add copilot_thread_id for session continuity (GitHub Copilot requirement)
    if ($self->{session} && $self->{session}{session_id}) {
        $payload->{copilot_thread_id} = $self->{session}{session_id};
        print STDERR "[DEBUG][APIManager] Including copilot_thread_id: $payload->{copilot_thread_id}\n" if should_log('DEBUG');
    } else {
        print STDERR "[WARNING][APIManager] NO copilot_thread_id - session will be treated as NEW (charges premium quota!)\n" if should_log('WARNING');
        print STDERR "[DEBUG][APIManager] session=" . (defined $self->{session} ? "defined" : "undef") . 
                     ", session_id=" . (defined $self->{session}{session_id} ? $self->{session}{session_id} : "undef") . "\n" if should_log('DEBUG');
    }
    
    # Add previous_response_id for GitHub Copilot billing continuity
    # CRITICAL: Use stateful_marker (not response 'id'!) for session continuation
    # This is the CORRECT implementation per VS Code Copilot Chat and SAM reference code
    # Using stateful_marker prevents duplicate premium charges for:
    #   - Continued conversations
    #   - Tool-calling iterations
    #   - Follow-up questions in same session
    my $previous_response_id = $self->_get_stateful_marker_for_model($model);
    
    if ($previous_response_id) {
        $payload->{previous_response_id} = $previous_response_id;
        print STDERR "[DEBUG][APIManager] Including previous_response_id (stateful_marker): " . 
                     substr($previous_response_id, 0, 20) . "...\n" if should_log('DEBUG');
    } else {
        # FALLBACK: Try old lastGitHubCopilotResponseId if stateful_marker not found
        # This is the expected path for GitHub Copilot (which doesn't return stateful_marker)
        if ($self->{session} && $self->{session}{lastGitHubCopilotResponseId}) {
            $previous_response_id = $self->{session}{lastGitHubCopilotResponseId};
            $payload->{previous_response_id} = $previous_response_id;
            print STDERR "[DEBUG][APIManager] Using response_id (lastGitHubCopilotResponseId): " . 
                         substr($previous_response_id, 0, 30) . "...\n" if should_log('DEBUG');
        } else {
            # Only warn if this is NOT the first request AND we have no fallback
            my $is_first_request = scalar(grep { $_->{role} ne 'system' } @$messages) <= 1;
            if (!$is_first_request) {
                print STDERR "[WARNING][APIManager] NO previous_response_id on turn 2+ - this will be charged as NEW request\n" if should_log('WARNING');
                # Debug: Why isn't fallback working?
                print STDERR "[DEBUG][APIManager] FALLBACK not available: session=" .
                             (defined $self->{session} ? "defined" : "undef") .
                             ", lastGitHubCopilotResponseId=" .
                             (defined $self->{session}{lastGitHubCopilotResponseId} ? $self->{session}{lastGitHubCopilotResponseId} : "undef") . "\n"
                    if should_log('DEBUG');
            }
        }
    }
    # Add tools if provided
    if ($opts{tools} && ref($opts{tools}) eq 'ARRAY' && @{$opts{tools}}) {
        $payload->{tools} = $opts{tools};
        print STDERR "[DEBUG][APIManager] Adding " . scalar(@{$opts{tools}}) . " tools to request\n"
            if $self->{debug};
    }
    
    # Adapt payload for specific endpoint
    $payload = $self->adapt_request_for_endpoint($payload, $endpoint_config);
    
    # CRITICAL: Sanitize entire payload to remove problematic UTF-8 characters
    $payload = _sanitize_payload_recursive($payload);
    
    # DEBUG: Log session continuity fields (CRITICAL for billing tracking)
    if ($self->{debug}) {
        print STDERR "[DEBUG][APIManager] BILLING CONTINUITY CHECK:\n";
        print STDERR "[DEBUG][APIManager]   copilot_thread_id: " . ($payload->{copilot_thread_id} || "NOT SET") . "\n";
        print STDERR "[DEBUG][APIManager]   previous_response_id: " . ($payload->{previous_response_id} || "NOT SET") . "\n";
        if (!$payload->{previous_response_id}) {
            print STDERR "[DEBUG][APIManager]   session ref: " . (ref($self->{session}) || "NOT AN OBJECT") . "\n";
            print STDERR "[DEBUG][APIManager]   lastGitHubCopilotResponseId: " . 
                         ($self->{session} ? ($self->{session}{lastGitHubCopilotResponseId} || "NOT SET") : "NO SESSION") . "\n";
        }
    }
    
    # DEBUG: Log last few messages
    if ($self->{debug} && $payload->{messages}) {
        my $msg_count = scalar(@{$payload->{messages}});
        my $stream_label = $stream ? "Streaming" : "Non-streaming";
        print STDERR "[DEBUG][APIManager] $stream_label: Sending $msg_count messages\n";
        my $start = $msg_count > 4 ? $msg_count - 4 : 0;
        for (my $i = $start; $i < $msg_count; $i++) {
            my $msg = $payload->{messages}[$i];
            my $preview = substr($msg->{content} || '', 0, 60);
            $preview =~ s/\n/ /g;
            print STDERR sprintf("  [%d] %s: %s%s\n", 
                $i, $msg->{role}, $preview,
                (length($msg->{content} || '') > 60 ? '...' : ''));
            if ($msg->{tool_calls}) {
                print STDERR sprintf("       HAS %d tool_calls\n", scalar(@{$msg->{tool_calls}}));
            }
            if ($msg->{tool_call_id}) {
                print STDERR sprintf("       tool_call_id=%s\n", substr($msg->{tool_call_id}, 0, 20));
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
    
    # GitHub Copilot: Use /chat/completions for all models
    if ($endpoint_config->{requires_copilot_headers}) {
        my $path = '/chat/completions';
        $final_endpoint =~ s{/$}{};
        $final_endpoint .= $path;
        
        if ($self->{debug}) {
            my $stream_label = $is_streaming ? "streaming" : "non-streaming";
            print STDERR "[DEBUG][APIManager] GitHub Copilot $stream_label endpoint: $final_endpoint\n";
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
        # Generate UUID-like request ID
        my $uuid = sprintf('%04x%04x-%04x-%04x-%04x-%04x%04x%04x',
            int(rand(0x10000)), int(rand(0x10000)),
            int(rand(0x10000)),
            int(rand(0x10000)) | 0x4000,
            int(rand(0x10000)) | 0x8000,
            int(rand(0x10000)), int(rand(0x10000)), int(rand(0x10000))
        );
        
        $req->header('X-Request-Id' => $uuid);
        $req->header('X-Interaction-Type' => 'conversational');
        $req->header('OpenAI-Intent' => 'conversational');
        $req->header('X-GitHub-Api-Version' => '2025-05-01');
        $req->header('Editor-Version' => 'vscode/1.96.0');
        $req->header('Editor-Plugin-Version' => 'copilot-chat/0.22.4');
        $req->header('User-Agent' => 'GitHubCopilotChat/0.22.4');
        
        # X-Initiator controls premium billing:
        # - 'user' (iteration 1): User-initiated request, charges premium quota
        # - 'agent' (iteration 2+): Tool-calling continuation, no additional charge
        # Per SAM reference: "iteration 0 = user-initiated, iteration 1+ = agent-initiated"
        # But CLIO's WorkflowOrchestrator uses 1-indexed iterations, so:
        # - iteration 1 = first request (user-initiated, charges quota)
        # - iteration 2+ = tool continuations (agent-initiated, free)
        my $tool_call_iteration = $opts->{tool_call_iteration} || 1;
        my $initiator = $tool_call_iteration <= 1 ? 'user' : 'agent';
        $req->header('X-Initiator' => $initiator);
        
        if ($self->{debug}) {
            warn "[DEBUG] Added GitHub Copilot headers (X-Request-Id: $uuid, X-Initiator: $initiator, iteration: $tool_call_iteration)\n";
        }
    }
    
    $req->content($json);
    
    return ($req, $final_endpoint);
}

# Helper: Handle error response
sub _handle_error_response {
    my ($self, $resp, $json, $is_streaming) = @_;
    
    my $status = $resp->code;
    my $error_prefix = $is_streaming ? "Streaming request failed" : "Request failed";
    my $error = "$error_prefix: " . $resp->status_line;
    
    # Try to extract detailed error from response body
    my $content = eval { decode_json($resp->decoded_content) };
    if ($content && $content->{error}) {
        $error = $content->{error}{message} || $content->{error} || $error;
    }
    
    # Log error details
    print STDERR "[ERROR][APIManager] $error\n" if should_log('ERROR');
    if ($is_streaming) {
        print STDERR "[ERROR][APIManager] Response body: " . $resp->decoded_content . "\n" if should_log('ERROR');
        print STDERR "[DEBUG][APIManager] Request was: " . substr($json, 0, 500) . "...\n" if should_log('DEBUG');
    } elsif ($self->{debug}) {
        warn "[ERROR] $error\n";
    }
    
    # Handle rate limiting (429) - parse retry delay from error response
    if ($status == 429) {
        my $retry_after = 60;  # Default fallback
        
        # Try to parse retry delay from error message (SAM pattern)
        # Message format: "Please retry in XX.XXs" or "retry in XX seconds"
        if ($error =~ /retry in ([\d.]+)\s*s(?:econds?)?/i) {
            $retry_after = int($1) + 1;  # Add 1 second buffer
        }
        # Try Retry-After header as fallback
        elsif (my $header_value = $resp->header('Retry-After')) {
            $retry_after = $header_value;
        }
        
        $self->{rate_limit_until} = time() + $retry_after;
        
        # Provide helpful error message
        my $retry_msg = sprintf(
            "Rate limit exceeded. Waiting %d seconds before retrying. "
            . "This is normal and CLIO will automatically retry after the wait period."
            . ($is_streaming ? "" : " Please review the API Terms of Service: https://docs.github.com/en/site-policy/github-terms/github-terms-of-service"),
            $retry_after
        );
        
        print STDERR "[INFO][APIManager] $retry_msg\n";
        $error = $retry_msg;
    }
    
    # Return appropriate format based on streaming vs non-streaming
    if ($is_streaming) {
        return { success => 0, error => $error };
    } else {
        return $self->_error($error);
    }
}

sub send_request {
    my ($self, $input, %opts) = @_;
    
    # Prevent rate limits: Add delay between requests
    # Track wall clock time, not just request timestamps
    # This ensures delay even when tool executions happen between requests
    if (defined $self->{last_request_time}) {
        my $now = Time::HiRes::time();  # High resolution time
        my $elapsed = $now - $self->{last_request_time};
        my $min_delay = 2.5;  # 2.5 second minimum between requests
        
        if ($elapsed < $min_delay) {
            my $wait = $min_delay - $elapsed;
            print STDERR "[DEBUG][APIManager] Rate limit prevention: waiting " . sprintf("%.3f", $wait) . "s\n" if should_log('DEBUG');
            Time::HiRes::sleep($wait);  # High resolution sleep
        }
    }
    
    # Record timestamp BEFORE request (prevents race conditions)
    $self->{last_request_time} = Time::HiRes::time();
    
    # Rate limiting: Check if we need to wait before making request
    if (time() < $self->{rate_limit_until}) {
        my $wait = int($self->{rate_limit_until} - time()) + 1;
        print STDERR "[INFO][APIManager] Rate limited. Waiting ${wait}s before retry...\n";
        
        # Show countdown for user feedback
        for (my $i = $wait; $i > 0; $i--) {
            print STDERR "\r[INFO][APIManager] Retrying in ${i}s..." unless $i % 5;  # Update every 5s
            sleep(1);
        }
        print STDERR "\r[INFO][APIManager] Retry limit cleared. Sending request...\n";
    }
    
    # Get endpoint-specific configuration
    my $ep = $self->_prepare_endpoint_config(%opts);
    my $endpoint_config = $ep->{config};
    my $endpoint = $ep->{endpoint};
    my $model = $ep->{model};
    
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
    
    # Validate and truncate messages against model token limits
    $messages = $self->validate_and_truncate_messages($messages, $model);
    
    # Build request payload (non-streaming)
    my $payload = $self->_build_payload($messages, $model, $endpoint_config, %opts, stream => 0);
    
    my $json = encode_json($payload);
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

    # ALWAYS log full request for debugging quota issues
    print STDERR "\n" . "="x80 . "\n";
    print STDERR "[REQUEST DEBUG] Endpoint: $final_endpoint\n";
    print STDERR "[REQUEST DEBUG] Headers:\n";
    for my $h ($req->headers->header_field_names) {
        print STDERR "  $h: " . $req->header($h) . "\n";
    }
    print STDERR "[REQUEST DEBUG] Body:\n";
    # Pretty-print JSON for easier comparison
    my $pretty_json = $json;
    eval {
        my $decoded = decode_json($json);
        $pretty_json = encode_json($decoded);  # Re-encode compactly
    };
    # Save to file for detailed inspection
    if (open my $fh, '>>', '/tmp/clio_requests.log') {
        print $fh "\n" . "="x80 . "\n";
        print $fh "[" . scalar(localtime) . "] GitHub Copilot Request\n";
        print $fh "Endpoint: $final_endpoint\n\n";
        print $fh "Headers:\n";
        for my $h ($req->headers->header_field_names) {
            print $fh "  $h: " . $req->header($h) . "\n";
        }
        print $fh "\nBody:\n$pretty_json\n";
        close $fh;
    }
    print STDERR "[First 800 chars]: " . substr($pretty_json, 0, 800) . "...\n";
    print STDERR "="x80 . "\n\n";

    if ($self->{debug}) {
        warn "[DEBUG] Making request to final endpoint: $final_endpoint\n";
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
        
        return $self->_error($error);
    }
    
    if (!$resp->is_success) {
        return $self->_handle_error_response($resp, $json, 0);
    }
    
    # Log raw response for debugging
    warn "[DEBUG] Raw response: " . $resp->decoded_content . "\n" if $self->{debug};
    
    my $data = eval { decode_json($resp->decoded_content) };
    if ($@) {
        my $error = "Invalid response format: $@";
        warn "[ERROR] $error\n" if $self->{debug};
        return $self->_error($error);
    }
    
    # Log parsed data structure
    warn "[DEBUG] Parsed data: " . encode_json($data) . "\n" if $self->{debug};
    
    # Extract stateful_marker for session continuation (GitHub Copilot billing)
    # This is the CORRECT field to use (not 'id'!) per VS Code implementation
    # The stateful_marker is used as previous_response_id in next request
    # to signal session continuation and prevent duplicate premium charges
    if ($data->{stateful_marker}) {
        my $iteration = $opts{tool_call_iteration} || 1;
        $self->_store_stateful_marker($data->{stateful_marker}, $model, $iteration);
    }
    
    # Check for stateful_marker in message as well (SAM approach)
    if ($data->{choices} && @{$data->{choices}} && 
        $data->{choices}[0]{message} && 
        $data->{choices}[0]{message}{stateful_marker}) {
        my $iteration = $opts{tool_call_iteration} || 1;
        $self->_store_stateful_marker($data->{choices}[0]{message}{stateful_marker}, $model, $iteration);
    }
    
    # DEPRECATED: Old response_id storage (kept temporarily for debugging)
    # TODO: Remove this once stateful_marker is confirmed working
    if ($data->{id} && $self->{session}) {
        my $response_id = $data->{id};
        $self->{session}{lastGitHubCopilotResponseId} = $response_id;
        print STDERR "[INFO][APIManager] ✅ Stored response_id (fallback mechanism): " . substr($response_id, 0, 30) . "...\n" if should_log('INFO');
        
        # Persist session immediately to maintain billing continuity
        if ($self->{session}->can('save')) {
            $self->{session}->save();
            print STDERR "[INFO][APIManager] ✅ Session saved with response_id\n" if should_log('INFO');
        } else {
            print STDERR "[ERROR][APIManager] Session object cannot save! Response ID will be lost!\n";
        }
    } else {
        print STDERR "[WARNING][APIManager] Cannot store response_id: " .
                     "id=" . (defined $data->{id} ? substr($data->{id}, 0, 20) . "..." : "undef") .
                     ", session=" . (defined $self->{session} ? "defined" : "undef") . "\n" if should_log('WARNING');
    }
    
    # Process GitHub Copilot quota headers for premium billing tracking
    $self->_process_quota_headers($resp->headers, $data->{id}) if $endpoint_config->{requires_copilot_headers};
    
    # Extract and validate the message content
    my $content = '';
    my $tool_calls = undef;  # Task 3: Extract tool_calls if present
    
    # Try to extract content based on different API response formats
    if (ref $data eq 'HASH') {
        # OpenAI/GitHub Copilot format
        if ($data->{choices} && @{$data->{choices}} && $data->{choices}[0]{message}) {
            my $message = $data->{choices}[0]{message};
            $content = $message->{content};
            
            # Task 3: Extract tool_calls from message if present
            if ($message->{tool_calls} && ref($message->{tool_calls}) eq 'ARRAY') {
                $tool_calls = $message->{tool_calls};
                
                if ($self->{debug}) {
                    warn "[DEBUG] Extracted " . scalar(@$tool_calls) . " tool_calls from response\n";
                }
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
        # Only wrap in conversation tags if not already wrapped
        if ($content !~ m{\[conversation\].*?\[/conversation\]}s) {
            $content = "[conversation]$content\[/conversation]";
            warn "[DEBUG] Wrapped content in conversation tags\n" if $self->{debug};
        }
        
        # Extract token usage for performance tracking
        if ($data->{usage}) {
            $tokens_in = $data->{usage}{prompt_tokens} || 0;
            $tokens_out = $data->{usage}{completion_tokens} || 0;
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
        
        return $result;
    }
    
    # Task 3: Handle case where AI only returns tool_calls (no content)
    if ($tool_calls && @$tool_calls) {
        if ($self->{debug}) {
            warn "[DEBUG] Response contains only tool_calls (no text content)\n";
        }
        
        return {
            content => '',  # Empty content when only tool_calls
            tool_calls => $tool_calls,
            usage => $data->{usage}
        };
    }
    
    # No valid content found
    warn "[ERROR] No message content in response\n" if $self->{debug};
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
    
    print STDERR "[DEBUG][APIManager] Starting streaming request\n" if should_log('DEBUG');
    
    # Prevent rate limits: Add delay between requests
    # Track wall clock time, not just request timestamps
    # This ensures delay even when tool executions happen between requests
    if (defined $self->{last_request_time}) {
        my $now = Time::HiRes::time();  # High resolution time
        my $elapsed = $now - $self->{last_request_time};
        my $min_delay = 2.5;  # 2.5 second minimum between requests
        
        if ($elapsed < $min_delay) {
            my $wait = $min_delay - $elapsed;
            print STDERR "[DEBUG][APIManager] Waiting " . sprintf("%.3f", $wait) . "s for rate limit\n"
                if $self->{debug};
            Time::HiRes::sleep($wait);  # High resolution sleep
        }
    }
    
    # Record timestamp BEFORE request (prevents race conditions)
    $self->{last_request_time} = Time::HiRes::time();
    
    # Rate limiting: Check if we need to wait before making request
    if (time() < $self->{rate_limit_until}) {
        my $wait = int($self->{rate_limit_until} - time()) + 1;
        print STDERR "[INFO][APIManager] Rate limited. Waiting ${wait}s before retry...\n";
        
        # Show countdown for user feedback
        for (my $i = $wait; $i > 0; $i--) {
            print STDERR "\r[INFO][APIManager] Retrying in ${i}s..." unless $i % 5;  # Update every 5s
            sleep(1);
        }
        print STDERR "\r[INFO][APIManager] Retry limit cleared. Sending request...\n";
    }
    
    # Extract on_chunk callback
    my $on_chunk = $opts{on_chunk};
    delete $opts{on_chunk};  # Remove from opts before building payload
    
    # Get endpoint-specific configuration
    my $ep = $self->_prepare_endpoint_config(%opts);
    my $endpoint_config = $ep->{config};
    my $endpoint = $ep->{endpoint};
    my $model = $ep->{model};
    
    # Prepare and trim messages
    my $messages = $self->_prepare_messages($input, %opts);
    
    # Debug logging
    if ($self->{debug}) {
        print STDERR "[DEBUG][APIManager] Streaming to $endpoint\n";
        print STDERR "[DEBUG][APIManager] Model: $model\n";
    }
    
    if (!$self->{api_key}) {
        return { success => 0, error => "Missing API key. Please configure a provider with /api provider <name> or set key with /api key <value>" };
    }
    
    # Validate and truncate messages against model token limits
    $messages = $self->validate_and_truncate_messages($messages, $model);
    
    # Build request payload (streaming enabled)
    my $payload = $self->_build_payload($messages, $model, $endpoint_config, %opts, stream => 1);
    
    # DEBUG: Print EXACT request payload being sent to API
    if ($self->{debug}) {
        require Data::Dumper;
        print STDERR "[DEBUG][APIManager] ===== REQUEST PAYLOAD =====\n";
        print STDERR "[DEBUG][APIManager] Endpoint: $endpoint\n";
        print STDERR "[DEBUG][APIManager] Model: $payload->{model}\n";
        print STDERR "[DEBUG][APIManager] Messages count: " . scalar(@{$payload->{messages}}) . "\n";
        if ($payload->{tools}) {
            print STDERR "[DEBUG][APIManager] Tools array (" . scalar(@{$payload->{tools}}) . " tools):\n";
            for my $i (0 .. $#{$payload->{tools}}) {
                my $tool = $payload->{tools}[$i];
                print STDERR "[DEBUG][APIManager]   Tool $i: $tool->{function}->{name}\n";
                print STDERR Data::Dumper->Dump([$tool], ["tool_$i"]);
            }
        } else {
            print STDERR "[DEBUG][APIManager] Tools: NONE\n";
        }
        print STDERR "[DEBUG][APIManager] ===== END REQUEST PAYLOAD =====\n";
    }
    
    my $json = encode_json($payload);
    
    # Create HTTP client
    my $ua = CLIO::Compat::HTTP->new(
        timeout => 300,  # Longer timeout for streaming
        agent   => 'GitHubCopilotChat/0.22.4',  # Match GitHub Copilot client  
        ssl_opts => { verify_hostname => 1 }
    );
    
    # Build HTTP request with headers (pass opts for tool_call_iteration)
    my ($req, $final_endpoint) = $self->_build_request($endpoint, $endpoint_config, $json, 1, \%opts);
    
    # Request headers available for debugging if needed (use should_log('DEBUG'))
    
    # Initialize metrics tracking
    my $start_time = time();
    my $first_token_time = undef;
    my $token_count = 0;
    my $accumulated_content = '';
    my $buffer = '';  # Buffer for partial SSE lines
    my $tool_calls_accumulator = {};  # Accumulate tool call deltas by index
    
    # Make streaming request with callback
    my $resp;
    my $streaming_headers;  # Capture headers from streaming callback
    eval {
        $resp = $ua->request($req, sub {
            my ($chunk, $response, $protocol) = @_;
            
            # Capture headers on first chunk (they're available in $response object)
            if (!$streaming_headers && $response) {
                $streaming_headers = $response->headers->clone;
                print STDERR "[DEBUG][APIManager] Captured headers from streaming response\n" if should_log('DEBUG');
            }
            
            # Append chunk to buffer
            $buffer .= $chunk;
            
            # Process complete SSE lines (ending with \n\n)
            while ($buffer =~ s/^(.*?)\n\n//s) {
                my $sse_chunk = $1;
                
                # Skip empty lines
                next unless $sse_chunk =~ /\S/;
                
                # Parse SSE format: "data: {...}\n"
                for my $line (split /\n/, $sse_chunk) {
                    next unless $line =~ /^data:\s*(.+)$/;
                    my $data_json = $1;
                    
                    # Check for stream end
                    next if $data_json eq '[DONE]';
                    
                    # Parse JSON chunk
                    my $data = eval { decode_json($data_json) };
                    if ($@) {
                        print STDERR "[WARN]APIManager] Failed to parse SSE chunk: $@\n" if $self->{debug};
                        next;
                    }
                    
                    # DEBUG: Log what fields are in each chunk
                    if (should_log('DEBUG')) {
                        my @fields = keys %$data;
                        print STDERR "[DEBUG][APIManager] SSE chunk fields: " . join(', ', @fields) . "\n";
                        if ($data->{id}) {
                            print STDERR "[DEBUG][APIManager] Chunk has id: " . substr($data->{id}, 0, 30) . "...\n";
                        }
                    }
                    
                    # Extract stateful_marker for session continuation (GitHub Copilot billing)
                    # This is the CORRECT field to use (not 'id'!) per VS Code implementation
                    # The stateful_marker is used as previous_response_id in next request
                    # to signal session continuation and prevent duplicate premium charges
                    if ($data->{stateful_marker}) {
                        my $iteration = $opts{tool_call_iteration} || 1;
                        $self->_store_stateful_marker($data->{stateful_marker}, $model, $iteration);
                    }
                    
                    # FALLBACK: Store response 'id' if no stateful_marker (GitHub Copilot doesn't return stateful_marker)
                    # This matches SAM's approach: statefulMarker = statefulMarker ?? id
                    if ($data->{id} && $self->{session}) {
                        $self->{session}{lastGitHubCopilotResponseId} = $data->{id};
                        print STDERR "[INFO][APIManager] ✅ Stored response_id (streaming, fallback): " . 
                                     substr($data->{id}, 0, 30) . "...\n" if should_log('INFO');
                        
                        print STDERR "[DEBUG][APIManager] Session object type: " . ref($self->{session}) . "\n" if should_log('DEBUG');
                        
                        # Persist session immediately to maintain billing continuity
                        if ($self->{session}->can('save')) {
                            print STDERR "[DEBUG][APIManager] Calling session->save()...\n" if should_log('DEBUG');
                            $self->{session}->save();
                            print STDERR "[INFO][APIManager] ✅ Session saved with response_id (streaming)\n" if should_log('INFO');
                        } else {
                            print STDERR "[ERROR][APIManager] Session object cannot save! Response ID will be lost!\n";
                        }
                    } elsif ($data->{id}) {
                        print STDERR "[WARNING][APIManager] Cannot store response_id (streaming): session is undef\n" 
                            if should_log('WARNING');
                    } else {
                        # DEBUG: Why no id?
                        print STDERR "[DEBUG][APIManager] No id in this chunk (session=" . 
                                     (defined $self->{session} ? "defined" : "undef") . ")\n" if should_log('DEBUG');
                    }
                    
                    # Extract content delta and tool_calls from chunk
                    my $content_delta = undef;
                    my $tool_calls_delta = undef;
                    
                    # OpenAI/GitHub Copilot streaming format
                    if ($data->{choices} && @{$data->{choices}}) {
                        my $choice = $data->{choices}[0];
                        my $delta = $choice->{delta};
                        
                        if ($delta) {
                            # Check for stateful_marker in delta as well
                            # (SAM implementation suggests it might be in message)
                            if ($delta->{stateful_marker}) {
                                my $iteration = $opts{tool_call_iteration} || 1;
                                $self->_store_stateful_marker($delta->{stateful_marker}, $model, $iteration);
                            }
                            
                            # Extract content
                            if ($delta->{content}) {
                                $content_delta = $delta->{content};
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
                                $tool_calls_accumulator->{$index} = {
                                    id => $tc_delta->{id} // '',
                                    type => $tc_delta->{type} // 'function',
                                    function => {
                                        name => '',
                                        arguments => '',
                                    }
                                };
                            }
                            
                            # Accumulate function name and arguments
                            if ($tc_delta->{function}) {
                                if ($tc_delta->{function}{name}) {
                                    $tool_calls_accumulator->{$index}{function}{name} .= $tc_delta->{function}{name};
                                }
                                if ($tc_delta->{function}{arguments}) {
                                    $tool_calls_accumulator->{$index}{function}{arguments} .= $tc_delta->{function}{arguments};
                                }
                            }
                            
                            print STDERR "[DEBUG][APIManager] Tool call delta: index=$index, " .
                                "name=" . ($tc_delta->{function}{name} // '') . ", " .
                                "args_chunk=" . (length($tc_delta->{function}{arguments} // 0)) . " bytes\n"
                                if $self->{debug};
                        }
                    }
                    
                    # If we got content, track metrics and call callback
                    if ($content_delta) {
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
    
    # Handle request errors
    if ($@) {
        my $error = "Streaming request failed: $@";
        print STDERR "[ERROR][APIManager] $error\n" if should_log('ERROR');
        return { success => 0, error => $error };
    }
    
    if (!$resp->is_success) {
        return $self->_handle_error_response($resp, $json, 1);
    }
    
    # Calculate final metrics
    my $end_time = time();
    my $total_duration = $end_time - $start_time;
    my $ttft = $first_token_time ? ($first_token_time - $start_time) : undef;
    my $tps = ($total_duration > 0 && $token_count > 0) ? ($token_count / $total_duration) : 0;
    
    # Debug metrics
    if ($self->{debug}) {
        print STDERR sprintf(
            "[DEBUG][APIManager] Streaming complete - TTFT: %.2fs, TPS: %.1f, Tokens: %d, Duration: %.2fs\n",
            $ttft // 0,
            $tps,
            $token_count,
            $total_duration
        );
    }
    
    # Persist session if we got a response_id
    if ($self->{session} && $self->{session}{lastGitHubCopilotResponseId}) {
        if ($self->{session}->can('save')) {
            $self->{session}->save();
        }
    }
    
    # Process quota headers for billing tracking (GitHub Copilot)
    # Use streaming_headers if available (captured during streaming), otherwise resp->headers
    my $headers_to_use = $streaming_headers || $resp->headers;
    
    print STDERR "[DEBUG][APIManager] Checking quota header conditions: requires_copilot_headers=" . 
        ($endpoint_config->{requires_copilot_headers} ? 'yes' : 'no') . ", has_headers=" . 
        ($headers_to_use ? 'yes' : 'no') . "\n" if should_log('DEBUG');
    
    if ($endpoint_config->{requires_copilot_headers} && $headers_to_use) {
        my $response_id = $self->{session}{lastGitHubCopilotResponseId} || 'unknown';
        
        print STDERR "[DEBUG][APIManager] Calling _process_quota_headers with response_id=$response_id\n" if should_log('DEBUG');
        $self->_process_quota_headers($headers_to_use, $response_id);
    } else {
        print STDERR "[DEBUG][APIManager] Skipping quota header processing\n" if should_log('DEBUG');
    }
    
    # Estimate usage for billing (streaming doesn't provide usage data)
    # Token estimates: accumulated_content ~= completion_tokens
    # Estimate prompt_tokens from messages array
    my $estimated_completion_tokens = $token_count;
    my $estimated_prompt_tokens = 0;
    
    # Estimate prompt tokens from messages
    if ($messages && ref($messages) eq 'ARRAY') {
        for my $msg (@$messages) {
            if ($msg->{content}) {
                $estimated_prompt_tokens += int(length($msg->{content}) / 4);
            }
        }
    } elsif ($input) {
        $estimated_prompt_tokens = int(length($input) / 4);
    }
    
    # Convert accumulated tool_calls to array
    my $tool_calls = undef;
    if (keys %$tool_calls_accumulator) {
        $tool_calls = [
            map { $tool_calls_accumulator->{$_} }
            sort { $a <=> $b }
            keys %$tool_calls_accumulator
        ];
        
        print STDERR "[DEBUG][APIManager] Accumulated " . scalar(@$tool_calls) . " tool calls from streaming\n"
            if $self->{debug};
    }
    
    # Build response with metrics and estimated usage
    my $response = {
        success => 1,
        content => $accumulated_content,
        metrics => {
            ttft => $ttft,
            tps => $tps,
            tokens => $token_count,
            duration => $total_duration,
        },
        usage => {
            prompt_tokens => $estimated_prompt_tokens,
            completion_tokens => $estimated_completion_tokens,
            total_tokens => $estimated_prompt_tokens + $estimated_completion_tokens,
        },
    };
    
    print STDERR "[DEBUG][APIManager] Streaming complete - accumulated content length: " . length($accumulated_content) . "\n" if should_log('DEBUG');
    print STDERR "[DEBUG][APIManager] Content: '" . $accumulated_content . "'\n" if should_log('DEBUG');
    
    # Add tool_calls if present
    if ($tool_calls) {
        $response->{tool_calls} = $tool_calls;
    }
    
    # DEBUG: Print EXACT response structure being returned
    if ($self->{debug}) {
        require Data::Dumper;
        print STDERR "[DEBUG][APIManager] ===== API RESPONSE =====\n";
        print STDERR "[DEBUG][APIManager] Has tool_calls: " . ($response->{tool_calls} ? "YES" : "NO") . "\n";
        if ($response->{tool_calls}) {
            print STDERR "[DEBUG][APIManager] Tool calls count: " . scalar(@{$response->{tool_calls}}) . "\n";
            print STDERR Data::Dumper->Dump([$response->{tool_calls}], ['tool_calls']);
        }
        print STDERR "[DEBUG][APIManager] Content length: " . length($response->{content}) . "\n";
        print STDERR "[DEBUG][APIManager] Content preview: " . substr($response->{content}, 0, 200) . "...\n";
        print STDERR "[DEBUG][APIManager] ===== END API RESPONSE =====\n";
    }
    
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
    
    # Create message file
    my $message_dir = "$ENV{HOME}/.clio/messages";
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
                open(my $fh, '<', $self->{message_file}) or die "Could not open message file: $!";
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

=head2 _process_quota_headers

Process GitHub Copilot quota headers from API response.

Extracts premium model usage information to track session billing continuity.
Headers examined:
- x-quota-snapshot-premium_models
- x-quota-snapshot-premium_interactions
- x-quota-snapshot-chat

Header format (URL-encoded key=value pairs):
"ent=100&ov=0.0&ovPerm=true&rem=75.5&rst=2025-11-01T00:00:00Z"

Fields:
- ent: Entitlement (total quota limit for billing period)
- rem: Remaining quota (percentage)
- ov: Overage used (beyond entitlement)
- ovPerm: Overage permitted (can user go over limit?)
- rst: Reset time (when quota resets)

Arguments:
- $headers: HTTP::Headers object from response
- $response_id: GitHub Copilot response ID (for logging)

=cut

sub _process_quota_headers {
    my ($self, $headers, $response_id) = @_;
    
    return unless $self->{session};
    
    # WORKAROUND: header() accessor returns empty for quota headers in streaming callback,
    # but scan() DOES see them! So we extract quota values directly from scan() instead.
    my $premium_models;
    my $premium_interactions;
    my $chat_quota;
    
    # Scan all headers and extract quota headers by name matching
    $headers->scan(sub {
        my ($name, $value) = @_;
        
        # Match quota headers (case-insensitive)
        if ($name =~ /^x-quota-snapshot-premium_models$/i) {
            $premium_models = $value;
        }
        elsif ($name =~ /^x-quota-snapshot-premium_interactions$/i) {
            $premium_interactions = $value;
        }
        elsif ($name =~ /^x-quota-snapshot-chat$/i) {
            $chat_quota = $value;
        }
    });
    
    # Quota headers available: premium_models, premium_interactions, chat
    
    # Select quota header in priority order (prefer chat for free models)
    my $quota_header = $premium_models || $premium_interactions || $chat_quota;
    my $quota_source;
    
    if ($premium_models) {
        $quota_source = 'x-quota-snapshot-premium_models';
    } elsif ($premium_interactions) {
        $quota_source = 'x-quota-snapshot-premium_interactions';
    } elsif ($chat_quota) {
        $quota_source = 'x-quota-snapshot-chat';
    }
    
    # Return if no quota header found
    unless ($quota_header) {
        print STDERR "[DEBUG][APIManager] No quota header in response\n" if should_log('DEBUG');
        return;
    }
    
    print STDERR "[DEBUG][APIManager] Using quota from: $quota_source\n" if should_log('DEBUG');
    
    # Parse URL-encoded string into key-value pairs
    # Format: "ent=100&ov=0.0&ovPerm=true&rem=75.5&rst=2025-11-01T00:00:00Z"
    my %quota;
    for my $pair (split /&/, $quota_header) {
        my ($key, $value) = split /=/, $pair, 2;
        $quota{$key} = $value if defined $value;
    }
    
    # Extract quota values from API header
    my $entitlement = int($quota{ent} || 0);
    my $overage_used = $quota{ov} || 0.0;
    my $overage_permitted = ($quota{ovPerm} || '') eq 'true';
    my $percent_remaining = $quota{rem} || 0.0;
    my $reset_date = $quota{rst} || 'unknown';
    
    # Calculate used based on entitlement and remaining percentage
    # SAM formula (Providers.swift:2463): max(0, Int(Double(entitlement) * (1.0 - percentRemaining / 100.0)))
    # Note: GitHub API provides ent + rem, NOT used directly
    my $used = int($entitlement * (1.0 - $percent_remaining / 100.0));
    $used = 0 if $used < 0;  # max(0, calculated_value)
    
    # Calculate available
    my $available = $entitlement - $used;
    
    # Store quota info in session
    $self->{session}{quota} = {
        entitlement => $entitlement,
        used => $used,
        available => $available,
        percent_remaining => $percent_remaining,
        overage_used => $overage_used,
        overage_permitted => $overage_permitted,
        reset_date => $reset_date,
        last_updated => time(),
    };
    
    # Calculate delta (change from last request) for premium quota tracking
    my $delta = undef;  # undefined for first request
    
    # In APIManager, $self->{session} IS the State object (not Manager)
    my $state = $self->{session};
    
    if ($state && defined $state->{_last_premium_used}) {
        $delta = $used - $state->{_last_premium_used};
        
        print STDERR "[DEBUG][APIManager] Calculated delta: $delta\n" if should_log('DEBUG');
        
        if ($delta > 0) {
            # Premium request(s) charged - store message for Chat to display
            my $percent_used = 100.0 - $percent_remaining;
            my $charge_msg = sprintf("+%d premium request%s charged (%d/%s - %.1f%% used)",
                $delta,
                $delta > 1 ? "s" : "",
                $used,
                $entitlement == -1 ? "unlimited" : $entitlement,
                $percent_used);
            
            # Store in session state for UI to display
            $state->{_premium_charge_message} = $charge_msg;
            
            print STDERR "[INFO][APIManager] $charge_msg\n" if should_log('INFO');
        } elsif ($delta < 0) {
            # Quota decreased (shouldn't happen)
            print STDERR "[WARNING][APIManager] Quota decreased by $delta (unexpected)\n" if should_log('WARNING');
        } else {
            # No charge - session continuity working!
            print STDERR "[INFO][APIManager] +0 premium requests (session continuity working)\n" if should_log('INFO');
        }
    } else {
        # First request - delta is undefined, will be charged
        print STDERR "[INFO][APIManager] Initial request - establishing baseline\n" if should_log('INFO');
    }
    
    # Update last known premium quota (state already retrieved above)
    return unless $state;  # Can't track quota without session state
    $state->{_last_premium_used} = $used;
    $state->{_last_quota_delta} = $delta;
    
    # Track total premium requests charged in billing summary
    if (defined $delta && $delta > 0) {
        # Increment premium request counter in session billing
        if (exists $state->{billing}{total_premium_requests}) {
            $state->{billing}{total_premium_requests} += $delta;
        }
    }
    
    # Persist session to save quota tracking
    if ($self->{session}->can('save')) {
        $self->{session}->save();
    }
    
    # Log quota information
    my $req_id_short = $response_id ? substr($response_id, 0, 8) : 'unknown';
    print STDERR "[INFO][APIManager] GitHub Copilot Premium Quota [req:$req_id_short]:\n" if should_log('INFO');
    print STDERR "[INFO][APIManager]  - Entitlement: " . ($entitlement == -1 ? "Unlimited" : $entitlement) . "\n" if should_log('INFO');
    print STDERR "[INFO][APIManager]  - Used: $used\n" if should_log('INFO');
    print STDERR "[INFO][APIManager]  - Remaining: " . sprintf("%.1f%%", $percent_remaining) . " ($available available)\n" if should_log('INFO');
    print STDERR "[INFO][APIManager]  - Overage: " . sprintf("%.1f", $overage_used) . " (permitted: " . ($overage_permitted ? 'yes' : 'no') . ")\n" if should_log('INFO');
    print STDERR "[INFO][APIManager]  - Reset Date: $reset_date\n" if should_log('INFO');
    
    # Warn if quota is running low
    if ($available < 10 && $available > 0) {
        print STDERR "[WARNING][APIManager] Only $available premium requests remaining!\n";
    } elsif ($available <= 0 && !$overage_permitted) {
        print STDERR "[ERROR][APIManager] Premium quota exhausted! Requests may fail.\n";
    }
}

=head2 _store_stateful_marker

Store stateful_marker for session continuation and billing optimization.

This implements the GitHub Copilot session continuation mechanism correctly
by storing the 'stateful_marker' field (not the 'id' field!) from API responses.

The stateful_marker is used as 'previous_response_id' in subsequent requests
to signal session continuation, which prevents multiple premium charges for
the same conversation thread (especially during tool-calling iterations).

Arguments:
- $marker: The stateful_marker string from the API response
- $model: The model ID this marker is associated with
- $iteration: Tool-calling iteration number (only store on iteration 1)

=cut

sub _store_stateful_marker {
    my ($self, $marker, $model, $iteration) = @_;
    
    return unless $self->{session};
    return unless defined $marker && $marker ne '';
    
    # Only store on first iteration (prevents overwriting during tool-calling)
    $iteration ||= 1;
    if ($iteration > 1) {
        print STDERR "[DEBUG][APIManager] Skipping stateful_marker storage (iteration $iteration)\n" 
            if should_log('DEBUG');
        return;
    }
    
    # Debug: Check if session exists
    unless ($self->{session}) {
        print STDERR "[ERROR][APIManager] Cannot store stateful_marker - no session object!\n";
        return;
    }
    
    # Initialize markers array if needed
    $self->{session}{_stateful_markers} ||= [];
    
    # Add marker to front (most recent first)
    unshift @{$self->{session}{_stateful_markers}}, {
        model => $model,
        marker => $marker,
        timestamp => time()
    };
    
    # Keep only last 10 markers (prevent unbounded growth)
    splice(@{$self->{session}{_stateful_markers}}, 10);
    
    print STDERR "[INFO][APIManager] ✅ Stored stateful_marker for model '$model': " . 
                 substr($marker, 0, 30) . "... (total markers: " . 
                 scalar(@{$self->{session}{_stateful_markers}}) . ")\n" if should_log('INFO');
    
    # Persist session
    if ($self->{session}->can('save')) {
        $self->{session}->save();
        print STDERR "[INFO][APIManager] ✅ Session saved with stateful_marker\n" if should_log('INFO');
    } else {
        print STDERR "[ERROR][APIManager] Session object cannot save! stateful_marker will be lost!\n";
    }
}

=head2 _get_stateful_marker_for_model

Retrieve the most recent stateful_marker for a given model.

Searches the session's stored markers and returns the most recent one
that matches the specified model ID.

Arguments:
- $model: The model ID to search for

Returns: stateful_marker string or undef if none found

=cut

sub _get_stateful_marker_for_model {
    my ($self, $model) = @_;
    
    unless ($self->{session}) {
        print STDERR "[ERROR][APIManager] Cannot get stateful_marker - no session object!\n";
        return undef;
    }
    
    # _stateful_markers may be undef (old sessions) or empty (expected for GitHub Copilot)
    # This is normal - we fall back to lastGitHubCopilotResponseId in _build_payload
    unless ($self->{session}{_stateful_markers} && @{$self->{session}{_stateful_markers}}) {
        print STDERR "[DEBUG][APIManager] No stateful_markers for model '$model' (will use response_id fallback)\n" 
            if should_log('DEBUG');
        return undef;
    }
    
    # Debug: Show what we have
    my $count = scalar(@{$self->{session}{_stateful_markers}});
    print STDERR "[DEBUG][APIManager] Searching for stateful_marker (model='$model', total markers=$count)\n"
        if should_log('DEBUG');
    
    # Search for most recent marker matching this model
    for my $marker_obj (@{$self->{session}{_stateful_markers}}) {
        if ($marker_obj->{model} eq $model) {
            print STDERR "[INFO][APIManager] ✅ Found stateful_marker for model '$model': " .
                         substr($marker_obj->{marker}, 0, 30) . "...\n" if should_log('INFO');
            return $marker_obj->{marker};
        }
    }
    
    # No marker found for this specific model - this is normal
    # Different models in the same session will have different markers
    print STDERR "[DEBUG][APIManager] No stateful_marker for model '$model' (searched $count markers)\n" 
        if should_log('DEBUG');
    
    # Debug: Show what models we DO have markers for
    if (should_log('DEBUG') && $count > 0) {
        my @models = map { $_->{model} } @{$self->{session}{_stateful_markers}};
        print STDERR "[DEBUG][APIManager] Available models in markers: " . join(', ', @models) . "\n";
    }
    
    return undef;
}

1;