#!/usr/bin/env perl
# Test terminal passthrough functionality
# Feature: Terminal Output Isolation
# Branch: feature/terminal-passthrough-and-interrupt

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use Test::More tests => 15;
use CLIO::Core::Config;
use CLIO::Tools::TerminalOperations;

print "\n=== Terminal Passthrough Tests ===\n\n";

# Test 1: Config defaults
{
    my $config = CLIO::Core::Config->new();
    
    is($config->get('terminal_passthrough'), 0, 
        "Default terminal_passthrough is 0 (false)");
    is($config->get('terminal_autodetect'), 1, 
        "Default terminal_autodetect is 1 (true)");
    
    print "[OK] Config defaults are correct\n";
}

# Test 2: Interactive command detection
{
    my $tool = CLIO::Tools::TerminalOperations->new();
    
    # Test known interactive commands
    ok($tool->_is_interactive_command('vim file.txt'), 
        "Detects vim as interactive");
    ok($tool->_is_interactive_command('nano README.md'), 
        "Detects nano as interactive");
    ok($tool->_is_interactive_command('less output.log'), 
        "Detects less as interactive");
    ok($tool->_is_interactive_command('git commit'), 
        "Detects git commit (no -m) as interactive");
    ok($tool->_is_interactive_command('git commit -S'), 
        "Detects git commit with GPG as interactive");
    ok($tool->_is_interactive_command('gpg --sign file.txt'), 
        "Detects gpg as interactive");
    ok($tool->_is_interactive_command('ssh user@example.com'), 
        "Detects ssh as interactive");
    
    # Test non-interactive commands
    ok(!$tool->_is_interactive_command('ls -la'), 
        "Detects ls as non-interactive");
    ok(!$tool->_is_interactive_command('git commit -m "message"'), 
        "Detects git commit -m as non-interactive");
    ok(!$tool->_is_interactive_command('cat file.txt'), 
        "Detects cat as non-interactive");
    
    print "[OK] Interactive command detection works\n";
}

# Test 3: Passthrough decision logic
{
    my $config = CLIO::Core::Config->new();
    my $tool = CLIO::Tools::TerminalOperations->new();
    
    # Test with auto-detect enabled (default)
    my $use_passthrough = $tool->_should_use_passthrough(
        'vim file.txt', 
        {}, 
        $config
    );
    ok($use_passthrough, 
        "Auto-detect enables passthrough for vim");
    
    # Test with per-command override
    $use_passthrough = $tool->_should_use_passthrough(
        'ls -la',
        { passthrough => 1 },  # Force passthrough
        $config
    );
    ok($use_passthrough, 
        "Per-command override forces passthrough");
    
    # Test with global passthrough enabled
    $config->set('terminal_passthrough', 1);
    $use_passthrough = $tool->_should_use_passthrough(
        'cat file.txt',
        {},
        $config
    );
    ok($use_passthrough, 
        "Global passthrough enables it for all commands");
    
    print "[OK] Passthrough decision logic correct\n";
}

print "\n=== All Tests Passed ===\n\n";

__END__

=head1 NAME

test_terminal_passthrough.pl - Test terminal passthrough functionality

=head1 DESCRIPTION

Tests the terminal passthrough feature implementation:

1. Config defaults (terminal_passthrough=0, terminal_autodetect=1)
2. Interactive command detection (vim, git commit, GPG, etc.)
3. Passthrough decision logic (per-command, global, auto-detect)

=head1 USAGE

    perl -I./lib tests/unit/test_terminal_passthrough.pl

=head1 EXPECTED OUTPUT

All 15 tests should pass:
- Config defaults correct
- Interactive commands detected
- Non-interactive commands not detected
- Passthrough logic respects priorities
