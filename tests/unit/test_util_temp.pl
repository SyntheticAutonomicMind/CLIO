#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_util_temp.pl - CLIO::Util::Temp resolves a writable directory

=cut

use strict;
use warnings;
use utf8;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../lib";
use File::Temp qw(tempdir);

use CLIO::Util::Temp qw(temp_dir);

my $dir = temp_dir();
ok(defined $dir && length $dir, 'temp_dir returns a value');
ok(-d $dir, "temp_dir returns an existing directory ($dir)");
ok(-w $dir, 'temp_dir returns a writable directory');

# A File::Temp call with an explicit DIR does not consult File::Spec::tmpdir,
# which is the reason this helper exists.
my ($fh, $path) = File::Temp::tempfile('clio_temp_test_XXXXXX', DIR => $dir);
ok($fh, 'tempfile succeeds with DIR from temp_dir');
is(dirname_of($path), dirname_of("$dir/x"), 'file is created inside the chosen directory')
    or diag("path=$path dir=$dir");
close $fh;
unlink $path;

sub dirname_of {
    my ($path) = @_;
    $path =~ s{/[^/]+\z}{};
    # temp_dir may hand back a path with a trailing slash (it echoes the
    # platform temp dir). "/tmp/" and "/tmp" name the same directory, so
    # compare them as the same string rather than failing on the slash.
    $path =~ s{/+\z}{};
    return $path;
}

done_testing();
