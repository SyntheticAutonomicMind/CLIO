package CLIO::Coordination::Client;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(should_log);
use IO::Socket::UNIX;
use IO::Select;
use CLIO::Util::JSON qw(encode_json decode_json);
use Carp qw(croak);
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
    
    my $session_id = $args{session_id} or croak "session_id required";
    my $agent_id = $args{agent_id} or croak "agent_id required";
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
        croak "Broker socket not found: $self->{socket_path}";
    }
    
    my $sock = IO::Socket::UNIX->new(
        Type => SOCK_STREAM,
        Peer => $self->{socket_path},
    ) or croak "Failed to connect to broker: $!";
    
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
    
    croak "Failed to register with broker";
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

# === Message Bus Methods (Phase 2) ===

sub send_message {
    my ($self, %args) = @_;
    
    my $to = $args{to} or croak "send_message requires 'to'";
    my $content = $args{content};
    my $message_type = $args{message_type} || $args{type} || 'generic';
    
    unless (defined $content) {
        croak "send_message requires 'content'";
    }
    
    my $result = $self->send_and_wait({
        type => 'send_message',
        to => $to,
        message_type => $message_type,
        content => $content,
    }, 2);
    
    if ($result && $result->{type} eq 'ack') {
        $self->log_debug("Message sent to $to: $message_type");
        return $result->{message_id};
    }
    
    return undef;
}

sub poll_my_inbox {
    my ($self) = @_;
    
    my $result = $self->send_and_wait({
        type => 'poll_inbox',
        agent_id => $self->{agent_id},
    }, 2);
    
    if ($result && $result->{type} eq 'inbox') {
        return $result->{messages} || [];
    }
    
    return [];
}

sub poll_user_inbox {
    my ($self) = @_;
    
    my $result = $self->send_and_wait({
        type => 'poll_user_inbox',
    }, 2);
    
    if ($result && $result->{type} eq 'user_inbox') {
        return $result->{messages} || [];
    }
    
    return [];
}

sub acknowledge_messages {
    my ($self, @message_ids) = @_;
    
    my $result = $self->send_and_wait({
        type => 'acknowledge_messages',
        message_ids => \@message_ids,
    }, 2);
    
    return ($result && $result->{success}) ? 1 : 0;
}

sub get_message_history {
    my ($self) = @_;
    
    my $result = $self->send_and_wait({
        type => 'get_message_history',
    }, 2);
    
    if ($result && $result->{type} eq 'message_history') {
        return $result->{messages} || [];
    }
    
    return [];
}

sub send_status {
    my ($self, %args) = @_;
    
    my $content = {
        status => $args{status} || 'working',
        progress => $args{progress},
        current_task => $args{current_task},
        details => $args{details},
    };
    
    return $self->send_message(
        to => 'user',
        message_type => 'status',
        content => $content,
    );
}

sub send_question {
    my ($self, %args) = @_;
    
    my $to = $args{to} || 'user';
    my $question = $args{question} || $args{content};
    
    unless ($question) {
        croak "send_question requires 'question' or 'content'";
    }
    
    return $self->send_message(
        to => $to,
        message_type => 'question',
        content => $question,
    );
}

sub send_complete {
    my ($self, $content) = @_;
    
    $content ||= 'Task completed';
    
    return $self->send_message(
        to => 'user',
        message_type => 'complete',
        content => $content,
    );
}

sub send_blocked {
    my ($self, $reason) = @_;
    
    $reason ||= 'Blocked on unknown issue';
    
    return $self->send_message(
        to => 'user',
        message_type => 'blocked',
        content => $reason,
    );
}

# === End Message Bus Methods ===

# === API Rate Limiting Methods (Phase 3) ===

sub request_api_slot {
    my ($self, $request_id) = @_;
    
    $request_id ||= int(rand(1000000));
    
    my $result = $self->send_and_wait({
        type => 'request_api_slot',
        agent_id => $self->{agent_id},
        request_id => $request_id,
    }, 10);  # Longer timeout for rate limit waits
    
    if (!$result) {
        # Broker not responding - allow request to proceed
        $self->log_debug("Broker not responding for API slot request, proceeding");
        return { granted => 1, delay => 0 };
    }
    
    if ($result->{type} eq 'api_slot_granted') {
        $self->log_debug("API slot granted immediately");
        return {
            granted => 1,
            delay => 0,
            request_id => $result->{request_id},
        };
    }
    elsif ($result->{type} eq 'api_slot_wait') {
        $self->log_debug("API slot requires wait: $result->{delay}s ($result->{reason})");
        return {
            granted => 0,
            delay => $result->{delay},
            reason => $result->{reason},
            in_flight => $result->{in_flight},
            request_id => $result->{request_id},
        };
    }
    
    # Unknown response, allow request
    return { granted => 1, delay => 0 };
}

sub release_api_slot {
    my ($self, %args) = @_;
    
    my $msg = {
        type => 'release_api_slot',
        agent_id => $self->{agent_id},
        request_id => $args{request_id} || 0,
        status => $args{status},
        retry_after => $args{retry_after},
    };
    
    # Include rate limit headers if provided
    if ($args{headers}) {
        $msg->{headers} = $args{headers};
    }
    
    my $result = $self->send_and_wait($msg, 2);
    
    return ($result && $result->{success}) ? 1 : 0;
}

sub get_rate_limit_status {
    my ($self) = @_;
    
    my $result = $self->send_and_wait({
        type => 'get_rate_limit_status',
    }, 2);
    
    if ($result && $result->{type} eq 'rate_limit_status') {
        return $result;
    }
    
    return {
        can_request => 1,
        in_flight => 0,
    };
}

sub wait_for_api_slot {
    my ($self, $max_wait) = @_;
    
    $max_wait ||= 120;  # Default 2 minute max wait
    my $start = time();
    my $request_id = int(rand(1000000));
    
    while (time() - $start < $max_wait) {
        my $result = $self->request_api_slot($request_id);
        
        if ($result->{granted}) {
            return {
                success => 1,
                request_id => $request_id,
                waited => time() - $start,
            };
        }
        
        # Need to wait
        my $delay = $result->{delay} || 0.5;
        $delay = 30 if $delay > 30;  # Cap individual waits at 30s
        
        $self->log_debug("Waiting ${delay}s for API slot (reason: $result->{reason})");
        sleep($delay);
    }
    
    # Timeout - return failure but include request_id so caller can proceed anyway
    return {
        success => 0,
        request_id => $request_id,
        waited => time() - $start,
        reason => 'timeout',
    };
}

# === End API Rate Limiting Methods ===


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
    CLIO::Core::Logger::log_debug('Client', "[$self->{agent_id}] $msg");
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.
