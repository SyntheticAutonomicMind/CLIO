#!/usr/bin/env perl
# Test isolated configuration and no-color options
# Tests CLI flag handling and source-level verification (no subprocess invocation)

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

my $clio_bin = "$RealBin/../../clio";

# Verify clio exists
ok(-x $clio_bin, "clio executable exists");

# Read the clio source once for multiple tests
open my $clio_fh, '<', $clio_bin or die "Cannot read clio: $!";
my $clio_source = do { local $/; <$clio_fh> };
close $clio_fh;

# Test 1: clio has --config option handling
like($clio_source, qr/--config.*ARGV/, "clio parses --config from ARGV");
like($clio_source, qr/config_dir_override/, "clio uses config_dir_override variable");

# Test 2: clio has --no-color option handling
like($clio_source, qr/--no-color/, "clio parses --no-color from ARGV");
like($clio_source, qr/NO_COLOR/, "clio sets NO_COLOR env var");

# Test 3: --help text includes key options
like($clio_source, qr/CLIO - Command Line/, "--help contains expected header");
like($clio_source, qr/--config\s+.*config/i, "--help documents --config option");
like($clio_source, qr/--no-color\s+.*color/i, "--help documents --no-color option");
like($clio_source, qr/NO_COLOR\s+.*color/i, "--help documents NO_COLOR env var");

# Test 4: --help exits early
like($clio_source, qr/--help.*\n.*exit\s+0/s, "--help block exits cleanly");

# Test 5: PathResolver respects config override
{
    require CLIO::Util::PathResolver;
    my $tmp = tempdir(CLEANUP => 1);
    CLIO::Util::PathResolver::init(base_dir => $tmp);
    my $base = CLIO::Util::PathResolver::get_base_dir();
    is($base, $tmp, "PathResolver respects base_dir override");
}

# Test 6: Chat.pm checks NO_COLOR env var
{
    my $chat_pm = "$RealBin/../../lib/CLIO/UI/Chat.pm";
    ok(-f $chat_pm, "Chat.pm exists");
    open my $fh, '<', $chat_pm or die "Cannot read Chat.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    like($content, qr/NO_COLOR/, "Chat.pm references NO_COLOR env var");
    like($content, qr/no_color.*\?.*0.*:.*1/s, "Chat.pm has conditional color logic");
}

done_testing();
