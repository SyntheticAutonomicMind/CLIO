# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Util::RateLimit;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Exporter 'import';
our @EXPORT_OK = qw(get_rate_limit_type_name format_reset_message);

=head1 NAME

CLIO::Util::RateLimit - Shared rate limit utility functions

=head1 DESCRIPTION

Common functions for rate limit error code mapping and reset time formatting.
Used by ResponseHandler, WorkflowOrchestrator, and Billing UI.

=head1 EXPORTS

=over 4

=item get_rate_limit_type_name($code)

=item format_reset_message($retry_after, $reset_timestamp)

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

    my %type_map = (
        qr/agent_mode_limit_exceeded/i    => 'Agent mode rate limit',
        qr/model_overloaded/i              => 'Model overload',
        qr/upstream_provider_rate_limit/i  => 'Upstream provider rate limit',
        qr/user_global_rate_limited/i      => 'Global rate limit',
        qr/user_model_rate_limited/i       => 'Model rate limit',
        qr/user_weekly_rate_limited/i      => 'Weekly rate limit',
        qr/user_monthly_rate_limited/i     => 'Monthly rate limit',
        qr/integration_rate_limited/i      => 'Integration rate limit',
    );

    for my $pattern (keys %type_map) {
        return $type_map{$pattern} if $code =~ /$pattern/;
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

1;

__END__
