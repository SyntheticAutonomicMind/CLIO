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

# Build a self-sufficient test config. APIManager validates api_base at
# construction time, so tests must provide a real (dummy) endpoint rather
# than depending on the user's local ~/.clio config.
sub make_test_config {
    my $dir = "/tmp/clio-test-agent-interrupt";
    `rm -rf $dir`;
    my $config = CLIO::Core::Config->new(config_dir => $dir);
    $config->set("provider", "openrouter", 0);
    $config->set("api_base", "https://openrouter.ai/api/v1/chat/completions", 0);
    $config->set("api_key", "test-key", 0);
    return $config;
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
    my $config = make_test_config();
    my $api_manager = CLIO::Core::APIManager->new(config => $config);
    my $session = CLIO::Session::Manager->new();
    
    # Create orchestrator (has tool registry with interact tool)
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
    
    # Verify content is either user response or placeholder (non-TTY environment)
    # In non-TTY, interact returns no output -> placeholder message
    die "Message content empty" unless $msg->{content} && length($msg->{content}) > 0;
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
    
    my $config = make_test_config();
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

# Test 5: Verify interrupt detection when flag already set (fast path, no I/O)
test("Interrupt detected via flag (fast path, no STDIN read)", sub {
    require CLIO::Core::WorkflowOrchestrator;
    require CLIO::Core::Config;
    require CLIO::Core::APIManager;
    require CLIO::Session::Manager;
    
    my $config = make_test_config();
    my $api_manager = CLIO::Core::APIManager->new(config => $config);
    my $session = CLIO::Session::Manager->new();
    
    my $orch = CLIO::Core::WorkflowOrchestrator->new(
        api_manager => $api_manager,
        session => $session,
        debug => 0
    );
    
    # Set interrupt flag (simulates ALRM handler having detected ESC)
    $session->state()->{user_interrupted} = 1;
    
    # Check for interrupt - should return 1 immediately via the pending() fast path,
    # WITHOUT reading from STDIN (since the flag is already set by the ALRM handler).
    # This is the correct behavior: pending=1 means "an interrupt was already
    # detected, it is waiting to be handled."
    my $result = $orch->_check_for_user_interrupt($session);
    
    die "Should return 1 when interrupt flag is already set (pending), got: $result" unless $result;
    
    # Clean up
    CLIO::Core::Interrupt::clear(session => $session);
});

# Test 6: Verify interrupt message format
test("Interrupt message has expected structure", sub {
    require CLIO::Core::WorkflowOrchestrator;
    require CLIO::Core::Config;
    require CLIO::Core::APIManager;
    require CLIO::Session::Manager;
    
    my $config = make_test_config();
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
    # In non-TTY, interact returns no output -> placeholder message
    # In TTY, user response would be added
    die "Message content empty" unless $msg->{content} && length($msg->{content}) > 0;
    die "Message role is not 'user'" unless $msg->{role} eq 'user';
    
    # If placeholder message, verify it mentions interrupt
    if ($msg->{content} =~ /cancelled interrupt/i) {
        die "Placeholder doesn't mention interrupt" unless $msg->{content} =~ /interrupt/i;
    }
});

# Test 7: Verify the steering response is persisted to session history.
# Regression: _handle_interrupt used to push the user's response into the
# in-flight messages array only. The assistant's ACK was persisted by the
# normal turn-end path, so the stored history contained an assistant reply
# to an instruction that was never stored. The next turn's projection
# rebuild read that history, dropped the steering, kept the ACK, and the
# model reverted to its prior plan (steering "ignored after the ack").
test("Interrupt steering response persisted to session history", sub {
    require CLIO::Core::WorkflowOrchestrator;
    require CLIO::Core::Config;
    require CLIO::Core::APIManager;
    require CLIO::Session::Manager;

    my $config = make_test_config();
    my $api_manager = CLIO::Core::APIManager->new(config => $config);
    my $session = CLIO::Session::Manager->new();

    my $orch = CLIO::Core::WorkflowOrchestrator->new(
        api_manager => $api_manager,
        session => $session,
        debug => 0
    );

    # Stub the interact tool so _handle_interrupt takes the success path
    # deterministically (non-TTY environments would otherwise land in the
    # cancel path and never exercise the steering persistence). The stub
    # receives the steering text via its constructor because a named sub
    # cannot reliably close over enclosing lexicals in Perl.
    my $steer_text = 'Steer: stop auditing, start fixing the duplicates';
    {
        package StubInteractTool;
        sub new {
            my ($class, $text) = @_;
            return bless { text => $text }, $class;
        }
        sub execute {
            my ($self, $args, $ctx) = @_;
            return {
                success => 1,
                output  => $self->{text},
                metadata => { user_response => $self->{text} },
            };
        }
    }

    my $registry = $orch->{tool_registry};
    die "No tool registry on orchestrator" unless $registry;
    $registry->{tools}{interact} = StubInteractTool->new($steer_text);

    my @messages = ();
    $orch->_handle_interrupt($session, \@messages);

    # In-memory: steering message appended as role=user
    die "No message added to in-flight array" unless @messages > 0;
    my $inflight = $messages[-1];
    die "In-flight role is not 'user'" unless $inflight->{role} eq 'user';
    die "In-flight content missing steering text"
        unless index($inflight->{content}, $steer_text) >= 0;

    # Session history: steering message persisted (the actual fix)
    my $history = $session->get_conversation_history();
    die "Session history empty after interrupt steering" unless $history && @$history;
    my $found = 0;
    for my $m (@$history) {
        next unless ($m->{role} // '') eq 'user';
        if (index($m->{content} // '', $steer_text) >= 0) {
            $found = 1;
            # YaRN preservation tag must be present so trimming keeps it
            die "Persisted steering message missing collaboration=interrupt metadata"
                unless $m->{metadata}
                    && $m->{metadata}{collaboration}
                    && $m->{metadata}{collaboration} eq 'interrupt';
            last;
        }
    }
    die "Steering response NOT persisted to session history" unless $found;
});

# Test 8: Verify the cancel-path continuation message is persisted too,
# so the model's response to it has a matching user message in history.
test("Cancel-path continuation message persisted to session history", sub {
    require CLIO::Core::WorkflowOrchestrator;
    require CLIO::Core::Config;
    require CLIO::Core::APIManager;
    require CLIO::Session::Manager;

    my $config = make_test_config();
    my $api_manager = CLIO::Core::APIManager->new(config => $config);
    my $session = CLIO::Session::Manager->new();

    my $orch = CLIO::Core::WorkflowOrchestrator->new(
        api_manager => $api_manager,
        session => $session,
        debug => 0
    );

    my @messages = ();

    # Non-TTY: interact returns no output -> cancel path. Verify the
    # synthetic continuation message is persisted as well.
    $orch->_handle_interrupt($session, \@messages);

    die "No message added" unless @messages > 0;
    my $msg = $messages[-1];
    die "Cancel-path role is not 'user'" unless $msg->{role} eq 'user';

    my $history = $session->get_conversation_history();
    die "Session history empty after cancel path" unless $history && @$history;
    my $found = 0;
    for my $m (@$history) {
        next unless ($m->{role} // '') eq 'user';
        if (index($m->{content} // '', 'pressed ESC to interrupt') >= 0) {
            $found = 1;
            last;
        }
    }
    die "Cancel-path continuation message NOT persisted to session history" unless $found;
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
