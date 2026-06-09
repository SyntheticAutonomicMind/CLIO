# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Util::UUID;

=head1 NAME

CLIO::Util::UUID - Centralized UUID v4 generation

=head1 DESCRIPTION

Generates RFC 9562 compliant UUID v4 identifiers with proper version and
variant bits. Uses C<int(rand())> which is sufficient for CLIO's usage
patterns (request tracking, session IDs, turn IDs).

Consolidates what was previously duplicated across APIManager,
GitHubCopilotModelsAPI, Session::Manager, and Session::State.

=head1 SYNOPSIS

    use CLIO::Util::UUID qw(uuid_v4);
    
    my $id = uuid_v4();  # e.g., "a3f2b8c1-4d5e-6f78-9abc-def012345678"

=cut

use strict;
use warnings;
use utf8;

use Exporter qw(import);
our @EXPORT_OK = qw(uuid_v4);

=head1 FUNCTIONS

=head2 uuid_v4

Generate an RFC 9562 UUID v4 identifier.

Returns: UUID string in standard format (xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx)

=cut

sub uuid_v4 {
    # Generate 32 random hex digits
    my @hex = ('0'..'9', 'a'..'f');
    my $uuid = '';
    for my $i (1..32) {
        $uuid .= $hex[int(rand(16))];
        $uuid .= '-' if $i == 8 || $i == 12 || $i == 16 || $i == 20;
    }
    # Set version (4) at position 14 (index 14 in the string)
    substr($uuid, 14, 1) = '4';
    # Set variant (8, 9, a, or b) at position 19
    substr($uuid, 19, 1) = $hex[8 + int(rand(4))];
    return $uuid;
}

1;

__END__

=head1 SEE ALSO

L<CLIO::Core::APIManager>, L<CLIO::Core::GitHubCopilotModelsAPI>,
L<CLIO::Session::Manager>, L<CLIO::Session::State>

RFC 9562: L<https://datatracker.ietf.org/doc/rfc9562/>

=cut
