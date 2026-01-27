package CLIO::Tools::TerminalOperations;

use strict;
use warnings;
use parent 'CLIO::Tools::Tool';
use Cwd 'getcwd';
use feature 'say';

=head1 NAME

CLIO::Tools::TerminalOperations - Shell/terminal command execution

=head1 DESCRIPTION

Provides safe terminal command execution with timeout and validation.

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
    
    # Determine if passthrough mode should be used
    my $config = $context->{config};
    my $use_passthrough = $self->_should_use_passthrough($command, $params, $config);
    
    eval {
        my $original_cwd = getcwd();
        chdir $working_dir if $working_dir ne '.';
        
        # Truncate command for display if very long
        my $display_cmd = length($command) > 60 
            ? substr($command, 0, 57) . "..."
            : $command;
        
        if ($use_passthrough) {
            # Passthrough mode: Execute with direct TTY access
            # User can interact (editor, GPG prompts, etc.)
            # Agent only gets exit code, not output
            
            local $SIG{ALRM} = sub { die "Command timeout after ${timeout}s\n" };
            alarm($timeout);
            
            my $exit_code = system($command);
            $exit_code = $exit_code >> 8;
            
            alarm(0);
            
            chdir $original_cwd if $working_dir ne '.';
            
            my $status = $exit_code == 0 ? "success" : "exit code $exit_code";
            my $action_desc = "running '$display_cmd' with direct terminal access ($status)";
            
            $result = $self->success_result(
                "Command executed with direct terminal access. User saw output/prompts directly.\nExit code: $exit_code",
                action_description => $action_desc,
                exit_code => $exit_code,
                command => $command,
                timeout => $timeout,
                passthrough => 1,
            );
        } else {
            # Capture mode: Execute and capture output for agent
            
            local $SIG{ALRM} = sub { die "Command timeout after ${timeout}s\n" };
            alarm($timeout);
            
            my $output = `$command 2>&1`;
            my $exit_code = $? >> 8;
            
            alarm(0);
            
            chdir $original_cwd if $working_dir ne '.';
            
            my $status = $exit_code == 0 ? "success" : "exit code $exit_code";
            my $action_desc = "running '$display_cmd' ($status)";
            
            $result = $self->success_result(
                $output,
                action_description => $action_desc,
                exit_code => $exit_code,
                command => $command,
                timeout => $timeout,
            );
        }
    };
    
    if ($@) {
        return $self->error_result("Command execution failed: $@");
    }
    
    return $result;
}

sub validate_command {
    my ($self, $params, $context) = @_;
    
    my $command = $params->{command};
    
    return $self->error_result("Missing 'command' parameter") unless $command;
    
    # Extract the actual command being executed (before pipes, redirects, or &&)
    # This excludes arguments and data like git commit messages
    my $executable = $command;
    
    # For git commands, only check the git subcommand, not arguments
    if ($command =~ /^\s*(?:git\s+(\w+)|(.+?))\s/) {
        my $git_cmd = $1;
        if ($git_cmd) {
            # For git, just check that it's git - don't check commit message content
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

=head2 _should_use_passthrough

Determine if passthrough mode should be used for a command.

Checks (in priority order):
1. Per-command passthrough parameter override
2. Global terminal_passthrough config setting
3. Auto-detection (if terminal_autodetect enabled)

Arguments:
- $command: Command string to execute
- $params: Parameters hash (may contain passthrough override)
- $config: Config object

Returns: Boolean (1 = use passthrough, 0 = use capture)

=cut

sub _should_use_passthrough {
    my ($self, $command, $params, $config) = @_;
    
    # 1. Per-command override (highest priority)
    if (defined $params->{passthrough}) {
        return $params->{passthrough} ? 1 : 0;
    }
    
    # 2. Global passthrough setting
    if ($config && $config->get('terminal_passthrough')) {
        return 1;
    }
    
    # 3. Auto-detection (if enabled)
    if ($config && $config->get('terminal_autodetect')) {
        return $self->_is_interactive_command($command);
    }
    
    # Default: capture mode
    return 0;
}

=head2 _is_interactive_command

Detect if a command is likely to be interactive (needs TTY access).

Arguments:
- $command: Command string to analyze

Returns: Boolean (1 = interactive, 0 = non-interactive)

=cut

sub _is_interactive_command {
    my ($self, $command) = @_;
    
    # Known interactive editors and pagers
    return 1 if $command =~ /\b(vim|vi|nvim|nano|emacs|less|more|man)\b/;
    
    # Git commit without message flag (will open editor)
    return 1 if $command =~ /git\s+commit(?!\s+.*(?:-m|--message))/;
    
    # Git commands with GPG signing (needs passphrase prompt)
    return 1 if $command =~ /git\s+.*(?:--gpg-sign|-S)\b/;
    
    # GPG operations (likely need passphrase)
    return 1 if $command =~ /\bgpg\b/;
    
    # Interactive shells (if command is just a shell invocation)
    return 1 if $command =~ /^\s*(bash|sh|zsh|fish|tcsh|csh)\s*$/;
    
    # SSH connections (interactive by default)
    return 1 if $command =~ /^\s*ssh\s+/;
    
    # Interactive python/ruby/node REPLs (no script argument)
    return 1 if $command =~ /^\s*(python|ruby|irb|node)\s*$/;
    
    return 0;
}

1;
