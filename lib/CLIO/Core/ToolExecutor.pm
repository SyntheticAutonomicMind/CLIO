package CLIO::Core::ToolExecutor;

use strict;
use warnings;
use utf8;
use Encode qw(decode encode);
use CLIO::Core::Logger qw(should_log);
use CLIO::Util::JSONRepair qw(repair_malformed_json);
use JSON::PP qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64 decode_base64);
use CLIO::Session::ToolResultStore;
use CLIO::Logging::ToolLogger;
use Time::HiRes qw(time);

=head1 NAME

CLIO::Core::ToolExecutor - Bridge between AI tool calls and protocol handlers

=head1 DESCRIPTION

Maps OpenAI-format tool calls to CLIO protocol handlers.
This is the execution layer that connects the WorkflowOrchestrator
to the actual protocol implementations.

Handles large tool results via ResultStorage:
- Results <8KB: returned inline
- Results >8KB: saved to disk, preview + marker returned
- AI uses read_tool_result to fetch chunks

Tool Format (from AI):
    {
        "id": "call_abc123",
        "type": "function",
        "function": {
            "name": "file_operations",
            "arguments": "{\"operation\":\"read\",\"path\":\"README.md\"}"
        }
    }

Protocol Format (for handlers):
    [FILE_OP:read:path=<base64_path>]
    [GIT:action=status:params=<base64_params>]
    [URL_FETCH:action=fetch:params=<base64_url>]

=head1 SYNOPSIS

    use CLIO::Core::ToolExecutor;
    
    my $executor = CLIO::Core::ToolExecutor->new(
        session => $session,
        debug => 1
    );
    
    my $result = $executor->execute_tool($tool_call, $tool_call_id);

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        session => $args{session},
        tool_registry => $args{tool_registry},
        config => $args{config},  # Store config for API keys (web search, etc.)
        ui => $args{ui},  # Store UI for tools
        spinner => $args{spinner},  # Store spinner for interactive tools
        debug => $args{debug} || 0,
        storage => CLIO::Session::ToolResultStore->new(debug => $args{debug}),
    };
    
    bless $self, $class;
    
    # Initialize ToolLogger
    if ($args{session} && $args{session}->{session_id}) {
        $self->{tool_logger} = CLIO::Logging::ToolLogger->new(
            session_id => $args{session}->{session_id},
            debug => $args{debug}
        );
        print STDERR "[DEBUG][ToolExecutor] Initialized ToolLogger\n" if should_log('DEBUG');
    }
    
    # Debug: Log if UI is available
    if (should_log('DEBUG')) {
        if ($self->{ui}) {
            print STDERR "[DEBUG][ToolExecutor] UI available for tools\n";
        } else {
            print STDERR "[DEBUG][ToolExecutor] WARNING: UI is undefined - tools won't have collaboration access\n";
        }
    }
    
    print STDERR "[DEBUG][ToolExecutor] Initialized with ToolResultStore\n" if should_log('DEBUG');
    
    return $self;
}

=head2 execute_tool

Execute a tool call from the AI.

Arguments:
- $tool_call: Hashref with tool call details:
  * id: Tool call ID
  * type: 'function'
  * function: { name, arguments }
- $tool_call_id: The tool call ID (for storage)

Returns:
- JSON string with execution result

=cut

sub execute_tool {
    my ($self, $tool_call, $tool_call_id) = @_;
    
    my $start_time = time();  # Start timing
    
    # Validate tool call structure
    unless ($tool_call && ref($tool_call) eq 'HASH') {
        return $self->_error_result("Invalid tool call structure");
    }
    
    my $tool_name = $tool_call->{function}->{name};
    my $arguments_json = $tool_call->{function}->{arguments};
    
    unless ($tool_name && $arguments_json) {
        return $self->_error_result("Missing tool name or arguments");
    }
    
    print STDERR "[DEBUG][ToolExecutor] Executing tool: $tool_name (id=$tool_call_id)\n" if should_log('DEBUG');
    
    # Parse arguments with UTF-8 handling
    my $arguments;
    eval {
        # Repair malformed JSON from AI (e.g., "offset":, → "offset":null,)
        my $json_str = repair_malformed_json($arguments_json, should_log('DEBUG'));
        
        # decode_json expects BYTES (not Perl's internal UTF-8 character strings)
        # If the string is UTF-8 flagged (wide characters), encode it to bytes first
        if (utf8::is_utf8($json_str)) {
            # String has UTF-8 flag - encode to bytes
            utf8::encode($json_str);
        }
        $arguments = decode_json($json_str);
    };
    if ($@) {
        my $error = $@;
        print STDERR "[ERROR][ToolExecutor] JSON parse error: $error\n" if should_log('ERROR');
        
        # Log the error
        $self->_log_tool_operation({
            tool_call_id => $tool_call_id,
            tool_name => $tool_name,
            operation => 'parse_error',
            parameters => { raw_json => $arguments_json },
            output => {},
            action_description => "Failed to parse arguments",
            sent_to_ai => "ERROR: Failed to parse tool arguments: $error",
            success => 0,
            error => "JSON parse error: $error",
            execution_time_ms => int((time() - $start_time) * 1000)
        });
        
        return $self->_error_result("Failed to parse tool arguments: $error");
    }
    
    # Get tool from registry
    my $tool_registry = $self->{tool_registry};
    unless ($tool_registry) {
        return $self->_error_result("Tool registry not available");
    }
    
    my $tool = $tool_registry->get_tool($tool_name);
    unless ($tool) {
        # Log unknown tool error
        $self->_log_tool_operation({
            tool_call_id => $tool_call_id,
            tool_name => $tool_name,
            operation => 'unknown',
            parameters => $arguments,
            output => {},
            action_description => "Unknown tool: $tool_name",
            sent_to_ai => "ERROR: Unknown tool: $tool_name",
            success => 0,
            error => "Unknown tool: $tool_name",
            execution_time_ms => int((time() - $start_time) * 1000)
        });
        
        return $self->_error_result("Unknown tool: $tool_name");
    }
    
    # Execute tool with operation from arguments
    if (should_log('DEBUG') && $tool_name eq 'user_collaboration') {
        if ($self->{ui}) {
            print STDERR "[DEBUG][ToolExecutor] Executing user_collaboration with UI available\n";
        } else {
            print STDERR "[DEBUG][ToolExecutor] ERROR: Executing user_collaboration but UI is undefined!\n";
        }
    }
    
    my $result = $tool->execute($arguments, {
        session => $self->{session},
        config => $self->{config},  # Pass config for API keys (web search)
        tool_call_id => $tool_call_id,
        ui => $self->{ui},  # Provide UI for user_collaboration
        spinner => $self->{spinner},  # Provide spinner for interactive tools
    });
    
    my $execution_time_ms = int((time() - $start_time) * 1000);
    
    # Handle result
    unless ($result && ref($result) eq 'HASH') {
        # Log invalid result
        $self->_log_tool_operation({
            tool_call_id => $tool_call_id,
            tool_name => $tool_name,
            operation => $arguments->{operation} || 'unknown',
            parameters => $arguments,
            output => {},
            action_description => "Tool returned invalid result",
            sent_to_ai => "ERROR: Tool returned invalid result",
            success => 0,
            error => "Tool returned invalid result",
            execution_time_ms => $execution_time_ms
        });
        
        return $self->_error_result("Tool returned invalid result");
    }
    
    if ($result->{success}) {
        # Success - return output WITH action_description for UI display
        my $output = $result->{output};
        
        # Convert complex types to JSON
        if (ref($output) eq 'HASH' || ref($output) eq 'ARRAY') {
            $output = encode_json($output);
        }
        
        # Store the raw output before potential truncation by ToolResultStore
        my $raw_output = $output;
        
        # Process via ToolResultStore (auto-persist if >8KB)
        # Note: session object has 'session_id' not 'id'
        my $session_id = $self->{session}->{session_id};
        if ($session_id && $tool_call_id) {
            $output = $self->{storage}->processToolResult(
                $tool_call_id,
                $output,
                $session_id
            );
        }
        
        # Log successful execution
        $self->_log_tool_operation({
            tool_call_id => $tool_call_id,
            tool_name => $tool_name,
            operation => $arguments->{operation} || 'unknown',
            parameters => $arguments,
            output => $raw_output,  # Log the FULL output, not the truncated version
            action_description => $result->{action_description} || "Executed $tool_name",
            sent_to_ai => $output,  # This might be truncated/preview
            success => 1,
            execution_time_ms => $execution_time_ms
        });
        
        # Return the output string (will be parsed by WorkflowOrchestrator for display)
        # BUT preserve action_description as metadata for UI display
        # We return JSON with both output and action_description
        my $response = {
            success => 1,  # Include success flag for test verification
            output => $output,
        };
        
        # Add action_description if present (for UI feedback)
        if ($result->{action_description}) {
            $response->{action_description} = $result->{action_description};
        }
        
        return encode_json($response);
    } else {
        # Error - log the failure
        $self->_log_tool_operation({
            tool_call_id => $tool_call_id,
            tool_name => $tool_name,
            operation => $arguments->{operation} || 'unknown',
            parameters => $arguments,
            output => $result->{output} || {},
            action_description => $result->{action_description} || "Tool execution failed",
            sent_to_ai => "ERROR: " . ($result->{error} || 'Unknown error'),
            success => 0,
            error => $result->{error} || 'Unknown error',
            execution_time_ms => $execution_time_ms
        });
        
        # Error
        return "ERROR: " . ($result->{error} || 'Unknown error');
    }
}

=head2 _execute_file_operations

Execute file_operations tool.

Arguments format:
    {
        "operation": "read|write|search|list",
        "path": "/path/to/file",
        "content": "file content" (for write),
        "pattern": "search pattern" (for search)
    }

=cut

sub _execute_file_operations {
    my ($self, $args, $tool_call_id) = @_;
    
    my $operation = $args->{operation};
    my $path = $args->{path};
    
    unless ($operation && $path) {
        return $self->_error_result("Missing required parameters: operation, path");
    }
    
    print STDERR "[DEBUG][ToolExecutor] File operation: $operation on $path\n" if should_log('DEBUG');
    
    # Build protocol command
    my $protocol_cmd;
    
    if ($operation eq 'read') {
        # [FILE_OP:read:path=<base64_path>]
        $protocol_cmd = sprintf('[FILE_OP:read:path=%s]', 
            encode_base64($path, ''));
    }
    elsif ($operation eq 'write') {
        my $content = $args->{content} || '';
        # [FILE_OP:write:path=<base64_path>:content=<base64_content>]
        $protocol_cmd = sprintf('[FILE_OP:write:path=%s:content=%s]',
            encode_base64($path, ''),
            encode_base64($content, ''));
    }
    elsif ($operation eq 'list') {
        # [FILE_OP:list:path=<base64_path>]
        $protocol_cmd = sprintf('[FILE_OP:list:path=%s]',
            encode_base64($path, ''));
    }
    elsif ($operation eq 'search') {
        my $pattern = $args->{pattern} || '';
        # For search, we'll use grep or similar - implement based on FileOp protocol
        # For now, return not implemented
        return $self->_error_result("Search operation not yet implemented");
    }
    else {
        return $self->_error_result("Unsupported file operation: $operation");
    }
    
    # Execute protocol
    return $self->_execute_protocol($protocol_cmd, $tool_call_id);
}

=head2 _execute_read_tool_result

Execute read_tool_result tool - retrieves stored large tool results.

Arguments format:
    {
        "tool_call_id": "call_abc123",
        "offset": 0 (optional),
        "length": 8192 (optional)
    }

=cut

sub _execute_read_tool_result {
    my ($self, $args) = @_;
    
    my $tool_call_id = $args->{tool_call_id};
    
    unless ($tool_call_id) {
        return $self->_error_result("Missing required parameter: tool_call_id");
    }
    
    unless ($self->{session} && $self->{session}->{session_id}) {
        return $self->_error_result("No active session");
    }
    
    my $offset = $args->{offset} || 0;
    my $length = $args->{length} || 8192;
    
    print STDERR "[DEBUG][ToolExecutor] Reading tool result: $tool_call_id, offset=$offset, length=$length\n" if should_log('DEBUG');
    
    # Retrieve chunk from storage
    my $chunk = eval {
        $self->{storage}->retrieve_chunk(
            $tool_call_id,
            $self->{session}->{session_id},
            $offset,
            $length
        );
    };
    
    if ($@) {
        return $self->_error_result("Failed to retrieve tool result: $@");
    }
    
    # Format as tool result
    my $result = {
        success => 1,
        content => $chunk->{content},
        offset => $chunk->{offset},
        length => $chunk->{length},
        total_length => $chunk->{total_length},
        has_more => $chunk->{has_more} ? JSON::PP::true : JSON::PP::false,
    };
    
    if ($chunk->{next_offset}) {
        $result->{next_offset} = $chunk->{next_offset};
        $result->{message} = "Retrieved chunk $offset-" . ($offset + $chunk->{length}) . 
                           " of $chunk->{total_length}. Use offset=$chunk->{next_offset} to continue.";
    } else {
        $result->{message} = "Final chunk retrieved.";
    }
    
    return encode_json($result);
}

=head2 _execute_git_operations

Execute git_operations tool.

Arguments format:
    {
        "operation": "status|log|diff|branch|commit|add|push|pull|clone",
        "args": ["arg1", "arg2", ...]
    }

=cut

sub _execute_git_operations {
    my ($self, $args, $tool_call_id) = @_;
    
    my $operation = $args->{operation};
    
    unless ($operation) {
        return $self->_error_result("Missing required parameter: operation");
    }
    
    print STDERR "[DEBUG][ToolExecutor] Git operation: $operation\n" if should_log('DEBUG');
    
    # Build params for Git protocol
    my $params = {
        command => $operation
    };
    
    # Add additional args if provided
    if ($args->{args} && ref($args->{args}) eq 'ARRAY') {
        $params->{args} = $args->{args};
    }
    
    # Build protocol command: [GIT:action=<action>:params=<base64_params>]
    my $protocol_cmd = sprintf('[GIT:action=%s:params=%s]',
        $operation,
        encode_base64(encode_json($params), ''));
    
    # Execute protocol
    return $self->_execute_protocol($protocol_cmd, $tool_call_id);
}

=head2 _execute_url_fetch

Execute url_fetch tool.

Arguments format:
    {
        "url": "https://example.com",
        "method": "GET|POST" (optional, default GET)
    }

=cut

sub _execute_url_fetch {
    my ($self, $args, $tool_call_id) = @_;
    
    my $url = $args->{url};
    
    unless ($url) {
        return $self->_error_result("Missing required parameter: url");
    }
    
    print STDERR "[DEBUG][ToolExecutor] URL fetch: $url\n" if should_log('DEBUG');
    
    # Build protocol command: [URL_FETCH:action=fetch:params=<base64_url>]
    my $protocol_cmd = sprintf('[URL_FETCH:action=fetch:params=%s]',
        encode_base64($url, ''));
    
    # Execute protocol
    return $self->_execute_protocol($protocol_cmd, $tool_call_id);
}

=head2 _execute_protocol

Execute a protocol command via Protocol Manager.

Arguments:
- $protocol_cmd: Protocol command string

Returns:
- JSON string with result

=cut

sub _execute_protocol {
    my ($self, $protocol_cmd, $tool_call_id) = @_;
    
    print STDERR "[DEBUG][ToolExecutor] Executing protocol: $protocol_cmd\n" if should_log('DEBUG');
    
    # Execute via Protocol Manager
    my $result = eval {
        require CLIO::Protocols::Manager;
        CLIO::Protocols::Manager->handle($protocol_cmd, $self->{session});
    };
    
    if ($@) {
        print STDERR "[ERROR][ToolExecutor] Protocol execution failed: $@\n";
        return $self->_error_result("Protocol execution failed: $@");
    }
    
    # Convert protocol result to tool result format
    return $self->_format_tool_result($result, $tool_call_id);
}

=head2 _format_tool_result

Format protocol result as JSON string for AI consumption.

Arguments:
- $protocol_result: Result from protocol handler

Returns:
- JSON string

=cut

sub _format_tool_result {
    my ($self, $result, $tool_call_id) = @_;
    
    # Handle different protocol result formats
    my $tool_result = {};
    
    if (!$result) {
        $tool_result = {
            success => 0,
            error => "No result from protocol handler"
        };
    }
    elsif (ref($result) eq 'HASH') {
        # Most protocols return hashrefs
        if ($result->{success}) {
            $tool_result->{success} = 1;
            
            # Extract content - try multiple fields
            # Priority order: content > processed_content > data > output
            my $content;
            if ($result->{content}) {
                $content = $result->{content};
            }
            elsif ($result->{processed_content}) {
                $content = $result->{processed_content};
            }
            elsif ($result->{data}) {
                # Handle base64-encoded data (e.g., from FILE_OP read)
                if (ref($result->{data}) eq '') {
                    # Try to decode if it looks like base64
                    my $decoded = eval { decode_base64($result->{data}) };
                    if ($decoded && !$@) {
                        $content = $decoded;
                    } else {
                        $content = $result->{data};
                    }
                }
                elsif (ref($result->{data}) eq 'HASH') {
                    # For nested data structures, extract useful fields
                    if ($result->{data}->{processed_data}) {
                        $content = $result->{data}->{processed_data};
                    }
                    elsif ($result->{data}->{text_content}) {
                        $content = $result->{data}->{text_content};
                    }
                    else {
                        $tool_result->{data} = $result->{data};
                    }
                }
                elsif (ref($result->{data}) eq 'ARRAY') {
                    $tool_result->{items} = $result->{data};
                }
            }
            elsif ($result->{output}) {
                $content = $result->{output};
            }
            
            # Process content through storage if it exists and we have tool_call_id
            if ($content && $tool_call_id && $self->{session} && $self->{session}->{session_id}) {
                my $processed = $self->{storage}->process_result(
                    $tool_call_id,
                    $content,
                    $self->{session}->{session_id}
                );
                $tool_result->{content} = $processed;
            }
            elsif ($content) {
                $tool_result->{content} = $content;
            }
            
            # Include metadata fields that are useful for AI
            for my $key (qw(message summary status files branch commits url status_code content_type title)) {
                if ($result->{$key}) {
                    $tool_result->{$key} = $result->{$key};
                }
            }
            
            # Special handling for URL_FETCH results
            if ($result->{url}) {
                # Include useful URL metadata
                $tool_result->{url} = $result->{url};
                if ($result->{title}) {
                    $tool_result->{title} = $result->{title};
                }
                if ($result->{content_type}) {
                    $tool_result->{content_type} = $result->{content_type};
                }
            }
        }
        else {
            $tool_result->{success} = 0;
            $tool_result->{error} = $result->{error} || $result->{message} || "Unknown error";
        }
    }
    else {
        # Unexpected result format
        $tool_result = {
            success => 0,
            error => "Unexpected protocol result format: " . ref($result)
        };
    }
    
    # Convert to JSON
    my $json = eval { encode_json($tool_result) };
    if ($@) {
        print STDERR "[ERROR][ToolExecutor] Failed to encode result: $@\n";
        return encode_json({
            success => 0,
            error => "Failed to encode result: $@"
        });
    }
    
    print STDERR "[DEBUG][ToolExecutor] Tool result: " . substr($json, 0, 500) . 
        (length($json) > 500 ? "..." : "") . "\n" if $self->{debug};
    
    return $json;
}

=head2 _error_result

Generate an error result in JSON format.

Arguments:
- $error_message: Error description

Returns:
- JSON string

=cut

sub _log_tool_operation {
    my ($self, $entry) = @_;
    
    # Only log if ToolLogger is available
    return unless $self->{tool_logger};
    
    eval {
        $self->{tool_logger}->log($entry);
    };
    if ($@) {
        print STDERR "[ERROR][ToolExecutor] Failed to log tool operation: $@\n" if should_log('ERROR');
    }
}

=head2 _error_result

Return a JSON error result.

=cut

sub _error_result {
    my ($self, $error) = @_;
    
    print STDERR "[ERROR][ToolExecutor] $error\n";
    
    return encode_json({
        success => 0,
        error => $error
    });
}

1;

__END__

=head1 TOOL → PROTOCOL MAPPING

file_operations:
    read   → [FILE_OP:read:path=<base64>]
    write  → [FILE_OP:write:path=<base64>:content=<base64>]
    list   → [FILE_OP:list:path=<base64>]
    search → [Not yet implemented]

git_operations:
    all → [GIT:action=<operation>:params=<base64_json>]
    
url_fetch:
    all → [URL_FETCH:action=fetch:params=<base64_url>]

=head1 RESULT FORMAT

Success:
    {
        "success": true,
        "content": "file contents...",
        "data": { ... },
        "message": "Optional message"
    }

Error:
    {
        "success": false,
        "error": "Error description"
    }

=head1 INTEGRATION

This module completes the tool calling pipeline:

    AI → tool_call → ToolExecutor → Protocol → Handler → Result → ToolExecutor → AI

Task 1: ✓ Tool Registry (defines tools)
Task 2: ✓ WorkflowOrchestrator (manages loop)
Task 3: ✓ APIManager (sends/receives tools)
Task 4: ✓ THIS MODULE (executes tools)
Task 5: ⏳ Testing
Task 6: ⏳ Cleanup

=head1 AUTHOR

Fewtarius

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

1;
