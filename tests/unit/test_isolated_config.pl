#!/usr/bin/env perl
# Test isolated configuration and no-color options
# This ensures CLIO can run in isolated mode for testing

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use File::Spec;

# Test directory for isolated config
my $test_dir = tempdir(CLEANUP => 1);
my $clio_bin = "$RealBin/../../clio";

# Verify clio exists
ok(-x $clio_bin, "clio executable exists");

# Test 1: --config option creates config in specified directory
{
    my $config_dir = File::Spec->catdir($test_dir, 'config-test');
    
    # Running CLIO with --config should use that directory
    # We use --help since it exits early and doesn't require full startup
    my $output = `$clio_bin --config $config_dir --help 2>&1`;
    my $exit_code = $? >> 8;
    
    is($exit_code, 0, "--config with --help exits cleanly");
    like($output, qr/CLIO - Command Line/, "--help shows expected output");
}

# Test 2: --no-color option is accepted
{
    my $output = `$clio_bin --no-color --help 2>&1`;
    my $exit_code = $? >> 8;
    
    is($exit_code, 0, "--no-color with --help exits cleanly");
    like($output, qr/CLIO - Command Line/, "--no-color --help shows expected output");
}

# Test 3: NO_COLOR environment variable is documented
{
    my $output = `$clio_bin --help 2>&1`;
    like($output, qr/NO_COLOR/, "Help mentions NO_COLOR environment variable");
}

# Test 4: --config option appears in help
{
    my $output = `$clio_bin --help 2>&1`;
    like($output, qr/--config.*config directory/, "Help documents --config option");
}

# Test 5: --no-color option appears in help
{
    my $output = `$clio_bin --help 2>&1`;
    like($output, qr/--no-color.*ANSI color/, "Help documents --no-color option");
}

# Test 6: Verify Chat.pm checks NO_COLOR env var
{
    require CLIO::UI::Chat;
    
    # Check that the module loads
    ok(1, "CLIO::UI::Chat module loads");
    
    # We can't easily test the constructor without mocking,
    # but we can verify the NO_COLOR check is in the code
    my $chat_pm = "$RealBin/../../lib/CLIO/UI/Chat.pm";
    open my $fh, '<', $chat_pm or die "Cannot read Chat.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    like($content, qr/NO_COLOR/, "Chat.pm references NO_COLOR env var");
    like($content, qr/no_color.*\?.*0.*:.*1/s, "Chat.pm has conditional color based on no_color");
}

done_testing();
