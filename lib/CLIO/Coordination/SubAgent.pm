# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Coordination::SubAgent;

use strict;
use warnings;
use utf8;
use CLIO::Coordination::Broker;
use CLIO::Coordination::Client;
use CLIO::Core::Logger qw(log_debug log_warning);
use POSIX qw(setsid);
use Carp qw(croak);

# Parse provider prefix from model name (e.g., "minimax/MiniMax-M3")
# Returns ($provider, $api_model) where $provider may be undef
sub _parse_model_provider {
    my ($model) = @_;
    
    if ($model && $model =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i) {
        my ($prefix, $rest) = ($1, $2);
        require CLIO::Providers;
        if (CLIO::Providers::provider_exists($prefix)) {
            return ($prefix, $rest);
        }
    }
    
    return (undef, $model);
}


=head1 NAME

CLIO::Coordination::SubAgent - Spawn and manage CLIO sub-agents

=head1 DESCRIPTION

Spawns independent CLIO processes that connect to the coordination broker
and work on specific tasks in parallel with the main agent and each other.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $session_id = $args{session_id};
    croak "session_id required" unless $session_id;
    
    # Determine temporary directory (use /dev/shm on Linux, /tmp on macOS)
    my $temp_dir = '/dev/shm';
    $temp_dir = '/tmp' if ($^O eq 'darwin' || !-d '/dev/shm');
    
    # Load or initialize agent counter (persists for session only)
    my $counter_file = "$temp_dir/clio-subagent-counter-$session_id.txt";
    my $next_id = 1;
    
    # Read with locking to prevent race conditions
    if (-f $counter_file) {
        if (open(my $fh, '+<', $counter_file)) {
            flock($fh, 2) or log_warning("SubAgent", "Cannot lock counter: $!");  # LOCK_EX
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
            flock($fh, 2) or log_warning("SubAgent", "Cannot lock counter: $!");  # LOCK_EX
            print $fh $self->{next_agent_id};
            close $fh;  # Releases lock
        }
    }
    
    my $working_dir = $options{working_dir};
    
    my $pid = fork();
    croak "Fork failed: $!" unless defined $pid;
    
    if ($pid == 0) {
        # Child process - chdir to working_dir if specified (puppeteer mode)
        if ($working_dir) {
            chdir($working_dir) or die "Cannot chdir to $working_dir: $!";
            log_debug('SubAgent', "Agent $agent_id: chdir to $working_dir");
        }
        
        # Become sub-agent
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
        ($working_dir ? (working_dir => $working_dir) : ()),
    };
    
    return $agent_id;
}

=head2 run_subagent($agent_id, $task, %options)

Runs in the child process. Connects to broker and executes task.

=cut

sub run_subagent {
    my ($self, $agent_id, $task, %options) = @_;
    
    # Reset terminal state first, while still connected to parent TTY
    # This must happen BEFORE closing STDIN or detaching from terminal
    # The child inherits the parent's terminal settings, which can corrupt the parent's terminal
    # Use light reset - no ANSI codes needed since we're about to redirect output
    eval {
        require CLIO::Compat::Terminal;
        CLIO::Compat::Terminal::reset_terminal_light();  # ReadMode(0) only
    };
    
    # Close inherited file descriptors
    # This prevents the child from interfering with parent's terminal I/O
    close(STDIN) or warn "Cannot close STDIN: $!";
    
    # Detach from parent terminal session
    setsid() or die "Cannot start new session: $!";
    
    # Redirect ALL I/O to log file (completely detach from parent terminal)
    my $tmpdir = $^O eq 'MSWin32' ? ($ENV{TEMP} || $ENV{TMP} || 'C:\\Temp') : '/tmp';
    my $log_path = File::Spec->catfile($tmpdir, "clio-agent-$agent_id.log");
    my $nulldev = $^O eq 'MSWin32' ? 'nul' : '/dev/null';
    open(STDIN, '<', $nulldev) or die "Cannot redirect STDIN: $!";
    open(STDOUT, '>>', $log_path) or die "Cannot open log: $!";
    open(STDERR, '>&STDOUT') or die "Cannot redirect STDERR: $!";
    
    print "=== Sub-agent $agent_id starting ===\n";
    print "Task: $task\n";
    print "Session: $self->{session_id}\n";
    
    # Set puppeteer environment variables if working_dir was specified
    if ($options{working_dir}) {
        $ENV{CLIO_PUPPETEER} = 1;
        # Extract project name from working_dir (last path component)
        my $project = $options{working_dir};
        $project =~ s{[/\\]+$}{};  # Strip trailing slashes
        $project =~ s{.*/}{};       # Get last path component
        $ENV{CLIO_PUPPETEER_PROJECT} = $project;
        print "Puppeteer mode: project=$project dir=$options{working_dir}\n";
    }
    
    # Check if persistent mode requested
    if ($options{persistent}) {
        $self->run_persistent_agent($agent_id, $task, %options);
    } else {
        $self->run_oneshot_agent($agent_id, $task, %options);
    }
}

sub run_oneshot_agent {
    my ($self, $agent_id, $task, %options) = @_;
    
    # Oneshot agents use the same robust AgentLoop as persistent agents.
    # The only difference: oneshot=1 causes the loop to exit after the
    # first task completes and the completion message is delivered.
    $self->_run_agent_loop($agent_id, $task, oneshot => 1, %options);
}

sub run_persistent_agent {
    my ($self, $agent_id, $task, %options) = @_;
    
    $self->_run_agent_loop($agent_id, $task, oneshot => 0, %options);
}

sub _run_agent_loop {
    my ($self, $agent_id, $task, %options) = @_;
    
    my $oneshot = delete $options{oneshot} // 0;
    my $mode = $oneshot ? 'ONESHOT' : 'PERSISTENT';
    
    print "Mode: $mode\n";
    print "Starting agent loop\n\n";
    
    # Set sub-agent environment (previously only set by the exec path)
    $ENV{CLIO_BROKER_SESSION} = $self->{session_id};
    $ENV{CLIO_BROKER_AGENT_ID} = $agent_id;
    $ENV{IS_SUBAGENT} = 1;
    
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
    
    # Create Config and Session (same as main CLIO initialization)
    my $config = CLIO::Core::Config->new();
    my $model = $options{model} || croak "No model specified for sub-agent";
    my $debug = $options{debug} || 0;
    
    # Configure the sub-agent's model and provider on the Config object.
    # Without this, get_current_model() reads the main session's model from
    # Config, causing all sub-agents to use the parent's model regardless of
    # what was specified at spawn time.
    my ($model_provider, $model_name) = _parse_model_provider($model);
    if ($model_provider) {
        # Model has explicit provider prefix (e.g., "minimax/MiniMax-M3")
        # Use set_provider to properly configure api_base, api_key, and model
        $config->set_provider($model_provider);
        $config->set('model', $model, 1);  # Set full model with prefix
    } else {
        # No provider prefix - just set the model on the existing provider
        $config->set('model', $model, 1);
    }
    
    log_debug('SubAgent', "Agent $agent_id configured: model=$model provider=" . ($model_provider // $config->get('provider')));
    
    # Create a session for this agent (required for API tracking, history, etc.)
    my $session = CLIO::Session::Manager->create(
        debug => $debug,
    );

    # Set LTM corroboration identity for this sub-agent. add_corroboration()
    # in CLIO::Memory::LongTerm reads $ENV{CLIO_AGENT_ID} /
    # $ENV{CLIO_SESSION_ID} to build the source key used for sybil-resistant
    # dedup. Without this, every sub-agent corroboration would collapse to
    # "unknown:unknown" and the parent + sub-agents could never jointly
    # promote an entry to [TRUSTED]. The agent_id from the broker gives
    # each sub-agent a distinct identity from the parent "main" process.
    $ENV{CLIO_AGENT_ID}   = $agent_id;
    $ENV{CLIO_SESSION_ID} = $session->{session_id};
    log_debug('SubAgent', "LTM identity: CLIO_AGENT_ID=$ENV{CLIO_AGENT_ID} CLIO_SESSION_ID=$ENV{CLIO_SESSION_ID}");

    # Resolve pre-loaded skills into rendered content blocks.
    # Each is appended to the subagent's system prompt at session start.
    my @preloaded_skill_blocks;
    if ($options{preloaded_skills} && @{$options{preloaded_skills}}) {
        require CLIO::Core::SkillManager;
        my $sm = CLIO::Core::SkillManager->new(debug => $debug);
        for my $name (@{$options{preloaded_skills}}) {
            my $content = $sm->render_skill_content($name);
            if (length $content) {
                push @preloaded_skill_blocks, {
                    name => $name,
                    content => $content,
                };
            }
            else {
                print "[SubAgent] WARNING: requested skill '$name' not found, skipping\n";
            }
        }
    }

    # Pass pre-loaded skills to SimpleAIAgent via env var (per-skill)
    # so the prompt builder can pick them up when constructing the
    # subagent's system prompt. SimpleAIAgent reads CLIO_PRELOADED_SKILLS
    # as a JSON array of {name, content} blocks.
    if (@preloaded_skill_blocks) {
        require CLIO::Util::JSON;
        $ENV{CLIO_PRELOADED_SKILLS} = CLIO::Util::JSON::encode_json(\@preloaded_skill_blocks);
        print "[SubAgent] Pre-loaded " . scalar(@preloaded_skill_blocks) . " skill(s) into system prompt\n";
    }

    # Create APIManager with proper configuration and session
    my $api_manager = CLIO::Core::APIManager->new(
        config => $config,
        model => $model,
        session => $session->state(),  # Pass session state for thread tracking
        broker_client => $client,      # Pass broker client for API rate limiting coordination
        debug => $debug,
    );
    
    # Create SimpleAIAgent for AI interactions (same as main CLIO)
    my $ai_agent = CLIO::Core::SimpleAIAgent->new(
        api => $api_manager,  # APIManager instance required
        session => $session,   # Session for history tracking
        debug => $debug,
        broker_client => $client,  # Pass broker client for coordination
        non_interactive => 1,      # Sub-agents are always non-interactive
    );
    
    # Custom instructions (including sub-agent mode) are automatically loaded
    # via PromptManager based on IS_SUBAGENT env var
    
    # Define task handler callback
    my $task_handler = sub {
        my ($task_content, $loop) = @_;
        
        print "[AgentLoop] Processing task: $task_content\n";
        
        # Call AI to process task using SimpleAIAgent (same as main CLIO)
        my $result = $ai_agent->process_user_request($task_content, {
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
    
    # Create and run agent loop (oneshot exits after first task, persistent loops)
    my $loop = CLIO::Core::AgentLoop->new(
        client => $client,
        initial_task => $task,
        on_task => $task_handler,
        oneshot => $oneshot,
        debug => 1,
    );
    
    eval {
        $loop->run();
    };
    if ($@) {
        print "Agent loop error: $@\n";
        croak $@;
    }
    
    print "Agent loop exited ($mode)\n";
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

1;
