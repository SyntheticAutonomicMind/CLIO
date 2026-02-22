package CLIO::Test::MockAPI;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_debug);
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::Test::MockAPI - Mock API provider for testing without real API keys

=head1 SYNOPSIS

    use CLIO::Test::MockAPI;
    
    my $mock = CLIO::Test::MockAPI->new();
    
    # Simple response
    my $response = $mock->chat_completion(messages => [...]);
    
    # With tool calls
    $mock->set_response({ tool_calls => [...] });
    my $response = $mock->chat_completion(...);
    
    # Simulate streaming
    $mock->stream_response($callback, { content => "Hello!" });

=head1 DESCRIPTION

MockAPI provides a mock implementation of the AI API interface for unit and
integration testing. It allows tests to run without requiring real API keys
or making network requests.

Features:

=over 4

=item * Configurable responses (content, tool calls, errors)

=item * Streaming simulation

=item * Request history tracking for verification

=item * Simulated usage/billing data

=back

=head1 METHODS

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        # Configurable responses
        default_response => $opts{default_response} // {
            content => "This is a mock response for testing.",
        },
        response_queue => [],  # Queue of responses to return in order
        
        # Request history
        requests => [],
        
        # Configuration
        model => $opts{model} // 'mock-model-1.0',
        provider => $opts{provider} // 'mock',
        
        # Error simulation
        simulate_error => $opts{simulate_error} // undef,
        error_rate => $opts{error_rate} // 0,  # 0-1, probability of error
        
        # Latency simulation (seconds)
        latency => $opts{latency} // 0,
        
        # Debug mode
        debug => $opts{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}

=head2 set_response($response)

Set the next response to return.

    $mock->set_response({
        content => "Hello!",
        tool_calls => undef,
    });
    
    # Or with tool calls:
    $mock->set_response({
        content => undef,
        tool_calls => [{
            id => 'call_123',
            type => 'function',
            function => {
                name => 'file_operations',
                arguments => '{"operation": "read_file", "path": "test.txt"}'
            }
        }]
    });

=cut

sub set_response {
    my ($self, $response) = @_;
    push @{$self->{response_queue}}, $response;
}

=head2 set_error($error_message)

Set an error to be returned on next request.

    $mock->set_error("Rate limit exceeded");

=cut

sub set_error {
    my ($self, $error) = @_;
    $self->{simulate_error} = $error;
}

=head2 clear_error()

Clear any pending error simulation.

=cut

sub clear_error {
    my ($self) = @_;
    $self->{simulate_error} = undef;
}

=head2 chat_completion(%params)

Mock implementation of chat completion API.

Parameters:

=over 4

=item * messages - Array of message hashes

=item * model - Model name (optional)

=item * stream - Whether to stream (ignored, use stream_response for streaming)

=item * tools - Available tools (for response generation)

=back

Returns: Response hash with 'choices' array

=cut

sub chat_completion {
    my ($self, %params) = @_;
    
    # Record request for later verification
    push @{$self->{requests}}, {
        messages => $params{messages},
        model => $params{model},
        tools => $params{tools},
        timestamp => time(),
    };
    
    # Simulate latency
    if ($self->{latency} > 0) {
        select(undef, undef, undef, $self->{latency});
    }
    
    # Simulate random errors
    if ($self->{error_rate} > 0 && rand() < $self->{error_rate}) {
        die "Mock API random error (error_rate=$self->{error_rate})\n";
    }
    
    # Return explicit error if set
    if ($self->{simulate_error}) {
        my $error = $self->{simulate_error};
        $self->{simulate_error} = undef;  # Clear after use
        die "Mock API error: $error\n";
    }
    
    # Get response from queue or use default
    my $response_data;
    if (@{$self->{response_queue}}) {
        $response_data = shift @{$self->{response_queue}};
    } else {
        $response_data = $self->{default_response};
    }
    
    # Build response structure (OpenAI-compatible format)
    my $response = {
        id => 'mock-' . int(rand(1000000)),
        object => 'chat.completion',
        created => time(),
        model => $self->{model},
        choices => [{
            index => 0,
            message => {
                role => 'assistant',
                content => $response_data->{content},
            },
            finish_reason => 'stop',
        }],
        usage => {
            prompt_tokens => _estimate_tokens($params{messages}),
            completion_tokens => _estimate_tokens([{content => $response_data->{content} // ''}]),
            total_tokens => 0,  # Will be summed
        },
    };
    
    # Add tool calls if present
    if ($response_data->{tool_calls}) {
        $response->{choices}[0]{message}{tool_calls} = $response_data->{tool_calls};
        $response->{choices}[0]{message}{content} = undef;  # Tool calls usually have no content
        $response->{choices}[0]{finish_reason} = 'tool_calls';
    }
    
    # Calculate total tokens
    $response->{usage}{total_tokens} = 
        $response->{usage}{prompt_tokens} + $response->{usage}{completion_tokens};
    
    log_debug('MockAPI', "Returning response: " . ($response_data->{content} // 'tool_calls'));
    
    return $response;
}

=head2 stream_response($callback, $response_data)

Simulate streaming response by calling callback with chunks.

    $mock->stream_response(sub {
        my ($chunk) = @_;
        print $chunk->{content} if $chunk->{content};
    }, { content => "Hello, world!" });

=cut

sub stream_response {
    my ($self, $callback, $response_data) = @_;
    
    $response_data //= $self->{default_response};
    
    my $content = $response_data->{content} // '';
    
    # Simulate chunk-by-chunk streaming
    my @words = split(/(\s+)/, $content);
    
    for my $i (0 .. $#words) {
        my $chunk = {
            choices => [{
                delta => {
                    content => $words[$i],
                },
                index => 0,
            }],
        };
        
        # Add finish_reason on last chunk
        if ($i == $#words) {
            $chunk->{choices}[0]{finish_reason} = 'stop';
        }
        
        $callback->($chunk);
        
        # Simulate network delay between chunks
        select(undef, undef, undef, 0.01) if $self->{latency};
    }
    
    return 1;
}

=head2 get_requests()

Get history of all requests made to the mock API.

    my @requests = $mock->get_requests();
    is(scalar(@requests), 2, 'Made 2 API calls');

=cut

sub get_requests {
    my ($self) = @_;
    return @{$self->{requests}};
}

=head2 get_last_request()

Get the most recent request.

    my $last = $mock->get_last_request();
    ok($last->{messages}[-1]{content} =~ /hello/, 'User said hello');

=cut

sub get_last_request {
    my ($self) = @_;
    return $self->{requests}[-1];
}

=head2 clear_requests()

Clear request history.

=cut

sub clear_requests {
    my ($self) = @_;
    $self->{requests} = [];
}

=head2 reset()

Reset all state (responses, errors, requests).

=cut

sub reset {
    my ($self) = @_;
    $self->{response_queue} = [];
    $self->{simulate_error} = undef;
    $self->{requests} = [];
}

# Private helper: estimate token count (very rough)
sub _estimate_tokens {
    my ($messages) = @_;
    
    my $total_chars = 0;
    for my $msg (@$messages) {
        my $content = $msg->{content} // '';
        $total_chars += length($content);
    }
    
    # Rough estimate: ~4 chars per token
    return int($total_chars / 4) || 1;
}

1;

=head1 EXAMPLE: Testing Tool Execution

    use CLIO::Test::MockAPI;
    use CLIO::Core::WorkflowOrchestrator;
    
    my $mock = CLIO::Test::MockAPI->new();
    
    # First response: AI wants to call a tool
    $mock->set_response({
        tool_calls => [{
            id => 'call_1',
            type => 'function',
            function => {
                name => 'file_operations',
                arguments => '{"operation": "read_file", "path": "README.md"}'
            }
        }]
    });
    
    # Second response: AI provides final answer
    $mock->set_response({
        content => 'The README contains installation instructions.'
    });
    
    # Now run the orchestrator with the mock API
    my $orchestrator = CLIO::Core::WorkflowOrchestrator->new(
        api_manager => $mock,
        # ...other options
    );
    
    my $result = $orchestrator->process_input("What's in README.md?");
    
    # Verify API was called correctly
    my @requests = $mock->get_requests();
    is(scalar(@requests), 2, 'Made 2 API calls (tool + final)');

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0

=cut
