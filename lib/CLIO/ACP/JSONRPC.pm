package CLIO::ACP::JSONRPC;

use strict;
use warnings;
use utf8;

use JSON::PP qw(encode_json decode_json);

=head1 NAME

CLIO::ACP::JSONRPC - JSON-RPC 2.0 message handling for ACP

=head1 SYNOPSIS

    use CLIO::ACP::JSONRPC;
    
    my $rpc = CLIO::ACP::JSONRPC->new();
    
    # Parse incoming message
    my $msg = $rpc->parse($json_string);
    # Returns: { type => 'request'|'notification'|'response', ... }
    
    # Create request
    my $req = $rpc->request('session/prompt', { sessionId => 'abc', prompt => [...] });
    
    # Create notification (no response expected)
    my $notif = $rpc->notification('session/cancel', { sessionId => 'abc' });
    
    # Create response
    my $resp = $rpc->response($request_id, $result);
    
    # Create error response
    my $err = $rpc->error($request_id, $code, $message, $data);

=head1 DESCRIPTION

JSON-RPC 2.0 message encoding/decoding for the Agent Client Protocol.
Handles request, response, notification, and error messages.

Per JSON-RPC 2.0 spec:
- Request: has id, method, params
- Notification: has method, params (no id)
- Response: has id, result OR error

=cut

# Standard JSON-RPC 2.0 error codes
our %ERROR_CODES = (
    PARSE_ERROR      => -32700,
    INVALID_REQUEST  => -32600,
    METHOD_NOT_FOUND => -32601,
    INVALID_PARAMS   => -32602,
    INTERNAL_ERROR   => -32603,
);

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        id_counter => 0,
        debug => $opts{debug} || 0,
    };
    
    bless $self, $class;
    return $self;
}

=head2 parse($json_string)

Parse a JSON-RPC 2.0 message from a JSON string.

Returns a hashref with:
- type: 'request', 'notification', 'response', or 'error'
- For requests: id, method, params
- For notifications: method, params
- For responses: id, result
- For errors: id, error (code, message, data)

Returns undef and sets $self->{last_error} on parse failure.

=cut

sub parse {
    my ($self, $json_string) = @_;
    
    # Parse JSON
    my $data = eval { decode_json($json_string) };
    if ($@) {
        $self->{last_error} = "JSON parse error: $@";
        return undef;
    }
    
    # Validate JSON-RPC 2.0 format
    unless (ref($data) eq 'HASH') {
        $self->{last_error} = "Message must be a JSON object";
        return undef;
    }
    
    # Check for JSON-RPC version (should be "2.0")
    if (exists $data->{jsonrpc} && $data->{jsonrpc} ne '2.0') {
        $self->{last_error} = "Unsupported JSON-RPC version: $data->{jsonrpc}";
        return undef;
    }
    
    # Determine message type
    if (exists $data->{method}) {
        # Request or Notification
        if (exists $data->{id}) {
            return {
                type => 'request',
                id => $data->{id},
                method => $data->{method},
                params => $data->{params} // {},
            };
        } else {
            return {
                type => 'notification',
                method => $data->{method},
                params => $data->{params} // {},
            };
        }
    } elsif (exists $data->{id}) {
        # Response
        if (exists $data->{error}) {
            return {
                type => 'error',
                id => $data->{id},
                error => $data->{error},
            };
        } else {
            return {
                type => 'response',
                id => $data->{id},
                result => $data->{result},
            };
        }
    } else {
        $self->{last_error} = "Invalid JSON-RPC message: missing method or id";
        return undef;
    }
}

=head2 request($method, $params)

Create a JSON-RPC 2.0 request message.

=cut

sub request {
    my ($self, $method, $params) = @_;
    
    my $id = ++$self->{id_counter};
    
    my $msg = {
        jsonrpc => '2.0',
        id => $id,
        method => $method,
    };
    
    $msg->{params} = $params if defined $params;
    
    return {
        json => encode_json($msg),
        id => $id,
        raw => $msg,
    };
}

=head2 notification($method, $params)

Create a JSON-RPC 2.0 notification message (no response expected).

=cut

sub notification {
    my ($self, $method, $params) = @_;
    
    my $msg = {
        jsonrpc => '2.0',
        method => $method,
    };
    
    $msg->{params} = $params if defined $params;
    
    return {
        json => encode_json($msg),
        raw => $msg,
    };
}

=head2 response($id, $result)

Create a JSON-RPC 2.0 success response message.

=cut

sub response {
    my ($self, $id, $result) = @_;
    
    my $msg = {
        jsonrpc => '2.0',
        id => $id,
        result => $result,
    };
    
    return {
        json => encode_json($msg),
        raw => $msg,
    };
}

=head2 error($id, $code, $message, $data)

Create a JSON-RPC 2.0 error response message.

Standard error codes:
- -32700: Parse error
- -32600: Invalid Request
- -32601: Method not found
- -32602: Invalid params
- -32603: Internal error

=cut

sub error {
    my ($self, $id, $code, $message, $data) = @_;
    
    my $error = {
        code => $code,
        message => $message,
    };
    
    $error->{data} = $data if defined $data;
    
    my $msg = {
        jsonrpc => '2.0',
        id => $id,
        error => $error,
    };
    
    return {
        json => encode_json($msg),
        raw => $msg,
    };
}

=head2 error_parse($id, $message)

Convenience method for parse error.

=cut

sub error_parse {
    my ($self, $id, $message) = @_;
    return $self->error($id, $ERROR_CODES{PARSE_ERROR}, $message // 'Parse error');
}

=head2 error_invalid_request($id, $message)

Convenience method for invalid request error.

=cut

sub error_invalid_request {
    my ($self, $id, $message) = @_;
    return $self->error($id, $ERROR_CODES{INVALID_REQUEST}, $message // 'Invalid Request');
}

=head2 error_method_not_found($id, $method)

Convenience method for method not found error.

=cut

sub error_method_not_found {
    my ($self, $id, $method) = @_;
    return $self->error($id, $ERROR_CODES{METHOD_NOT_FOUND}, "Method not found: $method");
}

=head2 error_invalid_params($id, $message)

Convenience method for invalid params error.

=cut

sub error_invalid_params {
    my ($self, $id, $message) = @_;
    return $self->error($id, $ERROR_CODES{INVALID_PARAMS}, $message // 'Invalid params');
}

=head2 error_internal($id, $message)

Convenience method for internal error.

=cut

sub error_internal {
    my ($self, $id, $message) = @_;
    return $self->error($id, $ERROR_CODES{INTERNAL_ERROR}, $message // 'Internal error');
}

=head2 last_error()

Get the last parse error message.

=cut

sub last_error {
    my ($self) = @_;
    return $self->{last_error};
}

1;

__END__

=head1 JSON-RPC 2.0 MESSAGE FORMATS

Request:
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}

Notification (no id, no response expected):
    {"jsonrpc":"2.0","method":"session/cancel","params":{...}}

Success Response:
    {"jsonrpc":"2.0","id":1,"result":{...}}

Error Response:
    {"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid Request"}}

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
