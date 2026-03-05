# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::ErrorContext;

use strict;
use warnings;
use utf8;
use Exporter 'import';

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::Core::ErrorContext - Error classification and formatting

=head1 DESCRIPTION

Provides utilities for classifying and formatting errors from eval blocks.
Normalizes error handling across the codebase with consistent categories
and user-friendly messages.

=head1 SYNOPSIS

    use CLIO::Core::ErrorContext qw(classify_error format_error);

    eval { ... };
    if ($@) {
        my $class = classify_error($@);
        my $msg   = format_error($@, 'API request');
        # $class is 'transport', 'auth', 'validation', 'io', or 'unexpected'
        # $msg is "API request failed (transport): Connection timed out"
    }

=cut

our @EXPORT_OK = qw(classify_error format_error);

my @TRANSPORT_PATTERNS = (
    qr/Connection refused/i,
    qr/Connection timed out/i,
    qr/Connection reset/i,
    qr/Could not connect/i,
    qr/Network is unreachable/i,
    qr/No route to host/i,
    qr/SSL.*error/i,
    qr/Can't connect/i,
    qr/timeout/i,
    qr/ETIMEDOUT/,
    qr/ECONNREFUSED/,
    qr/ECONNRESET/,
    qr/read timeout/i,
    qr/write timeout/i,
    qr/socket/i,
);

my @AUTH_PATTERNS = (
    qr/\b401\b/,
    qr/\b403\b/,
    qr/Unauthorized/i,
    qr/Forbidden/i,
    qr/Authentication failed/i,
    qr/Invalid.*token/i,
    qr/Invalid.*key/i,
    qr/token.*expired/i,
    qr/Access denied/i,
    qr/Permission denied/i,
);

my @VALIDATION_PATTERNS = (
    qr/\b400\b/,
    qr/\b422\b/,
    qr/Invalid.*parameter/i,
    qr/Missing.*required/i,
    qr/Malformed/i,
    qr/Invalid JSON/i,
    qr/Invalid format/i,
    qr/decode_json/i,
    qr/is not valid/i,
    qr/must be/i,
);

my @IO_PATTERNS = (
    qr/No such file/i,
    qr/Permission denied/i,
    qr/Is a directory/i,
    qr/Not a directory/i,
    qr/File exists/i,
    qr/Disk full/i,
    qr/No space left/i,
    qr/Read-only file system/i,
    qr/Cannot open/i,
    qr/Failed to open/i,
    qr/Failed to read/i,
    qr/Failed to write/i,
);

=head2 classify_error

Classify an error string into one of: transport, auth, validation, io, unexpected.

Arguments:
- error: The error string (typically $@)

Returns: String classification

=cut

sub classify_error {
    my ($error) = @_;
    $error //= '';
    $error = "$error";  # Stringify objects

    for my $pat (@AUTH_PATTERNS) {
        return 'auth' if $error =~ $pat;
    }
    for my $pat (@TRANSPORT_PATTERNS) {
        return 'transport' if $error =~ $pat;
    }
    for my $pat (@VALIDATION_PATTERNS) {
        return 'validation' if $error =~ $pat;
    }
    for my $pat (@IO_PATTERNS) {
        return 'io' if $error =~ $pat;
    }

    return 'unexpected';
}

=head2 format_error

Format an error with context for logging or display.

Arguments:
- error: The error string (typically $@)
- context: What was being done when the error occurred (e.g., 'API request')

Returns: Formatted error string

=cut

sub format_error {
    my ($error, $context) = @_;
    $error //= 'unknown error';
    $error = "$error";  # Stringify objects
    $context //= 'operation';

    # Clean up error string
    $error =~ s/\s+at \S+ line \d+\.?\s*$//;  # Strip Perl location
    $error =~ s/\s+$//;  # Trim trailing whitespace

    my $class = classify_error($error);
    return "$context failed ($class): $error";
}

1;

__END__

=head1 ERROR CLASSES

=over 4

=item transport

Network, connection, SSL, and timeout errors.

=item auth

Authentication and authorization failures (401, 403, token issues).

=item validation

Input validation failures (400, 422, malformed data).

=item io

File system errors (missing files, permissions, disk space).

=item unexpected

Anything that doesn't match known patterns.

=back

=cut
