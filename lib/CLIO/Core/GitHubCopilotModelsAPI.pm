package CLIO::Core::GitHubCopilotModelsAPI;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use JSON::PP qw(encode_json decode_json);
use CLIO::Compat::HTTP;
use File::Spec;
use File::Basename;

# SSL CA bundle setup
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
        }
    }
}

=head1 NAME

CLIO::Core::GitHubCopilotModelsAPI - GitHub Copilot /models API client

=head1 DESCRIPTION

Fetches model information from GitHub Copilot's /models endpoint.
Provides model capabilities and billing multipliers.

API endpoint: GET https://api.githubcopilot.com/models

=head1 SYNOPSIS

    use CLIO::Core::GitHubCopilotModelsAPI;
    
    my $api = CLIO::Core::GitHubCopilotModelsAPI->new(debug => 1);
    my $billing = $api->get_model_billing('gpt-4.1');
    
    print "Model: $billing->{is_premium} ? 'Premium' : 'Free'\n";
    print "Multiplier: ", $billing->{multiplier} || 0, "x\n";

=cut

sub new {
    my ($class, %args) = @_;
    
    my $cache_dir = File::Spec->catdir($ENV{HOME}, '.clio');
    my $cache_file = File::Spec->catfile($cache_dir, 'models_cache.json');
    
    # If api_key not provided, try to get it from GitHubAuth
    my $api_key = $args{api_key};
    unless ($api_key) {
        eval {
            require CLIO::Core::GitHubAuth;
            my $auth = CLIO::Core::GitHubAuth->new(debug => $args{debug} || 0);
            $api_key = $auth->get_copilot_token();  # Returns GitHub token if Copilot token unavailable
        };
        if ($@) {
            print STDERR "[WARN][GitHubCopilotModelsAPI] Failed to get GitHub token: $@\n";
        }
    }
    
    my $self = {
        api_key => $api_key,  # API key from parameter or GitHubAuth
        cache_file => $args{cache_file} || $cache_file,
        cache_ttl => $args{cache_ttl} || 3600,  # 1 hour
        debug => $args{debug} || 0,
    };
    
    return bless $self, $class;
}

=head2 fetch_models

Fetch model list from GitHub Copilot /models API.
Uses cached data if available and not expired.

Returns:
- Hashref with model data from API, or undef on error

=cut

sub fetch_models {
    my ($self) = @_;
    
    # Check if we have an API key
    unless ($self->{api_key}) {
        print STDERR "[WARN][GitHubCopilotModelsAPI] No API key available, cannot fetch models\n";
        return undef;
    }
    
    # Check cache first
    if (my $cached = $self->_load_cache()) {
        print STDERR "[DEBUG][GitHubCopilotModelsAPI] Using cached models data\n" 
            if $self->{debug};
        return $cached;
    }
    
    print STDERR "[DEBUG][GitHubCopilotModelsAPI] Fetching from API\n" 
        if $self->{debug};
    
    # Fetch from API
    my $ua = CLIO::Compat::HTTP->new(timeout => 30);
    my $req = HTTP::Request->new(GET => 'https://api.githubcopilot.com/models');
    $req->header('Authorization' => "Bearer $self->{api_key}");
    $req->header('Editor-Version' => 'vscode/1.96');
    $req->header('Editor-Plugin-Version' => 'copilot-chat/0.22.4');
    $req->header('X-Request-Id' => $self->_generate_uuid());
    $req->header('OpenAI-Intent' => 'model-access');  # CRITICAL: Required for billing metadata
    $req->header('X-GitHub-Api-Version' => '2025-05-01');
    
    my $resp = $ua->request($req);
    
    unless ($resp->is_success) {
        print STDERR "[ERROR][GitHubCopilotModelsAPI] Failed to fetch models: " . 
            $resp->code . " " . $resp->message . "\n";
        return undef;
    }
    
    my $data = eval { decode_json($resp->decoded_content) };
    if ($@) {
        print STDERR "[ERROR][GitHubCopilotModelsAPI] Failed to parse JSON: $@\n";
        return undef;
    }
    
    # Cache the response
    $self->_save_cache($data);
    
    print STDERR "[DEBUG][GitHubCopilotModelsAPI] Fetched " . 
        scalar(@{$data->{data} || []}) . " models\n" if $self->{debug};
    
    return $data;
}

=head2 get_model_billing

Get billing information for a specific model.

Arguments:
- $model_id: Model identifier (e.g., 'gpt-4.1')

Returns:
- Hashref: {is_premium => 0/1, multiplier => number}
- Defaults to {is_premium => 0, multiplier => 0} if model not found

=cut

sub get_model_billing {
    my ($self, $model_id) = @_;
    
    return {is_premium => 0, multiplier => 0} unless $model_id;
    
    my $models_data = $self->fetch_models();
    return {is_premium => 0, multiplier => 0} unless $models_data && $models_data->{data};
    
    # Find model by ID
    for my $model (@{$models_data->{data}}) {
        if ($model->{id} eq $model_id) {
            if ($model->{billing}) {
                print STDERR "[DEBUG][GitHubCopilotModelsAPI] Found billing for $model_id: " .
                    "premium=" . ($model->{billing}{is_premium} || 0) . ", " .
                    "multiplier=" . ($model->{billing}{multiplier} || 0) . "\n"
                    if $self->{debug};
                
                return {
                    is_premium => $model->{billing}{is_premium} || 0,
                    multiplier => $model->{billing}{multiplier} || 0
                };
            } else {
                # Model exists but API doesn't provide billing info
                # This shouldn't happen with correct headers, but handle gracefully
                print STDERR "[WARN][GitHubCopilotModelsAPI] Model $model_id has no billing data in API response\n"
                    if should_log('WARNING');
                
                return {is_premium => 0, multiplier => 0};  # Default to free if unknown
            }
        }
    }
    
    # Model not found in API response
    print STDERR "[WARN][GitHubCopilotModelsAPI] Model $model_id not found in API response\n"
        if should_log('WARNING');
    
    return {is_premium => 0, multiplier => 0};  # Default to free if unknown
}

=head2 _get_hardcoded_multiplier

=head2 get_all_models

Get all available models with full capabilities and billing info.

Returns:
- Arrayref of model hashrefs, each containing:
  - id: Model identifier
  - name: Display name (optional)
  - enabled: Boolean (optional)
  - billing: {is_premium, multiplier} (optional)
  - capabilities: {family, limits: {max_context_window_tokens, max_output_tokens, max_prompt_tokens}} (optional)

=cut

sub get_all_models {
    my ($self) = @_;
    
    my $models_data = $self->fetch_models();
    return [] unless $models_data && $models_data->{data};
    
    return $models_data->{data};
}

=head2 get_model_capabilities

Get capabilities for a specific model, including token limits.

Arguments:
- $model_id: Model identifier

Returns:
- Hashref with keys:
  - max_prompt_tokens: Maximum prompt tokens (THE enforced limit)
  - max_output_tokens: Maximum completion tokens
  - max_context_window_tokens: Total context window (for reference only)
  - family: Model family (optional)
- Returns undef if model not found

IMPORTANT: GitHub Copilot enforces max_prompt_tokens, NOT max_context_window_tokens.
Example: gpt-5-mini has 264k context but only 128k prompt tokens allowed.

=cut

sub get_model_capabilities {
    my ($self, $model_id) = @_;
    
    return undef unless $model_id;
    
    my $models_data = $self->fetch_models();
    return undef unless $models_data && $models_data->{data};
    
    # Find model by ID
    for my $model (@{$models_data->{data}}) {
        if ($model->{id} eq $model_id) {
            my $caps = {
                family => $model->{capabilities}{family} || undef,
            };
            
            if ($model->{capabilities} && $model->{capabilities}{limits}) {
                my $limits = $model->{capabilities}{limits};
                
                # CRITICAL: Use max_prompt_tokens as the enforced limit
                # Fallback to max_context_window_tokens if max_prompt_tokens unavailable
                $caps->{max_prompt_tokens} = $limits->{max_prompt_tokens} || 
                                              $limits->{max_context_window_tokens} || 128000;
                $caps->{max_output_tokens} = $limits->{max_output_tokens} || 4096;
                $caps->{max_context_window_tokens} = $limits->{max_context_window_tokens} || 128000;
                
                print STDERR "[DEBUG][GitHubCopilotModelsAPI] Capabilities for $model_id: " .
                    "max_prompt=" . ($caps->{max_prompt_tokens} || 'N/A') . ", " .
                    "max_output=" . ($caps->{max_output_tokens} || 'N/A') . "\n"
                    if $self->{debug};
            }
            
            return $caps;
        }
    }
    
    return undef;
}

=head2 _load_cache

Load cached models data if available and not expired.

Returns:
- Cached data hashref, or undef if cache missing/expired

=cut

sub _load_cache {
    my ($self) = @_;
    
    return undef unless -f $self->{cache_file};
    
    # Check if cache is expired
    my $age = time() - (stat($self->{cache_file}))[9];
    if ($age > $self->{cache_ttl}) {
        print STDERR "[DEBUG][GitHubCopilotModelsAPI] Cache expired (age: ${age}s, ttl: $self->{cache_ttl}s)\n"
            if $self->{debug};
        return undef;
    }
    
    open my $fh, '<', $self->{cache_file} or return undef;
    local $/;
    my $json = <$fh>;
    close $fh;
    
    return eval { decode_json($json) };
}

=head2 _save_cache

Save models data to cache file.

Arguments:
- $data: Data to cache

=cut

sub _save_cache {
    my ($self, $data) = @_;
    
    # Create cache directory if needed
    my $cache_dir = dirname($self->{cache_file});
    unless (-d $cache_dir) {
        mkdir $cache_dir or do {
            print STDERR "[WARN][GitHubCopilotModelsAPI] Cannot create cache directory: $!\n";
            return;
        };
    }
    
    open my $fh, '>', $self->{cache_file} or do {
        print STDERR "[WARN][GitHubCopilotModelsAPI] Cannot save cache: $!\n";
        return;
    };
    
    print $fh encode_json($data);
    close $fh;
    
    print STDERR "[DEBUG][GitHubCopilotModelsAPI] Saved models cache to $self->{cache_file}\n"
        if $self->{debug};
}



sub _generate_uuid {
    my ($self) = @_;
    
    # Simple UUID v4 generation (good enough for X-Request-Id)
    my @chars = ('a'..'f', '0'..'9');
    my $uuid = '';
    for my $i (1..32) {
        $uuid .= $chars[rand @chars];
        $uuid .= '-' if $i == 8 || $i == 12 || $i == 16 || $i == 20;
    }
    return $uuid;
}

1;

__END__


=head1 IMPLEMENTATION NOTES

This module fetches model billing information from GitHub Copilot's /models API.

API Response Structure:
```json
{
  "data": [
    {
      "id": "gpt-4.1",
      "name": "GPT-4 Turbo",
      "billing": {
        "is_premium": false,
        "multiplier": 0
      }
    },
    {
      "id": "claude-sonnet-4-20250514",
      "billing": {
        "is_premium": true,
        "multiplier": 1
      }
    }
  ]
}
```

Multiplier Meanings:
- 0x or null: Free (included in subscription)
- 1x: Standard premium rate
- 3x: 3x premium rate
- 20x: Very expensive models

Cache Strategy:
- Cache file: ~/.clio/models_cache.json
- TTL: 1 hour (3600 seconds)
- Refreshed automatically when expired

=cut

sub _generate_uuid {
    my ($self) = @_;
    
    # Simple UUID v4 generation (good enough for X-Request-Id)
    my @chars = ('a'..'f', '0'..'9');
    my $uuid = '';
    for my $i (1..32) {
        $uuid .= $chars[rand @chars];
        $uuid .= '-' if $i == 8 || $i == 12 || $i == 16 || $i == 20;
    }
    return $uuid;
}

