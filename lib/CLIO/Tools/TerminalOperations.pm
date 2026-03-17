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
use CLIO::Core::Logger qw(log_debug log_info log_warning);

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
    my $timeout = $params->{timeout} || 30;
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
    
    # Try multiplexer path first, fall back to direct TTY handoff
    my $mux = $self->_get_multiplexer($context);
    
    eval {
        my $original_cwd = getcwd();
        chdir $working_dir if $working_dir ne '.';
        
        my $start_time = Time::HiRes::time();

        if ($passthrough) {
            $result = $self->_execute_passthrough($command, $timeout, $display_cmd, $working_dir, $session);
        } elsif ($mux && $mux->available()) {
            $result = $self->_execute_in_mux_pane($command, $timeout, $display_cmd, $mux, $working_dir);
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

=head2 _execute_in_mux_pane

Execute a command in a multiplexer pane. The command runs in a new pane
where the user can see and interact with it. Output is captured via a
log file for the agent.

=cut

sub _execute_in_mux_pane {
    my ($self, $command, $timeout, $display_cmd, $mux, $working_dir) = @_;
    
    my $log_file = "/tmp/clio_terminal_$$.log";
    unlink $log_file if -f $log_file;
    
    # Build the command to run in the pane:
    # 1. cd to working directory
    # 2. Run command, capturing output via script
    # 3. Touch a done marker when complete
    my $done_marker = "/tmp/clio_terminal_done_$$";
    unlink $done_marker if -f $done_marker;
    
    # Wrap with working directory, output capture, and done marker
    # No script/pty - just subshell with redirect
    my $pane_cmd = "cd " . _shell_escape($working_dir) . " && "
                 . "($command) > " . _shell_escape($log_file) . " 2>&1"
                 . "; echo \$? > " . _shell_escape($done_marker);
    
    log_debug('TerminalOps', "Multiplexer execution: $pane_cmd");
    
    my $pane_id = $mux->create_pane(
        name    => "cmd-$$",
        command => $pane_cmd,
        size    => 40,
    );
    
    unless ($pane_id) {
        # Mux pane creation failed, fall back to direct TTY
        log_warning('TerminalOps', "Multiplexer pane creation failed, falling back to TTY handoff");
        return $self->_execute_captured($command, $timeout, $display_cmd, $working_dir);
    }
    
    # Wait for command to complete (poll for done marker)
    my $exit_code = $self->_wait_for_pane_completion($done_marker, $timeout, $mux, $pane_id);
    
    # Read captured output
    my $output = $self->_read_and_cleanup_log($log_file);
    unlink $done_marker if -f $done_marker;
    
    # Clean up the pane
    eval { $mux->kill_pane($pane_id) };
    
    return $self->success_result(
        $output,
        pre_action_description => $display_cmd,
        exit_code => $exit_code,
        command => $command,
        timeout => $timeout,
        passthrough => 1,
    );
}

=head2 _execute_captured

Execute a command in a subshell with output captured to a file.
No pty, no script command, no TTY handoff. Safe for all non-interactive
commands (grep, cat, ls, perl, git, etc).

=cut

sub _execute_captured {
    my ($self, $command, $timeout, $display_cmd, $working_dir, $session) = @_;
    
    my $log_file = "/tmp/clio_terminal_$$.log";
    unlink $log_file if -f $log_file;
    
    my $exit_code;
    my $interrupted = 0;
    
    # Use fork+waitpid instead of system() so we can:
    # 1. Poll for user interrupts during command execution
    # 2. Kill children cleanly on timeout or interrupt
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
        
        # Wait for child with timeout, polling for completion and interrupts
        my $start = Time::HiRes::time();
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
                kill('TERM', -$pid);  # Kill entire process group (POSIX: negative PID = group)
                # Give it a moment to clean up
                my $wait_start = Time::HiRes::time();
                while (Time::HiRes::time() - $wait_start < 2) {
                    last if waitpid($pid, POSIX::WNOHANG()) > 0;
                    Time::HiRes::usleep(50_000);
                }
                # Force kill if still alive
                if (waitpid($pid, POSIX::WNOHANG()) <= 0) {
                    kill('KILL', -$pid);  # Force kill entire process group
                    waitpid($pid, 0);
                }
                $exit_code = 130;  # Standard exit code for interrupt
                last;
            }
            
            if (Time::HiRes::time() - $start > $timeout) {
                $timed_out = 1;
                log_warning('TerminalOps', "Command timeout after ${timeout}s, killing child process group $pid");
                kill('TERM', -$pid);  # Kill entire process group (POSIX: negative PID = group)
                my $wait_start = Time::HiRes::time();
                while (Time::HiRes::time() - $wait_start < 2) {
                    last if waitpid($pid, POSIX::WNOHANG()) > 0;
                    Time::HiRes::usleep(50_000);
                }
                if (waitpid($pid, POSIX::WNOHANG()) <= 0) {
                    kill('KILL', -$pid);  # Force kill entire process group
                    waitpid($pid, 0);
                }
                last;
            }
            
            # Brief sleep to avoid busy-waiting (100ms)
            # ALRM may interrupt this sleep - that's fine
            Time::HiRes::usleep(100_000);
        }
        
        if ($timed_out) {
            die "Command timeout after ${timeout}s\n";
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
    
    # Read captured output
    my $output = $self->_read_and_cleanup_log($log_file);
    
    return $self->success_result(
        $output,
        pre_action_description => $display_cmd,
        exit_code => $exit_code,
        command => $command,
        timeout => $timeout,
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
    
    my $log_file = "/tmp/clio_terminal_$$.log";
    unlink $log_file if -f $log_file;
    
    # Suspend CLIO's terminal input handling so the command owns the TTY
    $self->_suspend_clio_input();
    
    # Save caller's ALRM handler and remaining alarm time
    my $saved_alrm = $SIG{ALRM};
    my $saved_alarm_remaining = alarm(0);
    
    my $exit_code;
    my $child_pid;
    
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
        
        # Wait for child with timeout
        local $SIG{ALRM} = sub { die "Command timeout after ${timeout}s\n" };
        alarm($timeout);
        
        waitpid($child_pid, 0);
        $exit_code = $? >> 8;
        
        alarm(0);
    };
    
    my $err = $@;
    
    # On timeout, kill the entire process group
    if ($err && $err =~ /timeout/ && $child_pid && $child_pid > 0) {
        log_warning('TerminalOps', "Passthrough command timeout, killing process group $child_pid");
        kill('TERM', -$child_pid);  # POSIX portable: negative PID = process group
        my $wait_start = Time::HiRes::time();
        while (Time::HiRes::time() - $wait_start < 2) {
            last if waitpid($child_pid, POSIX::WNOHANG()) > 0;
            Time::HiRes::usleep(50_000);
        }
        if (waitpid($child_pid, POSIX::WNOHANG()) <= 0) {
            kill('KILL', -$child_pid);  # Force kill
            waitpid($child_pid, 0);
        }
    }
    
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

=head2 _wait_for_pane_completion

Wait for a multiplexer pane command to complete by polling for a done marker file.

=cut

sub _wait_for_pane_completion {
    my ($self, $done_marker, $timeout, $mux, $pane_id) = @_;
    
    my $start = time();
    my $exit_code = -1;
    
    while (time() - $start < $timeout) {
        if (-f $done_marker) {
            # Read exit code from marker
            if (open my $fh, '<', $done_marker) {
                my $code = <$fh>;
                close $fh;
                chomp $code if defined $code;
                $exit_code = ($code =~ /^\d+$/) ? int($code) : -1;
            }
            last;
        }
        
        # Check if the pane still exists (command may have been killed)
        if ($mux->{driver} && $mux->{driver}->can('pane_exists')) {
            unless ($mux->{driver}->pane_exists($pane_id)) {
                log_debug('TerminalOps', "Multiplexer pane disappeared, command may have completed");
                # Give a moment for the done marker to be written
                select(undef, undef, undef, 0.5);
                if (-f $done_marker) {
                    if (open my $fh, '<', $done_marker) {
                        my $code = <$fh>;
                        close $fh;
                        chomp $code if defined $code;
                        $exit_code = ($code =~ /^\d+$/) ? int($code) : -1;
                    }
                }
                last;
            }
        }
        
        select(undef, undef, undef, 0.5);  # Poll every 500ms
    }
    
    if ($exit_code == -1 && time() - $start >= $timeout) {
        log_warning('TerminalOps', "Command timed out after ${timeout}s");
        $exit_code = 124;
    }
    
    return $exit_code;
}

=head2 _get_multiplexer

Get or create a Multiplexer instance from context.

=cut

sub _get_multiplexer {
    my ($self, $context) = @_;
    
    # Check if multiplexer is available in context
    if ($context && $context->{multiplexer}) {
        return $context->{multiplexer};
    }
    
    # Try to detect and create one
    my $mux;
    eval {
        require CLIO::UI::Multiplexer;
        $mux = CLIO::UI::Multiplexer->new();
    };
    if ($@) {
        log_debug('TerminalOps', "Could not load Multiplexer: $@");
        return undef;
    }
    
    return ($mux && $mux->available()) ? $mux : undef;
}

sub validate_command {
    my ($self, $params, $context) = @_;
    
    my $command = $params->{command};
    
    return $self->error_result("Missing 'command' parameter") unless $command;
    
    # Extract the actual command being executed (before pipes, redirects, or &&)
    my $executable = $command;
    
    # For git commands, only check the git subcommand, not arguments
    if ($command =~ /^\s*(?:git\s+(\w+)|(.+?))\s/) {
        my $git_cmd = $1;
        if ($git_cmd) {
            $executable = "git $git_cmd";
        }
    }
    
    # Check for dangerous patterns only in the actual executable part
    my @dangerous = ('rm -rf', 'sudo rm', 'shutdown', 'reboot', 'halt', 'dd if=', 'mkfs');
    
    foreach my $pattern (@dangerous) {
        if ($executable =~ /\Q$pattern\E/i) {
            return $self->error_result("Dangerous command pattern detected: $pattern");
        }
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
        command => $command,
        safe => 1,
    );
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
            description => "Timeout in seconds (default: 30)",
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
    $output = Encode::decode('UTF-8', $output, Encode::FB_DEFAULT);
    
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
