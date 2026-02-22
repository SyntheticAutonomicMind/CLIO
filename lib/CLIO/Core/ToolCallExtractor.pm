package CLIO::Core::ToolCallExtractor;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Util::JSON qw(encode_json decode_json);
use CLIO::Core::Logger qw(should_log log_debug log_warning);

=head1 NAME

CLIO::Core::ToolCallExtractor - Extract tool calls from AI response text

=head1 DESCRIPTION

Parses various tool call formats from AI-generated text content.
Supports multiple formats for compatibility with different LLM providers:

- OpenAI structured format (already handled by APIManager)
- `[tool_name operation]` + JSON block (CLIO legacy format)
- `<tool_call>...</tool_call>` XML tags (llama.cpp, Qwen)
- `CALL tool_name: {...}` format
- JSON code blocks with tool calls

Based on SAM's ToolCallExtractor.swift pattern.

=head1 SYNOPSIS

    my $extractor = CLIO::Core::ToolCallExtractor->new(debug => 1);
    
    my $result = $extractor->extract($ai_content);
    # Returns: {
    #   tool_calls => [...],      # Array of structured tool calls
    #   cleaned_content => "...", # Content with tool calls removed
    #   format => "..."           # Detected format
    # }

=cut

sub new {
    my ($class, %opts) = @_;
    
    return bless {
        debug => $opts{debug} || 0,
    }, $class;
}

=head2 extract

Extract tool calls from AI response content.

Arguments:
- $content: AI response text

Returns: Hashref with:
- tool_calls: Array of tool call hashrefs (OpenAI format)
- cleaned_content: Content with tool calls removed
- format: Detected format string

=cut

sub extract {
    my ($self, $content) = @_;
    
    return {
        tool_calls => [],
        cleaned_content => $content,
        format => 'none'
    } unless $content && $content =~ /\S/;
    
    log_debug('ToolCallExtractor', "Analyzing content for tool calls");
    
    # Try each format in order of specificity
    
    # 1. XML tag format: <tool_call>...</tool_call>
    if ($content =~ /<tool_call>/) {
        log_debug('ToolCallExtractor', "Detected XML tool_call format");
        return $self->_extract_xml_format($content);
    }
    
    # 2. CLIO format: [tool_name operation]\n{...}
    if ($content =~ /\[(\w+)\s+(\w+)\]/) {
        log_debug('ToolCallExtractor', "Detected CLIO [tool_name operation] format");
        return $self->_extract_clio_format($content);
    }
    
    # 3. CALL format: CALL tool_name: {...}
    if ($content =~ /\bCALL\s+(\w+):/i) {
        log_debug('ToolCallExtractor', "Detected CALL tool_name format");
        return $self->_extract_call_format($content);
    }
    
    # 4. JSON code block format: ```json\n[{...}]\n```
    if ($content =~ /```(?:json)?\s*\n/) {
        log_debug('ToolCallExtractor', "Detected JSON code block format");
        return $self->_extract_json_blocks($content);
    }
    
    # No tool calls detected
    log_debug('ToolCallExtractor', "No tool calls detected");
    return {
        tool_calls => [],
        cleaned_content => $content,
        format => 'none'
    };
}

=head2 _extract_xml_format

Extract <tool_call>...</tool_call> XML format.

Format:
    <tool_call>
    {
      "name": "tool_name",
      "arguments": {...}
    }
    </tool_call>

=cut

sub _extract_xml_format {
    my ($self, $content) = @_;
    
    my @tool_calls = ();
    my $cleaned = $content;
    
    # Extract all <tool_call>...</tool_call> blocks
    while ($content =~ /<tool_call>\s*(.+?)\s*<\/tool_call>/gs) {
        my $json_str = $1;
        
        log_debug('ToolCallExtractor', "Found XML tool_call block");
        
        # Parse JSON
        my $data = eval { decode_json($json_str) };
        if ($@) {
            log_warning('ToolCallExtractor', "Failed to parse XML tool_call JSON: $@");
            next;
        }
        
        # Convert to OpenAI format
        if ($data->{name}) {
            my $arguments = $data->{arguments};
            if (ref($arguments) eq 'HASH' || ref($arguments) eq 'ARRAY') {
                require JSON::PP;
                $arguments = encode_json($arguments);
            }
            
            push @tool_calls, {
                id => $data->{id} || $self->_generate_id(),
                type => 'function',
                function => {
                    name => $data->{name},
                    arguments => $arguments || '{}'
                }
            };
        }
    }
    
    # Remove tool_call blocks from content
    $cleaned =~ s/<tool_call>.*?<\/tool_call>//gs;
    $cleaned =~ s/^\s+|\s+$//g;  # Trim
    
    return {
        tool_calls => \@tool_calls,
        cleaned_content => $cleaned,
        format => 'xml'
    };
}

=head2 _extract_clio_format

Extract CLIO format: [tool_name operation]\n{...}

Format:
    [todo_operations write]
    {
      "operation": "write",
      "todoList": [...]
    }

=cut

sub _extract_clio_format {
    my ($self, $content) = @_;
    
    my @tool_calls = ();
    my $cleaned = $content;
    
    # Match [tool_name operation] followed by optional newlines and then a JSON block
    while ($content =~ /\[(\w+)\s+(\w+)\]\s*\n?\s*(\{(?:[^{}]|(?3))*\}|\[(?:[^\[\]]|(?3))*\])/gs) {
        my ($tool_name, $operation, $json_str) = ($1, $2, $3);
        
        log_debug('ToolCallExtractor', "Found CLIO format: [$tool_name $operation]");
        
        # The JSON might already contain the operation, or we need to wrap it
        my $arguments_data = eval { decode_json($json_str) };
        if ($@) {
            log_warning('ToolCallExtractor', "Failed to parse CLIO format JSON: $@");
            next;
        }
        
        # Ensure operation field is set if not already present
        if (ref($arguments_data) eq 'HASH' && !exists $arguments_data->{operation}) {
            $arguments_data->{operation} = $operation;
        }
        
        # Re-encode as JSON string
        require JSON::PP;
        my $arguments_json = encode_json($arguments_data);
        
        push @tool_calls, {
            id => $self->_generate_id(),
            type => 'function',
            function => {
                name => $tool_name,
                arguments => $arguments_json
            }
        };
    }
    
    # Remove [tool_name operation] + JSON blocks from content
    $cleaned =~ s/\[(\w+)\s+(\w+)\]\s*\n?\s*(\{(?:[^{}]|(?3))*\}|\[(?:[^\[\]]|(?3))*\])//gs;
    $cleaned =~ s/^\s+|\s+$//g;
    
    return {
        tool_calls => \@tool_calls,
        cleaned_content => $cleaned,
        format => 'clio'
    };
}

=head2 _extract_call_format

Extract CALL format: CALL tool_name: {...}

Format:
    CALL file_operations: {
      "operation": "read",
      "path": "file.txt"
    }

=cut

sub _extract_call_format {
    my ($self, $content) = @_;
    
    my @tool_calls = ();
    my $cleaned = $content;
    
    # Match CALL tool_name: followed by JSON
    while ($content =~ /\bCALL\s+(\w+):\s*(\{(?:[^{}]|(?2))*\}|\[(?:[^\[\]]|(?2))*\])/gsi) {
        my ($tool_name, $json_str) = ($1, $2);
        
        log_debug('ToolCallExtractor', "Found CALL format: CALL $tool_name");
        
        # Validate JSON
        my $arguments_data = eval { decode_json($json_str) };
        if ($@) {
            log_warning('ToolCallExtractor', "Failed to parse CALL format JSON: $@");
            next;
        }
        
        push @tool_calls, {
            id => $self->_generate_id(),
            type => 'function',
            function => {
                name => $tool_name,
                arguments => $json_str
            }
        };
    }
    
    # Remove CALL blocks from content
    $cleaned =~ s/\bCALL\s+(\w+):\s*(\{(?:[^{}]|(?2))*\}|\[(?:[^\[\]]|(?2))*\])//gsi;
    $cleaned =~ s/^\s+|\s+$//g;
    
    return {
        tool_calls => \@tool_calls,
        cleaned_content => $cleaned,
        format => 'call'
    };
}

=head2 _extract_json_blocks

Extract tool calls from JSON code blocks.

Format:
    ```json
    [{
      "name": "tool_name",
      "arguments": {...}
    }]
    ```

=cut

sub _extract_json_blocks {
    my ($self, $content) = @_;
    
    my @tool_calls = ();
    my $cleaned = $content;
    
    # Match ```json or ``` followed by JSON
    while ($content =~ /```(?:json)?\s*\n(.+?)\n```/gs) {
        my $json_str = $1;
        
        log_debug('ToolCallExtractor', "Found JSON code block");
        
        # Parse JSON
        my $data = eval { decode_json($json_str) };
        if ($@) {
            log_debug('ToolCallExtractor', "Not a valid JSON block: $@");
            next;
        }
        
        # Check if it's tool call format
        my @calls = ref($data) eq 'ARRAY' ? @$data : ($data);
        
        for my $call (@calls) {
            next unless ref($call) eq 'HASH';
            next unless $call->{name};
            
            my $arguments = $call->{arguments};
            if (ref($arguments) eq 'HASH' || ref($arguments) eq 'ARRAY') {
                require JSON::PP;
                $arguments = encode_json($arguments);
            }
            
            push @tool_calls, {
                id => $call->{id} || $self->_generate_id(),
                type => 'function',
                function => {
                    name => $call->{name},
                    arguments => $arguments || '{}'
                }
            };
        }
    }
    
    # Only remove code blocks if they contained tool calls
    if (@tool_calls) {
        $cleaned =~ s/```(?:json)?\s*\n.+?\n```//gs;
        $cleaned =~ s/^\s+|\s+$//g;
    }
    
    return {
        tool_calls => \@tool_calls,
        cleaned_content => $cleaned,
        format => 'json_block'
    };
}

=head2 _generate_id

Generate a unique tool call ID.

=cut

sub _generate_id {
    my ($self) = @_;
    
    # Generate random ID similar to OpenAI format
    return sprintf('call_%s', join('', map { ('a'..'z', 0..9)[rand 36] } 1..24));
}

1;
