package CLIO::Coordination::Broker;

use strict;
use warnings;
use utf8;
use IO::Socket::UNIX;
use IO::Select;
use JSON::PP qw(encode_json decode_json);
use Time::HiRes qw(time);
use POSIX qw(strftime);
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
    
    my $session_id = $args{session_id} or die "session_id required";
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

sub log_info {
    my ($self, $msg) = @_;
    my $ts = strftime("%Y-%m-%d %H:%M:%S", localtime);
    print STDERR "[INFO][$ts][Broker] $msg\n";
}

sub log_warn {
    my ($self, $msg) = @_;
    my $ts = strftime("%Y-%m-%d %H:%M:%S", localtime);
    print STDERR "[WARN][$ts][Broker] $msg\n";
}

sub log_debug {
    my ($self, $msg) = @_;
    return unless $self->{debug};
    my $ts = strftime("%Y-%m-%d %H:%M:%S", localtime);
    print STDERR "[DEBUG][$ts][Broker] $msg\n";
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.

