package CLIO::Core::GitHubAuth;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use CLIO::Util::ConfigPath qw(get_config_file get_config_dir);
use JSON::PP qw(encode_json decode_json);
use CLIO::Compat::HTTP;
use Time::HiRes qw(sleep time);
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
        client_id => 'Ov23lix5mfpW4hHM7y9G',  # SAM's GitHub OAuth app
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
        # Use SAM's OAuth App - we control this, it's trustworthy
        # Users who want more models (37 vs 31) can use /api set github_pat
        client_id => $args{client_id} || 'Ov23lix5mfpW4hHM7y9G',
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
    
    print STDERR "[INFO][GitHubAuth] Starting GitHub device authorization flow\n" if should_log('INFO');
    
    my $url = 'https://github.com/login/device/code';
    
    my $request = HTTP::Request->new(POST => $url);
    $request->header('Accept' => 'application/json');
    $request->header('Content-Type' => 'application/json');
    
    my $body = encode_json({
        client_id => $self->{client_id},
        scope => 'read:user user:email repo workflow copilot',  # Include copilot scope for model access
    });
    
    $request->content($body);
    
    my $response = $self->{ua}->request($request);
    
    unless ($response->is_success) {
        my $status = $response->code;
        my $error = $response->decoded_content || 'Unknown error';
        print STDERR "[ERROR][GitHubAuth] Device code request failed: HTTP $status - $error\n" if should_log('ERROR');
        die "Device code request failed: HTTP $status";
    }
    
    my $data = decode_json($response->decoded_content);
    
    print STDERR "[DEBUG][GitHubAuth] Device code obtained: $data->{user_code}\n" if should_log('DEBUG');
    
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
    
    print STDERR "[INFO][GitHubAuth] Polling for access token (15min timeout)...\n" if should_log('INFO');
    
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
            print STDERR "[WARN]GitHubAuth] HTTP error during polling: " . $response->code . "\n" if should_log('WARNING');
            next;  # Will wait at top of loop
        }
        
        my $data = decode_json($response->decoded_content);
        
        # DEBUG: Log the full response
        print STDERR "[DEBUG][GitHubAuth] Poll response: " . $response->decoded_content . "\n" if should_log('DEBUG');
        
        # Check for errors
        if ($data->{error}) {
            my $error = $data->{error};
            
            if ($error eq 'authorization_pending') {
                # User hasn't authorized yet, keep polling
                print STDERR "[DEBUG][GitHubAuth] Authorization pending...\n" if should_log('DEBUG');
                next;  # Will wait at top of loop
            }
            elsif ($error eq 'slow_down') {
                # Polling too fast - per OAuth spec, PERMANENTLY increase interval by 5 seconds
                $interval += 5;
                # Also push back next poll time by the new interval
                $next_poll_time = time() + $interval;
                print STDERR "[WARN]GitHubAuth] Polling too fast, increasing interval to ${interval}s\n" if should_log('WARNING');
                next;  # Will wait at top of loop
            }
            elsif ($error eq 'expired_token') {
                # Device code expired
                print STDERR "[ERROR][GitHubAuth] Device code expired\n" if should_log('ERROR');
                die "Device code expired. Please try again.";
            }
            elsif ($error eq 'access_denied') {
                # User denied authorization
                print STDERR "[ERROR][GitHubAuth] User denied authorization\n" if should_log('ERROR');
                die "Authorization denied by user";
            }
            else {
                # Unknown error
                print STDERR "[ERROR][GitHubAuth] Token poll error: $error\n" if should_log('ERROR');
                die "Token poll error: $error";
            }
        }
        
        # Success! We have the access token
        if ($data->{access_token}) {
            print STDERR "[INFO][GitHubAuth] Access token obtained successfully\n" if should_log('INFO');
            return $data->{access_token};
        }
        
        # No error and no token - unusual, keep polling
        print STDERR "[DEBUG][GitHubAuth] No error and no token in response, continuing...\n" if should_log('DEBUG');
    }
    
    # Timeout reached
    print STDERR "[ERROR][GitHubAuth] Authorization timed out after 15 minutes\n" if should_log('ERROR');
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
    
    print STDERR "[INFO][GitHubAuth] Exchanging GitHub token for Copilot token\n" if should_log('INFO');
    
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
            print STDERR "[INFO][GitHubAuth] Copilot token endpoint not available (404), will use GitHub token directly\n" if should_log('INFO');
            return undef;
        }
        
        # Other errors are real failures
        print STDERR "[ERROR][GitHubAuth] Copilot token exchange failed: HTTP $status - $error\n" if should_log('ERROR');
        die "Copilot token exchange failed: HTTP $status - $error";
    }
    
    my $data = decode_json($response->decoded_content);
    
    print STDERR "[INFO][GitHubAuth] Copilot token obtained, expires in $data->{refresh_in}s\n" if should_log('INFO');
    
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
        or die "Cannot write tokens file: $!";
    print $fh $json;
    close $fh;
    
    # Set restrictive permissions (600 - owner read/write only)
    chmod 0600, $self->{tokens_file};
    
    print STDERR "[DEBUG][GitHubAuth] Tokens saved to $self->{tokens_file}\n" if should_log('DEBUG');
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
            or die "Cannot read tokens file: $!";
        my $json = do { local $/; <$fh> };
        close $fh;
        
        $data = decode_json($json);
        
        print STDERR "[DEBUG][GitHubAuth] Tokens loaded from $self->{tokens_file}\n" if should_log('DEBUG');
    };
    
    if ($@) {
        print STDERR "[WARN]GitHubAuth] Failed to load tokens: $@\n" if should_log('WARNING');
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
        print STDERR "[DEBUG][GitHubAuth] Using PAT from config\n" if should_log('DEBUG');
        
        # PAT/ghu_ tokens need to be exchanged for a copilot session token
        # This gives access to more models (37+ vs 31)
        my $exchanged = $self->exchange_for_copilot_token($pat);
        if ($exchanged && $exchanged->{token}) {
            print STDERR "[DEBUG][GitHubAuth] Exchanged PAT for copilot token (full model access)\n" if should_log('DEBUG');
            # Store that we're using an exchanged token (requires Editor-Version header)
            $self->{using_exchanged_token} = 1;
            return $exchanged->{token};
        }
        
        # If exchange fails, return PAT directly (may have limited access)
        print STDERR "[WARN][GitHubAuth] PAT exchange failed, using PAT directly\n" if should_log('WARNING');
        return $pat;
    }
    # Ignore config errors, fall through to OAuth tokens
    
    my $tokens = $self->load_tokens();
    return undef unless $tokens;
    
    my $copilot = $tokens->{copilot_token};
    
    # If we have a Copilot token, use it (with refresh check)
    if ($copilot) {
        # Check if expired (with 5 minute buffer)
        my $now = time();
        if (($copilot->{expires_at} - 300) < $now) {
            print STDERR "[INFO][GitHubAuth] Copilot token expired, refreshing...\n" if should_log('INFO');
            
            # Refresh by exchanging GitHub token again
            eval {
                my $new_copilot = $self->exchange_for_copilot_token($tokens->{github_token});
                if ($new_copilot) {
                    $self->save_tokens($tokens->{github_token}, $new_copilot);
                    return $new_copilot->{token};
                } else {
                    # Exchange failed (404), fall back to GitHub token
                    print STDERR "[INFO][GitHubAuth] Copilot exchange unavailable, using GitHub token\n" if should_log('INFO');
                    return $tokens->{github_token};
                }
            };
            
            if ($@) {
                print STDERR "[WARN]GitHubAuth] Token refresh failed: $@, using GitHub token\n" if should_log('WARNING');
                return $tokens->{github_token};
            }
        }
        
        return $copilot->{token};
    }
    
    # No Copilot token - fall back to GitHub token
    if ($tokens->{github_token}) {
        print STDERR "[DEBUG][GitHubAuth] Using GitHub token (no Copilot token available)\n" if should_log('DEBUG');
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
        print STDERR "[INFO][GitHubAuth] Tokens cleared, user signed out\n" if should_log('INFO');
    }
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

GPL-3.0-only

=cut

1;
