package CLIO::Tools::SubAgentOperations;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use Scalar::Util qw(blessed);
use CLIO::Util::JSON qw(encode_json);
use parent 'CLIO::Tools::Tool';

=head1 NAME

CLIO::Tools::SubAgentOperations - Sub-agent management for multi-agent coordination

=head1 DESCRIPTION

Provides AI-callable operations for spawning and managing sub-agents.
This allows the primary AI to orchestrate multiple sub-agents working
in parallel on different aspects of a task.

Operations:
- spawn: Create a new sub-agent with a specific task
- list: List all active sub-agents and their status
- status: Get detailed status of a specific agent
- kill: Terminate a specific agent
- inbox: Check for messages from sub-agents
- send: Send a message to a specific agent
- broadcast: Send message to all agents

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = $class->SUPER::new(
        name => 'agent_operations',
        supported_operations => [qw(spawn list status wait kill killall inbox acknowledge history send broadcast)],
        description => q{Sub-agent management for multi-agent coordination.

Spawn and manage sub-agents to work on tasks in parallel.

━━━━━━━━━━━━━━━━━━━━━ SPAWN (create agents) ━━━━━━━━━━━━━━━━━━━━━
-  spawn - Create a new sub-agent with a specific task
   Parameters: 
     task (required): Natural language description of what the agent should do
     model (optional): AI model to use (default: current session model)
     persistent (optional, boolean): Keep agent alive for multiple tasks. Default is false (oneshot mode - agent exits after completing its task)
     working_dir (optional): Run agent in this directory (loads that project's .clio/ context)
   Returns: Agent ID and confirmation

━━━━━━━━━━━━━━━━━━━━━ MANAGE (monitor/control) ━━━━━━━━━━━━━━━━━━━
-  list - List all active sub-agents and their status
   Parameters: none
   Returns: List of agents with status (running/exited/etc)

-  status - Get detailed status of a specific agent
   Parameters: agent_id (required)
   Returns: Detailed agent info including logs

-  wait - Block until agent activity occurs (message, exit, status update)
   Parameters:
     timeout (optional, number): Max seconds to wait (default: 60)
     poll_interval (optional, number): Seconds between checks (default: 5)
   Returns: Events that occurred (messages, exits, status updates)

-  kill - Terminate a specific agent
   Parameters: agent_id (required)
   Returns: Confirmation

-  killall - Terminate all agents
   Parameters: none
   Returns: Count of terminated agents

━━━━━━━━━━━━━━━━━━━━━ COMMUNICATE (messages) ━━━━━━━━━━━━━━━━━━━━
-  inbox - Check for UNREAD messages from sub-agents (non-destructive)
   Parameters: none
   Returns: List of unread messages (questions, status updates, completions)
   NOTE: Messages remain unread until you call acknowledge

-  acknowledge - Mark messages as read (clears from inbox)
   Parameters: message_ids (optional, array) - specific IDs to acknowledge, or omit for all
   Returns: Confirmation

-  history - View ALL messages from this session (read and unread)
   Parameters: none
   Returns: Complete message history

-  send - Send guidance to a specific agent
   Parameters: agent_id (required), message (required)
   Returns: Confirmation

-  broadcast - Send message to all agents
   Parameters: message (required)
   Returns: Confirmation

EXAMPLE WORKFLOW:
1. Spawn agents: agent_operations(operation: "spawn", task: "create file X")
2. Wait for activity: agent_operations(operation: "wait", timeout: 60)
3. Check messages: agent_operations(operation: "inbox")
4. Reply if needed: agent_operations(operation: "send", agent_id: "agent-1", message: "yes")
5. Mark as read: agent_operations(operation: "acknowledge")
},
        %opts,
    );
    
    return $self;
}

sub schema {
    return {
        type => 'object',
        properties => {
            operation => {
                type => 'string',
                enum => ['spawn', 'list', 'status', 'wait', 'kill', 'killall', 'inbox', 'acknowledge', 'history', 'send', 'broadcast'],
                description => '[REQUIRED] Operation to perform.',
            },
            task => {
                type => 'string',
                description => '[REQUIRED for spawn] Natural language task description for the agent.',
            },
            model => {
                type => 'string',
                description => '[OPTIONAL] AI model to use for spawn. Default: current session model.',
            },
            persistent => {
                type => 'boolean',
                description => '[OPTIONAL] Keep agent alive for multiple tasks. Default: false (oneshot mode).',
            },
            agent_id => {
                type => 'string',
                description => '[REQUIRED for status/kill/send, OPTIONAL for others] Agent ID.',
            },
            message => {
                type => 'string',
                description => '[REQUIRED for send/broadcast] Message content to send to agent.',
            },
            working_dir => {
                type => 'string',
                description => '[OPTIONAL] Working directory for agent. Loads that project\'s .clio/ context (LTM, instructions, memory).',
            },
            timeout => {
                type => 'number',
                description => '[OPTIONAL] Max seconds to wait for wait operation. Default: 60.',
            },
            poll_interval => {
                type => 'number',
                description => '[OPTIONAL] Seconds between status checks for wait operation. Default: 5.',
            },
            message_ids => {
                type => 'array',
                items => { type => 'string' },
                description => '[OPTIONAL] Specific message IDs to acknowledge. Omit to acknowledge all.',
            },
        },
        required => ['operation'],
    };
}

sub before_route {
    my ($self, $operation, $params, $context) = @_;
    
    # Resolve SubAgent handler and stash for dispatch methods
    my $subagent_cmd = $self->_get_subagent_handler($context);
    unless ($subagent_cmd) {
        return $self->error_result("SubAgent system not available");
    }
    $self->{_subagent_cmd} = $subagent_cmd;
    
    return undef;
}

sub dispatch_table {
    return {
        spawn       => '_dispatch_spawn',
        list        => '_dispatch_list',
        status      => '_dispatch_status',
        wait        => '_dispatch_wait',
        kill        => '_dispatch_kill',
        killall     => '_dispatch_killall',
        inbox       => '_dispatch_inbox',
        acknowledge => '_dispatch_acknowledge',
        history     => '_dispatch_history',
        send        => '_dispatch_send',
        broadcast   => '_dispatch_broadcast',
    };
}

# Dispatch wrappers adapt the standard ($params, $context) signature
# to SubAgentOperations' methods that take $subagent_cmd

sub _dispatch_spawn       { my ($self, $params, $ctx) = @_; $self->spawn($params, $self->{_subagent_cmd}, $ctx) }
sub _dispatch_list        { my ($self) = @_; $self->list($self->{_subagent_cmd}) }
sub _dispatch_status      { my ($self, $params) = @_; $self->status($params, $self->{_subagent_cmd}) }
sub _dispatch_wait        { my ($self, $params, $ctx) = @_; $self->wait($params, $self->{_subagent_cmd}, $ctx) }
sub _dispatch_kill        { my ($self, $params, $ctx) = @_; $self->kill($params, $self->{_subagent_cmd}, $ctx) }
sub _dispatch_killall     { my ($self, $params, $ctx) = @_; $self->killall($self->{_subagent_cmd}, $ctx) }
sub _dispatch_inbox       { my ($self, $params, $ctx) = @_; $self->inbox($self->{_subagent_cmd}, $ctx) }
sub _dispatch_acknowledge { my ($self, $params) = @_; $self->acknowledge($params, $self->{_subagent_cmd}) }
sub _dispatch_history     { my ($self) = @_; $self->history($self->{_subagent_cmd}) }
sub _dispatch_send        { my ($self, $params) = @_; $self->send($params, $self->{_subagent_cmd}) }
sub _dispatch_broadcast   { my ($self, $params) = @_; $self->broadcast($params, $self->{_subagent_cmd}) }

sub _get_subagent_handler {
    my ($self, $context) = @_;
    
    # Try to get from context directly
    if ($context->{subagent_cmd}) {
        return $context->{subagent_cmd};
    }
    
    # Try to get from UI (Chat.pm) - this is the primary path
    # The UI is passed from ToolExecutor
    my $ui = $context->{ui};
    if ($ui && ref($ui) && $ui->can('get_command_handler')) {
        my $ch = $ui->get_command_handler();
        if ($ch && $ch->{subagent_cmd}) {
            return $ch->{subagent_cmd};
        }
    }
    
    # Try direct access to command_handler hash (legacy)
    if ($ui && ref($ui) eq 'HASH' && $ui->{command_handler}) {
        my $ch = $ui->{command_handler};
        if ($ch->{subagent_cmd}) {
            return $ch->{subagent_cmd};
        }
    }
    
    # Try blessed object with command_handler attribute
    if ($ui && blessed($ui) && $ui->{command_handler}) {
        my $ch = $ui->{command_handler};
        if ($ch->{subagent_cmd}) {
            return $ch->{subagent_cmd};
        }
        
        # Initialize SubAgent command handler if not present
        require CLIO::UI::Commands::SubAgent;
        $ch->{subagent_cmd} = CLIO::UI::Commands::SubAgent->new(
            chat => $ui,
            debug => $self->{debug},
        );
        return $ch->{subagent_cmd};
    }
    
    # Fall back to creating a minimal handler (for non-UI contexts)
    # NOTE: This handler won't have broker_client until spawn is called
    if ($context->{session}) {
        # Check if we already have a cached handler
        if ($self->{_subagent_handler}) {
            return $self->{_subagent_handler};
        }
        
        require CLIO::UI::Commands::SubAgent;
        
        # Create minimal chat-like object for SubAgent handler
        my $mock_chat = {
            session => $context->{session},
        };
        
        # Add display methods that do nothing (we capture output via return)
        $mock_chat->{display_system_message} = sub { };
        $mock_chat->{display_error_message} = sub { };
        $mock_chat->{display_key_value} = sub { };
        $mock_chat->{display_section_header} = sub { };
        $mock_chat->{writeline} = sub { };
        $mock_chat->{colorize} = sub { return $_[1] };
        
        # Cache the handler so subsequent calls reuse the same instance
        $self->{_subagent_handler} = CLIO::UI::Commands::SubAgent->new(
            chat => $mock_chat,
            debug => $self->{debug},
        );
        return $self->{_subagent_handler};
    }
    
    return undef;
}

sub _get_host_proto {
    my ($self, $context) = @_;
    my $ui = $context->{ui} if $context;
    if ($ui && blessed($ui) && $ui->{host_proto}) {
        return $ui->{host_proto};
    }
    return undef;
}

sub spawn {
    my ($self, $params, $handler, $context) = @_;
    
    my $task = $params->{task};
    return $self->error_result("Missing 'task' parameter") unless $task;
    
    # Use explicitly requested model, or inherit the current session model
    my $model = $params->{model} || ($context && $context->{current_model}) || 'unknown';
    my $persistent = $params->{persistent} ? 1 : 0;
    my $working_dir = $params->{working_dir};
    
    # Persistent mode requires a running broker - default to oneshot
    # Users can explicitly set persistent=true when a broker is available
    
    # Truncate task for display
    my $task_short = length($task) > 50 ? substr($task, 0, 47) . '...' : $task;
    my $action_desc = "spawning sub-agent ($model): $task_short";
    $action_desc .= " in $working_dir" if $working_dir;
    
    # Build args string
    my $args = qq{"$task" --model $model};
    $args .= " --persistent" if $persistent;
    $args .= qq{ --dir "$working_dir"} if $working_dir;
    
    # Suppress direct display - we'll return expanded_content instead
    $handler->{suppress_display} = 1;
    
    # Call the spawn command (display suppressed)
    my $result = $handler->cmd_spawn($args);
    
    delete $handler->{suppress_display};
    
    # Extract agent ID from result if available
    if ($handler->{manager}) {
        my $agents = $handler->{manager}->list_agents();
        my @ids = sort { $b cmp $a } keys %$agents;  # Get newest
        my $agent_id = $ids[0] || 'unknown';
        
        my $mode_str = $persistent ? 'persistent' : 'oneshot';
        my @expanded = (
            sprintf("%-20s %s", "Agent ID:", $agent_id),
            sprintf("%-20s %s", "Mode:", $mode_str),
            sprintf("%-20s %s", "Model:", $model),
            sprintf("%-20s %s", "Task:", qq{"$task_short"}),
        );
        if ($working_dir) {
            push @expanded, sprintf("%-20s %s", "Working Dir:", $working_dir);
        }
        
        # Register agent's project context with Chat for display labels
        if ($working_dir && $context && $context->{ui}) {
            my $ui = $context->{ui};
            if ($ui->can('register_agent_project')) {
                $ui->register_agent_project($agent_id, $working_dir);
            }
        }
        
        # Emit OSC agent event for host applications
        my $host_proto = $self->_get_host_proto($context);
        if ($host_proto && $host_proto->active()) {
            $host_proto->emit_agent_event('spawn',
                id    => $agent_id,
                task  => $task_short,
                model => $model,
                mode  => $mode_str,
                ($working_dir ? (working_dir => $working_dir) : ()),
            );
            # Emit updated agent tree
            $self->_emit_agent_tree($host_proto, $handler);
        }
        
        return $self->success_result(
            "Spawned sub-agent: $agent_id",
            action_description => $action_desc,
            expanded_content => \@expanded,
            agent_id => $agent_id,
            task => $task,
            model => $model,
            mode => $mode_str,
            ($working_dir ? (working_dir => $working_dir) : ()),
        );
    }
    
    return $self->success_result("Sub-agent spawned", action_description => $action_desc, task => $task);
}

sub _emit_agent_tree {
    my ($self, $host_proto, $handler) = @_;
    return unless $host_proto && $host_proto->active() && $handler->{manager};
    
    my $agents = $handler->{manager}->list_agents();
    my @agent_list;
    for my $id (sort keys %$agents) {
        my $agent = $agents->{$id};
        push @agent_list, {
            id     => $id,
            parent => 'primary',
            state  => $agent->{status},
            ($agent->{working_dir} ? (project => $agent->{working_dir}) : ()),
        };
    }
    
    $host_proto->emit_agent_tree({
        root   => 'primary',
        agents => \@agent_list,
    });
}

# Poll broker for status_update messages from child agents and re-emit as OSC events
# This bridges the gap between child agent state and the host application's UI
sub _relay_child_status {
    my ($self, $handler) = @_;
    
    return unless $handler->{broker_client};
    
    my $updates = eval { $handler->{broker_client}->poll_status_updates() };
    return unless $updates && @$updates;
    
    my $host_proto = $self->_get_host_proto();
    return unless $host_proto;
    
    for my $update (@$updates) {
        $host_proto->emit_agent_event('status',
            agent_id => $update->{agent_id} || 'unknown',
            state    => $update->{state}    || 'unknown',
            ($update->{tool}    ? (tool    => $update->{tool})    : ()),
            ($update->{message} ? (message => $update->{message}) : ()),
        );
    }
}


sub wait {
    my ($self, $params, $handler, $context) = @_;

    my $timeout = $params->{timeout} || 60;
    my $poll_interval = $params->{poll_interval} || 5;

    my $action_desc = "waiting for agent activity (${timeout}s timeout)";

    unless ($handler->{manager}) {
        return $self->error_result("No sub-agents spawned");
    }

    my $start = time();
    my @events;

    while ((time() - $start) < $timeout) {
        # Relay child status updates via OSC
        $self->_relay_child_status($handler);

        # Check for new messages from agents
        if ($handler->{broker_client}) {
            my $messages = eval { $handler->{broker_client}->poll_user_inbox() };
            if ($messages && @$messages) {
                my @msg_ids;
                for my $msg (@$messages) {
                    push @msg_ids, $msg->{id} if $msg->{id};
                    push @events, {
                        type => 'message',
                        from => $msg->{from},
                        message_type => $msg->{type},
                        content => $msg->{content},
                        timestamp => $msg->{timestamp},
                    };
                }
                # Acknowledge so they don't re-appear on next poll
                if (@msg_ids) {
                    eval { $handler->{broker_client}->acknowledge_messages(@msg_ids) };
                }
            }

            # Check for status updates
            my $updates = eval { $handler->{broker_client}->poll_status_updates() };
            if ($updates && @$updates) {
                for my $update (@$updates) {
                    push @events, {
                        type => 'status_update',
                        agent_id => $update->{agent_id},
                        state => $update->{state},
                        ($update->{tool} ? (tool => $update->{tool}) : ()),
                        ($update->{message} ? (message => $update->{message}) : ()),
                        timestamp => $update->{timestamp},
                    };
                }
            }
        }

        # Check for agent exits
        my $agents = $handler->{manager}->list_agents();
        for my $id (sort keys %$agents) {
            my $agent = $agents->{$id};
            if ($agent->{status} && $agent->{status} eq 'exited') {
                push @events, {
                    type => 'exit',
                    agent_id => $id,
                    task => $agent->{task},
                };
            }
        }

        # Return early if any events occurred
        if (@events) {
            my $elapsed = int(time() - $start);
            my $count = scalar @events;
            $action_desc = "received $count event(s) after ${elapsed}s";
            return $self->success_result(
                "Received $count event(s)",
                action_description => $action_desc,
                events => \@events,
                count => $count,
                elapsed => $elapsed,
                timed_out => 0,
            );
        }

        # Sleep before next poll
        sleep($poll_interval);
    }

    # Timeout with no events
    my $elapsed = int(time() - $start);
    $action_desc = "wait timed out after ${elapsed}s with no events";
    return $self->success_result(
        "Wait timed out after ${elapsed}s with no events",
        action_description => $action_desc,
        events => [],
        count => 0,
        elapsed => $elapsed,
        timed_out => 1,
    );
}

sub list {
    my ($self, $handler) = @_;
    
    my $action_desc = "listing active sub-agents";
    
    # Poll broker for status updates from child agents and re-emit as OSC
    $self->_relay_child_status($handler);
    
    unless ($handler->{manager}) {
        return $self->success_result("No sub-agents spawned", action_description => $action_desc, agents => []);
    }
    
    my $agents = $handler->{manager}->list_agents();
    
    my @agent_list;
    for my $id (sort keys %$agents) {
        my $agent = $agents->{$id};
        push @agent_list, {
            id => $id,
            status => $agent->{status},
            mode => $agent->{mode} || 'oneshot',
            task => $agent->{task},
            pid => $agent->{pid},
            runtime => time() - $agent->{started},
        };
    }
    
    my $count = scalar(@agent_list);
    $action_desc = "found $count active sub-agent(s)";
    
    return $self->success_result(
        "Found $count agent(s)",
        action_description => $action_desc,
        agents => \@agent_list,
        count => $count,
    );
}

sub status {
    my ($self, $params, $handler) = @_;
    
    my $agent_id = $params->{agent_id};
    return $self->error_result("Missing 'agent_id' parameter") unless $agent_id;
    
    my $action_desc = "checking status of $agent_id";
    
    unless ($handler->{manager}) {
        return $self->error_result("No sub-agents running");
    }
    
    my $agents = $handler->{manager}->list_agents();
    my $agent = $agents->{$agent_id};
    
    unless ($agent) {
        return $self->error_result("Agent not found: $agent_id");
    }
    
    my $elapsed = time() - $agent->{started};
    
    # Get log tail if available
    my $log_path = "/tmp/clio-agent-$agent_id.log";
    my $log_tail = '';
    if (-f $log_path) {
        $log_tail = ($^O eq "MSWin32" ? "" : `tail -20 "$log_path" 2>/dev/null`);
    }
    
    $action_desc = "$agent_id: $agent->{status} (${elapsed}s)";
    
    return $self->success_result(
        "Agent status: $agent_id",
        action_description => $action_desc,
        agent_id => $agent_id,
        status => $agent->{status},
        mode => $agent->{mode} || 'oneshot',
        task => $agent->{task},
        pid => $agent->{pid},
        runtime_seconds => $elapsed,
        log_path => $log_path,
        recent_log => $log_tail,
    );
}

sub kill {
    my ($self, $params, $handler, $context) = @_;
    
    my $agent_id = $params->{agent_id};
    return $self->error_result("Missing 'agent_id' parameter") unless $agent_id;
    
    my $action_desc = "terminating $agent_id";
    
    unless ($handler->{manager}) {
        return $self->error_result("No sub-agents running");
    }
    
    if ($handler->{manager}->kill_agent($agent_id)) {
        # Emit OSC agent exit event
        my $host_proto = $self->_get_host_proto($context);
        if ($host_proto && $host_proto->active()) {
            $host_proto->emit_agent_event('exit',
                id     => $agent_id,
                reason => 'killed',
            );
            $self->_emit_agent_tree($host_proto, $handler);
        }
        return $self->success_result("Terminated agent: $agent_id", action_description => $action_desc, agent_id => $agent_id);
    }
    
    return $self->error_result("Agent not found: $agent_id");
}

sub killall {
    my ($self, $handler, $context) = @_;
    
    my $action_desc = "terminating all sub-agents";
    
    unless ($handler->{manager}) {
        return $self->success_result("No sub-agents to kill", action_description => $action_desc, count => 0);
    }
    
    my $agents = $handler->{manager}->list_agents();
    my $count = 0;
    my $host_proto = $self->_get_host_proto($context);
    
    for my $agent_id (keys %$agents) {
        if ($handler->{manager}->kill_agent($agent_id)) {
            $count++;
            # Emit OSC agent exit event for each killed agent
            if ($host_proto && $host_proto->active()) {
                $host_proto->emit_agent_event('exit',
                    id     => $agent_id,
                    reason => 'killed',
                );
            }
        }
    }
    
    # Emit updated tree (should be empty now)
    if ($host_proto && $host_proto->active()) {
        $self->_emit_agent_tree($host_proto, $handler);
    }
    
    $action_desc = "terminated $count sub-agent(s)";
    return $self->success_result("Terminated $count agent(s)", action_description => $action_desc, count => $count);
}

sub inbox {
    my ($self, $handler, $context) = @_;
    
    my $action_desc = "checking agent inbox";
    
    # Poll broker for status updates from child agents and re-emit as OSC
    $self->_relay_child_status($handler);
    
    unless ($handler->{broker_client}) {
        return $self->success_result("No messages (broker not active)", action_description => $action_desc, messages => []);
    }
    
    my $messages = $handler->{broker_client}->poll_user_inbox();
    
    unless ($messages && @$messages) {
        return $self->success_result("No unread messages from sub-agents", action_description => "inbox empty", messages => []);
    }
    
    my @formatted = map {
        {
            id => $_->{id},
            from => $_->{from},
            type => $_->{type},
            content => $_->{content},
            timestamp => $_->{timestamp},
        }
    } @$messages;
    
    my $count = scalar(@formatted);
    $action_desc = "found $count unread message(s) from sub-agents";
    
    # Build expanded_content for the tool card display
    # Shows message summaries inline so user can see what agents sent
    my @expanded_content;
    for my $msg (@formatted) {
        my $from = $msg->{from} || 'unknown';
        my $type = $msg->{type} || 'generic';
        my $content = $msg->{content} || '';
        
        # Format content for single line display
        my $content_preview;
        if (ref($content) eq 'HASH') {
            # For structured content (like status), show key fields
            if ($content->{status}) {
                $content_preview = $content->{status};
                $content_preview .= ": $content->{current_task}" if $content->{current_task};
            } else {
                my @parts = map { "$_: $content->{$_}" } (sort keys %$content)[0..1];  # First 2 keys
                $content_preview = join(', ', @parts);
            }
        } else {
            # For string content, truncate if needed
            $content_preview = length($content) > 60 ? substr($content, 0, 57) . '...' : $content;
        }
        
        push @expanded_content, "[$from] $type: $content_preview";
    }
    
    # Build output that shows actual message content prominently
    # This ensures AI cannot ignore the messages
    my @output_lines;
    push @output_lines, "=== UNREAD MESSAGES ($count) ===";
    for my $msg (@formatted) {
        my $from = $msg->{from} || 'unknown';
        my $type = $msg->{type} || 'generic';
        my $content = $msg->{content} || '';
        push @output_lines, "";
        push @output_lines, "--- Message #$msg->{id} from $from [$type] ---";
        if (ref($content) eq 'HASH') {
            for my $key (sort keys %$content) {
                push @output_lines, "  $key: $content->{$key}";
            }
        } else {
            push @output_lines, "  $content";
        }
    }
    push @output_lines, "";
    push @output_lines, "Call agent_operations(operation: 'acknowledge') to mark as read.";
    
    # Emit OSC events for each message so host apps can display them
    my $host_proto = $self->_get_host_proto($context);
    if ($host_proto && $host_proto->active()) {
        for my $msg (@formatted) {
            $host_proto->emit_agent_event('message',
                id      => $msg->{from},
                type    => $msg->{type},
                content => ref($msg->{content}) ? encode_json($msg->{content}) : $msg->{content},
            );
        }
    }
    
    return $self->success_result(
        join("\n", @output_lines),
        action_description => $action_desc,
        expanded_content => \@expanded_content,
        messages => \@formatted,
        count => $count,
    );
}

sub acknowledge {
    my ($self, $params, $handler) = @_;
    
    my $action_desc = "acknowledging messages";
    
    unless ($handler->{broker_client}) {
        return $self->error_result("Broker not active");
    }
    
    my $message_ids = $params->{message_ids} || [];
    my $success = $handler->{broker_client}->acknowledge_messages(@$message_ids);
    
    if ($success) {
        my $desc = @$message_ids ? "acknowledged " . scalar(@$message_ids) . " message(s)" : "acknowledged all messages";
        return $self->success_result("Messages acknowledged", action_description => $desc);
    } else {
        return $self->error_result("Failed to acknowledge messages");
    }
}

sub history {
    my ($self, $handler) = @_;
    
    my $action_desc = "retrieving message history";
    
    unless ($handler->{broker_client}) {
        return $self->success_result("No history (broker not active)", action_description => $action_desc, messages => []);
    }
    
    my $messages = $handler->{broker_client}->get_message_history();
    
    unless ($messages && @$messages) {
        return $self->success_result("No messages in history", action_description => "history empty", messages => []);
    }
    
    my @formatted = map {
        {
            id => $_->{id},
            from => $_->{from},
            type => $_->{type},
            content => $_->{content},
            timestamp => $_->{timestamp},
        }
    } @$messages;
    
    my $count = scalar(@formatted);
    $action_desc = "found $count message(s) in history";
    
    # Build output showing complete message history
    my @output_lines;
    push @output_lines, "=== MESSAGE HISTORY ($count messages) ===";
    for my $msg (@formatted) {
        my $from = $msg->{from} || 'unknown';
        my $type = $msg->{type} || 'generic';
        my $content = $msg->{content} || '';
        my $time = localtime($msg->{timestamp});
        push @output_lines, "";
        push @output_lines, "--- Message #$msg->{id} from $from [$type] at $time ---";
        if (ref($content) eq 'HASH') {
            for my $key (sort keys %$content) {
                push @output_lines, "  $key: $content->{$key}";
            }
        } else {
            push @output_lines, "  $content";
        }
    }
    
    return $self->success_result(
        join("\n", @output_lines),
        action_description => $action_desc,
        messages => \@formatted,
        count => $count,
    );
}

sub send {
    my ($self, $params, $handler) = @_;
    
    my $agent_id = $params->{agent_id};
    my $message = $params->{message};
    
    return $self->error_result("Missing 'agent_id' parameter") unless $agent_id;
    return $self->error_result("Missing 'message' parameter") unless $message;
    
    my $action_desc = "sending message to $agent_id";
    
    unless ($handler->{broker_client}) {
        return $self->error_result("Broker not running");
    }
    
    my $msg_id = $handler->{broker_client}->send_message(
        to => $agent_id,
        message_type => 'guidance',
        content => $message,
    );
    
    # Create expanded content showing the message preview
    my $message_preview = length($message) > 70 ? substr($message, 0, 67) . '...' : $message;
    my @expanded_content = ($message_preview);
    
    if ($msg_id) {
        return $self->success_result(
            "Message sent to $agent_id",
            action_description => $action_desc,
            expanded_content => \@expanded_content,
            message_id => $msg_id,
            agent_id => $agent_id,
        );
    }
    
    return $self->error_result("Failed to send message");
}

sub broadcast {
    my ($self, $params, $handler) = @_;
    
    my $message = $params->{message};
    return $self->error_result("Missing 'message' parameter") unless $message;
    
    my $action_desc = "broadcasting to all agents";
    
    unless ($handler->{broker_client}) {
        return $self->error_result("Broker not running");
    }
    
    my $msg_id = $handler->{broker_client}->send_message(
        to => 'all',
        message_type => 'broadcast',
        content => $message,
    );
    
    if ($msg_id) {
        return $self->success_result(
            "Broadcast sent to all agents",
            action_description => $action_desc,
            message_id => $msg_id,
        );
    }
    
    return $self->error_result("Failed to broadcast");
}

1;

__END__

=head1 USAGE

The AI can use this tool to spawn and coordinate multiple sub-agents:

    # Spawn a sub-agent (inherits current session model)
    agent_operations(
        operation => "spawn",
        task => "Create a test file in scratch/",
    )
    
    # Check agent status
    agent_operations(operation => "list")
    
    # Check for messages
    agent_operations(operation => "inbox")
    
    # Reply to an agent
    agent_operations(
        operation => "send",
        agent_id => "agent-1",
        message => "Yes, proceed with that approach"
    )

=head1 SEE ALSO

L<CLIO::UI::Commands::SubAgent> - User slash commands for sub-agent management
L<CLIO::Coordination::Broker> - Central coordination broker
L<CLIO::Coordination::Client> - Broker client library

=cut

1;
