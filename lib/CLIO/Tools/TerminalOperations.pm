# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Tools::TerminalOperations;

use strict;
use warnings;
use utf8;
use parent 'CLIO::Tools::Tool';
use Cwd 'getcwd';
use feature 'say';
use CLIO::Core::Logger qw(log_debug log_info log_warning);

=head1 NAME

CLIO::Tools::TerminalOperations - Shell/terminal command execution

=head1 DESCRIPTION

Provides safe terminal command execution with timeout and validation.
All commands run in passthrough mode - visible and interactive to the user.
When a terminal multiplexer (tmux/screen/zellij) is available, commands
run in a separate pane. Otherwise, CLIO suspends its input handling and
gives full TTY control to the command.

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
    
    # Try multiplexer path first, fall back to direct TTY handoff
    my $mux = $self->_get_multiplexer($context);
    
    eval {
        my $original_cwd = getcwd();
        chdir $working_dir if $working_dir ne '.';
        
        if ($mux && $mux->available()) {
            $result = $self->_execute_in_mux_pane($command, $timeout, $display_cmd, $mux, $working_dir);
        } else {
            $result = $self->_execute_with_tty_handoff($command, $timeout, $display_cmd, $working_dir);
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
    
    my $script_cmd = $self->_get_script_command($command, $log_file);
    
    # Wrap with working directory and done marker
    my $pane_cmd = "cd " . _shell_escape($working_dir) . " && "
                 . "$script_cmd; echo \$? > " . _shell_escape($done_marker);
    
    log_debug('TerminalOps', "Multiplexer execution: $pane_cmd");
    
    my $pane_id = $mux->create_pane(
        name    => "cmd-$$",
        command => $pane_cmd,
        size    => 40,
    );
    
    unless ($pane_id) {
        # Mux pane creation failed, fall back to direct TTY
        log_warning('TerminalOps', "Multiplexer pane creation failed, falling back to TTY handoff");
        return $self->_execute_with_tty_handoff($command, $timeout, $display_cmd, $working_dir);
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

=head2 _execute_with_tty_handoff

Execute a command with full TTY handoff. CLIO suspends its input handling
(ReadMode), gives the terminal to the command via system(), then resumes.
Output is captured via the script command for the agent.

=cut

sub _execute_with_tty_handoff {
    my ($self, $command, $timeout, $display_cmd, $working_dir) = @_;
    
    my $log_file = "/tmp/clio_terminal_$$.log";
    unlink $log_file if -f $log_file;
    
    # Suspend CLIO's terminal input handling so the command owns the TTY
    $self->_suspend_clio_input();
    
    my $exit_code;
    my $timed_out = 0;
    
    eval {
        # Build the script command for output capture
        my $script_cmd = $self->_get_script_command($command, $log_file);
        
        local $SIG{ALRM} = sub { die "Command timeout after ${timeout}s\n" };
        alarm($timeout);
        
        # system() gives the child process full TTY access
        $exit_code = system($script_cmd);
        $exit_code = $exit_code >> 8;
        
        alarm(0);
    };
    
    if ($@) {
        alarm(0);
        if ($@ =~ /timeout/) {
            $timed_out = 1;
            $exit_code = 124;  # Standard timeout exit code
        } else {
            # Resume input before returning error
            $self->_resume_clio_input();
            die $@;
        }
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

=cut

sub _resume_clio_input {
    my ($self) = @_;
    
    eval {
        require CLIO::Compat::Terminal;
        # Restore to normal mode first (cooked)
        CLIO::Compat::Terminal::ReadMode(0, *STDIN);
    };
    if ($@) {
        log_debug('TerminalOps', "Could not resume ReadMode: $@");
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

=head2 _get_script_command

Generate platform-specific script command for terminal recording.

macOS and Linux have different script command syntax:
- macOS: script -q <logfile> <command>
- Linux: script -qc "<command>" <logfile>

Arguments:
- $command: Command to execute
- $log_file: Path to output log file

Returns: Complete script command string

=cut

sub _get_script_command {
    my ($self, $command, $log_file) = @_;
    
    # Detect platform by checking uname
    my $platform = `uname -s 2>/dev/null` || '';
    chomp $platform;
    
    # Escape command for shell
    my $escaped_cmd = $command;
    $escaped_cmd =~ s/'/'\\''/g;
    
    if ($platform eq 'Darwin') {
        return "script -q '$log_file' sh -c '$escaped_cmd'";
    } else {
        return "script -qc '$escaped_cmd' '$log_file'";
    }
}

=head2 _read_and_cleanup_log

Read output from the script log file, sanitize it, and clean up.

=cut

sub _read_and_cleanup_log {
    my ($self, $log_file) = @_;
    
    my $output = '';
    if (-f $log_file) {
        if (open my $fh, '<:encoding(UTF-8)', $log_file) {
            $output = do { local $/; <$fh> };
            close $fh;
        }
        unlink $log_file;
    }
    
    return $self->_sanitize_terminal_output($output);
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
