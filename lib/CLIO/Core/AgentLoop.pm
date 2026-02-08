package CLIO::Core::AgentLoop;

use strict;
use warnings;
use utf8;
use Time::HiRes qw(time sleep);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::Core::AgentLoop - Persistent agent event loop

=head1 DESCRIPTION

Implements the main event loop for persistent multi-agent coordination.
Agents stay alive, poll for messages, process tasks, and communicate
bidirectionally with users and other agents.

This transforms agents from fire-and-forget task runners into persistent
collaborative team members.

=head1 SYNOPSIS

    use CLIO::Core::AgentLoop;
    
    my $loop = CLIO::Core::AgentLoop->new(
        client => $broker_client,
        initial_task => "Build authentication module",
        on_task => sub { my ($task) = @_; ... },
    );
    
    $loop->run();

=cut

sub new {
    my ($class, %args) = @_;
    
    my $client = $args{client} or die "client required";
    my $on_task = $args{on_task} or die "on_task callback required";
    
    my $self = {
        client => $client,
        on_task => $on_task,
        initial_task => $args{initial_task},
        running => 1,
        current_task => undef,
        heartbeat_interval => $args{heartbeat_interval} || 30,
        poll_interval => $args{poll_interval} || 1,
        last_heartbeat => 0,
        waiting_for_response => 0,
        debug => $args{debug} || 0,
    };
    
    return bless $self, $class;
}

sub run {
    my ($self) = @_;
    
    $self->log_info("Agent loop starting");
    
    # Process initial task if provided
    if ($self->{initial_task}) {
        $self->{current_task} = $self->{initial_task};
        $self->process_current_task();
    }
    
    # Main event loop
    while ($self->{running}) {
        eval {
            $self->iteration();
        };
        if ($@) {
            $self->log_error("Loop iteration error: $@");
            # Continue running despite errors
        }
        
        sleep($self->{poll_interval});
    }
    
    $self->log_info("Agent loop exiting");
}

sub iteration {
    my ($self) = @_;
    
    # Check for new messages from broker
    my $messages;
    eval {
        $messages = $self->{client}->poll_my_inbox();
    };
    if ($@) {
        $self->log_warn("Broker communication error: $@");
        $messages = [];
        # Try to reconnect after a short delay
        sleep 1;
    }
    
    if (@$messages) {
        $self->log_debug("Received " . scalar(@$messages) . " messages");
    }
    
    for my $msg (@$messages) {
        $self->handle_message($msg);
    }
    
    # Send periodic heartbeat
    if (time() - $self->{last_heartbeat} > $self->{heartbeat_interval}) {
        $self->send_heartbeat();
    }
    
    # Process current task if not waiting
    if ($self->{current_task} && !$self->{waiting_for_response}) {
        $self->process_current_task();
    }
}

sub handle_message {
    my ($self, $msg) = @_;
    
    my $type = $msg->{type} || 'unknown';
    my $from = $msg->{from} || 'unknown';
    
    $self->log_debug("Handling message: $type from $from");
    
    if ($type eq 'task') {
        $self->handle_task_message($msg);
    }
    elsif ($type eq 'clarification') {
        $self->handle_clarification_message($msg);
    }
    elsif ($type eq 'guidance') {
        $self->handle_guidance_message($msg);
    }
    elsif ($type eq 'stop') {
        $self->handle_stop_message($msg);
    }
    else {
        $self->log_debug("Unknown message type: $type");
    }
}

sub handle_task_message {
    my ($self, $msg) = @_;
    
    my $task = $msg->{content};
    
    $self->log_info("New task received: $task");
    
    # Queue the task
    $self->{current_task} = $task;
    $self->{waiting_for_response} = 0;
    
    # Send acknowledgment
    $self->{client}->send_message(
        to => $msg->{from},
        message_type => 'ack',
        content => "Task accepted: $task",
    );
}

sub handle_clarification_message {
    my ($self, $msg) = @_;
    
    my $answer = $msg->{content};
    
    $self->log_info("Received clarification: $answer");
    
    # Resume processing with the answer
    $self->{waiting_for_response} = 0;
    
    # Store the answer for the task processor to use
    $self->{last_clarification} = $answer;
    
    # Continue task processing will happen in next iteration
}

sub handle_guidance_message {
    my ($self, $msg) = @_;
    
    my $guidance = $msg->{content};
    
    $self->log_info("Received guidance: $guidance");
    
    # Guidance can modify or redirect current work
    # Implementation depends on task processing logic
    # For now, just log it
}

sub handle_stop_message {
    my ($self, $msg) = @_;
    
    $self->log_info("Stop signal received");
    
    # Graceful shutdown
    $self->{running} = 0;
    
    # Send acknowledgment
    $self->{client}->send_message(
        to => $msg->{from},
        message_type => 'ack',
        content => "Shutting down gracefully",
    );
}

sub process_current_task {
    my ($self) = @_;
    
    my $task = $self->{current_task};
    return unless $task;
    
    $self->log_debug("Processing task: $task");
    
    # Call the task handler
    my $result = eval {
        $self->{on_task}->($task, $self);
    };
    
    if ($@) {
        $self->log_error("Task processing error: $@");
        
        # Report error to user
        $self->{client}->send_blocked("Task failed: $@");
        
        # Clear current task
        $self->{current_task} = undef;
        return;
    }
    
    # If task completed successfully
    if ($result && $result->{completed}) {
        $self->log_info("Task completed");
        
        $self->{client}->send_complete($result->{message} || "Task completed successfully");
        
        # Clear current task
        $self->{current_task} = undef;
    }
    elsif ($result && $result->{blocked}) {
        $self->log_info("Task blocked: $result->{reason}");
        
        # Set waiting flag
        $self->{waiting_for_response} = 1;
        
        # Ask for help via broker
        $self->{client}->send_question(
            to => 'user',
            question => $result->{reason},
        );
    }
    elsif ($result && $result->{status}) {
        # Send status update
        $self->{client}->send_status(
            status => $result->{status},
            progress => $result->{progress},
            current_task => $result->{current_task},
        );
    }
}

sub send_heartbeat {
    my ($self) = @_;
    
    $self->{client}->send({
        type => 'heartbeat',
    });
    
    $self->{last_heartbeat} = time();
}

sub ask_question {
    my ($self, $question, $to) = @_;
    
    $to ||= 'user';
    
    $self->log_info("Asking question: $question");
    
    $self->{waiting_for_response} = 1;
    
    $self->{client}->send_question(
        to => $to,
        question => $question,
    );
}

sub send_status_update {
    my ($self, %args) = @_;
    
    $self->{client}->send_status(%args);
}

sub stop {
    my ($self) = @_;
    
    $self->{running} = 0;
}

sub log_info {
    my ($self, $msg) = @_;
    print STDERR "[INFO][AgentLoop] $msg\n";
}

sub log_debug {
    my ($self, $msg) = @_;
    return unless $self->{debug};
    print STDERR "[DEBUG][AgentLoop] $msg\n";
}

sub log_warn {
    my ($self, $msg) = @_;
    print STDERR "[WARN][AgentLoop] $msg\n";
}

sub log_error {
    my ($self, $msg) = @_;
    print STDERR "[ERROR][AgentLoop] $msg\n";
}

1;

__END__

=head1 METHODS

=head2 new(%args)

Create new agent loop.

Required arguments:
- client: CLIO::Coordination::Client instance
- on_task: Callback for task processing

Optional arguments:
- initial_task: Task to process on startup
- heartbeat_interval: Seconds between heartbeats (default: 30)
- poll_interval: Seconds between inbox polls (default: 1)
- debug: Enable debug logging

=head2 run()

Start the event loop. Blocks until stop() called or stop message received.

=head2 ask_question($question, $to)

Ask a question and wait for response. Sets waiting_for_response flag.

=head2 send_status_update(%args)

Send status update to user.

=head2 stop()

Stop the event loop gracefully.

=head1 TASK HANDLER CALLBACK

The on_task callback receives ($task, $loop) and should return:

- {completed => 1, message => "..."} - Task finished
- {blocked => 1, reason => "..."} - Need help
- {status => "...", progress => N, current_task => "..."} - Progress update
- undef or {} - Task still processing

The callback can use $loop->ask_question() to request help.

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.
