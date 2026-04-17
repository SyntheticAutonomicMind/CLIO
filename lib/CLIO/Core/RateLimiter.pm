# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::RateLimiter;

=head1 NAME

CLIO::Core::RateLimiter - Per-provider request rate limiting and queuing

=head1 DESCRIPTION

Manages concurrent request limits per AI provider and honors Retry-After
headers to prevent rate limit errors. Implements request queuing when
concurrency limits are reached.

Supports:
- Configurable max concurrent requests per provider
- Retry-After header parsing and honoring
- X-RateLimit-* header parsing (OpenAI, Anthropic, GitHub)
- openai-remaining-requests header parsing
- Adaptive throttling based on remaining quota

=head1 SYNOPSIS

    use CLIO::Core::RateLimiter;
    
    my $limiter = CLIO::Core::RateLimiter->new();
    
    # Acquire a slot before making a request
    $limiter->acquire($provider);
    
    # Release when request completes
    $limiter->release($provider);
    
    # Update rate limit state from API headers
    $limiter->update_from_headers($provider, $headers);
    
    # Wait if provider is rate limited or at concurrency limit
    my $wait = $limiter->check_and_wait($provider);
    sleep($wait) if $wait;

=cut

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Time::HiRes qw(time sleep);
use CLIO::Core::Logger qw(should_log log_debug log_info log_warning);

# Default concurrency limit per provider
use constant DEFAULT_MAX_CONCURRENT => 2;

# Default rate limit window (seconds)
use constant DEFAULT_RATE_WINDOW => 60;

# Singleton instance
my $_singleton;

=head2 get_instance

Get the singleton RateLimiter instance.

Returns: CLIO::Core::RateLimiter singleton

=cut

sub get_instance {
    my ($class, %args) = @_;
    $_singleton //= $class->new(%args);
    return $_singleton;
}

=head2 reset_instance

Reset the singleton (primarily for testing).

=cut

sub reset_instance {
    $_singleton = undef;
}

=head2 new

=head2 new

Create a new RateLimiter instance.

Arguments:
- max_concurrent: Optional hashref of provider => max concurrent requests

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        # Max concurrent requests per provider
        max_concurrent => $args{max_concurrent} || {},
        
        # Currently active requests per provider
        active_requests => {},
        
        # Request queue per provider (array of {time, callback})
        request_queue => {},
        
        # Rate limit state per provider
        rate_limit_state => {},
        
        # Last time we processed the queue for each provider
        last_queue_check => {},
    };
    
    return bless $self, $class;
}

=head2 get_max_concurrent

Get the configured max concurrent requests for a provider.

Arguments:
- $provider: Provider name (e.g., 'github', 'openai')

Returns: Max concurrent requests (default: 2)

=cut

sub get_max_concurrent {
    my ($self, $provider) = @_;
    $provider = lc($provider);
    return $self->{max_concurrent}{$provider} // DEFAULT_MAX_CONCURRENT;
}

=head2 set_max_concurrent

Set max concurrent requests for a provider.

Arguments:
- $provider: Provider name
- $max: Maximum concurrent requests

=cut

sub set_max_concurrent {
    my ($self, $provider, $max) = @_;
    $provider = lc($provider);
    $self->{max_concurrent}{$provider} = $max;
    log_debug('RateLimiter', "Set $provider max_concurrent=$max");
}

=head2 acquire

Attempt to acquire a slot for a request. Returns immediately if slot
available, or returns 0 if at concurrency limit.

Arguments:
- $provider: Provider name

Returns: 1 if acquired, 0 if at limit (caller should wait)

=cut

sub acquire {
    my ($self, $provider) = @_;
    $provider = lc($provider);
    my $current = $self->{active_requests}{$provider} // 0;
    my $max = $self->get_max_concurrent($provider);
    
    if ($current >= $max) {
        log_debug('RateLimiter', "Provider $provider at concurrency limit ($current/$max)");
        return 0;
    }
    
    $self->{active_requests}{$provider} = $current + 1;
    log_debug('RateLimiter', "Acquired slot for $provider ($current -> " . ($current + 1) . "/$max)");
    return 1;
}

=head2 release

Release a request slot after completion.

Arguments:
- $provider: Provider name

=cut

sub release {
    my ($self, $provider) = @_;
    $provider = lc($provider);
    my $current = $self->{active_requests}{$provider} // 0;
    if ($current > 0) {
        $self->{active_requests}{$provider} = $current - 1;
        log_debug('RateLimiter', "Released slot for $provider ($current -> " . ($current - 1) . ")");
    }
}

=head2 update_from_headers

Update rate limit state from response headers.

Arguments:
- $provider: Provider name
- $headers: HTTP::Headers object or hashref

=cut

sub update_from_headers {
    my ($self, $provider, $headers) = @_;
    $provider = lc($provider);
    return unless $headers;
    
    my %rl_state = ();
    
    # Extract headers (handle both object and hash)
    my %headers_hash;
    if (ref($headers) eq 'HASH') {
        %headers_hash = %$headers;
    } elsif ($headers->can('scan')) {
        $headers->scan(sub {
            my ($name, $value) = @_;
            $headers_hash{lc($name)} = $value;
        });
    } elsif ($headers->can('header')) {
        # Single-header accessor
        for my $key (qw(
            retry-after
            x-ratelimit-limit-requests
            x-ratelimit-remaining-requests
            x-ratelimit-reset-requests
            x-ratelimit-limit-tokens
            x-ratelimit-remaining-tokens
            x-ratelimit-reset-tokens
            openai-remaining-requests
            openai-next-refill-time
        )) {
            my $val = $headers->header($key);
            $headers_hash{$key} = $val if defined $val;
        }
    }
    
    # Parse standard rate limit headers
    if (my $limit = $headers_hash{'x-ratelimit-limit-requests'}) {
        $rl_state{limit_requests} = $limit;
    }
    if (my $remaining = $headers_hash{'x-ratelimit-remaining-requests'}) {
        $rl_state{remaining_requests} = $remaining;
    }
    if (my $reset = $headers_hash{'x-ratelimit-reset-requests'}) {
        $rl_state{reset_requests} = $reset;
    }
    
    # Parse OpenAI-specific headers
    if (my $remaining = $headers_hash{'openai-remaining-requests'}) {
        $rl_state{openai_remaining} = $remaining;
    }
    if (my $refill = $headers_hash{'openai-next-refill-time'}) {
        $rl_state{openai_refill_time} = $refill;
    }
    
    # Parse Retry-After header
    if (my $retry_after = $headers_hash{'retry-after'}) {
        if ($retry_after =~ /^\d+$/) {
            $rl_state{retry_after} = int($retry_after);
        } elsif ($retry_after =~ /^(\d+)$/) {
            # Could be epoch timestamp
            my $ts = int($retry_after);
            if ($ts > time()) {
                $rl_state{retry_after} = $ts - time();
            }
        }
        $rl_state{retry_after_time} = time() + ($rl_state{retry_after} // 0);
    }
    
    # Calculate percent remaining for adaptive throttling
    if (defined $rl_state{limit_requests} && defined $rl_state{remaining_requests}) {
        my $limit = $rl_state{limit_requests};
        if ($limit > 0) {
            $rl_state{percent_remaining} = ($rl_state{remaining_requests} / $limit) * 100;
        }
    }
    
    # Calculate adaptive delay
    $rl_state{adaptive_delay} = $self->_calculate_adaptive_delay($provider, \%rl_state);
    
    # Store state
    $self->{rate_limit_state}{$provider} = \%rl_state;
    
    if (should_log('DEBUG')) {
        log_debug('RateLimiter', "Rate limit state for $provider:");
        for my $key (sort keys %rl_state) {
            log_debug('RateLimiter', "  $key: $rl_state{$key}");
        }
    }
    
    return \%rl_state;
}

=head2 _calculate_adaptive_delay

Calculate delay to add between requests based on remaining quota.

Arguments:
- $provider: Provider name
- $rl_state: Rate limit state hashref

Returns: Recommended delay in seconds (0 = no delay)

=cut

sub _calculate_adaptive_delay {
    my ($self, $provider, $rl_state) = @_;
    
    my $delay = 0;
    
    # If we hit retry-after, respect it
    if ($rl_state->{retry_after} && $rl_state->{retry_after} > 0) {
        return $rl_state->{retry_after};
    }
    
    # Check OpenAI remaining requests
    if (defined $rl_state->{openai_remaining}) {
        if ($rl_state->{openai_remaining} <= 1) {
            # Very low - add significant delay
            $delay = 5;
            log_debug('RateLimiter', "Low openai-remaining-requests ($rl_state->{openai_remaining}), adding ${delay}s delay");
        } elsif ($rl_state->{openai_remaining} <= 5) {
            $delay = 1;
        }
    }
    
    # Check standard remaining requests
    if (defined $rl_state->{percent_remaining}) {
        if ($rl_state->{percent_remaining} <= 10) {
            $delay = 2 if $delay < 2;
            log_debug('RateLimiter', "Low rate limit remaining (" . $rl_state->{percent_remaining} . "%), adding ${delay}s delay");
        } elsif ($rl_state->{percent_remaining} <= 25) {
            $delay = 1 if $delay < 1;
        }
    }
    
    return $delay;
}

=head2 check_and_wait

Check if we should wait before making a request due to rate limiting
or concurrency limits.

Arguments:
- $provider: Provider name

Returns: Seconds to wait (0 = proceed immediately, >0 = sleep and retry)

=cut

sub check_and_wait {
    my ($self, $provider) = @_;
    $provider = lc($provider);
    my $wait = 0;
    
    # Check Retry-After
    my $rl_state = $self->{rate_limit_state}{$provider};
    if ($rl_state && $rl_state->{retry_after_time}) {
        my $remaining = $rl_state->{retry_after_time} - time();
        if ($remaining > 0) {
            log_debug('RateLimiter', "Rate limited, retry-after: ${remaining}s");
            return $remaining;
        }
    }
    
    # Check concurrency limit
    my $active = $self->{active_requests}{$provider} // 0;
    my $max = $self->get_max_concurrent($provider);
    if ($active >= $max) {
        # Estimate wait based on typical request duration
        $wait = 0.5;  # Start with small wait
        log_debug('RateLimiter', "At concurrency limit, waiting ${wait}s");
        return $wait;
    }
    
    # Check adaptive throttling
    if ($rl_state && $rl_state->{adaptive_delay} && $rl_state->{adaptive_delay} > 0) {
        log_debug('RateLimiter', "Adaptive throttle, waiting $rl_state->{adaptive_delay}s");
        return $rl_state->{adaptive_delay};
    }
    
    return 0;
}

=head2 get_rate_limit_info

Get current rate limit state for a provider.

Arguments:
- $provider: Provider name

Returns: Hashref of rate limit info, or undef if not available

=cut

sub get_rate_limit_info {
    my ($self, $provider) = @_;
    $provider = lc($provider);
    return $self->{rate_limit_state}{$provider};
}

=head2 clear_rate_limit

Clear rate limit state for a provider (after successful request).

Arguments:
- $provider: Provider name

=cut

sub clear_rate_limit {
    my ($self, $provider) = @_;
    $provider = lc($provider);
    # Decay the adaptive delay but don't clear completely
    my $rl_state = $self->{rate_limit_state}{$provider};
    if ($rl_state) {
        # Gradually reduce delay on successful requests
        if ($rl_state->{adaptive_delay}) {
            $rl_state->{adaptive_delay} = int($rl_state->{adaptive_delay} * 0.8);
            if ($rl_state->{adaptive_delay} < 0.1) {
                $rl_state->{adaptive_delay} = 0;
            }
        }
        
        # Clear retry-after since request succeeded
        delete $rl_state->{retry_after};
        delete $rl_state->{retry_after_time};
    }
}

=head2 get_active_count

Get number of active requests for a provider.

Arguments:
- $provider: Provider name

Returns: Number of active requests

=cut

sub get_active_count {
    my ($self, $provider) = @_;
    $provider = lc($provider);
    return $self->{active_requests}{$provider} // 0;
}

=head2 is_rate_limited

Check if provider is currently rate limited.

Arguments:
- $provider: Provider name

Returns: 1 if rate limited, 0 otherwise

=cut

sub is_rate_limited {
    my ($self, $provider) = @_;
    
    my $rl_state = $self->{rate_limit_state}{$provider};
    return 0 unless $rl_state;
    
    # Check if Retry-After is still valid
    if ($rl_state->{retry_after_time}) {
        return $rl_state->{retry_after_time} > time() ? 1 : 0;
    }
    
    return 0;
}

1;

__END__