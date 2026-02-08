package CLIO::UI::Commands::SubAgent;

use strict;
use warnings;
use utf8;
use POSIX qw(setsid);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use CLIO::Core::Logger qw(should_log);

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

# Delegate display methods to chat
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_section_header { shift->{chat}->display_section_header(@_) }
sub display_key_value { shift->{chat}->display_key_value(@_) }
sub display_command_row { shift->{chat}->display_command_row(@_) }
sub display_list_item { shift->{chat}->display_list_item(@_) }
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub colorize { shift->{chat}->colorize(@_) }
sub writeline { shift->{chat}->writeline(@_) }

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
    elsif ($subcommand eq 'send') {
        return $self->cmd_send($args);
    }
    elsif ($subcommand eq 'reply') {
        return $self->cmd_reply($args);
    }
    elsif ($subcommand eq 'broadcast') {
        return $self->cmd_broadcast($args);
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
    
    # Auto-start broker if needed
    unless ($self->{broker_pid}) {
        $self->start_broker($session_id);
    }
    
    # Initialize manager if needed
    unless ($self->{manager}) {
        require CLIO::Coordination::SubAgent;
        $self->{manager} = CLIO::Coordination::SubAgent->new(
            session_id => $session_id,
            broker_pid => $self->{broker_pid},
        );
    }
    
    # Parse options (--model, --persistent, etc)
    my $model = 'gpt-5-mini';  # default
    my $persistent = 0;  # default to oneshot mode
    
    if ($task =~ s/\s*--model\s+(\S+)\s*/ /) {
        $model = $1;
    }
    if ($task =~ s/\s*--persistent\s*/ /) {
        $persistent = 1;
    }
    
    # Clean up extra whitespace
    $task =~ s/^\s+|\s+$//g;
    
    # Spawn agent
    my $agent_id = $self->{manager}->spawn_agent($task, 
        model => $model,
        persistent => $persistent,
    );
    
    my $mode_str = $persistent ? 'persistent' : 'oneshot';
    
    # Display formatted output following CLIO style
    $self->display_section_header("SUB-AGENT SPAWNED");
    $self->display_key_value("Agent ID", $self->colorize($agent_id, 'BOLD'));
    $self->display_key_value("Mode", $self->colorize($mode_str, $persistent ? 'YELLOW' : 'CYAN'));
    $self->display_key_value("Model", $model);
    
    # Truncate long tasks for display
    my $display_task = length($task) > 60 ? substr($task, 0, 57) . '...' : $task;
    $self->display_key_value("Task", $self->colorize(qq{"$display_task"}, 'DIM'));
    $self->writeline("", markdown => 0);
    $self->writeline("Use " . $self->colorize("/subagent list", 'BOLD') . " to monitor progress", markdown => 0);
    
    return "";  # Already displayed
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
    $self->{chat}{pagination_enabled} = 1;
    
    $self->display_section_header("SUB-AGENTS");
    
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
        $self->writeline(sprintf("  %-12s %s%s  %s (%s)",
            $self->colorize($id, 'BOLD'), $status_colored, $mode_badge, $task_display, $time_str), markdown => 0);
    }
    
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("Legend: ", 'DIM') . $self->colorize("[P]", 'CYAN') . 
        $self->colorize("=persistent mode, others are oneshot (exit after task)", 'DIM'), markdown => 0);
    
    # Disable pagination
    $self->{chat}{pagination_enabled} = 0;
    
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
    $self->{chat}{pagination_enabled} = 1;
    
    $self->display_section_header("AGENT STATUS: $agent_id");
    $self->display_key_value("Status", $self->colorize($status, $status_style));
    $self->display_key_value("Mode", $mode eq 'persistent' ? $self->colorize('persistent', 'CYAN') : 'oneshot');
    $self->display_key_value("PID", $agent->{pid});
    $self->display_key_value("Runtime", $time_str);
    $self->writeline("", markdown => 0);
    $self->display_key_value("Task", $agent->{task});
    
    # Check log file
    my $log_path = "/tmp/clio-agent-$agent_id.log";
    if (-f $log_path) {
        $self->writeline("", markdown => 0);
        $self->display_key_value("Log", $log_path);
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("Last 10 lines:", 'DIM'), markdown => 0);
        my $log_tail = `tail -10 "$log_path" 2>/dev/null`;
        if ($log_tail) {
            # Show log lines with dim styling
            for my $line (split /\n/, $log_tail) {
                $self->writeline("  " . $self->colorize($line, 'DIM'), markdown => 0);
            }
        }
    }
    
    # Disable pagination
    $self->{chat}{pagination_enabled} = 0;
    
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
        return "✓ Terminated agent: $agent_id";
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
    
    return $count > 0 ? "✓ Terminated $count agent(s)" : "No agents to kill";
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
            $output .= "  🔒 $file\n";
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
        $output .= "  🔒 Held by: $git_lock->{holder}\n";
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
        $self->display_system_message("No messages from sub-agents.");
        return "";
    }
    
    # Enable pagination for long output
    $self->{chat}{pagination_enabled} = 1;
    
    $self->display_section_header("AGENT MESSAGES (" . scalar(@$messages) . ")");
    
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
        
        $self->writeline($self->colorize("[$type]", $type_color) . " from " . 
            $self->colorize($from, 'BOLD') . " (id: $id)", markdown => 0);
        
        if (ref($content) eq 'HASH') {
            for my $key (sort keys %$content) {
                $self->display_key_value("  $key", $content->{$key}) if defined $content->{$key};
            }
        } else {
            $self->writeline("  $content", markdown => 0);
        }
        
        $self->writeline("", markdown => 0);
    }
    
    $self->writeline("Use " . $self->colorize("/subagent reply <agent-id> <response>", 'BOLD') . " to respond", markdown => 0);
    
    # Disable pagination
    $self->{chat}{pagination_enabled} = 0;
    
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

sub cmd_help {
    my ($self) = @_;
    
    # Enable pagination for help text
    $self->{chat}{pagination_enabled} = 1;
    
    $self->display_command_header("SUB-AGENT");
    $self->writeline("", markdown => 0);
    $self->writeline("Spawn and manage multiple CLIO agents working in parallel.", markdown => 0);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("LIFECYCLE");
    $self->display_command_row("/subagent spawn <task>", "Spawn new sub-agent with task", 35);
    $self->display_command_row("  --model <model>", "Specify AI model (default: gpt-5-mini)", 35);
    $self->display_command_row("  --persistent", "Keep agent alive for multiple tasks", 35);
    $self->display_command_row("/subagent list", "List all sub-agents and their status", 35);
    $self->display_command_row("/subagent status <id>", "Show detailed agent status", 35);
    $self->display_command_row("/subagent kill <id>", "Terminate specific agent", 35);
    $self->display_command_row("/subagent killall", "Terminate all sub-agents", 35);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("COMMUNICATION");
    $self->display_command_row("/subagent inbox", "Show messages from agents", 35);
    $self->display_command_row("/subagent send <id> <msg>", "Send message to agent", 35);
    $self->display_command_row("/subagent reply <id> <msg>", "Reply to agent question", 35);
    $self->display_command_row("/subagent broadcast <msg>", "Send message to all agents", 35);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("COORDINATION");
    $self->display_command_row("/subagent locks", "Show current file/git locks", 35);
    $self->display_command_row("/subagent discoveries", "Show shared discoveries", 35);
    $self->display_command_row("/subagent warnings", "Show shared warnings", 35);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("MODES");
    $self->writeline($self->colorize("  Oneshot (default): ", 'BOLD') . "Agent completes one task and exits", markdown => 0);
    $self->writeline($self->colorize("  Persistent:        ", 'BOLD') . "Agent stays alive, polls for messages", markdown => 0);
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("Tip: ", 'DIM') . "Use --persistent for interactive work where you need to reply.", markdown => 0);
    
    # Disable pagination
    $self->{chat}{pagination_enabled} = 0;
    
    return "";  # Already displayed
}

=head2 start_broker()

Start the coordination broker if not already running.

=cut

sub start_broker {
    my ($self, $session_id) = @_;
    
    # Use provided session ID or fall back
    $session_id ||= $self->{chat}{session}{id} || "session-" . time();
    
    # Pre-load Broker module before fork (avoids runtime loading in child)
    require CLIO::Coordination::Broker;
    
    my $pid = fork();
    die "Cannot fork broker: $!" unless defined $pid;
    
    if ($pid == 0) {
        # Child process - run broker
        
        # Redirect I/O early so we capture everything
        my $log_path = "/tmp/clio-broker-$session_id.log";
        open(STDERR, '>>', $log_path) or die "Cannot open log: $!";
        open(STDOUT, '>&STDERR') or die "Cannot dup STDERR: $!";
        autoflush STDERR 1;
        autoflush STDOUT 1;
        
        print STDERR "[DEBUG] Broker child process starting, PID=$$\n";
        
        # CRITICAL: Reset terminal state before detaching
        eval {
            require CLIO::Compat::Terminal;
            CLIO::Compat::Terminal::ReadMode(0);  # Normal mode
            print STDERR "[DEBUG] Terminal reset complete\n";
        };
        if ($@) {
            print STDERR "[ERROR] Terminal reset failed: $@\n";
        }
        
        # Close inherited file descriptors
        close(STDIN) or do { print STDERR "[WARN] Cannot close STDIN: $!\n"; };
        print STDERR "[DEBUG] STDIN closed\n";
        
        # Detach from terminal
        print STDERR "[DEBUG] Calling setsid()...\n";
        setsid() or do {
            print STDERR "[ERROR] setsid() failed: $!\n";
            exit 1;
        };
        print STDERR "[DEBUG] setsid() complete\n";
        
        # Redirect STDIN from /dev/null
        open(STDIN, '<', '/dev/null') or do {
            print STDERR "[ERROR] Cannot redirect STDIN: $!\n";
            exit 1;
        };
        print STDERR "[DEBUG] STDIN redirected from /dev/null\n";
        
        # Now run broker
        print STDERR "[DEBUG] About to create Broker object\n";
        
        eval {
            require CLIO::Coordination::Broker;
            print STDERR "[DEBUG] Broker module loaded\n";
            
            my $broker = CLIO::Coordination::Broker->new(
                session_id => $session_id,
                debug => 1,
            );
            
            print STDERR "[DEBUG] Broker object created, calling run()\n";
            $broker->run();
            print STDERR "[INFO] Broker run() returned (should not happen)\n";
        };
        
        if ($@) {
            print STDERR "[ERROR] Broker died: $@\n";
        }
        
        print STDERR "[DEBUG] Broker child exiting\n";
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
        print STDERR "[DEBUG] Connected to broker as primary user\n" if should_log('DEBUG');
    };
    if ($@) {
        print STDERR "[WARN] Could not connect to broker: $@\n" if should_log('WARN');
    }
    
    print STDERR "[INFO] Broker started with PID: $pid for session: $session_id\n" if should_log('INFO');
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.
