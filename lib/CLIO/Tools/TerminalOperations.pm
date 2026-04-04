# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Tools::TerminalOperations;

use strict;
use warnings;
use utf8;
use parent 'CLIO::Tools::Tool';
use Cwd 'getcwd';
use feature 'say';
use POSIX qw(WNOHANG);
use Time::HiRes ();
use CLIO::Core::Logger qw(log_debug log_info log_warning log_error);
use CLIO::Security::CommandAnalyzer qw(analyze_command);

=head1 NAME

CLIO::Tools::TerminalOperations - Shell/terminal command execution

=head1 DESCRIPTION

Provides safe terminal command execution with timeout and validation.
Commands run in captured mode by default (output redirected to file,
no pty created). When passthrough mode is requested, the user gets
interactive TTY access with output captured via tee. Multiplexer panes
are used when available for isolated execution.

=cut

sub new {
    my ($class, %opts) = @_;
    
    return $class->SUPER::new(
        name => 'terminal_operations',
        description => q{Execute shell commands safely with validation and timeout.

Operations:
-  exec - Run command and capture output
-  execute - Alias for 'exec'
-  validate - Check command safety before execution
},
# Timeout is an idle timeout: if the command produces no output for
# $timeout seconds it is killed. Active commands that keep writing
# output will not be killed until the hard ceiling (10min default).
        supported_operations => [qw(exec execute validate)],
        %opts,
    );
}

=head2 get_tool_definition

Override to mark command parameter as required for exec/execute operations.

Returns: Hashref with complete tool definition

=cut

sub get_tool_definition {
    my ($self) = @_;
    
    my $def = $self->SUPER::get_tool_definition();
    
    # Mark command as required for exec and execute operations
    $def->{parameters}{required} = ["operation"];
    
    # Add conditional requirement: command is required for exec/execute
    $def->{parameters}{description} = 
        "For exec/execute: 'command' parameter is required. " .
        "For validate: 'command' parameter is required.";
    
    return $def;
}

sub route_operation {
    my ($self, $operation, $params, $context) = @_;
    
    if ($operation eq 'execute' || $operation eq 'exec') {
        return $self->execute_command($params, $context);
    } elsif ($operation eq 'validate') {
        return $self->validate_command($params, $context);
    }
    
    return $self->error_result("Operation not implemented: $operation");
}

sub execute_command {
    my ($self, $params, $context) = @_;
    
    # Validate params
    unless ($params && ref($params) eq 'HASH') {
        return $self->error_result("Invalid parameters: expected hash reference");
    }
    
    my $command = $params->{command};
    my $timeout = $params->{timeout} || 60;
    my $passthrough = $params->{passthrough} || 0;
    
    # Get working directory from params first, then from session context, then default to '.'
    my $working_dir = $params->{working_directory};
    if (!$working_dir && $context && $context->{session} && $context->{session}->{state}) {
        $working_dir = $context->{session}->{state}->{working_directory};
    }
    $working_dir ||= '.';
    
    my $result;
    
    unless (defined $command && length($command) > 0) {
        return $self->error_result("Missing or empty 'command' parameter");
    }
    
    # Validate command first
    my $validation = $self->validate_command({ command => $command }, $context);
    unless ($validation->{success}) {
        return $validation;
    }
    
    # Display the command BEFORE execution so user can see what's about to run
    my $display_cmd = length($command) > 120
        ? substr($command, 0, 117) . "..."
        : $command;
    
    # Pre-execution display handled via pre_action_description
    # The WorkflowOrchestrator will display this before execution
    
    # Extract session for interrupt checking during execution
    my $session;
    if ($context && $context->{session}) {
        $session = $context->{session};
    } elsif ($context && $context->{ui} && $context->{ui}->{session}) {
        $session = $context->{ui}->{session};
    }
    
    eval {
        my $original_cwd = getcwd();
        chdir $working_dir if $working_dir ne '.';
        
        my $start_time = Time::HiRes::time();

        if ($passthrough) {
            $result = $self->_execute_passthrough($command, $timeout, $display_cmd, $working_dir, $session);
        } else {
            $result = $self->_execute_captured($command, $timeout, $display_cmd, $working_dir, $session);
        }
        
        # Append [exit:N | Xms] footer to output so agent develops cost intuition
        if ($result && $result->{success} && defined $result->{exit_code}) {
            my $elapsed_ms = int((Time::HiRes::time() - $start_time) * 1000);
            my $duration_str = $elapsed_ms >= 1000
                ? sprintf("%.1fs", $elapsed_ms / 1000)
                : "${elapsed_ms}ms";
            my $footer = "\n[exit:$result->{exit_code} | $duration_str]";
            if (ref($result->{output}) eq 'HASH') {
                $result->{output}{text} = ($result->{output}{text} // '') . $footer;
            } else {
                $result->{output} = ($result->{output} // '') . $footer;
            }
        }

        chdir $original_cwd if $working_dir ne '.';
    };
    
    if ($@) {
        return $self->error_result("Command execution failed: $@");
    }
    
    return $result;
}

=head2 _execute_captured

Execute a command in a subshell with output captured to a file.
No pty, no script command, no TTY handoff. Safe for all non-interactive
commands (grep, cat, ls, perl, git, etc).

=cut

sub _execute_captured {
    my ($self, $command, $timeout, $display_cmd, $working_dir, $session) = @_;
    
    my $log_file;
    if ($^O eq 'MSWin32') {
        my $tmp = $ENV{TEMP} || $ENV{TMP} || 'C:\\Temp';
        $log_file = "$tmp\\clio_terminal_$$.log";
    } else {
        $log_file = "/tmp/clio_terminal_$$.log";
    }
    unlink $log_file if -f $log_file;
    
    my $exit_code;
    my $interrupted = 0;
    my $hard_ceiling = $ENV{CLIO_TERMINAL_MAX_TIMEOUT} || 600;
    
    if ($^O eq 'MSWin32') {
        # Windows: no fork/exec, use system() with output redirect
        my $escaped_log = $log_file;
        $escaped_log =~ s/"/\\"/g;
        my $cmd = qq{cmd.exe /C "$command" > "$escaped_log" 2>&1};
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm($timeout) if $timeout;
            $exit_code = system($cmd);
            alarm(0);
            $exit_code = $exit_code >> 8 if defined $exit_code;
        };
        if ($@) {
            if ($@ =~ /alarm/) {
                $exit_code = 124;
            } else {
                log_warning('TerminalOps', "Command execution error: $@");
                $exit_code = 1 unless defined $exit_code;
            }
        }
    } else {
    # Unix: Use fork+waitpid instead of system() so we can:
    # 1. Poll for user interrupts during command execution
    # 2. Kill children cleanly on timeout or interrupt
    # 3. Extend timeout when command is actively producing output
    # We intentionally do NOT touch $SIG{ALRM} or alarm() here - Chat.pm's
    # 1-second ALRM handler must keep firing for interrupt detection.
    eval {
        my $pid = fork();
        if (!defined $pid) {
            die "Fork failed: $!\n";
        }
        
        if ($pid == 0) {
            # Child: create new process group so we can kill the entire tree
            POSIX::setpgid(0, 0);
            my $escaped_log = _shell_escape($log_file);
            exec("/bin/sh", "-c", "($command) > $escaped_log 2>&1")
                or POSIX::_exit(127);  # exec failed
        }
        
        # Parent: set child's process group (race-safe with child's setpgid)
        eval { POSIX::setpgid($pid, $pid) };
        
        # Wait for child with timeout, polling for completion and interrupts.
        # Activity-based timeout: if the command is producing output, the idle
        # timer resets. The command is only killed when it has been silent for
        # $timeout seconds, OR when the hard ceiling is reached.
        my $start = Time::HiRes::time();
        my $last_activity = $start;
        my $last_output_size = 0;
        my $timed_out = 0;
        
        while (1) {
            my $waited = waitpid($pid, POSIX::WNOHANG());
            if ($waited > 0) {
                $exit_code = $? >> 8;
                last;
            }
            
            # Check for user interrupt (set by Chat.pm ALRM handler)
            if ($session && $session->state() && $session->state()->{user_interrupted}) {
                log_info('TerminalOps', "User interrupt during command execution, killing child process group $pid");
                $interrupted = 1;
                $self->_kill_process_group($pid);
                $exit_code = 130;
                last;
            }
            
            # Check for output activity - reset idle timer if command is producing output
            my $current_size = -s $log_file || 0;
            if ($current_size > $last_output_size) {
                $last_activity = Time::HiRes::time();
                $last_output_size = $current_size;
            }
            
            my $now = Time::HiRes::time();
            my $idle_seconds = $now - $last_activity;
            my $wall_seconds = $now - $start;
            
            # Hard ceiling: absolute wall-clock limit regardless of activity
            if ($wall_seconds > $hard_ceiling) {
                $timed_out = 1;
                log_warning('TerminalOps', "Command hit hard ceiling after ${hard_ceiling}s, killing process group $pid");
                $self->_kill_process_group($pid);
                last;
            }
            
            # Idle timeout: no output for $timeout seconds
            if ($idle_seconds > $timeout) {
                $timed_out = 1;
                my $total = int($wall_seconds);
                log_warning('TerminalOps', "Command idle for ${timeout}s (${total}s total), killing process group $pid");
                $self->_kill_process_group($pid);
                last;
            }
            
            # Brief sleep to avoid busy-waiting (100ms)
            # ALRM may interrupt this sleep - that's fine
            Time::HiRes::usleep(100_000);
        }
        
        if ($timed_out) {
            die "Command timeout after ${timeout}s idle\n";
        }
    };
    
    if ($@) {
        if ($@ =~ /timeout/) {
            $exit_code = 124;
        } else {
            # Fork or other unexpected failure - log and set error exit code
            log_warning('TerminalOps', "Command execution error: $@");
            $exit_code = 1 unless defined $exit_code;
        }
    }
    } # end Unix fork path
    
    # Read captured output
    my $output = $self->_read_and_cleanup_log($log_file);
    
    # Build expanded_content for inline display (show output under the command)
    my @expanded;
    if (defined $output && length($output)) {
        my @lines = split /\n/, $output;
        # Show up to 15 lines of output; truncate if longer
        my $max_preview = 15;
        for my $j (0 .. ($#lines < $max_preview - 1 ? $#lines : $max_preview - 1)) {
            push @expanded, $lines[$j];
        }
        if (@lines > $max_preview) {
            push @expanded, "... (" . scalar(@lines) . " lines total)";
        }
    }
    
    return $self->success_result(
        $output,
        pre_action_description => $display_cmd,
        exit_code => $exit_code,
        command => $command,
        timeout => $timeout,
        expanded_content => (@expanded ? \@expanded : undef),
    );
}

=head2 _execute_passthrough

Execute a command with interactive TTY access. The user can interact with
the command (signing, prompts, etc). Output is captured via tee so the
agent can still see results. Falls back to plain system() if tee would
interfere with the command.

=cut

sub _execute_passthrough {
    my ($self, $command, $timeout, $display_cmd, $working_dir, $session) = @_;
    
    my $log_file;
    if ($^O eq 'MSWin32') {
        my $tmp = $ENV{TEMP} || $ENV{TMP} || 'C:\\Temp';
        $log_file = "$tmp\\clio_terminal_pt_$$.log";
    } else {
        $log_file = "/tmp/clio_terminal_$$.log";
    }
    unlink $log_file if -f $log_file;
    
    # Suspend CLIO's terminal input handling so the command owns the TTY
    $self->_suspend_clio_input();
    
    # Save caller's ALRM handler and remaining alarm time, then disable.
    # We use a poll loop instead of alarm() for timeout - no ALRM needed.
    my $saved_alrm = $SIG{ALRM};
    my $saved_alarm_remaining = alarm(0);
    
    my $exit_code;
    my $child_pid;
    my $interrupted = 0;
    my $hard_ceiling = $ENV{CLIO_TERMINAL_MAX_TIMEOUT} || 600;
    
    if ($^O eq 'MSWin32') {
        # Windows: no fork/exec, use system() with output redirect
        my $escaped_log = $log_file;
        $escaped_log =~ s/"/\\"/g;
        my $cmd = qq{cmd.exe /C "$command" > "$escaped_log" 2>&1};
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm($timeout) if $timeout;
            $exit_code = system($cmd);
            alarm(0);
            $exit_code = $exit_code >> 8 if defined $exit_code;
        };
        if ($@) {
            if ($@ =~ /alarm/) {
                $exit_code = 124;
            } else {
                log_warning('TerminalOps', "Command execution error: $@");
                $exit_code = 1 unless defined $exit_code;
            }
        }
    } else {
    eval {
        # Fork to get a child PID we can manage with process groups
        $child_pid = fork();
        if (!defined $child_pid) {
            die "Fork failed: $!\n";
        }
        
        if ($child_pid == 0) {
            # Child: create new process group for clean cleanup
            POSIX::setpgid(0, 0);
            # Exec the command with tee for output capture
            my $escaped_log = _shell_escape($log_file);
            exec("/bin/sh", "-c", "$command 2>&1 | tee $escaped_log")
                or POSIX::_exit(127);
        }
        
        # Parent: set child's process group (race-safe)
        eval { POSIX::setpgid($child_pid, $child_pid) };
        
        # Poll loop with activity-based timeout (matches captured mode pattern).
        # No alarm() or $SIG{ALRM} used - avoids the historical ALRM bugs.
        my $start = Time::HiRes::time();
        my $last_activity = $start;
        my $last_output_size = 0;
        my $timed_out = 0;
        
        while (1) {
            my $waited = waitpid($child_pid, POSIX::WNOHANG());
            if ($waited > 0) {
                $exit_code = $? >> 8;
                last;
            }
            
            # Check for user interrupt
            if ($session && $session->state() && $session->state()->{user_interrupted}) {
                log_info('TerminalOps', "User interrupt during passthrough, killing process group $child_pid");
                $interrupted = 1;
                $self->_kill_process_group($child_pid);
                $exit_code = 130;
                last;
            }
            
            # Check for output activity (tee writes to log file)
            my $current_size = -s $log_file || 0;
            if ($current_size > $last_output_size) {
                $last_activity = Time::HiRes::time();
                $last_output_size = $current_size;
            }
            
            my $now = Time::HiRes::time();
            my $idle_seconds = $now - $last_activity;
            my $wall_seconds = $now - $start;
            
            # Hard ceiling
            if ($wall_seconds > $hard_ceiling) {
                $timed_out = 1;
                log_warning('TerminalOps', "Passthrough hit hard ceiling after ${hard_ceiling}s, killing process group $child_pid");
                $self->_kill_process_group($child_pid);
                last;
            }
            
            # Idle timeout
            if ($idle_seconds > $timeout) {
                $timed_out = 1;
                my $total = int($wall_seconds);
                log_warning('TerminalOps', "Passthrough idle for ${timeout}s (${total}s total), killing process group $child_pid");
                $self->_kill_process_group($child_pid);
                last;
            }
            
            Time::HiRes::usleep(100_000);
        }
        
        if ($timed_out) {
            die "Command timeout after ${timeout}s idle\n";
        }
    };
    } # end Unix fork path
    
    my $err = $@;
    
    # Restore caller's ALRM handler and re-arm their alarm.
    # alarm(0) returns 0 both when no alarm was pending AND when <1 second
    # remained (integer floor). If a handler existed, always re-arm with at
    # least 1 second so the periodic timer doesn't go dead.
    $SIG{ALRM} = $saved_alrm || 'DEFAULT';
    if ($saved_alrm && ref($saved_alrm) eq 'CODE') {
        alarm($saved_alarm_remaining || 1);
    } elsif ($saved_alarm_remaining) {
        alarm($saved_alarm_remaining);
    }
    
    if ($err) {
        if ($err =~ /timeout/) {
            $exit_code = 124;
        }
        # Don't re-throw - still need to resume input
    }
    
    # Resume CLIO's terminal input handling
    $self->_resume_clio_input();
    
    # Read captured output
    my $output = $self->_read_and_cleanup_log($log_file);
    
    return $self->success_result(
        $output,
        pre_action_description => $display_cmd,
        exit_code => $exit_code,
        command => $command,
        timeout => $timeout,
        passthrough => 1,
    );
}

=head2 _kill_process_group

Send TERM to a process group, wait up to 2 seconds for graceful exit, then
KILL if still alive. Uses POSIX-portable negative-PID form for group kill.

=cut

sub _kill_process_group {
    my ($self, $pid) = @_;
    return unless $pid && $pid > 0;
    
    kill('TERM', -$pid);
    my $wait_start = Time::HiRes::time();
    while (Time::HiRes::time() - $wait_start < 2) {
        last if waitpid($pid, POSIX::WNOHANG()) > 0;
        Time::HiRes::usleep(50_000);
    }
    if (waitpid($pid, POSIX::WNOHANG()) <= 0) {
        kill('KILL', -$pid);
        waitpid($pid, 0);
    }
}

=head2 _suspend_clio_input

Suspend CLIO's ReadKey-based input handling so a child process can own the TTY.

=cut

sub _suspend_clio_input {
    my ($self) = @_;
    
    eval {
        require CLIO::Compat::Terminal;
        CLIO::Compat::Terminal::ReadMode(0, *STDIN);
    };
    if ($@) {
        log_debug('TerminalOps', "Could not suspend ReadMode: $@");
    }
}

=head2 _resume_clio_input

Resume CLIO's ReadKey-based input handling after a child process completes.
Restores terminal to pristine state first, which Chat.pm will then set
to cbreak mode for interrupt detection.

=cut

sub _resume_clio_input {
    my ($self) = @_;
    
    eval {
        require CLIO::Compat::Terminal;
        # Force full restoration to pristine state
        CLIO::Compat::Terminal::reset_terminal();
        # Re-enable cbreak mode so ReadKey(-1) in Chat.pm ALRM handler works
        # This is critical for interrupt detection (ESC key, Ctrl-C)
        CLIO::Compat::Terminal::ReadMode(1);
    };
    if ($@) {
        log_debug('TerminalOps', "Could not resume terminal: $@");
    }
}

sub validate_command {
    my ($self, $params, $context) = @_;

    my $command = $params->{command};

    return $self->error_result("Missing 'command' parameter") unless $command;

    # Get security settings from config
    my $config = ($context && $context->{config}) ? $context->{config} : undef;
    my $sandbox = ($config && $config->get('sandbox')) ? 1 : 0;
    my $security_level = ($config) ? ($config->get('security_level') || 'standard') : 'standard';

    # Run intent-based command analysis
    my $analysis = analyze_command($command,
        sandbox        => $sandbox,
        security_level => $security_level,
    );

    # Hard-blocked commands (critical risk - system destructive)
    if ($analysis->{blocked}) {
        my @descs = map { $_->{description} } @{$analysis->{flags}};
        my $reason = join('; ', @descs);
        log_warning('TermOps', "BLOCKED command: $reason");
        return $self->error_result(
            "Command blocked (critical risk): $reason\n\n" .
            "This command was classified as system-destructive and cannot be executed.\n" .
            "If you believe this is a false positive, the user can adjust the security level."
        );
    }

    # Commands requiring user confirmation
    if ($analysis->{requires_confirmation}) {
        my $approved = $self->_prompt_command_confirmation($command, $analysis, $context);
        unless ($approved) {
            log_info('TermOps', "User DENIED command: $analysis->{summary}");
            return $self->error_result(
                "Command denied by user.\n\n" .
                "Security analysis: $analysis->{summary}\n" .
                "The user chose not to allow this command. Try a different approach."
            );
        }
        log_info('TermOps', "User APPROVED command: $analysis->{summary}");
    }

    # Truncate command for display if very long
    my $display_cmd;
    if (length($command) > 60) {
        $display_cmd = substr($command, 0, 57) . '...';
    } else {
        $display_cmd = $command;
    }
    my $action_desc = "validating command '$display_cmd'";

    return $self->success_result(
        "Command validated",
        action_description => $action_desc,
        command   => $command,
        safe      => 1,
        analysis  => $analysis,
    );
}

=head2 _prompt_command_confirmation

Prompt the user to approve or deny a flagged command.

Displays the security analysis and asks the user to confirm.
Session-level grants are tracked so the user isn't re-prompted
for the same category of command within a session.

Returns: 1 if approved, 0 if denied

=cut

# Session-level grants: once user approves a category, don't re-ask
my %_session_grants;

sub _prompt_command_confirmation {
    my ($self, $command, $analysis, $context) = @_;

    # Check session-level grants first
    for my $flag (@{$analysis->{flags}}) {
        my $cat = $flag->{category};
        if ($_session_grants{$cat}) {
            log_debug('TermOps', "Session grant exists for category '$cat' - auto-approving");
            return 1;
        }
    }

    # We need the UI to prompt the user
    my $ui = ($context && $context->{ui}) ? $context->{ui} : undef;

    unless ($ui && $ui->can('colorize')) {
        # No UI available (non-interactive mode) - deny by default
        log_warning('TermOps', "No UI for security prompt - denying command");
        return 0;
    }

    # Stop spinner if active
    my $spinner = ($context && $context->{spinner}) ? $context->{spinner} : undef;
    $spinner->stop() if $spinner && $spinner->can('stop');

    # Build the confirmation display
    print "\n";
    print $ui->colorize("  SECURITY CHECK ", 'ERROR');
    print "\n\n";

    # Show the command (truncated if very long)
    my $display_cmd = $command;
    if (length($display_cmd) > 200) {
        $display_cmd = substr($display_cmd, 0, 197) . '...';
    }
    print $ui->colorize("  Command: ", 'BOLD');
    print "$display_cmd\n\n";

    # Show flags
    for my $flag (@{$analysis->{flags}}) {
        my $severity_color = 'WARNING';
        $severity_color = 'ERROR' if $flag->{severity} eq 'high' || $flag->{severity} eq 'critical';

        print $ui->colorize("  [$flag->{severity}] ", $severity_color);
        print "$flag->{description}\n";
        if ($flag->{details}) {
            print $ui->colorize("          ", 'DIM');
            print $ui->colorize("$flag->{details}\n", 'DIM');
        }
    }

    print "\n";
    print $ui->colorize("  Options: ", 'BOLD');
    print "(y)es once, (a)llow category for session, (n)o deny\n";

    # Suspend ALRM handler - Chat.pm's 1-second timer calls ReadKey(-1)
    # which consumes keystrokes before <STDIN> can read them
    my $saved_alrm = $SIG{ALRM};
    my $remaining_alarm = alarm(0);

    require CLIO::Compat::Terminal;

    # Flush any buffered ReadKey input from cbreak mode
    while (defined(eval { CLIO::Compat::Terminal::ReadKey(-1) })) { }

    CLIO::Compat::Terminal::ReadMode(0);  # Normal mode for input

    print $ui->colorize("  > ", 'PROMPT');

    my $response = <STDIN>;
    chomp($response) if defined $response;
    $response = lc($response || 'n');

    CLIO::Compat::Terminal::ReadMode(1);

    # Restore ALRM handler
    $SIG{ALRM} = $saved_alrm || 'DEFAULT';
    alarm($remaining_alarm) if $remaining_alarm;

    # Restart spinner
    $spinner->start() if $spinner && $spinner->can('start');

    if ($response eq 'y' || $response eq 'yes') {
        return 1;
    } elsif ($response eq 'a' || $response eq 'allow') {
        # Grant session-level permission for all flagged categories
        for my $flag (@{$analysis->{flags}}) {
            $_session_grants{$flag->{category}} = 1;
            log_info('TermOps', "Session grant added for category: $flag->{category}");
        }
        return 1;
    }

    return 0;
}

=head2 reset_session_grants

Reset all session-level command security grants.
Called when starting a new session.

=cut

sub reset_session_grants {
    %_session_grants = ();
}

=head2 get_additional_parameters

Define parameters specific to terminal_operations.

Returns: Hashref of parameter definitions

=cut

sub get_additional_parameters {
    my ($self) = @_;
    
    return {
        command => {
            type => "string",
            description => "Shell command to execute",
        },
        timeout => {
            type => "integer",
            description => "Idle timeout in seconds (default: 60). Command is killed only after this many seconds with no output. Active commands keep running.",
        },
        working_directory => {
            type => "string",
            description => "Working directory for command execution (default: '.')",
        },
        passthrough => {
            type => "boolean",
            description => "Force passthrough mode (direct terminal access, no output capture). Overrides config settings.",
        },
    };
}

=head2 _read_and_cleanup_log

Read output from the script log file, sanitize it, and clean up.

=cut

sub _read_and_cleanup_log {
    my ($self, $log_file) = @_;
    
    my $output = '';
    if (-f $log_file) {
        if (open my $fh, '<:raw', $log_file) {
            $output = do { local $/; <$fh> };
            close $fh;
        }
        unlink $log_file;
    }
    
    # Decode as UTF-8, replacing invalid bytes with U+FFFD
    # Terminal output may contain non-UTF-8 bytes (Latin-1, CP437, raw binary)
    require Encode;
    $output = Encode::decode('UTF-8', $output, Encode::FB_DEFAULT());
    
    $output = $self->_sanitize_terminal_output($output);
    
    # Strip replacement characters left from invalid byte sequences
    $output =~ s/\x{FFFD}//g;
    
    return $output;
}

=head2 _sanitize_terminal_output

Remove terminal control sequences from captured output.

=cut

sub _sanitize_terminal_output {
    my ($self, $output) = @_;
    
    # Remove ANSI escape sequences
    $output =~ s/\x1b\[[0-9;]*[a-zA-Z]//g;
    
    # Remove other common escape sequences
    $output =~ s/\x1b[(\)][AB012]//g;
    $output =~ s/\x1b\][0-9];[^\x07]*\x07//g;
    $output =~ s/\x1b[=>]//g;
    
    # Clean up line endings
    $output =~ s/\r+\n/\n/g;
    $output =~ s/\r(?!\n)//g;
    
    # Remove backspace characters
    while ($output =~ s/.\x08//g) {}
    
    # Remove BEL characters
    $output =~ s/\x07//g;
    
    return $output;
}

=head2 _shell_escape

Escape a string for safe use in a shell command.

=cut

sub _shell_escape {
    my ($str) = @_;
    $str =~ s/'/'\\''/g;
    return "'$str'";
}

=head2 _reset_terminal_state_light

Light terminal reset - just restore ReadMode.

=cut

sub _reset_terminal_state_light {
    my ($self) = @_;
    
    return unless -t STDIN;
    
    eval {
        require CLIO::Compat::Terminal;
        CLIO::Compat::Terminal::reset_terminal_light();
    };
    
    return 1;
}

=head2 _reset_terminal_state

Moderate terminal reset.

=cut

sub _reset_terminal_state {
    my ($self) = @_;
    
    return unless -t STDIN && -t STDOUT;
    
    eval {
        require CLIO::Compat::Terminal;
        CLIO::Compat::Terminal::reset_terminal();
    };
    
    return 1;
}

1;
