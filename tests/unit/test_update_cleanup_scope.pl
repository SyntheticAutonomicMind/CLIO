#!/usr/bin/env perl
# Regression: cleanup scope must use the explicit cleanup dir from
# download_version, not dirname($source_dir). The previous dirname() approach
# would rmtree the entire parent directory (e.g. /tmp when source_dir sat
# at /tmp/foo) on shared systems, walking thousands of unrelated files.

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More;
use File::Path qw(rmtree);
use CLIO::Update;

# Verify the "silent context" path: when caller does `my $x = download_version()`,
# wantarray is false inside _download_and_extract so it returns the extracted
# path only. Make sure Update::switch_to_version's old `my $source_dir = ...`
# code path still works (it now uses list context, but legacy callers might
# not). This guards against accidentally changing _download_and_extract's
# scalar return.
{
    no warnings 'redefine';
    local *CLIO::Update::download_version = sub {
        # Mimic scalar-context return: just the extracted path
        return "/tmp/clio-update-test/inner";
    };
    local *CLIO::Update::install_from_directory = sub { return 1 };
    my $updater = CLIO::Update->new(debug => 0);
    # Should still work - cleanup_dir will be undef, cleanup is skipped
    my $r = $updater->switch_to_version("20260101.1");
    ok($r->{success}, "scalar-context download_version still handled gracefully");
}

# Verify the proper list-context path: cleanup dir used as scope.
{
    my $test_root = "/tmp/clio-cleanup-test-$$";
    mkdir $test_root;
    mkdir "$test_root/version-12345";
    mkdir "$test_root/version-12345/inner";
    mkdir "$test_root/important-sibling";
    open my $fh, '>', "$test_root/important-sibling/data.txt";
    print $fh "do not delete\n";
    close $fh;

    no warnings 'redefine';
    local *CLIO::Update::download_version = sub {
        return ("$test_root/version-12345/inner", "$test_root/version-12345");
    };
    local *CLIO::Update::install_from_directory = sub { return 1 };
    my $updater = CLIO::Update->new(debug => 0);
    my $r = $updater->switch_to_version("20260101.1");

    ok($r->{success}, "list-context download_version succeeded");
    ok(!-d "$test_root/version-12345", "cleanup dir was removed");
    ok(-d "$test_root/important-sibling", "sibling outside cleanup dir preserved");
    ok(-f "$test_root/important-sibling/data.txt", "sibling file preserved");

    open my $fh2, '<', "$test_root/important-sibling/data.txt";
    my $content = <$fh2>;
    close $fh2;
    is($content, "do not delete\n", "sibling content intact");

    rmtree($test_root);
}

done_testing();
