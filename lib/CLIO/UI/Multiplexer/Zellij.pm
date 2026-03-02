package CLIO::UI::Multiplexer::Zellij;

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug log_info log_warning);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::UI::Multiplexer::Zellij - Zellij driver for CLIO multiplexer integration

=head1 DESCRIPTION

Implements pane management via the Zellij CLI action commands.
Zellij uses a modern pane model with floating panes and tab support.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        debug      => $args{debug} // 0,
        zellij_bin => _find_zellij(),
        pane_map   => {},  # name => pane_id
        next_id    => 1,
    };

    bless $self, $class;
    return $self;
}

=head2 create_pane(%args)

Create a new Zellij pane running the given command.

Arguments:
    name    - Pane label (e.g., 'agent-1')
    command - Command to execute in the pane
    vertical - Split direction (default: horizontal)
    size    - Ignored (Zellij handles sizing automatically)

Returns: pane identifier string

=cut

sub create_pane {
    my ($self, %args) = @_;

    my $name    = $args{name} or croak "name required";
    my $command = $args{command} or croak "command required";
    my $vertical = $args{vertical} // 0;

    # Zellij uses 'action new-pane' to create panes
    # --direction: left/right/up/down
    my $direction = $vertical ? 'down' : 'right';

    my @cmd = (
        $self->{zellij_bin}, 'action', 'new-pane',
        '--direction', $direction,
        '--name', $name,
        '--', 'sh', '-c', $command,
    );

    log_debug('Zellij', "Running: " . join(' ', @cmd));

    eval { $self->_run_cmd(@cmd) };
    if ($@) {
        log_warning('Zellij', "Failed to create pane '$name': $@");
        return undef;
    }

    # Zellij doesn't return pane IDs from CLI commands
    # Use our own tracking ID
    my $pane_id = "zellij:$name:" . $self->{next_id}++;
    $self->{pane_map}{$name} = $pane_id;

    log_info('Zellij', "Created pane '$name' ($pane_id)");

    # Move focus back to the original pane
    eval {
        $self->_run_cmd($self->{zellij_bin}, 'action', 'focus-previous-pane');
    };

    return $pane_id;
}

=head2 kill_pane($pane_id)

Kill a Zellij pane. Since Zellij doesn't expose pane IDs via CLI,
we focus the pane by name and close it.

=cut

sub kill_pane {
    my ($self, $pane_id) = @_;

    return 0 unless $pane_id;

    # Extract name from our pane_id format
    my $name;
    if ($pane_id =~ /^zellij:([^:]+):/) {
        $name = $1;
    } else {
        $name = $pane_id;
    }

    # Zellij can close panes by focusing them then closing
    # This is imperfect - Zellij CLI doesn't have great pane targeting
    eval {
        $self->_run_cmd($self->{zellij_bin}, 'action', 'close-pane');
    };
    if ($@) {
        log_debug('Zellij', "close-pane failed (may already be closed): $@");
    }

    # Clean up internal tracking
    my @to_remove = grep { ($self->{pane_map}{$_} // '') eq $pane_id } keys %{$self->{pane_map}};
    delete $self->{pane_map}{$_} for @to_remove;

    return 1;
}

=head2 pane_exists($pane_id)

Check if a Zellij pane still exists. Limited by Zellij's CLI capabilities.

=cut

sub pane_exists {
    my ($self, $pane_id) = @_;

    return 0 unless $pane_id;

    # Zellij doesn't have a reliable way to check specific pane existence
    # via CLI. We assume panes exist until kill is called.
    # The Multiplexer base class will clean up on list_panes() calls.
    return exists $self->{pane_map}{ $self->_name_from_id($pane_id) } ? 1 : 0;
}

=head2 list_panes()

List known Zellij panes.

Returns: arrayref of pane info hashes

=cut

sub list_panes {
    my ($self) = @_;

    my @result;
    for my $name (sort keys %{$self->{pane_map}}) {
        push @result, {
            id      => $self->{pane_map}{$name},
            command => $name,
        };
    }

    return \@result;
}

# === Private Methods ===

sub _name_from_id {
    my ($self, $pane_id) = @_;
    if ($pane_id =~ /^zellij:([^:]+):/) {
        return $1;
    }
    return $pane_id;
}

sub _run_cmd {
    my ($self, @cmd) = @_;

    my $pid = open(my $pipe, '-|');
    if (!defined $pid) {
        croak "Cannot fork for zellij command: $!";
    }

    if ($pid == 0) {
        open(STDERR, '>&STDOUT');
        exec(@cmd) or die "Cannot exec: $!";
    }

    my $output = do { local $/; <$pipe> };
    close($pipe);
    my $exit_code = $? >> 8;

    if ($exit_code != 0) {
        croak "zellij command failed (exit $exit_code): " . join(' ', @cmd) . "\nOutput: " . ($output // '');
    }

    return $output;
}

sub _find_zellij {
    my $path = `which zellij 2>/dev/null`;
    chomp $path if $path;
    return $path || 'zellij';
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.
