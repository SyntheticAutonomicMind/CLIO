# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Util::Proxy;

=head1 NAME

CLIO::Util::Proxy - Shared proxy environment variable resolution

=head1 DESCRIPTION

Resolves proxy configuration from standard environment variables.
Consolidates what was duplicated between CLIO::Compat::HTTP and CLIO::Update.

=head1 SYNOPSIS

    use CLIO::Util::Proxy qw(resolve_proxy_url);
    
    my $proxy = resolve_proxy_url();           # from env vars
    my $proxy = resolve_proxy_url($explicit);  # explicit override

=cut

use strict;
use warnings;
use utf8;

use Exporter qw(import);
our @EXPORT_OK = qw(resolve_proxy_url);

=head1 FUNCTIONS

=head2 resolve_proxy_url

Resolve the proxy URL from explicit parameter or environment variables.

Checks standard proxy environment variables in priority order:
  HTTPS_PROXY, HTTP_PROXY, ALL_PROXY,
  https_proxy, http_proxy, all_proxy

Arguments:
    $explicit - Explicit proxy URL to check first (optional)

Returns: Proxy URL string, or empty string if none configured

=cut

sub resolve_proxy_url {
    my ($explicit) = @_;
    
    # Explicit parameter takes precedence
    if ($explicit && length $explicit) {
        return $explicit if $explicit =~ m{^https?://};
        return $explicit if $explicit =~ m{^socks[45]h?://};
    }
    
    # Check environment variables (standard convention, uppercase preferred)
    for my $env (qw(HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy all_proxy)) {
        next unless $ENV{$env};
        if ($ENV{$env} =~ m{^https?://} || $ENV{$env} =~ m{^socks[45]h?://}) {
            return $ENV{$env};
        }
    }
    
    return '';
}

1;

__END__

=head1 SEE ALSO

L<CLIO::Compat::HTTP>, L<CLIO::Update>

=cut
