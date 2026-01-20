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
    my $working_dir = $params->{working_directory} || '.';
    my $result;
    
    unless (defined $command && length($command) > 0) {
        return $self->error_result("Missing or empty 'command' parameter");
    }
    
    # Validate command first
    my $validation = $self->validate_command({ command => $command }, $context);
    unless ($validation->{success}) {
        return $validation;
    }
    
    eval {
        my $original_cwd = getcwd();
        chdir $working_dir if $working_dir ne '.';
        
        # Execute with timeout
        my $output;
        local $SIG{ALRM} = sub { die "Command timeout after ${timeout}s\n" };
        alarm($timeout);
        
        $output = `$command 2>&1`;
        my $exit_code = $? >> 8;
        
        alarm(0);
        
        chdir $original_cwd if $working_dir ne '.';
        
        # Truncate command for display if very long
        my $display_cmd = length($command) > 60 
            ? substr($command, 0, 57) . "..."
            : $command;
        my $status = $exit_code == 0 ? "success" : "exit code $exit_code";
        my $action_desc = "running '$display_cmd' ($status)";
        
        $result = $self->success_result(
            $output,
            action_description => $action_desc,
            exit_code => $exit_code,
            command => $command,
            timeout => $timeout,
        );
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
    
    # Check for dangerous patterns
    my @dangerous = ('rm -rf', 'sudo rm', 'shutdown', 'reboot', 'halt', 'dd if=', 'mkfs', 'format');
    
    foreach my $pattern (@dangerous) {
        if ($command =~ /\Q$pattern\E/i) {
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

1;
