package CLIO::Coordination::Client;

use strict;
use warnings;
use utf8;
use IO::Socket::UNIX;
use IO::Select;
use JSON::PP qw(encode_json decode_json);
use Time::HiRes qw(time sleep);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::Coordination::Client - Client library for multi-agent coordination

=head1 DESCRIPTION

Provides a simple interface for CLIO agents to communicate with the
coordination broker.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $session_id = $args{session_id} or die "session_id required";
    my $agent_id = $args{agent_id} or die "agent_id required";
    my $task = $args{task} || "Untitled task";
    my $socket_dir = $args{socket_dir} || '/dev/shm/clio';
    
    # macOS compatibility
    if ($^O eq 'darwin' && !-d '/dev/shm') {
        $socket_dir = '/tmp/clio';
    }
    
    my $socket_path = "$socket_dir/broker-$session_id.sock";
    
    my $self = {
        session_id => $session_id,
        agent_id => $agent_id,
        task => $task,
        socket_path => $socket_path,
        socket => undef,
        buffer => '',
        debug => $args{debug} || 0,
    };
    
    bless $self, $class;
    
    $self->connect();
    
    return $self;
}

sub connect {
    my ($self) = @_;
    
    unless (-e $self->{socket_path}) {
        die "Broker socket not found: $self->{socket_path}";
    }
    
    my $sock = IO::Socket::UNIX->new(
        Type => SOCK_STREAM,
        Peer => $self->{socket_path},
    ) or die "Failed to connect to broker: $!";
    
    $sock->blocking(0);
    $self->{socket} = $sock;
    
    # Register with broker
    my $result = $self->send_and_wait({
        type => 'register',
        id => $self->{agent_id},
        task => $self->{task},
    }, 2);
    
    if ($result && $result->{type} eq 'ack' && $result->{success}) {
        $self->log_debug("Registered with broker");
        return 1;
    }
    
    die "Failed to register with broker";
}

sub disconnect {
    my ($self) = @_;
    
    return unless $self->{socket};
    
    eval {
        $self->{socket}->close();
    };
    
    $self->{socket} = undef;
    $self->log_debug("Disconnected from broker");
}

sub request_file_lock {
    my ($self, $files, $mode) = @_;
    
    $mode ||= 'write';
    
    my $result = $self->send_and_wait({
        type => 'request_file_lock',
        files => $files,
        mode => $mode,
    }, 5);
    
    if ($result && $result->{type} eq 'lock_granted') {
        $self->log_debug("File lock granted: " . join(', ', @$files));
        return 1;
    }
    elsif ($result && $result->{type} eq 'lock_denied') {
        $self->log_debug("File lock denied: " . join(', ', @$files));
        return 0;
    }
    
    return 0;
}

sub release_file_lock {
    my ($self, $files) = @_;
    
    $self->send({
        type => 'release_file_lock',
        files => $files,
    });
    
    return 1;
}

sub request_git_lock {
    my ($self) = @_;
    
    my $result = $self->send_and_wait({
        type => 'request_git_lock',
    }, 5);
    
    if ($result && $result->{type} eq 'git_lock_granted') {
        $self->log_debug("Git lock granted");
        return 1;
    }
    
    $self->log_debug("Git lock denied");
    return 0;
}

sub release_git_lock {
    my ($self) = @_;
    
    $self->send({
        type => 'release_git_lock',
    });
    
    return 1;
}

sub get_status {
    my ($self) = @_;
    
    my $result = $self->send_and_wait({
        type => 'get_status',
    }, 2);
    
    return $result;
}

sub send_discovery {
    my ($self, $content, $category) = @_;
    
    $category ||= 'general';
    
    $self->send({
        type => 'discovery',
        content => $content,
        category => $category,
    });
    
    return 1;
}

sub send_warning {
    my ($self, $content, $severity) = @_;
    
    $severity ||= 'medium';
    
    $self->send({
        type => 'warning',
        content => $content,
        severity => $severity,
    });
    
    return 1;
}

sub get_discoveries {
    my ($self) = @_;
    
    my $result = $self->send_and_wait({
        type => 'get_discoveries',
    }, 2);
    
    return $result->{discoveries} if $result && $result->{type} eq 'discoveries';
    return [];
}

sub get_warnings {
    my ($self) = @_;
    
    my $result = $self->send_and_wait({
        type => 'get_warnings',
    }, 2);
    
    return $result->{warnings} if $result && $result->{type} eq 'warnings';
    return [];
}

sub send {
    my ($self, $msg) = @_;
    
    return unless $self->{socket};
    
    my $json = encode_json($msg);
    
    eval {
        $self->{socket}->print("$json\n");
    };
    if ($@) {
        warn "Failed to send message: $@";
        return 0;
    }
    
    return 1;
}

sub send_and_wait {
    my ($self, $msg, $timeout) = @_;
    
    $timeout ||= 5;
    
    $self->send($msg) or return undef;
    
    my $select = IO::Select->new($self->{socket});
    my $deadline = time() + $timeout;
    
    while (time() < $deadline) {
        my $remaining = $deadline - time();
        $remaining = 0.1 if $remaining < 0.1;
        
        my @ready = $select->can_read($remaining);
        
        if (@ready) {
            my $data;
            my $bytes = $self->{socket}->sysread($data, 65536);
            
            if (!defined $bytes || $bytes == 0) {
                warn "Broker disconnected";
                return undef;
            }
            
            $self->{buffer} .= $data;
            
            # Process complete messages
            if ($self->{buffer} =~ s/^(.+?)\n//) {
                my $line = $1;
                my $response = eval { decode_json($line) };
                return $response if $response;
            }
        }
    }
    
    warn "Timeout waiting for broker response";
    return undef;
}

sub log_debug {
    my ($self, $msg) = @_;
    return unless $self->{debug};
    print STDERR "[DEBUG][Client][$self->{agent_id}] $msg\n";
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.
