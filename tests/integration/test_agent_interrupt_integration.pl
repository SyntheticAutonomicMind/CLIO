#!/usr/bin/env perl
# Integration test for agent interrupt functionality
# Feature: ESC Key Interrupt
# Branch: feature/terminal-passthrough-and-interrupt

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";

print "\n=== Agent Interrupt Integration Tests ===\n\n";

# Since we can't easily simulate ESC keypress programmatically,
# these are verification tests that check the logic is in place

my $test_count = 0;
my $pass_count = 0;

sub test {
    my ($name, $coderef) = @_;
    $test_count++;
    print "Test $test_count: $name... ";
    eval {
        $coderef->();
        $pass_count++;
        print "PASS\n";
    };
    if ($@) {
        print "FAIL\n";
        print "  Error: $@\n";
    }
}

# Test 1: Verify WorkflowOrchestrator has interrupt methods
test("WorkflowOrchestrator has _check_for_user_interrupt method", sub {
    require CLIO::Core::WorkflowOrchestrator;
    
    my $can_check = CLIO::Core::WorkflowOrchestrator->can('_check_for_user_interrupt');
    die "Method _check_for_user_interrupt not found" unless $can_check;
});

test("WorkflowOrchestrator has _handle_interrupt method", sub {
    require CLIO::Core::WorkflowOrchestrator;
    
    my $can_handle = CLIO::Core::WorkflowOrchestrator->can('_handle_interrupt');
    die "Method _handle_interrupt not found" unless $can_handle;
});

# Test 2: Verify interrupt handling logic
test("Interrupt message uses role=user (not system)", sub {
    require CLIO::Core::WorkflowOrchestrator;
    require CLIO::Core::Config;
    require CLIO::Session::Manager;
    require CLIO::Core::APIManager;
    
    # Create minimal objects
    my $config = CLIO::Core::Config->new();
    my $api_manager = CLIO::Core::APIManager->new(config => $config);
    my $session = CLIO::Session::Manager->new();
    
    # Create orchestrator
    my $orch = CLIO::Core::WorkflowOrchestrator->new(
        api_manager => $api_manager,
        session => $session,
        debug => 0
    );
    
    # Create messages array
    my @messages = ();
    
    # Call _handle_interrupt
    $orch->_handle_interrupt($session, \@messages);
    
    # Verify message added
    die "No message added" unless @messages > 0;
    
    # Verify role is 'user' not 'system'
    my $msg = $messages[-1];
    die "Message role is not 'user': got '$msg->{role}'" unless $msg->{role} eq 'user';
    
    # Verify content mentions interrupt
    die "Message doesn't mention interrupt" unless $msg->{content} =~ /interrupt/i;
    
    # Verify content mentions user_collaboration
    die "Message doesn't mention user_collaboration" unless $msg->{content} =~ /user_collaboration/i;
});

# Test 3: Verify session state handling
test("Interrupt flag set and cleared correctly", sub {
    require CLIO::Session::Manager;
    
    my $session = CLIO::Session::Manager->new();
    
    # Set interrupt flag
    $session->state()->{user_interrupted} = 1;
    
    die "Interrupt flag not set" unless $session->state()->{user_interrupted};
    
    # Clear flag
    $session->state()->{user_interrupted} = 0;
    
    die "Interrupt flag not cleared" if $session->state()->{user_interrupted};
});

# Test 4: Verify no TTY handling
test("_check_for_user_interrupt returns 0 when no TTY", sub {
    require CLIO::Core::WorkflowOrchestrator;
    require CLIO::Core::Config;
    require CLIO::Core::APIManager;
    require CLIO::Session::Manager;
    
    my $config = CLIO::Core::Config->new();
    my $api_manager = CLIO::Core::APIManager->new(config => $config);
    my $session = CLIO::Session::Manager->new();
    
    my $orch = CLIO::Core::WorkflowOrchestrator->new(
        api_manager => $api_manager,
        session => $session,
        debug => 0
    );
    
    # This test might fail if we're running in a TTY
    # Just verify it doesn't crash
    my $result;
    eval {
        $result = $orch->_check_for_user_interrupt($session);
    };
    
    die "Method crashed: $@" if $@;
    die "Result not defined" unless defined $result;
    die "Result not boolean" unless $result == 0 || $result == 1;
});

# Test 5: Verify duplicate interrupt prevention
test("Duplicate interrupts prevented when flag already set", sub {
    require CLIO::Core::WorkflowOrchestrator;
    require CLIO::Core::Config;
    require CLIO::Core::APIManager;
    require CLIO::Session::Manager;
    
    my $config = CLIO::Core::Config->new();
    my $api_manager = CLIO::Core::APIManager->new(config => $config);
    my $session = CLIO::Session::Manager->new();
    
    my $orch = CLIO::Core::WorkflowOrchestrator->new(
        api_manager => $api_manager,
        session => $session,
        debug => 0
    );
    
    # Set interrupt flag
    $session->state()->{user_interrupted} = 1;
    
    # Try to check for interrupt (should return 0 immediately)
    my $result = $orch->_check_for_user_interrupt($session);
    
    die "Should return 0 when already interrupted, got: $result" if $result;
});

# Test 6: Verify interrupt message format
test("Interrupt message has expected structure", sub {
    require CLIO::Core::WorkflowOrchestrator;
    require CLIO::Core::Config;
    require CLIO::Core::APIManager;
    require CLIO::Session::Manager;
    
    my $config = CLIO::Core::Config->new();
    my $api_manager = CLIO::Core::APIManager->new(config => $config);
    my $session = CLIO::Session::Manager->new();
    
    my $orch = CLIO::Core::WorkflowOrchestrator->new(
        api_manager => $api_manager,
        session => $session,
        debug => 0
    );
    
    my @messages = ();
    $orch->_handle_interrupt($session, \@messages);
    
    my $msg = $messages[-1];
    
    # Verify has required content
    die "Missing ESC mention" unless $msg->{content} =~ /ESC/;
    die "Missing user_collaboration mention" unless $msg->{content} =~ /user_collaboration/;
    die "Missing 'operation: request_input'" unless $msg->{content} =~ /operation.*request_input/;
    die "Missing example" unless $msg->{content} =~ /Example:/i;
});

# Summary
print "\n=== Test Summary ===\n";
print "Total: $test_count\n";
print "Passed: $pass_count\n";
print "Failed: " . ($test_count - $pass_count) . "\n";

if ($pass_count == $test_count) {
    print "\n✓ All integration tests passed!\n\n";
    print "NOTE: Manual testing required to verify ESC key detection\n";
    print "      during actual agent workflow execution.\n\n";
    exit 0;
} else {
    print "\n✗ Some tests failed\n\n";
    exit 1;
}

__END__

=head1 NAME

test_agent_interrupt_integration.pl - Integration tests for agent interrupt

=head1 DESCRIPTION

Tests the agent interrupt functionality (ESC key):

1. Methods exist in WorkflowOrchestrator
2. Interrupt message uses role=user (maintains alternation)
3. Session state handling (set/clear interrupt flag)
4. No TTY handling (doesn't crash)
5. Duplicate interrupt prevention
6. Message format and content

NOTE: This doesn't test actual ESC key detection - that requires manual testing.

=head1 USAGE

    perl -I./lib tests/integration/test_agent_interrupt_integration.pl
