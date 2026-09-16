#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: config test-mode isolation must not depend on how the
# script path was typed. _config_in_test_mode() used to match the caller's
# literal path against m{/tests/} or m{^\.\.?/tests/}, so invoking this file
# as `perl tests/unit/x.pl` (no leading ./) matched neither, isolation
# silently turned off, and the test wrote to the developer's real ~/.clio.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::RealBin/../../lib";

use Test::More;
use Cwd qw(abs_path);

my $SELF = "$FindBin::RealBin/" . ($0 =~ m{([^/]+)$})[0];
$SELF = $0 unless -f $SELF;

# ---------------------------------------------------------------------------
# Probe mode: report this process's own isolation state, then exit.
# ---------------------------------------------------------------------------
if ($ENV{CLIO_ISOLATION_PROBE}) {
    require CLIO::Core::Config;
    require CLIO::Util::ConfigPath;
    my $c = CLIO::Core::Config->new();
    my $real = CLIO::Util::ConfigPath::get_config_dir();
    print "persist=$c->{persist}\n";
    print "is_real_dir=", ($c->{config_dir} eq $real ? 'yes' : 'no'), "\n";
    exit 0;
}

use CLIO::Core::Config;
use CLIO::Util::ConfigPath qw(get_config_dir);

# ---------------------------------------------------------------------------
# In-process: constructing Config from under tests/ is always isolated.
# ---------------------------------------------------------------------------
my $cfg = CLIO::Core::Config->new();
is($cfg->{persist}, 0, 'test-mode Config does not persist');
isnt($cfg->{config_dir}, get_config_dir(),
    'test-mode Config config_dir is not the real ~/.clio');

# A production-style caller must NOT be isolated, or real runs would lose
# their configuration. Covered by the "-e one-liner" probe at the end.
# (_config_in_test_mode() reads caller(1) because Config::new() calls it, so
# it is exercised through real invocations rather than called directly.)

# ---------------------------------------------------------------------------
# Subprocess: the same file, invoked three ways, must isolate identically.
# ---------------------------------------------------------------------------
my $perl = $^X;
my $repo = abs_path("$FindBin::RealBin/../..");
my $lib  = "$repo/lib";
my $self_name = ($0 =~ m{([^/]+)$})[0];

my %spellings = (
    'relative (tests/unit/...)' => "tests/unit/$self_name",
    'dot-relative (./tests/...)' => "./tests/unit/$self_name",
    'absolute'                   => $SELF,
);

for my $label (sort keys %spellings) {
    my $path = $spellings{$label};
    local $ENV{CLIO_ISOLATION_PROBE} = 1;
    delete local $ENV{CLIO_TEST};

    # cd in a subshell so the child still receives the literal path spelling
    # (that is the behaviour under test) without moving the parent's CWD.
    my $out = qx{cd "$repo" && $perl -Ilib $path 2>&1};
    my @lines = split /\n/, $out;
    chomp @lines;

    my ($persist) = grep { /^persist=/ } @lines;
    my ($is_real) = grep { /^is_real_dir=/ } @lines;
    ok(defined $persist && defined $is_real, "$label: probe reported status")
        or diag("child output: $out");

    is($persist, 'persist=0', "$label: isolated (persist=0)");
    is($is_real, 'is_real_dir=no', "$label: never points at real ~/.clio");
}

# A caller that is not under tests/ keeps the real config and keeps writing.
{
    local $ENV{CLIO_TEST};
    delete $ENV{CLIO_TEST};
    my $probe = <<'PROBE';
use CLIO::Core::Config;
my $c = CLIO::Core::Config->new();
print "persist=$c->{persist}\n";
PROBE
    my $out = qx{$perl -I"$lib" -e '$probe' 2>&1};
    like($out, qr/persist=1/,
        'non-test caller still persists to the real config');
}

done_testing();
