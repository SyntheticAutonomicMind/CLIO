# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Test::WarningAttribution;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(classify_warnings is_vendor_line warning_location);

=head1 NAME

CLIO::Test::WarningAttribution - Group test warnings by provenance and location

=head1 DESCRIPTION

The strict runner re-runs every test under C<-W> and must answer two questions
separately: did the test pass, and did production code warn. This module turns
raw stderr into findings grouped by warning label and location, splitting
warnings that come from vendor perl from warnings that come from CLIO.

A warning raised inside a vendor module reports the vendor location. When a
C<# clio-frame> line follows it (see L<CLIO::Test::WarningTrace>), the caller
is the actionable frame and the warning is attributed there instead. A vendor
warning with no CLIO frame is informational.

=head1 SYNOPSIS

    use CLIO::Test::WarningAttribution qw(classify_warnings);

    my ($findings, $vendor_count) =
        classify_warnings($stderr, \@warning_patterns, '/repo/root');

=cut

sub _strip_ansi {
    my ($s) = @_;
    $s =~ s/\e\[[0-9;]*m//g;
    return $s;
}

=head2 is_vendor_line

Arguments: $line
Returns: Boolean - true when the blame line names a system or CPAN perl tree.

=cut

sub is_vendor_line {
    my ($line) = @_;
    return 1 if $line =~ m{/System/Library/Perl/};
    return 1 if $line =~ m{/Library/Perl/};
    return 1 if $line =~ m{\.cpan\b|/\.cpan/};
    return 1 if $line =~ m{at\s+\S*perl/\S+/\S+\.pm\s+line\s+\d+};
    return 0;
}

=head2 warning_location

Arguments: $line, $repo_root (optional)
Returns: "file:line", relative to $repo_root when the path is inside it.

=cut

sub warning_location {
    my ($line, $repo_root) = @_;
    if ($line =~ m{\bat\s+(\S+?)\s+line\s+(\d+)}) {
        my ($file, $lineno) = ($1, $2);
        $file =~ s{^\Q$repo_root\E/}{} if defined $repo_root && length $repo_root;
        return "$file:$lineno";
    }
    return '(unknown location)';
}

sub _summarize {
    my ($line) = @_;
    $line =~ s/\s*at\s+\S+\s+line\s+\d+.*$//;
    $line =~ s/^\s+|\s+$//g;
    return $line;
}

=head2 classify_warnings

Arguments:
  $stderr    (required) - captured stderr
  $patterns  (required) - arrayref of [qr//, label] pairs
  $repo_root (optional) - used to make blame paths relative

Returns: (\@findings, $vendor_count). Each finding is
    { label => ..., count => N, places => [ { location, count, message } ] }

=cut

sub classify_warnings {
    my ($stderr, $patterns, $repo_root) = @_;
    my (%found, $vendor);
    $vendor = 0;
    return ([], 0) unless defined $stderr;
    $patterns ||= [];

    my @lines = split /\n/, $stderr;

    for my $pat (@$patterns) {
        my ($re, $label) = @$pat;
        for my $i (0 .. $#lines) {
            my $line = $lines[$i];
            next unless $line =~ m{$re};
            my $clean = _strip_ansi($line);

            # A warning raised inside a vendor module reports the vendor
            # location; the CLIO frame on the following line is the caller
            # that handed it the bad value.
            my $frame;
            if ($i < $#lines
                && $lines[$i + 1] =~ /^#\s*clio-frame\s+(\S+)\s+line\s+(\d+)/) {
                $frame = "$1:$2";
            }

            if (!$frame && is_vendor_line($clean)) {
                $vendor++;
                next;
            }

            my $loc = $frame // warning_location($clean, $repo_root);
            $found{$label} ||= {};
            $found{$label}{$loc} ||= { count => 0, message => _summarize($clean) };
            $found{$label}{$loc}{count}++;
        }
    }

    my @findings;
    for my $label (sort keys %found) {
        my @places = map {
            {
                location => $_,
                count    => $found{$label}{$_}{count},
                message  => $found{$label}{$_}{message},
            }
        } sort keys %{ $found{$label} };
        my $count = 0;
        $count += $_->{count} for @places;
        push @findings, { label => $label, count => $count, places => \@places };
    }
    return (\@findings, $vendor);
}

1;

__END__

=head1 LICENSE

GPL-3.0-only

=cut
