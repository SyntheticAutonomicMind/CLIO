# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Util::Curl;

=head1 NAME

CLIO::Util::Curl - Locate the system curl binary

=head1 DESCRIPTION

Finds the path to the system curl binary, with platform-specific detection
for Unix, macOS, Windows, and iOS/a-Shell environments.

Consolidates what was previously duplicated across CLIO::Compat::HTTP
and CLIO::MCP::Transport::HTTP.

=head1 SYNOPSIS

    use CLIO::Util::Curl qw(locate_curl);
    
    my $curl_path = locate_curl();
    my $has_curl = defined locate_curl();

=cut

use strict;
use warnings;
use utf8;

use Exporter qw(import);
our @EXPORT_OK = qw(locate_curl);

=head1 FUNCTIONS

=head2 locate_curl

Find the path to the system curl binary.

Searches:
- Common filesystem paths on Unix/macOS
- PATH directories
- which-based fallback (iOS/a-Shell compatibility)
- where-based search on Windows

Returns: Path to curl binary, or undef if not found

=cut

sub locate_curl {
    # Windows: use 'where' command
    if ($^O eq 'MSWin32') {
        my $where_curl = `where curl 2>nul`;
        chomp $where_curl;
        return $where_curl if $where_curl && $where_curl =~ /curl/;
        return undef;
    }
    
    # Unix: check common filesystem paths first (fastest)
    for my $path ('/usr/bin/curl', '/bin/curl', '/usr/local/bin/curl', '/opt/homebrew/bin/curl') {
        return $path if -x $path;
    }
    
    # Search PATH directories
    for my $dir (split /:/, $ENV{PATH} || '') {
        my $path = "$dir/curl";
        return $path if -x $path && !-d $path;
    }
    
    # iOS/a-Shell fallback: curl is an ios_system command, not a filesystem path
    my $nulldev = '/dev/null';
    my $which_curl = `which curl 2>$nulldev`;
    chomp $which_curl;
    return $which_curl if $which_curl && $which_curl =~ /curl/;
    
    return undef;
}

1;

__END__

=head1 SEE ALSO

L<CLIO::Compat::HTTP>, L<CLIO::MCP::Transport::HTTP>

=cut
