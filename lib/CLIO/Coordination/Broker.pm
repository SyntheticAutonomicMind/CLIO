package CLIO::Coordination::Broker;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(should_log);
use IO::Socket::UNIX;
use IO::Select;
use CLIO::Util::JSON qw(encode_json decode_json);
use Time::HiRes qw(time);
use POSIX qw(strftime);
use Carp qw(croak);
use File::Path qw(make_path);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::Coordination::Broker - Multi-agent coordination server

=head1 DESCRIPTION

A Unix socket-based coordination server that allows multiple CLIO agents
to work in parallel on the same codebase without conflicts.

Provides:
- File locking (prevent concurrent edits)
- Git coordination (serialize commits)
- Knowledge sharing (discoveries, warnings)
- Agent status tracking

Based on the proven PhotonMUD broker architecture.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $session_id = $args{session_id} or croak "session_id required";
    my $socket_dir = $args{socket_dir} || '/dev/shm/clio';
    
    # macOS uses /tmp instead of /dev/shm
    if ($^O eq 'darwin' && !-d '/dev/shm') {
        $socket_dir = '/tmp/clio';
    }
    
    my $socket_path = "$socket_dir/broker-$session_id.sock";
    
    my $self = {
        session_id => $session_id,
        socket_dir => $socket_dir,
        socket_path => $socket_path,
        max_clients => $args{max_clients} || 10,
        debug => $args{debug} || 0,
        
        # State tracking
        server => undef,
        select => undef,
        clients => {},
        file_locks => {},
        git_lock => {
            holder => undef,
            files => [],
            locked_at => 0,
        },
        agent_status => {},
        discoveries => [],
        warnings => [],
        next_lock_id => 1,
        
        # Message bus (Phase 2)
        agent_inboxes => {},  # agent_id => [@messages]
        user_inbox => [],     # Messages for user (unread)
        user_inbox_history => [],  # All messages ever sent to user (read + unread)
        next_msg_id => 1,
        
        # API Rate Limiting (Phase 3)
        # Modeled after VSCode's RequestRateLimiter
        api_rate_limit => {
            max_parallel => $args{max_parallel_api} || 2,  # Max concurrent API requests
            min_delay => 0.025,  # Minimum 25ms between requests (40/sec limit)
            last_request_time => 0,
            in_flight => 0,  # Current number of requests in progress
            queue => [],     # Waiting requests: [{agent_id, request_id, queued_at}]
            
            # Rate limit state from response headers
            remaining => undef,    # x-ratelimit-remaining
            reset_at => undef,     # x-ratelimit-reset (unix timestamp)
            retry_after => undef,  # retry-after header value
            retry_until => 0,      # Don't send requests until this time
            
            # Quota tracking
            quota_used => undef,   # x-github-total-quota-used percentage
            quota_timestamp => 0,
            target_quota => 80,    # Start throttling above this %
        },
    };
    
    return bless $self, $class;
}

sub run {
    my ($self) = @_;
    
    eval {
        $self->init();
        $self->log_info("Broker initialized successfully");
        $self->event_loop();
    };
    if ($@) {
        $self->log_warn("Broker fatal error: $@");
        die $@;
    }
}

sub init {
    my ($self) = @_;
    
    $self->log_info("CLIO Coordination Broker starting...");
    $self->log_info("Session: $self->{session_id}");
    
    # Ensure socket directory exists
    unless (-d $self->{socket_dir}) {
        make_path($self->{socket_dir}, { mode => 0777 });
    }
    chmod 0777, $self->{socket_dir};
    
    # Clean up stale socket
    unlink $self->{socket_path} if -e $self->{socket_path};
    
    # Create listening socket
    my $server = IO::Socket::UNIX->new(
        Type   => SOCK_STREAM,
        Local  => $self->{socket_path},
        Listen => $self->{max_clients},
    ) or die "Cannot create socket at $self->{socket_path}: $!";
    
    chmod 0777, $self->{socket_path};
    
    $self->{server} = $server;
    $self->{select} = IO::Select->new($server);
    
    $self->log_info("Broker listening on $self->{socket_path}");
}

1;

sub event_loop {
    my ($self) = @_;
    
    my $last_maintenance = time();
    
    # Install signal handlers
    local $SIG{PIPE} = 'IGNORE';  # Ignore broken pipes
    local $SIG{CHLD} = 'IGNORE';  # Ignore child process signals
    
    while (1) {
        # Wrap in eval to catch any errors
        eval {
            my @ready = $self->{select}->can_read(1);
            
            foreach my $fh (@ready) {
                if ($fh == $self->{server}) {
                    $self->accept_client();
                } else {
                    $self->handle_client_data($fh);
                }
            }
            
            if (time() - $last_maintenance > 10) {
                $self->do_maintenance();
                $last_maintenance = time();
            }
        };
        if ($@) {
            $self->log_warn("Event loop error: $@");
            # Continue running despite errors
        }
    }
}

sub accept_client {
    my ($self) = @_;
    
    my $client = $self->{server}->accept();
    return unless $client;
    
    $client->blocking(0);
    $self->{select}->add($client);
    
    my $fd = fileno($client);
    $self->{clients}{$fd} = {
        socket => $client,
        type => undef,
        id => undef,
        task => undef,
        last_activity => time(),
        buffer => '',
    };
    
    $self->log_debug("New connection: fd=$fd");
}

sub handle_client_data {
    my ($self, $client) = @_;
    
    my $fd = fileno($client);
    return unless exists $self->{clients}{$fd};
    
    my $data;
    my $bytes;
    
    # Wrap sysread in eval to catch errors
    eval {
        $bytes = $client->sysread($data, 65536);
    };
    if ($@) {
        $self->log_warn("sysread error for fd=$fd: $@");
        $self->handle_disconnect($fd);
        return;
    }
    
    if (!defined $bytes || $bytes == 0) {
        $self->handle_disconnect($fd);
        return;
    }
    
    $self->{clients}{$fd}{buffer} .= $data;
    $self->{clients}{$fd}{last_activity} = time();
    
    # Process complete messages with error handling
    while ($self->{clients}{$fd} && $self->{clients}{$fd}{buffer} =~ s/^(.+?)\n//) {
        my $line = $1;
        eval {
            my $msg = decode_json($line);
            $self->handle_message($fd, $msg);
        };
        if ($@) {
            $self->log_warn("Invalid JSON from fd=$fd: $@");
            $self->send_error($fd, "Invalid JSON");
        }
    }
}

sub handle_disconnect {
    my ($self, $fd) = @_;
    
    return unless exists $self->{clients}{$fd};
    
    my $client_info = $self->{clients}{$fd};
    my $agent_id = $client_info->{id};
    
    if ($agent_id) {
        $self->release_all_agent_locks($agent_id);
        delete $self->{agent_status}{$agent_id};
        $self->log_info("Agent disconnected: $agent_id");
    }
    
    $self->{select}->remove($client_info->{socket});
    $client_info->{socket}->close();
    delete $self->{clients}{$fd};
}


sub handle_message {
    my ($self, $fd, $msg) = @_;
    
    my $type = $msg->{type} || 'unknown';
    
    if ($type eq 'register') {
        $self->handle_register($fd, $msg);
    }
    elsif ($type eq 'request_file_lock') {
        $self->handle_request_file_lock($fd, $msg);
    }
    elsif ($type eq 'release_file_lock') {
        $self->handle_release_file_lock($fd, $msg);
    }
    elsif ($type eq 'request_git_lock') {
        $self->handle_request_git_lock($fd, $msg);
    }
    elsif ($type eq 'release_git_lock') {
        $self->handle_release_git_lock($fd, $msg);
    }
    elsif ($type eq 'heartbeat') {
        $self->handle_heartbeat($fd);
    }
    elsif ($type eq 'discovery') {
        $self->handle_discovery($fd, $msg);
    }
    elsif ($type eq 'warning') {
        $self->handle_warning($fd, $msg);
    }
    elsif ($type eq 'get_discoveries') {
        $self->handle_get_discoveries($fd);
    }
    elsif ($type eq 'get_warnings') {
        $self->handle_get_warnings($fd);
    }
    elsif ($type eq 'get_status') {
        $self->handle_get_status($fd);
    }
    elsif ($type eq 'send_message') {
        $self->handle_send_message($fd, $msg);
    }
    elsif ($type eq 'poll_inbox') {
        $self->handle_poll_inbox($fd, $msg);
    }
    elsif ($type eq 'poll_user_inbox') {
        $self->handle_poll_user_inbox($fd);
    }
    elsif ($type eq 'acknowledge_messages') {
        $self->handle_acknowledge_messages($fd, $msg);
    }
    elsif ($type eq 'get_message_history') {
        $self->handle_get_message_history($fd);
    }
    # API Rate Limiting (Phase 3)
    elsif ($type eq 'request_api_slot') {
        $self->handle_request_api_slot($fd, $msg);
    }
    elsif ($type eq 'release_api_slot') {
        $self->handle_release_api_slot($fd, $msg);
    }
    elsif ($type eq 'get_rate_limit_status') {
        $self->handle_get_rate_limit_status($fd);
    }
    else {
        $self->send_error($fd, "Unknown message type: $type");
    }
}

sub handle_register {
    my ($self, $fd, $msg) = @_;
    
    my $agent_id = $msg->{id};
    my $task = $msg->{task};
    
    unless ($agent_id) {
        $self->send_error($fd, "Registration requires 'id'");
        return;
    }
    
    $self->{clients}{$fd}{type} = 'agent';
    $self->{clients}{$fd}{id} = $agent_id;
    $self->{clients}{$fd}{task} = $task;
    
    $self->{agent_status}{$agent_id} = {
        task => $task,
        status => 'registered',
        files => [],
    };
    
    $self->log_info("Agent registered: $agent_id");
    
    $self->send_message($fd, {
        type => 'ack',
        request_type => 'register',
        success => JSON::PP::true,
    });
}

sub handle_request_file_lock {
    my ($self, $fd, $msg) = @_;
    
    my $agent_id = $self->{clients}{$fd}{id};
    unless ($agent_id) {
        $self->send_error($fd, "Not registered");
        return;
    }
    
    my $files = $msg->{files};
    my $mode = $msg->{mode} || 'write';
    
    unless ($files && ref($files) eq 'ARRAY' && @$files) {
        $self->send_error($fd, "request_file_lock requires 'files' array");
        return;
    }
    
    # Check if any file is locked by another agent
    my @blocked_files;
    for my $file (@$files) {
        if (exists $self->{file_locks}{$file}) {
            my $lock = $self->{file_locks}{$file};
            if ($lock->{owner} ne $agent_id) {
                push @blocked_files, { file => $file, held_by => $lock->{owner} };
            }
        }
    }
    
    if (@blocked_files) {
        $self->send_message($fd, {
            type => 'lock_denied',
            files => $files,
            blocked => \@blocked_files,
        });
        return;
    }
    
    # Grant locks
    my $lock_id = $self->{next_lock_id}++;
    for my $file (@$files) {
        $self->{file_locks}{$file} = {
            owner => $agent_id,
            mode => $mode,
            locked_at => time(),
            lock_id => $lock_id,
        };
    }
    
    $self->log_debug("File lock granted to $agent_id: " . join(', ', @$files));
    
    $self->send_message($fd, {
        type => 'lock_granted',
        files => $files,
        lock_id => $lock_id,
    });
}

sub handle_release_file_lock {
    my ($self, $fd, $msg) = @_;
    
    my $agent_id = $self->{clients}{$fd}{id};
    my $files = $msg->{files};
    
    unless ($files && ref($files) eq 'ARRAY') {
        $self->send_error($fd, "release_file_lock requires 'files' array");
        return;
    }
    
    for my $file (@$files) {
        if (exists $self->{file_locks}{$file}) {
            my $lock = $self->{file_locks}{$file};
            if ($lock->{owner} eq $agent_id) {
                delete $self->{file_locks}{$file};
                $self->log_debug("File lock released by $agent_id: $file");
            }
        }
    }
    
    $self->send_message($fd, {
        type => 'ack',
        request_type => 'release_file_lock',
        files => $files,
    });
}

sub handle_request_git_lock {
    my ($self, $fd, $msg) = @_;
    
    my $agent_id = $self->{clients}{$fd}{id};
    unless ($agent_id) {
        $self->send_error($fd, "Not registered");
        return;
    }
    
    # Check if git lock is available
    if ($self->{git_lock}{holder}) {
        $self->send_message($fd, {
            type => 'git_lock_denied',
            held_by => $self->{git_lock}{holder},
        });
        return;
    }
    
    # Grant git lock
    my $lock_id = $self->{next_lock_id}++;
    $self->{git_lock} = {
        holder => $agent_id,
        locked_at => time(),
        lock_id => $lock_id,
    };
    
    $self->log_debug("Git lock granted to $agent_id");
    
    $self->send_message($fd, {
        type => 'git_lock_granted',
        lock_id => $lock_id,
    });
}

sub handle_release_git_lock {
    my ($self, $fd, $msg) = @_;
    
    my $agent_id = $self->{clients}{$fd}{id};
    
    if ($self->{git_lock}{holder} && $self->{git_lock}{holder} eq $agent_id) {
        $self->{git_lock} = {
            holder => undef,
            locked_at => 0,
        };
        $self->log_debug("Git lock released by $agent_id");
    }
    
    $self->send_message($fd, {
        type => 'ack',
        request_type => 'release_git_lock',
    });
}

sub handle_heartbeat {
    my ($self, $fd) = @_;
    
    $self->{clients}{$fd}{last_activity} = time();
    
    $self->send_message($fd, {
        type => 'heartbeat_ack',
    });
}

sub handle_discovery {
    my ($self, $fd, $msg) = @_;
    
    my $agent_id = $self->{clients}{$fd}{id};
    return unless $agent_id;
    
    my $discovery = {
        agent => $agent_id,
        timestamp => time(),
        category => $msg->{category} || 'general',
        content => $msg->{content},
    };
    
    push @{$self->{discoveries}}, $discovery;
    
    $self->log_info("Discovery from $agent_id [$discovery->{category}]: $msg->{content}");
    
    # Acknowledge
    $self->send_message($fd, {
        type => 'ack',
        request_type => 'discovery',
    });
}

sub handle_warning {
    my ($self, $fd, $msg) = @_;
    
    my $agent_id = $self->{clients}{$fd}{id};
    return unless $agent_id;
    
    my $warning = {
        agent => $agent_id,
        timestamp => time(),
        severity => $msg->{severity} || 'medium',
        content => $msg->{content},
    };
    
    push @{$self->{warnings}}, $warning;
    
    $self->log_warn("Warning from $agent_id [$warning->{severity}]: $msg->{content}");
    
    # Acknowledge
    $self->send_message($fd, {
        type => 'ack',
        request_type => 'warning',
    });
}

sub handle_get_discoveries {
    my ($self, $fd) = @_;
    
    $self->send_message($fd, {
        type => 'discoveries',
        discoveries => $self->{discoveries},
        count => scalar(@{$self->{discoveries}}),
    });
}

sub handle_get_warnings {
    my ($self, $fd) = @_;
    
    $self->send_message($fd, {
        type => 'warnings',
        warnings => $self->{warnings},
        count => scalar(@{$self->{warnings}}),
    });
}

sub handle_get_status {
    my ($self, $fd) = @_;
    
    $self->send_message($fd, {
        type => 'status',
        agents => $self->{agent_status},
        file_locks => $self->{file_locks},
        git_lock => $self->{git_lock},
        discoveries => $self->{discoveries},
        warnings => $self->{warnings},
    });
}

sub handle_send_message {
    my ($self, $fd, $msg) = @_;
    
    my $sender = $self->{clients}{$fd}{id};
    unless ($sender) {
        $self->send_error($fd, "Not registered");
        return;
    }
    
    my $recipient = $msg->{to};
    my $message_type = $msg->{message_type} || 'generic';
    my $content = $msg->{content};
    
    unless ($recipient && defined $content) {
        $self->send_error($fd, "send_message requires 'to' and 'content'");
        return;
    }
    
    # Create message envelope
    my $message = {
        id => $self->{next_msg_id}++,
        from => $sender,
        to => $recipient,
        type => $message_type,
        content => $content,
        timestamp => time(),
    };
    
    # Route message to appropriate inbox
    if ($recipient eq 'user') {
        push @{$self->{user_inbox}}, $message;
        push @{$self->{user_inbox_history}}, $message;  # Keep in history
        $self->log_debug("Message from $sender to user: $message_type");
    }
    elsif ($recipient eq 'all') {
        # Broadcast to all agents
        for my $agent_id (keys %{$self->{agent_status}}) {
            next if $agent_id eq $sender;  # Don't send to self
            $self->{agent_inboxes}{$agent_id} ||= [];
            push @{$self->{agent_inboxes}{$agent_id}}, $message;
        }
        $self->log_debug("Broadcast from $sender to all agents");
    }
    else {
        # Direct message to specific agent
        $self->{agent_inboxes}{$recipient} ||= [];
        push @{$self->{agent_inboxes}{$recipient}}, $message;
        $self->log_debug("Message from $sender to $recipient: $message_type");
    }
    
    # Acknowledge
    $self->send_message($fd, {
        type => 'ack',
        request_type => 'send_message',
        message_id => $message->{id},
    });
}

sub handle_poll_inbox {
    my ($self, $fd, $msg) = @_;
    
    my $agent_id = $msg->{agent_id};
    unless ($agent_id) {
        $self->send_error($fd, "poll_inbox requires 'agent_id'");
        return;
    }
    
    # Get messages for this agent
    my $inbox = $self->{agent_inboxes}{$agent_id} || [];
    my @messages = @$inbox;
    
    # Clear inbox after retrieval
    $self->{agent_inboxes}{$agent_id} = [];
    
    $self->log_debug("Agent $agent_id polled inbox: " . scalar(@messages) . " messages");
    
    $self->send_message($fd, {
        type => 'inbox',
        messages => \@messages,
        count => scalar(@messages),
    });
}

sub handle_poll_user_inbox {
    my ($self, $fd) = @_;
    
    # Get unread messages (don't clear - let acknowledge_messages do that)
    my @messages = @{$self->{user_inbox}};
    
    $self->log_debug("User polled inbox: " . scalar(@messages) . " unread messages");
    
    $self->send_message($fd, {
        type => 'user_inbox',
        messages => \@messages,
        count => scalar(@messages),
    });
}

sub handle_acknowledge_messages {
    my ($self, $fd, $msg) = @_;
    
    my $message_ids = $msg->{message_ids} || [];  # Optional: specific IDs to acknowledge
    
    if (@$message_ids) {
        # Acknowledge specific messages
        my %ids_to_ack = map { $_ => 1 } @$message_ids;
        my @remaining;
        for my $m (@{$self->{user_inbox}}) {
            if ($ids_to_ack{$m->{id}}) {
                $self->log_debug("Acknowledged message: $m->{id}");
            } else {
                push @remaining, $m;
            }
        }
        $self->{user_inbox} = \@remaining;
    } else {
        # Acknowledge all messages
        my $count = scalar(@{$self->{user_inbox}});
        $self->{user_inbox} = [];
        $self->log_debug("Acknowledged all $count messages");
    }
    
    $self->send_message($fd, {
        type => 'acknowledge_result',
        success => 1,
    });
}

sub handle_get_message_history {
    my ($self, $fd) = @_;
    
    # Return all messages ever sent to user (both read and unread)
    my @messages = @{$self->{user_inbox_history}};
    
    $self->log_debug("User requested history: " . scalar(@messages) . " total messages");
    
    $self->send_message($fd, {
        type => 'message_history',
        messages => \@messages,
        count => scalar(@messages),
    });
}

sub release_all_agent_locks {
    my ($self, $agent_id) = @_;
    
    # Release file locks
    for my $file (keys %{$self->{file_locks}}) {
        if ($self->{file_locks}{$file}{owner} eq $agent_id) {
            delete $self->{file_locks}{$file};
            $self->log_debug("Auto-released file lock: $file");
        }
    }
    
    # Release git lock
    if ($self->{git_lock}{holder} && $self->{git_lock}{holder} eq $agent_id) {
        $self->{git_lock} = {
            holder => undef,
            locked_at => 0,
        };
        $self->log_debug("Auto-released git lock");
    }
}

sub do_maintenance {
    my ($self) = @_;
    
    my $now = time();
    my $timeout = 120;
    
    for my $fd (keys %{$self->{clients}}) {
        my $client = $self->{clients}{$fd};
        if ($now - $client->{last_activity} > $timeout) {
            $self->log_warn("Client timeout: fd=$fd");
            $self->handle_disconnect($fd);
        }
    }
}

sub send_message {
    my ($self, $fd, $msg) = @_;
    
    return unless exists $self->{clients}{$fd};
    
    my $json = encode_json($msg);
    my $socket = $self->{clients}{$fd}{socket};
    
    eval {
        $socket->print("$json\n");
    };
    if ($@) {
        $self->log_warn("Failed to send to fd=$fd: $@");
        # Don't disconnect here - let the next read detect the problem
    }
}

sub send_error {
    my ($self, $fd, $message) = @_;
    
    $self->send_message($fd, {
        type => 'error',
        message => $message,
    });
}

# =============================================================================
# API Rate Limiting Handlers (Phase 3)
# Implements VSCode-style request queuing and rate limit coordination
# =============================================================================

sub handle_request_api_slot {
    my ($self, $fd, $msg) = @_;
    
    my $agent_id = $msg->{agent_id} || 'unknown';
    my $request_id = $msg->{request_id} || int(rand(1000000));
    my $rl = $self->{api_rate_limit};
    my $now = time();
    
    # Calculate required delay
    my $delay = $self->_calculate_api_delay();
    
    # Check if we can grant immediately
    if ($rl->{in_flight} < $rl->{max_parallel} && $delay <= 0) {
        $rl->{in_flight}++;
        $rl->{last_request_time} = $now;
        
        $self->log_debug("API slot granted immediately to $agent_id (in_flight: $rl->{in_flight})");
        
        $self->send_message($fd, {
            type => 'api_slot_granted',
            request_id => $request_id,
            delay => 0,
        });
        return;
    }
    
    # Need to wait - calculate total delay
    my $wait_for_slot = 0;
    if ($rl->{in_flight} >= $rl->{max_parallel}) {
        # Estimate when a slot will free up (average request takes ~2-5 seconds)
        $wait_for_slot = 0.5;  # Small delay, will re-check
    }
    
    my $total_delay = $delay > 0 ? $delay : $wait_for_slot;
    $total_delay = 0.1 if $total_delay < 0.1;  # Minimum 100ms
    
    $self->log_debug("API slot delayed for $agent_id: ${total_delay}s (in_flight: $rl->{in_flight}, delay: $delay)");
    
    $self->send_message($fd, {
        type => 'api_slot_wait',
        request_id => $request_id,
        delay => $total_delay,
        in_flight => $rl->{in_flight},
        reason => $delay > 0 ? 'rate_limit' : 'max_parallel',
    });
}

sub handle_release_api_slot {
    my ($self, $fd, $msg) = @_;
    
    my $agent_id = $msg->{agent_id} || 'unknown';
    my $request_id = $msg->{request_id} || 0;
    my $rl = $self->{api_rate_limit};
    
    # Decrement in-flight counter
    $rl->{in_flight}-- if $rl->{in_flight} > 0;
    
    # Update rate limit state from response headers if provided
    if ($msg->{headers}) {
        my $h = $msg->{headers};
        
        # Parse x-ratelimit-remaining
        if (defined $h->{'x-ratelimit-remaining'}) {
            $rl->{remaining} = int($h->{'x-ratelimit-remaining'});
        }
        
        # Parse x-ratelimit-reset (Unix timestamp)
        if (defined $h->{'x-ratelimit-reset'}) {
            $rl->{reset_at} = int($h->{'x-ratelimit-reset'});
        }
        
        # Parse retry-after header
        if (defined $h->{'retry-after'}) {
            my $retry = $h->{'retry-after'};
            # Could be seconds or HTTP date
            if ($retry =~ /^\d+$/) {
                $rl->{retry_until} = time() + $retry;
                $rl->{retry_after} = $retry;
            }
        }
        
        # Parse quota used percentage
        if (defined $h->{'x-github-total-quota-used'}) {
            $rl->{quota_used} = $h->{'x-github-total-quota-used'};
            $rl->{quota_timestamp} = time();
        }
        
        $self->log_debug("Updated rate limit state: remaining=" . ($rl->{remaining} // 'N/A') . 
                        ", reset=" . ($rl->{reset_at} // 'N/A') . 
                        ", quota=" . ($rl->{quota_used} // 'N/A') . "%");
    }
    
    # Handle error responses
    if ($msg->{status} && $msg->{status} == 429) {
        # Rate limited - set retry_until from retry-after or default 60s
        my $retry_delay = $msg->{retry_after} || 60;
        $rl->{retry_until} = time() + $retry_delay;
        $self->log_info("Rate limit hit by $agent_id, blocking requests for ${retry_delay}s");
    }
    
    $self->log_debug("API slot released by $agent_id (in_flight: $rl->{in_flight})");
    
    $self->send_message($fd, {
        type => 'ack',
        success => 1,
    });
}

sub handle_get_rate_limit_status {
    my ($self, $fd) = @_;
    
    my $rl = $self->{api_rate_limit};
    my $now = time();
    
    $self->send_message($fd, {
        type => 'rate_limit_status',
        in_flight => $rl->{in_flight},
        max_parallel => $rl->{max_parallel},
        remaining => $rl->{remaining},
        reset_at => $rl->{reset_at},
        retry_until => $rl->{retry_until},
        quota_used => $rl->{quota_used},
        can_request => ($rl->{in_flight} < $rl->{max_parallel} && $now >= $rl->{retry_until}),
    });
}

sub _calculate_api_delay {
    my ($self) = @_;
    
    my $rl = $self->{api_rate_limit};
    my $now = time();
    my $delay = 0;
    
    # Check retry_until (rate limit cooldown)
    if ($rl->{retry_until} > $now) {
        $delay = $rl->{retry_until} - $now;
        return $delay;
    }
    
    # Check minimum delay between requests (abuse prevention)
    my $elapsed = $now - $rl->{last_request_time};
    if ($elapsed < $rl->{min_delay}) {
        $delay = $rl->{min_delay} - $elapsed;
    }
    
    # Check remaining requests in window
    if (defined $rl->{remaining} && $rl->{remaining} <= $rl->{in_flight}) {
        # No remaining requests, wait until reset
        if (defined $rl->{reset_at} && $rl->{reset_at} > $now) {
            my $reset_delay = $rl->{reset_at} - $now;
            $delay = $reset_delay if $reset_delay > $delay;
        }
    }
    
    # Quota-based throttling (like VSCode)
    if (defined $rl->{quota_used} && $rl->{quota_used} > $rl->{target_quota}) {
        my $quota_delta = $rl->{quota_used} - $rl->{target_quota};
        my $time_since_quota = $now - $rl->{quota_timestamp};
        
        # Decay time - assume quota decays over ~60 seconds
        my $decay_time = 60;
        my $max_quota_delay = 5;  # Max 5s delay from quota
        
        my $quota_adjustment = ($quota_delta / (100 - $rl->{target_quota}));
        $quota_adjustment *= (1.0 - ($time_since_quota / $decay_time)) if $time_since_quota < $decay_time;
        $quota_adjustment = 0 if $quota_adjustment < 0;
        
        my $quota_delay = $quota_adjustment * $max_quota_delay;
        $delay = $quota_delay if $quota_delay > $delay;
    }
    
    return $delay;
}

sub log_info {
    my ($self, $msg) = @_;
    CLIO::Core::Logger::log_info('Broker', $msg);
}

sub log_warn {
    my ($self, $msg) = @_;
    CLIO::Core::Logger::log_warning('Broker', $msg);
}

sub log_debug {
    my ($self, $msg) = @_;
    return unless $self->{debug};
    CLIO::Core::Logger::log_debug('Broker', $msg);
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.

