# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Providers::Anthropic;

use strict;
use warnings;
use utf8;
use parent 'CLIO::Providers::Base';
use CLIO::Util::JSON qw(encode_json decode_json);
use CLIO::Core::Logger qw(log_debug log_warning);
# JSON::PP is loaded for the boolean constant (JSON::PP::true) which
# CLIO::Util::JSON::encode_json serializes as JSON `true` (a plain Perl
# 1 is serialized as `1`, not `true`). Use the empty import list to avoid
# a prototype-mismatch conflict with CLIO::Util::JSON's encode_json.
use JSON::PP ();

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
use constant DEFAULT_MAX_TOKENS => 16384;
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
    
    # Normalize api_base: if it doesn't contain a versioned path (i.e. it's
    # just a root URL like https://proxy.example.com or
    # https://proxy.example.com:8443), append the standard Anthropic
    # messages path.
    if ($self->{api_base} && $self->{api_base} !~ m{/v\d+/}) {
        $self->{api_base} =~ s{/+$}{};
        $self->{api_base} .= '/v1/messages';
        log_debug('Anthropic', "Normalized api_base to: $self->{api_base}");
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
            # Fallback: try newline-separated "key: value" format
            my %parsed;
            for my $line (split /\\n|\n/, $ENV{ANTHROPIC_CUSTOM_HEADERS}) {
                if ($line =~ /^([^:]+):\s*(.*)$/) {
                    $parsed{$1} = $2;
                }
            }
            if (%parsed) {
                %all_custom_headers = (%all_custom_headers, %parsed);
            } else {
                log_warning('Anthropic', "Failed to parse ANTHROPIC_CUSTOM_HEADERS: $@");
            }
        }
    }
    $self->{custom_headers} = \%all_custom_headers;
    
    # Track current tool call being streamed
    $self->{_current_tool_call} = undef;
    $self->{_accumulated_json} = '';
    # Track current thinking block being streamed (signature captured here)
    $self->{_current_thinking} = undef;
    # Accumulated thinking blocks (with signature + redacted_thinking data) for round-trip
    $self->{_thinking_blocks} = [];

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
    
    # Resolve the effective model for this request (may differ from instance default)
    my $effective_model = $options->{model} // $self->{model};
    
    # Separate system prompt from messages
    my ($system_prompt, $conversation) = $self->_separate_system_prompt($messages);
    
    # Convert messages to Anthropic format
    my $anthropic_messages = $self->convert_messages($conversation);
    
    # Build request payload
    my $payload = {
        model => $effective_model,
        max_tokens => $options->{max_tokens} // $self->{max_tokens},
        stream => JSON::PP::true,
        messages => $anthropic_messages,
    };
    
    # Add system prompt if present
    if ($system_prompt) {
        $payload->{system} = [{
            type          => 'text',
            text          => $system_prompt,
            cache_control => { type => 'ephemeral' },
        }];
    }
    
    # Add tools if present
    if ($tools && @$tools) {
        my @converted_tools = map { $self->convert_tool($_) } @$tools;
        if (@converted_tools) {
            $converted_tools[-1]{cache_control} = { type => 'ephemeral' };
            $payload->{tools} = \@converted_tools;
        }
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
    
    # Extended thinking support.
    # $options->{thinking} is a hashref built by APIManager describing what thinking
    # configuration the caller wants. Shape:
    #   { enabled => 1, effort => 'low|medium|high', budget_tokens => N, mode => 'enabled|adaptive' }
    # When APIManager passes thinking => { enabled => 0 }, thinking is fully disabled.
# When no thinking option is passed, thinking defaults to disabled. The caller
# (APIManager._send_native_streaming) owns the decision and always passes an
# explicit thinking config when it wants thinking enabled.
    my $thinking = $options->{thinking};
    my $model = $effective_model;
    my $thinking_enabled = 0;

    if ($thinking && ref($thinking) eq 'HASH') {
        # Caller provided explicit thinking config
        if ($thinking->{enabled}) {
            # Fill in defaults for partial configs
            $thinking = $self->_default_thinking_config($model, $thinking);
            $thinking_enabled = 1;
        }
        # else: enabled => 0, thinking is fully disabled
    }
    else {
        # No thinking option passed - default to disabled. The caller should
        # always pass an explicit thinking config when it wants thinking enabled.
        $thinking = { enabled => 0 };
        $thinking_enabled = 0;
    }

    # Apply thinking to payload when enabled
    if ($thinking_enabled && $thinking->{mode}) {
        if ($thinking->{mode} eq 'enabled') {
            # Anthropic requires max_tokens > budget_tokens. Ensure the output
            # budget covers both thinking and response tokens.
            my $budget = $thinking->{budget_tokens};
            my $min_max_tokens = $budget + 4096;  # 4096 minimum response budget
            if ($payload->{max_tokens} <= $budget) {
                log_debug('Anthropic', "Adjusting max_tokens from $payload->{max_tokens} to $min_max_tokens (budget_tokens=$budget + 4096 response)");
                $payload->{max_tokens} = $min_max_tokens;
            }
            $payload->{thinking} = {
                type => 'enabled',
                budget_tokens => $budget,
            };
        }
        elsif ($thinking->{mode} eq 'adaptive') {
            # Adaptive thinking: type goes in the thinking block, effort
            # goes in output_config (TOP-LEVEL field, not inside thinking).
            # Per Anthropic docs:
            #   thinking: { type: "adaptive", display: "summarized" }
            #   output_config: { effort: "low"|"medium"|"high"|"xhigh"|"max" }
            # Sending effort inside the thinking block is silently ignored
            # by the API and produces no behavior change.
            $payload->{thinking} = {
                type   => 'adaptive',
                # display='summarized' makes thinking text visible to CLIO.
                # 'omitted' is the default on Fable 5 / Mythos 5 / Sonnet 5 /
                # Opus 4.8 / Opus 4.7 (returns empty thinking field). We set
                # 'summarized' explicitly so thinking text is available across
                # all adaptive-capable models. No extra cost - charged for
                # original thinking tokens, not the summary.
                display => 'summarized',
            };
            if ($thinking->{effort} && $thinking->{effort} ne 'medium') {
                # Accepted values: low|medium|high|xhigh|max.
                # 'medium' is the default and may be omitted. Other values
                # are forwarded verbatim so future effort levels reach
                # the API without a CLIO update.
                $payload->{output_config}{effort} = $thinking->{effort};
            }
        }
    }

    # When thinking is enabled, Anthropic requires temperature=1 and forbids
    # top_k. top_p is allowed but only in the range [0.95, 1]. Remove
    # incompatible sampling parameters to avoid 400 errors.
    if ($payload->{thinking}) {
        $payload->{temperature} = 1;
        delete $payload->{top_k};
        if (exists $payload->{top_p} && $payload->{top_p} < 0.95) {
            $payload->{top_p} = 0.95;
        }
    }

    $self->debug("Built Anthropic request with " . scalar(@$anthropic_messages) . " messages");
    
    return {
        url => $self->{api_base},
        method => 'POST',
        headers => $self->get_headers($effective_model),
        body => encode_json($payload),
    };
}

=head2 get_headers($model)

Get HTTP headers for Anthropic API requests.

Arguments:
  $model - Optional model name override. When provided, used to determine
           whether the interleaved-thinking beta header is needed. Falls
           back to the instance default model.

Returns: Hashref of HTTP headers

=cut

sub get_headers {
    my ($self, $model) = @_;
    
    $model //= $self->{model};

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

    # Interleaved thinking beta header. Required for Sonnet 4.5 / Opus 4.5 / Opus 4.1
    # (and earlier) to use thinking blocks before tool calls and to round-trip the
    # signature on subsequent turns. 4.6+ models support this without the beta header.
    if ($self->_needs_interleaved_thinking_beta($model)) {
        my $betas = $headers{'anthropic-beta'};
        my @beta_list = $betas ? split(/\s*,\s*/, $betas) : ();
        push @beta_list, 'interleaved-thinking-2025-05-14' unless grep { $_ eq 'interleaved-thinking-2025-05-14' } @beta_list;
        $headers{'anthropic-beta'} = join(',', @beta_list);
    }

    return \%headers;
}

=head2 get_thinking_blocks()

Return the arrayref of thinking blocks (with signature) accumulated during the
current streaming response. Caller should clear them via clear_thinking_blocks
after persisting to the assistant message.

Returns: Arrayref of thinking blocks; each is either:
  { type => 'thinking', signature => '...' }  (text captured via on_thinking)
  { type => 'redacted_thinking', data => '...' }

=cut

sub get_thinking_blocks {
    my ($self) = @_;
    return $self->{_thinking_blocks} || [];
}

sub clear_thinking_blocks {
    my ($self) = @_;
    $self->{_thinking_blocks} = [];
    $self->{_current_thinking} = undef;
    $self->{_final_usage} = undef;
}

=head2 get_final_usage()

Return the final usage data captured from message_delta event, if any.
This is used when message_delta contains both stop_reason and usage,
where only the stop event can be returned from parse_stream_event.

Returns: Hashref with output_tokens, or undef if not available.

=cut

sub get_final_usage {
    my ($self) = @_;
    return $self->{_final_usage};
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
        utf8::encode($line) if utf8::is_utf8($line);
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
            # Extended thinking block starting. Anthropic may include a 'signature'
            # on the initial content_block_start; if so, capture it for round-trip
            # (the model requires the signature on the previous turn's thinking block
            # when interleaved thinking is enabled).
            # Initialize text => '' so the thinking_delta handler can accumulate into
            # it; without this the text was computed for display but never persisted
            # into _thinking_blocks, and on providers/modes that require the prior
            # turn's thinking text to round-trip with the model, the text was
            # silently lost after being shown once.
            $self->{_current_thinking} = {
                type => 'thinking',
                signature => $block->{signature},
                text      => '',
            };
            log_debug('Anthropic', 'thinking block start (signature=' . ($block->{signature} ? 'yes' : 'no') . ')');
            return {
                type => 'thinking_start',
                content => '',
            };
        }
        elsif ($block_type eq 'redacted_thinking') {
            # Anthropic may redact thinking blocks (when safety filtering trips).
            # The encrypted 'data' blob must be passed back verbatim on subsequent
            # turns, or the API rejects the request.
            my $rb = {
                type => 'redacted_thinking',
                data => $block->{data} // '',
            };
            push @{$self->{_thinking_blocks}}, $rb;
            $self->{_current_thinking} = undef;
            return {
                type => 'thinking_redacted',
                data => $rb->{data},
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
            # Extended thinking content. The Anthropic native API uses
            # delta.thinking, but some proxies/variants emit delta.text
            # or delta.reasoning_content for the same event. Check all
            # three so we render thinking content from compatible proxies
            # that diverge from the upstream field name.
            my $thinking_text = $delta->{thinking} // $delta->{text} // $delta->{reasoning_content} // '';
            # Accumulate the text into the current thinking block so it
            # round-trips with the model on the next turn. Without this
            # the text was shown once and then silently dropped.
            if (length $thinking_text) {
                $self->{_current_thinking}{text} .= $thinking_text
                    if $self->{_current_thinking};
            }
            return {
                type => 'thinking',
                content => $thinking_text,
            };
        }
        elsif ($delta_type eq 'signature_delta') {
            # Anthropic streams the signature as a separate delta after the thinking
            # content. Capture it so we can round-trip it.
            $self->{_current_thinking}{signature} = $delta->{signature}
                if $self->{_current_thinking};
            return undef;  # internal bookkeeping only
        }
    }
    elsif ($event_type eq 'content_block_stop') {
        # If we just finished a thinking block, persist it for round-trip.
        if ($self->{_current_thinking} && $self->{_current_thinking}{type} eq 'thinking') {
            log_debug('Anthropic', 'thinking block stop (text_len=' . length($self->{_current_thinking}{text} // '') . ', signature=' . ($self->{_current_thinking}{signature} ? 'yes' : 'no') . ')');
            push @{$self->{_thinking_blocks}}, $self->{_current_thinking};
            $self->{_current_thinking} = undef;
            return {
                type => 'thinking_end',
            };
        }

        # Check if we were accumulating a tool call
        if ($self->{_current_tool_call}) {
            my $tool_call = $self->{_current_tool_call};
            $self->{_current_tool_call} = undef;
            
            # Parse accumulated arguments
            my $arguments = {};
            if ($self->{_accumulated_json}) {
                eval {
                    my $json_str = $self->{_accumulated_json};
                    utf8::encode($json_str) if utf8::is_utf8($json_str);
                    $arguments = decode_json($json_str);
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
        
        # If both stop_reason and usage are present, we can only return one event
        # per parse_stream_event call. Prioritize stop_reason (critical for stream
        # termination) but store usage for later retrieval via get_final_usage().
        if ($delta && $delta->{stop_reason}) {
            # Store usage if present for later retrieval
            $self->{_final_usage} = $usage if $usage;
            return {
                type => 'stop',
                stop_reason => $self->_map_stop_reason($delta->{stop_reason}),
            };
        }
        
        if ($usage) {
            return {
                type => 'usage',
                output_tokens => $usage->{output_tokens} // 0,
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

    # Anthropic requires thinking blocks to come FIRST in the content array,
    # in the order they were emitted, with their original signatures preserved.
    # Without the signature the API rejects the request on subsequent turns
    # (when extended thinking + tool use is enabled).
    if ($msg->{reasoning_blocks} && ref($msg->{reasoning_blocks}) eq 'ARRAY') {
        for my $block (@{$msg->{reasoning_blocks}}) {
            next unless ref($block) eq 'HASH';
            if (($block->{type} // '') eq 'redacted_thinking') {
                push @content, {
                    type => 'redacted_thinking',
                    data => $block->{data} // '',
                };
            }
            elsif (($block->{type} // '') eq 'thinking') {
                # Thinking blocks need both the text AND the signature.
                # Text comes from reasoning_content (set by WorkflowOrchestrator)
                # or from the block's own text field.
                my $thinking_text = $block->{text} // $msg->{reasoning_content} // '';
                push @content, {
                    type => 'thinking',
                    thinking => $thinking_text,
                    signature => $block->{signature} // '',
                };
            }
        }
    }
    elsif ($msg->{reasoning_content} && $msg->{reasoning_signature}) {
        # Legacy single-block round-trip (no reasoning_blocks array).
        push @content, {
            type => 'thinking',
            thinking => $msg->{reasoning_content},
            signature => $msg->{reasoning_signature},
        };
    }

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
                eval {
                    utf8::encode($arguments) if utf8::is_utf8($arguments);
                    $arguments = decode_json($arguments);
                };
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

=head2 _supports_adaptive_thinking($model)

Returns true if the given Anthropic model supports the adaptive thinking
mode (4.6+ family). Adaptive drops the budget_tokens field and lets the
model decide based on the effort hint.

=cut

sub _supports_adaptive_thinking {
    my ($self, $model) = @_;
    return 0 unless defined $model && length $model;
    # 4.6+ family: claude-{family}-{major}-6, -7, -8, plus non-versioned names
    # (e.g. claude-mythos). 4.5 and earlier use the older enabled+budget_tokens
    # form. Be conservative: anything we don't recognize as 4.6+ uses 'enabled'.
    return 1 if $model =~ /-(?:opus|sonnet|haiku)-4-(?:[6-9]|\d{2,})$/i;
    return 1 if $model =~ /^claude-mythos/i;
    return 0;
}

=head2 _needs_interleaved_thinking_beta($model)

Anthropic's interleaved-thinking beta header is required for Sonnet 4.5,
Opus 4.5, and Opus 4.1 to use extended thinking across tool calls. Models
released after 4.5 accept the parameter natively without the header; for
those models this returns false.

=cut

sub _needs_interleaved_thinking_beta {
    my ($self, $model) = @_;
    return 0 unless defined $model && length $model;
    # 4.6+ family doesn't need the beta header.
    return 0 if $self->_supports_adaptive_thinking($model);
    # 4.5 and earlier (including 4.0, 4.1, 3.x) need it.
    return 1 if $model =~ /-(?:opus|sonnet|haiku)-4-[0-5]$/i;
    return 1 if $model =~ /-(?:opus|sonnet|haiku)-4-\d+-\d{8}$/i;  # dated 4.x
    return 1 if $model =~ /^claude-(?:opus|sonnet|haiku)-3/i;       # 3.x family
    # Unknown - default to requiring the beta header (safer).
    return 1;
}

=head2 _max_thinking_budget_for_model($model)

Returns the maximum thinking budget in tokens for the given model. For
4.6+ (adaptive) this is informational only - the API no longer uses it.

Anthropic spec:
  - 4.5 family (Sonnet/Opus/Haiku): 32k for Sonnet/Opus, 8k for Haiku 4.5
  - 4.0/4.1: 32k
  - 3.7 Sonnet: 64k
  - 3.x (older): 32k recommended

=cut

sub _max_thinking_budget_for_model {
    my ($self, $model) = @_;
    return 32000 unless defined $model && length $model;
    return 8000 if $model =~ /-haiku-4-5$/i;
    return 64000 if $model =~ /-3-7-sonnet/i;
    return 32000;
}

=head2 _default_thinking_config($model, $opts)

Build a default thinking config hashref for the given model and effort.

Inputs:
  $model - Anthropic model name
  $opts  - optional hashref with { enabled => 1, effort => 'low|medium|high' }

Returns a hashref with:
  enabled       - 1/0
  mode          - 'enabled' or 'adaptive' (or undef if disabled)
  effort        - 'low'|'medium'|'high'|'xhigh'|'max' (for adaptive) or for budget sizing
  budget_tokens - integer for 'enabled' mode (clamped to model max)

When called without $opts, returns the default config (enabled, medium effort).

=cut

sub _default_thinking_config {
    my ($self, $model, $opts) = @_;
    $opts //= {};

    my $enabled = exists $opts->{enabled} ? $opts->{enabled} : 1;
    return { enabled => 0 } unless $enabled;

    my $effort = $opts->{effort} // 'medium';
    # Accept any Anthropic-defined effort level. Known values today:
    #   low|medium|high - all adaptive-capable models
    #   xhigh           - Fable 5, Mythos 5, Opus 4.8, Opus 4.7, Sonnet 5
    #   max             - all adaptive-capable models (no depth limit)
    # Future levels (xhighest, etc.) pass through verbatim. Unknown
    # values fall back to 'medium' to avoid sending malformed payloads
    # to the API.
    $effort = 'medium' unless $effort =~ /^(?:low|medium|high|xhigh|max)$/;

    my $max = $self->_max_thinking_budget_for_model($model);

    # Prefer explicit mode from thinking_opt (set by APIManager from capabilities).
    # Fall back to regex-based detection for backward compatibility.
    my $adaptive = exists $opts->{mode}
        ? ($opts->{mode} eq 'adaptive')
        : $self->_supports_adaptive_thinking($model);

    if ($adaptive) {
        return {
            enabled => 1,
            mode    => 'adaptive',
            effort  => $effort,
        };
    }

    # 'enabled' mode: budget maps from effort. Anthropic docs recommend
    # 1024 minimum, 16k+ for complex tasks. We use 4k/10k/20k for
    # low/medium/high (clamped to model max).
    # 'xhigh' maps to 32k - deeper reasoning than 'high', useful for
    # complex agent loops and long-horizon planning tasks.
    # 'max' maps to the model max budget - no soft constraint, only the
    # hard max_tokens ceiling applies.
    # Note: build_request() ensures max_tokens > budget_tokens + 4096
    # (minimum response budget) as a safety net.
    my %effort_to_budget = (
        low    => 4096,
        medium => 10240,
        high   => 20480,
        xhigh  => 32768,
        max    => 65536,    # highest standard budget; model max clamps if needed
    );
    my $budget = $effort_to_budget{$effort};
    $budget = $max if $budget > $max;
    $budget = 1024 if $budget < 1024;

    return {
        enabled       => 1,
        mode          => 'enabled',
        effort        => $effort,
        budget_tokens => $budget,
    };
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