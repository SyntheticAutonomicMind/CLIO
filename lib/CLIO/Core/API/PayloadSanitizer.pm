# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::API::PayloadSanitizer;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Scalar::Util qw(blessed looks_like_number);
use CLIO::Core::Logger qw(log_warning);
use CLIO::Util::TextSanitizer qw(sanitize_text sanitize_tool_output);

# Map of known JSON boolean class names to plain Perl boolean values.
# These classes come from JSON::PP, JSON::XS, Cpanel::JSON::XS.
my %JSON_BOOLEAN_CLASS = (
    'JSON::PP::Boolean'     => 1,
    'JSON::XS::Boolean'     => 1,
    'Cpanel::JSON::XS::Boolean' => 1,
    'Types::Serialiser::BooleanBase' => 1,  # Base class used by some backends
);

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
    my ($data, $preserve_lossless) = @_;

    if (!defined $data) {
        return undef;
    } elsif (ref($data) eq 'HASH') {
        # Tool results must arrive at the provider byte-identical to what the
        # tool returned. The model quotes them back in apply_patch old_lines
        # and other exact-match edits, so replacing or deleting characters
        # here makes it emit text that never existed on disk: the edit cannot
        # match, and the retry sends the same altered text. Invisible-character
        # filtering still runs, because that is a security boundary.
        my $role = $data->{role};
        my $type = $data->{type};
        my $is_tool_content = $preserve_lossless
            || (defined $role && $role eq 'tool')
            || (defined $type && $type eq 'function_call_output');
        my %sanitized;
        for my $key (keys %$data) {
            $sanitized{$key} = sanitize_payload($data->{$key}, $is_tool_content);
        }
        return \%sanitized;
    } elsif (ref($data) eq 'ARRAY') {
        return [ map { sanitize_payload($_, $preserve_lossless) } @$data ];
    } elsif (!ref($data)) {
        return $data if looks_like_number($data);
        return $preserve_lossless ? sanitize_tool_output($data) : sanitize_text($data);
    } else {
        # Blessed ref (not hash/array): check for known JSON boolean types
        # and convert to plain Perl boolean values for correct serialization.
        my $class = blessed($data);
        if ($class && $JSON_BOOLEAN_CLASS{$class}) {
            # Re-wrap as a JSON boolean rather than collapsing to 1/0.
            # Collapsing silently rewrites the value's type: a schema
            # property such as `append => { default => false }` reached the
            # provider as `default: 0`, an integer where the schema declares
            # a boolean. JSON::PP::Boolean is recognised as a boolean by
            # JSON::PP, JSON::XS, and Cpanel::JSON::XS alike, so re-wrapping
            # keeps both the meaning and the wire type intact.
            require JSON::PP;
            return $data ? JSON::PP::true() : JSON::PP::false();
        }

        # Unknown blessed ref: pass through unchanged. The caller
        # is responsible for serialising it. We log once per process for
        # visibility, since this is unusual.
        log_debug('PayloadSanitizer',
            'Passing through blessed ref of type ' . ($class // 'unknown') .
            ' - caller is responsible for serialising') if $class;
        return $data;
    }
}

1;
