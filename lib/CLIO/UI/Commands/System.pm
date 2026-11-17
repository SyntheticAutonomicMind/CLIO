# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Commands::System;

use strict;
use warnings;
use utf8;
use parent 'CLIO::UI::Commands::Base';

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

Note: Complex commands like /todo, /memory, /skills
are still in Chat.pm pending further refactoring.

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


=head2 handle_shell_command()

Launch interactive shell session

=cut

sub _find_windows_bash {
    # Check PATH for bash.exe (Git for Windows, BusyBox, MSYS2)
    for my $dir (split /;/, $ENV{PATH} || '') {
        my $bash = "$dir\\bash.exe";
        return $bash if -x $bash;
    }
    return undef;
}

sub handle_shell_command {
    my ($self) = @_;
    
    return 1 if $self->_require_interactive('interactive shell');
    
    $self->display_system_message("Launching interactive shell...");
    $self->display_system_message("Type 'exit' to return to CLIO");
    $self->writeline("", markdown => 0);
    
    # Reset terminal to normal mode before launching shell.
    # ReadLine may have left it in raw mode - the shell must inherit
    # normal mode so Ctrl-C sends SIGINT rather than literal bytes.
    eval {
        require CLIO::Compat::Terminal;
        CLIO::Compat::Terminal::ReadMode(0);
    };
    
    # Determine shell: $SHELL on Unix, bash or cmd.exe on Windows
    my $shell;
    if ($^O eq 'MSWin32') {
        # Prefer bash from Git for Windows or BusyBox (added to PATH by host application)
        my $bash = _find_windows_bash();
        $shell = $bash || $ENV{COMSPEC} || 'cmd.exe';
    } else {
        $shell = $ENV{SHELL} || '/bin/bash';
    }
    system($shell);
    
    # Restore terminal state after shell exits (shell may have changed settings)
    eval {
        require CLIO::Compat::Terminal;
        CLIO::Compat::Terminal::reset_terminal();
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
        
        $self->display_key_value("Total Requests", $billing->{total_requests} || 0);
        $self->display_key_value("Input Tokens", $billing->{total_prompt_tokens} || 0);
        $self->display_key_value("Output Tokens", $billing->{total_completion_tokens} || 0);

        my $total = ($billing->{total_prompt_tokens} || 0) + ($billing->{total_completion_tokens} || 0);
        $self->display_key_value("Total Tokens", $total);

        # Calculate average if we have requests
        if ($billing->{total_requests} && $billing->{total_requests} > 0) {
            my $avg = int($total / $billing->{total_requests});
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

    return 1 if $self->_require_interactive('multi-line editor');

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

=head2 handle_security_command(@args)

Handle the /security command - inspect and revoke approval grants.

  /security                  Show every active grant
  /security reset            Clear every grant
  /security reset <scope>    Clear one scope: command, script, overwrite,
                             web, path

=cut

# Human labels for the GrantStore scopes.
my %SECURITY_SCOPE_LABELS = (
    command      => 'command',
    script       => 'script',
    overwrite    => 'overwrite',
    web          => 'web',
    path         => 'path',
);

sub handle_security_command {
    my ($self, @args) = @_;

    require CLIO::Security::GrantStore;

    my $action = $args[0] || '';
    my $scope  = $args[1];

    if ($action eq 'reset') {
        my $cleared;
        if (defined $scope && length $scope) {
            unless ($SECURITY_SCOPE_LABELS{$scope}) {
                $self->display_error_message(
                    "Unknown scope '$scope'. Scopes: " . join(', ', sort keys %SECURITY_SCOPE_LABELS));
                return;
            }
            $cleared = CLIO::Security::GrantStore::reset_scope($scope);
            $self->display_command_header("SECURITY GRANTS RESET");
            $self->display_success_message(
                "Cleared $cleared grant(s) in the '$SECURITY_SCOPE_LABELS{$scope}' scope.");
        } else {
            $cleared = CLIO::Security::GrantStore::reset();
            $self->display_command_header("SECURITY GRANTS RESET");
            $self->display_success_message("All $cleared approval grant(s) cleared.");
        }
        $self->writeline("", markdown => 0);
        $self->display_key_value("Effect", "Every category prompts again");
        return;
    }

    $self->display_command_header("SECURITY STATUS");

    # What the configuration itself has already decided for this session. A
    # level of relaxed lowers the severity a finding is reported at; sandbox
    # escalates everything. Both are worth seeing next to the grants, because
    # together they are the whole answer to "what will not ask me?".
    if ($self->{config}) {
        my $level   = $self->{config}->get('security_level') || 'standard';
        my $sandbox = $self->{config}->get('sandbox') ? 'on' : 'off';
        my %note = (
            relaxed  => 'commands prompt for critical only; scripts are scanned and labelled low',
            standard => 'commands prompt for high and above; scripts prompt on any finding',
            strict   => 'commands prompt for medium and above; scripts prompt on any finding',
        );
        $self->display_key_value("Security level", "$level (" . ($note{$level} || '') . ')');
        $self->display_key_value("Sandbox", "$sandbox (escalates every finding)") if $sandbox eq 'on';
        $self->writeline("", markdown => 0);
    }

    # One table, one shape: the store is the only thing that knows where
    # grants live, so this view cannot drift out of sync with enforcement.
    my @grants = CLIO::Security::GrantStore::list_grants();

    unless (@grants) {
        $self->display_info_message("No active approval grants.");
        $self->display_key_value("All security prompts", "active (interactive)");
        $self->writeline("", markdown => 0);
        $self->display_key_value("Tip", "Answer (a)ll at a prompt to grant a category");
        return;
    }

    $self->display_key_value("Active grants", scalar(@grants) . " grant(s)");

    for my $grant (@grants) {
        my $label = $SECURITY_SCOPE_LABELS{ $grant->{scope} } || $grant->{scope};
        my $target = $grant->{key};

        if ($grant->{scope} eq 'path') {
            my $data = $grant->{data} || {};
            my $where = $data->{path};
            if (defined $where && length $where) {
                # A directory approval covers everything below it, so show it
                # as a directory rather than as a file with an odd name.
                $where .= '/' if $data->{prefix} && $where ne '/';
            } else {
                $where = 'any path';
            }
            $target = ($data->{operation} || '?') . ' -> ' . $where;
            $target .= $data->{one_time_use} ? ' (one-time)' : ' (session)';
        }

        $self->display_list_item("$label: $target (" . _format_grant_age($grant->{age}) . ')');
    }

    my $ttl = CLIO::Security::GrantStore::ttl_seconds();
    $self->writeline("", markdown => 0);
    if ($ttl > 0) {
        my $hours = $ttl / 3600;
        $self->display_key_value("Lifetime", sprintf('%.0f hour(s); resumed sessions keep unexpired grants', $hours));
    } else {
        $self->display_key_value("Lifetime", "no expiry");
    }
    $self->display_key_value("Tip", "Use /security reset [scope] to clear grants");
}

=head2 _format_grant_age($seconds) (Internal)

Render a grant's age as a short human string.

=cut

sub _format_grant_age {
    my ($age) = @_;
    $age //= 0;
    return 'just now' if $age < 60;
    return int($age / 60) . 'm ago' if $age < 3600;
    return int($age / 3600) . 'h ago' if $age < 86400;
    return int($age / 86400) . 'd ago';
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut

1;
