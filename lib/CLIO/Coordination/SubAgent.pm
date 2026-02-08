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
    
    my $session_id = $args{session_id};
    die "session_id required" unless $session_id;
    
    # Determine temporary directory (use /dev/shm on Linux, /tmp on macOS)
    my $temp_dir = '/dev/shm';
    $temp_dir = '/tmp' if ($^O eq 'darwin' || !-d '/dev/shm');
    
    # Load or initialize agent counter (persists for session only)
    my $counter_file = "$temp_dir/clio-subagent-counter-$session_id.txt";
    my $next_id = 1;
    
    # Read with locking to prevent race conditions
    if (-f $counter_file) {
        if (open(my $fh, '+<', $counter_file)) {
            flock($fh, 2) or warn "Cannot lock counter: $!";  # LOCK_EX
            $next_id = <$fh> || 1;
            chomp $next_id;
            $next_id = int($next_id) || 1;
            close $fh;  # Releases lock
        }
    }
    
    my $self = {
        session_id => $session_id,
        broker_pid => $args{broker_pid},
        broker_path => $args{broker_path},
        agents => {},  # agent_id => { pid, task, status }
        next_agent_id => $next_id,
        counter_file => $counter_file,
    };
    
    return bless $self, $class;
}

=head2 spawn_agent($task, %options)

Spawn a new sub-agent to work on a specific task.

Returns: agent_id

=cut

sub spawn_agent {
    my ($self, $task, %options) = @_;
    
    my $agent_id = "agent-" . $self->{next_agent_id}++;
    
    # Persist counter for next spawn (with locking)
    if ($self->{counter_file}) {
        if (open(my $fh, '>', $self->{counter_file})) {
            flock($fh, 2) or warn "Cannot lock counter: $!";  # LOCK_EX
            print $fh $self->{next_agent_id};
            close $fh;  # Releases lock
        }
    }
    
    my $pid = fork();
    die "Fork failed: $!" unless defined $pid;
    
    if ($pid == 0) {
        # Child process - become sub-agent
        $self->run_subagent($agent_id, $task, %options);
        exit 0;
    }
    
    # Parent process - track agent
    my $mode = $options{persistent} ? 'persistent' : 'oneshot';
    $self->{agents}{$agent_id} = {
        pid => $pid,
        task => $task,
        status => 'running',
        mode => $mode,
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
    
    # Redirect ALL I/O to log file (completely detach from parent terminal)
    my $log_path = "/tmp/clio-agent-$agent_id.log";
    open(STDIN, '<', '/dev/null') or die "Cannot redirect STDIN: $!";
    open(STDOUT, '>>', $log_path) or die "Cannot open log: $!";
    open(STDERR, '>&STDOUT') or die "Cannot redirect STDERR: $!";
    
    print "=== Sub-agent $agent_id starting ===\n";
    print "Task: $task\n";
    print "Session: $self->{session_id}\n";
    
    # Check if persistent mode requested
    if ($options{persistent}) {
        $self->run_persistent_agent($agent_id, $task, %options);
    } else {
        $self->run_oneshot_agent($agent_id, $task, %options);
    }
}

sub run_oneshot_agent {
    my ($self, $agent_id, $task, %options) = @_;
    
    # Original exec-based implementation
    
    # Find CLIO executable
    use FindBin;
    my $clio_path = "$FindBin::Bin/clio";
    unless (-x $clio_path) {
        die "Cannot find CLIO executable: $clio_path";
    }
    
    # Set environment for broker connection and custom configuration
    $ENV{CLIO_BROKER_SESSION} = $self->{session_id};
    $ENV{CLIO_BROKER_AGENT_ID} = $agent_id;
    $ENV{CLIO_CUSTOM_INSTRUCTIONS} = "$FindBin::Bin/.clio/subagent-instructions.md";  # Override instructions
    
    # Build CLIO command
    my $model = $options{model} || 'gpt-5-mini';
    my @cmd = (
        $clio_path,
        '--model', $model,
        '--input', $task,
        '--exit',
    );
    
    print "Model: $model\n";
    print "Command: " . join(' ', @cmd) . "\n";
    print "Env: CLIO_BROKER_SESSION=$ENV{CLIO_BROKER_SESSION}\n";
    print "Env: CLIO_BROKER_AGENT_ID=$ENV{CLIO_BROKER_AGENT_ID}\n";
    print "Env: CLIO_CUSTOM_INSTRUCTIONS=$ENV{CLIO_CUSTOM_INSTRUCTIONS}\n\n";
    
    # Execute (replaces this process entirely)
    exec(@cmd) or die "Cannot exec CLIO: $!";
}

sub run_persistent_agent {
    my ($self, $agent_id, $task, %options) = @_;
    
    print "Mode: PERSISTENT\n";
    print "Starting persistent agent loop\n\n";
    
    # Load required modules
    use CLIO::Core::AgentLoop;
    use CLIO::Coordination::Client;
    use CLIO::Core::SimpleAIAgent;
    use CLIO::Core::APIManager;
    use CLIO::Core::Config;
    use CLIO::Session::Manager;
    
    # Create broker client
    my $client = CLIO::Coordination::Client->new(
        session_id => $self->{session_id},
        agent_id => $agent_id,
        task => $task,
        debug => 1,
    );
    
    print "[INFO] Connected to broker\n" if $ENV{CLIO_LOG_LEVEL};
    
    # Create Config and Session (same as main CLIO initialization)
    my $config = CLIO::Core::Config->new();
    my $model = $options{model} || 'gpt-5-mini';
    my $debug = $options{debug} || 0;
    
    # Create a session for this agent (required for API tracking, history, etc.)
    my $session = CLIO::Session::Manager->create(
        debug => $debug,
    );
    
    # Create APIManager with proper configuration and session
    my $api_manager = CLIO::Core::APIManager->new(
        config => $config,
        model => $model,
        session => $session->state(),  # Pass session state for thread tracking
        debug => $debug,
    );
    
    # Create SimpleAIAgent for AI interactions (same as main CLIO)
    my $ai_agent = CLIO::Core::SimpleAIAgent->new(
        api => $api_manager,  # APIManager instance required
        session => $session,   # Session for history tracking
        debug => $debug,
        broker_client => $client,  # Pass broker client for coordination
    );
    
    # Load custom instructions if available
    my $custom_instructions = '';
    if ($ENV{CLIO_CUSTOM_INSTRUCTIONS} && -f $ENV{CLIO_CUSTOM_INSTRUCTIONS}) {
        open my $fh, '<', $ENV{CLIO_CUSTOM_INSTRUCTIONS};
        $custom_instructions = do { local $/; <$fh> };
        close $fh;
        print "Loaded custom instructions\n";
    }
    
    # Define task handler callback
    my $task_handler = sub {
        my ($task_content, $loop) = @_;
        
        print "[AgentLoop] Processing task: $task_content\n";
        
        # Build prompt with custom instructions
        my $prompt = $custom_instructions ? "$custom_instructions\n\n$task_content" : $task_content;
        
        # Call AI to process task using SimpleAIAgent (same as main CLIO)
        my $result = $ai_agent->process_user_request($prompt, {
            on_chunk => sub {
                my ($chunk) = @_;
                print $chunk if defined $chunk;
            },
        });
        
        if ($result->{success}) {
            print "[AgentLoop] Task completed successfully\n";
            return {
                completed => 1,
                message => $result->{content} || "Completed: $task_content",
            };
        } else {
            print "[AgentLoop] Task failed: " . ($result->{error} || 'Unknown error') . "\n";
            return {
                blocked => 1,
                reason => $result->{error} || 'Unknown error',
            };
        }
    };
    
    # Create and run agent loop
    my $loop = CLIO::Core::AgentLoop->new(
        client => $client,
        initial_task => $task,
        on_task => $task_handler,
        debug => 1,
    );
    
    print "Starting agent loop\n";
    
    eval {
        $loop->run();
    };
    if ($@) {
        print "Agent loop error: $@\n";
        die $@;
    }
    
    print "Agent loop exited\n";
    $client->disconnect();
}

=head2 list_agents()

Returns hash of all active agents.

=cut

sub list_agents {
    my ($self) = @_;
    
    # Check which agents are still running
    for my $agent_id (keys %{$self->{agents}}) {
        my $agent = $self->{agents}{$agent_id};
        next unless $agent->{status} eq 'running';
        
        if (kill(0, $agent->{pid}) == 0) {
            # Process no longer exists
            if ($agent->{mode} eq 'oneshot') {
                $agent->{status} = 'exited';  # Oneshot agents exit after task
            } else {
                $agent->{status} = 'stopped';  # Persistent agents shouldn't exit
            }
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
