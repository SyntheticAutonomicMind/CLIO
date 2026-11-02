package CLIO::Tools::SubAgentOperations;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use Scalar::Util qw(blessed);
use CLIO::Util::JSON qw(encode_json);
use Cwd qw(abs_path);
use Time::HiRes qw(sleep);
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
        supported_operations => [qw(spawn list status wait kill killall inbox acknowledge history send broadcast report)],
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

━━━━━━━━━━━━━━━━━━━━━ READ (reports) ━━━━━━━━━━━━━━━━━━━━━━━━━
-  report - Read an agent's full final report
   Parameters: agent_id (required)
   Returns: The complete text the agent reported

EXAMPLE WORKFLOW:
1. Spawn agents: agent_operations(operation: "spawn", task: "create file X")
2. Keep working, do not block on them
3. When an agent reports in, read the message: agent_operations(operation: "inbox")
4. Pull the full text of one report: agent_operations(operation: "report", agent_id: "agent-1")
5. Reply if needed: agent_operations(operation: "send", agent_id: "agent-1", message: "yes")
6. Mark as read: agent_operations(operation: "acknowledge")
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
                enum => ['spawn', 'list', 'status', 'wait', 'kill', 'killall', 'inbox', 'acknowledge', 'history', 'send', 'broadcast', 'report'],
                description => '[REQUIRED] Operation to perform.',
            },
            task => {
                type => 'string',
                description => '[REQUIRED for spawn - agent will fail without this] Natural language task description for the agent.',
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
                description => '[REQUIRED for status/kill/send/report operations] Agent ID to target. Omit for list/inbox/broadcast/spawn operations.',
            },
            message => {
                type => 'string',
                description => '[REQUIRED for send/broadcast] Message content to send to agent.',
            },
            working_dir => {
                type => 'string',
                description => '[OPTIONAL] Working directory for agent. Loads that project\'s .clio/ context (LTM, instructions, memory).',
            },
            skills => {
                type => 'string',
                description => '[OPTIONAL] Comma-separated skill names to pre-load into the subagent\'s system prompt. Each skill is rendered and injected; the subagent treats them as active instructions without needing to call skill_operations.',
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
    
    # Sandbox mode: Block all sub-agent operations
    if ($context && $context->{config} && $context->{config}->get('sandbox')) {
        return $self->error_result(
            "Sandbox mode: Sub-agent operations are disabled.\n\n" .
            "The --sandbox flag blocks all sub-agent spawning and management. " .
            "This is a security feature to prevent the agent from reaching outside the local project."
        );
    }
    
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
        report      => '_dispatch_report',
    };
}

# Dispatch wrappers adapt the standard ($params, $context) signature
# to SubAgentOperations' methods that take $subagent_cmd

sub _dispatch_spawn       { my ($self, $params, $ctx) = @_; $self->spawn($params, $self->{_subagent_cmd}, $ctx) }
sub _dispatch_list        { my ($self, $params, $ctx) = @_; $self->list($self->{_subagent_cmd}, $ctx) }
sub _dispatch_status      { my ($self, $params, $ctx) = @_; $self->status($params, $self->{_subagent_cmd}) }
sub _dispatch_wait        { my ($self, $params, $ctx) = @_; $self->wait($params, $self->{_subagent_cmd}, $ctx) }
sub _dispatch_kill        { my ($self, $params, $ctx) = @_; $self->kill($params, $self->{_subagent_cmd}, $ctx) }
sub _dispatch_killall     { my ($self, $params, $ctx) = @_; $self->killall($self->{_subagent_cmd}, $ctx) }
sub _dispatch_inbox       { my ($self, $params, $ctx) = @_; $self->inbox($self->{_subagent_cmd}, $ctx) }
sub _dispatch_acknowledge { my ($self, $params, $ctx) = @_; $self->acknowledge($params, $self->{_subagent_cmd}) }
sub _dispatch_history     { my ($self, $params, $ctx) = @_; $self->history($self->{_subagent_cmd}) }
sub _dispatch_send        { my ($self, $params, $ctx) = @_; $self->send($params, $self->{_subagent_cmd}) }
sub _dispatch_report      { my ($self, $params, $ctx) = @_; $self->report($params, $self->{_subagent_cmd}) }
sub _dispatch_broadcast   { my ($self, $params, $ctx) = @_; $self->broadcast($params, $self->{_subagent_cmd}) }

sub _get_subagent_handler {
    my ($self, $context) = @_;
    
    # Path 1: Direct from context (most common for tool calls)
    if ($context->{subagent_cmd}) {
        return $context->{subagent_cmd};
    }
    
    # Path 2: From UI's command handler (primary path for interactive sessions)
    my $ui = $context->{ui};
    if ($ui && ref($ui) && $ui->can('get_command_handler')) {
        my $ch = $ui->get_command_handler();
        if ($ch && $ch->{subagent_cmd}) {
            return $ch->{subagent_cmd};
        }
    }
    
    # Path 3: From blessed UI object with command_handler attribute
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
    
    # Path 4: Fall back to creating a minimal handler (for non-UI contexts)
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
        
        # Create a minimal broker_client stub for non-UI contexts.
        # Must be a blessed object (not a plain hashref) because callers
        # use method-call syntax: $handler->{broker_client}->poll_user_inbox()
        # A plain hashref with coderef values would fail with "Can't call
        # method ... on unblessed reference".
        my $mock_broker_client = CLIO::Coordination::BrokerClient::Mock->new();
        
        # Cache the handler so subsequent calls reuse the same instance
        $self->{_subagent_handler} = CLIO::UI::Commands::SubAgent->new(
            chat => $mock_chat,
            debug => $self->{debug},
        );
        # Inject mock broker_client so inbox/relay don't crash
        $self->{_subagent_handler}{broker_client} = $mock_broker_client;
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
    return $self->error_result("Missing required parameter: task") unless $task;
    
    # Use explicitly requested model, or inherit the current session model
    my $model = $params->{model} || ($context && $context->{current_model}) || ($context && $context->{api_manager} && $context->{api_manager}->can('get_current_model') && $context->{api_manager}->get_current_model()) || 'unknown';
    my $persistent = $params->{persistent} ? 1 : 0;
    my $working_dir = $params->{working_dir};

    # Validate working_dir exists if provided
    if ($working_dir) {
        unless (-d $working_dir) {
            return $self->error_result("Working directory does not exist: $working_dir");
        }
        # Ensure it's an absolute path
        $working_dir = abs_path($working_dir) || $working_dir;
    }

    # Optional pre-loaded skills: comma-separated list of names that
    # should be rendered into the subagent's system prompt at spawn time.
    my @preloaded_skills;
    if ($params->{skills}) {
        @preloaded_skills = grep { defined $_ && length $_ } split(/\s*,\s*/, $params->{skills});
    }

    # Persistent mode requires a running broker - default to oneshot
    # Users can explicitly set persistent=true when a broker is available

    # Truncate task for display
    my $task_short = length($task) > 50 ? substr($task, 0, 47) . '...' : $task;
    my $action_desc = "spawning sub-agent ($model): $task_short";
    $action_desc .= " in $working_dir" if $working_dir;
    $action_desc .= " [skills: " . join(',', @preloaded_skills) . "]" if @preloaded_skills;

    # Build args string
    my $args = qq{"$task" --model $model};
    $args .= " --persistent" if $persistent;
    $args .= qq{ --dir "$working_dir"} if $working_dir;
    $args .= qq{ --skills "${\(join(',', @preloaded_skills))}"} if @preloaded_skills;
    
    # Extract model routing config from the parent context so it can be
    # passed through cmd_spawn -> spawn_agent -> _run_agent_loop.
    # The UI path (cmd_spawn) extracts this from $self->{chat}{config},
    # but the tool path goes through a mock chat, so we need to pass it
    # explicitly via the args string.
    my $routing_args = '';
    my @route_candidates;
    my $route_index;
    my $route_name;
    my $route_active_role;
    if ($context && $context->{api_manager} && $context->{api_manager}{config}) {
        my $parent_config = $context->{api_manager}{config};
        my $candidates = $parent_config->get_model_candidates();
        if ($candidates && ref($candidates) eq 'ARRAY' && @$candidates) {
            @route_candidates = @$candidates;
            $route_index = $parent_config->get_model_routing_index() // 0;
            $routing_args .= " --route-candidates " . join(',', map { quotemeta($_) } @$candidates);
            $routing_args .= " --route-index " . int($route_index);
        }
        $route_name = $parent_config->get('route_name');
        if (defined $route_name && length($route_name)) {
            $routing_args .= " --route-name " . quotemeta($route_name);
        }
        # Also propagate the active role so the sub-agent inherits it
        if ($parent_config->can('get_route_active_role')) {
            $route_active_role = $parent_config->get_route_active_role();
            if (defined $route_active_role && length($route_active_role)) {
                $routing_args .= " --route-role " . quotemeta($route_active_role);
            }
        }
    }
    
    # Suppress direct display - we'll return expanded_content instead
    $handler->{suppress_display} = 1;
    
    # Call the spawn command (display suppressed)
    my $result = $handler->cmd_spawn($args . $routing_args);

    delete $handler->{suppress_display};
    
    # Extract agent ID from result if available
    if ($handler->{manager}) {
        my $agents = $handler->{manager}->list_agents();
        # Get newest agent by numeric ID (not string sort, which
        # would put agent-10 before agent-2)
        my @ids = sort {
            my ($an) = $a =~ /(\d+)/;
            my ($bn) = $b =~ /(\d+)/;
            ($an // 0) <=> ($bn // 0)
        } keys %$agents;
        my $agent_id = $ids[-1] || 'unknown';
        
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
        
        # Register the agent with the session so the UI can track its
        # state, report elapsed time and label its cards.
        if ($context && $context->{ui}) {
            my $ui = $context->{ui};
            if ($ui->can('register_agent')) {
                $ui->register_agent($agent_id,
                    project => $working_dir,
                    task    => $task,
                    model   => $model,
                );
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
            (@preloaded_skills ? (preloaded_skills => \@preloaded_skills) : ()),
            (@route_candidates ? (model_candidates => \@route_candidates) : ()),
            (defined $route_index ? (model_routing_index => $route_index) : ()),
            (defined $route_name ? (route_name => $route_name) : ()),
            (defined $route_active_role ? (route_active_role => $route_active_role) : ()),
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

# NOTE: the status_update and activity queues are owned by the session
# UI (CLIO::UI::Chat::_poll_broker_events), which polls them once per
# loop to render live agent cards and to forward OSC agent events to an
# external host application. Polling them here as well would steal
# events from that consumer, because both broker queues are destructive
# on read.



sub wait {
    my ($self, $params, $handler, $context) = @_;

    my $timeout = $params->{timeout} || 60;
    my $poll_interval = $params->{poll_interval} || 1;  # Default to 1 second for more responsive polling

    my $action_desc = "waiting for agent activity (${timeout}s timeout)";

    unless ($handler->{manager}) {
        return $self->error_result("No sub-agents spawned");
    }

    my $start = time();
    my @events;

    # Cursors stop the same event being reported twice. poll_user_inbox
    # is non-destructive by design (messages stay unread until the AI
    # acknowledges them), so without a cursor every poll re-delivered
    # every message the AI had already seen and 'wait' could never
    # return a quiet result.
    my $msg_cursor = $handler->{_wait_msg_cursor} // 0;
    my %reported_exit = %{ $handler->{_wait_exit_cursor} || {} };

    while ((time() - $start) < $timeout) {
        # Allow the user to break out of a long wait. Every other
        # long-running tool honours this; wait did not, so a multi-minute
        # wait could not be interrupted with ESC.
        if ($self->check_interrupt($context)) {
            my $elapsed = int(time() - $start);
            $handler->{_wait_msg_cursor} = $msg_cursor;
            $handler->{_wait_exit_cursor} = \%reported_exit;
            return $self->success_result(
                "Wait interrupted by user after ${elapsed}s",
                action_description => "wait interrupted after ${elapsed}s",
                events => \@events,
                count => scalar(@events),
                elapsed => $elapsed,
                timed_out => 0,
                interrupted => 1,
            );
        }

        # Render live agent activity so the user can see what the agents
        # are doing while this wait blocks the session. Without this the
        # wait is a black box: nothing appears on screen until it
        # returns.
        if ($context && $context->{ui}
            && $context->{ui}->can('poll_agent_activity')
            && $handler->{broker_client}) {
            eval {
                $context->{ui}->poll_agent_activity($handler->{broker_client});
            };
        }

        # Check for new messages from agents. Only messages we have not
        # already reported are returned.
        if ($handler->{broker_client}) {
            my $messages = eval { $handler->{broker_client}->poll_user_inbox() };
            if ($messages && @$messages) {
                for my $msg (@$messages) {
                    my $id = $msg->{id} // 0;
                    next if $id && $id <= $msg_cursor;
                    $msg_cursor = $id if $id > $msg_cursor;

                    # Bound the content. A wave of agent reports would
                    # otherwise put every full report into the manager's
                    # context in one tool result. The full text stays
                    # available through the 'report' operation.
                    my $content = $msg->{content};
                    if (!ref($content) && defined($content) && length($content) > 2000) {
                        $content = substr($content, 0, 2000)
                            . "\n[truncated - call agent_operations(operation: 'report', "
                            . "agent_id: '" . ($msg->{from} // 'unknown') . "') for the full text]";
                    }

                    push @events, {
                        type => 'message',
                        from => $msg->{from},
                        message_type => $msg->{type},
                        content => $content,
                        timestamp => $msg->{timestamp},
                        id => $msg->{id},
                    };
                }
            }
        }

        # Check for agent exits. An agent is reported once.
        my $agents = $handler->{manager}->list_agents();
        for my $id (sort keys %$agents) {
            my $agent = $agents->{$id};
            next unless $agent->{status} && $agent->{status} eq 'exited';
            next if $reported_exit{$id};
            $reported_exit{$id} = 1;

            push @events, {
                type => 'exit',
                agent_id => $id,
                task => $agent->{task},
                exit_code => $agent->{exit_code},
            };
        }

        $handler->{_wait_msg_cursor} = $msg_cursor;
        $handler->{_wait_exit_cursor} = \%reported_exit;

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

        # Sleep before next poll (use Time::HiRes for sub-second precision)
        Time::HiRes::sleep($poll_interval);
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
    my ($self, $handler, $context) = @_;
    
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
    return $self->error_result("Missing required parameter: agent_id") unless $agent_id;
    
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
    my $log_path = CLIO::Coordination::SubAgent->log_path_for($agent_id);
    my $log_tail = '';
    if (-f $log_path) {
        # Read in-process rather than shelling out. The agent id reaches
        # this code from a tool call, and interpolating it into a shell
        # command would allow command substitution.
        eval {
            open(my $fh, '<:encoding(UTF-8)', $log_path) or die "Cannot open log: $!";
            my @lines = <$fh>;
            close $fh;
            @lines = @lines[-20 .. -1] if @lines > 20;
            $log_tail = join('', @lines);
        };
        $log_tail = '' if $@;
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

=head2 report($params, $handler)

Read an agent's full final report.

The inbox operation returns a bounded preview so a wave of agent reports
cannot flood the manager's context. This operation returns the complete
text of one agent's report.

Arguments:
- $params: Hashref with agent_id
- $handler: The sub-agent command handler

Returns: Success result carrying the full report text.

=cut

sub report {
    my ($self, $params, $handler) = @_;

    my $agent_id = $params->{agent_id};
    return $self->error_result("Missing required parameter: agent_id") unless $agent_id;

    my $report_path = CLIO::Coordination::SubAgent->report_path_for($agent_id);
    my $report = '';

    if (-f $report_path) {
        eval {
            open(my $fh, '<:encoding(UTF-8)', $report_path)
                or die "Cannot open report file: $!";
            $report = do { local $/; <$fh> };
            close $fh;
        };
        if ($@) {
            return $self->error_result("Cannot read agent report: $@");
        }
    }

    # Fall back to the tail of the agent's log when no report was
    # written. The agent may still be running, or may have failed before
    # producing a final answer.
    my $source = 'report';
    unless (length $report) {
        my $log_path = CLIO::Coordination::SubAgent->log_path_for($agent_id);
        if (-f $log_path) {
            eval {
                open(my $fh, '<:encoding(UTF-8)', $log_path)
                    or die "Cannot open log file: $!";
                my @lines = <$fh>;
                close $fh;
                @lines = @lines[-100 .. -1] if @lines > 100;
                $report = join('', @lines);
            };
            $source = 'log tail' if !$@ && length $report;
        }
    }

    unless (length $report) {
        return $self->error_result("No report available for $agent_id");
    }

    my $action_desc = "reading report for $agent_id ($source)";

    return $self->success_result(
        $report,
        action_description => $action_desc,
        agent_id => $agent_id,
        source => $source,
        report_path => $report_path,
    );
}

sub kill {
    my ($self, $params, $handler, $context) = @_;    
    my $agent_id = $params->{agent_id};
    return $self->error_result("Missing required parameter: agent_id") unless $agent_id;

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
                # Show all key fields in the preview — not just the first 2
                my @parts = map { "$_: $content->{$_}" } (sort keys %$content);
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
    #
    # Each message is bounded. A wave of agent reports would otherwise
    # put every full report into the manager's context at once, which is
    # the resource that decides whether the manager can still synthesise
    # the results. The full text stays available through the 'report'
    # operation.
    my $max_preview = 2000;
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
        }
        elsif (length($content) > $max_preview) {
            push @output_lines, "  " . substr($content, 0, $max_preview);
            push @output_lines,
                "  [truncated - call agent_operations(operation: 'report', agent_id: '$from') for the full text]";
        }
        else {
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
    
    # DO NOT auto-acknowledge messages here. Messages should only be acknowledged
    # when the AI explicitly calls agent_operations(operation: 'acknowledge').
    # This preserves unread state if the AI doesn't process the messages.
    
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
    
    return $self->error_result("Missing required parameter: agent_id") unless $agent_id;
    return $self->error_result("Missing required parameter: message") unless $message;
    
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
    return $self->error_result("Missing required parameter: message") unless $message;
    
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

# Mock broker client for non-interactive contexts (no broker running).
# Provides no-op returns so inbox/status/list operations degrade
# gracefully instead of crashing on method calls to a non-object.
package CLIO::Coordination::BrokerClient::Mock;
sub new { bless {}, shift }
sub poll_status_updates  { return [] }
sub poll_user_inbox      { return [] }
sub acknowledge_messages { return 1 }
sub send_message         { return undef }
sub get_message_history  { return [] }
sub get_status           { return { type => 'status' } }
sub disconnect           { }

1;
