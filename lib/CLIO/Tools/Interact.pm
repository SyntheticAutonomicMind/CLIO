package CLIO::Tools::Interact;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(should_log log_debug log_error log_info log_warning);
use CLIO::UI::Terminal qw(box_char);
use parent 'CLIO::Tools::Tool';
use feature 'say';

=head1 NAME

CLIO::Tools::Interact - Tool for mid-stream user collaboration

=head1 DESCRIPTION

Enables agents to pause execution and request user input, clarification,
or decisions without consuming additional premium API requests.

This is the PRIMARY mechanism for agent-user communication during task
execution. Agents should use this tool for ALL collaboration instead of
providing summary responses.

KEY BENEFITS:
- FREE - Does not consume AI Credits
- SYNCHRONOUS - Workflow continues in same API call
- INTERACTIVE - User can guide agent in real-time
- EFFICIENT - Reduces back-and-forth API calls

=head1 SYNOPSIS

    use CLIO::Tools::Interact;
    
    my $tool = CLIO::Tools::Interact->new(debug => 1);
    
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
        name => 'interact',
        description => q{Request user input, clarification, or decisions during task execution.

THIS IS A JSON TOOL CALL, NOT TEXT. Do NOT use text markers like "[COLLABORATION]".

- FREE (does not consume API requests) and BLOCKING (pauses until user responds)
- Use for: checkpoints, approvals, progress updates, questions, reporting blockers
- Do NOT use for: questions answerable with tools, info already in conversation

Parameters:
- message (required): Your question/update for the user
- context (optional): Additional context to help user understand},
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

sub dispatch_table {
    return {
        request_input => 'request_input',
    };
}


=head2 get_additional_parameters

Define parameters for interact in JSON schema sent to AI.

=cut

sub get_additional_parameters {
    my ($self) = @_;
    
    return {
        message => {
            type => "string",
            description => "[REQUIRED] Your question/update for the user.",
        },
        context => {
            type => "string",
            description => "[OPTIONAL] Additional context to help user understand.",
        },
        listen_broker => {
            type => "boolean",
            description => "[OPTIONAL] Also listen for broker events while waiting for user input. Use as main loop when managing agents.",
        },
        timeout => {
            type => "number",
            description => "[OPTIONAL] Max seconds to wait when listen_broker is true. Default: 300.",
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
    
    log_debug('Interact', "Requesting user input");
    log_debug('Interact', "Message: $message");
    
    # === SUB-AGENT MODE: Route to broker instead of interactive UI ===
    if ($context->{broker_client}) {
        log_debug('Interact', "Sub-agent mode detected - routing to broker");
        return $self->_request_via_broker($params, $context);
    }
    
    # Stop busy indicator before displaying collaboration prompt
    # This is the only interactive tool that waits for user input, so spinner must stop
    # Get spinner from UI instead of directly from context (context.spinner is not reliably set)
    my $ui = $context->{ui};
    my $spinner = $ui ? $ui->{spinner} : undef;
    
    # Add detailed logging for spinner reference validation
    if (should_log('DEBUG')) {
        log_debug('Interact', "UI reference: " . (defined $ui ? "DEFINED" : "UNDEFINED"));
        log_debug('Interact', "Spinner reference from UI: " . (defined $spinner ? ref($spinner) : "UNDEFINED"));
        if ($spinner) {
            if (ref($spinner) eq 'CLIO::UI::ProgressSpinner') {
                log_debug('Interact', "Spinner object: valid ProgressSpinner instance");
                log_debug('Interact', "Spinner running state: " . ($spinner->is_running() ? "YES" : "NO"));
            } else {
                log_debug('Interact', "ERROR - not a ProgressSpinner!");
            }
        } else {
            log_debug('Interact', "Spinner is undefined (may not have been started yet)");
        }
    }
    
    if ($spinner && $spinner->can('stop')) {
        log_debug('Interact', "Stopping busy spinner before collaboration prompt");
        $spinner->stop();
        log_debug('Interact', "Spinner stopped successfully");
    } elsif (should_log('DEBUG')) {
        log_debug('Interact', "Spinner not available or not running - skipping stop");
    }
    
    # Get UI object from context
    unless ($ui && $ui->can('request_collaboration')) {
        return {
            success => 0,
            error => "UI not available for collaboration (context missing ui object)"
        };
    }
    
    # Display action line BEFORE showing collaboration prompt
    if ($ui->can('colorize')) {
        my $tool_format = 'inline';
        if ($ui->{theme_mgr} && $ui->{theme_mgr}->can('get_tool_display_format')) {
            $tool_format = $ui->{theme_mgr}->get_tool_display_format();
        }
        
        if ($tool_format eq 'inline') {
            # Inline: no connector needed, the prompt speaks for itself
        } else {
            my $conn = $ui->colorize(box_char('bottomleft') . box_char('horizontal') . ' ', 'DIM');
            my $action = $ui->colorize("Requesting your input...", 'DATA');
            print "$conn$action\n";
        }
        STDOUT->flush() if STDOUT->can('flush');
    }
    
    # Request user input through UI
    # This will block until user responds
    my $user_response;
    my $listen_broker = $params->{listen_broker};
    
    if ($listen_broker) {
        # Multiplexed mode: listen for both user input AND broker events
        # The broker_client is resolved by Chat.pm from its command handler
        # (SubAgent command stores it at $self->{command_handler}{subagent_cmd}{broker_client})
        my $result = $ui->request_collaboration($message, $user_context, {
            listen_broker => 1,
            timeout => $params->{timeout} || 300,
        });
        
        # Result is a hashref with source, input, and events
        if (ref($result) eq 'HASH') {
            $user_response = $result->{input};
            
            # Build output with agent events context for the AI
            my $output = $user_response // '';
            my @events = @{$result->{events} || []};
            my $source = $result->{source} || 'user';
            
            # When interrupted by agent event, format output for AI awareness
            if ($source eq 'agent_event') {
                $output = '';  # No user input - this was an agent interrupt
            }
            
            if (@events) {
                my @agent_msgs;
                for my $evt (@events) {
                    next unless ($evt->{type} || '') eq 'agent_message';
                    my $agent = $evt->{agent_id} || 'unknown';
                    my $msg_type = $evt->{message_type} || 'message';
                    my $content = $evt->{content} || '';
                    # Strip HTML comments (session markers etc.) from agent content
                    $content =~ s/<!--.*?-->//gs if !ref($content);
                    push @agent_msgs, "[$agent] ($msg_type): $content";
                }
                if (@agent_msgs) {
                    my $prefix = $source eq 'agent_event'
                        ? "Agent message received:\n"
                        : "\n\nAgent messages received while waiting:\n";
                    $output .= $prefix . join("\n", @agent_msgs);
                }
            }
            
            # Store collaboration in session history
            if ($context->{session} && defined $user_response && $source ne 'agent_event') {
                $context->{session}->add_message(
                    'assistant',
                    "[COLLABORATION] $message" . ($user_context ? "\n\nContext: $user_context" : "")
                );
                $context->{session}->add_message('user', $user_response);
            }
            
            return {
                success => 1,
                output => $output,
                metadata => {
                    source => $source,
                    agent_id => $result->{agent_id},
                    events => \@events,
                    collaboration_type => 'request_input',
                },
            };
        }
        
        # Fallback: result was a plain string (shouldn't happen)
        $user_response = $result;
    } else {
        # Standard mode: just wait for user
        $user_response = $ui->request_collaboration($message, $user_context);
    }
    
    unless (defined $user_response) {
        return {
            success => 0,
            error => "User cancelled collaboration or provided no input"
        };
    }
    
    log_debug('Interact', "User responded: $user_response");
    
    # Store collaboration in session history
    if ($context->{session}) {
        # Add agent message (the request)
        $context->{session}->add_message(
            'assistant',
            "[COLLABORATION] $message" . ($user_context ? "\n\nContext: $user_context" : "")
        );
        
        # Add user response
        $context->{session}->add_message(
            'user',
            $user_response
        );
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
    
    log_debug('Interact', "Sending question to broker for user");
    
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
        log_error('Interact', "Failed to send question to broker");
        return {
            success => 0,
            error => "Failed to send question to broker"
        };
    }
    
    log_debug('Interact', "Question sent (id: $msg_id), polling for response...");
    
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
            
            log_debug('Interact', "Polled message: type='$type' from='$msg->{from}'");
            
            # Accept clarification or guidance as response
            if ($type eq 'clarification' || $type eq 'guidance' || $type eq 'response') {
                $response = ref($msg->{content}) ? $msg->{content} : $msg->{content};
                log_info('Interact', "Received response: $response");
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
        log_warning('Interact', "Timeout waiting for response from user");
        return {
            success => 0,
            error => "Timeout waiting for user response via broker (waited ${timeout}s)"
        };
    }
    
    # Store in session if available
    if ($context->{session}) {
        $context->{session}->add_message(
            'assistant',
            "[BROKER QUESTION] $message"
        );
        $context->{session}->add_message(
            'user', 
            $response
        );
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
