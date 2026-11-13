# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Tools::TerminalOperations;

use strict;
use warnings;
use Carp qw(croak);
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use parent 'CLIO::Tools::Tool';
use CLIO::Util::ShellSyntax qw(check_shell_syntax);
use Cwd 'getcwd';
use POSIX qw(WNOHANG dup2);
use File::Temp ();
use Time::HiRes ();
use CLIO::Core::Logger qw(log_debug log_warning log_error);
use CLIO::Security::CommandAnalyzer qw(analyze_command extract_write_targets);

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

Operations (REQUIRED 'operation' parameter; 'command' parameter required for both):
-  exec - Run command and capture output. Returns {output, exit_code, action_description}.
-  validate - Check command safety before execution.

Behavior: Commands run in captured mode by default (output to file, no pty).
Use passthrough=true for interactive TTY access. Multiplexer panes used when available.
Timeout is idle: command killed after N seconds with no output. Default idle timeout is 300s (5min). Active commands run until hard ceiling (10min).

Feeding input: prefer the 'stdin' parameter over writing a heredoc. It carries no
terminator line, needs no quoting, and is the reliable way to pass multi-line
content to a program.

Pre-flight: every command is parsed with 'sh -n' before running. If the shell
cannot parse it, the call is rejected with the syntax error and a hint, and
nothing executes.

QUICK EXAMPLE:
{"operation": "exec", "command": "ls -la"}
},
# Timeout is an idle timeout: if the command produces no output for
# $timeout seconds it is killed. Active commands that keep writing
# output will not be killed until the hard ceiling (10min default).
# Default 300s (5min) aligns with other CLIO tools (Interact, RemoteExecution)
# and prevents premature kills of long-running commands that are silently
# working (model loading, large compiles, DB queries, etc.).
        supported_operations => [qw(exec validate)],
        operation_aliases => [qw(run execute shell check)],
        %opts,
    );
}

=head2 before_route

Block all terminal operations in sandbox mode. The CommandAnalyzer denylist
is defense-in-depth only — it cannot reliably classify all commands (full
paths, encoding, interpreter exfiltration, etc.). In sandbox mode, no shell
command should execute.

=cut

sub before_route {
    my ($self, $operation, $params, $context) = @_;

    if ($context && $context->{config} && $context->{config}->get('sandbox')) {
        log_debug('TerminalOps', "Sandbox: BLOCKED terminal_operations.$operation");
        return $self->error_result(
            "Sandbox mode: Terminal operations are disabled.\n\n" .
            "The --sandbox flag blocks all command execution to prevent arbitrary shell access. " .
            "This is a security feature — there is no safe subset of shell commands to allow in sandboxed mode."
        );
    }

    return undef;
}

=head2 get_tool_definition

Override to mark command parameter as required for exec/execute operations.
Override to mark command parameter as required for exec operations.

Returns: Hashref with complete tool definition

=cut

sub get_tool_definition {
    my ($self) = @_;

    my $def = $self->SUPER::get_tool_definition();

    # Mark 'command' as required for exec/validate. The base class only
    # marks 'operation' as required; we add 'command' here so the schema
    # is accurate and the pre-validate hook in Tool.pm can catch missing
    # commands before the handler runs.
    $def->{parameters}{required} = ["operation", "command"];

    # Description makes the requirement explicit so the model knows from
    # the schema (not just from runtime errors) that command is required.
    $def->{parameters}{description} =
        "For exec: 'command' parameter is required. " .
        "For validate: 'command' parameter is required.";

    return $def;
}

sub dispatch_table {
    return {
        exec     => 'execute_command',
        run      => 'execute_command',
        execute  => 'execute_command',
        shell    => 'execute_command',
        validate => 'validate_command',
        check    => 'validate_command',
    };
}

sub get_additional_parameters {
    my ($self) = @_;
    return {
        command => {
            type => "string",
            description => "[REQUIRED for both exec and validate] Shell command string. Example: 'ls -la' or 'git status'.",
        },
        timeout => {
            type => "integer",
            description => "[OPTIONAL] Idle timeout in seconds. Command killed after N seconds with no output. Default: 300 (5min). Active commands run until hard ceiling of 600s.",
        },
        passthrough => {
            type => "boolean",
            description => "[OPTIONAL] Use interactive TTY mode instead of captured output. Default: false. Use only when the command needs user interaction (signing, prompts).",
        },
        working_directory => {
            type => "string",
            description => "[OPTIONAL] Working directory for command. Defaults to current session working directory or '.'.",
        },
        stdin => {
            type => "string",
            description => "[OPTIONAL] Text to feed to the command's standard input. Use this instead of writing a heredoc: no terminator line, no quoting, and no literal newlines needed inside the command string. Example: command 'tr a-z A-Z' with stdin 'hello'.",
        },
    };
}

sub execute_command {
    my ($self, $params, $context) = @_;
    
    # Validate params
    unless ($params && ref($params) eq 'HASH') {
        return $self->error_result("Invalid parameters: expected hash reference");
    }
    
    my $command = $params->{command};
    # Default idle timeout is 300s (5min). Aligned with other CLIO tools
    # (Interact, RemoteExecution) and the 600s hard ceiling. 60s was too
    # short for commands that are silently working (model loading, large
    # compiles, DB queries) - the activity-based timeout resets on stdout
    # but not on silent CPU work.
    my $timeout = $params->{timeout} || 300;
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
    
    # Stage the stdin payload as a file so the child can read it from a real
    # descriptor. This is what removes the agent's need to build a heredoc,
    # the most common source of malformed multi-line commands.
    my $stdin_file;
    if (defined $params->{stdin} && length $params->{stdin}) {
        my ($path, $err) = _write_stdin_file($params->{stdin});
        return $self->error_result("Cannot stage stdin content: $err") if $err;
        $stdin_file = $path;
    }

    my $original_cwd = getcwd();
    my $changed_dir = ($working_dir ne '.');
    chdir $working_dir if $changed_dir;
    
    eval {
        my $start_time = Time::HiRes::time();

        if ($passthrough) {
            $result = $self->_execute_passthrough($command, $timeout, $display_cmd, $working_dir, $session, $stdin_file);
        } else {
            $result = $self->_execute_captured($command, $timeout, $display_cmd, $working_dir, $session, $stdin_file);
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
    };
    
    chdir $original_cwd if $changed_dir;
    unlink $stdin_file if $stdin_file && -f $stdin_file;

    if ($@) {
        return $self->error_result("Command execution failed: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

=head2 _execute_captured

Execute a command in a subshell with output captured to a file.
No pty, no script command, no TTY handoff. Safe for all non-interactive
commands (grep, cat, ls, perl, git, etc).

=cut

sub _find_windows_bash {
    for my $dir (split /;/, $ENV{PATH} || '') {
        my $bash = "$dir\\bash.exe";
        return $bash if -x $bash;
    }
    return undef;
}

=head2 _windows_exec_string (Internal)

Build the command line passed to system() on Windows.

The log redirect sits outside the quoted command string, so unlike the Unix
captured path it never touches the command's own final line.

Arguments: $command, $log_file, $stdin_file (optional)
Returns: command line string

=cut

sub _windows_exec_string {
    my ($command, $log_file, $stdin_file) = @_;

    my $escaped_log = $log_file;
    $escaped_log =~ s/"/\\"/g;

    my $stdin_redir = '';
    if ($stdin_file) {
        my $escaped_stdin = $stdin_file;
        $escaped_stdin =~ s/"/\\"/g;
        $stdin_redir = qq{ < "$escaped_stdin"};
    }

    my $bash = _find_windows_bash();
    if ($bash) {
        # Use bash -c for POSIX command support
        my $escaped_command = $command;
        $escaped_command =~ s/'/'\\''/g;
        return qq{"$bash" -c '$escaped_command'$stdin_redir > "$escaped_log" 2>&1};
    }

    return qq{cmd.exe /C "$command"$stdin_redir > "$escaped_log" 2>&1};
}

# Private per-process directory for command capture files. Created on first
# use; see _capture_dir.
my $CAPTURE_DIR;

=head2 _capture_dir (Internal)

Private directory holding this process's command capture files. Do not call
directly; this is internal to the execution paths.

Created once per process with mode 0700 and removed at exit. Capture files must
not sit directly in a world-writable /tmp under a name derived from the PID:
any process able to guess the path can pre-create it, swap it, or delete it
while a command is still running.

Returns: Absolute path to the directory.

=cut

sub _capture_dir {
    my ($self) = @_;

    return $CAPTURE_DIR if defined $CAPTURE_DIR && -d $CAPTURE_DIR;

    my $dir = File::Temp::tempdir('clio-term-XXXXXXXX', TMPDIR => 1, CLEANUP => 1);
    chmod 0700, $dir;
    $CAPTURE_DIR = $dir;
    return $CAPTURE_DIR;
}

=head2 _new_capture_file($kind) (Internal)

Allocate a capture file unique to one command execution. Do not call directly;
this is internal to the execution paths.

Previously every execution in a process shared one path,
C</tmp/clio_terminal_$$.log>. C<$$> is constant for the process and identical
across threads, so concurrent executions - the orchestrator classifies tool
calls as parallel and runs them together - unlinked each other's file
mid-flight. The victim kept writing to the detached inode while its parent read
an empty or absent file and reported success with no output at all.

Arguments:
- $kind: Prefix naming the execution mode ('out' captured, 'pt' passthrough) so the two never share a name.

Returns: Absolute path to a new empty file.

=cut

sub _new_capture_file {
    my ($self, $kind) = @_;

    my ($fh, $path) = File::Temp::tempfile("${kind}-XXXXXXXX",
                                           DIR => _capture_dir(), UNLINK => 0);
    # Bind and close. Discarding a File::Temp handle into undef leaves its
    # descriptor open.
    close $fh;
    return $path;
}

sub _execute_captured {
    my ($self, $command, $timeout, $display_cmd, $working_dir, $session, $stdin_file) = @_;
    
    my $log_file = $self->_new_capture_file('out');
    
    my $exit_code;
    my $interrupted = 0;
    my $hard_ceiling = $ENV{CLIO_TERMINAL_MAX_TIMEOUT} || 600;
    
    if ($^O eq 'MSWin32') {
        # Windows: prefer bash (Git for Windows) for POSIX compatibility,
        # fall back to cmd.exe
        my $cmd = _windows_exec_string($command, $log_file, $stdin_file);
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
                log_debug('TerminalOps', "Command execution error: $@");
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
            croak "Fork failed: $!\n";
        }
        
        if ($pid == 0) {
            # Child: create new process group so we can kill the entire tree
            POSIX::setpgid(0, 0);
            # Detach from parent's STDIN to prevent child from competing
            # for terminal input (causes hangs when child also reads TTY)
            if ($stdin_file) {
                open(STDIN, '<', $stdin_file) or POSIX::_exit(126);
            } else {
                open(STDIN, '<', '/dev/null') or POSIX::_exit(126);
            }

            # Attach the log with dup2 instead of wrapping the command in a
            # shell redirect. The previous form was "($command) > $log 2>&1",
            # which appends ") > $log 2>&1" to whatever the command's final
            # line happens to be. That silently corrupts any command ending in
            # a heredoc terminator, because the terminator is no longer alone
            # on its line and the heredoc runs to end of input, and any command
            # ending in a comment, because the redirect falls inside the
            # comment. Both failed with a shell syntax error the agent could
            # not attribute to anything, and the log file was never created, so
            # the agent received no output at all. Redirecting the descriptors
            # here leaves the command byte-for-byte as written.
            open(my $logfh, '>', $log_file) or POSIX::_exit(126);
            POSIX::dup2(fileno($logfh), 1) or POSIX::_exit(126);
            POSIX::dup2(fileno($logfh), 2) or POSIX::_exit(126);
            close $logfh if fileno($logfh) > 2;

            exec("/bin/sh", "-c", $command)
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
            
            # Compute current idle/wall time FIRST so it's available for all
            # diagnostic logging in this iteration (interrupt, hard ceiling, idle).
            my $now = Time::HiRes::time();
            my $idle_seconds = $now - $last_activity;
            my $wall_seconds = $now - $start;

            # Check for user interrupt (set by Chat.pm ALRM handler via Interrupt module).
            # Use Interrupt::pending() so we catch both the session-state flag and
            # the package-level global flag (the latter is set by the ALRM handler
            # and is visible to code paths that do not have a session reference).
            if ($session && $session->can('state') && $session->state()->{user_interrupted}) {
                log_debug('TerminalOps', "User interrupt detected (ESC/Ctrl-C), killing child process group $pid (wall=" . sprintf('%.1fs', $wall_seconds) . " idle=" . sprintf('%.1fs', $idle_seconds) . ")");
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
            
            # Hard ceiling: absolute wall-clock limit regardless of activity
            if ($wall_seconds > $hard_ceiling) {
                log_debug('TerminalOps', "Hard ceiling reached: wall=" . sprintf('%.1fs', $wall_seconds) . " > $hard_ceiling, killing child process group $pid (idle=" . sprintf('%.1fs', $idle_seconds) . ")");
                $timed_out = 1;
                log_debug('TerminalOps', "Command hit hard ceiling after ${hard_ceiling}s, killing process group $pid");
                $self->_kill_process_group($pid);
                last;
            }
            
            # Idle timeout: no output for $timeout seconds
            if ($idle_seconds > $timeout) {
                log_debug('TerminalOps', "Idle timeout reached: idle=" . sprintf('%.1fs', $idle_seconds) . " > $timeout (wall=" . sprintf('%.1fs', $wall_seconds) . "), killing child process group $pid");
                $timed_out = 1;
                my $total = int($wall_seconds);
                log_debug('TerminalOps', "Command idle for ${timeout}s (${total}s total), killing process group $pid");
                $self->_kill_process_group($pid);
                last;
            }
            
            # Brief sleep to avoid busy-waiting (100ms)
            # ALRM may interrupt this sleep - that's fine
            Time::HiRes::usleep(100_000);
        }
        
        if ($timed_out) {
            croak "Command timeout after ${timeout}s idle\n";
        }
    };
    
    if ($@) {
        if ($@ =~ /timeout/) {
            $exit_code = 124;
        } else {
            # Fork or other unexpected failure - log and set error exit code
            log_debug('TerminalOps', "Command execution error: $@");
            $exit_code = 1 unless defined $exit_code;
        }
    }
    } # end Unix fork path
    
    # Read captured output. The size is taken first so a lost capture file can
    # be told apart from a command that genuinely printed nothing.
    my $captured_bytes = -s $log_file || 0;
    my $output = $self->_read_and_cleanup_log($log_file);
    if (!length($output)) {
        log_debug('TerminalOps', "No output captured: bytes_at_read=$captured_bytes"
            . " exit=" . (defined $exit_code ? $exit_code : 'undef')
            . ($captured_bytes > 0 ? " (data present but decoded empty)" : ""));
    }
    
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
    my ($self, $command, $timeout, $display_cmd, $working_dir, $session, $stdin_file) = @_;
    
    # 'pt' keeps passthrough capture distinct from captured-mode capture; the
    # Unix branch previously reused the captured-mode name exactly.
    my $log_file = $self->_new_capture_file('pt');
    
    # Suspend CLIO's terminal input handling so the command owns the TTY
    $self->_suspend_clio_input();

    # On Unix we INTENTIONALLY do NOT touch $SIG{ALRM} or alarm().
    # Chat.pm installs a 1-second ALRM handler that scans stdin for
    # ESC and sets session->state()->{user_interrupted}, which the
    # poll loop below checks. The Unix path also uses Time::HiRes
    # polling for the timeout, so it doesn't need a local alarm().
    # The Windows path below DOES need its own alarm() because fork()
    # is unavailable and we fall back to system(); the local SIG{ALRM}
    # is scoped to the eval block, so Chat.pm's handler is still
    # preserved on Windows outside that eval.
    my $saved_alrm;
    my $saved_alarm_remaining;
    if ($^O eq 'MSWin32') {
        $saved_alrm = $SIG{ALRM};
        $saved_alarm_remaining = alarm(0);
    }

    my $exit_code;
    my $child_pid;
    my $interrupted = 0;
    my $hard_ceiling = $ENV{CLIO_TERMINAL_MAX_TIMEOUT} || 600;
    
    if ($^O eq 'MSWin32') {
        # Windows: prefer bash (Git for Windows) for POSIX compatibility,
        # fall back to cmd.exe
        my $cmd = _windows_exec_string($command, $log_file, $stdin_file);
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
                log_debug('TerminalOps', "Command execution error: $@");
                $exit_code = 1 unless defined $exit_code;
            }
        }
    } else {
    eval {
        # Fork to get a child PID we can manage with process groups
        $child_pid = fork();
        if (!defined $child_pid) {
            croak "Fork failed: $!\n";
        }
        
        if ($child_pid == 0) {
            # Child: create new process group for clean cleanup
            POSIX::setpgid(0, 0);
            if ($stdin_file) {
                open(STDIN, '<', $stdin_file) or POSIX::_exit(126);
            }
            # Exec the command with tee for output capture.
            #
            # The command is grouped with { } and the closing brace is placed
            # on its own line. Appending " 2>&1 | tee $log" directly to the
            # command glued it onto the command's last line, which broke
            # heredocs (the terminator is no longer alone, so the text
            # "EOF 2>&1 | tee /tmp/..." got fed to the child program as input)
            # and trailing comments (the pipeline was commented out, so nothing
            # reached the log). A newline before the brace keeps both intact.
            my $wrapped = _passthrough_wrap($command, $log_file);
            exec("/bin/sh", "-c", $wrapped)
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
            
            # Compute current idle/wall time FIRST so it's available for all
            # diagnostic logging in this iteration.
            my $now = Time::HiRes::time();
            my $idle_seconds = $now - $last_activity;
            my $wall_seconds = $now - $start;

            # Check for user interrupt
            if ($session && $session->can('state') && $session->state()->{user_interrupted}) {
                log_debug('TerminalOps', "User interrupt detected (ESC/Ctrl-C), killing passthrough process group $child_pid (wall=" . sprintf('%.1fs', $wall_seconds) . " idle=" . sprintf('%.1fs', $idle_seconds) . ")");
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
            
            # Hard ceiling
            if ($wall_seconds > $hard_ceiling) {
                log_debug('TerminalOps', "Hard ceiling reached in passthrough: wall=" . sprintf('%.1fs', $wall_seconds) . " > $hard_ceiling, killing process group $child_pid (idle=" . sprintf('%.1fs', $idle_seconds) . ")");
                $timed_out = 1;
                log_debug('TerminalOps', "Passthrough hit hard ceiling after ${hard_ceiling}s, killing process group $child_pid");
                $self->_kill_process_group($child_pid);
                last;
            }
            
            # Idle timeout
            if ($idle_seconds > $timeout) {
                log_debug('TerminalOps', "Idle timeout reached in passthrough: idle=" . sprintf('%.1fs', $idle_seconds) . " > $timeout (wall=" . sprintf('%.1fs', $wall_seconds) . "), killing process group $child_pid");
                $timed_out = 1;
                my $total = int($wall_seconds);
                log_debug('TerminalOps', "Passthrough idle for ${timeout}s (${total}s total), killing process group $child_pid");
                $self->_kill_process_group($child_pid);
                last;
            }
            
            Time::HiRes::usleep(100_000);
        }
        
        if ($timed_out) {
            croak "Command timeout after ${timeout}s idle\n";
        }
    };
    } # end Unix fork path
    
    my $err = $@;

    # Restore caller's ALRM handler (only needed on Windows where we saved it).
    # On Unix we left Chat.pm's ALRM handler untouched, so nothing to restore.
    if ($^O eq 'MSWin32') {
        # alarm(0) returns 0 both when no alarm was pending AND when <1 second
        # remained (integer floor). If a handler existed, always re-arm with at
        # least 1 second so the periodic timer doesn't go dead.
        $SIG{ALRM} = $saved_alrm || 'DEFAULT';
        if ($saved_alrm && ref($saved_alrm) eq 'CODE') {
            alarm($saved_alarm_remaining || 1);
        } elsif ($saved_alarm_remaining) {
            alarm($saved_alarm_remaining);
        }
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
Reaps all child processes to prevent zombies.

Safety: before issuing the kill, verifies the child's PGID is actually the
child's PID. If the child's setpgid(0, 0) failed at fork time, the child
would be in CLIO's PGID (or worse, CLIO's shell's PGID), and a kill
targeting PGID=$pid would either be a no-op or - far worse - hit CLIO
itself. Same defensive pattern as CLIO::Compat::Terminal::kill_stale_children.

Note: POSIX::getpgid is not exported on macOS Perl, so we resolve the PGID
via ps. Falls back to BAILING OUT (refusing to kill) if the lookup fails -
safer than firing SIGKILL at the wrong group.

=cut

sub _get_pid_pgid {
    my ($pid) = @_;
    return undef unless $pid && $pid =~ /^\d+$/;

    # Prefer POSIX::getpgid on systems where it works (Linux). Falls back to
    # ps on macOS / older Perls where the function isn't exported.
    my $pgid = eval { POSIX::getpgid($pid) };
    return $pgid if defined $pgid;

    my $ps = `ps -o pid,pgid -p $pid 2>/dev/null`;
    if ($ps =~ /^\s*\d+\s+(\d+)/m) {
        return $1;
    }
    return undef;
}

sub _kill_process_group {
    my ($self, $pid) = @_;
    return unless $pid && $pid > 0;

    log_debug('TerminalOps', "_kill_process_group entered: pid=$pid my_pid=$$ my_pgid=" . (_get_pid_pgid($$) // 'unknown'));

    # Safety check: verify the child's PGID is the child's PID before
    # targeting that process group with SIGKILL. If the child's setpgid(0, 0)
    # silently failed at fork, the child is in CLIO's PGID (or the shell's),
    # and killing PGID=$pid would either miss the child entirely or, in
    # pathological cases, fan out to CLIO/peers. The same pattern is used in
    # CLIO::Compat::Terminal::kill_stale_children.
    my $child_pgid = _get_pid_pgid($pid);
    if (!defined $child_pgid || $child_pgid != $pid) {
        log_debug('TerminalOps', "Refusing to kill PID $pid: its PGID is " . ($child_pgid // 'unknown') . ", not its own PID. Child setpgid likely failed at fork; would risk killing CLIO or its peers.");
        return;
    }

    my $term_sent = kill('TERM', -$pid);
    log_debug('TerminalOps', "Sent SIGTERM to PGID=$pid (kill returned: " . ($term_sent ? scalar($term_sent) : '0') . " targets)");
    my $wait_start = Time::HiRes::time();
    my $term_grace = 0;
    while (Time::HiRes::time() - $wait_start < 2) {
        my $w = waitpid($pid, POSIX::WNOHANG());
        if ($w > 0) {
            $term_grace = Time::HiRes::time() - $wait_start;
            last;
        }
        if ($w < 0) {
            log_debug('TerminalOps', "waitpid($pid, WNOHANG) returned -1 during TERM grace: errno=$!");
        }
        Time::HiRes::usleep(50_000);
    }
    my $final_w = waitpid($pid, POSIX::WNOHANG());
    if ($final_w <= 0) {
        log_debug('TerminalOps', "PID $pid did not exit within 2s of SIGTERM, escalating to SIGKILL");
        my $kill_sent = kill('KILL', -$pid);
        log_debug('TerminalOps', "Sent SIGKILL to PGID=$pid (kill returned: " . ($kill_sent ? scalar($kill_sent) : '0') . " targets)");
        my $reaped = waitpid($pid, 0);
        log_debug('TerminalOps', "Blocking waitpid($pid) returned: " . ($reaped // 'undef') . " status=" . (($reaped && $reaped > 0) ? ($? >> 8) : 'n/a'));
    } else {
        log_debug('TerminalOps', "PID $pid exited cleanly after SIGTERM within " . sprintf('%.2fs', $term_grace));
    }

    # Reap any remaining children in the process group to prevent zombies
    # Use non-blocking waitpid in a loop
    my $reaped_count = 0;
    while (waitpid(-1, POSIX::WNOHANG()) > 0) {
        $reaped_count++;
    }
    if ($reaped_count > 0) {
        log_debug('TerminalOps', "Reaped $reaped_count remaining child(ren) via waitpid(-1) to prevent zombies");
    }
    log_debug('TerminalOps', "_kill_process_group complete for pid=$pid");
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

=head2 _enforce_write_paths

Check the filesystem destinations a shell command names against path
authorization.

Returns: an error result when a write target is refused, undef when every
recognized destination is allowed.

=cut

sub _enforce_write_paths {
    my ($self, $command, $context) = @_;

    my $targets = extract_write_targets($command);
    return undef unless @$targets;

    require CLIO::Security::PathAuthorizer;
    $self->{path_authorizer} ||= CLIO::Security::PathAuthorizer->new(debug => $self->{debug});
    my $authorizer = $self->{path_authorizer};

    my $session    = ($context && $context->{session}) ? $context->{session} : {};
    my $session_id = $session->{session_id} || $session->{id} || '';

    for my $target (@$targets) {
        my $result = $authorizer->authorize_or_prompt(
            path              => $target,
            working_directory => $self->{session_dir},
            conversation_id   => $session_id,
            operation         => 'terminal_operations.write',
            is_user_initiated => 0,
            prompt            => sub {
                my %details = @_;
                return CLIO::Security::PathAuthorizer::prompt_for_path_authorization(
                    %details,
                    ui            => $context->{ui},
                    broker_client => $context->{broker_client},
                    spinner       => $context->{spinner},
                );
            },
        );

        next if $result->{status} eq 'allowed';

        my $reason = $result->{reason} || 'path is outside the session directory';
        log_debug('TermOps', "DENIED command write target '$target': $reason");
        return $self->error_result(
            "Command denied: it writes to '$target', outside the session directory.\n\n" .
            "Reason: $reason\n" .
            "Run the command with a destination inside the session directory."
        );
    }

    return undef;
}

sub validate_command {
    my ($self, $params, $context) = @_;

    my $command = $params->{command};

 return $self->error_result("Missing required parameter: command") unless $command;

    # Parse the command with the same shell that would run it, before anything
    # else happens. A command the shell cannot parse would fail on execution
    # anyway, so checking here costs a few milliseconds, produces a much better
    # diagnostic than the shell's raw message, runs no side effects, and keeps
    # the user from being prompted to approve a command that could never have
    # worked.
    if (my $syntax = check_shell_syntax($command)) {
        log_debug('TermOps', "Rejecting command with invalid shell syntax: $syntax->{error}");
        my $msg = "Command rejected: the shell could not parse it. Nothing was executed.\n\n"
                . "Syntax error: $syntax->{error}";
        $msg .= "\n\nHint: $syntax->{hint}" if $syntax->{hint};
        return $self->error_result($msg);
    }

    # Get security settings from config
    my $config = ($context && $context->{config}) ? $context->{config} : undef;
    my $sandbox = ($config && $config->get('sandbox')) ? 1 : 0;
    my $security_level = ($config) ? ($config->get('security_level') || 'standard') : 'standard';

    # Run intent-based command analysis
    my $analysis = analyze_command($command,
        sandbox        => $sandbox,
        security_level => $security_level,
    );

    # Path containment for shell writes, at the level whose contract is to be
    # tight. file_operations and apply_patch enforce the session directory, but
    # an arbitrary command could route around them ("echo x > /etc/y"), so the
    # file guard alone did not bound where a command could write. The extractor
    # reads only the command's surface syntax and cannot see a path a script
    # builds internally, so this narrows the gap rather than closing it.
    if ($security_level eq 'strict' && $self->{session_dir}) {
        my $path_denial = $self->_enforce_write_paths($command, $context);
        return $path_denial if $path_denial;
    }

    # Dry-run safety: when the command is critical-risk AND we don't have a real
    # interactive TTY (no -t STDIN), deny it without prompting. The prompt path
    # is only safe when a human is actually at the terminal to read the warning
    # and choose yes/no/allow. In --input mode, captured/cron-like contexts, or
    # any other non-interactive invocation, the prompt could auto-resolve to 'y'
    # from stale session grants or piped input - which is exactly the security
    # hole this guard closes.
    if ($analysis->{blocked} && !-t STDIN) {
        my @descs = map { $_->{description} } @{$analysis->{flags}};
        my $reason = join('; ', @descs);
        log_debug('TermOps', "DENIED critical command in non-interactive context: $reason");
        return $self->error_result(
            "Command denied (critical risk, non-interactive context).\n\n" .
            "Security analysis: $reason\n" .
            "Critical commands require an interactive TTY for explicit user approval. " .
            "Run this command directly in your shell, or use a non-destructive alternative."
        );
    }

    # Hard-blocked commands (critical risk - system destructive)
    # Still prompt the user - they always have final say
    if ($analysis->{blocked}) {
        my @descs = map { $_->{description} } @{$analysis->{flags}};
        my $reason = join('; ', @descs);
        log_debug('TermOps', "CRITICAL risk command: $reason");

        # Route through user confirmation with critical risk context
        my $approved = $self->_prompt_command_confirmation($command, $analysis, $context);
        unless ($approved) {
            log_debug('TermOps', "User DENIED critical command: $analysis->{summary}");
            return $self->error_result(
                "Command denied by user (critical risk).\n\n" .
                "Security analysis: $reason\n" .
                "The user chose not to allow this command. Try a different approach."
            );
        }
        log_debug('TermOps', "User APPROVED critical command: $analysis->{summary}");
    }

    # Commands requiring user confirmation
    if ($analysis->{requires_confirmation}) {
        my $approved = $self->_prompt_command_confirmation($command, $analysis, $context);
        unless ($approved) {
            log_debug('TermOps', "User DENIED command: $analysis->{summary}");
            return $self->error_result(
                "Command denied by user.\n\n" .
                "Security analysis: $analysis->{summary}\n" .
                "The user chose not to allow this command. Try a different approach."
            );
        }
        log_debug('TermOps', "User APPROVED command: $analysis->{summary}");
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
        approved_by => $self->_decision_source($analysis, $context),
    );
}

# Session-level grants: once user approves a category, don't re-ask.
# Declared before any sub that references it so both _decision_source and
# _prompt_command_confirmation see the same hash.
my %_session_grants;

=head2 _decision_source

Internal: report WHY a command was approved (interactive prompt, session grant,
no flags) so callers can audit the decision path. Returns a short string.

=cut

sub _decision_source {
    my ($self, $analysis, $context) = @_;

    return 'no_flags' if !@{$analysis->{flags} || []};
    # Was a session grant responsible?
    for my $flag (@{$analysis->{flags}}) {
        if ($_session_grants{$flag->{category}}) {
            return 'session_grant:' . $flag->{category};
        }
    }

    return 'auto';
}

=head2 _prompt_command_confirmation

Prompt the user to approve or deny a flagged command.

Displays the security analysis and asks the user to confirm.
Session-level grants are tracked so the user isn't re-prompted
for the same category of command within a session. All risk levels
(including critical) support session grants via (a)llow.

Returns: 1 if approved, 0 if denied

=cut

sub _prompt_command_confirmation {
    my ($self, $command, $analysis, $context) = @_;

    my $is_critical = ($analysis->{risk_level} && $analysis->{risk_level} eq 'critical') ? 1 : 0;

    # Check session-level grants first
    for my $flag (@{$analysis->{flags}}) {
        my $cat = $flag->{category};
        if ($_session_grants{$cat}) {
            log_debug('TermOps', "Session grant exists for category '$cat' - auto-approving");
            return 1;
        }
    }

    my $ui = ($context && $context->{ui}) ? $context->{ui} : undef;

    unless ($ui && $ui->can('colorize')) {
        # No TTY - try broker relay for headless sub-agents
        my $broker = ($context && $context->{broker_client}) ? $context->{broker_client} : undef;
        if ($broker) {
            log_debug('TermOps', "No TTY - relaying command authorization through broker");
            require CLIO::Security::AuthorizationRelay;
            my $relay = CLIO::Security::AuthorizationRelay->new(broker_client => $broker);
            if ($relay->available()) {
                my $result = $relay->request_command_authorization($command, $analysis, $context);
                if ($result->{approved}) {
                    # Handle session grants from relay
                    if ($result->{grant_type} eq 'session') {
                        for my $flag (@{$analysis->{flags}}) {
                            $_session_grants{$flag->{category}} = 1;
                            log_debug('TermOps', "Session grant (via relay) for: $flag->{category}");
                        }
                    }
                    return 1;
                }
                return 0;
            }
        }
        log_debug('TermOps', "No UI and no broker relay - denying command");
        return 0;
    }

    # Suspend ALRM handler first - Chat.pm's 1-second timer calls ReadKey(-1)
    # which would consume keystrokes before <STDIN> can read them.
    my $saved_alrm = $SIG{ALRM};
    my $remaining_alarm = alarm(0);

    # Switch to cooked (normal) mode BEFORE displaying the prompt.
    # Previously, the terminal stayed in cbreak mode during the prompt, and
    # a ReadKey(-1) flush ran AFTER the user typed their response - consuming
    # the user's actual keystrokes (e.g. "n" + Enter). This caused <STDIN>
    # to block, the user to re-type (often "y"), and the security denial to
    # be silently ignored: the command ran, the session saved, and the
    # prompt reappeared for the same command.
    #
    # In cooked mode, <STDIN> reads a full line with proper line buffering
    # and echo. The ALRM is suspended above so it cannot fire during the
    # prompt to interfere with input.
    require CLIO::Compat::Terminal;
    CLIO::Compat::Terminal::ReadMode(0);

    my $spinner = ($context && $context->{spinner}) ? $context->{spinner} : undef;
    $spinner->stop() if $spinner && $spinner->can('stop');

    # Build prompt options — unified across all risk levels (including critical).
    # All risk levels use the same three-option format:
    #   (y)es once | (a)llow category | (n)o deny
    my $options = '(y)es once | (a)llow category | (n)o deny';

    # Use themed security prompt
    my $theme_mgr = $ui->{theme_mgr};
    if ($theme_mgr && $theme_mgr->can('get_security_prompt')) {
        my ($prompt_line, $input_line) = $theme_mgr->get_security_prompt(
            $command,
            $analysis->{flags},
            $options,
        );
        if ($is_critical) {
            print "\n" . $ui->colorize('[WARN] CRITICAL RISK', 'error_message') . "\n" . $prompt_line . "\n" . $input_line;
        } else {
            print "\n$prompt_line\n$input_line";
        }
    } else {
        # Minimal fallback if no theme available
        # Build flag descriptions on one line
        my @flag_parts;
        for my $flag (@{$analysis->{flags} || []}) {
            push @flag_parts, "[$flag->{severity}] $flag->{description}";
        }
        my $flags_str = join(" | ", @flag_parts);
        if ($is_critical) {
            print "\n* CRITICAL RISK | $command\n  $flags_str\n  $options: ";
        } else {
            print "\n* Security | $command\n  $flags_str\n  $options: ";
        }
    }

    # Flush stdout so the prompt is visible before blocking on input
    my $old_fh = select(STDOUT);
    $| = 1; select($old_fh);

    my $response = <STDIN>;
    chomp($response) if defined $response;
    $response = lc($response || 'n');

    CLIO::Compat::Terminal::ReadMode(1);

    # Restore ALRM handler
    $SIG{ALRM} = $saved_alrm || 'DEFAULT';
    alarm($remaining_alarm) if $remaining_alarm;

    $spinner->start() if $spinner && $spinner->can('start');

    if ($response eq 'y' || $response eq 'yes') {
        return 1;
    } elsif ($response eq 'a' || $response eq 'allow') {
        # Grant for the session - by category for all risk levels
        for my $flag (@{$analysis->{flags}}) {
            $_session_grants{$flag->{category}} = 1;
            log_debug('TermOps', "Session grant added for category: $flag->{category}");
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

=head2 _passthrough_wrap (Internal)

Wrap a command so its output reaches both the terminal and a log file.

The command is grouped with braces and the closing brace sits on its own
line. Appending the pipeline straight onto the command glued it to the
command's final line, which broke heredocs - the terminator stops being
alone, so "EOF 2>&1 | tee /tmp/..." gets fed to the child program as input -
and trailing comments, where the pipeline was commented out and nothing
reached the log.

Arguments: $command, $log_file
Returns: command string suitable for sh -c

=cut

sub _passthrough_wrap {
    my ($command, $log_file) = @_;
    my $escaped_log = _shell_escape($log_file);
    return "{ $command\n} 2>&1 | tee $escaped_log";
}

=head2 _write_stdin_file (Internal)

Stage text for the command's standard input into a temporary file.

Arguments: $content (required) - the text to feed
Returns: ($path, $error) - exactly one is defined

=cut

sub _write_stdin_file {
    my ($content) = @_;

    my ($fh, $path) = File::Temp::tempfile('clio_stdin_XXXXXX', TMPDIR => 1);
    unless ($fh) {
        return (undef, "tempfile: $!");
    }
    # Encode only when the scalar carries the UTF-8 flag. A payload that
    # arrived as raw bytes must be written through untouched, or it would be
    # encoded a second time.
    my $raw = $content;
    utf8::encode($raw) if utf8::is_utf8($raw);
    unless (print {$fh} $raw) {
        my $err = $!;
        close $fh;
        unlink $path;
        return (undef, "write: $err");
    }
    close $fh or unlink $path;

    return ($path, undef);
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
