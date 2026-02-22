package CLIO::Providers::Base;

use strict;
use warnings;
use utf8;
use Carp qw(croak);

=head1 NAME

CLIO::Providers::Base - Base class for CLIO API providers

=head1 DESCRIPTION

Defines the interface that all provider implementations must follow.
Providers handle the translation between CLIO's internal message format
(OpenAI-compatible) and provider-specific API formats.

=head1 SYNOPSIS

    package CLIO::Providers::Anthropic;
    use parent 'CLIO::Providers::Base';
    
    sub build_request { ... }
    sub parse_stream_event { ... }
    # etc.

=head1 INTERFACE

All provider implementations must inherit from this class and implement
all abstract methods marked with 'croak "Not implemented"'.

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        api_base => $opts{api_base},
        api_key => $opts{api_key},
        model => $opts{model},
        debug => $opts{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}

=head2 build_request($messages, $tools, $options)

Build an HTTP request for the chat completion API.

Arguments:
  - $messages: Arrayref of messages in OpenAI format
  - $tools: Arrayref of tool definitions in OpenAI format
  - $options: Hashref with options (model, max_tokens, temperature, etc.)

Returns: Hashref with:
  - url: Full URL to call
  - method: HTTP method (typically 'POST')
  - headers: Hashref of headers
  - body: Encoded request body (string)

=cut

sub build_request {
    my ($self, $messages, $tools, $options) = @_;
    croak "build_request() not implemented by " . ref($self);
}

=head2 parse_stream_event($line)

Parse a single line from the streaming response.

Arguments:
  - $line: Raw line from the HTTP stream

Returns: Hashref with one of:
  - { type => 'text', content => '...' } - Text delta
  - { type => 'tool_start', id => '...', name => '...' } - Tool call started
  - { type => 'tool_args', content => '...' } - Tool arguments delta
  - { type => 'tool_end' } - Tool call completed
  - { type => 'done' } - Stream completed
  - { type => 'error', message => '...' } - Error occurred
  - undef - Line should be ignored (e.g., empty, event type)

=cut

sub parse_stream_event {
    my ($self, $line) = @_;
    croak "parse_stream_event() not implemented by " . ref($self);
}

=head2 convert_messages($messages)

Convert an array of messages from OpenAI format to provider format.

Arguments:
  - $messages: Arrayref of messages in OpenAI format

Returns: Arrayref or hashref appropriate for the provider's API

=cut

sub convert_messages {
    my ($self, $messages) = @_;
    croak "convert_messages() not implemented by " . ref($self);
}

=head2 convert_tool($tool)

Convert a single tool definition from OpenAI format to provider format.

Arguments:
  - $tool: Tool definition in OpenAI format:
    { type => 'function', function => { name, description, parameters } }

Returns: Provider-specific tool format

=cut

sub convert_tool {
    my ($self, $tool) = @_;
    croak "convert_tool() not implemented by " . ref($self);
}

=head2 convert_tool_result($tool_call_id, $result, $is_error)

Convert a tool result to provider format.

Arguments:
  - $tool_call_id: ID of the tool call being responded to
  - $result: Result content (string or structured)
  - $is_error: Boolean, whether this is an error result

Returns: Provider-specific tool result message/content

=cut

sub convert_tool_result {
    my ($self, $tool_call_id, $result, $is_error) = @_;
    croak "convert_tool_result() not implemented by " . ref($self);
}

=head2 build_assistant_response($accumulated)

Build the final assistant response from accumulated stream data.

Arguments:
  - $accumulated: Hashref with accumulated data:
    {
      text => '...',           # Accumulated text content
      tool_calls => [...],     # Array of { id, name, arguments }
      usage => { ... },        # Token usage if available
    }

Returns: Hashref in OpenAI-compatible assistant message format

=cut

sub build_assistant_response {
    my ($self, $accumulated) = @_;
    
    # Default implementation - most providers can use this
    my $response = {
        role => 'assistant',
    };
    
    if ($accumulated->{text}) {
        $response->{content} = $accumulated->{text};
    }
    
    if ($accumulated->{tool_calls} && @{$accumulated->{tool_calls}}) {
        $response->{tool_calls} = $accumulated->{tool_calls};
    }
    
    if ($accumulated->{usage}) {
        $response->{usage} = $accumulated->{usage};
    }
    
    return $response;
}

=head2 get_headers()

Get default headers for API requests.

Returns: Hashref of HTTP headers

=cut

sub get_headers {
    my ($self) = @_;
    croak "get_headers() not implemented by " . ref($self);
}

=head2 supports_streaming()

Check if this provider supports streaming responses.

Returns: Boolean

=cut

sub supports_streaming {
    return 1;  # Most providers support streaming
}

=head2 supports_tools()

Check if this provider supports tool calling.

Returns: Boolean

=cut

sub supports_tools {
    return 1;  # Most modern providers support tools
}

=head2 get_stop_reason($data)

Extract the stop reason from response data.

Arguments:
  - $data: Provider-specific response data

Returns: One of 'stop', 'tool_calls', 'length', 'error'

=cut

sub get_stop_reason {
    my ($self, $data) = @_;
    return 'stop';  # Default
}

=head2 debug($message)

Log a debug message if debug mode is enabled.

=cut

sub debug {
    my ($self, $message) = @_;
    if ($self->{debug}) {
        print STDERR "[DEBUG][" . ref($self) . "] $message\n";
    }
}

1;

__END__

=head1 EXAMPLE IMPLEMENTATION

See CLIO::Providers::Anthropic for a complete implementation example.

=head1 AUTHOR

CLIO Project

=cut
