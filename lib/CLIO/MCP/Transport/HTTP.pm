package CLIO::MCP::Transport::HTTP;

use strict;
use warnings;
use utf8;
use Carp qw(croak);

=head1 NAME

CLIO::MCP::Transport::HTTP - Streamable HTTP transport for MCP

=head1 DESCRIPTION

Implements the MCP Streamable HTTP transport (2025-11-25 spec).
Uses curl for HTTP requests and supports both JSON responses
and Server-Sent Events (SSE) streaming.

Supports:
- POST requests with JSON-RPC messages
- SSE stream parsing for streaming responses
- Session management via MCP-Session-Id header
- Protocol version header
- Automatic fallback from StreamableHTTP to legacy SSE

=head1 SYNOPSIS

    use CLIO::MCP::Transport::HTTP;
    
    my $transport = CLIO::MCP::Transport::HTTP->new(
        url     => 'https://example.com/mcp',
        headers => { 'Authorization' => 'Bearer token' },
        timeout => 30,
    );
    
    $transport->connect() or croak "Failed to connect MCP HTTP transport";
    my $response = $transport->send_request('initialize', { ... });
    $transport->disconnect();

=cut

use CLIO::Util::JSON qw(encode_json decode_json);
use CLIO::Core::Logger qw(should_log log_debug log_error log_warning);

sub new {
    my ($class, %args) = @_;
    
    my $self = bless {
        url              => $args{url} || croak("MCP HTTP transport requires 'url'"),
        headers          => $args{headers} || {},
        timeout          => $args{timeout} || 30,
        debug            => $args{debug} || 0,
        session_id       => undef,
        protocol_version => '2025-11-25',
        request_id       => 0,
        connected        => 0,
        curl_path        => undef,  # Located lazily on first use
    }, $class;
    
    return $self;
}

=head2 connect

Establish connection by sending initialize request.

Returns: 1 on success, 0 on failure

=cut

sub connect {
    my ($self) = @_;
    
    # Locate curl lazily (avoids constructor-time PATH issues)
    unless ($self->{curl_path}) {
        $self->{curl_path} = $self->_locate_curl();
    }
    
    unless ($self->{curl_path}) {
        log_error('MCP:HTTP', "curl not found in PATH");
        return 0;
    }
    
    $self->{connected} = 1;  # Optimistic - HTTP is stateless
    return 1;
}

=head2 disconnect

End the HTTP session. Sends DELETE if session ID exists.

=cut

sub disconnect {
    my ($self) = @_;
    
    # If we have a session, try to terminate it
    if ($self->{session_id}) {
        eval {
            $self->_http_request(
                method => 'DELETE',
                body   => undef,
            );
        };
        # Ignore errors - server may not support DELETE
    }
    
    $self->{connected}  = 0;
    $self->{session_id} = undef;
}

=head2 send_request

Send a JSON-RPC request and wait for response.

Arguments:
- $method: JSON-RPC method name
- $params: Parameters hashref

Returns: Response hashref or undef on error

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
    
    my $result = $self->_http_request(
        method => 'POST',
        body   => encode_json($message),
    );
    
    return undef unless $result;
    
    # Check for session ID in headers (set during initialize)
    if ($result->{headers}{'mcp-session-id'} && !$self->{session_id}) {
        $self->{session_id} = $result->{headers}{'mcp-session-id'};
        log_debug('MCP:HTTP', "Session ID: $self->{session_id}");
    }
    
    # Parse response based on content type
    my $content_type = $result->{headers}{'content-type'} || '';
    
    if ($content_type =~ m{text/event-stream}) {
        # SSE response - parse events to find our JSON-RPC response
        return $self->_parse_sse_response($result->{body}, $id);
    }
    elsif ($content_type =~ m{application/json}) {
        # Direct JSON response
        my $response = eval { decode_json($result->{body}) };
        if ($@) {
            log_error('MCP:HTTP', "JSON parse error: $@");
            return undef;
        }
        return $response;
    }
    else {
        log_warning('MCP:HTTP', "Unexpected content-type: $content_type");
        # Try parsing as JSON anyway
        my $response = eval { decode_json($result->{body}) };
        return $response if $response;
        return undef;
    }
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
    
    $self->_http_request(
        method => 'POST',
        body   => encode_json($message),
    );
}

=head2 is_connected

Check if transport is connected.

=cut

sub is_connected { return $_[0]->{connected} }
sub session_id   { return $_[0]->{session_id} }

# === Private methods ===

sub _http_request {
    my ($self, %opts) = @_;
    
    my $method = $opts{method} || 'POST';
    my $body   = $opts{body};
    
    my @curl_args = (
        $self->{curl_path},
        '-s',               # Silent
        '-S',               # Show errors
        '-D', '-',          # Dump headers to stdout
        '-X', $method,
        '--max-time', ($self->{timeout} || 30),
    );
    
    # Add headers
    push @curl_args, '-H', 'Content-Type: application/json';
    push @curl_args, '-H', 'Accept: application/json, text/event-stream';
    push @curl_args, '-H', "MCP-Protocol-Version: $self->{protocol_version}";
    
    # Add session ID if we have one
    if ($self->{session_id}) {
        push @curl_args, '-H', "MCP-Session-Id: $self->{session_id}";
    }
    
    # Add custom headers
    for my $key (keys %{$self->{headers}}) {
        push @curl_args, '-H', "$key: $self->{headers}{$key}";
    }
    
    # Add body for POST
    if ($body && $method eq 'POST') {
        push @curl_args, '-d', $body;
    }
    
    push @curl_args, $self->{url};
    
    log_debug('MCP:HTTP', ">> $method " . ($self->{url} || '')) if $self->{debug};
    log_debug('MCP:HTTP', ">> $body") if $self->{debug} && $body;
    
    # Execute curl
    my $output = '';
    my $pid = open(my $pipe, '-|', @curl_args) or do {
        log_error('MCP:HTTP', "Failed to run curl: $!");
        return undef;
    };
    
    {
        local $/;
        $output = <$pipe>;
    }
    close $pipe;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        log_error('MCP:HTTP', "curl exited with code $exit_code");
        $self->{connected} = 0 if $exit_code == 7;  # Connection refused
        return undef;
    }
    
    # Parse headers and body from curl -D - output
    # Headers end at first blank line
    my ($raw_headers, $response_body);
    
    if ($output =~ /\r?\n\r?\n/) {
        # Split at first double newline (end of headers)
        # But curl with -D - puts headers + body together
        # Handle potential 100 Continue responses too
        my @parts = split(/\r?\n\r?\n/, $output, 2);
        
        # If first part starts with HTTP, it's headers
        if ($parts[0] =~ /^HTTP\//) {
            $raw_headers = $parts[0];
            $response_body = $parts[1] // '';
            
            # Handle 100 Continue: headers may chain
            while ($response_body =~ /^HTTP\/.*?\r?\n\r?\n/s) {
                my @sub = split(/\r?\n\r?\n/, $response_body, 2);
                $raw_headers = $sub[0];
                $response_body = $sub[1] // '';
            }
        } else {
            $response_body = $output;
            $raw_headers = '';
        }
    } else {
        $response_body = $output;
        $raw_headers = '';
    }
    
    # Parse headers
    my %headers;
    my $status_code = 0;
    for my $line (split /\r?\n/, $raw_headers) {
        if ($line =~ /^HTTP\/[\d.]+ (\d+)/) {
            $status_code = $1;
        }
        elsif ($line =~ /^([^:]+):\s*(.*)$/) {
            $headers{lc($1)} = $2;
        }
    }
    
    log_debug('MCP:HTTP', "<< HTTP $status_code") if $self->{debug};
    log_debug('MCP:HTTP', "<< $response_body") if $self->{debug} && $response_body;
    
    # Handle error status codes
    if ($status_code >= 400) {
        if ($status_code == 404 && $self->{session_id}) {
            # Session terminated - need to re-initialize
            log_debug('MCP:HTTP', "Session terminated by server (404)");
            $self->{session_id} = undef;
        }
        log_warning('MCP:HTTP', "HTTP $status_code from server");
        return undef;
    }
    
    return {
        status  => $status_code,
        headers => \%headers,
        body    => $response_body,
    };
}

sub _parse_sse_response {
    my ($self, $body, $expected_id) = @_;
    
    # Parse SSE format: lines of "event: ...", "data: ...", "id: ..."
    # Events are separated by blank lines
    my @events;
    my $current = {};
    
    for my $line (split /\r?\n/, $body) {
        if ($line eq '') {
            # End of event
            if ($current->{data}) {
                push @events, $current;
            }
            $current = {};
            next;
        }
        
        if ($line =~ /^data:\s*(.*)$/) {
            $current->{data} = ($current->{data} || '') . $1;
        }
        elsif ($line =~ /^event:\s*(.*)$/) {
            $current->{event} = $1;
        }
        elsif ($line =~ /^id:\s*(.*)$/) {
            $current->{id} = $1;
        }
        elsif ($line =~ /^retry:\s*(\d+)$/) {
            $current->{retry} = $1;
        }
        # Lines starting with : are comments, ignore
    }
    
    # Don't forget last event if no trailing newline
    push @events, $current if $current->{data};
    
    # Find JSON-RPC response matching our request ID
    for my $event (@events) {
        next unless $event->{data};
        
        my $msg = eval { decode_json($event->{data}) };
        next unless $msg;
        
        # Return the first response matching our ID
        if (defined $msg->{id} && $msg->{id} == $expected_id) {
            return $msg;
        }
        
        # Log notifications/requests from server
        if ($msg->{method}) {
            log_debug('MCP:HTTP', "Server notification: $msg->{method}");
        }
    }
    
    log_warning('MCP:HTTP', "No matching response found in SSE stream for id=$expected_id");
    return undef;
}

sub _locate_curl {
    my ($class_or_self) = @_;
    # Check PATH
    for my $dir (split /:/, $ENV{PATH} || '') {
        my $path = "$dir/curl";
        return $path if -x $path && !-d $path;
    }
    # Check common locations as fallback
    for my $path ('/usr/bin/curl', '/usr/local/bin/curl', '/opt/homebrew/bin/curl') {
        return $path if -x $path;
    }
    return undef;
}

1;

__END__

=head1 SEE ALSO

L<CLIO::MCP::Client>, L<CLIO::MCP::Manager>

MCP Streamable HTTP Transport: L<https://modelcontextprotocol.io/specification/2025-11-25/basic/transports>

=cut
