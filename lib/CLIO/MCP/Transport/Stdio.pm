package CLIO::MCP::Transport::Stdio;

use strict;
use warnings;
use utf8;

=head1 NAME

CLIO::MCP::Transport::Stdio - Stdio transport for MCP

=head1 DESCRIPTION

Implements the MCP stdio transport. Spawns an MCP server as a subprocess
and communicates via JSON-RPC 2.0 over stdin/stdout.

This module provides the same interface as CLIO::MCP::Transport::HTTP,
allowing the Client to use either transport transparently.

=cut

use CLIO::Util::JSON qw(encode_json decode_json);
use IO::Select;
use POSIX qw(WNOHANG);
use CLIO::Core::Logger qw(log_debug log_error log_warning);

sub new {
    my ($class, %args) = @_;
    
    my $self = bless {
        command     => $args{command} || [],
        environment => $args{environment} || {},
        timeout     => $args{timeout} || 30,
        debug       => $args{debug} || 0,
        name        => $args{name} || 'stdio',
        pid         => undef,
        stdin_fh    => undef,
        stdout_fh   => undef,
        stderr_fh   => undef,
        connected   => 0,
        request_id  => 0,
    }, $class;
    
    return $self;
}

=head2 connect

Spawn the MCP server subprocess.

Returns: 1 on success, 0 on failure

=cut

sub connect {
    my ($self) = @_;
    
    my @cmd = @{$self->{command}};
    unless (@cmd) {
        log_error('MCP:$self->{name}', "No command specified");
        return 0;
    }
    
    log_debug('MCP', "Spawning stdio server '$self->{name}': @cmd");
    
    # Create pipes
    my ($child_stdin_r,  $child_stdin_w);
    my ($child_stdout_r, $child_stdout_w);
    my ($child_stderr_r, $child_stderr_w);
    
    pipe($child_stdin_r,  $child_stdin_w)  or return 0;
    pipe($child_stdout_r, $child_stdout_w) or return 0;
    pipe($child_stderr_r, $child_stderr_w) or return 0;
    
    my $pid = fork();
    return 0 unless defined $pid;
    
    if ($pid == 0) {
        # Child process
        close $child_stdin_w;
        close $child_stdout_r;
        close $child_stderr_r;
        
        open STDIN,  '<&', $child_stdin_r  or die "dup stdin: $!";
        open STDOUT, '>&', $child_stdout_w or die "dup stdout: $!";
        open STDERR, '>&', $child_stderr_w or die "dup stderr: $!";
        
        close $child_stdin_r;
        close $child_stdout_w;
        close $child_stderr_w;
        
        for my $key (keys %{$self->{environment}}) {
            $ENV{$key} = $self->{environment}{$key};
        }
        
        exec @cmd;
        die "exec failed: $!";
    }
    
    # Parent
    close $child_stdin_r;
    close $child_stdout_w;
    close $child_stderr_w;
    
    my $old_fh = select($child_stdin_w); $| = 1; select($old_fh);
    binmode($child_stdout_r, ':encoding(UTF-8)');
    binmode($child_stdin_w,  ':encoding(UTF-8)');
    
    $self->{pid}       = $pid;
    $self->{stdin_fh}  = $child_stdin_w;
    $self->{stdout_fh} = $child_stdout_r;
    $self->{stderr_fh} = $child_stderr_r;
    $self->{connected} = 1;
    
    log_debug('MCP', "Stdio server '$self->{name}' spawned (PID: $pid)");
    return 1;
}

=head2 disconnect

Shut down the subprocess.

=cut

sub disconnect {
    my ($self) = @_;
    return unless $self->{pid};
    
    log_debug('MCP', "Disconnecting stdio server '$self->{name}' (PID: $self->{pid})");
    
    close $self->{stdin_fh} if $self->{stdin_fh};
    $self->{stdin_fh} = undef;
    
    # Wait for clean exit
    my $waited = 0;
    while ($waited < 3) {
        last if waitpid($self->{pid}, WNOHANG) > 0;
        select(undef, undef, undef, 0.1);
        $waited += 0.1;
    }
    
    # Force kill if still running
    if (kill(0, $self->{pid})) {
        kill('TERM', $self->{pid});
        $waited = 0;
        while ($waited < 2) {
            last if waitpid($self->{pid}, WNOHANG) > 0;
            select(undef, undef, undef, 0.1);
            $waited += 0.1;
        }
        if (kill(0, $self->{pid})) {
            kill('KILL', $self->{pid});
            waitpid($self->{pid}, 0);
        }
    }
    
    close $self->{stdout_fh} if $self->{stdout_fh};
    close $self->{stderr_fh} if $self->{stderr_fh};
    $self->{stdout_fh} = undef;
    $self->{stderr_fh} = undef;
    $self->{pid}       = undef;
    $self->{connected} = 0;
}

=head2 send_request

Send a JSON-RPC request and wait for response.

=cut

sub send_request {
    my ($self, $method, $params) = @_;
    
    my $id = ++$self->{request_id};
    my $message = {
        jsonrpc => '2.0',
        id      => $id,
        method  => $method,
    };
    $message->{params} = $params if $params;
    
    $self->_write_message($message) or return undef;
    return $self->_read_response($id);
}

=head2 send_notification

Send a JSON-RPC notification (no response expected).

=cut

sub send_notification {
    my ($self, $method, $params) = @_;
    
    my $message = {
        jsonrpc => '2.0',
        method  => $method,
    };
    $message->{params} = $params if $params;
    
    $self->_write_message($message);
}

=head2 is_connected

Check if transport is connected and process alive.

=cut

sub is_connected {
    my ($self) = @_;
    return 0 unless $self->{connected} && $self->{pid};
    
    my $result = waitpid($self->{pid}, WNOHANG);
    if ($result != 0) {
        $self->{connected} = 0;
        return 0;
    }
    return 1;
}

# === Private methods ===

sub _write_message {
    my ($self, $message) = @_;
    
    my $fh = $self->{stdin_fh};
    return 0 unless $fh;
    
    my $json = eval { encode_json($message) };
    return 0 if $@;
    
    log_debug('MCP', ">> $json") if $self->{debug};
    
    eval { print $fh "$json\n" };
    return $@ ? 0 : 1;
}

sub _read_response {
    my ($self, $expected_id) = @_;
    
    my $fh = $self->{stdout_fh};
    return undef unless $fh;
    
    my $select = IO::Select->new($fh);
    my $start = time();
    
    while (time() - $start < $self->{timeout}) {
        $self->_drain_stderr();
        
        if ($select->can_read(0.5)) {
            my $line = <$fh>;
            unless (defined $line) {
                $self->{connected} = 0;
                return undef;
            }
            
            chomp $line;
            next unless length $line;
            
            log_debug('MCP', "<< $line") if $self->{debug};
            
            my $msg = eval { decode_json($line) };
            next if $@;
            
            return $msg if defined $msg->{id} && $msg->{id} == $expected_id;
            
            # Server notification - log and skip
            log_debug('MCP', "Server notification: $msg->{method}") if $msg->{method};
        }
    }
    
    log_warning('MCP:$self->{name}', "Timeout waiting for response (id=$expected_id)");
    return undef;
}

sub _drain_stderr {
    my ($self) = @_;
    my $fh = $self->{stderr_fh};
    return unless $fh;
    
    my $select = IO::Select->new($fh);
    while ($select->can_read(0)) {
        my $buf;
        last unless sysread($fh, $buf, 4096);
        chomp $buf;
        log_debug('MCP', "[$self->{name} stderr] $buf") if $self->{debug};
    }
}

sub DESTROY {
    my ($self) = @_;
    $self->disconnect() if $self->{connected};
}

1;

__END__

=head1 SEE ALSO

L<CLIO::MCP::Transport::HTTP>, L<CLIO::MCP::Client>

=cut
