# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Util::CABundle;

=head1 NAME

CLIO::Util::CABundle - Centralized CA certificate bundle detection

=head1 DESCRIPTION

Detects the platform-appropriate CA certificate bundle and sets
C<PERL_LWP_SSL_CA_FILE> for LWP-based HTTPS. Also provides
C<find_ca_bundle()> for non-LWP consumers (curl, etc.).

Consolidates what was previously duplicated across APIManager,
GitHubCopilotModelsAPI, and Compat::HTTP.

=head1 SYNOPSIS

    use CLIO::Util::CABundle;
    
    my $ca_path = find_ca_bundle();
    # $ENV{PERL_LWP_SSL_CA_FILE} is already set at compile time

=cut

use strict;
use warnings;
use utf8;

use CLIO::Core::Logger qw(log_warning);
use Exporter qw(import);
our @EXPORT_OK = qw(find_ca_bundle);

# Shared CA bundle path (populated by BEGIN block)
our $CA_BUNDLE_PATH;

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# _search_ca_locations must be defined ABOVE the BEGIN block
# because it's called at compile time (before the rest of
# the file is parsed).
sub _search_ca_locations {
    my @paths = (
        # Environment variable (runtime override, checked separately above)
        ($ENV{SSL_CERT_FILE} && -f $ENV{SSL_CERT_FILE} && -r $ENV{SSL_CERT_FILE})
            ? $ENV{SSL_CERT_FILE} : (),
        # Debian/Ubuntu and derivatives
        '/etc/ssl/certs/ca-certificates.crt',
        # RHEL/CentOS/Fedora
        '/etc/pki/tls/certs/ca-bundle.crt',
        # OpenBSD / macOS default
        '/etc/ssl/cert.pem',
        # macOS Homebrew (Intel)
        '/usr/local/etc/openssl/cert.pem',
        # macOS Homebrew (Apple Silicon)
        '/opt/homebrew/etc/openssl@3/cert.pem',
        # iOS / a-Shell
        "$ENV{HOME}/Documents/cacert.pem",
        "$ENV{HOME}/../cacert.pem",
        '/tmp/cacert.pem',
    );
    
    for my $path (@paths) {
        next unless defined $path && length $path;
        if (-f $path && -r $path) {
            return $path;
        }
    }
    
    return undef;
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Set PERL_LWP_SSL_CA_FILE at compile time so LWP sees it
# before any HTTPS connection is attempted.
BEGIN {
    # Skip if already configured by user or environment
    if ($ENV{PERL_LWP_SSL_CA_FILE}) {
        $CA_BUNDLE_PATH = $ENV{PERL_LWP_SSL_CA_FILE};
    } else {
        $CA_BUNDLE_PATH = _search_ca_locations();
        if ($CA_BUNDLE_PATH) {
            $ENV{PERL_LWP_SSL_CA_FILE} = $CA_BUNDLE_PATH;
        } else {
            log_debug('CABundle', "No CA bundle found in common locations. HTTPS requests may fail.");
        }
    }
}

=head1 FUNCTIONS

=head2 find_ca_bundle

Find the platform-appropriate CA certificate bundle.

Searches for CA certificates in standard Unix/Linux/macOS locations.
Returns undef if no bundle is found.

Returns: Path to CA bundle file, or undef

=cut

sub find_ca_bundle {
    # Return cached result if already searched
    return $CA_BUNDLE_PATH if defined $CA_BUNDLE_PATH;
    
    # Check environment variable first (set by bundled runtimes, distros, etc.)
    if ($ENV{SSL_CERT_FILE} && -f $ENV{SSL_CERT_FILE} && -r $ENV{SSL_CERT_FILE}) {
        $CA_BUNDLE_PATH = $ENV{SSL_CERT_FILE};
        return $CA_BUNDLE_PATH;
    }
    
    $CA_BUNDLE_PATH = _search_ca_locations();
    return $CA_BUNDLE_PATH;
}

1;

__END__

=head1 SEE ALSO

L<CLIO::Core::APIManager>, L<CLIO::Compat::HTTP>

=cut
