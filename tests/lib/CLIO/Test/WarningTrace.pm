# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Test::WarningTrace;

use strict;
use warnings;

=head1 NAME

CLIO::Test::WarningTrace - Print the nearest CLIO stack frame after each warning

=head1 SYNOPSIS

    CLIO_REPO_ROOT=/path/to/CLIO perl -Itests/lib -MCLIO::Test::WarningTrace test.pl

=head1 DESCRIPTION

Perl reports a warning at the line that raised it. When that line is inside a
vendor module (C<lib.pm>, a CPAN library), the reported location is useless for
diagnosis: the actionable frame is the CLIO code that handed the module a bad
value.

This module installs a C<$SIG{__WARN__}> handler that prints the warning as
normal, then prints the nearest stack frame under C<$ENV{CLIO_REPO_ROOT}/lib>.
The strict runner uses that line to attribute the warning to production CLIO
code instead of discarding it as vendor noise.

Only production frames are reported. A warning raised by a test calling a
vendor module would otherwise be attributed to the test file, turning every
test into a CLIO warning and hiding the production defects among them.

C<$ENV{CLIO_WARN_FRAME_PREFIX}> overrides C<lib> for testing the attribution
path from a synthetic tree.

The handler is a no-op when C<CLIO_REPO_ROOT> is unset, so loading the module
without the runner only adds the default warning passthrough.

=cut

our $IN_WARN = 0;

BEGIN {
    my $repo_root = $ENV{CLIO_REPO_ROOT};
    $repo_root =~ s{/+$}{} if defined $repo_root;
    my $prefix = defined $ENV{CLIO_WARN_FRAME_PREFIX} && length $ENV{CLIO_WARN_FRAME_PREFIX}
        ? $ENV{CLIO_WARN_FRAME_PREFIX}
        : 'lib';
    $prefix =~ s{/+$}{};

    $SIG{__WARN__} = sub {
        return if $IN_WARN;
        local $IN_WARN = 1;

        my $msg = defined $_[0] ? $_[0] : '';
        print STDERR $msg;
        print STDERR "\n" if length($msg) && $msg !~ /\n\z/;

        return unless defined $repo_root && length $repo_root;

        # Depth is capped: a warning raised through deep recursion should not
        # flood stderr, and the nearest production frame is the actionable one.
        my $wanted = "$repo_root/$prefix/";
        for my $i (0 .. 20) {
            my @frame = caller($i);
            last unless @frame;
            my ($pkg, $file, $line, $sub) = @frame;
            next unless defined $file && length $file;
            next unless index($file, $wanted) == 0;

            $file =~ s{^\Q$repo_root\E/?}{};
            printf STDERR "# clio-frame %s line %d %s\n", $file, $line, defined $sub ? $sub : '';
            last;
        }
    };
}

1;

__END__

=head1 LICENSE

GPL-3.0-only

=cut
