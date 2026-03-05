# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Commands::Mux;

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug log_info log_warning);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::UI::Commands::Mux - Terminal multiplexer commands

=head1 DESCRIPTION

Commands for managing terminal multiplexer integration (tmux, GNU Screen, Zellij).
When CLIO is running inside a multiplexer, these commands allow creating and
managing output panes for sub-agents and event streams.

Commands:
- /mux status    - Show multiplexer detection and pane status
- /mux agent <id> - Open a pane tailing a specific agent's log
- /mux close <id> - Close a specific managed pane
- /mux close all  - Close all CLIO-managed panes
- /mux auto [on|off] - Toggle auto-pane on agent spawn

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        chat          => $args{chat} || croak "chat instance required",
        subagent_cmd  => $args{subagent_cmd},  # Reference to SubAgent command handler
        debug         => $args{debug} // 0,
    };

    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_section_header { shift->{chat}->display_section_header(@_) }
sub display_key_value { shift->{chat}->display_key_value(@_) }
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub colorize { shift->{chat}->colorize(@_) }
sub writeline { shift->{chat}->writeline(@_) }

sub handle {
    my ($self, $subcommand, $args) = @_;

    $subcommand ||= 'help';
    $args ||= '';

    if ($subcommand eq 'status' || $subcommand eq 'st') {
        return $self->cmd_status();
    }
    elsif ($subcommand eq 'agent') {
        return $self->cmd_agent($args);
    }
    elsif ($subcommand eq 'close' || $subcommand eq 'kill') {
        return $self->cmd_close($args);
    }
    elsif ($subcommand eq 'auto') {
        return $self->cmd_auto($args);
    }
    elsif ($subcommand eq 'help' || $subcommand eq '?') {
        return $self->cmd_help();
    }
    else {
        return "Unknown subcommand: $subcommand\nUse /mux help for available commands";
    }
}

sub cmd_status {
    my ($self) = @_;

    my $mux = $self->_get_multiplexer();

    $self->display_section_header("MULTIPLEXER STATUS");

    if (!$mux) {
        $self->display_key_value("Detected", $self->colorize("none", 'DIM'));
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("Not running inside a terminal multiplexer.", 'DIM'), markdown => 0);
        $self->writeline($self->colorize("Start CLIO inside tmux, GNU Screen, or Zellij for multi-pane support.", 'DIM'), markdown => 0);
        return "";
    }

    my $info = $mux->status_info();

    $self->display_key_value("Detected", $self->colorize($info->{detected}, 'GREEN'));
    $self->display_key_value("Auto-pane", $info->{auto_pane}
        ? $self->colorize("on", 'GREEN')
        : $self->colorize("off", 'DIM'));
    $self->display_key_value("Managed panes", $info->{pane_count});

    if ($info->{pane_count} > 0) {
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("Active Panes:", 'BOLD'), markdown => 0);

        my $panes = $info->{panes};
        for my $pane_id (sort keys %$panes) {
            my $pane = $panes->{$pane_id};
            my $age = time() - $pane->{created_at};
            my $age_str = sprintf("%dm%ds", int($age / 60), $age % 60);
            $self->writeline(sprintf("  %-20s %s (%s)",
                $self->colorize($pane->{name}, 'BOLD'),
                $self->colorize($pane_id, 'DIM'),
                $age_str,
            ), markdown => 0);
        }
    }

    return "";
}

sub cmd_agent {
    my ($self, $agent_id) = @_;

    unless ($agent_id) {
        $self->display_error_message("Usage: /mux agent <agent-id>");
        return "";
    }

    $agent_id =~ s/^\s+|\s+$//g;

    my $mux = $self->_get_multiplexer();
    unless ($mux) {
        $self->display_error_message("Not running inside a terminal multiplexer.");
        $self->writeline($self->colorize("Start CLIO inside tmux, GNU Screen, or Zellij.", 'DIM'), markdown => 0);
        return "";
    }

    my $log_path = "/tmp/clio-agent-$agent_id.log";
    unless (-f $log_path) {
        $self->display_error_message("No log file found for agent: $agent_id");
        $self->writeline($self->colorize("Log path: $log_path", 'DIM'), markdown => 0);
        return "";
    }

    my $pane_id = $mux->create_agent_pane($agent_id, $log_path);
    if ($pane_id) {
        $self->display_system_message("Opened pane for $agent_id");
        $self->display_key_value("Pane", $self->colorize($pane_id, 'DIM'));
    } else {
        $self->display_error_message("Failed to create pane for $agent_id");
    }

    return "";
}

sub cmd_close {
    my ($self, $target) = @_;

    $target =~ s/^\s+|\s+$//g if $target;

    my $mux = $self->_get_multiplexer();
    unless ($mux) {
        $self->display_error_message("Not running inside a terminal multiplexer.");
        return "";
    }

    if (!$target) {
        $self->display_error_message("Usage: /mux close <pane-id|all>");
        return "";
    }

    if ($target eq 'all') {
        my $count = $mux->kill_all_panes();
        $self->display_system_message("Closed $count pane(s)");
        return "";
    }

    # Try to find pane by name or ID
    my $panes = $mux->list_panes();
    my $found_id;

    # First try direct pane ID match
    if (exists $panes->{$target}) {
        $found_id = $target;
    } else {
        # Try matching by name
        for my $pid (keys %$panes) {
            if ($panes->{$pid}{name} eq $target) {
                $found_id = $pid;
                last;
            }
        }
    }

    if ($found_id) {
        $mux->kill_pane($found_id);
        $self->display_system_message("Closed pane: $found_id");
    } else {
        $self->display_error_message("Pane not found: $target");
        if (keys %$panes) {
            $self->writeline($self->colorize("Active panes: " . join(', ', sort keys %$panes), 'DIM'), markdown => 0);
        }
    }

    return "";
}

sub cmd_auto {
    my ($self, $setting) = @_;

    $setting =~ s/^\s+|\s+$//g if $setting;

    my $mux = $self->_get_multiplexer();
    unless ($mux) {
        $self->display_error_message("Not running inside a terminal multiplexer.");
        return "";
    }

    if (!$setting) {
        # Toggle
        my $current = $mux->auto_pane();
        $mux->auto_pane(!$current);
        my $new_state = $mux->auto_pane() ? 'on' : 'off';
        $self->display_system_message("Auto-pane: $new_state");
        return "";
    }

    if ($setting eq 'on' || $setting eq '1' || $setting eq 'true') {
        $mux->auto_pane(1);
        $self->display_system_message("Auto-pane: on");
    }
    elsif ($setting eq 'off' || $setting eq '0' || $setting eq 'false') {
        $mux->auto_pane(0);
        $self->display_system_message("Auto-pane: off");
    }
    else {
        $self->display_error_message("Invalid setting: $setting (use on/off)");
    }

    return "";
}

sub cmd_help {
    my ($self) = @_;

    $self->display_section_header("MULTIPLEXER COMMANDS");

    my @commands = (
        ['status',        'Show multiplexer detection and pane status'],
        ['agent <id>',    'Open pane tailing a sub-agent\'s log'],
        ['close <id>',    'Close a specific managed pane'],
        ['close all',     'Close all CLIO-managed panes'],
        ['auto [on|off]', 'Toggle auto-pane on agent spawn'],
        ['help',          'Show this help message'],
    );

    for my $cmd (@commands) {
        $self->writeline(sprintf("  %-18s %s",
            $self->colorize("/mux $cmd->[0]", 'BOLD'),
            $cmd->[1],
        ), markdown => 0);
    }

    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("Supported multiplexers: tmux, GNU Screen, Zellij", 'DIM'), markdown => 0);
    $self->writeline($self->colorize("Auto-pane opens a live output pane when /agent spawn is used.", 'DIM'), markdown => 0);

    return "";
}

# === Private Methods ===

sub _get_multiplexer {
    my ($self) = @_;

    # Get multiplexer via SubAgent command handler (shared instance)
    if ($self->{subagent_cmd}) {
        return $self->{subagent_cmd}->multiplexer();
    }

    # Fallback: create our own instance
    unless (exists $self->{_multiplexer}) {
        eval {
            require CLIO::UI::Multiplexer;
            $self->{_multiplexer} = CLIO::UI::Multiplexer->new(debug => $self->{debug});
        };
        if ($@ || !$self->{_multiplexer} || !$self->{_multiplexer}->available()) {
            $self->{_multiplexer} = undef;
        }
    }

    return $self->{_multiplexer};
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.
