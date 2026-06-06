# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Providers::NVIDIA;

use strict;
use warnings;
use utf8;
use parent 'CLIO::Providers::Base';
use CLIO::Util::JSON qw(encode_json decode_json);

=head1 NAME

CLIO::Providers::NVIDIA - Native NVIDIA NIM API provider

=head1 DESCRIPTION

Implements the NVIDIA NIM API for generative AI models.
NVIDIA NIM provides OpenAI-compatible endpoints for various models including
Nemotron series.

=head1 SYNOPSIS

    use CLIO::Providers::NVIDIA;
    
    my $provider = CLIO::Providers::NVIDIA->new(
        api_key => 'nvapi-...',
        model => 'nvidia/nemotron-3-ultra-550b-a55b',
    );
    
    my $request = $provider->build_request($messages, $tools, $options);

=head1 API DIFFERENCES

NVIDIA NIM uses OpenAI-compatible API format, so it follows the same structure
as OpenAI's API. The main differences are:
- Base URL: https://integrate.api.nvidia.com/v1
- Authentication: Bearer token with nvapi- prefix
- Model naming: nvidia/{model-name}

=cut

# Default values
use constant DEFAULT_MODEL => 'nvidia/nemotron-3-ultra-550b-a55b';
use constant DEFAULT_MAX_TOKENS => 8192;
use constant DEFAULT_API_BASE => 'https://integrate.api.nvidia.com/v1';

sub new {
    my ($class, %opts) = @_;
    
    my $self = $class->SUPER::new(%opts);
    
    $self->{api_base} //= DEFAULT_API_BASE;
    $self->{model} //= DEFAULT_MODEL;
    $self->{max_tokens} = $opts{max_tokens} // DEFAULT_MAX_TOKENS;
    
    # Store custom headers if provided (e.g., from APIManager)
    $self->{custom_headers} = $opts{custom_headers} // {};
    
    if ($self->{debug}) {
        require CLIO::Core::Logger;
        CLIO::Core::Logger::log_debug('NVIDIA', "NVIDIA provider new() - debug flag: true, custom_headers: " . encode_json($self->{custom_headers}));
    }
    
    return $self;
}

=head2 build_request($messages, $tools, $options)

Build an HTTP request for NVIDIA NIM's OpenAI-compatible API.

=cut

sub build_request {
    my ($self, $messages, $tools, $options) = @_;
    
    $options //= {};
    
    my $model = $options->{model} // $self->{model};
    
    # NVIDIA NIM API expects the full model ID (e.g., "nvidia/nemotron-3-ultra-550b-a55b")
    # Do NOT strip the prefix - the API uses the full ID
    
    # Build request payload (OpenAI format)
    my $payload = {
        model => $model,
        messages => $messages,
        stream => JSON::PP::true,
    };
    
    # Add optional parameters
    if (defined $options->{max_tokens}) {
        $payload->{max_tokens} = $options->{max_tokens};
    }
    
    if (defined $options->{temperature}) {
        $payload->{temperature} = $options->{temperature};
    }

    if (defined $options->{top_p}) {
        $payload->{top_p} = $options->{top_p};
    }

    if (defined $options->{presence_penalty}) {
        $payload->{presence_penalty} = $options->{presence_penalty};
    }

    if (defined $options->{frequency_penalty}) {
        $payload->{frequency_penalty} = $options->{frequency_penalty};
    }
    
    # Add tools if present
    if ($tools && @$tools) {
        $payload->{tools} = $tools;
        $payload->{tool_choice} = 'auto';
    }
    
    # Build URL
    my $url = "$self->{api_base}/chat/completions";
    
    my $headers = $self->get_headers();
    $self->debug("Built NVIDIA request for model $model");
    $self->debug("Request URL: $url");
    $self->debug("Request headers: " . encode_json($headers));
    $self->debug("Request payload: " . encode_json($payload));
    
    return {
        url => $url,
        method => 'POST',
        headers => $headers,
        body => encode_json($payload),
    };
}

=head2 get_headers()

Get HTTP headers for NVIDIA API requests.

=cut

sub get_headers {
    my ($self) = @_;

    my %headers = (
        'Content-Type' => 'application/json',
        'Accept' => 'application/json',
        'Authorization' => "Bearer $self->{api_key}",
    );
    
    # Merge custom headers (e.g., from APIManager)
    for my $key (keys %{$self->{custom_headers} // {}}) {
        $headers{$key} = $self->{custom_headers}{$key};
    }
    
    return \%headers;
}

=head2 parse_stream_event($line)

Parse a single line from NVIDIA's streaming response.
NVIDIA uses OpenAI-compatible streaming format.

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
        utf8::encode($line) if utf8::is_utf8($line);
        $data = decode_json($line);
    };
    if ($@) {
        $self->debug("Failed to parse JSON: $@ - Line: $line");
        return undef;
    }
    
    # Debug: log the raw response data
    $self->debug("NVIDIA response data: " . encode_json($data));
    
    # Check for error
    if ($data->{error}) {
        return {
            type => 'error',
            message => $data->{error}{message} || 'Unknown error',
        };
    }
    
    # Extract choices
    my $choices = $data->{choices};
    return undef unless $choices && @$choices;
    
    my $choice = $choices->[0];
    my $delta = $choice->{delta};
    
    # Handle text content
    if (defined $delta->{content}) {
        return {
            type => 'text',
            content => $delta->{content},
        };
    }
    
    # Handle tool calls
    if (defined $delta->{tool_calls}) {
        my $tool_calls = $delta->{tool_calls};
        return undef unless @$tool_calls;
        
        my $tool_call = $tool_calls->[0];
        my $index = $tool_call->{index} // 0;
        
        if (defined $tool_call->{id}) {
            # Tool call started
            return {
                type => 'tool_start',
                id => $tool_call->{id},
                name => $tool_call->{function}{name},
            };
        }
        elsif (defined $tool_call->{function}{arguments}) {
            # Tool arguments delta - check if tool_end is also signalled
            my $event = {
                type => 'tool_args',
                content => $tool_call->{function}{arguments},
            };
            # NVIDIA sends finish_reason alongside the last tool_calls delta.
            # Signal to the streaming handler that tool_end should fire after
            # this event is processed.
            if (defined $choice->{finish_reason} && $choice->{finish_reason} eq 'tool_calls') {
                $event->{also_tool_end} = 1;
            }
            return $event;
        }
        elsif ($tool_call->{index} == $index) {
            # Tool call continuation (no new data)
            return undef;
        }
        
        # If we got here with finish_reason=tool_calls but no delta data,
        # return tool_end directly (handled by the check below).
    }
    
    # Handle tool call completion (finish_reason == "tool_calls")
    if (defined $choice->{finish_reason} && $choice->{finish_reason} eq 'tool_calls') {
        return {
            type => 'tool_end',
        };
    }
    
    # Check for finish reason
    if (defined $choice->{finish_reason}) {
        return {
            type => 'stop',
            stop_reason => $self->_map_finish_reason($choice->{finish_reason}),
        };
    }
    
    # Usage metadata
    if (defined $data->{usage}) {
        return {
            type => 'usage',
            input_tokens => $data->{usage}{prompt_tokens} // 0,
            output_tokens => $data->{usage}{completion_tokens} // 0,
            total_tokens => $data->{usage}{total_tokens} // 0,
        };
    }
    
    return undef;
}

=head2 convert_messages($messages)

NVIDIA uses OpenAI-compatible format, so no conversion needed.

=cut

sub convert_messages {
    my ($self, $messages) = @_;
    return $messages;
}

=head2 convert_tool($tool)

NVIDIA uses OpenAI-compatible format, so no conversion needed.

=cut

sub convert_tool {
    my ($self, $tool) = @_;
    return $tool;
}

=head2 convert_tool_result($tool_call_id, $result, $is_error)

NVIDIA uses OpenAI-compatible format, so no conversion needed.

=cut

sub convert_tool_result {
    my ($self, $tool_call_id, $result, $is_error) = @_;
    return {
        tool_call_id => $tool_call_id,
        role => 'tool',
        content => $result,
    };
}

=head2 build_assistant_response($accumulated)

Build the final assistant response from accumulated stream data.

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

=head2 supports_streaming()

Check if this provider supports streaming responses.

=cut

sub supports_streaming {
    return 1;
}

=head2 supports_tools()

Check if this provider supports tool calling.

=cut

sub supports_tools {
    return 1;
}

=head2 get_stop_reason($data)

Extract the stop reason from response data.

=cut

sub get_stop_reason {
    my ($self, $data) = @_;
    
    if ($data->{choices} && @{$data->{choices}}) {
        my $finish_reason = $data->{choices}[0]{finish_reason};
        return $self->_map_finish_reason($finish_reason);
    }
    
    return 'stop';
}

#
# Private helper methods
#

sub _map_finish_reason {
    my ($self, $reason) = @_;
    
    # Map NVIDIA/NVIDIA finish reasons to standard ones
    my %map = (
        stop => 'stop',
        length => 'length',
        tool_calls => 'tool_calls',
        content_filter => 'stop',  # Treat as stop for safety
        function_call => 'tool_calls',
    );
    
    return $map{$reason} // 'stop';
}

1;

__END__

=head1 AUTHOR

CLIO Project

=cut

1;