# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Coordination::Client;

use strict;
use warnings;
use utf8;
use IO::Socket::UNIX;
use IO::Select;
use CLIO::Util::JSON qw(encode_json decode_json safe_decode_json);
use Carp qw(croak);
use Time::HiRes qw(time sleep);
require CLIO::Core::Logger;


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
    my ($self, $request_id, %opts) = @_;

    $request_id ||= int(rand(1000000));

    my $msg = {
        type => 'request_api_slot',
        agent_id => $self->{agent_id},
        request_id => $request_id,
    };
    # Optional ITPM context. When provided, the broker checks the
    # aggregate per-model input-token sliding window (across all
    # connected agents) and may delay the slot beyond pure RPM gates.
    $msg->{model}          = $opts{model}          if defined $opts{model};
    $msg->{pending_tokens} = $opts{pending_tokens} if defined $opts{pending_tokens};

    my $result = $self->send_and_wait($msg, 10);  # Longer timeout for rate limit waits

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

# Fire-and-forget report of an API request's ITPM-relevant input tokens.
# Used by APIManager after each response completes to feed the broker's
# per-model sliding window so cross-agent ITPM coordination sees this
# agent's actual consumption. Cache reads are NOT included - Anthropic
# uncached ITPM only counts input_tokens + cache_creation_input_tokens.
sub report_api_tokens {
    my ($self, %args) = @_;

    my $msg = {
        type => 'report_api_tokens',
        agent_id => $self->{agent_id},
    };
    $msg->{model}                      = $args{model}                      if defined $args{model};
    $msg->{input_tokens}               = $args{input_tokens}               if defined $args{input_tokens};
    $msg->{cache_creation_input_tokens} = $args{cache_creation_input_tokens} if defined $args{cache_creation_input_tokens};

    return $self->send($msg);
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

    # Include raw HTTP response headers so the broker can refresh its
    # x-ratelimit-* snapshot.
    if ($args{headers}) {
        $msg->{headers} = $args{headers};
    }
    # Forward Anthropic ITPM/OTPM/RPM headers (parsed rate_limit_info
    # from ResponseHandler.process_rate_limit_headers). Lets the broker
    # maintain the same per-model Anthropic snapshot the agent sees, so
    # future slot requests from any agent get the precise ITPM-aware
    # delay instead of falling back to the learned ceiling.
    if ($args{model} && ref($args{anthropic_rate_limit_info}) eq 'HASH') {
        $msg->{model}                       = $args{model};
        $msg->{anthropic_rate_limit_info}   = $args{anthropic_rate_limit_info};
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

# Send a status_update to the broker for OSC forwarding to primary agent
# Used by child agents in puppeteer mode to report their state
sub send_status_update {
    my ($self, %args) = @_;
    
    my $msg = {
        type     => 'status_update',
        agent_id => $self->{agent_id},
        state    => $args{state} || 'unknown',
    };
    $msg->{tool}    = $args{tool}    if $args{tool};
    $msg->{message} = $args{message} if $args{message};
    
    # Fire-and-forget (don't block on ack)
    return $self->send($msg);
}

# Poll the broker for status_updates from child agents
# Used by primary agent to collect updates for OSC re-emission
sub poll_status_updates {
    my ($self) = @_;
    
    my $result = $self->send_and_wait({
        type => 'poll_status_updates',
    }, 2);
    
    if ($result && $result->{type} eq 'status_updates') {
        return $result->{updates} || [];
    }
    
    return [];
}

sub wait_for_api_slot {
    my ($self, $max_wait, %opts) = @_;

    $max_wait ||= 120;  # Default 2 minute max wait
    my $start = time();
    my $request_id = int(rand(1000000));

    while (time() - $start < $max_wait) {
        my $result = $self->request_api_slot($request_id, %opts);

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

# === Authorization Relay Methods ===

# Send an authorization request through the broker and wait for user response
# Used by child agents when they hit a security prompt with no TTY
sub request_authorization {
    my ($self, %args) = @_;
    
    my $result = $self->send_and_wait({
        type        => 'authorization_request',
        request_id  => $args{request_id},
        agent_id    => $args{agent_id} || $self->{agent_id},
        category    => $args{category},
        description => $args{description},
        risk_level  => $args{risk_level},
        flags       => $args{flags},
        options     => $args{options},
    }, $args{timeout} || 60);
    
    return $result;
}

# Send an authorization response back through the broker
# Used by primary session after getting user input
sub send_authorization_response {
    my ($self, %args) = @_;
    
    return $self->send_and_wait({
        type        => 'authorization_response',
        request_id  => $args{request_id},
        approved    => $args{approved},
        grant_type  => $args{grant_type},
    }, 5);
}

# === End Authorization Relay Methods ===

# === Activity Streaming Methods ===

# Send a tool activity event to the broker
# Used by child agents to stream tool execution events for real-time monitoring
sub send_activity {
    my ($self, $action, $tool, $detail) = @_;

    my $msg = {
        type      => 'activity_stream',
        agent_id  => $self->{agent_id},
        action    => $action || 'unknown',
    };
    $msg->{tool_name} = $tool   if defined $tool;
    $msg->{detail}    = $detail if defined $detail;

    # Fire-and-forget (don't block on ack)
    return $self->send($msg);
}

# Poll the broker for accumulated activity log entries
# Used by primary agent to collect tool events from all child agents
sub poll_activity {
    my ($self) = @_;

    my $result = $self->send_and_wait({
        type => 'poll_activity',
    }, 2);

    if ($result && $result->{type} eq 'activity') {
        return $result->{entries} || [];
    }

    return [];
}

# === End Activity Streaming Methods ===


sub send {
    my ($self, $msg) = @_;
    
    return 0 if $self->{_disconnected};
    return 0 unless $self->{socket};
    
    my $json = encode_json($msg);
    my $data = "$json\n";
    
    eval {
        # Must use blocking write to ensure complete delivery.
        # Non-blocking print() does short writes on large messages,
        # leaving partial JSON that the broker can never parse.
        $self->{socket}->blocking(1);
        my $offset = 0;
        my $len = length($data);
        while ($offset < $len) {
            my $written = syswrite($self->{socket}, $data, $len - $offset, $offset);
            if (!defined $written) {
                croak "syswrite failed: $!";
            }
            $offset += $written;
        }
        $self->{socket}->blocking(0);
    };
    if ($@) {
        eval { $self->{socket}->blocking(0) };  # Restore non-blocking on error
        CLIO::Core::Logger::log_debug("BrokerClient", "Failed to send message: $@");
        return 0;
    }
    
    return 1;
}

sub reconnect {
    my ($self) = @_;
    
    # Close old socket if any
    eval { $self->{socket}->close() } if $self->{socket};
    $self->{socket} = undef;
    $self->{buffer} = '';
    
    # Try to reconnect
    eval { $self->connect() };
    if ($@) {
        $self->{_disconnected} = 1;
        return 0;
    }
    
    $self->{_disconnected} = 0;
    CLIO::Core::Logger::log_debug("BrokerClient", "Reconnected to broker");
    return 1;
}

sub send_and_wait {
    my ($self, $msg, $timeout) = @_;
    
    $timeout ||= 5;
    
    # Circuit breaker: don't attempt if known disconnected
    return undef if $self->{_disconnected};
    
    $self->send($msg) or return undef;
    
    my $select = IO::Select->new($self->{socket});
    my $deadline = time() + $timeout;
    my $reconnect_attempted = 0;
    
    while (time() < $deadline) {
        my $remaining = $deadline - time();
        $remaining = 0.1 if $remaining < 0.1;
        
        my @ready = $select->can_read($remaining);
        
        if (@ready) {
            my $data;
            my $bytes = $self->{socket}->sysread($data, 65536);
            
            if (!defined $bytes || $bytes == 0) {
                # Broker disconnected - try to reconnect once only
                if (!$reconnect_attempted && $self->reconnect()) {
                    $reconnect_attempted = 1;
                    $self->send($msg) or return undef;
                    $select = IO::Select->new($self->{socket});
                    $deadline = time() + $timeout;
                    next;
                }
                # Reconnect already tried or failed - circuit breaker
                $self->{_disconnected} = 1;
                return undef;
            }
            
            $self->{buffer} .= $data;
            
            # Process complete messages
            if ($self->{buffer} =~ s/^(.+?\n)//) {
                my $line = $1;
                chomp $line;
                my $response = safe_decode_json($line);
                return $response if $response;
            }
        }
    }
    
    CLIO::Core::Logger::log_debug("BrokerClient", "Timeout waiting for broker response");
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

1;
