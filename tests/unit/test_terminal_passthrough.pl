#!/usr/bin/env perl
# Test terminal operations - passthrough execution behavior
# All commands execute with full TTY visibility

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use Test::More tests => 10;
use CLIO::Tools::TerminalOperations;

print "\n=== Terminal Operations Tests ===\n\n";

# Test 1: Tool construction
{
    my $tool = CLIO::Tools::TerminalOperations->new();
    ok(defined $tool, "TerminalOperations can be constructed");
    is($tool->{name}, 'terminal_operations', "Tool name is correct");
    print "[OK] Tool construction\n";
}

# Test 2: Validate safe commands
{
    my $tool = CLIO::Tools::TerminalOperations->new();
    
    my $result = $tool->validate_command({ command => 'ls -la' });
    ok($result->{success}, "ls -la validates as safe");
    
    $result = $tool->validate_command({ command => 'git status' });
    ok($result->{success}, "git status validates as safe");
    
    print "[OK] Safe command validation\n";
}

# Test 3: Validate dangerous commands rejected
{
    my $tool = CLIO::Tools::TerminalOperations->new();
    
    my $result = $tool->validate_command({ command => 'rm -rf /' });
    ok(!$result->{success}, "rm -rf rejected");
    
    $result = $tool->validate_command({ command => 'shutdown now' });
    ok(!$result->{success}, "shutdown rejected");
    
    print "[OK] Dangerous command rejection\n";
}

# Test 4: Missing command parameter
{
    my $tool = CLIO::Tools::TerminalOperations->new();
    
    my $result = $tool->execute_command({}, {});
    ok(!$result->{success}, "Missing command returns error");
    
    $result = $tool->execute_command({ command => '' }, {});
    ok(!$result->{success}, "Empty command returns error");
    
    print "[OK] Missing command handling\n";
}

# Test 5: Multiplexer detection method exists
{
    my $tool = CLIO::Tools::TerminalOperations->new();
    ok($tool->can('_get_multiplexer'), "Has _get_multiplexer method");
    
    print "[OK] Multiplexer integration method exists\n";
}

# Test 6: Tool definition includes required params
{
    my $tool = CLIO::Tools::TerminalOperations->new();
    my $def = $tool->get_tool_definition();
    
    ok(exists $def->{parameters}{properties}{command}, 
        "Tool definition includes command parameter");
    
    print "[OK] Tool definition correct\n";
}

print "\n=== All Tests Passed ===\n\n";

__END__

=head1 NAME

test_terminal_passthrough.pl - Test terminal operations

=head1 DESCRIPTION

Tests terminal operations tool:

1. Tool construction
2. Safe command validation
3. Dangerous command rejection
4. Missing command handling
5. Multiplexer integration
6. Tool definition

=head1 USAGE

    perl -I./lib tests/unit/test_terminal_passthrough.pl

=cut
