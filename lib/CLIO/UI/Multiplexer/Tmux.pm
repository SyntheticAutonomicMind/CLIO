# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Multiplexer::Tmux;

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug log_info log_warning);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::UI::Multiplexer::Tmux - tmux driver for CLIO multiplexer integration

=head1 DESCRIPTION

Implements pane management via the tmux CLI. All operations use
tmux subcommands (split-window, kill-pane, list-panes, etc.).

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        debug     => $args{debug} // 0,
        tmux_bin  => _find_tmux(),
        pane_map  => {},  # internal_id => tmux_pane_id
    };

    bless $self, $class;
    return $self;
}

=head2 create_pane(%args)

Create a new tmux pane.

Arguments:
    name    - Pane label (used for tracking)
    command - Command to execute in the pane
    vertical - Split direction (default: horizontal / side-by-side)
    size    - Pane size as percentage (default: 30)

Returns: pane identifier string

=cut

sub create_pane {
    my ($self, %args) = @_;

    my $name    = $args{name} or croak "name required";
    my $command = $args{command} or croak "command required";
    my $vertical = $args{vertical} // 0;
    my $size    = $args{size} // 30;

    my $split_flag = $vertical ? '-v' : '-h';

    # First, create the pane without -P/-F (more compatible)
    # Then query for the newest pane ID
    my @cmd = (
        $self->{tmux_bin}, 'split-window',
        $split_flag,
        '-d',                        # Don't steal focus
        '-l', "${size}%",            # Size as percentage
        $command,
    );

    log_debug('Tmux', "Running: " . join(' ', map { "'$_'" } @cmd));

    eval { $self->_run_cmd(@cmd) };
    if ($@) {
        log_warning('Tmux', "split-window failed: $@");
        return undef;
    }

    # Get the pane ID of the most recently created pane
    my $pane_id = $self->_find_newest_pane();

    if ($pane_id) {
        $self->{pane_map}{$name} = $pane_id;
        log_info('Tmux', "Created pane $pane_id for '$name'");
    } else {
        log_warning('Tmux', "Created pane but could not determine its ID");
        # Use a synthetic ID for tracking
        $pane_id = "tmux:$name:" . time();
        $self->{pane_map}{$name} = $pane_id;
    }

    return $pane_id;
}

=head2 kill_pane($pane_id)

Kill a tmux pane by its ID.

=cut

sub kill_pane {
    my ($self, $pane_id) = @_;

    return 0 unless $pane_id;

    # Only send kill-pane for real tmux pane IDs (format: %N)
    if ($pane_id =~ /^%\d+$/) {
        my @cmd = ($self->{tmux_bin}, 'kill-pane', '-t', $pane_id);
        log_debug('Tmux', "Killing pane: $pane_id");

        eval { $self->_run_cmd(@cmd) };
        if ($@) {
            log_debug('Tmux', "kill-pane failed (pane may already be closed): $@");
        }
    }

    # Clean up internal tracking
    my @to_remove = grep { ($self->{pane_map}{$_} // '') eq $pane_id } keys %{$self->{pane_map}};
    delete $self->{pane_map}{$_} for @to_remove;

    return 1;
}

=head2 pane_exists($pane_id)

Check if a tmux pane still exists.

=cut

sub pane_exists {
    my ($self, $pane_id) = @_;

    return 0 unless $pane_id;

    # Only check real tmux pane IDs
    return 0 unless $pane_id =~ /^%\d+$/;

    my @cmd = ($self->{tmux_bin}, 'list-panes', '-F', '#{pane_id}');
    my $output = eval { $self->_run_cmd(@cmd) };
    return 0 if $@;

    my @panes = split /\n/, ($output // '');
    return grep { $_ eq $pane_id } @panes;
}

=head2 list_panes()

List all panes in the current window.

Returns: arrayref of pane IDs

=cut

sub list_panes {
    my ($self) = @_;

    my @cmd = ($self->{tmux_bin}, 'list-panes', '-F', '#{pane_id} #{pane_current_command}');
    my $output = eval { $self->_run_cmd(@cmd) };
    return [] if $@;

    my @result;
    for my $line (split /\n/, ($output // '')) {
        if ($line =~ /^(%\d+)\s+(.*)$/) {
            push @result, { id => $1, command => $2 };
        }
    }

    return \@result;
}

# === Private Methods ===

sub _run_cmd {
    my ($self, @cmd) = @_;

    # Use open3-style pipe to avoid shell quoting issues
    my $pid = open(my $pipe, '-|');
    if (!defined $pid) {
        croak "Cannot fork for tmux command: $!";
    }

    if ($pid == 0) {
        # Child - redirect stderr to stdout, then exec
        open(STDERR, '>&STDOUT');
        exec(@cmd) or die "Cannot exec: $!";
    }

    # Parent - read output
    my $output = do { local $/; <$pipe> };
    close($pipe);
    my $exit_code = $? >> 8;

    if ($exit_code != 0) {
        croak "tmux command failed (exit $exit_code): " . join(' ', @cmd) . "\nOutput: " . ($output // '');
    }

    return $output;
}

sub _find_newest_pane {
    my ($self) = @_;

    # List panes sorted by creation time (newest last)
    my @cmd = ($self->{tmux_bin}, 'list-panes', '-F', '#{pane_id}');
    my $output = eval { $self->_run_cmd(@cmd) };
    return undef if $@;

    my @panes = split /\n/, ($output // '');
    return $panes[-1] if @panes;  # Last pane is newest
    return undef;
}

sub _find_tmux {
    my $path = `which tmux 2>/dev/null`;
    chomp $path if $path;
    return $path || 'tmux';
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.
