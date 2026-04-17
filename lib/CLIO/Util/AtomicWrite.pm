package CLIO::Util::AtomicWrite;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use Exporter 'import';

our @EXPORT_OK = qw(atomic_write);

=head1 NAME

CLIO::Util::AtomicWrite - Atomic file write utility

=head1 DESCRIPTION

Provides a single atomic_write() function that writes content to a file
via temp-file-then-rename, preventing corruption from process kills or
crashes during write.

=head1 SYNOPSIS

    use CLIO::Util::AtomicWrite qw(atomic_write);

    # Write raw bytes (JSON from encode_json)
    atomic_write($path, $json_bytes);

    # Write with UTF-8 encoding layer
    atomic_write($path, $text, encoding => 'UTF-8');

    # Write with restricted permissions
    atomic_write($path, $data, mode => 0600);

=cut

sub atomic_write {
    my ($path, $content, %opts) = @_;

    my $encoding = $opts{encoding};
    my $mode     = $opts{mode};

    # Use PID in temp name to prevent race conditions with multiple agents
    my $temp = "${path}.tmp.$$";

    my $open_mode = $encoding ? ">:encoding($encoding)" : '>:raw';
    open my $fh, $open_mode, $temp
        or croak "Cannot create temp file '$temp': $!";

    chmod($mode, $temp) if defined $mode;

    print $fh $content;
    close $fh or croak "Cannot close temp file '$temp': $!";

    rename $temp, $path
        or croak "Cannot rename '$temp' to '$path': $!";

    return 1;
}

1;
