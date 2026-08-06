# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Commands::SubAgent;

use strict;
use warnings;
use utf8;
use POSIX qw(setsid);
use Carp qw(croak);
use CLIO::UI::Terminal qw(ui_char);
use parent 'CLIO::UI::Commands::Base';


use CLIO::Core::Logger qw(log_debug log_error log_info log_warning);

=head1 NAME

CLIO::UI::Commands::SubAgent - Multi-agent coordination commands

=head1 DESCRIPTION

Commands for spawning and managing sub-agents that work in parallel.

Commands:
- /subagent spawn <task>
- /subagent list
- /subagent status <agent-id>
- /subagent kill <agent-id>
- /subagent killall
- /subagent locks
- /subagent discoveries
- /subagent warnings

Alias: /agent

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        manager => undef,     # SubAgent manager (created on first use)
        debug => $args{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}


sub handle {
    my ($self, $subcommand, $args) = @_;
    
    $subcommand ||= 'help';
    $args ||= '';
    
    if ($subcommand eq 'spawn') {
        return $self->cmd_spawn($args);
    }
    elsif ($subcommand eq 'list' || $subcommand eq 'ls') {
        return $self->cmd_list();
    }
    elsif ($subcommand eq 'status') {
        return $self->cmd_status($args);
    }
    elsif ($subcommand eq 'kill') {
        return $self->cmd_kill($args);
    }
    elsif ($subcommand eq 'killall') {
        return $self->cmd_killall();
    }
    elsif ($subcommand eq 'locks') {
        return $self->cmd_locks();
    }
    elsif ($subcommand eq 'discoveries' || $subcommand eq 'disc') {
        return $self->cmd_discoveries();
    }
    elsif ($subcommand eq 'warnings' || $subcommand eq 'warn') {
        return $self->cmd_warnings();
    }
    elsif ($subcommand eq 'inbox' || $subcommand eq 'messages') {
        return $self->cmd_inbox();
    }
    elsif ($subcommand eq 'ack' || $subcommand eq 'acknowledge') {
        return $self->cmd_ack($args);
    }
    elsif ($subcommand eq 'history' || $subcommand eq 'hist') {
        return $self->cmd_history();
    }
    elsif ($subcommand eq 'send') {
        return $self->cmd_send($args);
    }
    elsif ($subcommand eq 'reply') {
        return $self->cmd_reply($args);
    }
    elsif ($subcommand eq 'broadcast') {
        return $self->cmd_broadcast($args);
    }
    elsif ($subcommand eq 'projects' || $subcommand eq 'proj') {
        return $self->cmd_projects();
    }
    elsif ($subcommand eq 'help' || $subcommand eq '?') {
        return $self->cmd_help();
    }
    else {
        return "Unknown subcommand: $subcommand\nUse /subagent help for available commands";
    }
}

sub cmd_spawn {
    my ($self, $task) = @_;
    
    # Block sub-agents from spawning more sub-agents (prevent fork bombs)
    if ($ENV{CLIO_BROKER_AGENT_ID}) {
        return "ERROR: Sub-agents cannot spawn additional sub-agents.\n" .
               "This prevents coordination issues and fork bombs.\n" .
               "Send a message to the primary agent if you need additional help.";
    }
    
    unless ($task) {
        return "Usage: /subagent spawn <task>\nExample: /subagent spawn \"fix bug in Module::A\"";
    }
    
    # Get or create consistent session ID for this command's lifecycle
    my $session_id = $self->{chat}{session}{id} || $self->{coordination_session_id};
    unless ($session_id) {
        $session_id = "session-" . time();
        $self->{coordination_session_id} = $session_id;
    }
    
    # Auto-start broker if needed (ensure it's alive)
    $self->ensure_broker($session_id);
    
    # Initialize manager if needed
    unless ($self->{manager}) {
        require CLIO::Coordination::SubAgent;
        $self->{manager} = CLIO::Coordination::SubAgent->new(
            session_id => $session_id,
            broker_pid => $self->{broker_pid},
        );
    }
    
    # Parse options (--model, --persistent, --dir, etc)
    my $model;  # default: inherit current session model
    my $persistent = 0;  # default to oneshot mode
    my $working_dir;  # default: inherit parent's working directory
    
    if ($task =~ s/\s*--model\s+(\S+)\s*/ /) {
        $model = $1;
    }
    if ($task =~ s/\s*--persistent\s*/ /) {
        $persistent = 1;
    }
    if ($task =~ s/\s*--dir\s+"([^"]+)"\s*/ / || $task =~ s/\s*--dir\s+(\S+)\s*/ /) {
        $working_dir = $1;
    }
    if ($task =~ s/\s*--project\s+"([^"]+)"\s*/ / || $task =~ s/\s*--project\s+(\S+)\s*/ /) {
        # Resolve project name to working directory via Puppeteer topology
        my $project_name = $1;
        my $resolve_error;
        eval {
            require CLIO::Protocols::Puppeteer;
            my $pup = CLIO::Protocols::Puppeteer->new(root => '.');
            my $project = $pup->get_project($project_name);
            if ($project) {
                $working_dir = $project->{path};
            } else {
                $resolve_error = "Unknown project '$project_name'. Use /subagent projects to see available projects.";
            }
        };
        if ($@) {
            return "ERROR: Could not load Puppeteer module: $@";
        }
        if ($resolve_error) {
            return "ERROR: $resolve_error";
        }
    }

    # Pre-load skills (comma-separated names) so the subagent can use them
    # without needing skill_operations. Each skill is loaded into the
    # subagent's system prompt at spawn time. The full content is rendered
    # into the task so the child process can inject it via --skill flag.
    my @preloaded_skills;
    if ($task =~ s/\s*--skills?\s+"([^"]+)"\s*/ / || $task =~ s/\s*--skills?\s+([^\s]+(?:\s*,\s*[^\s]+)*)\s*/ /) {
        my $skill_list = $1;
        @preloaded_skills = split(/\s*,\s*/, $skill_list);
        @preloaded_skills = grep { defined $_ && length $_ } @preloaded_skills;
    }
    
    # Persistent mode requires a running broker - default to oneshot
    # Users can explicitly set persistent=true when a broker is available
    
    # If no model specified, inherit from the current session
    unless ($model) {
        if ($self->{chat} && $self->{chat}{ai_agent} && $self->{chat}{ai_agent}{api}) {
            $model = $self->{chat}{ai_agent}{api}->get_current_model();
        }
        unless ($model) {
            return "ERROR: No model specified and could not determine current session model. Use --model <name>.";
        }
    }
    
    # Clean up extra whitespace
    $task =~ s/^\s+|\s+$//g;
    
    # Spawn agent
    my $agent_id = $self->{manager}->spawn_agent($task,
        model => $model,
        persistent => $persistent,
        debug => $self->{debug},
        ($working_dir ? (working_dir => $working_dir) : ()),
        (@preloaded_skills ? (preloaded_skills => \@preloaded_skills) : ()),
    );
    
    my $mode_str = $persistent ? 'persistent' : 'oneshot';
    
    # Auto-create multiplexer pane for agent output
    my $mux_pane_id;
    if ($self->_multiplexer() && $self->_multiplexer()->auto_pane()) {
        $mux_pane_id = $self->_multiplexer()->create_agent_pane($agent_id);
    }
    
    # Display formatted output (skip when called from tool with suppress_display)
    unless ($self->{suppress_display}) {
        $self->display_section_header("SUB-AGENT SPAWNED");
        $self->display_key_value("Agent ID", $self->colorize($agent_id, 'BOLD'));
        $self->display_key_value("Mode", $self->colorize($mode_str, $persistent ? 'YELLOW' : 'CYAN'));
        $self->display_key_value("Model", $model);
        
        if ($working_dir) {
            $self->display_key_value("Working Dir", $self->colorize($working_dir, 'CYAN'));
        }

        if (@preloaded_skills) {
            $self->display_key_value("Pre-loaded Skills", $self->colorize(join(', ', @preloaded_skills), 'CYAN'));
        }
        
        if ($mux_pane_id) {
            my $mux_type = $self->_multiplexer()->type();
            $self->display_key_value("Output", $self->colorize("$mux_type pane (live)", 'GREEN'));
        }
        
        # Truncate long tasks for display
        my $display_task = length($task) > 60 ? substr($task, 0, 57) . '...' : $task;
        $self->display_key_value("Task", $self->colorize(qq{"$display_task"}, 'DIM'));
        $self->writeline("", markdown => 0);
        $self->writeline("Use " . $self->colorize("/subagent list", 'BOLD') . " to monitor progress", markdown => 0);
    }
    
    return "";  # Already displayed (or suppressed for tool path)
}

sub cmd_list {
    my ($self) = @_;
    
    unless ($self->{manager}) {
        $self->display_system_message("No sub-agents spawned this session.");
        $self->writeline("Use " . $self->colorize("/subagent spawn <task>", 'BOLD') . " to start one.", markdown => 0);
        return "";
    }
    
    my $agents = $self->{manager}->list_agents();
    
    unless (keys %$agents) {
        $self->display_system_message("No sub-agents"); return "";
    }
    
    # Enable pagination for long output
    $self->{chat}{pager}->enable();

    return unless $self->display_section_header("SUB-AGENTS");

    for my $id (sort keys %$agents) {
        my $agent = $agents->{$id};
        my $mode = $agent->{mode} || 'oneshot';
        my $status = $agent->{status};
        
        # Status styling
        my ($status_style, $status_label);
        if ($status eq 'running') {
            $status_style = 'GREEN';
            $status_label = 'running';
        } elsif ($status eq 'exited') {
            $status_style = 'DIM';
            $status_label = 'exited';
        } elsif ($status eq 'stopped') {
            $status_style = 'YELLOW';
            $status_label = 'stopped';
        } elsif ($status eq 'killed') {
            $status_style = 'RED';
            $status_label = 'killed';
        } else {
            $status_style = 'DIM';
            $status_label = $status;
        }
        
        my $elapsed = time() - $agent->{started};
        my $time_str = sprintf("%dm%ds", int($elapsed / 60), $elapsed % 60);
        my $mode_badge = $mode eq 'persistent' ? $self->colorize(' [P]', 'CYAN') : '';
        
        my $task_display = $agent->{task};
        $task_display = substr($task_display, 0, 45) . '...' if length($task_display) > 48;
        
        # Display agent row
        my $status_colored = $self->colorize("[$status_label]", $status_style);
        my $row = sprintf("  %-12s %s%s  %s (%s)",
            $self->colorize($id, 'BOLD'), $status_colored, $mode_badge, $task_display, $time_str);
        return unless $self->writeline($row, markdown => 0);
    }

    return unless $self->writeline("", markdown => 0);
    return unless $self->writeline($self->colorize("Legend: ", 'DIM') . $self->colorize("[P]", 'CYAN') .
        $self->colorize("=persistent mode, others are oneshot (exit after task)", 'DIM'), markdown => 0);

    # Disable pagination
    $self->{chat}{pager}->disable();
    
    return "";  # Already displayed
}

sub cmd_status {
    my ($self, $agent_id) = @_;
    
    unless ($agent_id) {
        $self->display_error_message("Usage: /subagent status <agent-id>");
        return "";
    }
    
    unless ($self->{manager}) {
        $self->display_error_message("No sub-agents running");
        return "";
    }
    
    my $agents = $self->{manager}->list_agents();
    my $agent = $agents->{$agent_id};
    
    unless ($agent) {
        $self->display_error_message("Agent not found: $agent_id");
        return "";
    }
    
    my $elapsed = time() - $agent->{started};
    my $time_str = sprintf("%dm%ds", int($elapsed / 60), $elapsed % 60);
    my $mode = $agent->{mode} || 'oneshot';
    
    # Status styling
    my $status = $agent->{status};
    my $status_style = 'DIM';
    $status_style = 'GREEN' if $status eq 'running';
    $status_style = 'YELLOW' if $status eq 'stopped';
    $status_style = 'RED' if $status eq 'killed';
    
    # Enable pagination
    $self->{chat}{pager}->enable();

    return unless $self->display_section_header("AGENT STATUS: $agent_id");
    return unless $self->display_key_value("Status", $self->colorize($status, $status_style));
    return unless $self->display_key_value("Mode", $mode eq 'persistent' ? $self->colorize('persistent', 'CYAN') : 'oneshot');
    return unless $self->display_key_value("PID", $agent->{pid});
    return unless $self->display_key_value("Runtime", $time_str);
    return unless $self->writeline("", markdown => 0);
    return unless $self->display_key_value("Task", $agent->{task});

    # Check log file
    my $log_path = "/tmp/clio-agent-$agent_id.log";
    if (-f $log_path) {
        return unless $self->writeline("", markdown => 0);
        return unless $self->display_key_value("Log", $log_path);
        return unless $self->writeline("", markdown => 0);
        return unless $self->writeline($self->colorize("Last 10 lines:", 'DIM'), markdown => 0);
        my $log_tail = ($^O eq "MSWin32" ? "" : `tail -10 "$log_path" 2>/dev/null`);
        if ($log_tail) {
            # Show log lines with dim styling
            for my $line (split /\n/, $log_tail) {
                return unless $self->writeline("  " . $self->colorize($line, 'DIM'), markdown => 0);
            }
        }
    }
    
    # Disable pagination
    $self->{chat}{pager}->disable();
    
    return "";
}

sub cmd_kill {
    my ($self, $agent_id) = @_;
    
    unless ($agent_id) {
        $self->display_error_message("Usage: /subagent kill <agent-id>"); return "";
    }
    
    unless ($self->{manager}) {
        $self->display_error_message("No sub-agents running"); return "";
    }
    
    if ($self->{manager}->kill_agent($agent_id)) {
        return "[" . ui_char("check") . "] Terminated agent: $agent_id";
    }
    
    $self->display_error_message("Agent not found: $agent_id"); return "";
}

sub cmd_killall {
    my ($self) = @_;
    
    unless ($self->{manager}) {
        $self->display_error_message("No sub-agents running"); return "";
    }
    
    my $agents = $self->{manager}->list_agents();
    my $count = 0;
    
    for my $agent_id (keys %$agents) {
        if ($self->{manager}->kill_agent($agent_id)) {
            $count++;
        }
    }
    
    return $count > 0 ? "[" . ui_char("check") . "] Terminated $count agent(s)" : "No agents to kill";
}

sub cmd_locks {
    my ($self) = @_;
    
    unless ($self->{broker_pid}) {
        return "Broker not running";
    }
    
    # Create temporary client to query broker
    require CLIO::Coordination::Client;
    my $session_id = $self->{chat}{session}{id} || "session-" . time();
    
    my $client = eval {
        CLIO::Coordination::Client->new(
            session_id => $session_id,
            agent_id => 'manager',
            task => 'Query locks',
        );
    };
    
    unless ($client) {
        return "Could not connect to broker: $@";
    }
    
    my $status = $client->get_status();
    $client->disconnect();
    
    unless ($status && $status->{type} eq 'status') {
        return "Could not query broker";
    }
    
    my $output = "Current Locks:\n\n";
    
    # File locks
    my $file_locks = $status->{file_locks} || {};
    if (keys %$file_locks) {
        $output .= "File Locks:\n";
        for my $file (sort keys %$file_locks) {
            my $lock = $file_locks->{$file};
            $output .= "  [" . ui_char("lock") . "] $file\n";
            $output .= "     Owner: $lock->{owner}\n";
            $output .= "     Mode: $lock->{mode}\n";
        }
    } else {
        $output .= "No file locks\n";
    }
    
    $output .= "\n";
    
    # Git lock
    my $git_lock = $status->{git_lock} || {};
    if ($git_lock->{holder}) {
        $output .= "Git Lock:\n";
        $output .= "  [" . ui_char("lock") . "] Held by: $git_lock->{holder}\n";
    } else {
        $output .= "No git lock\n";
    }
    
    return $output;
}

sub cmd_discoveries {
    my ($self) = @_;
    
    unless ($self->{broker_pid}) {
        return "Broker not running";
    }
    
    # Create temporary client to query broker
    require CLIO::Coordination::Client;
    my $session_id = $self->{chat}{session}{id} || "session-" . time();
    
    my $client = eval {
        CLIO::Coordination::Client->new(
            session_id => $session_id,
            agent_id => 'manager',
            task => 'Query discoveries',
        );
    };
    
    unless ($client) {
        return "Could not connect to broker: $@";
    }
    
    my $discoveries = $client->get_discoveries();
    $client->disconnect();
    
    unless ($discoveries && @$discoveries) {
        return "No discoveries shared yet";
    }
    
    my $output = "Shared Discoveries:\n\n";
    
    for my $disc (@$discoveries) {
        my $time_str = scalar localtime($disc->{timestamp});
        $output .= " [$disc->{category}] from $disc->{agent_id}\n";
        $output .= "   $disc->{content}\n";
        $output .= "   ($time_str)\n\n";
    }
    
    return $output;
}

sub cmd_warnings {
    my ($self) = @_;
    
    unless ($self->{broker_pid}) {
        return "Broker not running";
    }
    
    # Create temporary client to query broker
    require CLIO::Coordination::Client;
    my $session_id = $self->{chat}{session}{id} || "session-" . time();
    
    my $client = eval {
        CLIO::Coordination::Client->new(
            session_id => $session_id,
            agent_id => 'manager',
            task => 'Query warnings',
        );
    };
    
    unless ($client) {
        return "Could not connect to broker: $@";
    }
    
    my $warnings = $client->get_warnings();
    $client->disconnect();
    
    unless ($warnings && @$warnings) {
        return "No warnings shared yet";
    }
    
    my $output = "Shared Warnings:\n\n";
    
    for my $warn (@$warnings) {
        my $time_str = scalar localtime($warn->{timestamp});
        my $icon = $warn->{severity} eq 'high' ? '' :
                   $warn->{severity} eq 'medium' ? '' : '';
        $output .= "$icon [$warn->{severity}] from $warn->{agent_id}\n";
        $output .= "   $warn->{content}\n";
        $output .= "   ($time_str)\n\n";
    }
    
    return $output;
}

# === Message Bus Commands (Phase 2) ===

sub cmd_inbox {
    my ($self) = @_;
    
    unless ($self->{broker_client}) {
        $self->display_error_message("Broker not running. Spawn an agent first.");
        return "";
    }
    
    my $messages = $self->{broker_client}->poll_user_inbox();
    
    unless ($messages && @$messages) {
        $self->display_system_message("No unread messages from sub-agents.\nUse /subagent history to see all messages");
        return "";
    }
    
    # Enable pagination for long output
    $self->{chat}{pager}->enable();

    return unless $self->display_section_header("UNREAD MESSAGES (" . scalar(@$messages) . ")");

    for my $msg (@$messages) {
        my $from = $msg->{from} || 'unknown';
        my $type = $msg->{type} || 'generic';
        my $content = $msg->{content} || '';
        my $time = localtime($msg->{timestamp});
        my $id = $msg->{id};
        
        # Color by message type
        my $type_color = 'DIM';
        $type_color = 'YELLOW' if $type eq 'question';
        $type_color = 'GREEN' if $type eq 'complete';
        $type_color = 'RED' if $type eq 'blocked';
        $type_color = 'CYAN' if $type eq 'status';
        $type_color = 'MAGENTA' if $type eq 'discovery';

        return unless $self->writeline($self->colorize("[$type]", $type_color) . " from " .
            $self->colorize($from, 'BOLD') . " (id: $id)", markdown => 0);

        if (ref($content) eq 'HASH') {
            for my $key (sort keys %$content) {
                next unless defined $content->{$key};
                return unless $self->display_key_value("  $key", $content->{$key});
            }
        } else {
            return unless $self->writeline("  $content", markdown => 0);
        }

        return unless $self->writeline("", markdown => 0);
    }

    return unless $self->writeline("Use " . $self->colorize("/subagent reply <agent-id> <response>", 'BOLD') . " to respond", markdown => 0);
    return unless $self->writeline("Use " . $self->colorize("/subagent ack", 'BOLD') . " to mark messages as read", markdown => 0);

    # Disable pagination
    $self->{chat}{pager}->disable();
    
    return "";  # Already displayed
}

sub cmd_ack {
    my ($self, $args) = @_;
    
    unless ($self->{broker_client}) {
        $self->display_error_message("Broker not running.");
        return "";
    }
    
    # Parse optional message IDs from args
    my @ids;
    if ($args) {
        @ids = split /\s*,\s*|\s+/, $args;
    }
    
    my $success = $self->{broker_client}->acknowledge_messages(@ids);
    
    if ($success) {
        my $msg = @ids ? "Acknowledged " . scalar(@ids) . " message(s)" : "All messages acknowledged";
        $self->display_system_message($msg);
    } else {
        $self->display_error_message("Failed to acknowledge messages");
    }
    
    return "";
}

sub cmd_history {
    my ($self) = @_;
    
    unless ($self->{broker_client}) {
        $self->display_error_message("Broker not running. Spawn an agent first.");
        return "";
    }
    
    my $messages = $self->{broker_client}->get_message_history();
    
    unless ($messages && @$messages) {
        $self->display_system_message("No messages in history.");
        return "";
    }
    
    # Enable pagination for long output
    $self->{chat}{pager}->enable();

    return unless $self->display_section_header("MESSAGE HISTORY (" . scalar(@$messages) . ")");

    for my $msg (@$messages) {
        my $from = $msg->{from} || 'unknown';
        my $type = $msg->{type} || 'generic';
        my $content = $msg->{content} || '';
        my $time = localtime($msg->{timestamp});
        my $id = $msg->{id};
        
        # Color by message type
        my $type_color = 'DIM';
        $type_color = 'YELLOW' if $type eq 'question';
        $type_color = 'GREEN' if $type eq 'complete';
        $type_color = 'RED' if $type eq 'blocked';
        $type_color = 'CYAN' if $type eq 'status';
        $type_color = 'MAGENTA' if $type eq 'discovery';

        return unless $self->writeline($self->colorize("[$type]", $type_color) . " from " .
            $self->colorize($from, 'BOLD') . " (id: $id) at $time", markdown => 0);

        if (ref($content) eq 'HASH') {
            for my $key (sort keys %$content) {
                next unless defined $content->{$key};
                return unless $self->display_key_value("  $key", $content->{$key});
            }
        } else {
            return unless $self->writeline("  $content", markdown => 0);
        }

        return unless $self->writeline("", markdown => 0);
    }
    
    # Disable pagination
    $self->{chat}{pager}->disable();
    
    return "";  # Already displayed
}

sub cmd_send {
    my ($self, $args) = @_;
    
    unless ($self->{broker_client}) {
        $self->display_error_message("Broker not running. Spawn an agent first.");
        return "";
    }
    
    unless ($args =~ /^(\S+)\s+(.+)$/s) {
        $self->display_error_message("Usage: /subagent send <agent-id> <message>");
        return "";
    }
    
    my ($agent_id, $message) = ($1, $2);
    
    my $msg_id = $self->{broker_client}->send_message(
        to => $agent_id,
        message_type => 'guidance',
        content => $message,
    );
    
    if ($msg_id) {
        $self->display_system_message("Message sent to $agent_id (id: $msg_id)");
    } else {
        $self->display_error_message("Failed to send message");
    }
    return "";
}

sub cmd_reply {
    my ($self, $args) = @_;
    
    unless ($self->{broker_client}) {
        $self->display_error_message("Broker not running. Spawn an agent first.");
        return "";
    }
    
    unless ($args =~ /^(\S+)\s+(.+)$/s) {
        $self->display_error_message("Usage: /subagent reply <agent-id> <response>");
        return "";
    }
    
    my ($agent_id, $response) = ($1, $2);
    
    my $msg_id = $self->{broker_client}->send_message(
        to => $agent_id,
        message_type => 'clarification',
        content => $response,
    );
    
    if ($msg_id) {
        $self->display_system_message("Reply sent to $agent_id (id: $msg_id)");
    } else {
        $self->display_error_message("Failed to send reply");
    }
    return "";
}

sub cmd_broadcast {
    my ($self, $message) = @_;
    
    unless ($self->{broker_client}) {
        $self->display_error_message("Broker not running. Spawn an agent first.");
        return "";
    }
    
    unless ($message) {
        $self->display_error_message("Usage: /subagent broadcast <message>");
        return "";
    }
    
    my $msg_id = $self->{broker_client}->send_message(
        to => 'all',
        message_type => 'broadcast',
        content => $message,
    );
    
    if ($msg_id) {
        $self->display_system_message("Broadcast sent to all agents (id: $msg_id)");
    } else {
        $self->display_error_message("Failed to broadcast");
    }
    return "";
}

# === End Message Bus Commands ===

sub cmd_projects {
    my ($self) = @_;
    
    eval {
        require CLIO::Protocols::Puppeteer;
    };
    if ($@) {
        return "Puppeteer module not available: $@";
    }
    
    my $pup = CLIO::Protocols::Puppeteer->new(root => '.');
    my $topology = $pup->detect_topology();
    
    $self->display_command_header("PROJECTS");
    $self->writeline("", markdown => 0);
    
    if ($topology->{count} == 0) {
        $self->writeline("No child projects detected.", markdown => 0);
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("Tip: ", 'DIM') . "Projects are detected from .gitmodules and directories containing .clio/", markdown => 0);
        return "";
    }
    
    $self->writeline("Found $topology->{count} project(s):", markdown => 0);
    $self->writeline("", markdown => 0);
    
    for my $name (sort keys %{$topology->{projects}}) {
        my $p = $topology->{projects}{$name};
        
        my @flags;
        push @flags, $self->colorize("LTM", 'GREEN') if $p->{has_ltm};
        push @flags, $self->colorize("instructions", 'GREEN') if $p->{has_instructions};
        push @flags, $self->colorize("submodule", 'CYAN') if $p->{source} eq 'submodule';
        push @flags, $self->colorize("directory", 'DIM') if $p->{source} eq 'directory';
        
        my $flag_str = @flags ? " [" . join(", ", @flags) . "]" : "";
        $self->writeline("  " . $self->colorize($name, 'BOLD') . " ($p->{path})$flag_str", markdown => 0);
    }
    
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("Usage: ", 'DIM') . '/subagent spawn "task" --dir ./ProjectName', markdown => 0);
    
    return "";
}

sub cmd_help {
    my ($self) = @_;
    
    # Enable pagination for help text
    $self->{chat}{pager}->enable();

    return unless $self->display_command_header("SUB-AGENT");
    return unless $self->writeline("", markdown => 0);
    return unless $self->writeline("Spawn and manage multiple CLIO agents working in parallel.", markdown => 0);
    return unless $self->writeline("", markdown => 0);

    my @help_sections = (
        { header => 'LIFECYCLE', rows => [
            ['/subagent spawn <task>',          'Spawn new sub-agent with task', 35],
            ['  --model <model>',                'Specify AI model (default: current session model)', 35],
            ['  --persistent',                   'Keep agent alive for multiple tasks', 35],
            ['/subagent list',                   'List all sub-agents and their status', 35],
            ['/subagent status <id>',            'Show detailed agent status', 35],
            ['/subagent kill <id>',              'Terminate specific agent', 35],
            ['/subagent killall',                'Terminate all sub-agents', 35],
        ], after => [''] },
        { header => 'COMMUNICATION', rows => [
            ['/subagent inbox',                  'Show UNREAD messages from agents', 35],
            ['/subagent ack [ids]',              'Mark messages as read', 35],
            ['/subagent history',                'Show ALL messages (read+unread)', 35],
            ['/subagent send <id> <msg>',        'Send message to agent', 35],
            ['/subagent reply <id> <msg>',       'Reply to agent question', 35],
            ['/subagent broadcast <msg>',        'Send message to all agents', 35],
        ], after => [''] },
        { header => 'COORDINATION', rows => [
            ['/subagent locks',                  'Show current file/git locks', 35],
            ['/subagent discoveries',            'Show shared discoveries', 35],
            ['/subagent warnings',               'Show shared warnings', 35],
        ], after => [''] },
        { header => 'PUPPETEER (MULTI-PROJECT)', rows => [
            ['/subagent projects',               'List child projects with .clio/ context', 35],
            ['/subagent spawn <task> --dir <path>',     'Spawn agent in project directory', 35],
            ['/subagent spawn <task> --project <name>', 'Spawn agent by project name', 35],
        ], after => [''] },
        { header => 'MODES', rows => [], after => [
            $self->colorize('  Oneshot (default): ', 'BOLD') . 'Agent completes one task and exits',
            $self->colorize('  Persistent:        ', 'BOLD') . 'Agent stays alive, polls for messages',
            '',
            $self->colorize('Tip: ', 'DIM') . 'Use --persistent for interactive work where you need to reply.',
        ] },
    );

    for my $section (@help_sections) {
        return unless $self->display_section_header($section->{header});
        for my $row (@{$section->{rows}}) {
            return unless $self->display_command_row(@{$row});
        }
        for my $line (@{$section->{after}}) {
            return unless $self->writeline($line, markdown => 0);
        }
    }

    # Disable pagination
    $self->{chat}{pager}->disable();
    
    return "";  # Already displayed
}

=head2 _multiplexer()

Lazy-initialize and return the Multiplexer instance. Returns undef if
no multiplexer is detected.

=cut

sub _multiplexer {
    my ($self) = @_;

    # Return cached instance or undef
    return $self->{_multiplexer} if exists $self->{_multiplexer};

    # Try to load and detect multiplexer
    eval {
        require CLIO::UI::Multiplexer;
        $self->{_multiplexer} = CLIO::UI::Multiplexer->new(
            debug => $self->{debug},
        );
    };
    if ($@) {
        log_warning('SubAgent', "Failed to load Multiplexer: $@");
        $self->{_multiplexer} = undef;
    }

    # If no multiplexer detected, cache undef to avoid re-checking
    unless ($self->{_multiplexer} && $self->{_multiplexer}->available()) {
        $self->{_multiplexer} = undef;
    }

    return $self->{_multiplexer};
}

=head2 multiplexer()

Public accessor for the Multiplexer instance (used by /mux commands).

=cut

sub multiplexer {
    my ($self) = @_;
    return $self->_multiplexer();
}

=head2 start_broker()

Start the coordination broker if not already running.

=cut

sub ensure_broker {
    my ($self, $session_id) = @_;
    
    # Check if broker is running and alive
    if ($self->{broker_pid}) {
        if (kill(0, $self->{broker_pid})) {
            # Broker is alive
            return 1;
        }
        # Broker died - clean up and restart
        log_warning('SubAgent', "Broker PID $self->{broker_pid} is dead, restarting");
        $self->{broker_pid} = undef;
        $self->{broker_client} = undef;
    }
    
    # Start a new broker
    $self->start_broker($session_id);
    return 1;
}

sub start_broker {
    my ($self, $session_id) = @_;
    
    # Use provided session ID or fall back
    $session_id ||= $self->{chat}{session}{id} || "session-" . time();
    
    # Pre-load Broker module before fork (avoids runtime loading in child)
    require CLIO::Coordination::Broker;
    
    my $pid = fork();
    croak "Cannot fork broker: $!" unless defined $pid;
    
    if ($pid == 0) {
        # Child process - run broker
        
        # Reset terminal state first, while still connected to parent TTY
        # This must happen BEFORE closing STDIN or redirecting output
        eval {
            require CLIO::Compat::Terminal;
            CLIO::Compat::Terminal::reset_terminal();  # Full reset including stty sane
        };
        
        # Redirect I/O early so we capture everything
        my $log_path = "/tmp/clio-broker-$session_id.log";
        open(STDERR, '>>', $log_path) or die "Cannot open log: $!";
        open(STDOUT, '>&STDERR') or die "Cannot dup STDERR: $!";
        autoflush STDERR 1;
        autoflush STDOUT 1;
        
        log_debug('SubAgent', "Broker child process starting, PID=$$");
        log_debug('SubAgent', "Terminal reset complete");
        
        # Close inherited file descriptors
        close(STDIN) or do { CLIO::Core::Logger::log_warning('SubAgent', "Cannot close STDIN: $!"); };
        log_debug('SubAgent', "STDIN closed");
        
        # Detach from terminal
        log_debug('SubAgent', "Calling setsid()...");
        setsid() or do {
            log_error('SubAgent', "[ERROR] setsid() failed: $!");
            exit 1;
        };
        log_debug('SubAgent', "setsid() complete");
        
        # Redirect STDIN from null device
        my $nulldev = $^O eq 'MSWin32' ? 'nul' : '/dev/null';
        open(STDIN, '<', $nulldev) or do {
            log_error('SubAgent', "[ERROR] Cannot redirect STDIN: $!");
            exit 1;
        };
        log_debug('SubAgent', "STDIN redirected from $nulldev");
        
        # Now run broker
        log_debug('SubAgent', "About to create Broker object");
        
        eval {
            require CLIO::Coordination::Broker;
            log_debug('SubAgent', "Broker module loaded");
            
            my $broker = CLIO::Coordination::Broker->new(
                session_id => $session_id,
                debug => 1,
                no_idle_exit => 1,
            );
            
            log_debug('SubAgent', "Broker object created, calling run()");
            $broker->run();
            log_info('SubAgent', "[INFO] Broker run() returned (should not happen)");
        };
        
        if ($@) {
            log_error('SubAgent', "[ERROR] Broker died: $@");
        }
        
        log_debug('SubAgent', "Broker child exiting");
        exit 0;
    }
    
    # Parent - save broker PID and wait for startup
    $self->{broker_pid} = $pid;
    $self->{coordination_session_id} = $session_id;
    sleep 1;  # Give broker time to start
    
    # Connect to broker as the primary user/manager
    eval {
        require CLIO::Coordination::Client;
        $self->{broker_client} = CLIO::Coordination::Client->new(
            session_id => $session_id,
            agent_id => 'user',  # Primary user connection
            task => 'Primary user session',
        );
        log_debug('SubAgent', "Connected to broker as primary user");
        
        # Note: We do NOT inject broker_client into the primary agent's APIManager.
        # The broker rate limiter is for sub-agent coordination only. The primary
        # agent uses its own local rate limiter. Injecting it here would cause the
        # primary agent to block on broker API slots while sub-agents are working.
    };
    if ($@) {
        log_warning('SubAgent', "Could not connect to broker: $@");
    }
    
    log_info('SubAgent', "Broker started with PID: $pid for session: $session_id");
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.

1;
