package CLIO::Providers::Google;

use strict;
use warnings;
use utf8;
use parent 'CLIO::Providers::Base';
use CLIO::Util::JSON qw(encode_json decode_json);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::Providers::Google - Native Google Gemini GenerateContent API provider

=head1 DESCRIPTION

Implements the Google Gemini API for generative AI models.
Handles the translation between CLIO's OpenAI-compatible format
and Google's native API format.

=head1 SYNOPSIS

    use CLIO::Providers::Google;
    
    my $provider = CLIO::Providers::Google->new(
        api_key => 'AIza...',
        model => 'gemini-2.5-flash',
    );
    
    my $request = $provider->build_request($messages, $tools, $options);

=head1 API DIFFERENCES

Google's GenerateContent API differs from OpenAI in several ways:

1. Uses 'contents' instead of 'messages'
2. Messages have 'parts' array instead of 'content' string
3. Role is 'user' or 'model' (not 'assistant')
4. System prompt is 'systemInstruction' (not a message)
5. Tools are wrapped in 'functionDeclarations'
6. Auth is via API key as query parameter or header

=cut

# Default values
use constant DEFAULT_MODEL => 'gemini-2.5-flash';
use constant DEFAULT_MAX_TOKENS => 8192;
use constant DEFAULT_API_BASE => 'https://generativelanguage.googleapis.com/v1beta';

sub new {
    my ($class, %opts) = @_;
    
    my $self = $class->SUPER::new(%opts);
    
    $self->{api_base} //= DEFAULT_API_BASE;
    $self->{model} //= DEFAULT_MODEL;
    $self->{max_tokens} = $opts{max_tokens} // DEFAULT_MAX_TOKENS;
    
    # Track current tool call being streamed
    $self->{_current_tool_call} = undef;
    $self->{_tool_call_counter} = 0;
    
    return $self;
}

=head2 build_request($messages, $tools, $options)

Build an HTTP request for Google's GenerateContent API.

=cut

sub build_request {
    my ($self, $messages, $tools, $options) = @_;
    
    $options //= {};
    
    my $model = $options->{model} // $self->{model};
    
    # Separate system prompt from messages
    my ($system_prompt, $conversation) = $self->_separate_system_prompt($messages);
    
    # Convert messages to Google format (contents array)
    my $contents = $self->convert_messages($conversation);
    
    # Build request payload
    my $payload = {
        contents => $contents,
        generationConfig => {
            maxOutputTokens => $options->{max_tokens} // $self->{max_tokens},
        },
    };
    
    # Add system instruction if present
    if ($system_prompt) {
        $payload->{systemInstruction} = {
            parts => [{ text => $system_prompt }],
        };
    }
    
    # Add tools if present
    if ($tools && @$tools) {
        $payload->{tools} = [{
            functionDeclarations => [ map { $self->convert_tool($_) } @$tools ],
        }];
        # Default to auto tool choice
        $payload->{toolConfig} = {
            functionCallingConfig => {
                mode => 'AUTO',
            },
        };
    }
    
    # Optional parameters
    if (defined $options->{temperature}) {
        $payload->{generationConfig}{temperature} = $options->{temperature};
    }
    
    if (defined $options->{top_p}) {
        $payload->{generationConfig}{topP} = $options->{top_p};
    }
    
    # Build URL with model and streaming endpoint
    # Format: /models/{model}:streamGenerateContent?key={api_key}
    my $url = "$self->{api_base}/models/$model:streamGenerateContent";
    $url .= "?key=$self->{api_key}" if $self->{api_key};
    $url .= "&alt=sse";  # Request SSE format for streaming
    
    $self->debug("Built Google request with " . scalar(@$contents) . " content blocks");
    
    return {
        url => $url,
        method => 'POST',
        headers => $self->get_headers(),
        body => encode_json($payload),
    };
}

=head2 get_headers()

Get HTTP headers for Google API requests.

=cut

sub get_headers {
    my ($self) = @_;
    
    return {
        'Content-Type' => 'application/json',
        'Accept' => 'text/event-stream',
    };
}

=head2 parse_stream_event($line)

Parse a single line from Google's streaming response.

Google uses a JSON array format for streaming:
  data: {"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}

=cut

sub parse_stream_event {
    my ($self, $line) = @_;
    
    # Skip empty lines
    return undef if !defined $line || $line eq '' || $line =~ /^\s*$/;
    
    # Extract data from "data: {...}" lines
    return undef unless $line =~ s/^data:\s*//;
    
    # Skip [DONE] marker
    return { type => 'done' } if $line eq '[DONE]';
    
    # Parse JSON
    my $data;
    eval {
        $data = decode_json($line);
    };
    if ($@) {
        $self->debug("Failed to parse JSON: $@ - Line: $line");
        return undef;
    }
    
    # Extract candidate content
    my $candidates = $data->{candidates};
    return undef unless $candidates && @$candidates;
    
    my $candidate = $candidates->[0];
    my $content = $candidate->{content};
    
    # Check for finish reason
    if ($candidate->{finishReason}) {
        return {
            type => 'stop',
            stop_reason => $self->_map_stop_reason($candidate->{finishReason}),
        };
    }
    
    return undef unless $content && $content->{parts};
    
    # Process parts
    for my $part (@{$content->{parts}}) {
        # Text part (may be regular text or thought/reasoning)
        if (defined $part->{text}) {
            # Gemini thinking models return thought summaries with thought: true
            if ($part->{thought}) {
                return {
                    type => 'thinking',
                    content => $part->{text},
                };
            }
            return {
                type => 'text',
                content => $part->{text},
            };
        }
        
        # Function call part
        if ($part->{functionCall}) {
            my $fc = $part->{functionCall};
            # Generate unique ID (Google doesn't always provide one)
            my $id = $fc->{id} // "call_" . (++$self->{_tool_call_counter}) . "_" . time();
            
            return {
                type => 'tool_end',  # Google sends complete tool calls, not streamed
                id => $id,
                name => $fc->{name},
                arguments => $fc->{args} // {},
            };
        }
    }
    
    # Usage metadata
    if ($data->{usageMetadata}) {
        return {
            type => 'usage',
            input_tokens => $data->{usageMetadata}{promptTokenCount} // 0,
            output_tokens => $data->{usageMetadata}{candidatesTokenCount} // 0,
        };
    }
    
    return undef;
}

=head2 convert_messages($messages)

Convert OpenAI-format messages to Google format (contents array).

=cut

sub convert_messages {
    my ($self, $messages) = @_;
    
    my @contents;
    
    for my $msg (@$messages) {
        my $role = $msg->{role};
        
        # Skip system messages (handled separately as systemInstruction)
        next if $role eq 'system';
        
        if ($role eq 'user') {
            push @contents, $self->_convert_user_message($msg);
        }
        elsif ($role eq 'assistant') {
            push @contents, $self->_convert_assistant_message($msg);
        }
        elsif ($role eq 'tool') {
            push @contents, $self->_convert_tool_result_message($msg);
        }
    }
    
    return \@contents;
}

=head2 convert_tool($tool)

Convert an OpenAI-format tool to Google format (functionDeclaration).

=cut

sub convert_tool {
    my ($self, $tool) = @_;
    
    my $function = $tool->{function};
    
    # Google uses 'parameters' but with slightly different schema format
    my $parameters = $function->{parameters} // { type => 'OBJECT', properties => {} };
    
    # Convert 'object' to 'OBJECT' for Google (case matters)
    if ($parameters->{type}) {
        $parameters->{type} = uc($parameters->{type});
    }
    
    return {
        name => $function->{name},
        description => $function->{description} // '',
        parameters => $parameters,
    };
}

=head2 convert_tool_result($tool_call_id, $result, $is_error)

Convert a tool result to Google format (functionResponse).

=cut

sub convert_tool_result {
    my ($self, $tool_call_id, $result, $is_error) = @_;
    
    my $response = {
        name => $tool_call_id,  # Google uses name, not ID
        response => {
            output => ref($result) ? $result : ($result // ''),
        },
    };
    
    if ($is_error) {
        $response->{response} = {
            error => ref($result) ? $result : ($result // 'Error'),
        };
    }
    
    return {
        role => 'user',  # Tool results are user messages in Google format
        parts => [{
            functionResponse => $response,
        }],
    };
}

#
# Private helper methods
#

sub _separate_system_prompt {
    my ($self, $messages) = @_;
    
    my $system_prompt;
    my @conversation;
    
    for my $msg (@$messages) {
        if ($msg->{role} eq 'system') {
            # Concatenate multiple system messages
            if ($system_prompt) {
                $system_prompt .= "\n\n" . $msg->{content};
            } else {
                $system_prompt = $msg->{content};
            }
        } else {
            push @conversation, $msg;
        }
    }
    
    return ($system_prompt, \@conversation);
}

sub _convert_user_message {
    my ($self, $msg) = @_;
    
    my $content = $msg->{content};
    
    # Simple string content
    if (!ref($content)) {
        return {
            role => 'user',
            parts => [{ text => $content }],
        };
    }
    
    # Array of content parts (for images, etc.)
    if (ref($content) eq 'ARRAY') {
        my @parts;
        for my $part (@$content) {
            if ($part->{type} eq 'text') {
                push @parts, { text => $part->{text} };
            }
            elsif ($part->{type} eq 'image_url') {
                # Convert image URL to Google format
                my $url = $part->{image_url}{url};
                if ($url =~ m{^data:([^;]+);base64,(.+)$}) {
                    push @parts, {
                        inlineData => {
                            mimeType => $1,
                            data => $2,
                        },
                    };
                }
            }
        }
        return {
            role => 'user',
            parts => \@parts,
        };
    }
    
    # Default: wrap as is
    return {
        role => 'user',
        parts => [{ text => $content }],
    };
}

sub _convert_assistant_message {
    my ($self, $msg) = @_;
    
    my @parts;
    
    # Add text content
    if ($msg->{content}) {
        push @parts, { text => $msg->{content} };
    }
    
    # Add tool calls (function calls in Google format)
    if ($msg->{tool_calls}) {
        for my $tool_call (@{$msg->{tool_calls}}) {
            my $arguments = $tool_call->{function}{arguments};
            # Parse if string
            if (!ref($arguments)) {
                eval { $arguments = decode_json($arguments); };
                $arguments = {} if $@;
            }
            
            push @parts, {
                functionCall => {
                    name => $tool_call->{function}{name},
                    args => $arguments,
                },
            };
        }
    }
    
    return {
        role => 'model',  # Google uses 'model' instead of 'assistant'
        parts => \@parts,
    };
}

sub _convert_tool_result_message {
    my ($self, $msg) = @_;
    
    # OpenAI format: { role => 'tool', tool_call_id => '...', content => '...' }
    # Google format: { role => 'user', parts => [{ functionResponse => {...} }] }
    
    # Try to extract the function name from tool_call_id
    # Format is usually "call_123_timestamp" or similar
    my $name = $msg->{name} // $msg->{tool_call_id};
    
    return {
        role => 'user',
        parts => [{
            functionResponse => {
                name => $name,
                response => {
                    output => $msg->{content} // '',
                },
            },
        }],
    };
}

sub _map_stop_reason {
    my ($self, $google_reason) = @_;
    
    my %reason_map = (
        'STOP' => 'stop',
        'MAX_TOKENS' => 'length',
        'SAFETY' => 'content_filter',
        'RECITATION' => 'stop',
        'OTHER' => 'stop',
    );
    
    return $reason_map{$google_reason} // 'stop';
}

1;

__END__

=head1 STREAMING PROTOCOL

Google's GenerateContent streaming uses SSE with JSON payloads:

    data: {"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}

Each chunk contains:
- candidates[0].content.parts[] - Array of content parts
- candidates[0].finishReason - Why generation stopped
- usageMetadata - Token counts

Parts can be:
- { text: "..." } - Text output
- { functionCall: { name: "...", args: {...} } } - Tool call

=head1 AUTHOR

CLIO Project

=cut
