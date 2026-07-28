# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Util::RateLimit;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Exporter 'import';
our @EXPORT_OK = qw(get_rate_limit_type_name format_reset_message parse_anthropic_reset_timestamp);

=head1 NAME

CLIO::Util::RateLimit - Shared rate limit utility functions

=head1 SYNOPSIS

    use CLIO::Util::RateLimit qw(create_rate_limiter);

    my $limiter = create_rate_limiter(requests_per_minute => 60);
    if (!$limiter->try_acquire()) {
        sleep $limiter->retry_after();
    }

=head1 DESCRIPTION

Common functions for rate limit error code mapping and reset time formatting.
Used by ResponseHandler, WorkflowOrchestrator, and Billing UI.

=head1 EXPORTS

=over 4

=item get_rate_limit_type_name($code)

=item format_reset_message($retry_after, $reset_timestamp)

=item parse_anthropic_reset_timestamp($value)

=back

=cut

=head2 get_rate_limit_type_name

Map a rate limit code to a user-friendly type name for display.

Arguments:
- $code: Rate limit error code string (e.g., 'user_weekly_rate_limited')

Returns: User-friendly type name (e.g., 'Weekly rate limit')

=cut

sub get_rate_limit_type_name {
    my ($code) = @_;
    return 'rate limit' unless $code;

    # Ordered list - more specific patterns first. Hash `for (keys %h)`
    # iterates in unpredictable order so a long-suffix regex would be
    # shadowed by a shorter-prefix one. Using an explicit ordered array
    # guarantees "Requests" beats "UserByModelByMinute" deterministically.
    my @type_list = (
        qr/agent_mode_limit_exceeded/i      => 'Agent mode rate limit',
        qr/model_overloaded/i                => 'Model overload',
        qr/upstream_provider_rate_limit/i    => 'Upstream provider rate limit',
        qr/user_global_rate_limited/i        => 'Global rate limit',
        qr/user_model_rate_limited/i         => 'Model rate limit',
        qr/user_weekly_rate_limited/i        => 'Weekly rate limit',
        qr/user_monthly_rate_limited/i       => 'Monthly rate limit',
        qr/integration_rate_limited/i        => 'Integration rate limit',
        # Anthropic-specific rate limit codes.
        # Newer responses use the generic "RateLimitReached" envelope with a
        # descriptive message (e.g. "Rate limit of 250000 per 60s exceeded for
        # UserByModelByMinuteUncachedInputTokens"). Older responses and some
        # Bedrock proxies still surface the bucket names directly, so we map
        # both shapes. Bucket semantics:
        #   UncachedInputTokens -> input tokens per minute (ITPM, the cap the
        #                            user keeps hitting with large conversations)
        #   UncachedOutputTokens -> output tokens per minute (OTPM)
        #   InputTokens / OutputTokens -> include cache reads (Haiku 3.5 only)
        #   Requests -> request rate (RPM)
        # Ordering matters: the four bucket suffixes MUST come before the
        # generic "userbymodelbyminute" prefix or hash lookup would shadow
        # them on any input matching both.
        qr/ratelimitreached/i                            => 'Anthropic rate limit',
        qr/userbymodelbyminuteuncachedinputtokens/i      => 'Anthropic uncached input token limit (ITPM)',
        qr/userbymodelbyminuteuncachedoutputtokens/i     => 'Anthropic uncached output token limit (OTPM)',
        qr/userbymodelbyminuteinputtokens/i              => 'Anthropic input token limit (ITPM)',
        qr/userbymodelbyminuteoutputtokens/i             => 'Anthropic output token limit (OTPM)',
        qr/userbymodelbyminuterequests/i                 => 'Anthropic request rate limit (RPM)',
        qr/userbymodelbyminute/i                         => 'Anthropic per-model rate limit',
        qr/anthropic[_-]ratelimit/i                      => 'Anthropic rate limit',
        # Z.AI-specific rate limit codes
        qr/^zai_usage_limit$/i               => 'Z.AI usage limit',
        qr/^1302$/                            => 'Z.AI concurrency limit',
        qr/^1303$/                            => 'Z.AI frequency limit',
        qr/^1305$/                            => 'Z.AI rate limit',
        qr/^1308$/                            => 'Z.AI usage limit',
        qr/^1309$/                            => 'Z.AI plan expired',
        qr/^1310$/                            => 'Z.AI weekly/monthly limit',
        qr/^1311$/                            => 'Z.AI model not in plan',
        qr/^1313$/                            => 'Z.AI fair use restriction',
    );

    # Iterate the ordered list, not its hash repr. `for (keys %h)` does
    # not preserve insertion order in Perl, so the more-specific Anthropic
    # bucket codes would be shadowed by the shorter `userbymodelbyminute`
    # prefix under some Perl builds. Walking the array keeps the explicit
    # ordering above meaningful.
    while (my ($pattern, $name) = splice(@type_list, 0, 2)) {
        return $name if $code =~ /$pattern/;
    }

    return 'rate limit';
}

=head2 format_reset_message

Format a human-readable reset time message from retry_after seconds and/or
reset timestamp.

Arguments:
- $retry_after: Seconds until rate limit resets (fallback if no reset_timestamp)
- $reset_timestamp: Unix epoch timestamp for accurate reset time (optional, preferred)

Returns: Formatted string like " and try again in 5 minutes" or empty string

=cut

sub format_reset_message {
    my ($retry_after, $reset_timestamp) = @_;

    if ($reset_timestamp && $reset_timestamp =~ /^\d+$/ && $reset_timestamp > time()) {
        $retry_after = $reset_timestamp - time();
    }

    return '' unless defined($retry_after) && $retry_after > 0;

    if ($retry_after >= 86400) {
        my $days = int($retry_after / 86400);
        return " and try again in about $days day" . ($days > 1 ? 's' : '');
    } elsif ($retry_after >= 3600) {
        my $hours = int($retry_after / 3600);
        return " and try again in about $hours hour" . ($hours > 1 ? 's' : '');
    } elsif ($retry_after >= 60) {
        my $mins = int($retry_after / 60);
        return " and try again in $mins minute" . ($mins > 1 ? 's' : '');
    } else {
        return " and try again in $retry_after second" . ($retry_after > 1 ? 's' : '');
    }
}

=head2 parse_anthropic_reset_timestamp

Parse an Anthropic-style rate limit reset header value into seconds until
reset. Anthropic rate limit `*-reset` headers are RFC 3339 timestamps (for
example `2026-07-22T12:34:56Z`), unlike OpenAI/Copilot reset headers which
carry seconds-until-reset or epoch seconds.

Returns the integer number of seconds from `time()` to the parsed reset
moment, clamped to a non-negative integer. Returns undef when the value
cannot be parsed (callers should treat that as "no reset known").

Arguments:
- $value: Header value (RFC 3339 string, or undef)

Returns: Integer seconds until reset, or undef.

=cut

sub parse_anthropic_reset_timestamp {
    my ($value) = @_;
    return undef unless defined $value && length $value;

    my $ts = $value;
    $ts =~ s/^\s+|\s+$//g;

    # Match ISO 8601 / RFC 3339 with required seconds component. Accept both
    # 'YYYY-MM-DDTHH:MM:SSZ' and 'YYYY-MM-DD HH:MM:SS+02:00' variants.
    return undef unless $ts =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:Z|[+-]\d{2}:?\d{2})?$/i;

    my ($y, $mo, $d, $h, $mi, $s) = ($1, $2, $3, $4, $5, $6);

    # Detect timezone offset (e.g. +02:00, -0500). No offset means UTC.
    my $offset_seconds = 0;
    if ($ts =~ /([+-])(\d{2}):?(\d{2})$/) {
        my ($sign, $oh, $om) = ($1, $2, $3);
        $offset_seconds = ($oh * 3600 + $om * 60) * ($sign eq '-' ? -1 : 1);
    }

    my $utc_epoch;
    eval {
        require Time::Local;
        $utc_epoch = Time::Local::timegm($s, $mi, $h, $d, $mo - 1, $y - 1900);
    };
    return undef if $@ || !defined $utc_epoch;

    # `timegm` treats inputs as UTC, so the epoch IS the UTC moment.
    my $secs = int($utc_epoch - time());
    return $secs < 0 ? 0 : $secs;
}

1;

__END__
