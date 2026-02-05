package CLIO::Coordination::SubAgent;

use strict;
use warnings;
use utf8;
use CLIO::Coordination::Broker;
use CLIO::Coordination::Client;
use POSIX qw(setsid);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::Coordination::SubAgent - Spawn and manage CLIO sub-agents

=head1 DESCRIPTION

Spawns independent CLIO processes that connect to the coordination broker
and work on specific tasks in parallel with the main agent and each other.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        session_id => $args{session_id},
        broker_pid => $args{broker_pid},
        broker_path => $args{broker_path},
        agents => {},  # agent_id => { pid, task, status }
        next_agent_id => 1,
    };
    
    die "session_id required" unless $self->{session_id};
    
    return bless $self, $class;
}

=head2 spawn_agent($task, %options)

Spawn a new sub-agent to work on a specific task.

Returns: agent_id

=cut

sub spawn_agent {
    my ($self, $task, %options) = @_;
    
    my $agent_id = "agent-" . $self->{next_agent_id}++;
    
    my $pid = fork();
    die "Fork failed: $!" unless defined $pid;
    
    if ($pid == 0) {
        # Child process - become sub-agent
        $self->run_subagent($agent_id, $task, %options);
        exit 0;
    }
    
    # Parent process - track agent
    $self->{agents}{$agent_id} = {
        pid => $pid,
        task => $task,
        status => 'running',
        started => time(),
    };
    
    return $agent_id;
}

=head2 run_subagent($agent_id, $task, %options)

Runs in the child process. Connects to broker and executes task.

=cut

sub run_subagent {
    my ($self, $agent_id, $task, %options) = @_;
    
    # CRITICAL: Reset terminal state before detaching
    # The child inherits the parent's terminal settings, which can corrupt the parent's terminal
    eval {
        require CLIO::Compat::Terminal;
        CLIO::Compat::Terminal::ReadMode(0);  # Normal mode
    };
    
    # Close inherited file descriptors (except STDIN which we'll redirect)
    # This prevents the child from interfering with parent's terminal I/O
    close(STDIN) or warn "Cannot close STDIN: $!";
    
    # Detach from parent terminal session
    setsid() or die "Cannot start new session: $!";
    
    # Find CLIO executable
    use FindBin;
    my $clio_path = "$FindBin::Bin/clio";
    unless (-x $clio_path) {
        die "Cannot find CLIO executable: $clio_path";
    }
    
    # Set environment for broker connection
    $ENV{CLIO_BROKER_SESSION} = $self->{session_id};
    $ENV{CLIO_BROKER_AGENT_ID} = $agent_id;
    
    # Build CLIO command
    my $model = $options{model} || 'gpt-5-mini';
    my @cmd = (
        $clio_path,
        '--model', $model,
        '--input', $task,
        '--exit',
    );
    
    # Redirect ALL I/O to log file (completely detach from parent terminal)
    my $log_path = "/tmp/clio-agent-$agent_id.log";
    open(STDIN, '<', '/dev/null') or die "Cannot redirect STDIN: $!";
    open(STDOUT, '>>', $log_path) or die "Cannot open log: $!";
    open(STDERR, '>&STDOUT') or die "Cannot redirect STDERR: $!";
    
    print "=== Sub-agent $agent_id starting ===\n";
    print "Task: $task\n";
    print "Model: $model\n";
    print "Session: $self->{session_id}\n";
    print "Command: " . join(' ', @cmd) . "\n\n";
    
    # Execute (replaces this process entirely)
    exec(@cmd) or die "Cannot exec CLIO: $!";
}

=head2 list_agents()

Returns hash of all active agents.

=cut

sub list_agents {
    my ($self) = @_;
    
    # Check which agents are still running
    for my $agent_id (keys %{$self->{agents}}) {
        my $agent = $self->{agents}{$agent_id};
        if (kill(0, $agent->{pid}) == 0) {
            # Process no longer exists
            $agent->{status} = 'completed';
        }
    }
    
    return $self->{agents};
}

=head2 kill_agent($agent_id)

Terminate a specific agent.

=cut

sub kill_agent {
    my ($self, $agent_id) = @_;
    
    return unless exists $self->{agents}{$agent_id};
    
    my $agent = $self->{agents}{$agent_id};
    kill 'TERM', $agent->{pid};
    $agent->{status} = 'killed';
    
    return 1;
}

=head2 wait_all()

Wait for all agents to complete.

=cut

sub wait_all {
    my ($self) = @_;
    
    for my $agent_id (keys %{$self->{agents}}) {
        my $agent = $self->{agents}{$agent_id};
        if ($agent->{status} eq 'running') {
            waitpid($agent->{pid}, 0);
            $agent->{status} = 'completed';
        }
    }
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.
