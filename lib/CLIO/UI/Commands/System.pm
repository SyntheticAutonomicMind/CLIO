package CLIO::UI::Commands::System;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);

=head1 NAME

CLIO::UI::Commands::System - System utility commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::System;
  
  my $sys_cmd = CLIO::UI::Commands::System->new(
      chat => $chat_instance,
      session => $session,
      debug => 0
  );
  
  # Handle system commands
  $sys_cmd->handle_exec_command('ls -la');
  $sys_cmd->handle_performance_command();
  $sys_cmd->handle_multiline_command();

=head1 DESCRIPTION

Handles system utility commands including:
- /exec, /shell - Execute shell commands
- /performance, /perf - Show performance metrics
- /multiline, /ml - Multi-line input mode

Note: Complex commands like /todo, /memory, /billing, /context, /skills
are still in Chat.pm pending further refactoring.

Extracted from Chat.pm to improve maintainability.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    # Assign object references separately
    $self->{session} = $args{session};
    $self->{config} = $args{config};
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_key_value { shift->{chat}->display_key_value(@_) }
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub writeline { shift->{chat}->writeline(@_) }
sub colorize { shift->{chat}->colorize(@_) }

=head2 handle_shell_command()

Launch interactive shell session

=cut

sub handle_shell_command {
    my ($self) = @_;
    
    $self->display_system_message("Launching interactive shell...");
    $self->display_system_message("Type 'exit' to return to CLIO");
    $self->writeline("", markdown => 0);
    
    system($ENV{SHELL} || '/bin/bash');
    
    # Restore terminal state after shell exits
    # The shell may have changed terminal settings
    eval {
        require CLIO::Compat::Terminal;
        CLIO::Compat::Terminal::reset_terminal();  # Moderate reset: ReadMode + safe ANSI codes
    };
    
    $self->writeline("", markdown => 0);
    $self->display_system_message("Returned to CLIO");
}

=head2 handle_exec_command(@args)

Execute a shell command and display output

=cut

sub handle_exec_command {
    my ($self, @args) = @_;
    
    unless (@args) {
        $self->display_error_message("Usage: /exec <command>");
        return;
    }
    
    my $command = join(' ', @args);
    
    $self->display_system_message("Executing: $command");
    $self->writeline("", markdown => 0);
    
    my $output = `$command 2>&1`;
    my $exit_code = $? >> 8;
    
    # Output each line through writeline for pagination support
    for my $line (split /\n/, $output) {
        $self->writeline($line, markdown => 0);
    }
    $self->writeline("", markdown => 0);
    
    if ($exit_code != 0) {
        $self->display_error_message("Command exited with code: $exit_code");
    } else {
        $self->display_system_message("Command completed successfully");
    }
}

=head2 handle_performance_command(@args)

Display performance metrics

=cut

sub handle_performance_command {
    my ($self, @args) = @_;
    
    $self->display_command_header("PERFORMANCE METRICS");
    
    # Get session stats
    if ($self->{session} && $self->{session}->state()) {
        my $state = $self->{session}->state();
        my $billing = $state->{billing} || {};
        
        $self->display_key_value("Total Requests", $billing->{request_count} || 0);
        $self->display_key_value("Input Tokens", $billing->{input_tokens} || 0);
        $self->display_key_value("Output Tokens", $billing->{output_tokens} || 0);
        
        my $total = ($billing->{input_tokens} || 0) + ($billing->{output_tokens} || 0);
        $self->display_key_value("Total Tokens", $total);
        
        # Calculate average if we have requests
        if ($billing->{request_count} && $billing->{request_count} > 0) {
            my $avg = int($total / $billing->{request_count});
            $self->display_key_value("Avg Tokens/Request", $avg);
        }
    } else {
        $self->display_system_message("No session metrics available");
    }
    
    $self->writeline("", markdown => 0);
}

=head2 handle_multiline_command()

Open external editor for multi-line input

=cut

sub handle_multiline_command {
    my ($self) = @_;
    
    require CLIO::Core::Editor;
    my $editor = CLIO::Core::Editor->new(
        config => $self->{config},
        debug => $self->{debug}
    );
    
    # Check if editor is available
    unless ($editor->check_editor_available()) {
        $self->display_error_message("Editor not found: " . $editor->{editor});
        $self->display_system_message("Set editor with: /config editor <editor>");
        $self->display_system_message("Or set \$EDITOR or \$VISUAL environment variable");
        return;
    }
    
    my $result = $editor->edit_multiline();
    
    if ($result->{success} && $result->{content} && length($result->{content}) > 0) {
        return $result->{content};  # Return content to be processed as input
    } else {
        $self->display_system_message("Multi-line input cancelled (empty content)");
        return;
    }
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
