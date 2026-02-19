#!/usr/bin/env perl
# Test to verify add_message is called with correct signature
# and that session message management is centralized

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More;

# Test 1: Verify Session::State add_message signature
{
    require CLIO::Session::State;
    
    # Get the subroutine reference
    my $add_message = \&CLIO::Session::State::add_message;
    ok(defined $add_message, "add_message subroutine exists in Session::State");
    
    # Parse the prototype/signature from the source
    my $state_pm = "$RealBin/../../lib/CLIO/Session/State.pm";
    open my $fh, '<', $state_pm or die "Cannot read State.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    # Check that add_message takes ($self, $role, $content, $opts) - positional args
    like($content, qr/sub add_message\s*\{[^}]*my\s*\(\$self,\s*\$role,\s*\$content,\s*\$opts\)/s,
        "add_message signature is (self, role, content, opts)");
}

# Test 2: Verify Session::Manager delegates correctly
{
    my $manager_pm = "$RealBin/../../lib/CLIO/Session/Manager.pm";
    open my $fh, '<', $manager_pm or die "Cannot read Manager.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    # Check that Manager's add_message also uses positional args
    like($content, qr/sub add_message\s*\{[^}]*my\s*\(\$self,\s*\$role,\s*\$content,\s*\$opts\)/s,
        "Session::Manager add_message has same signature");
    
    # Verify it delegates to State
    like($content, qr/\$self->\{state\}->add_message\(\$role,\s*\$content,\s*\$opts\)/,
        "Session::Manager delegates to State with correct args");
}

# Test 3: Check that NO callers use the wrong hashref-style signature
{
    my @files_to_check = qw(
        lib/CLIO/Tools/UserCollaboration.pm
        lib/CLIO/UI/Chat.pm
        lib/CLIO/UI/Display.pm
        lib/CLIO/Core/WorkflowOrchestrator.pm
    );
    
    for my $file (@files_to_check) {
        my $path = "$RealBin/../../$file";
        next unless -f $path;
        
        open my $fh, '<', $path or die "Cannot read $file: $!";
        my $content = do { local $/; <$fh> };
        close $fh;
        
        # Check for wrong pattern: add_message({ ... })
        # This would pass a hashref as the first argument (role)
        unlike($content, qr/->add_message\(\s*\{/,
            "$file does not use wrong hashref signature for add_message");
    }
}

# Test 4: Verify Display.pm does NOT call add_message (centralized management)
{
    my $display_pm = "$RealBin/../../lib/CLIO/UI/Display.pm";
    open my $fh, '<', $display_pm or die "Cannot read Display.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    # display_assistant_message should NOT call add_message
    # (to avoid duplication with WorkflowOrchestrator)
    my ($display_assistant_method) = $content =~ /(sub display_assistant_message\s*\{.*?\n\})/s;
    
    if ($display_assistant_method) {
        unlike($display_assistant_method, qr/->add_message\(/,
            "display_assistant_message does not call add_message (centralized in WorkflowOrchestrator)");
    } else {
        fail("Could not find display_assistant_message method");
    }
}

# Test 5: Verify WorkflowOrchestrator owns user message management
{
    my $orchestrator_pm = "$RealBin/../../lib/CLIO/Core/WorkflowOrchestrator.pm";
    open my $fh, '<', $orchestrator_pm or die "Cannot read WorkflowOrchestrator.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    # Check that WorkflowOrchestrator adds user message to session
    like($content, qr/\$session->add_message\('user',\s*\$user_input\)/,
        "WorkflowOrchestrator adds user message with correct signature");
    
    # Check for the comment explaining centralized management
    like($content, qr/Save user message to session history/,
        "WorkflowOrchestrator documents session message management");
}

# Test 6: Verify Chat.pm does NOT add user message (centralized in Orchestrator)
{
    my $chat_pm = "$RealBin/../../lib/CLIO/UI/Chat.pm";
    open my $fh, '<', $chat_pm or die "Cannot read Chat.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    # The main run() loop should have a comment explaining NO user message add
    like($content, qr/NOTE:.*user message.*WorkflowOrchestrator/is,
        "Chat.pm documents that user messages are managed by WorkflowOrchestrator");
}

done_testing();