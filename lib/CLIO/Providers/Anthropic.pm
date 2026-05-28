# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Providers::Anthropic;

use strict;
use warnings;
use utf8;
use parent 'CLIO::Providers::Base';
use CLIO::Util::JSON qw(encode_json decode_json);
use CLIO::Core::Logger qw(log_debug log_warning);

=head1 NAME

CLIO::Providers::Anthropic - Native Anthropic Messages API provider

=head1 DESCRIPTION

Implements the Anthropic Messages API for Claude models.
Handles the translation between CLIO's OpenAI-compatible format
and Anthropic's native API format.

Supports:
- Anthropic Messages API (POST /v1/messages)
- SSE streaming with content_block_delta events
- Tool calling (tool_use/tool_result content blocks)
- Extended thinking (thinking content blocks)
- Vision (image input)
- Custom headers via ANTHROPIC_CUSTOM_HEADERS config
- Proxy endpoints via ANTHROPIC_BASE_URL config

=head1 SYNOPSIS

    use CLIO::Providers::Anthropic;
    
    my $provider = CLIO::Providers::Anthropic->new(
        api_key => 'sk-ant-...',
        model => 'claude-sonnet-4-20250514',
    );
    
    my $request = $provider->build_request($messages, $tools, $options);

=head1 API DIFFERENCES

Anthropic's Messages API differs from OpenAI in several ways:

1. System prompt is a top-level field, not a message
2. Tool definitions use 'input_schema' instead of 'parameters'
3. Tool calls are 'tool_use' content blocks in the response
4. Tool results are 'tool_result' content blocks in user messages
5. Streaming uses different event types (content_block_start/delta/stop)
6. Auth uses 'x-api-key' header instead of 'Authorization: Bearer'
7. Requires 'anthropic-version' header

=cut

# Anthropic API version
use constant ANTHROPIC_VERSION => '2023-06-01';

# Default values
use constant DEFAULT_MODEL => 'claude-sonnet-4-20250514';
use constant DEFAULT_MAX_TOKENS => 8192;
use constant DEFAULT_API_BASE => 'https://api.anthropic.com/v1/messages';

sub new {
    my ($class, %opts) = @_;
    
    my $self = $class->SUPER::new(%opts);
    
    # Allow environment variable overrides for proxy/custom setups
    # ANTHROPIC_BASE_URL overrides the configured api_base
    # ANTHROPIC_API_KEY overrides the configured api_key
    # ANTHROPIC_CUSTOM_HEADERS is a JSON string of additional headers
    if ($ENV{ANTHROPIC_BASE_URL}) {
        $self->{api_base} = $ENV{ANTHROPIC_BASE_URL};
    } else {
        $self->{api_base} //= DEFAULT_API_BASE;
    }
    
    if ($ENV{ANTHROPIC_API_KEY}) {
        $self->{api_key} = $ENV{ANTHROPIC_API_KEY};
    }
    
    $self->{model} //= DEFAULT_MODEL;
    $self->{max_tokens} = $opts{max_tokens} // DEFAULT_MAX_TOKENS;
    
    # Custom headers: merge provider config headers with environment variable headers
    my %all_custom_headers;
    if ($opts{custom_headers} && ref($opts{custom_headers}) eq 'HASH') {
        %all_custom_headers = %{$opts{custom_headers}};
    }
    if ($ENV{ANTHROPIC_CUSTOM_HEADERS}) {
        eval {
            my $env_headers = decode_json($ENV{ANTHROPIC_CUSTOM_HEADERS});
            if (ref($env_headers) eq 'HASH') {
                %all_custom_headers = (%all_custom_headers, %$env_headers);
            }
        };
        if ($@) {
            log_warning('Anthropic', "Failed to parse ANTHROPIC_CUSTOM_HEADERS: $@");
        }
    }
    $self->{custom_headers} = \%all_custom_headers;
    
    # Track current tool call being streamed
    $self->{_current_tool_call} = undef;
    $self->{_accumulated_json} = '';
    
    return $self;
}

=head2 build_request($messages, $tools, $options)

Build an HTTP request for Anthropic's Messages API.

Arguments:
  $messages - Arrayref of messages in OpenAI format
  $tools    - Arrayref of tool definitions in OpenAI format
  $options  - Hashref with model, max_tokens, temperature, etc.

Returns: Hashref with url, method, headers, body

=cut

sub build_request {
    my ($self, $messages, $tools, $options) = @_;
    
    $options //= {};
    
    # Separate system prompt from messages
    my ($system_prompt, $conversation) = $self->_separate_system_prompt($messages);
    
    # Convert messages to Anthropic format
    my $anthropic_messages = $self->convert_messages($conversation);
    
    # Build request payload
    my $payload = {
        model => $options->{model} // $self->{model},
        max_tokens => $options->{max_tokens} // $self->{max_tokens},
        stream => JSON::PP::true,
        messages => $anthropic_messages,
    };
    
    # Add system prompt if present
    if ($system_prompt) {
        $payload->{system} = $system_prompt;
    }
    
    # Add tools if present
    if ($tools && @$tools) {
        $payload->{tools} = [ map { $self->convert_tool($_) } @$tools ];
        # Default to auto tool choice
        $payload->{tool_choice} = { type => 'auto' };
    }
    
    # Optional parameters
    if (defined $options->{temperature}) {
        $payload->{temperature} = $options->{temperature};
    }
    
    if (defined $options->{top_p}) {
        $payload->{top_p} = $options->{top_p};
    }
    
    # Extended thinking support
    if ($options->{thinking} && ref($options->{thinking}) eq 'HASH') {
        $payload->{thinking} = $options->{thinking};
    }
    
    $self->debug("Built Anthropic request with " . scalar(@$anthropic_messages) . " messages");
    
    return {
        url => $self->{api_base},
        method => 'POST',
        headers => $self->get_headers(),
        body => encode_json($payload),
    };
}

=head2 get_headers()

Get HTTP headers for Anthropic API requests.

Returns: Hashref of HTTP headers

=cut

sub get_headers {
    my ($self) = @_;
    
    my %headers = (
        'Content-Type' => 'application/json',
        'x-api-key' => $self->{api_key},
        'anthropic-version' => ANTHROPIC_VERSION,
        'Accept' => 'text/event-stream',
    );
    
    # Merge custom headers (for proxy endpoints, etc.)
    if ($self->{custom_headers} && keys %{$self->{custom_headers}}) {
        for my $key (keys %{$self->{custom_headers}}) {
            $headers{$key} = $self->{custom_headers}{$key};
        }
    }
    
    return \%headers;
}

=head2 parse_stream_event($line)

Parse a single line from Anthropic's streaming response.

Anthropic uses Server-Sent Events (SSE) format:
  event: message_start
  data: {"type":"message_start",...}
  
  event: content_block_delta
  data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}

Arguments:
  $line - Raw line from the HTTP stream

Returns: Hashref with event data, or undef for ignorable lines

=cut

sub parse_stream_event {
    my ($self, $line) = @_;
    
    # Skip empty lines
    return undef if !defined $line || $line eq '' || $line =~ /^\s*$/;
    
    # Skip event type lines (we parse from data lines)
    return undef if $line =~ /^event:/;
    
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
    
    my $event_type = $data->{type} // '';
    
    # Handle different event types
    if ($event_type eq 'message_start') {
        # Extract usage from message_start
        my $usage = $data->{message}{usage};
        if ($usage) {
            return {
                type => 'usage',
                input_tokens => $usage->{input_tokens} // 0,
                output_tokens => $usage->{output_tokens} // 0,
            };
        }
        return undef;
    }
    elsif ($event_type eq 'content_block_start') {
        my $block = $data->{content_block};
        my $block_type = $block->{type} // '';
        
        if ($block_type eq 'text') {
            # Text block starting - no action needed
            return undef;
        }
        elsif ($block_type eq 'tool_use') {
            # Tool call starting
            $self->{_current_tool_call} = {
                id => $block->{id},
                name => $block->{name},
            };
            $self->{_accumulated_json} = '';
            return {
                type => 'tool_start',
                id => $block->{id},
                name => $block->{name},
            };
        }
        elsif ($block_type eq 'thinking') {
            # Extended thinking block starting
            return {
                type => 'thinking',
                content => undef,
            };
        }
    }
    elsif ($event_type eq 'content_block_delta') {
        my $delta = $data->{delta};
        my $delta_type = $delta->{type} // '';
        
        if ($delta_type eq 'text_delta') {
            return {
                type => 'text',
                content => $delta->{text} // '',
            };
        }
        elsif ($delta_type eq 'input_json_delta') {
            # Accumulate partial JSON for tool arguments
            $self->{_accumulated_json} .= $delta->{partial_json} // '';
            return {
                type => 'tool_args',
                content => $delta->{partial_json} // '',
            };
        }
        elsif ($delta_type eq 'thinking_delta') {
            # Extended thinking content
            return {
                type => 'thinking',
                content => $delta->{thinking} // '',
            };
        }
    }
    elsif ($event_type eq 'content_block_stop') {
        # Check if we were accumulating a tool call
        if ($self->{_current_tool_call}) {
            my $tool_call = $self->{_current_tool_call};
            $self->{_current_tool_call} = undef;
            
            # Parse accumulated arguments
            my $arguments = {};
            if ($self->{_accumulated_json}) {
                eval {
                    $arguments = decode_json($self->{_accumulated_json});
                };
                if ($@) {
                    log_warning('Anthropic', "Failed to parse tool arguments: $@");
                }
            }
            $self->{_accumulated_json} = '';
            
            return {
                type => 'tool_end',
                id => $tool_call->{id},
                name => $tool_call->{name},
                arguments => $arguments,
            };
        }
        return undef;
    }
    elsif ($event_type eq 'message_delta') {
        # May contain stop reason and final usage
        my $delta = $data->{delta};
        my $usage = $data->{usage};
        
        my @results;
        
        if ($delta && $delta->{stop_reason}) {
            push @results, {
                type => 'stop',
                stop_reason => $self->_map_stop_reason($delta->{stop_reason}),
            };
        }
        
        if ($usage) {
            push @results, {
                type => 'usage',
                output_tokens => $usage->{output_tokens} // 0,
            };
        }
        
        # Return first result if any (message_delta typically has stop_reason)
        return $results[0] if @results;
        return undef;
    }
    elsif ($event_type eq 'message_stop') {
        return { type => 'done' };
    }
    elsif ($event_type eq 'error') {
        return {
            type => 'error',
            message => $data->{error}{message} // 'Unknown Anthropic API error',
        };
    }
    
    # Unknown event type - ignore
    return undef;
}

=head2 convert_messages($messages)

Convert OpenAI-format messages to Anthropic format.

Anthropic format differences:
- No 'system' role (handled as top-level 'system' field)
- 'assistant' role stays the same
- Tool results are 'tool_result' content blocks in 'user' messages
- Tool calls are 'tool_use' content blocks in 'assistant' messages
- Consecutive same-role messages must be merged

Arguments:
  $messages - Arrayref of messages in OpenAI format

Returns: Arrayref of messages in Anthropic format

=cut

sub convert_messages {
    my ($self, $messages) = @_;
    
    my @anthropic_messages;
    my $last_role = '';
    
    for my $msg (@$messages) {
        my $role = $msg->{role};
        
        # Skip system messages (handled separately as top-level field)
        next if $role eq 'system';
        
        my $converted;
        if ($role eq 'user') {
            $converted = $self->_convert_user_message($msg);
        }
        elsif ($role eq 'assistant') {
            $converted = $self->_convert_assistant_message($msg);
        }
        elsif ($role eq 'tool') {
            $converted = $self->_convert_tool_result_message($msg);
        }
        else {
            next;
        }
        
        # Anthropic requires alternating user/assistant roles.
        # If we get two consecutive same-role messages, merge their content.
        if ($converted->{role} eq $last_role && @anthropic_messages) {
            my $prev = $anthropic_messages[-1];
            # Merge content arrays
            my $prev_content = ref($prev->{content}) eq 'ARRAY'
                ? $prev->{content} : [{ type => 'text', text => $prev->{content} }];
            my $new_content = ref($converted->{content}) eq 'ARRAY'
                ? $converted->{content} : [{ type => 'text', text => $converted->{content} }];
            $prev->{content} = [@$prev_content, @$new_content];
        }
        else {
            push @anthropic_messages, $converted;
        }
        
        $last_role = $converted->{role};
    }
    
    return \@anthropic_messages;
}

=head2 convert_tool($tool)

Convert an OpenAI-format tool definition to Anthropic format.

OpenAI format:
  { type => 'function', function => { name, description, parameters } }

Anthropic format:
  { name, description, input_schema }

=cut

sub convert_tool {
    my ($self, $tool) = @_;
    
    my $function = $tool->{function};
    
    return {
        name => $function->{name},
        description => $function->{description} // '',
        input_schema => $function->{parameters} // { type => 'object', properties => {} },
    };
}

=head2 convert_tool_result($tool_call_id, $result, $is_error)

Convert a tool result to Anthropic format.

In Anthropic's format, tool results are content blocks within a user message:
  { role => 'user', content => [{ type => 'tool_result', tool_use_id => '...', content => '...' }] }

Arguments:
  $tool_call_id - ID of the tool call being responded to
  $result       - Result content (string or structured)
  $is_error     - Boolean, whether this is an error result

Returns: Hashref in Anthropic message format

=cut

sub convert_tool_result {
    my ($self, $tool_call_id, $result, $is_error) = @_;
    
    my $content = ref($result) ? encode_json($result) : ($result // '');
    
    my $tool_result = {
        type => 'tool_result',
        tool_use_id => $tool_call_id,
        content => $content,
    };
    
    if ($is_error) {
        $tool_result->{is_error} = JSON::PP::true;
    }
    
    return {
        role => 'user',
        content => [$tool_result],
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
            content => $content,
        };
    }
    
    # Array of content parts (for images, tool results, etc.)
    if (ref($content) eq 'ARRAY') {
        my @parts;
        for my $part (@$content) {
            if ($part->{type} eq 'text') {
                push @parts, { type => 'text', text => $part->{text} };
            }
            elsif ($part->{type} eq 'image_url') {
                # Convert image URL to Anthropic format
                my $url = $part->{image_url}{url};
                if ($url =~ m{^data:([^;]+);base64,(.+)$}) {
                    push @parts, {
                        type => 'image',
                        source => {
                            type => 'base64',
                            media_type => $1,
                            data => $2,
                        },
                    };
                }
                elsif ($url =~ m{^https?://}) {
                    # Anthropic supports URL images
                    push @parts, {
                        type => 'image',
                        source => {
                            type => 'url',
                            url => $url,
                        },
                    };
                }
            }
            elsif ($part->{type} eq 'tool_result') {
                # Already in Anthropic format
                push @parts, $part;
            }
        }
        return {
            role => 'user',
            content => \@parts,
        };
    }
    
    # Default: wrap as text
    return {
        role => 'user',
        content => $content,
    };
}

sub _convert_assistant_message {
    my ($self, $msg) = @_;
    
    my @content;
    
    # Add text content
    if ($msg->{content}) {
        push @content, {
            type => 'text',
            text => $msg->{content},
        };
    }
    
    # Add tool calls (convert from OpenAI to Anthropic format)
    if ($msg->{tool_calls}) {
        for my $tool_call (@{$msg->{tool_calls}}) {
            my $arguments = $tool_call->{function}{arguments};
            # Parse if string
            if (!ref($arguments)) {
                eval { $arguments = decode_json($arguments); };
                $arguments = {} if $@;
            }
            
            push @content, {
                type => 'tool_use',
                id => $tool_call->{id},
                name => $tool_call->{function}{name},
                input => $arguments,
            };
        }
    }
    
    # Anthropic requires content to be an array when tool_use is present,
    # but can be a simple string for text-only responses
    if (@content == 1 && $content[0]{type} eq 'text') {
        return {
            role => 'assistant',
            content => $content[0]{text},
        };
    }
    
    return {
        role => 'assistant',
        content => \@content,
    };
}

sub _convert_tool_result_message {
    my ($self, $msg) = @_;
    
    # OpenAI format: { role => 'tool', tool_call_id => '...', content => '...' }
    # Anthropic format: { role => 'user', content => [{ type => 'tool_result', ... }] }
    
    my $content = $msg->{content};
    # Ensure content is a string for Anthropic
    if (ref($content)) {
        $content = encode_json($content);
    }
    
    return {
        role => 'user',
        content => [{
            type => 'tool_result',
            tool_use_id => $msg->{tool_call_id},
            content => $content // '',
        }],
    };
}

sub _map_stop_reason {
    my ($self, $anthropic_reason) = @_;
    
    my %reason_map = (
        'end_turn' => 'stop',
        'stop_sequence' => 'stop',
        'tool_use' => 'tool_calls',
        'max_tokens' => 'length',
    );
    
    return $reason_map{$anthropic_reason} // 'stop';
}

1;

__END__

=head1 STREAMING PROTOCOL

Anthropic's Messages API uses Server-Sent Events (SSE) with these event types:

=over 4

=item message_start

Initial message metadata and input token count.

=item content_block_start

New content block beginning (text, tool_use, or thinking).

=item content_block_delta

Content being streamed (text_delta, input_json_delta, or thinking_delta).

=item content_block_stop

Content block complete. For tool_use blocks, accumulated JSON is parsed.

=item message_delta

Final message metadata including stop_reason and output token count.

=item message_stop

Stream complete.

=item error

Error occurred.

=back

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0-only

=cut