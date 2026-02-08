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
use CLIO::Core::Logger qw(should_log);
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
        supported_operations => [qw(spawn list status kill killall inbox send broadcast)],
        description => q{Sub-agent management for multi-agent coordination.

Spawn and manage sub-agents to work on tasks in parallel.

━━━━━━━━━━━━━━━━━━━━━ SPAWN (create agents) ━━━━━━━━━━━━━━━━━━━━━
-  spawn - Create a new sub-agent with a specific task
   Parameters: 
     task (required): Natural language description of what the agent should do
     model (optional): AI model to use (default: gpt-5-mini)
     persistent (optional): Keep agent alive for multiple tasks (default: false)
   Returns: Agent ID and confirmation

━━━━━━━━━━━━━━━━━━━━━ MANAGE (monitor/control) ━━━━━━━━━━━━━━━━━━━
-  list - List all active sub-agents and their status
   Parameters: none
   Returns: List of agents with status (running/exited/etc)

-  status - Get detailed status of a specific agent
   Parameters: agent_id (required)
   Returns: Detailed agent info including logs

-  kill - Terminate a specific agent
   Parameters: agent_id (required)
   Returns: Confirmation

-  killall - Terminate all agents
   Parameters: none
   Returns: Count of terminated agents

━━━━━━━━━━━━━━━━━━━━━ COMMUNICATE (messages) ━━━━━━━━━━━━━━━━━━━━
-  inbox - Check for messages from sub-agents
   Parameters: none
   Returns: List of messages (questions, status updates, completions)

-  send - Send guidance to a specific agent
   Parameters: agent_id (required), message (required)
   Returns: Confirmation

-  broadcast - Send message to all agents
   Parameters: message (required)
   Returns: Confirmation

EXAMPLE WORKFLOW:
1. Spawn agents: agent_operations(operation: "spawn", task: "create file X")
2. Monitor: agent_operations(operation: "list")
3. Check messages: agent_operations(operation: "inbox")
4. Reply if needed: agent_operations(operation: "send", agent_id: "agent-1", message: "yes")
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
                enum => ['spawn', 'list', 'status', 'kill', 'killall', 'inbox', 'send', 'broadcast'],
                description => 'Operation to perform',
            },
            task => {
                type => 'string',
                description => 'Task description for spawn operation',
            },
            model => {
                type => 'string',
                description => 'AI model for spawn (default: gpt-5-mini)',
            },
            persistent => {
                type => 'boolean',
                description => 'Keep agent alive for multiple tasks (spawn)',
            },
            agent_id => {
                type => 'string',
                description => 'Agent ID for status/kill/send operations',
            },
            message => {
                type => 'string',
                description => 'Message content for send/broadcast operations',
            },
        },
        required => ['operation'],
    };
}

sub execute {
    my ($self, $params, $context) = @_;
    
    my $operation = $params->{operation} || '';
    
    # Get or create the SubAgent command handler from context
    my $subagent_cmd = $self->_get_subagent_handler($context);
    unless ($subagent_cmd) {
        return $self->error_result("SubAgent system not available");
    }
    
    if ($operation eq 'spawn') {
        return $self->spawn($params, $subagent_cmd);
    }
    elsif ($operation eq 'list') {
        return $self->list($subagent_cmd);
    }
    elsif ($operation eq 'status') {
        return $self->status($params, $subagent_cmd);
    }
    elsif ($operation eq 'kill') {
        return $self->kill($params, $subagent_cmd);
    }
    elsif ($operation eq 'killall') {
        return $self->killall($subagent_cmd);
    }
    elsif ($operation eq 'inbox') {
        return $self->inbox($subagent_cmd);
    }
    elsif ($operation eq 'send') {
        return $self->send($params, $subagent_cmd);
    }
    elsif ($operation eq 'broadcast') {
        return $self->broadcast($params, $subagent_cmd);
    }
    else {
        return $self->error_result("Unknown operation: $operation");
    }
}

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

sub spawn {
    my ($self, $params, $handler) = @_;
    
    my $task = $params->{task};
    return $self->error_result("Missing 'task' parameter") unless $task;
    
    my $model = $params->{model} || 'gpt-5-mini';
    my $persistent = $params->{persistent} ? 1 : 0;
    
    # Truncate task for display
    my $task_short = length($task) > 50 ? substr($task, 0, 47) . '...' : $task;
    my $action_desc = "spawning sub-agent ($model): $task_short";
    
    # Build args string
    my $args = qq{"$task" --model $model};
    $args .= " --persistent" if $persistent;
    
    # Call the spawn command
    my $result = $handler->cmd_spawn($args);
    
    # Extract agent ID from result if available
    if ($handler->{manager}) {
        my $agents = $handler->{manager}->list_agents();
        my @ids = sort { $b cmp $a } keys %$agents;  # Get newest
        my $agent_id = $ids[0] || 'unknown';
        
        return $self->success_result(
            "Spawned sub-agent: $agent_id",
            action_description => $action_desc,
            agent_id => $agent_id,
            task => $task,
            model => $model,
            mode => $persistent ? 'persistent' : 'oneshot',
        );
    }
    
    return $self->success_result("Sub-agent spawned", action_description => $action_desc, task => $task);
}

sub list {
    my ($self, $handler) = @_;
    
    my $action_desc = "listing active sub-agents";
    
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
        $log_tail = `tail -20 "$log_path" 2>/dev/null`;
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
    my ($self, $params, $handler) = @_;
    
    my $agent_id = $params->{agent_id};
    return $self->error_result("Missing 'agent_id' parameter") unless $agent_id;
    
    my $action_desc = "terminating $agent_id";
    
    unless ($handler->{manager}) {
        return $self->error_result("No sub-agents running");
    }
    
    if ($handler->{manager}->kill_agent($agent_id)) {
        return $self->success_result("Terminated agent: $agent_id", action_description => $action_desc, agent_id => $agent_id);
    }
    
    return $self->error_result("Agent not found: $agent_id");
}

sub killall {
    my ($self, $handler) = @_;
    
    my $action_desc = "terminating all sub-agents";
    
    unless ($handler->{manager}) {
        return $self->success_result("No sub-agents to kill", action_description => $action_desc, count => 0);
    }
    
    my $agents = $handler->{manager}->list_agents();
    my $count = 0;
    
    for my $agent_id (keys %$agents) {
        if ($handler->{manager}->kill_agent($agent_id)) {
            $count++;
        }
    }
    
    $action_desc = "terminated $count sub-agent(s)";
    return $self->success_result("Terminated $count agent(s)", action_description => $action_desc, count => $count);
}

sub inbox {
    my ($self, $handler) = @_;
    
    my $action_desc = "checking agent inbox";
    
    unless ($handler->{broker_client}) {
        return $self->success_result("No messages (broker not active)", action_description => $action_desc, messages => []);
    }
    
    my $messages = $handler->{broker_client}->poll_user_inbox();
    
    unless ($messages && @$messages) {
        return $self->success_result("No messages from sub-agents", action_description => "inbox empty", messages => []);
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
    $action_desc = "received $count message(s) from sub-agents";
    
    return $self->success_result(
        "Received $count message(s)",
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
    
    if ($msg_id) {
        return $self->success_result(
            "Message sent to $agent_id",
            action_description => $action_desc,
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

    # Spawn a sub-agent
    agent_operations(
        operation => "spawn",
        task => "Create a test file in scratch/",
        model => "gpt-5-mini"
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
