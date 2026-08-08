# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::API::PayloadSanitizer;

use strict;
use warnings;
use utf8;
use Scalar::Util qw(blessed looks_like_number);
use CLIO::Core::Logger qw(log_warning);
use CLIO::Util::TextSanitizer qw(sanitize_text);
use CLIO::Util::JSON qw(is_hashref is_arrayref);
use Exporter 'import';

our @EXPORT_OK = qw(sanitize_payload);

=head1 NAME

CLIO::Core::API::PayloadSanitizer - Recursive payload sanitization for API requests

=head1 DESCRIPTION

Recursively sanitizes data structures before JSON encoding for API requests.
Removes problematic UTF-8 characters (emojis, bullets, etc.) that cause API
400 errors from providers like MiniMax and Z.AI.

CRITICAL: Numeric values are NOT passed through sanitize_text() because that
stringifies them - and JSON::XS (unlike JSON::PP) preserves the Perl string
flag, causing integer fields like max_tokens to be encoded as "32768" (string)
instead of 32768 (integer), which the API rejects with a 400 validation error.

Extracted from APIManager to reduce module size.

=head1 SYNOPSIS

    use CLIO::Core::API::PayloadSanitizer qw(sanitize_payload);

    my $payload = { messages => [...], max_tokens => 32768 };
    $payload = sanitize_payload($payload);

=cut

sub sanitize_payload {
    my ($data) = @_;

    if (!defined $data) {
        return undef;
    } elsif (is_hashref($data)) {
        my %sanitized;
        for my $key (keys %$data) {
            $sanitized{$key} = sanitize_payload($data->{$key});
        }
        return \%sanitized;
    } elsif (is_arrayref($data)) {
        return [ map { sanitize_payload($_) } @$data ];
    } elsif (!ref($data)) {
        return looks_like_number($data) ? $data : sanitize_text($data);
    } else {
        # Blessed ref (not hash/array): pass through unchanged. The caller
        # is responsible for serialising it. We log once per process for
        # visibility, since this is unusual.
        log_warning('PayloadSanitizer',
            'Passing through blessed ref of type ' . blessed($data) .
            ' - caller is responsible for serialising') if blessed($data);
        return $data;
    }
}

1;
