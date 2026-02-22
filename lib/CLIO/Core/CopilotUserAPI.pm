package CLIO::Core::CopilotUserAPI;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use CLIO::Core::Logger qw(should_log);
use CLIO::Util::ConfigPath qw(get_config_file);
use CLIO::Util::JSON qw(encode_json decode_json);
use CLIO::Compat::HTTP;

=head1 NAME

CLIO::Core::CopilotUserAPI - GitHub Copilot User API client

=head1 DESCRIPTION

Fetches user and quota information from GitHub's internal Copilot API.

API endpoint: GET https://api.github.com/copilot_internal/user

This endpoint provides comprehensive user data including:
- User info (login, copilot_plan, access_type_sku)
- Quota snapshots (entitlement, remaining, percent_remaining, unlimited)
- Overage tracking (overage_count, overage_permitted)
- Reset dates (quota_reset_date_utc)
- Endpoints configuration (api, proxy, etc.)

Based on reference implementation from onwatch (internal/api/copilot_client.go).

=head1 SYNOPSIS

    use CLIO::Core::CopilotUserAPI;
    
    my $api = CLIO::Core::CopilotUserAPI->new(debug => 1);
    
    # Fetch complete user data
    my $user = $api->fetch_user();
    
    # Get quota for premium requests
    my $quota = $user->get_quota('premium_interactions');
    print "Used: ", $quota->{used}, " of ", $quota->{entitlement}, "\n";
    
    # Check if quota is available without making API call (cached)
    my $cached = $api->get_cached_user();

=cut

# Custom errors
our $ERR_UNAUTHORIZED = 'copilot_user: unauthorized - invalid token';
our $ERR_FORBIDDEN = 'copilot_user: forbidden - token revoked or missing scope';
our $ERR_SERVER_ERROR = 'copilot_user: server error';
our $ERR_NETWORK_ERROR = 'copilot_user: network error';
our $ERR_INVALID_RESPONSE = 'copilot_user: invalid response';

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug => $args{debug} || 0,
        cache_ttl => $args{cache_ttl} || 300,  # 5 minutes default
        cache_file => $args{cache_file} || get_config_file('copilot_user_cache.json'),
        base_url => 'https://api.github.com/copilot_internal/user',
        ua => CLIO::Compat::HTTP->new(
            agent => 'CLIO/2.0.0',
            timeout => 30,
        ),
    };
    
    bless $self, $class;
    return $self;
}

=head2 fetch_user($token)

Fetch user and quota data from the Copilot API.

Arguments:
- $token: GitHub token (PAT or OAuth token). If not provided, gets from GitHubAuth.

Returns: CopilotUserData object, or undef on error.

Sets $@ with error message on failure.

=cut

sub fetch_user {
    my ($self, $token) = @_;
    
    # Get token if not provided
    unless ($token) {
        eval {
            require CLIO::Core::GitHubAuth;
            my $auth = CLIO::Core::GitHubAuth->new(debug => $self->{debug});
            
            # Try GitHub token first (for user endpoint, not copilot token)
            my $tokens = $auth->load_tokens();
            $token = $tokens->{github_token} if $tokens;
            
            # Note: We do NOT fall back to Config->get('github_pat') here
            # because it creates a circular dependency: Config->load() calls
            # _get_copilot_user_api_endpoint() which calls this method, which
            # would then call Config->new() again -> infinite recursion.
            # GitHubAuth is the proper token source.
        };
        
        unless ($token) {
            $@ = "No GitHub token available. Run /api login first.";
            return undef;
        }
    }
    
    print STDERR "[DEBUG][CopilotUserAPI] Fetching user data from $self->{base_url}\n"
        if $self->{debug};
    
    my $req = HTTP::Request->new(GET => $self->{base_url});
    $req->header('Authorization' => "token $token");
    $req->header('Accept' => 'application/json');
    $req->header('User-Agent' => 'CLIO/2.0.0');
    
    my $resp = $self->{ua}->request($req);
    
    # Handle HTTP errors
    unless ($resp->is_success) {
        my $status = $resp->code;
        
        if ($status == 401) {
            $@ = $ERR_UNAUTHORIZED;
        } elsif ($status == 403) {
            $@ = $ERR_FORBIDDEN;
        } elsif ($status >= 500) {
            $@ = $ERR_SERVER_ERROR;
        } else {
            $@ = "copilot_user: unexpected status code $status";
        }
        
        print STDERR "[ERROR][CopilotUserAPI] $@\n" if should_log('ERROR');
        return undef;
    }
    
    # Parse response
    my $body = $resp->decoded_content;
    
    if (!$body || length($body) == 0) {
        $@ = "$ERR_INVALID_RESPONSE: empty response body";
        return undef;
    }
    
    my $data = eval { decode_json($body) };
    if ($@) {
        $@ = "$ERR_INVALID_RESPONSE: $@";
        return undef;
    }
    
    # Create user data object
    my $user = CLIO::Core::CopilotUserData->new($data);
    
    # Cache the response
    $self->_save_cache($data);
    
    print STDERR "[DEBUG][CopilotUserAPI] User data fetched: login=$user->{login}, plan=$user->{copilot_plan}\n"
        if $self->{debug};
    
    return $user;
}

=head2 get_cached_user()

Get cached user data if available and not expired.

Returns: CopilotUserData object, or undef if cache is stale/missing.

=cut

sub get_cached_user {
    my ($self) = @_;
    
    my $cached = $self->_load_cache();
    return undef unless $cached;
    
    return CLIO::Core::CopilotUserData->new($cached);
}

=head2 _save_cache($data)

Save user data to cache file.

=cut

sub _save_cache {
    my ($self, $data) = @_;
    
    my $cache = {
        data => $data,
        cached_at => time(),
    };
    
    eval {
        open my $fh, '>:encoding(UTF-8)', $self->{cache_file}
            or die "Cannot write cache: $!";
        print $fh encode_json($cache);
        close $fh;
        chmod 0600, $self->{cache_file};
    };
    
    if ($@) {
        print STDERR "[WARN][CopilotUserAPI] Failed to save cache: $@\n" if should_log('WARNING');
    }
}

=head2 _load_cache()

Load user data from cache file if valid.

Returns: Cached data hashref, or undef if expired/missing.

=cut

sub _load_cache {
    my ($self) = @_;
    
    return undef unless -f $self->{cache_file};
    
    my $cache;
    eval {
        open my $fh, '<:encoding(UTF-8)', $self->{cache_file}
            or die "Cannot read cache: $!";
        my $json = do { local $/; <$fh> };
        close $fh;
        
        $cache = decode_json($json);
    };
    
    return undef if $@;
    return undef unless $cache && $cache->{data};
    
    # Check TTL
    my $age = time() - ($cache->{cached_at} || 0);
    if ($age > $self->{cache_ttl}) {
        print STDERR "[DEBUG][CopilotUserAPI] Cache expired (age=${age}s, ttl=$self->{cache_ttl}s)\n"
            if $self->{debug};
        return undef;
    }
    
    print STDERR "[DEBUG][CopilotUserAPI] Using cached user data (age=${age}s)\n"
        if $self->{debug};
    
    return $cache->{data};
}

=head2 clear_cache()

Clear the cached user data.

=cut

sub clear_cache {
    my ($self) = @_;
    
    if (-f $self->{cache_file}) {
        unlink $self->{cache_file};
        print STDERR "[DEBUG][CopilotUserAPI] Cache cleared\n" if $self->{debug};
    }
}

#=============================================================================
# CopilotUserData - Structured response object
#=============================================================================

package CLIO::Core::CopilotUserData;

use strict;
use warnings;

=head1 NAME

CLIO::Core::CopilotUserData - Parsed Copilot user response

=head1 DESCRIPTION

Represents the parsed response from /copilot_internal/user endpoint.
Provides convenient accessors for quota data.

=cut

sub new {
    my ($class, $data) = @_;
    
    my $self = {
        # User info
        login => $data->{login} || '',
        copilot_plan => $data->{copilot_plan} || 'unknown',
        access_type_sku => $data->{access_type_sku} || '',
        
        # Reset dates
        quota_reset_date => $data->{quota_reset_date} || '',
        quota_reset_date_utc => $data->{quota_reset_date_utc} || '',
        
        # Raw quota snapshots
        quota_snapshots => $data->{quota_snapshots} || {},
        
        # Endpoints
        endpoints => $data->{endpoints} || {},
        
        # Raw data for debugging
        _raw => $data,
    };
    
    bless $self, $class;
    return $self;
}

=head2 get_quota($name)

Get quota data for a specific quota type.

Arguments:
- $name: Quota name (e.g., 'premium_interactions', 'chat', 'completions')

Returns: Hashref with:
- name: Quota name
- entitlement: Total quota limit
- remaining: Remaining count
- used: Used count (calculated)
- percent_remaining: Percentage remaining
- percent_used: Percentage used (calculated)
- unlimited: Boolean
- overage_count: Overage used beyond entitlement
- overage_permitted: Boolean
- quota_id: Internal ID
- timestamp_utc: Snapshot timestamp

Returns undef if quota not found.

=cut

sub get_quota {
    my ($self, $name) = @_;
    
    my $snapshot = $self->{quota_snapshots}{$name};
    return undef unless $snapshot;
    
    my $entitlement = $snapshot->{entitlement} || 0;
    my $remaining = $snapshot->{remaining} || 0;
    my $percent_remaining = $snapshot->{percent_remaining} || 0;
    
    # Calculate used directly from entitlement - remaining (no percentage calculation needed)
    # The user API provides the actual remaining count, not just percentage
    my $used = $entitlement > 0 ? ($entitlement - $remaining) : 0;
    $used = 0 if $used < 0;  # Safety: ensure non-negative
    
    return {
        name => $name,
        entitlement => $entitlement,
        remaining => $remaining,
        used => $used,
        percent_remaining => $percent_remaining,
        percent_used => 100.0 - $percent_remaining,
        unlimited => $snapshot->{unlimited} || 0,
        overage_count => $snapshot->{overage_count} || 0,
        overage_permitted => $snapshot->{overage_permitted} || 0,
        quota_id => $snapshot->{quota_id} || '',
        timestamp_utc => $snapshot->{timestamp_utc} || '',
    };
}

=head2 get_premium_quota()

Get the premium interactions quota (most commonly needed).

Returns: Quota hashref from get_quota('premium_interactions'), or undef.

=cut

sub get_premium_quota {
    my ($self) = @_;
    return $self->get_quota('premium_interactions');
}

=head2 get_all_quotas()

Get all available quota types.

Returns: Array of quota names.

=cut

sub get_all_quotas {
    my ($self) = @_;
    return sort keys %{$self->{quota_snapshots}};
}

=head2 get_api_endpoint()

Get the user-specific API endpoint URL.

Returns: API URL string, or default if not available.

=cut

sub get_api_endpoint {
    my ($self) = @_;
    return $self->{endpoints}{api} || 'https://api.githubcopilot.com';
}

=head2 get_display_name($quota_name)

Get human-readable display name for a quota type.

=cut

my %DISPLAY_NAMES = (
    premium_interactions => 'Premium Requests',
    chat => 'Chat',
    completions => 'Completions',
);

sub get_display_name {
    my ($self, $name) = @_;
    return $DISPLAY_NAMES{$name} || $name;
}

=head2 is_pro_plus()

Check if user has Pro+ plan (higher quota).

=cut

sub is_pro_plus {
    my ($self) = @_;
    return $self->{copilot_plan} =~ /pro_plus|individual_pro_plus/i;
}

=head2 is_business()

Check if user has Business plan.

=cut

sub is_business {
    my ($self) = @_;
    return $self->{copilot_plan} =~ /business|enterprise/i;
}

=head2 to_hash()

Convert to plain hash for serialization.

=cut

sub to_hash {
    my ($self) = @_;
    
    return {
        login => $self->{login},
        copilot_plan => $self->{copilot_plan},
        access_type_sku => $self->{access_type_sku},
        quota_reset_date_utc => $self->{quota_reset_date_utc},
        quotas => {
            map { 
                $_ => $self->get_quota($_) 
            } $self->get_all_quotas()
        },
        api_endpoint => $self->get_api_endpoint(),
    };
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 SEE ALSO

L<CLIO::Core::GitHubAuth> - Token management
L<CLIO::Core::GitHubCopilotModelsAPI> - Model information

=cut
