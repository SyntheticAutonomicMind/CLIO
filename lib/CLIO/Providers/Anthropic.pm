package CLIO::Providers::Anthropic;

use strict;
use warnings;
use parent 'CLIO::Providers::Base';
use CLIO::Util::JSON qw(encode_json decode_json);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::Providers::Anthropic - Native Anthropic Messages API provider

=head1 DESCRIPTION

Implements the Anthropic Messages API for Claude models.
Handles the translation between CLIO's OpenAI-compatible format
and Anthropic's native API format.

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
3. Tool calls are 'tool_use' content blocks
4. Tool results are 'tool_result' content in user messages
5. Streaming uses different event types (content_block_delta, etc.)

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
    
    $self->{api_base} //= DEFAULT_API_BASE;
    $self->{model} //= DEFAULT_MODEL;
    $self->{max_tokens} = $opts{max_tokens} // DEFAULT_MAX_TOKENS;
    
    # Track current tool call being streamed
    $self->{_current_tool_call} = undef;
    $self->{_accumulated_json} = '';
    
    # Track if we're currently in a thinking block
    $self->{_in_thinking_block} = 0;
    
    return $self;
}

=head2 build_request($messages, $tools, $options)

Build an HTTP request for Anthropic's Messages API.

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

=cut

sub get_headers {
    my ($self) = @_;
    
    return {
        'Content-Type' => 'application/json',
        'x-api-key' => $self->{api_key},
        'anthropic-version' => ANTHROPIC_VERSION,
        'Accept' => 'text/event-stream',
    };
}

=head2 parse_stream_event($line)

Parse a single line from Anthropic's streaming response.

Anthropic uses Server-Sent Events (SSE) format:
  event: message_start
  data: {"type":"message_start",...}
  
  event: content_block_delta
  data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}

=cut

sub parse_stream_event {
    my ($self, $line) = @_;
    
    # Skip empty lines
    return undef if !defined $line || $line eq '' || $line =~ /^\s*$/;
    
    # Skip event type lines (we parse from data)
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
        # Extract usage from message_start if available
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
        elsif ($block_type eq 'thinking') {
            # Thinking block starting (reasoning model)
            $self->{_in_thinking_block} = 1;
            return {
                type => 'thinking_start',
            };
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
        elsif ($delta_type eq 'thinking_delta') {
            # Thinking content delta (reasoning model)
            return {
                type => 'thinking',
                content => $delta->{thinking} // '',
            };
        }
        elsif ($delta_type eq 'signature_delta') {
            # Thinking signature delta - ignore for display purposes
            return undef;
        }
        elsif ($delta_type eq 'input_json_delta') {
            # Accumulate partial JSON for tool arguments
            $self->{_accumulated_json} .= $delta->{partial_json} // '';
            return {
                type => 'tool_args',
                content => $delta->{partial_json} // '',
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
                    $self->debug("Failed to parse tool arguments: $@");
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
        
        # Check if we were in a thinking block
        if ($self->{_in_thinking_block}) {
            $self->{_in_thinking_block} = 0;
            return {
                type => 'thinking_end',
            };
        }
        
        return undef;
    }
    elsif ($event_type eq 'message_delta') {
        # May contain stop reason and final usage
        my $delta = $data->{delta};
        if ($delta && $delta->{stop_reason}) {
            return {
                type => 'stop',
                stop_reason => $self->_map_stop_reason($delta->{stop_reason}),
            };
        }
        return undef;
    }
    elsif ($event_type eq 'message_stop') {
        return { type => 'done' };
    }
    elsif ($event_type eq 'error') {
        return {
            type => 'error',
            message => $data->{error}{message} // 'Unknown error',
        };
    }
    
    # Unknown event type
    return undef;
}

=head2 convert_messages($messages)

Convert OpenAI-format messages to Anthropic format.

=cut

sub convert_messages {
    my ($self, $messages) = @_;
    
    my @anthropic_messages;
    
    for my $msg (@$messages) {
        my $role = $msg->{role};
        
        # Skip system messages (handled separately)
        next if $role eq 'system';
        
        if ($role eq 'user') {
            push @anthropic_messages, $self->_convert_user_message($msg);
        }
        elsif ($role eq 'assistant') {
            push @anthropic_messages, $self->_convert_assistant_message($msg);
        }
        elsif ($role eq 'tool') {
            # Tool results are added to the user message in Anthropic format
            # This should be handled specially when building the full message list
            push @anthropic_messages, $self->_convert_tool_result_message($msg);
        }
    }
    
    return \@anthropic_messages;
}

=head2 convert_tool($tool)

Convert an OpenAI-format tool to Anthropic format.

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

=cut

sub convert_tool_result {
    my ($self, $tool_call_id, $result, $is_error) = @_;
    
    my $content = {
        type => 'tool_result',
        tool_use_id => $tool_call_id,
        content => ref($result) ? encode_json($result) : ($result // ''),
    };
    
    if ($is_error) {
        $content->{is_error} = JSON::PP::true;
    }
    
    return {
        role => 'user',
        content => [$content],
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
    
    # Array of content parts (for images, etc.)
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
            }
        }
        return {
            role => 'user',
            content => \@parts,
        };
    }
    
    # Default: wrap as is
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
    
    # Add tool calls
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
    
    return {
        role => 'assistant',
        content => @content == 1 && $content[0]{type} eq 'text' 
            ? $content[0]{text}  # Simple string for text-only
            : \@content,         # Array for mixed content
    };
}

sub _convert_tool_result_message {
    my ($self, $msg) = @_;
    
    # OpenAI format: { role => 'tool', tool_call_id => '...', content => '...' }
    # Anthropic format: { role => 'user', content => [{ type => 'tool_result', ... }] }
    
    return {
        role => 'user',
        content => [{
            type => 'tool_result',
            tool_use_id => $msg->{tool_call_id},
            content => $msg->{content} // '',
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

New content block (text or tool_use) beginning.

=item content_block_delta

Content being streamed (text_delta or input_json_delta).

=item content_block_stop

Content block complete.

=item message_delta

Final message metadata including stop_reason.

=item message_stop

Stream complete.

=item error

Error occurred.

=back

=head1 AUTHOR

CLIO Project

=cut
