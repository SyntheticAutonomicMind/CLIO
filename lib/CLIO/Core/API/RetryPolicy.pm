# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::API::RetryPolicy;

use strict;
use warnings;
use utf8;

=head1 NAME

CLIO::Core::API::RetryPolicy - Retry budgets, backoff, and retry messages

=head1 SYNOPSIS

    use CLIO::Core::API::RetryPolicy qw(budget delay describe is_transient);

    my $budget = budget(
        error_type       => 'server_error',
        max_server       => 0,     # 0 = infinite
    );
    if (!$budget->{infinite} && $attempt > $budget->{limit}) { ... }

    my $wait = delay(
        error_type  => 'server_error',
        attempt     => $attempt,
        retry_after => $api_response->{retry_after},
        max_delay   => 300,
        jitter      => 0.2,
    );

    my $msg = describe(
        label    => 'Server error',
        attempt  => $attempt,
        budget   => $budget,
        delay    => $wait,
    );

=head1 DESCRIPTION

Every decision about how long to wait before retrying an API request, and
every decision about how many times a given error class may be retried,
lives here. The three functions are pure: no session, no config object, no
terminal. Callers pass in the values they read from configuration and from
the provider's response, and get numbers and strings back.

Keeping the policy in one place is what stops the retry message from
disagreeing with the sleep that follows it. The message is built from the
same number the caller sleeps for, after every adjustment has been applied.

=head2 Error classes

  transient      server_error, connection_error, timeout, overloaded, truncated
  rate_limit     rate_limit, concurrency_limit
  deterministic  request_timeout, bad_request
  other          anything else (malformed_tool_json, token_limit_exceeded, ...)

Transient errors back off exponentially. Rate limits honor the provider's
C<Retry-After> without exponential growth, because the provider already told
us when it is willing to talk again. Deterministic errors get a small,
fixed budget: a request that outruns a deadline will outrun it every time.

=cut

use Exporter 'import';
our @EXPORT_OK = qw(
    budget delay describe format_delay
    is_transient is_rate_limited backoff_base
    DEFAULT_MAX_DELAY DEFAULT_MIN_DELAY DEFAULT_JITTER
    DEFAULT_RATE_LIMIT_MAX_DELAY
    DEFAULT_MAX_ATTEMPTS DEFAULT_MAX_SERVER_ATTEMPTS DEFAULT_MAX_RATE_LIMIT_ATTEMPTS
    DEFAULT_CONNECT_TIMEOUT DEFAULT_STALL_TIMEOUT
);

=head1 CONSTANTS

The defaults here are the source of truth for every retry knob. Config
getters in L<CLIO::Core::Config> and the fallbacks in
L<CLIO::Core::API::ErrorHandler> read these constants rather than
repeating the numbers, so a change lands in one place.

=cut

=head2 DEFAULT_MAX_DELAY

Upper bound on any single wait, in seconds. Five minutes.

=cut

use constant DEFAULT_MAX_DELAY => 300;

=head2 DEFAULT_MIN_DELAY

Floor on any single wait, in seconds. Prevents a provider that answers
C<Retry-After: 0> from turning the retry loop into a hot loop.

=cut

use constant DEFAULT_MIN_DELAY => 1;

=head2 DEFAULT_JITTER

Fractional jitter applied to computed waits. 0.2 means +/-20% for transient
errors and up to +20% for rate limits.

=cut

use constant DEFAULT_JITTER => 0.2;

=head2 DEFAULT_RATE_LIMIT_MAX_DELAY

Upper bound on a single wait after a rate limit, in seconds. Fifteen
minutes. A provider that says "come back in 15 minutes" is telling the
truth, and retrying after five just earns another 429.

=cut

use constant DEFAULT_RATE_LIMIT_MAX_DELAY => 900;

=head2 DEFAULT_MAX_ATTEMPTS

Retries for unclassified errors before giving up. Three.

=cut

use constant DEFAULT_MAX_ATTEMPTS => 3;

=head2 DEFAULT_MAX_SERVER_ATTEMPTS

Retries for transient errors. 0 means retry until the request succeeds or
the user interrupts.

=cut

use constant DEFAULT_MAX_SERVER_ATTEMPTS => 0;

=head2 DEFAULT_MAX_RATE_LIMIT_ATTEMPTS

Retries for rate limits. 0 means keep waiting until the provider lets the
request through.

=cut

use constant DEFAULT_MAX_RATE_LIMIT_ATTEMPTS => 0;

=head2 DEFAULT_CONNECT_TIMEOUT

Seconds one attempt may spend opening a socket. Ten. Separate from the
request ceiling because a down network makes the connect wait the entire
cost of an attempt.

=cut

use constant DEFAULT_CONNECT_TIMEOUT => 10;

=head2 DEFAULT_STALL_TIMEOUT

Idle-transfer ceiling in seconds. 0 disables it: a reasoning model can sit
silent for a long time before its first token, and cutting that off would
break working requests to catch broken ones.

=cut

use constant DEFAULT_STALL_TIMEOUT => 0;

my %TRANSIENT = map { $_ => 1 } qw(
    server_error connection_error timeout overloaded truncated
);

my %RATE_LIMITED = map { $_ => 1 } qw(
    rate_limit concurrency_limit
);

# Per-error-class base for exponential growth, in seconds. These match the
# retry_after values ResponseHandler attaches to each class, and act as the
# floor when a provider hint is missing or implausibly small.
my %BACKOFF_BASE = (
    connection_error => 3,
    server_error     => 2,
    truncated        => 2,
    timeout          => 30,
    overloaded       => 10,
);

# request_timeout is CLIO's own ceiling expiring. The response will outrun
# the ceiling every time, so one retry covers a grazed limit and no more.
use constant REQUEST_TIMEOUT_RETRIES => 1;

# An unrecognized 400 is a payload/model/backend problem. Four attempts is
# enough to ride out a provider blip without burying the real error.
use constant BAD_REQUEST_RETRIES => 4;

=head1 FUNCTIONS

=head2 is_transient($error_type)

Returns true for errors that represent a temporary condition and are worth
retrying with exponential backoff.

=cut

sub is_transient {
    my ($type) = @_;
    return 0 unless defined $type && length $type;
    return $TRANSIENT{$type} ? 1 : 0;
}

=head2 is_rate_limited($error_type)

Returns true for provider rate-limit and local concurrency-limit errors.

=cut

sub is_rate_limited {
    my ($type) = @_;
    return 0 unless defined $type && length $type;
    return $RATE_LIMITED{$type} ? 1 : 0;
}

=head2 backoff_base($error_type)

Returns the base delay in seconds for exponential growth for this error
class. Unknown classes use 2s.

=cut

sub backoff_base {
    my ($type) = @_;
    return $BACKOFF_BASE{$type // ''} // 2;
}

=head2 budget(%args)

Resolve the retry budget for an error class.

Arguments:
    error_type        - API error_type string
    max_generic       - Retries for unclassified errors (default 3)
    max_server        - Retries for transient errors, 0 = infinite (default 0)
    max_rate_limit    - Retries for rate limits, 0 = infinite (default 0)

Returns a hashref:
    limit    - Maximum attempts allowed (ignored when infinite)
    infinite - True when the class retries until it succeeds or the user stops
    kind     - 'transient' | 'rate_limit' | 'request_deadline' | 'bad_request' | 'generic'

Example:
    my $b = budget(error_type => 'rate_limit', max_rate_limit => 0);
    # { limit => 0, infinite => 1, kind => 'rate_limit' }

=cut

sub budget {
    my (%args) = @_;

    my $type           = $args{error_type} // '';
    my $max_generic    = defined $args{max_generic}    ? $args{max_generic}    : 3;
    my $max_server     = defined $args{max_server}     ? $args{max_server}     : 0;
    my $max_rate_limit = defined $args{max_rate_limit} ? $args{max_rate_limit} : 0;

    if (is_rate_limited($type)) {
        return {
            limit    => $max_rate_limit,
            infinite => $max_rate_limit == 0 ? 1 : 0,
            kind     => 'rate_limit',
        };
    }

    if (is_transient($type)) {
        return {
            limit    => $max_server,
            infinite => $max_server == 0 ? 1 : 0,
            kind     => 'transient',
        };
    }

    if ($type eq 'request_timeout') {
        return {
            limit    => REQUEST_TIMEOUT_RETRIES,
            infinite => 0,
            kind     => 'request_deadline',
        };
    }

    if ($type eq 'bad_request') {
        return {
            limit    => BAD_REQUEST_RETRIES,
            infinite => 0,
            kind     => 'bad_request',
        };
    }

    return {
        limit    => $max_generic,
        infinite => $max_generic == 0 ? 1 : 0,
        kind     => 'generic',
    };
}

=head2 delay(%args)

Compute the wait before the next attempt.

Arguments:
    error_type  - API error_type string
    attempt     - 1-based attempt counter (the attempt that just failed)
    retry_after - Provider hint in seconds, if any
    max_delay   - Ceiling for one wait (default: DEFAULT_MAX_DELAY)
    min_delay   - Floor for one wait (default: DEFAULT_MIN_DELAY)
    jitter      - Fractional jitter (default: DEFAULT_JITTER, 0 disables)
    rng         - Coderef returning 0..1, for deterministic tests

Returns a number of seconds, rounded to one decimal place.

Rate limits: the provider's hint is the wait. Jitter is applied upward only,
so a retry never lands sooner than the provider asked for.

Transient errors: exponential growth from the larger of the provider hint
and the class floor, capped at C<max_delay>, with symmetric jitter so that
independent clients sharing an outage do not wake in lockstep.

=cut

sub delay {
    my (%args) = @_;

    my $type      = $args{error_type} // '';
    my $attempt   = $args{attempt} // 1;
    my $max_delay = defined $args{max_delay} ? $args{max_delay} : DEFAULT_MAX_DELAY;
    my $min_delay = defined $args{min_delay} ? $args{min_delay} : DEFAULT_MIN_DELAY;
    my $jitter    = defined $args{jitter}    ? $args{jitter}    : DEFAULT_JITTER;
    my $rng       = $args{rng} // sub { rand() };
    my $hint      = $args{retry_after};

    $attempt = 1 if !defined $attempt || $attempt < 1;
    $max_delay = DEFAULT_MIN_DELAY if $max_delay < DEFAULT_MIN_DELAY;
    $min_delay = 0 if $min_delay < 0;
    $jitter = 0 if $jitter < 0;

    if (is_rate_limited($type)) {
        my $wait = (defined $hint && $hint > 0) ? $hint : 60;
        $wait = $max_delay if $wait > $max_delay;
        # Upward-only jitter: the provider's Retry-After is a lower bound.
        $wait += $wait * $jitter * $rng->() if $jitter > 0;
        $wait = $min_delay if $wait < $min_delay;
        return _round($wait, $max_delay);
    }

    my $base = backoff_base($type);
    # Trust a provider hint only when it is longer than our own floor -
    # otherwise a "Retry-After: 1" on a 5xx would stall the backoff curve.
    my $first = (defined $hint && $hint > $base) ? $hint : $base;
    $first = $max_delay if $first > $max_delay;

    # Grow by doubling until the cap is reached. A loop rather than
    # $first * 2**($attempt-1) because attempt grows without bound on
    # infinite-retry budgets, and 2**1024 overflows to Inf (then to NaN
    # once jitter multiplies it by zero).
    my $wait = $first;
    for my $i (2 .. $attempt) {
        last if $wait >= $max_delay;
        $wait *= 2;
    }
    $wait = $max_delay if $wait > $max_delay;

    # Symmetric jitter. Clients that all saw the same outage must not all
    # retry on the same second.
    $wait += $wait * $jitter * (2 * $rng->() - 1) if $jitter > 0;

    $wait = $min_delay if $wait < $min_delay;
    $wait = $max_delay if $wait > $max_delay;

    return _round($wait, $max_delay);
}

=head2 format_delay($seconds)

Format a wait for display: whole seconds render as "3s", fractions as
"2.4s". Values at or above ten seconds drop the fraction.

=cut

sub format_delay {
    my ($seconds) = @_;
    $seconds = 0 unless defined $seconds;

    return sprintf('%.1fs', $seconds) if $seconds < 10 && $seconds != int($seconds);
    return sprintf('%ds', int($seconds + 0.5));
}

=head2 describe(%args)

Build the system message shown while waiting to retry.

Arguments:
    label    - Human label, e.g. "Server error" or "Model rate limit"
    attempt  - 1-based attempt counter
    budget   - Hashref from C<budget()> (defaults to a generic 3-attempt one)
    delay    - Wait in seconds, as returned by C<delay()>. Required.
    detail   - Optional parenthetical detail, e.g. "DNS resolution failed"
    omit_delay - Omit the seconds from the text (default: 0). Used when the
                 caller renders a live countdown next to this line, so the
                 wait appears once, as a number that ticks down.
    infinity - Display string for infinite budgets (default: "inf")
    hint     - Optional trailing hint, e.g. "press ESC to stop"

Returns the message string.

The delay in the message is the delay the caller is about to sleep for.
That is the whole point of building the message here rather than at the
call site: the message cannot drift from the behavior.

=cut

sub describe {
    my (%args) = @_;

    my $label    = $args{label} // 'Error';
    my $attempt  = $args{attempt} // 1;
    my $budget   = $args{budget} // { limit => 3, infinite => 0 };
    my $wait     = defined $args{delay} ? $args{delay} : 0;
    my $detail   = $args{detail};
    my $infinity = defined $args{infinity} ? $args{infinity} : 'inf';
    my $hint     = $args{hint};

    # The label is the whole first sentence. Appending a fixed verb here
    # ("$label detected") reads wrong for half the labels - "Stream truncated
    # detected" is not English - so the label is expected to be a noun phrase
    # and nothing is bolted onto it.
    my $text = $label;

    # The label starts the sentence, so it is capitalized - unless it is a
    # proper noun that is already capitalized ("Model rate limit").
    $text = ucfirst($text) if $text =~ /^[a-z]/;
    $text .= " ($detail)" if defined $detail && length $detail;
    $text .= '.';

    # Nothing to wait for - say what is happening instead of "Retrying in 0s".
    if ($args{omit_delay}) {
        $text .= ' Retrying...';
    } elsif ($wait <= 0) {
        $text .= " Retrying immediately.";
    } else {
        $text .= ' Retrying in ' . format_delay($wait) . '...';
    }

    my $count = $budget->{infinite}
        ? "attempt $attempt/$infinity"
        : "attempt $attempt/" . ($budget->{limit} // '?');

    $count .= ", $hint" if defined $hint && length $hint;

    return "$text ($count)";
}

sub _round {
    my ($wait, $max_delay) = @_;
    my $rounded = int($wait * 10 + 0.5) / 10;
    $rounded = $max_delay if $rounded > $max_delay;
    return $rounded;
}

1;

__END__

=head1 SEE ALSO

L<CLIO::Core::API::ErrorHandler> - consumes this policy
L<CLIO::Core::API::ResponseHandler> - classifies errors, supplies C<retry_after>
L<CLIO::Compat::HTTP> - transport, supplies connection subtype and elapsed time

=cut
