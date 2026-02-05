package CLIO::UI::Commands::SubAgent;

use strict;
use warnings;
use utf8;

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

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
        chat => $args{chat},  # Reference to Chat.pm
        manager => undef,     # SubAgent manager (created on first use)
    };
    
    return bless $self, $class;
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
    elsif ($subcommand eq 'help' || $subcommand eq '?') {
        return $self->cmd_help();
    }
    else {
        return "Unknown subcommand: $subcommand\nUse /subagent help for available commands";
    }
}

sub cmd_spawn {
    my ($self, $task) = @_;
    
    unless ($task) {
        return "Usage: /subagent spawn <task>\nExample: /subagent spawn \"fix bug in Module::A\"";
    }
    
    # Auto-start broker if needed
    unless ($self->{broker_pid}) {
        $self->start_broker();
    }
    
    # Initialize manager if needed
    unless ($self->{manager}) {
        require CLIO::Coordination::SubAgent;
        my $session_id = $self->{chat}{session}{id} || "session-" . time();
        $self->{manager} = CLIO::Coordination::SubAgent->new(
            session_id => $session_id,
            broker_pid => $self->{broker_pid},
        );
    }
    
    # Parse options (--model, etc)
    my $model = 'gpt-5-mini';  # default
    if ($task =~ s/\s*--model\s+(\S+)\s*/ /) {
        $model = $1;
    }
    
    # Clean up extra whitespace
    $task =~ s/^\s+|\s+$//g;
    
    # Spawn agent
    my $agent_id = $self->{manager}->spawn_agent($task, model => $model);
    
    return "✓ Spawned sub-agent: $agent_id\nTask: $task\nModel: $model\n\n" .
           "Use /subagent list to monitor progress";
}

sub cmd_list {
    my ($self) = @_;
    
    unless ($self->{manager}) {
        return "No sub-agents running";
    }
    
    my $agents = $self->{manager}->list_agents();
    
    unless (keys %$agents) {
        return "No sub-agents";
    }
    
    my $output = "Active Sub-Agents:\n\n";
    for my $id (sort keys %$agents) {
        my $agent = $agents->{$id};
        my $status_icon = $agent->{status} eq 'running' ? '●' : 
                          $agent->{status} eq 'completed' ? '✓' : '✗';
        my $elapsed = time() - $agent->{started};
        my $time_str = sprintf("%dm%ds", int($elapsed / 60), $elapsed % 60);
        
        $output .= sprintf("  %s %-12s [%-10s] %s (%s)\n",
            $status_icon, $id, $agent->{status}, $agent->{task}, $time_str);
    }
    
    return $output;
}

sub cmd_status {
    my ($self, $agent_id) = @_;
    
    unless ($agent_id) {
        return "Usage: /subagent status <agent-id>";
    }
    
    unless ($self->{manager}) {
        return "No sub-agents running";
    }
    
    my $agents = $self->{manager}->list_agents();
    my $agent = $agents->{$agent_id};
    
    unless ($agent) {
        return "Agent not found: $agent_id";
    }
    
    my $elapsed = time() - $agent->{started};
    my $time_str = sprintf("%dm%ds", int($elapsed / 60), $elapsed % 60);
    
    my $output = "Agent: $agent_id\n";
    $output .= "Status: $agent->{status}\n";
    $output .= "Task: $agent->{task}\n";
    $output .= "PID: $agent->{pid}\n";
    $output .= "Runtime: $time_str\n";
    
    # Check log file
    my $log_path = "/tmp/clio-agent-$agent_id.log";
    if (-f $log_path) {
        $output .= "Log: $log_path\n";
        $output .= "\nLast 10 lines of log:\n";
        my $log_tail = `tail -10 "$log_path" 2>/dev/null`;
        if ($log_tail) {
            $output .= $log_tail;
        }
    }
    
    return $output;
}

sub cmd_kill {
    my ($self, $agent_id) = @_;
    
    unless ($agent_id) {
        return "Usage: /subagent kill <agent-id>";
    }
    
    unless ($self->{manager}) {
        return "No sub-agents running";
    }
    
    if ($self->{manager}->kill_agent($agent_id)) {
        return "✓ Terminated agent: $agent_id";
    }
    
    return "Agent not found: $agent_id";
}

sub cmd_killall {
    my ($self) = @_;
    
    unless ($self->{manager}) {
        return "No sub-agents running";
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

sub cmd_help {
    my ($self) = @_;
    
    return <<'HELP';
Sub-Agent Commands (alias: /agent)

Spawn and manage multiple CLIO agents working in parallel:

  /subagent spawn <task>      Spawn new sub-agent with task
  /subagent list              List all active sub-agents
  /subagent status <id>       Show detailed status
  /subagent kill <id>         Terminate specific agent
  /subagent killall           Terminate all sub-agents
  /subagent locks             Show current file/git locks
  /subagent discoveries       Show shared discoveries
  /subagent warnings          Show shared warnings

Examples:
  /subagent spawn "fix bug in lib/Module/A.pm"
  /subagent spawn "add tests" --model gpt-4.1
  /subagent list
  /subagent kill agent-1
  /subagent discoveries

All sub-agents coordinate through a broker to prevent conflicts.
File locks ensure no concurrent edits. Git locks serialize commits.
HELP
}

=head2 start_broker()

Start the coordination broker if not already running.

=cut

sub start_broker {
    my ($self) = @_;
    
    my $session_id = $self->{chat}{session}{id} || "session-" . time();
    
    my $pid = fork();
    die "Cannot fork broker: $!" unless defined $pid;
    
    if ($pid == 0) {
        # Child process - run broker
        
        # CRITICAL: Reset terminal state before detaching
        eval {
            require CLIO::Compat::Terminal;
            CLIO::Compat::Terminal::ReadMode(0);  # Normal mode
        };
        
        # Close inherited file descriptors
        close(STDIN) or warn "Cannot close STDIN: $!";
        
        # Detach from terminal
        setsid() or die "Cannot start new session: $!";
        
        # Redirect ALL I/O to log
        my $log_path = "/tmp/clio-broker-$session_id.log";
        open(STDIN, '<', '/dev/null') or die "Cannot redirect STDIN: $!";
        open(STDERR, '>>', $log_path) or die "Cannot open broker log: $!";
        open(STDOUT, '>&STDERR') or die "Cannot redirect STDOUT: $!";
        
        require CLIO::Coordination::Broker;
        my $broker = CLIO::Coordination::Broker->new(
            session_id => $session_id,
            debug => 1,
        );
        
        $broker->run();
        exit 0;
    }
    
    # Parent - save broker PID and wait for startup
    $self->{broker_pid} = $pid;
    sleep 1;  # Give broker time to start
    
    print STDERR "[Broker started with PID: $pid for session: $session_id]\n";
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.
