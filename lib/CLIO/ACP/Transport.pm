package CLIO::ACP::Transport;

use strict;
use warnings;
use utf8;

use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use CLIO::ACP::JSONRPC;

=head1 NAME

CLIO::ACP::Transport - stdio transport for ACP JSON-RPC messages

=head1 SYNOPSIS

    use CLIO::ACP::Transport;
    
    my $transport = CLIO::ACP::Transport->new();
    
    # Read a message from stdin
    my $msg = $transport->read();
    
    # Write a message to stdout
    $transport->write($json_string);
    
    # Send a notification
    $transport->send_notification('session/update', { ... });

=head1 DESCRIPTION

Handles stdio transport for ACP:
- Reads newline-delimited JSON-RPC messages from stdin
- Writes newline-delimited JSON-RPC messages to stdout
- Messages must not contain embedded newlines

Per ACP spec:
- Messages are delimited by newlines (\n)
- Messages MUST NOT contain embedded newlines
- The agent MAY write to stderr for logging
- The agent MUST NOT write anything to stdout that is not a valid ACP message

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        input => $opts{input} || \*STDIN,
        output => $opts{output} || \*STDOUT,
        debug => $opts{debug} || 0,
        jsonrpc => CLIO::ACP::JSONRPC->new(debug => $opts{debug}),
        buffer => '',
    };
    
    # Set binary mode for sysread/syswrite compatibility
    # Note: We use :raw for sysread, decode/encode manually
    binmode($self->{input}, ':raw');
    binmode($self->{output}, ':raw');
    
    # Make output unbuffered for immediate message delivery
    my $old_fh = select($self->{output});
    $| = 1;
    select($old_fh);
    
    bless $self, $class;
    return $self;
}

=head2 read()

Read and parse a single JSON-RPC message from the input.

Returns the parsed message hashref, or undef on EOF/error.

Blocks until a complete message is available.

=cut

sub read {
    my ($self) = @_;
    
    my $input = $self->{input};
    
    # Read until we get a complete line
    while (1) {
        # Check if we have a complete message in buffer
        if ($self->{buffer} =~ s/^([^\n]*)\n//) {
            my $line = $1;
            $line =~ s/\r$//;  # Handle CRLF
            
            next if $line eq '';  # Skip empty lines
            
            # Decode UTF-8 bytes to Perl string
            utf8::decode($line);
            
            $self->_debug("< $line");
            
            my $msg = $self->{jsonrpc}->parse($line);
            
            unless ($msg) {
                $self->_log("Parse error: " . $self->{jsonrpc}->last_error());
                # For parse errors, we should still return something
                # so the agent can send an error response
                return {
                    type => 'parse_error',
                    error => $self->{jsonrpc}->last_error(),
                    raw => $line,
                };
            }
            
            return $msg;
        }
        
        # Read more data
        my $chunk;
        my $bytes = sysread($input, $chunk, 4096);
        
        unless (defined $bytes) {
            $self->_log("Read error: $!");
            return undef;
        }
        
        if ($bytes == 0) {
            # EOF
            return undef;
        }
        
        $self->{buffer} .= $chunk;
    }
}

=head2 read_nonblock()

Non-blocking read. Returns message if available, undef if no data ready.

=cut

sub read_nonblock {
    my ($self) = @_;
    
    # Check if we have a complete message in buffer
    if ($self->{buffer} =~ s/^([^\n]*)\n//) {
        my $line = $1;
        $line =~ s/\r$//;
        
        return undef if $line eq '';
        
        $self->_debug("< $line");
        
        my $msg = $self->{jsonrpc}->parse($line);
        return $msg || {
            type => 'parse_error',
            error => $self->{jsonrpc}->last_error(),
            raw => $line,
        };
    }
    
    # Try non-blocking read
    my $input = $self->{input};
    my $flags = fcntl($input, F_GETFL, 0);
    fcntl($input, F_SETFL, $flags | O_NONBLOCK);
    
    my $chunk;
    my $bytes = sysread($input, $chunk, 4096);
    
    fcntl($input, F_SETFL, $flags);  # Restore flags
    
    if ($bytes && $bytes > 0) {
        $self->{buffer} .= $chunk;
        return $self->read_nonblock();  # Check if we have complete message now
    }
    
    return undef;
}

=head2 write($json_string)

Write a JSON string to output, followed by newline.

=cut

sub write {
    my ($self, $json_string) = @_;
    
    # Ensure no embedded newlines (replace with escaped version if found)
    $json_string =~ s/\n/\\n/g;
    
    # Encode to UTF-8 bytes
    utf8::encode($json_string) if utf8::is_utf8($json_string);
    
    $self->_debug("> $json_string");
    
    my $output = $self->{output};
    syswrite($output, "$json_string\n");
}

=head2 send_response($id, $result)

Send a JSON-RPC response.

=cut

sub send_response {
    my ($self, $id, $result) = @_;
    
    my $resp = $self->{jsonrpc}->response($id, $result);
    $self->write($resp->{json});
}

=head2 send_error($id, $code, $message, $data)

Send a JSON-RPC error response.

=cut

sub send_error {
    my ($self, $id, $code, $message, $data) = @_;
    
    my $resp = $self->{jsonrpc}->error($id, $code, $message, $data);
    $self->write($resp->{json});
}

=head2 send_notification($method, $params)

Send a JSON-RPC notification (no response expected).

=cut

sub send_notification {
    my ($self, $method, $params) = @_;
    
    my $notif = $self->{jsonrpc}->notification($method, $params);
    $self->write($notif->{json});
}

=head2 send_request($method, $params)

Send a JSON-RPC request. Returns the request id.

=cut

sub send_request {
    my ($self, $method, $params) = @_;
    
    my $req = $self->{jsonrpc}->request($method, $params);
    $self->write($req->{json});
    return $req->{id};
}

=head2 jsonrpc()

Get the JSONRPC instance for direct access.

=cut

sub jsonrpc {
    my ($self) = @_;
    return $self->{jsonrpc};
}

=head2 _debug($message)

Write debug message to stderr.

=cut

sub _debug {
    my ($self, $message) = @_;
    print STDERR "[ACP::Transport] $message\n" if $self->{debug};
}

=head2 _log($message)

Write log message to stderr (always).

=cut

sub _log {
    my ($self, $message) = @_;
    print STDERR "[ACP::Transport] $message\n";
}

1;

__END__

=head1 MESSAGE FRAMING

ACP uses newline-delimited JSON messages:

    {"jsonrpc":"2.0","id":0,"method":"initialize","params":{...}}\n
    {"jsonrpc":"2.0","id":0,"result":{...}}\n

Each message is a single line of JSON followed by \n.
Messages MUST NOT contain embedded newlines.

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
