package CLIO::MCP::Client;

use strict;
use warnings;
use utf8;

=head1 NAME

CLIO::MCP::Client - Model Context Protocol client implementation

=head1 DESCRIPTION

Implements the MCP client protocol over stdio transport. Spawns an MCP server
as a subprocess, communicates via JSON-RPC 2.0 over stdin/stdout.

Supports the MCP 2025-11-25 specification:
- Initialize/capability negotiation
- tools/list - Discover available tools
- tools/call - Execute tools
- Graceful shutdown

=head1 SYNOPSIS

    use CLIO::MCP::Client;
    
    my $client = CLIO::MCP::Client->new(
        name    => 'filesystem',
        command => ['npx', '-y', '@modelcontextprotocol/server-filesystem', '/tmp'],
        debug   => 1,
    );
    
    $client->connect() or die "Failed to connect";
    my $tools = $client->list_tools();
    my $result = $client->call_tool('read_file', { path => '/tmp/test.txt' });
    $client->disconnect();

=cut

use JSON::PP qw(encode_json decode_json);
use IO::Select;
use POSIX qw(WNOHANG);
use Cwd qw(getcwd);

use CLIO::Core::Logger qw(should_log log_debug);

sub new {
    my ($class, %args) = @_;
    
    my $self = bless {
        name            => $args{name} || 'unnamed',
        command         => $args{command} || [],
        environment     => $args{environment} || {},
        timeout         => $args{timeout} || 30,
        debug           => $args{debug} || 0,
        pid             => undef,
        stdin_fh        => undef,
        stdout_fh       => undef,
        stderr_fh       => undef,
        connected       => 0,
        server_info     => undef,
        server_caps     => undef,
        tools           => [],
        request_id      => 0,
        read_buffer     => '',
    }, $class;
    
    return $self;
}

=head2 connect

Spawn the MCP server subprocess and perform initialization handshake.

Returns: 1 on success, 0 on failure

=cut

sub connect {
    my ($self) = @_;
    
    my @cmd = @{$self->{command}};
    unless (@cmd) {
        print STDERR "[ERROR][MCP:$self->{name}] No command specified\n" if should_log('ERROR');
        return 0;
    }
    
    log_debug('MCP', "Connecting to server '$self->{name}': @cmd");
    
    # Create pipes for stdin/stdout/stderr
    my ($child_stdin_r,  $child_stdin_w);
    my ($child_stdout_r, $child_stdout_w);
    my ($child_stderr_r, $child_stderr_w);
    
    pipe($child_stdin_r,  $child_stdin_w)  or do {
        print STDERR "[ERROR][MCP:$self->{name}] pipe() failed: $!\n";
        return 0;
    };
    pipe($child_stdout_r, $child_stdout_w) or do {
        print STDERR "[ERROR][MCP:$self->{name}] pipe() failed: $!\n";
        return 0;
    };
    pipe($child_stderr_r, $child_stderr_w) or do {
        print STDERR "[ERROR][MCP:$self->{name}] pipe() failed: $!\n";
        return 0;
    };
    
    my $pid = fork();
    
    if (!defined $pid) {
        print STDERR "[ERROR][MCP:$self->{name}] fork() failed: $!\n";
        return 0;
    }
    
    if ($pid == 0) {
        # Child process - MCP server
        close $child_stdin_w;
        close $child_stdout_r;
        close $child_stderr_r;
        
        open STDIN,  '<&', $child_stdin_r  or die "dup stdin: $!";
        open STDOUT, '>&', $child_stdout_w or die "dup stdout: $!";
        open STDERR, '>&', $child_stderr_w or die "dup stderr: $!";
        
        close $child_stdin_r;
        close $child_stdout_w;
        close $child_stderr_w;
        
        # Set environment variables
        for my $key (keys %{$self->{environment}}) {
            $ENV{$key} = $self->{environment}{$key};
        }
        
        exec @cmd;
        die "exec failed: $!";
    }
    
    # Parent process
    close $child_stdin_r;
    close $child_stdout_w;
    close $child_stderr_w;
    
    # Set autoflush on stdin pipe
    my $old_fh = select($child_stdin_w);
    $| = 1;
    select($old_fh);
    
    # Set non-blocking on stdout for reading
    binmode($child_stdout_r, ':encoding(UTF-8)');
    binmode($child_stdin_w,  ':encoding(UTF-8)');
    
    $self->{pid}       = $pid;
    $self->{stdin_fh}  = $child_stdin_w;
    $self->{stdout_fh} = $child_stdout_r;
    $self->{stderr_fh} = $child_stderr_r;
    
    log_debug('MCP', "Server '$self->{name}' spawned (PID: $pid)");
    
    # Perform initialization handshake
    my $init_ok = $self->_initialize();
    
    if ($init_ok) {
        $self->{connected} = 1;
        log_debug('MCP', "Server '$self->{name}' initialized successfully");
        
        # List tools
        $self->_discover_tools();
        
        return 1;
    } else {
        print STDERR "[ERROR][MCP:$self->{name}] Initialization handshake failed\n" if should_log('ERROR');
        $self->disconnect();
        return 0;
    }
}

=head2 disconnect

Gracefully shut down the MCP server connection.

=cut

sub disconnect {
    my ($self) = @_;
    
    return unless $self->{pid};
    
    log_debug('MCP', "Disconnecting server '$self->{name}' (PID: $self->{pid})");
    
    # Close stdin to signal shutdown
    if ($self->{stdin_fh}) {
        close $self->{stdin_fh};
        $self->{stdin_fh} = undef;
    }
    
    # Wait briefly for clean exit
    my $waited = 0;
    while ($waited < 3) {
        my $result = waitpid($self->{pid}, WNOHANG);
        last if $result > 0;
        select(undef, undef, undef, 0.1);
        $waited += 0.1;
    }
    
    # Force kill if still running
    if (kill(0, $self->{pid})) {
        log_debug('MCP', "Sending SIGTERM to '$self->{name}' (PID: $self->{pid})");
        kill('TERM', $self->{pid});
        
        $waited = 0;
        while ($waited < 2) {
            my $result = waitpid($self->{pid}, WNOHANG);
            last if $result > 0;
            select(undef, undef, undef, 0.1);
            $waited += 0.1;
        }
        
        if (kill(0, $self->{pid})) {
            log_debug('MCP', "Sending SIGKILL to '$self->{name}' (PID: $self->{pid})");
            kill('KILL', $self->{pid});
            waitpid($self->{pid}, 0);
        }
    }
    
    # Close remaining file handles
    close $self->{stdout_fh} if $self->{stdout_fh};
    close $self->{stderr_fh} if $self->{stderr_fh};
    
    $self->{stdout_fh} = undef;
    $self->{stderr_fh} = undef;
    $self->{pid}       = undef;
    $self->{connected} = 0;
    
    log_debug('MCP', "Server '$self->{name}' disconnected");
}

=head2 is_connected

Check if the MCP server is connected and alive.

=cut

sub is_connected {
    my ($self) = @_;
    
    return 0 unless $self->{connected} && $self->{pid};
    
    # Check if process is still alive
    my $result = waitpid($self->{pid}, WNOHANG);
    if ($result != 0) {
        $self->{connected} = 0;
        return 0;
    }
    
    return 1;
}

=head2 list_tools

Get the list of tools available from this MCP server.

Returns: Arrayref of tool definitions

=cut

sub list_tools {
    my ($self) = @_;
    return $self->{tools} || [];
}

=head2 call_tool

Call a tool on the MCP server.

Arguments:
- $tool_name: Name of the tool to call
- $arguments: Hashref of arguments to pass

Returns: Hashref with result (content array) or error

=cut

sub call_tool {
    my ($self, $tool_name, $arguments) = @_;
    
    unless ($self->is_connected()) {
        return { error => "Not connected to server '$self->{name}'" };
    }
    
    my $response = $self->_send_request('tools/call', {
        name      => $tool_name,
        arguments => $arguments || {},
    });
    
    if (!$response) {
        return { error => "No response from server '$self->{name}'" };
    }
    
    if ($response->{error}) {
        return {
            error   => $response->{error}{message} || 'Unknown error',
            code    => $response->{error}{code},
            isError => 1,
        };
    }
    
    my $result = $response->{result} || {};
    
    # Extract text content from MCP result format
    my $text = '';
    if ($result->{content} && ref($result->{content}) eq 'ARRAY') {
        for my $item (@{$result->{content}}) {
            if ($item->{type} eq 'text') {
                $text .= $item->{text} . "\n" if defined $item->{text};
            } elsif ($item->{type} eq 'image') {
                $text .= "[Image: $item->{mimeType}]\n";
            } elsif ($item->{type} eq 'resource') {
                if ($item->{resource} && $item->{resource}{text}) {
                    $text .= $item->{resource}{text} . "\n";
                } else {
                    $text .= "[Resource: $item->{resource}{uri}]\n";
                }
            }
        }
    }
    
    return {
        content => $result->{content},
        text    => $text,
        isError => $result->{isError} ? 1 : 0,
    };
}

=head2 server_info

Get server information from initialization.

=cut

sub server_info { return $_[0]->{server_info} }
sub server_capabilities { return $_[0]->{server_caps} }
sub name { return $_[0]->{name} }

# === Private methods ===

sub _initialize {
    my ($self) = @_;
    
    my $response = $self->_send_request('initialize', {
        protocolVersion => '2025-11-25',
        capabilities    => {
            roots => { listChanged => JSON::PP::false },
        },
        clientInfo => {
            name    => 'CLIO',
            version => '2.0.0',
        },
    });
    
    unless ($response && $response->{result}) {
        print STDERR "[ERROR][MCP:$self->{name}] Initialize failed - no valid response\n" if should_log('ERROR');
        return 0;
    }
    
    my $result = $response->{result};
    
    $self->{server_info} = $result->{serverInfo};
    $self->{server_caps} = $result->{capabilities};
    
    my $server_name = $result->{serverInfo}{name} || 'unknown';
    my $server_ver  = $result->{serverInfo}{version} || '?';
    my $proto_ver   = $result->{protocolVersion} || '?';
    
    log_debug('MCP', "Server: $server_name v$server_ver (protocol: $proto_ver)");
    
    if ($result->{instructions}) {
        log_debug('MCP', "Server instructions: $result->{instructions}");
    }
    
    # Send initialized notification
    $self->_send_notification('notifications/initialized', {});
    
    return 1;
}

sub _discover_tools {
    my ($self) = @_;
    
    unless ($self->{server_caps} && $self->{server_caps}{tools}) {
        log_debug('MCP', "Server '$self->{name}' does not advertise tools capability");
        $self->{tools} = [];
        return;
    }
    
    my $response = $self->_send_request('tools/list', {});
    
    unless ($response && $response->{result} && $response->{result}{tools}) {
        print STDERR "[WARN][MCP:$self->{name}] tools/list returned no tools\n" if should_log('WARNING');
        $self->{tools} = [];
        return;
    }
    
    $self->{tools} = $response->{result}{tools};
    
    my $count = scalar @{$self->{tools}};
    log_debug('MCP', "Server '$self->{name}' provides $count tool(s)");
    
    for my $tool (@{$self->{tools}}) {
        log_debug('MCP', "  - $tool->{name}: " . ($tool->{description} || 'no description'));
    }
}

sub _next_id {
    my ($self) = @_;
    return ++$self->{request_id};
}

sub _send_request {
    my ($self, $method, $params) = @_;
    
    my $id = $self->_next_id();
    
    my $message = {
        jsonrpc => '2.0',
        id      => $id,
        method  => $method,
    };
    $message->{params} = $params if $params;
    
    $self->_write_message($message) or return undef;
    
    # Read response (with timeout)
    return $self->_read_response($id);
}

sub _send_notification {
    my ($self, $method, $params) = @_;
    
    my $message = {
        jsonrpc => '2.0',
        method  => $method,
    };
    $message->{params} = $params if $params;
    
    $self->_write_message($message);
}

sub _write_message {
    my ($self, $message) = @_;
    
    my $fh = $self->{stdin_fh};
    unless ($fh) {
        print STDERR "[ERROR][MCP:$self->{name}] stdin not available\n" if should_log('ERROR');
        return 0;
    }
    
    my $json = eval { encode_json($message) };
    if ($@) {
        print STDERR "[ERROR][MCP:$self->{name}] JSON encode failed: $@\n" if should_log('ERROR');
        return 0;
    }
    
    log_debug('MCP', ">> $json") if $self->{debug};
    
    eval {
        print $fh "$json\n";
    };
    if ($@) {
        print STDERR "[ERROR][MCP:$self->{name}] Write failed: $@\n" if should_log('ERROR');
        return 0;
    }
    
    return 1;
}

sub _read_response {
    my ($self, $expected_id) = @_;
    
    my $fh = $self->{stdout_fh};
    unless ($fh) {
        return undef;
    }
    
    my $select = IO::Select->new($fh);
    my $timeout = $self->{timeout};
    my $start = time();
    
    while (time() - $start < $timeout) {
        # Also drain stderr to prevent pipe buffer blocking
        $self->_drain_stderr();
        
        if ($select->can_read(0.5)) {
            my $line = <$fh>;
            
            unless (defined $line) {
                log_debug('MCP', "Server '$self->{name}' closed stdout (EOF)");
                $self->{connected} = 0;
                return undef;
            }
            
            chomp $line;
            next unless length $line;
            
            log_debug('MCP', "<< $line") if $self->{debug};
            
            my $msg = eval { decode_json($line) };
            if ($@) {
                print STDERR "[WARN][MCP:$self->{name}] Invalid JSON from server: $@\n" if should_log('WARNING');
                next;
            }
            
            # Check if this is the response we're waiting for
            if (defined $msg->{id} && $msg->{id} == $expected_id) {
                return $msg;
            }
            
            # Could be a notification or request from server - log and skip for now
            if ($msg->{method}) {
                log_debug('MCP', "Server notification: $msg->{method}");
            }
        }
    }
    
    print STDERR "[WARN][MCP:$self->{name}] Timed out waiting for response (id=$expected_id)\n" if should_log('WARNING');
    return undef;
}

sub _drain_stderr {
    my ($self) = @_;
    
    my $fh = $self->{stderr_fh};
    return unless $fh;
    
    my $select = IO::Select->new($fh);
    while ($select->can_read(0)) {
        my $buf;
        my $bytes = sysread($fh, $buf, 4096);
        last unless $bytes;
        
        # Log stderr from MCP server
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

L<CLIO::MCP::Manager>, L<CLIO::Tools::MCPBridge>

MCP Specification: L<https://modelcontextprotocol.io/specification/2025-11-25>

=cut
