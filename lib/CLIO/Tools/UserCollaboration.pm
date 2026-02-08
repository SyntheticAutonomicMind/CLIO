package CLIO::Tools::UserCollaboration;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use parent 'CLIO::Tools::Tool';
use feature 'say';

=head1 NAME

CLIO::Tools::UserCollaboration - Tool for mid-stream user collaboration

=head1 DESCRIPTION

Enables agents to pause execution and request user input, clarification,
or decisions without consuming additional premium API requests.

This is the PRIMARY mechanism for agent-user communication during task
execution. Agents should use this tool for ALL collaboration instead of
providing summary responses.

KEY BENEFITS:
- FREE - Does not consume premium requests
- SYNCHRONOUS - Workflow continues in same API call
- INTERACTIVE - User can guide agent in real-time
- EFFICIENT - Reduces back-and-forth API calls

=head1 SYNOPSIS

    use CLIO::Tools::UserCollaboration;
    
    my $tool = CLIO::Tools::UserCollaboration->new(debug => 1);
    
    my $result = $tool->execute(
        {
            operation => 'request_input',
            message => 'Found 3 possible approaches. Which should I use?',
            context => 'Analyzing code structure for refactoring'
        },
        { session => $session, ui => $ui }
    );
    
    # Result contains user's response
    print "User said: $result->{output}\n";

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = $class->SUPER::new(
        name => 'user_collaboration',
        description => q{Request user input, clarification, or decisions during task execution.

**CRITICAL - Use This Tool for ALL Agent-User Collaboration:**

You MUST use this tool instead of providing summary responses or asking questions in chat. This tool is FREE (no premium request cost) and enables efficient collaboration.

**WHEN TO USE (ALWAYS):**
- Before implementing complex changes
- When multiple valid approaches exist
- To show findings and get approval
- To report errors and ask for guidance
- At any decision point
- For progress checkpoints
- When you need clarification

**WHEN NOT TO USE:**
- Never (seriously, always use it for collaboration)
- Questions answerable with available tools
- Information already in conversation history

**EXAMPLES:**

SUCCESS: "Found 3 bugs. Fix all at once or one at a time?"
SUCCESS: "Analyzed codebase. Here are 2 approaches: A) Refactor entirely (3 hours), B) Patch (30 min). Which?"
SUCCESS: "Encountered error X. Should I: 1) Retry, 2) Try alternative, 3) Report?"
FAILURE: "Here's what I found..." (don't summarize - use the tool!)
FAILURE: "Should I search the codebase?" (just do it, don't ask)

**WORKFLOW:**
1. Agent calls this tool with message
2. UI displays message with special styling
3. User responds
4. Response returned to agent as tool result
5. Agent continues in SAME API call (no extra cost!)

**Parameters:**
- message (required): Your question/update for the user
- context (optional): Additional context to help user understand
},
        supported_operations => [qw(request_input)],
        
        # Execution control - MUST block and be interactive
        requires_blocking => 1,  # Workflow MUST wait for user response
        is_interactive => 1,     # Requires terminal I/O
        
        %opts,
    );
    
    return $self;
}

=head2 route_operation

Route to the appropriate handler based on operation.

=cut

sub route_operation {
    my ($self, $operation, $params, $context) = @_;
    
    if ($operation eq 'request_input') {
        return $self->request_input($params, $context);
    }
    
    return $self->operation_error("Unknown operation: $operation");
}


=head2 get_additional_parameters

Define parameters for user_collaboration in JSON schema sent to AI.

=cut

sub get_additional_parameters {
    my ($self) = @_;
    
    return {
        message => {
            type => "string",
            description => "Your question/update for the user (required)",
        },
        context => {
            type => "string",
            description => "Optional additional context to help user understand",
        },
    };
}

=head2 request_input

Request input from user mid-execution.

Arguments:
- $params: Hashref with:
  * message: The question/update for the user (required)
  * context: Optional additional context
- $context: Execution context with:
  * ui: UI object for displaying collaboration prompt
  * session: Session object

Returns: Hashref with:
  * success: 1
  * output: User's response text
  * metadata: Collaboration info

=cut

sub request_input {
    my ($self, $params, $context) = @_;
    
    # Validate parameters
    unless ($params->{message}) {
        return {
            success => 0,
            error => "Missing required parameter: message"
        };
    }
    
    my $message = $params->{message};
    my $user_context = $params->{context} || '';
    
    print STDERR "[DEBUG][UserCollaboration] Requesting user input\n" if should_log('DEBUG');
    print STDERR "[DEBUG][UserCollaboration] Message: $message\n" if should_log('DEBUG');
    
    # === SUB-AGENT MODE: Route to broker instead of interactive UI ===
    if ($context->{broker_client}) {
        print STDERR "[DEBUG][UserCollaboration] Sub-agent mode detected - routing to broker\n" if should_log('DEBUG');
        return $self->_request_via_broker($params, $context);
    }
    
    # Stop busy indicator before displaying collaboration prompt
    # This is the only interactive tool that waits for user input, so spinner must stop
    # Get spinner from UI instead of directly from context (context.spinner is not reliably set)
    my $ui = $context->{ui};
    my $spinner = $ui ? $ui->{spinner} : undef;
    
    # Add detailed logging for spinner reference validation
    if (should_log('DEBUG')) {
        print STDERR "[DEBUG][UserCollaboration] UI reference: " . (defined $ui ? "DEFINED" : "UNDEFINED") . "\n";
        print STDERR "[DEBUG][UserCollaboration] Spinner reference from UI: " . (defined $spinner ? ref($spinner) : "UNDEFINED") . "\n";
        if ($spinner) {
            if (ref($spinner) eq 'CLIO::UI::ProgressSpinner') {
                print STDERR "[DEBUG][UserCollaboration] Spinner object: valid ProgressSpinner instance\n";
                print STDERR "[DEBUG][UserCollaboration] Spinner running state: " . ($spinner->{running} ? "YES" : "NO") . "\n";
            } else {
                print STDERR "[DEBUG][UserCollaboration] ERROR - not a ProgressSpinner!\n";
            }
        } else {
            print STDERR "[DEBUG][UserCollaboration] Spinner is undefined (may not have been started yet)\n";
        }
    }
    
    if ($spinner && $spinner->can('stop')) {
        print STDERR "[DEBUG][UserCollaboration] Stopping busy spinner before collaboration prompt\n" if should_log('DEBUG');
        $spinner->stop();
        print STDERR "[DEBUG][UserCollaboration] Spinner stopped successfully\n" if should_log('DEBUG');
    } elsif (should_log('DEBUG')) {
        print STDERR "[DEBUG][UserCollaboration] Spinner not available or not running - skipping stop\n";
    }
    
    # Get UI object from context
    unless ($ui && $ui->can('request_collaboration')) {
        return {
            success => 0,
            error => "UI not available for collaboration (context missing ui object)"
        };
    }
    
    # Display action line BEFORE showing collaboration prompt
    # This closes the box-drawing header and indicates what's happening
    if ($ui->can('colorize')) {
        my $conn = $ui->colorize("\x{2514}\x{2500} ", 'DIM');
        my $action = $ui->colorize("Requesting your input...", 'DATA');
        print "$conn$action\n";
        STDOUT->flush() if STDOUT->can('flush');
    }
    
    # Request user input through UI
    # This will block until user responds
    my $user_response = $ui->request_collaboration($message, $user_context);
    
    unless (defined $user_response) {
        return {
            success => 0,
            error => "User cancelled collaboration or provided no input"
        };
    }
    
    print STDERR "[DEBUG][UserCollaboration] User responded: $user_response\n" if should_log('DEBUG');
    
    # Store collaboration in session history
    if ($context->{session}) {
        # Add agent message (the request)
        $context->{session}->add_message({
            role => 'assistant',
            content => "[COLLABORATION] $message" . ($user_context ? "\n\nContext: $user_context" : "")
        });
        
        # Add user response
        $context->{session}->add_message({
            role => 'user',
            content => $user_response
        });
    }
    
    return {
        success => 1,
        output => $user_response,
        # Don't include action_description since we already displayed it
        metadata => {
            message => $message,
            context => $user_context,
            user_response => $user_response,
            collaboration_type => 'request_input'
        }
    };
}

=head2 _request_via_broker

Handle collaboration request for sub-agents via the message broker.

Instead of interactive terminal I/O, sub-agents:
1. Send their question to the user's inbox via broker
2. Poll their own inbox for a response
3. Return the response to continue processing

This enables the "swarm" pattern where sub-agents work autonomously
but can still ask questions and receive guidance from the primary
agent or user.

=cut

sub _request_via_broker {
    my ($self, $params, $context) = @_;
    
    my $broker_client = $context->{broker_client};
    my $message = $params->{message};
    my $user_context = $params->{context} || '';
    
    print STDERR "[DEBUG][UserCollaboration] Sending question to broker for user\n" if should_log('DEBUG');
    
    # Build full message with context
    my $full_message = $message;
    if ($user_context) {
        $full_message .= "\n\nContext: $user_context";
    }
    
    # Send question to user inbox
    my $msg_id = $broker_client->send_question(
        to => 'user',
        question => $full_message,
    );
    
    unless ($msg_id) {
        print STDERR "[ERROR][UserCollaboration] Failed to send question to broker\n" if should_log('ERROR');
        return {
            success => 0,
            error => "Failed to send question to broker"
        };
    }
    
    print STDERR "[DEBUG][UserCollaboration] Question sent (id: $msg_id), polling for response...\n" if should_log('DEBUG');
    
    # Poll for response with timeout
    my $timeout = 300;  # 5 minutes max wait
    my $poll_interval = 2;  # Check every 2 seconds
    my $start_time = time();
    my $response = undef;
    
    while (time() - $start_time < $timeout) {
        # Poll our inbox for clarification or guidance messages
        my $messages = $broker_client->poll_my_inbox();
        
        for my $msg (@$messages) {
            my $type = $msg->{type} || '';
            
            print STDERR "[TRACE][UserCollaboration] Polled message: type='$type' from='$msg->{from}'\n" if should_log('TRACE');
            
            # Accept clarification or guidance as response
            if ($type eq 'clarification' || $type eq 'guidance' || $type eq 'response') {
                $response = ref($msg->{content}) ? $msg->{content} : $msg->{content};
                print STDERR "[INFO][UserCollaboration] Received response: $response\n" if should_log('INFO');
                last;
            }
            
            # Handle stop signals gracefully
            if ($type eq 'stop') {
                return {
                    success => 0,
                    error => "Received stop signal from coordinator"
                };
            }
        }
        
        last if defined $response;
        
        # Wait before polling again
        sleep($poll_interval);
    }
    
    unless (defined $response) {
        print STDERR "[WARN][UserCollaboration] Timeout waiting for response from user\n" if should_log('WARN');
        return {
            success => 0,
            error => "Timeout waiting for user response via broker (waited ${timeout}s)"
        };
    }
    
    # Store in session if available
    if ($context->{session}) {
        $context->{session}->add_message({
            role => 'assistant',
            content => "[BROKER QUESTION] $message"
        });
        $context->{session}->add_message({
            role => 'user', 
            content => $response
        });
    }
    
    return {
        success => 1,
        output => $response,
        metadata => {
            message => $message,
            context => $user_context,
            user_response => $response,
            collaboration_type => 'request_input',
            via_broker => 1,
            broker_message_id => $msg_id,
        }
    };
}

1;
