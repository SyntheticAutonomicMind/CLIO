# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Coordination::SubAgent;

use strict;
use warnings;
use utf8;
use CLIO::Coordination::Broker;
use CLIO::Coordination::Client;
use CLIO::Core::Logger qw(log_debug log_warning);
use POSIX qw(setsid WNOHANG);
use File::Spec;
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


=head2 log_path_for($agent_id)

Return the log file path for a given agent ID. Centralized so all
callers (SubAgent, UI commands, SubAgentOperations) use the same
path regardless of platform.

=cut

sub log_path_for {
    my ($class, $agent_id) = @_;
    my $tmpdir = $^O eq 'MSWin32' ? ($ENV{TEMP} || $ENV{TMP} || 'C:\\Temp') : '/tmp';
    return File::Spec->catfile($tmpdir, "clio-agent-$agent_id.log");
}

=head2 report_path_for($agent_id)

Return the path of the agent's final report file. The report holds the
agent's complete final answer on its own, separate from the human-facing
log which interleaves tool output. The manager pulls it on demand via
the agent_operations 'report' operation.

=cut

sub report_path_for {
    my ($class, $agent_id) = @_;
    my $tmpdir = $^O eq 'MSWin32' ? ($ENV{TEMP} || $ENV{TMP} || 'C:\\Temp') : '/tmp';
    return File::Spec->catfile($tmpdir, "clio-agent-$agent_id-report.txt");
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
            flock($fh, 2) or log_debug("SubAgent", "Cannot lock counter: $!");  # LOCK_EX
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
            flock($fh, 2) or log_debug("SubAgent", "Cannot lock counter: $!");  # LOCK_EX
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
        ($options{model_candidates} ? (model_candidates => $options{model_candidates}) : ()),
        (defined $options{route_name} ? (route_name => $options{route_name}) : ()),
        (defined $options{route_active_role} ? (route_active_role => $options{route_active_role}) : ()),
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
    my $log_path = __PACKAGE__->log_path_for($agent_id);
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
    
    # Set sub-agent environment
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
    
    # Create Config and Session (same as main CLIO initialization)
    # NOTE: $debug must be declared before Client creation so it can be
    # used to configure the broker client's debug flag.
    my $debug = $options{debug} || 0;
    
    # Create broker client
    my $client = CLIO::Coordination::Client->new(
        session_id => $self->{session_id},
        agent_id => $agent_id,
        task => $task,
        debug => $debug,
    );

    # Give the child a host protocol wired to the broker.
    #
    # HostProtocol::set_broker_relay forwards status and tool events to
    # the broker as status_update and activity messages, which the parent
    # session renders as live agent cards. The relay existed but was never
    # connected, so no status or activity events were ever produced and
    # the parent had no way to see what a child was doing.
    #
    # The child writes to a log file rather than a terminal, so clear any
    # inherited OSC host flag: OSC escape sequences in a log file are
    # noise, and the broker relay is the channel that matters here.
    delete $ENV{CLIO_HOST_PROTOCOL};
    require CLIO::UI::HostProtocol;
    my $host_proto = CLIO::UI::HostProtocol->new(debug => $debug);
    $host_proto->set_broker_relay($client);
    log_debug('SubAgent', "Agent $agent_id: host protocol relay enabled");
    
    # Create Config and Session (same as main CLIO initialization)
    my $config = CLIO::Core::Config->new();
    my $model = $options{model} || croak "No model specified for sub-agent";
    
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
    
    # Propagate model routing configuration from the parent session.
    # Without this, the sub-agent gets a fresh Config with empty candidates,
    # so cycle_model() in APIManager has nothing to cycle through.
    if ($options{model_candidates} && ref($options{model_candidates}) eq 'ARRAY' && @{$options{model_candidates}}) {
        $config->set_model_candidates($options{model_candidates});
        $config->set_model_routing_index($options{model_routing_index} // 0);
        log_debug('SubAgent', "Propagated " . scalar(@{$options{model_candidates}}) . " routing candidates (index=" . ($options{model_routing_index} // 0) . ")");
    }
    if (defined $options{route_name}) {
        $config->set('route_name', $options{route_name}, 0);
    }
    # Propagate the active role so the sub-agent inherits the parent's
    # role-aware routing context. This is transient (not persisted).
    if (defined $options{route_active_role}) {
        $config->set('route_active_role', $options{route_active_role}, 0)
            if $config->can('set_route_active_role');
    }
    
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

        # Relay tool activity to the parent so the user can see what this
        # agent is doing while it works.
        my $on_tool_call = sub {
            my ($tool_name) = @_;
            return unless defined $tool_name;
            $host_proto->emit_status('tools');
            $host_proto->emit_tool_start($tool_name);
        };
        my $on_tool_end = sub {
            my ($tool_name) = @_;
            return unless defined $tool_name;
            $host_proto->emit_tool_end($tool_name);
        };

        # Call AI to process task using SimpleAIAgent (same as main CLIO)
        my $result = $ai_agent->process_user_request($task_content, {
            on_chunk => sub {
                my ($chunk) = @_;
                print $chunk if defined $chunk;
            },
            on_tool_call => $on_tool_call,
            on_tool_end => $on_tool_end,
        });
        
        if ($result->{success}) {
            print "[AgentLoop] Task completed successfully\n";

            my $report = $self->_extract_report($result);

            # Persist the report on its own so the manager can pull the
            # full text on demand without parsing the interleaved log.
            $self->_write_report($agent_id, $report);

            return {
                completed => 1,
                message => $self->_build_completion_message($report, $task_content),
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
        debug => $debug,
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

=head2 _extract_report($result)

Pull the agent's final answer out of a SimpleAIAgent result.

SimpleAIAgent stores the assistant's final text in 'final_response', with
'ai_response' holding the same value. It never populates 'content'.
Reading 'content' here always yielded undef, so the manager received a
restated copy of the task instead of the agent's findings.

Arguments:
- $result: The SimpleAIAgent result hashref

Returns: The report text, or an empty string.

=cut

sub _extract_report {
    my ($self, $result) = @_;

    return '' unless $result && ref($result) eq 'HASH';

    my $report = $result->{final_response};
    $report = $result->{ai_response}
        if (!defined $report || $report eq '');
    return '' unless defined $report;

    return $report;
}

=head2 _build_completion_message($report, $task_content)

Build the message the agent sends when it completes.

Arguments:
- $report: The agent's final answer
- $task_content: The task the agent was given, used as a fallback

Returns: The report, or a restatement of the task when there is no
report.

=cut

sub _build_completion_message {
    my ($self, $report, $task_content) = @_;

    return $report if defined $report && $report ne '';
    return "Completed: $task_content";
}

=head2 _write_report($agent_id, $report)

Persist the agent's final report to its own file. Runs in the child
process after stdout has been redirected to the agent log.

Arguments:
- $agent_id: The agent identifier
- $report: The full final answer text

Returns: 1 on success, 0 on failure.

=cut

sub _write_report {
    my ($self, $agent_id, $report) = @_;

    my $path = __PACKAGE__->report_path_for($agent_id);
    eval {
        open(my $fh, '>:encoding(UTF-8)', $path)
            or die "Cannot open report file $path: $!";
        print $fh $report;
        close $fh;
        1;
    };
    if ($@) {
        log_debug('SubAgent', "Agent $agent_id: cannot write report: $@");
        return 0;
    }

    log_debug('SubAgent', "Agent $agent_id: report written to $path");
    return 1;
}

=head2 list_agents()

Returns hash of all active agents.

=cut

sub list_agents {
    my ($self) = @_;

    # Check which agents are still running.
    #
    # Use waitpid(WNOHANG) rather than kill(0, $pid). A child that has
    # exited but has not been reaped is a zombie, and a zombie still
    # answers kill(0) successfully, so the old check reported every
    # finished agent as 'running' and no exit event was ever raised.
    # waitpid both detects the exit and reaps the child.
    for my $agent_id (keys %{$self->{agents}}) {
        my $agent = $self->{agents}{$agent_id};
        next unless $agent->{status} eq 'running';

        my $reaped = waitpid($agent->{pid}, WNOHANG);
        if ($reaped == $agent->{pid}) {
            # Child exited and has now been reaped. $? holds its status.
            $agent->{exit_code} = $?;
            $self->_mark_agent_exited($agent);
        }
        elsif ($reaped == -1) {
            # No such child (already reaped elsewhere, or never existed).
            $self->_mark_agent_exited($agent);
        }
    }

    return $self->{agents};
}

=head2 _mark_agent_exited($agent)

Transition an agent's status to its terminal state. Oneshot agents exit
when their task completes; persistent agents exiting is unexpected and
is recorded as 'stopped'.

Arguments:
- $agent: The agent record hashref

Returns: Nothing.

=cut

sub _mark_agent_exited {
    my ($self, $agent) = @_;

    if ($agent->{mode} eq 'oneshot') {
        $agent->{status} = 'exited';
    }
    else {
        $agent->{status} = 'stopped';
    }
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
    
    # Reap the child process to prevent zombies. Use WNOHANG to avoid
    # blocking if the process hasn't exited yet (it may need time to
    # clean up after SIGTERM).
    my $kid = waitpid($agent->{pid}, 1);  # WNOHANG
    unless ($kid == -1) {
        # Process reaped, or still running (WNOHANG returns 0 for still-running)
        $agent->{status} = 'completed' if $kid > 0;
    }
    
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
        elsif ($agent->{status} eq 'killed') {
            # Reap killed agents that haven't been waited on yet
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
