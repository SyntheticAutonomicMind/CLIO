#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: the provider count claimed in the documentation matches the
# provider registry.
#
# The registry in lib/CLIO/Providers.pm is the single source of truth for
# how many providers CLIO supports. The documentation states that count in
# several places, and those numbers were hand-maintained - so they drifted.
# PR #41 added a provider and updated one README line while leaving a
# second line in the same file, plus four other files, claiming the old
# count.
#
# This test makes the drift detectable: adding a provider without
# updating the documentation fails the suite instead of shipping stale
# numbers.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";

use Test::More;
use CLIO::Providers qw(list_providers);

my $root = "$FindBin::Bin/../..";

# list_providers() returns a sorted list. sort in scalar context is
# undefined, so the count has to come from an array.
my @providers = list_providers();
my $actual = scalar @providers;

# Phrases that state the size of the provider registry. Each pattern is
# anchored to wording that can only mean the registry total - a generic
# "N providers" would also match things like "3 providers support
# streaming", which is not a registry count.
my @patterns = (
    qr/\b(\d+)\s+AI providers\b/,
    qr/\b(\d+)\s+providers are configured\b/,
    qr/\((\d+)\s+providers\)/,
    qr/\ball\s+(\d+)\s+providers\b/,
    qr/\b(\d+)\s+providers in\s+`?Providers\.pm/,
);

# Files that state the count.
my @files = (
    'README.md',
    'AGENTS.md',
    'docs/USER_GUIDE.md',
    'docs/FEATURES.md',
    'docs/ARCHITECTURE.md',
    'docs/DEVELOPER_DOCUMENTATION_GUIDE.md',
    'docs/PROVIDERS.md',
);

my $found_any = 0;

for my $rel (@files) {
    my $path = "$root/$rel";
    SKIP: {
        skip "$rel not found", 1 unless -f $path;

        my $content = do {
            open my $fh, '<:encoding(UTF-8)', $path or die "Cannot read $path: $!";
            local $/;
            <$fh>;
        };

        my $line_no = 0;
        for my $line (split /\n/, $content) {
            $line_no++;
            for my $pattern (@patterns) {
                next unless $line =~ $pattern;
                my $claimed = $1;
                $found_any = 1;
                is($claimed, $actual,
                    "$rel:$line_no claims $claimed providers, registry has $actual")
                    or diag("Update the provider count in $rel:$line_no");
                last;
            }
        }
    }
}

ok($found_any, 'The provider count was actually found and checked');

done_testing();
