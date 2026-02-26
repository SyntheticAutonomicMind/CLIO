package CLIO::Core::GitHubAuth;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(log_debug log_error log_info log_warning);
use CLIO::Util::ConfigPath qw(get_config_file get_config_dir);
use CLIO::Util::JSON qw(encode_json decode_json);
use CLIO::Compat::HTTP;
use Time::HiRes qw(sleep time);
use Carp qw(croak);
use File::Spec;

=head1 NAME

CLIO::Core::GitHubAuth - GitHub OAuth Device Code Flow authentication

=head1 DESCRIPTION

Implements GitHub's OAuth Device Code Flow for desktop applications.
Based on SAM's GitHubDeviceFlowService pattern.

Flow:
1. Request device code from GitHub
2. Display verification URL and user code to user
3. Poll for access token (user authorizes in browser)
4. Exchange GitHub token for Copilot-specific token
5. Store tokens with auto-refresh

=head1 SYNOPSIS

    my $auth = CLIO::Core::GitHubAuth->new(
        client_id => 'Iv1.b507a08c87ecfe98',  # GitHub Copilot Plugin (official)
        debug => 1
    );
    
    # Start device flow
    my $result = $auth->start_device_flow();
    # Returns: { user_code => 'ABCD-1234', verification_uri => 'https://github.com/login/device', ... }
    
    # Poll for token (blocks until authorized or timeout)
    my $github_token = $auth->poll_for_token($result->{device_code}, $result->{interval});
    
    # Exchange for Copilot token
    my $copilot_token = $auth->exchange_for_copilot_token($github_token);
    
    # Save tokens
    $auth->save_tokens($github_token, $copilot_token);
    
    # Load tokens
    my $tokens = $auth->load_tokens();
    
    # Get current Copilot token (with auto-refresh)
    my $token = $auth->get_copilot_token();

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        # Use GitHub's official Copilot Plugin GitHub App
        # This enables token exchange for full model access (42+ models)
        client_id => $args{client_id} || 'Iv1.b507a08c87ecfe98',
        debug => $args{debug} || 0,
        ua => CLIO::Compat::HTTP->new(
            agent => 'CLIO/2.0.0',
            timeout => 30,
        ),
        tokens_file => get_config_file('github_tokens.json'),
    };
    
    bless $self, $class;
    
    # Ensure tokens directory exists (get_config_dir creates it automatically)
    get_config_dir();
    
    return $self;
}

=head2 start_device_flow

Request device and user codes from GitHub.

Returns hashref with:
- device_code: Used for polling
- user_code: Display to user
- verification_uri: URL for user to visit
- expires_in: Expiration time in seconds
- interval: Polling interval in seconds

=cut

sub start_device_flow {
    my ($self) = @_;
    
    log_info('GitHubAuth', "Starting GitHub device authorization flow");
    
    my $url = 'https://github.com/login/device/code';
    
    my $request = HTTP::Request->new(POST => $url);
    $request->header('Accept' => 'application/json');
    $request->header('Content-Type' => 'application/json');
    
    my $body = encode_json({
        client_id => $self->{client_id},
        scope => 'read:user',  # Minimal scope - Copilot access is via token exchange
    });
    
    $request->content($body);
    
    my $response = $self->{ua}->request($request);
    
    unless ($response->is_success) {
        my $status = $response->code;
        my $error = $response->decoded_content || 'Unknown error';
        log_error('GitHubAuth', "Device code request failed: HTTP $status - $error");
        die "Device code request failed: HTTP $status";
    }
    
    my $data = decode_json($response->decoded_content);
    
    log_debug('GitHubAuth', "Device code obtained: $data->{user_code}");
    
    return {
        device_code => $data->{device_code},
        user_code => $data->{user_code},
        verification_uri => $data->{verification_uri},
        expires_in => $data->{expires_in},
        interval => $data->{interval},
    };
}

=head2 poll_for_token

Poll GitHub for access token until user authorizes.

Arguments:
- $device_code: Device code from start_device_flow
- $interval: Polling interval in seconds (default 5)

Returns: GitHub access token string

Dies on timeout, denial, or error.

=cut

sub poll_for_token {
    my ($self, $device_code, $interval) = @_;
    
    $interval //= 5;
    $interval = 5 if $interval < 5;  # Minimum 5 seconds
    
    my $url = 'https://github.com/login/oauth/access_token';
    my $timeout = time() + 900;  # 15 minutes (GitHub device codes expire after 15 min)
    
    log_info('GitHubAuth', "Polling for access token (15min timeout)...");
    
    # Track next poll time to avoid polling too fast
    my $next_poll_time = time();
    
    while (time() < $timeout) {
        # Wait until next poll time (interruptible sleep for Ctrl-C)
        while (time() < $next_poll_time) {
            my $remaining = $next_poll_time - time();
            last if $remaining <= 0;
            sleep(1);  # Sleep in 1-second increments for responsiveness
        }
        
        # Set next poll time BEFORE making request (so slow_down is respected)
        $next_poll_time = time() + $interval;
        
        my $request = HTTP::Request->new(POST => $url);
        $request->header('Accept' => 'application/json');
        $request->header('Content-Type' => 'application/json');
        
        my $body = encode_json({
            client_id => $self->{client_id},
            device_code => $device_code,
            grant_type => 'urn:ietf:params:oauth:grant-type:device_code',
        });
        
        $request->content($body);
        
        my $response = $self->{ua}->request($request);
        
        unless ($response->is_success) {
            # HTTP error (rare - GitHub usually returns 200 with error in body)
            log_error('GitHubAuth.pm', "[WARN]GitHubAuth] HTTP error during polling: " . $response->code . "");
            next;  # Will wait at top of loop
        }
        
        my $data = decode_json($response->decoded_content);
        
        # DEBUG: Log the full response
        log_debug('GitHubAuth', "Poll response: " . $response->decoded_content);
        
        # Check for errors
        if ($data->{error}) {
            my $error = $data->{error};
            
            if ($error eq 'authorization_pending') {
                # User hasn't authorized yet, keep polling
                log_debug('GitHubAuth', "Authorization pending...");
                next;  # Will wait at top of loop
            }
            elsif ($error eq 'slow_down') {
                # Polling too fast - per OAuth spec, PERMANENTLY increase interval by 5 seconds
                $interval += 5;
                # Also push back next poll time by the new interval
                $next_poll_time = time() + $interval;
                log_warning('GitHubAuth', "Polling too fast, increasing interval to ${interval}s");
                next;  # Will wait at top of loop
            }
            elsif ($error eq 'expired_token') {
                # Device code expired
                log_error('GitHubAuth', "Device code expired");
                die "Device code expired. Please try again.";
            }
            elsif ($error eq 'access_denied') {
                # User denied authorization
                log_error('GitHubAuth', "User denied authorization");
                die "Authorization denied by user";
            }
            else {
                # Unknown error
                log_error('GitHubAuth', "Token poll error: $error");
                die "Token poll error: $error";
            }
        }
        
        # Success! We have the access token
        if ($data->{access_token}) {
            log_info('GitHubAuth', "Access token obtained successfully");
            return $data->{access_token};
        }
        
        # No error and no token - unusual, keep polling
        log_debug('GitHubAuth', "No error and no token in response, continuing...");
    }
    
    # Timeout reached
    log_error('GitHubAuth', "Authorization timed out after 15 minutes");
    die "Authorization timed out after 15 minutes. Please try again.";
}

=head2 exchange_for_copilot_token

Exchange GitHub user token for Copilot-specific token.
This token has access to billing metadata and Copilot features.

If exchange fails (404), returns undef - caller should use GitHub token directly.

Arguments:
- $github_token: GitHub access token from device flow

Returns: Hashref with Copilot token data, or undef if exchange unavailable:
- token: Copilot access token
- expires_at: Unix timestamp when token expires
- refresh_in: Seconds until refresh recommended
- username: GitHub username (optional)

=cut

sub exchange_for_copilot_token {
    my ($self, $github_token) = @_;
    
    log_info('GitHubAuth', "Exchanging GitHub token for Copilot token");
    
    my $url = 'https://api.github.com/copilot_internal/v2/token';
    
    # Note: This endpoint requires GET, not POST
    my $request = HTTP::Request->new(GET => $url);
    $request->header('Authorization' => "token $github_token");
    $request->header('Editor-Version' => 'vscode/2.0.0');
    $request->header('User-Agent' => 'GitHubCopilotChat/2.0.0');
    
    my $response = $self->{ua}->request($request);
    
    unless ($response->is_success) {
        my $status = $response->code;
        my $error = $response->decoded_content || 'Unknown error';
        
        # 404 means endpoint not available - this is OK, we'll use GitHub token directly
        if ($status == 404) {
            log_info('GitHubAuth', "Copilot token endpoint not available (404), will use GitHub token directly");
            return undef;
        }
        
        # Other errors are real failures
        log_error('GitHubAuth', "Copilot token exchange failed: HTTP $status - $error");
        die "Copilot token exchange failed: HTTP $status - $error";
    }
    
    my $data = decode_json($response->decoded_content);
    
    log_info('GitHubAuth', "Copilot token obtained, expires in $data->{refresh_in}s");
    
    return {
        token => $data->{token},
        expires_at => $data->{expires_at},
        refresh_in => $data->{refresh_in},
        username => $data->{username},
    };
}

=head2 save_tokens

Save GitHub and Copilot tokens to disk.

Arguments:
- $github_token: GitHub access token (string)
- $copilot_token: Copilot token data (hashref from exchange_for_copilot_token)

=cut

sub save_tokens {
    my ($self, $github_token, $copilot_token) = @_;
    
    my $data = {
        github_token => $github_token,
        copilot_token => $copilot_token,
        saved_at => time(),
    };
    
    my $json = encode_json($data);
    
    open my $fh, '>', $self->{tokens_file}
        or croak "Cannot write tokens file: $!";
    print $fh $json;
    close $fh;
    
    # Set restrictive permissions (600 - owner read/write only)
    chmod 0600, $self->{tokens_file};
    
    # Clear models cache - new tokens may have different model access
    eval {
        require CLIO::Core::ConfigPath;
        my $cache_file = CLIO::Core::ConfigPath::get_config_file('models_cache.json');
        if ($cache_file && -f $cache_file) {
            unlink $cache_file;
            log_debug('GitHubAuth', "Cleared models cache after token update");
        }
    };
    
    log_debug('GitHubAuth', "Tokens saved to $self->{tokens_file}");
}

=head2 load_tokens

Load GitHub and Copilot tokens from disk.

Returns: Hashref with:
- github_token: GitHub access token (string)
- copilot_token: Copilot token data (hashref)
- saved_at: Unix timestamp when saved

Returns undef if tokens file doesn't exist or is invalid.

=cut

sub load_tokens {
    my ($self) = @_;
    
    return undef unless -f $self->{tokens_file};
    
    my $data;
    eval {
        open my $fh, '<', $self->{tokens_file}
            or croak "Cannot read tokens file: $!";
        my $json = do { local $/; <$fh> };
        close $fh;
        
        $data = decode_json($json);
        
        log_debug('GitHubAuth', "Tokens loaded from $self->{tokens_file}");
    };
    
    if ($@) {
        log_warning('GitHubAuth', "Failed to load tokens: $@");
        return undef;
    }
    
    return $data;
}

=head2 get_copilot_token

Get current Copilot token, refreshing if expired.

Priority order:
1. PAT from config (if set via /api set github_pat)
2. Copilot token from OAuth flow (with auto-refresh)
3. GitHub token from OAuth flow (fallback)

Returns: Token string (PAT, Copilot, or GitHub), or undef if not authenticated.

=cut

sub get_copilot_token {
    my ($self) = @_;
    
    # Priority 1: Check for PAT in config (returns more models)
    my $pat;
    eval {
        require CLIO::Core::Config;
        my $config = CLIO::Core::Config->new(debug => $self->{debug});
        $pat = $config->get('github_pat');
    };
    if ($pat && $pat =~ /^(ghp_|ghu_|github_pat_)/) {
        log_debug('GitHubAuth', "Using PAT from config");
        
        # PAT/ghu_ tokens need to be exchanged for a copilot session token
        # This gives access to more models (37+ vs 31)
        my $exchanged = $self->exchange_for_copilot_token($pat);
        if ($exchanged && $exchanged->{token}) {
            log_debug('GitHubAuth', "Exchanged PAT for copilot token (full model access)");
            # Store that we're using an exchanged token (requires Editor-Version header)
            $self->{using_exchanged_token} = 1;
            return $exchanged->{token};
        }
        
        # If exchange fails, return PAT directly (may have limited access)
        log_warning('GitHubAuth', "PAT exchange failed, using PAT directly");
        return $pat;
    }
    # Ignore config errors, fall through to OAuth tokens
    
    my $tokens = $self->load_tokens();
    return undef unless $tokens;
    
    my $copilot = $tokens->{copilot_token};
    
    # If we have a Copilot token, use it (with refresh check)
    if ($copilot) {
        # Exchanged tokens (tid=) require Editor-Version header for API access
        $self->{using_exchanged_token} = 1;
        
        # Check if expired (with 5 minute buffer)
        my $now = time();
        if (($copilot->{expires_at} - 300) < $now) {
            log_info('GitHubAuth', "Copilot token expired, refreshing...");
            
            # Refresh by exchanging GitHub token again
            # NOTE: Do NOT use 'return' inside eval{} - it returns from eval, not the sub!
            my $refreshed_token;
            eval {
                my $new_copilot = $self->exchange_for_copilot_token($tokens->{github_token});
                if ($new_copilot) {
                    $self->save_tokens($tokens->{github_token}, $new_copilot);
                    $refreshed_token = $new_copilot->{token};
                } else {
                    # Exchange failed (404), fall back to GitHub token
                    log_info('GitHubAuth', "Copilot exchange unavailable, using GitHub token");
                    $self->{using_exchanged_token} = 0;
                    $refreshed_token = $tokens->{github_token};
                }
            };
            
            if ($@) {
                log_warning('GitHubAuth', "Token refresh failed: $@, using GitHub token");
                $self->{using_exchanged_token} = 0;
                return $tokens->{github_token};
            }
            
            return $refreshed_token if $refreshed_token;
        }
        
        return $copilot->{token};
    }
    
    # No Copilot token - try to exchange GitHub token first
    if ($tokens->{github_token}) {
        log_info('GitHubAuth', "No Copilot token, attempting exchange...");
        my $exchanged = eval { $self->exchange_for_copilot_token($tokens->{github_token}) };
        if ($exchanged && $exchanged->{token}) {
            log_info('GitHubAuth', "Exchange succeeded, saving Copilot token");
            eval { $self->save_tokens($tokens->{github_token}, $exchanged) };
            $self->{using_exchanged_token} = 1;
            return $exchanged->{token};
        }
        
        # Exchange failed - use raw token (limited model access)
        log_debug('GitHubAuth', "Exchange failed, using GitHub token directly");
        return $tokens->{github_token};
    }
    
    # No token at all
    return undef;
}

=head2 is_authenticated

Check if user is authenticated with valid tokens.

Returns: Boolean (true if PAT is set or OAuth tokens exist)

=cut

sub is_authenticated {
    my ($self) = @_;
    
    # Check for PAT first
    my $pat;
    eval {
        require CLIO::Core::Config;
        my $config = CLIO::Core::Config->new(debug => $self->{debug});
        $pat = $config->get('github_pat');
    };
    if ($pat && $pat =~ /^(ghp_|ghu_|github_pat_)/) {
        return 1;
    }
    
    # Fall back to OAuth tokens
    my $tokens = $self->load_tokens();
    return 0 unless $tokens;
    return 0 unless $tokens->{github_token};
    return 0 unless $tokens->{copilot_token};
    
    return 1;
}

=head2 get_username

Get GitHub username from Copilot token.

Returns: Username string, or undef if not available.

=cut

sub get_username {
    my ($self) = @_;
    
    my $tokens = $self->load_tokens();
    return undef unless $tokens;
    return $tokens->{copilot_token}{username};
}

=head2 clear_tokens

Sign out by deleting stored tokens.

=cut

sub clear_tokens {
    my ($self) = @_;
    
    if (-f $self->{tokens_file}) {
        unlink $self->{tokens_file}
            or warn "Failed to delete tokens file: $!";
        log_info('GitHubAuth', "Tokens cleared, user signed out");
    }
    
    # Clear models cache - stale cache would show wrong model list
    eval {
        require CLIO::Core::ConfigPath;
        my $cache_file = CLIO::Core::ConfigPath::get_config_file('models_cache.json');
        if ($cache_file && -f $cache_file) {
            unlink $cache_file;
            log_debug('GitHubAuth', "Cleared models cache after sign out");
        }
    };
}

=head2 needs_reauth

Check if stored tokens need re-authentication (e.g., from old OAuth App).

Returns: String with reason if re-auth needed, undef if OK.

This is used for one-time migration notices when the authentication
system changes (e.g., switching OAuth Apps).

=cut

sub needs_reauth {
    my ($self) = @_;
    
    my $tokens = $self->load_tokens();
    return undef unless $tokens;
    return undef unless $tokens->{github_token};
    
    # Check for old OAuth App tokens (gho_ prefix = OAuth App user token)
    # New GitHub App tokens use ghu_ prefix
    if ($tokens->{github_token} =~ /^gho_/) {
        return "Your GitHub token was created with an older authentication method "
             . "that provides limited model access. Please run /api logout then "
             . "/api login to upgrade to the new authentication with full model "
             . "access (42+ models including Claude, Gemini, and GPT-5).";
    }
    
    # Check for missing copilot_token (exchange may have failed)
    if (!$tokens->{copilot_token} && $tokens->{github_token} =~ /^ghu_/) {
        # Try exchanging now
        my $result = eval { $self->exchange_for_copilot_token($tokens->{github_token}) };
        if ($result) {
            # Exchange succeeded - save and clear the warning
            eval { $self->save_tokens($tokens->{github_token}, $result) };
            return undef;
        }
        # Exchange failed with ghu_ token - something else is wrong
        return "Your GitHub token could not be exchanged for a Copilot session token. "
             . "Please run /api logout then /api login to re-authenticate.";
    }
    
    return undef;
}

=head2 validate_github_token

Validate that the stored GitHub token is still valid by making a test API call.

Returns: Hashref with:
- valid: Boolean (true if token works)
- username: GitHub username if valid
- error: Error message if invalid
- status: HTTP status code if request was made

=cut

sub validate_github_token {
    my ($self) = @_;
    
    my $tokens = $self->load_tokens();
    unless ($tokens && $tokens->{github_token}) {
        return { valid => 0, error => 'No GitHub token stored' };
    }
    
    my $github_token = $tokens->{github_token};
    
    # Validate by hitting GitHub's user endpoint (lightweight)
    my $url = 'https://api.github.com/user';
    my $request = HTTP::Request->new(GET => $url);
    $request->header('Authorization' => "token $github_token");
    $request->header('User-Agent' => 'CLIO/2.0.0');
    $request->header('Accept' => 'application/json');
    
    my $response = eval { $self->{ua}->request($request) };
    
    if ($@) {
        return { valid => 0, error => "Network error: $@" };
    }
    
    my $status = $response->code;
    
    if ($response->is_success) {
        my $data = eval { decode_json($response->decoded_content) };
        my $username = $data ? ($data->{login} || 'unknown') : 'unknown';
        log_debug('GitHubAuth', "GitHub token validated - user: $username");
        return { valid => 1, username => $username, status => $status };
    }
    
    if ($status == 401) {
        log_warning('GitHubAuth', "GitHub token is invalid/expired (401)");
        return { valid => 0, error => 'Token invalid or expired', status => $status };
    }
    
    if ($status == 403) {
        log_warning('GitHubAuth', "GitHub token lacks permissions (403)");
        return { valid => 0, error => 'Token lacks required permissions', status => $status };
    }
    
    # Other status - network issue or GitHub outage
    return { valid => 0, error => "Unexpected HTTP $status", status => $status };
}

=head2 force_refresh_copilot_token

Force-refresh the Copilot session token using the stored GitHub token.
Used when APIManager detects auth failures and needs a fresh token.

Returns: Fresh token string, or undef if refresh fails.

=cut

sub force_refresh_copilot_token {
    my ($self) = @_;
    
    my $tokens = $self->load_tokens();
    unless ($tokens && $tokens->{github_token}) {
        log_warning('GitHubAuth', "Cannot refresh - no GitHub token stored");
        return undef;
    }
    
    log_info('GitHubAuth', "Force-refreshing Copilot session token");
    
    my $new_copilot = eval { $self->exchange_for_copilot_token($tokens->{github_token}) };
    
    if ($@ || !$new_copilot) {
        my $error = $@ || 'Exchange returned undef';
        log_debug('GitHubAuth', "Force-refresh failed: $error (caller will try fallback)");
        return undef;
    }
    
    # Save the refreshed token
    eval { $self->save_tokens($tokens->{github_token}, $new_copilot) };
    if ($@) {
        log_warning('GitHubAuth', "Failed to save refreshed token: $@");
    }
    
    $self->{using_exchanged_token} = 1;
    log_info('GitHubAuth', "Copilot token refreshed successfully");
    
    return $new_copilot->{token};
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

GPL-3.0-only

=cut

1;
