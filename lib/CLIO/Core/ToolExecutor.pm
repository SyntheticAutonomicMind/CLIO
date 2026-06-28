# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::ToolExecutor;

use strict;
use warnings;
use utf8;
use Encode qw(decode);
use CLIO::Core::Logger qw(should_log log_debug);
use CLIO::Core::ErrorContext qw(classify_error format_error);
use CLIO::Util::JSONRepair qw(repair_malformed_json);
use CLIO::Util::JSON qw(encode_json decode_json safe_decode_json safe_encode_json);
use CLIO::Session::ToolResultStore;
use CLIO::Logging::ToolLogger;
use CLIO::Security::SecretRedactor qw(redact redact_any);
use Storable qw(dclone);
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
        broker_client => $args{broker_client},  # Broker client for multi-agent coordination
        api_manager => $args{api_manager},  # API manager for current model info
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
        log_debug('ToolExecutor', "Initialized ToolLogger");
    }
    
    # Debug: Log if UI is available
    if (should_log('DEBUG')) {
        if ($self->{ui}) {
            log_debug('ToolExecutor', "UI available for tools");
        } else {
            log_debug('ToolExecutor', "WARNING: UI is undefined - tools won't have collaboration access");
        }
    }
    
    log_debug('ToolExecutor', "Initialized with ToolResultStore");
    
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
    
    # Defensive: some servers (e.g., llama.cpp) send arguments as a parsed
    # JSON object instead of a string.  Re-encode to a string if needed.
    if (ref($arguments_json)) {
        log_debug('ToolExecutor',
            "Tool '$tool_name' arguments is " . ref($arguments_json) . " - re-encoding to JSON string");
        $arguments_json = safe_encode_json($arguments_json, '{}');
        $tool_call->{function}->{arguments} = $arguments_json;
    }
    
    unless ($tool_name && defined $arguments_json) {
        return $self->_error_result("Missing tool name or arguments");
    }
    
    log_debug('ToolExecutor', "Executing tool: $tool_name (id=$tool_call_id)");
    
    # Parse arguments with UTF-8 handling
    # Reuse pre-parsed args from WorkflowOrchestrator when available
    my $arguments;
    if ($tool_call->{_parsed_args}) {
        $arguments = $tool_call->{_parsed_args};
    } else {
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
    }
    if (!$arguments && $@) {
        my $error = $@;
        log_debug('ToolExecutor', "JSON parse error: $error");
        
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
    
    # PHASE 1: Normalize dual JSON parameters (_json variants)
    # If agent passed content_json (object), convert to content (string)
    # This allows agents to pass complex data without escaping
    $arguments = $self->_normalize_dual_json_params($arguments);
    
    # PHASE 2: Handle oneOf parameters (standard JSON Schema)
    # If tool uses oneOf with string/object types, accept both formats
    # This uses standard JSON Schema instead of custom "json_string" type
    $arguments = $self->_normalize_oneof_params($arguments, $tool_name);
    
    # Get tool from registry
    my $tool_registry = $self->{tool_registry};
    unless ($tool_registry) {
        return $self->_error_result("Tool registry not available");
    }
    
    # Resolve tool aliases via the registry (single source of truth)
    my $alias_info = $tool_registry->get_alias_info($tool_name);
    if ($alias_info) {
        log_debug('ToolExecutor', "Aliasing '$tool_name' -> '$alias_info->{tool}' with operation='$alias_info->{operation}'");
        $tool_name = $alias_info->{tool};
        $arguments->{operation} = $alias_info->{operation};
    }
    
    my $original_tool_name = $tool_name;
    
    # Check if this is an MCP tool (prefixed with mcp_)
    if ($tool_name =~ /^mcp_/ && $self->{mcp_manager}) {
        # Sandbox mode: Block all MCP tool calls
        if ($self->{config} && $self->{config}->get('sandbox')) {
            log_info('ToolExecutor', "Sandbox: BLOCKED MCP tool '$tool_name'");
            return $self->_error_result(
                "Sandbox mode: MCP tools are disabled.\n\n" .
                "The --sandbox flag blocks all MCP operations. " .
                "This is a security feature to prevent the agent from reaching outside the local project."
            );
        }
        
        require CLIO::Tools::MCPBridge;
        
        log_debug('ToolExecutor', "Executing MCP tool: $tool_name");
        
        my $result = CLIO::Tools::MCPBridge->execute_tool(
            $self->{mcp_manager}, $tool_name, $arguments
        );
        
        my $execution_time_ms = int((time() - $start_time) * 1000);
        
        # Log the MCP tool operation
        $self->_log_tool_operation({
            tool_call_id     => $tool_call_id,
            tool_name        => $tool_name,
            operation        => 'mcp_call',
            parameters       => $arguments,
            output           => { text => $result->{output} || $result->{error} || '' },
            action_description => $result->{action_description} || "MCP tool: $tool_name",
            sent_to_ai       => $result->{output} || $result->{error} || '',
            success          => $result->{success} ? 1 : 0,
            error            => $result->{error},
            execution_time_ms => $execution_time_ms,
        });
        
        if ($result->{success}) {
            my $response = {
                success            => 1,
                output             => $result->{output} || '',
                action_description => $result->{action_description} || "MCP tool: $tool_name",
            };
            return encode_json($response);
        } else {
            return $self->_error_result($result->{error} || 'MCP tool execution failed');
        }
    }
    
    # Check if this is a plugin tool (prefixed with plugin_)
    if ($tool_name =~ /^plugin_/ && $self->{plugin_manager}) {
        # Sandbox mode: Block all plugin tool calls
        if ($self->{config} && $self->{config}->get('sandbox')) {
            log_info('ToolExecutor', "Sandbox: BLOCKED plugin tool '$tool_name'");
            return $self->_error_result(
                "Sandbox mode: Plugin tools are disabled.\n\n" .
                "The --sandbox flag blocks all plugin operations. " .
                "This is a security feature to prevent the agent from reaching outside the local project."
            );
        }
        
        require CLIO::Tools::PluginBridge;
        
        log_debug('ToolExecutor', "Executing plugin tool: $tool_name");
        
        my $result = CLIO::Tools::PluginBridge->execute_tool(
            $self->{plugin_manager}, $tool_name, $arguments
        );
        
        my $execution_time_ms = int((time() - $start_time) * 1000);
        
        # Log the plugin tool operation
        $self->_log_tool_operation({
            tool_call_id     => $tool_call_id,
            tool_name        => $tool_name,
            operation        => 'plugin_call',
            parameters       => $arguments,
            output           => { text => $result->{output} || $result->{error} || '' },
            action_description => $result->{action_description} || "Plugin tool: $tool_name",
            sent_to_ai       => $result->{output} || $result->{error} || '',
            success          => $result->{success} ? 1 : 0,
            error            => $result->{error},
            execution_time_ms => $execution_time_ms,
        });
        
        if ($result->{success}) {
            my $response = {
                success            => 1,
                output             => $result->{output} || '',
                action_description => $result->{action_description} || "Plugin tool: $tool_name",
            };
            return encode_json($response);
        } else {
            return $self->_error_result($result->{error} || 'Plugin tool execution failed');
        }
    }
    
    my $tool = $tool_registry->get_tool($tool_name);
    unless ($tool) {
        # Log unknown tool error
        $self->_log_tool_operation({
            tool_call_id => $tool_call_id,
            tool_name => $original_tool_name,
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
    if (should_log('DEBUG') && $tool_name eq 'interact') {
        if ($self->{ui}) {
            log_debug('ToolExecutor', "Executing interact with UI available");
        } else {
            log_debug('ToolExecutor', "ERROR: Executing interact but UI is undefined!");
        }
    }
    
    # Get current model from api_manager for tools that need it (e.g., sub-agent spawning)
    my $current_model;
    if ($self->{api_manager} && $self->{api_manager}->can('get_current_model')) {
        $current_model = $self->{api_manager}->get_current_model();
    }

    # Protect against SIGPIPE from broken broker socket connections during tool execution
    # This prevents crashes when the broker process dies or network fails mid-tool
    local $SIG{PIPE} = 'IGNORE';

    my $result = $tool->execute($arguments, {
        session => $self->{session},
        config => $self->{config},  # Pass config for API keys (web search)
        tool_call_id => $tool_call_id,
        ui => $self->{ui},  # Provide UI for interact
        spinner => $self->{spinner},  # Provide spinner for interactive tools
        broker_client => $self->{broker_client},  # Provide broker for coordination
        file_vault => $self->{file_vault},  # FileVault for undo tracking
        vault_turn_id => $self->{vault_turn_id},  # Current turn ID for vault
        current_model => $current_model,  # Current session model for sub-agents
        api_manager => $self->{api_manager},  # For model capabilities (dynamic chunk sizing)
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
    
    # Validate tool result schema - ensure required fields exist
    unless (exists $result->{success} && defined $result->{output}) {
        log_warning('ToolExecutor', "Tool '$tool_name' returned result missing required fields (success, output)");
        $result = {
            success => 0,
            output => "Tool returned malformed result (missing success/output fields)",
            error => "Internal tool error: malformed result structure",
        };
    }
    
    if ($result->{success}) {
        # Success - return output WITH action_description for UI display
        my $output = $result->{output};
        
        # Convert complex types to JSON
        if (ref($output) eq 'HASH' || ref($output) eq 'ARRAY') {
            $output = encode_json($output);
        }
        
        # === SECURITY: Redact secrets and PII from tool output ===
        # This happens BEFORE sending to AI and logging, ensuring secrets
        # are never exposed to the LLM or stored in logs
        # Levels: strict, standard, api_permissive, pii, off
        # See: /config set redact_level <level>
        # Backward compat: redact_secrets true -> standard, false -> off
        my $redact_level = $self->_get_redact_level();
        if ($redact_level ne 'off' && defined $output) {
            $output = redact($output, level => $redact_level);
        }
        
        # Store the raw output before potential truncation by ToolResultStore
        my $raw_output = $output;
        
        # Process via ToolResultStore (auto-persist if >8KB)
        # EXCEPT: read_tool_result output must NOT be re-persisted.
        # It already returns chunked data; re-persisting creates an infinite
        # loop where each chunk generates a new toolCallId that the model
        # reads at offset=0, producing another >8KB result, ad infinitum.
        my $operation = $arguments->{operation} || '';
        my $skip_persist = ($operation eq 'read_tool_result');
        
        my $session_id = $self->{session}->{session_id};
        if ($session_id && $tool_call_id && !$skip_persist) {
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
        
        # Pass through expanded_content for inline display (e.g. terminal output)
        if ($result->{expanded_content} && ref($result->{expanded_content}) eq 'ARRAY') {
            $response->{expanded_content} = $result->{expanded_content};
        }
        
        # Pass through metadata for display (e.g. file diffs)
        if ($result->{metadata} && ref($result->{metadata}) eq 'HASH') {
            $response->{metadata} = $result->{metadata};
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
        my $error_msg = $result->{error} || 'Unknown error';
        return encode_json({
            success => 0,
            error => $error_msg,
            output => "ERROR: $error_msg",
        });
    }
}

=head2 _execute_read_tool_result

Execute read_tool_result tool - retrieves stored large tool results.

Arguments format:
    {
        "tool_call_id": "call_abc123",
        "offset": 0 (optional),
        "length": 8192 (optional, scales with model context)
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

    # Default chunk size scales with model context window
    my $default_chunk = 8192;
    if ($self->{api_manager} && $self->{api_manager}->can('get_model_capabilities')) {
        my $caps = eval { $self->{api_manager}->get_model_capabilities() };
        if ($caps && $caps->{max_prompt_tokens}) {
            require CLIO::Core::Defaults;
            $default_chunk = CLIO::Core::Defaults::default_chunk_size($caps->{max_prompt_tokens});
        }
    }
    my $length = $args->{length} || $default_chunk;
    
    log_debug('ToolExecutor', "Reading tool result: $tool_call_id, offset=$offset, length=$length");
    
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
        has_more => $chunk->{has_more} ? \1 : \0,
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
        log_debug('ToolExecutor', "Failed to log tool operation: $@");
    }
}

=head2 _error_result

Return a JSON error result.

=cut

sub _error_result {
    my ($self, $error) = @_;
    
    log_debug('ToolExecutor', "Error: $error");
    
    return encode_json({
        success => 0,
        error => $error,
        output => "ERROR: $error",
    });
}

=head2 _normalize_dual_json_params

Normalize dual JSON parameters (_json variants) to their base form.

This enables agents to pass complex data as JSON objects instead of escaped strings.

Example:
  Agent passes: {content_json: {"key": "value"}}
  System converts to: {content: "{\"key\": \"value\"}"}

Arguments:
- $params: Hashref of tool parameters

Returns:
- Normalized params hashref (deep copy, original unchanged)

=cut

sub _normalize_dual_json_params {
    my ($self, $params) = @_;
    
    return $params unless $params && ref($params) eq 'HASH';
    
    # Deep clone to avoid mutating caller's data
    $params = dclone($params);
    
    # Look for _json parameter variants
    my @param_keys = keys %$params;
    for my $key (@param_keys) {
        # Check if this is a _json variant (e.g., content_json, data_json)
        if ($key =~ /^(.+)_json$/) {
            my $base_key = $1;  # Remove _json suffix
            my $json_value = $params->{$key};
            
            # Skip if both _json and base exist (base takes precedence for backward compat)
            if (exists $params->{$base_key}) {
                log_debug('ToolExecutor', "Both $key and $base_key exist - using $base_key");
                delete $params->{$key};  # Remove _json version
                next;
            }
            
            # Convert JSON object/array to string
            if (ref($json_value) eq 'HASH' || ref($json_value) eq 'ARRAY') {
                log_debug('ToolExecutor', "Normalizing $key -> $base_key (object to string)");
                
                # Serialize the object/array to JSON string
                my $json_string = encode_json($json_value);
                $params->{$base_key} = $json_string;
                delete $params->{$key};  # Remove _json version
            }
            elsif (!ref($json_value)) {
                # Already a string - just move it to base key
                log_debug('ToolExecutor', "Normalizing $key -> $base_key (string to string)");
                $params->{$base_key} = $json_value;
                delete $params->{$key};
            }
        }
    }
    
    return $params;
}

=head2 _normalize_oneof_params

Normalize oneOf type parameters to accept both formats.

This is Phase 2 using standard JSON Schema with oneOf.
A parameter defined with oneOf can accept multiple types:

```perl
{
  "text": {
    "oneOf": [
      {"type": "string"},
      {"type": "object"}
    ]
  }
}
```

Both formats are valid:
  text: {"key": "value"}        <- JSON object
  text: "{\"key\": \"value\"}"  <- JSON string

We normalize both to string format internally.

Arguments:
- $params: Hashref of tool parameters
- $tool_name: Tool name (for looking up parameter schemas)

Returns:
- Normalized params hashref

=cut

sub _normalize_oneof_params {
    my ($self, $params, $tool_name) = @_;
    
    return $params unless $params && ref($params) eq 'HASH';
    return $params unless $tool_name;
    
    # Get tool from registry to check parameter schemas
    my $tool = $self->{tool_registry}->get_tool($tool_name);
    return $params unless $tool;
    
    # Get tool definition to check parameter schemas (cached)
    my $tool_def = $self->_get_cached_tool_definition($tool_name);
    return $params unless $tool_def && $tool_def->{parameters};
    
    my $properties = $tool_def->{parameters}{properties};
    return $params unless $properties && ref($properties) eq 'HASH';
    
    # Check each parameter
    for my $param_name (keys %$params) {
        my $param_def = $properties->{$param_name};
        next unless $param_def && ref($param_def) eq 'HASH';
        
        # Check if this parameter has oneOf with string and object types
        next unless $param_def->{oneOf} && ref($param_def->{oneOf}) eq 'ARRAY';
        
        my $has_string = 0;
        my $has_object = 0;
        
        for my $option (@{$param_def->{oneOf}}) {
            $has_string = 1 if $option->{type} && $option->{type} eq 'string';
            $has_object = 1 if $option->{type} && $option->{type} eq 'object';
        }
        
        # Only process if oneOf includes both string and object
        next unless $has_string && $has_object;
        
        my $param_value = $params->{$param_name};
        
        # If it's a HASH or ARRAY, convert to JSON string
        if (ref($param_value) eq 'HASH' || ref($param_value) eq 'ARRAY') {
            log_debug('ToolExecutor', "oneOf param '$param_name': object -> string");
            
            # Serialize to JSON string
            $params->{$param_name} = encode_json($param_value);
        }
        elsif (!ref($param_value)) {
            # Already a string - optionally validate it's valid JSON
            my $parsed = safe_decode_json($param_value);
            if ($@) {
                # Not JSON or invalid - that's OK, might be plain text
                log_debug('ToolExecutor', "oneOf param '$param_name': plain string (not JSON)");
            } else {
                log_debug('ToolExecutor', "oneOf param '$param_name': valid JSON string (passthrough)");
            }
        }
    }
    
    return $params;
}

=head2 _get_cached_tool_definition

Get cached tool definition to avoid re-fetching on every call.

Arguments:
- $tool_name: Tool name

Returns:
- Tool definition hashref or undef

=cut

sub _get_cached_tool_definition {
    my ($self, $tool_name) = @_;
    
    $self->{_tool_def_cache} ||= {};
    
    unless ($self->{_tool_def_cache}{$tool_name}) {
        my $tool = $self->{tool_registry}->get_tool($tool_name);
        return unless $tool;
        $self->{_tool_def_cache}{$tool_name} = $tool->get_tool_definition();
    }
    
    return $self->{_tool_def_cache}{$tool_name};
}

=head2 _get_redact_level

Get the redaction level from config with backward compatibility.

Returns: 'strict', 'standard', 'api_permissive', 'pii', or 'off'

Backward compatibility:
  - redact_secrets=true  -> 'standard'
  - redact_secrets=false -> 'off'
  - redact_level=<value> -> uses that value

=cut

sub _get_redact_level {
    my ($self) = @_;
    
    return 'pii' unless $self->{config};
    
    # Check new redact_level first
    my $level = $self->{config}->get('redact_level');
    if (defined $level && $level =~ /^(strict|standard|api_permissive|pii|off)$/) {
        return $level;
    }
    
    # Backward compatibility: check old redact_secrets boolean
    my $redact_secrets = $self->{config}->get('redact_secrets');
    if (defined $redact_secrets) {
        # If explicitly set, convert to level
        return $redact_secrets ? 'standard' : 'off';
    }
    
    # Default
    return 'pii';
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

GPL-3.0-only

=cut

1;
