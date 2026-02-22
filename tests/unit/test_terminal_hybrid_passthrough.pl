#!/usr/bin/env perl
# Test hybrid passthrough mode with script command

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use CLIO::Tools::TerminalOperations;
use CLIO::Core::Config;
use Data::Dumper;

print "Testing hybrid passthrough mode...\n\n";

# Create tool instance
my $tool = CLIO::Tools::TerminalOperations->new();

# Create minimal config with autodetect enabled
my $config = CLIO::Core::Config->new();
$config->set('terminal_autodetect', 1);

my $context = {
    config => $config,
};

# Test 1: Simple echo (non-interactive - should use capture mode)
print "Test 1: Simple echo command (capture mode)\n";
my $result1 = $tool->execute_command({
    command => 'echo "Hello from test"',
}, $context);

print "Result structure:\n" . Dumper($result1) . "\n";

print "\nAll tests completed.\n";
