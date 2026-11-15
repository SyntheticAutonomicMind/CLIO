# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Util::Temp;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(temp_dir);

=head1 NAME

CLIO::Util::Temp - Resolve a writable temporary directory

=head1 SYNOPSIS

    use CLIO::Util::Temp qw(temp_dir);
    my $dir = temp_dir();
    my ($fh, $path) = File::Temp::tempfile('clio_XXXXXX', DIR => $dir);

=head1 DESCRIPTION

File::Spec::tmpdir emits "Use of uninitialized value" warnings when the
temporary-directory environment variables are unset and the process runs under
C<-w>; the module's own C<local $^W> does not suppress them because the warning
fires inside a lexical scope it does not control. It also caches by comparing
unset variables. Passing an explicit C<DIR> to File::Temp avoids the call
entirely, and this module supplies that directory.

The first environment variable that names an existing writable directory wins.
If none does, C</tmp> is used on Unix and C<C:\Temp> or the current directory
on Windows.

=cut

=head2 temp_dir

Returns: Path to a writable temporary directory.

=cut

sub temp_dir {
    for my $key (qw(TMPDIR TEMP TMP)) {
        my $value = $ENV{$key};
        next unless defined $value && length $value;
        next unless -d $value && -w $value;
        return $value;
    }

    if ($^O eq 'MSWin32') {
        return 'C:\\Temp' if -d 'C:\\Temp';
        return '.';
    }
    return '/tmp';
}

1;

__END__

=head1 LICENSE

GPL-3.0-only

=cut
