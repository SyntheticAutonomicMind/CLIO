package CLIO::Core::WorkflowOrchestrator;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(should_log log_error log_warning log_info log_debug);
use CLIO::Util::TextSanitizer qw(sanitize_text);
use CLIO::Util::JSONRepair qw(repair_malformed_json);
use CLIO::Util::AnthropicXMLParser qw(is_anthropic_xml_format parse_anthropic_xml_to_json);
use CLIO::UI::ToolOutputFormatter;
use CLIO::Core::ToolErrorGuidance;
use CLIO::Util::JSON qw(encode_json decode_json);
use Encode qw(encode_utf8);  # For handling Unicode in JSON
use Time::HiRes qw(time);
use Digest::MD5 qw(md5_hex);
use CLIO::Compat::Terminal qw(ReadKey ReadMode);  # For interrupt detection
use CLIO::Logging::ProcessStats;

# ANSI color codes for terminal output - FALLBACK only when UI is unavailable
# The preferred approach is using $self->{ui}->colorize() which respects theme settings
my %COLORS = (
    RESET     => "\e[0m",
    SYSTEM    => "\e[36m",    # Cyan - System messages (fallback matches Theme.pm system_message)
    TOOL      => "\e[1;36m",  # Bright Cyan - Tool names
    DETAIL    => "\e[2;37m",  # Dim White - Action details
);

=head1 NAME

CLIO::Core::WorkflowOrchestrator - Autonomous tool calling workflow orchestrator

=head1 DESCRIPTION

Implements the main workflow loop for OpenAI-compatible tool calling.
This replaces fragile pattern matching with intelligent tool use by the AI.

The orchestrator:
1. Sends user input to AI with available tools
2. Checks if AI requested tool_calls
3. Executes tools and adds results to conversation
4. Loops back to AI until it returns a final answer
5. Prevents infinite loops with max iterations

Based on SAM's AgentOrchestrator but simplified for CLIO.

=head1 SYNOPSIS

    use CLIO::Core::WorkflowOrchestrator;
    
    my $orchestrator = CLIO::Core::WorkflowOrchestrator->new(
        api_manager => $api_manager,
        debug => 1
    );
    
    my $result = $orchestrator->process_input($user_input, $session);
    print $result->{content};

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        api_manager => $args{api_manager},
        session => $args{session},
        max_iterations => $args{max_iterations} || 500,  # Increased from 10 to support complex coding tasks
        debug => $args{debug} || 0,
        ui => $args{ui},  # Store UI reference for buffer flushing
        spinner => $args{spinner},  # Store spinner for interactive tools (user_collaboration)
        skip_custom => $args{skip_custom} || 0,  # Skip custom instructions (--no-custom-instructions)
        skip_ltm => $args{skip_ltm} || 0,        # Skip LTM injection (--no-ltm)
        non_interactive => $args{non_interactive} || 0,  # Non-interactive mode (--input flag)
        broker_client => $args{broker_client},   # Broker client for multi-agent coordination
        consecutive_errors => 0,  # Track consecutive identical errors
        last_error => '',         # Track last error message
        max_consecutive_errors => 3,  # Break loop after 3 identical errors
    };
    
    bless $self, $class;
    
    # Initialize tool output formatter
    $self->{formatter} = CLIO::UI::ToolOutputFormatter->new(ui => $args{ui});
    
    # Initialize tool error guidance
    $self->{error_guidance} = CLIO::Core::ToolErrorGuidance->new();
    
    # Initialize tool registry
    require CLIO::Tools::Registry;
    $self->{tool_registry} = CLIO::Tools::Registry->new(debug => $args{debug});
    
    # Register default tools
    $self->_register_default_tools();
    
    # Initialize tool executor (Task 4)
    require CLIO::Core::ToolExecutor;
    $self->{tool_executor} = CLIO::Core::ToolExecutor->new(
        session => $args{session},
        tool_registry => $self->{tool_registry},
        config => $args{config},  # Forward config for web search API keys
        ui => $args{ui},  # Forward UI for user_collaboration
        spinner => $args{spinner},  # Forward spinner for interactive tools
        broker_client => $args{broker_client},  # Forward broker client for coordination
        debug => $args{debug}
    );
    
    # Initialize MCP (Model Context Protocol) manager
    eval {
        require CLIO::MCP::Manager;
        $self->{mcp_manager} = CLIO::MCP::Manager->new(
            config => $args{config},
            debug  => $args{debug},
        );
        my $mcp_connected = $self->{mcp_manager}->start();
        if ($mcp_connected > 0) {
            # Pass MCP manager to tool executor for MCP tool calls
            $self->{tool_executor}{mcp_manager} = $self->{mcp_manager};
        }
    };
    if ($@) {
        log_warning('WorkflowOrchestrator', "MCP initialization failed: $@");
    }
    
    # Initialize snapshot system for file change tracking
    eval {
        require CLIO::Session::Snapshot;
        $self->{snapshot} = CLIO::Session::Snapshot->new(
            debug => $args{debug},
        );
        if ($self->{snapshot}->is_available()) {
            log_debug('WorkflowOrchestrator', "Snapshot system initialized");
        } else {
            log_debug('WorkflowOrchestrator', "Snapshot system unavailable (git not found)");
            $self->{snapshot} = undef;
        }
    };
    if ($@) {
        log_debug('WorkflowOrchestrator', "Snapshot system failed to load: $@");
        $self->{snapshot} = undef;
    }
    
    # Initialize process stats tracker
    $self->{process_stats} = CLIO::Logging::ProcessStats->new(
        session_id => ($args{session} && $args{session}->can('session_id'))
            ? $args{session}->session_id() : 'unknown',
        debug => $args{debug},
    );
    $self->{process_stats}->capture('session_start');
    
    log_debug('WorkflowOrchestrator', "Initialized with max_iterations=$self->{max_iterations}");
    
    if ($self->{skip_custom} || $self->{skip_ltm}) {
        log_debug('WorkflowOrchestrator', "Incognito flags: skip_custom=$self->{skip_custom}, skip_ltm=$self->{skip_ltm}");
    }
    
    return $self;
}

# Helper function: Provide tool-specific recovery guidance
# Defined here (before use) to avoid forward declaration issues
sub _get_tool_specific_guidance {
    my ($tool_name) = @_;
    
    return '' unless defined $tool_name;
    
    # Special guidance for read_tool_result failures
    if ($tool_name eq 'file_operations') {
        return <<'GUIDANCE';

ALTERNATIVE APPROACHES FOR FILE OPERATIONS:
If read_tool_result is failing repeatedly, try these instead:
1. Use terminal_operations with head/tail/sed to view specific portions:
   terminal_operations(operation: "exec", command: "head -n 50 /path/to/file")
2. Use file_operations with read_file and line ranges:
   file_operations(operation: "read_file", path: "/path/to/file", start_line: 1, end_line: 100)
3. Use grep_search to find specific patterns instead of reading entire file:
   file_operations(operation: "grep_search", query: "pattern")

GUIDANCE
    }
    
    return '';
}

=head2 _register_default_tools

Register default tools (file_operations, etc.) with the tool registry.

=cut

sub _register_default_tools {
    my ($self) = @_;
    
    # Tools blocked for sub-agents (to prevent coordination issues and fork bombs)
    my %blocked_for_subagent = (
        'remote_execution' => 1,    # Cannot spawn remote work
        'agent_operations' => 1,    # Cannot spawn additional sub-agents
    );
    
    # Check if we're running as a sub-agent
    my $is_subagent = $self->{broker_client} ? 1 : 0;
    
    # Register FileOperations tool
    require CLIO::Tools::FileOperations;
    $self->{tool_registry}->register_tool(
        CLIO::Tools::FileOperations->new(debug => $self->{debug})
    );
    
    # Register VersionControl tool
    require CLIO::Tools::VersionControl;
    $self->{tool_registry}->register_tool(
        CLIO::Tools::VersionControl->new(debug => $self->{debug})
    );
    
    # Register TerminalOperations tool
    require CLIO::Tools::TerminalOperations;
    $self->{tool_registry}->register_tool(
        CLIO::Tools::TerminalOperations->new(debug => $self->{debug})
    );
    
    # Register MemoryOperations tool
    require CLIO::Tools::MemoryOperations;
    $self->{tool_registry}->register_tool(
        CLIO::Tools::MemoryOperations->new(debug => $self->{debug})
    );
    
    # Register WebOperations tool
    require CLIO::Tools::WebOperations;
    $self->{tool_registry}->register_tool(
        CLIO::Tools::WebOperations->new(debug => $self->{debug})
    );
    
    # Register TodoList tool
    require CLIO::Tools::TodoList;
    $self->{tool_registry}->register_tool(
        CLIO::Tools::TodoList->new(debug => $self->{debug})
    );
    
    # Register CodeIntelligence tool
    require CLIO::Tools::CodeIntelligence;
    $self->{tool_registry}->register_tool(
        CLIO::Tools::CodeIntelligence->new(debug => $self->{debug})
    );
    
    # Register UserCollaboration tool
    require CLIO::Tools::UserCollaboration;
    $self->{tool_registry}->register_tool(
        CLIO::Tools::UserCollaboration->new(debug => $self->{debug})
    );
    
    # Register RemoteExecution tool (blocked for sub-agents)
    unless ($is_subagent && $blocked_for_subagent{'remote_execution'}) {
        require CLIO::Tools::RemoteExecution;
        $self->{tool_registry}->register_tool(
            CLIO::Tools::RemoteExecution->new(debug => $self->{debug})
        );
    } else {
        log_debug('WorkflowOrchestrator', "Blocked remote_execution for sub-agent");
    }
    
    # Register SubAgentOperations tool (blocked for sub-agents to prevent fork bombs)
    unless ($is_subagent && $blocked_for_subagent{'agent_operations'}) {
        require CLIO::Tools::SubAgentOperations;
        $self->{tool_registry}->register_tool(
            CLIO::Tools::SubAgentOperations->new(debug => $self->{debug})
        );
    } else {
        log_debug('WorkflowOrchestrator', "Blocked agent_operations for sub-agent");
    }
    
    # Register ApplyPatch tool (diff-based file editing)
    require CLIO::Tools::ApplyPatch;
    $self->{tool_registry}->register_tool(
        CLIO::Tools::ApplyPatch->new(debug => $self->{debug})
    );
    
    log_debug('WorkflowOrchestrator', "Registered default tools (subagent=$is_subagent)");
}

=head2 process_input

Main workflow loop for tool calling.

Arguments:
- $user_input: User's request (string)
- $session: Session object with conversation history
- %opts: Optional parameters
  * on_chunk: Callback for streaming responses (receives content chunk and metrics)
  * on_system_message: Callback for system messages like rate limits (receives message string)

Returns:
- Hashref with:
  * success: Boolean
  * content: Final AI response
  * iterations: Number of iterations used
  * tool_calls_made: Array of tool calls executed
  * error: Error message (if failed)
  * metrics: Performance metrics (if streaming was used)

=cut

sub process_input {
    my ($self, $user_input, $session, %opts) = @_;
    
    # Extract callbacks
    my $on_chunk = $opts{on_chunk};
    my $on_system_message = $opts{on_system_message};  # Callback for system messages
    my $on_tool_call_from_ui = $opts{on_tool_call};  # Tool call tracker from UI
    my $on_thinking = $opts{on_thinking};  # Callback for reasoning/thinking content
    
    # Take a snapshot before processing - captures state before any AI modifications
    my $turn_snapshot;
    if ($self->{snapshot}) {
        $turn_snapshot = eval { $self->{snapshot}->take() };
        if ($turn_snapshot) {
            # Store on session for /undo access
            if ($session && ref($session) && $session->can('state')) {
                my $state = $session->state();
                $state->{last_snapshot} = $turn_snapshot;
                # Keep a history of recent snapshots (last 20 turns)
                $state->{snapshot_history} ||= [];
                push @{$state->{snapshot_history}}, {
                    hash => $turn_snapshot,
                    timestamp => time(),
                    user_input => substr($user_input, 0, 100),  # Truncated for storage
                };
                # Trim to last 20
                if (@{$state->{snapshot_history}} > 20) {
                    splice(@{$state->{snapshot_history}}, 0, @{$state->{snapshot_history}} - 20);
                }
            }
            log_debug('WorkflowOrchestrator', "Pre-turn snapshot: $turn_snapshot");
        } elsif ($@) {
            log_debug('WorkflowOrchestrator', "Snapshot failed: $@");
        }
    }
    
    log_debug('WorkflowOrchestrator', "Processing input: '$user_input'");
    
    # Build initial messages array
    my @messages = ();
    
    # Build system prompt with dynamic tools FIRST
    # This must come before history to ensure tools are always available
    my $system_prompt = $self->_build_system_prompt($session);
    push @messages, {
        role => 'system',
        content => $system_prompt
    };
    
    log_debug('WorkflowOrchestrator', "Added system prompt with tools (" . length($system_prompt) . " chars)");
    
    # Inject context files from session
    $self->_inject_context_files($session, \@messages);
    
    # Load conversation history from session (excluding any system messages from history)
    my $history = $self->_load_conversation_history($session);
    
    # Apply aggressive pre-flight trimming before adding history to messages
    # This prevents token limit errors on the first API call
    # Uses model's actual context window for dynamic threshold calculation
    if ($history && @$history) {
        # Get model capabilities to determine context window
        my $model_caps = {};
        if ($self->{api_manager}) {
            $model_caps = $self->{api_manager}->get_model_capabilities() || {};
        }
        
        $history = $self->_trim_conversation_for_api(
            $history, 
            $system_prompt,
            model_context_window => $model_caps->{max_context_window_tokens} // 128000,
            max_response_tokens => $model_caps->{max_output_tokens} // 16000,
        );
    }
    
    if ($history && @$history) {
        push @messages, @$history;
        log_debug('WorkflowOrchestrator', "Loaded " . scalar(@$history) . " messages from history (after pre-flight trim)");
    }
    
    # Add current user message to messages array for API call
    push @messages, {
        role => 'user',
        content => $user_input
    };
    
    # Save user message to session history NOW (before processing)
    # This ensures the message is persisted even if processing fails
    if ($session && $session->can('add_message')) {
        $session->add_message('user', $user_input);
        log_debug('WorkflowOrchestrator', "Saved user message to session history");
    }
    
    # Get tool definitions from registry (for API)
    my $tools = $self->{tool_registry}->get_tool_definitions();
    
    # Add MCP tool definitions if MCP is active
    if ($self->{mcp_manager}) {
        eval {
            require CLIO::Tools::MCPBridge;
            my $mcp_defs = CLIO::Tools::MCPBridge->generate_tool_definitions($self->{mcp_manager});
            if ($mcp_defs && @$mcp_defs) {
                for my $mcp_def (@$mcp_defs) {
                    push @$tools, {
                        type     => 'function',
                        function => {
                            name        => $mcp_def->{name},
                            description => $mcp_def->{description},
                            parameters  => $mcp_def->{parameters},
                        },
                    };
                }
                log_debug('WorkflowOrchestrator', "Added " . scalar(@$mcp_defs) . " MCP tool(s) to API definitions");
            }
        };
        log_warning('WorkflowOrchestrator', "MCP tool definition error: $@") if $@;
    }
    
    log_debug('WorkflowOrchestrator', "Loaded " . scalar(@$tools) . " tool definitions");
    
    # Main workflow loop
    my $iteration = 0;
    my @tool_calls_made = ();
    my $start_time = time();
    my $retry_count = 0;  # Track retries per iteration (prevents infinite loops)
    my $max_retries = 3;  # Maximum retries for API errors (malformed JSON, etc.)
    my $max_server_retries = 20;  # Higher limit for server/network errors (502, 503, 599)
    
    # Session-level error budget: Limit total errors across all iterations
    # This prevents cascading failures from consuming the entire session
    my $session_error_count = $session->{_error_count} // 0;
    my $max_session_errors = 10;  # Hard limit per request processing
    
    while ($iteration < $self->{max_iterations}) {
        $iteration++;
        
        # Clear interrupt pending flag at start of each iteration
        $self->{_interrupt_pending} = 0;
        
        # Capture process stats at iteration boundary
        $self->{process_stats}->capture('iteration_start', { iteration => $iteration })
            if $self->{process_stats};
        
        log_debug('WorkflowOrchestrator', "Iteration $iteration/$self->{max_iterations}");
        
        # Check for user interrupt (ESC key press)
        if ($self->_check_for_user_interrupt($session)) {
            $self->_handle_interrupt($session, \@messages);
            # Don't count this iteration - interrupt handling is free
            $iteration--;
        }
        
        # Enforce message alternation for Claude compatibility
        # Must be done before EVERY API call, as messages array is modified during tool calling
        my $alternated_messages = $self->_enforce_message_alternation(\@messages);
        
        # Show busy indicator before API call if this is a continuation after tool execution
        # On first iteration, the spinner is already shown by Chat.pm before calling orchestrate()
        # On subsequent iterations (after tools), DON'T show "CLIO: " here - let streaming callback
        # decide whether to show it based on whether there's actual content or just tool calls
        if ($iteration > 1 && $self->{ui}) {
            # Show the busy indicator (spinner) without prefix
            # If there's content, the streaming callback will print "CLIO: " before it
            if ($self->{ui}->can('show_busy_indicator')) {
                $self->{ui}->show_busy_indicator();
                log_debug('WorkflowOrchestrator', "Showing busy indicator before API iteration $iteration");
            }
        }
        
        # Send to AI with tools (ALWAYS use streaming for proper quota headers from GitHub Copilot)
        my $api_response = eval {
            # Use streaming mode always (GitHub Copilot requires stream:true for real quota data)
            # If no callback provided, use a no-op callback
            log_debug('WorkflowOrchestrator', "Using streaming mode (iteration $iteration)");
            
            # Provide a default no-op callback if none specified
            my $base_callback = $on_chunk || sub { };  # No-op callback
            
            # Wrap callback to check for user interrupt during streaming
            # With true streaming (data_callback), this fires for each SSE chunk
            # and allows ESC detection within ~1 second during content generation
            my $callback = sub {
                my @args = @_;
                
                # Check for interrupt on each streaming chunk
                if (!$self->{_interrupt_pending} && $self->_check_for_user_interrupt($session)) {
                    $self->{_interrupt_pending} = 1;
                    log_info('WorkflowOrchestrator', "Interrupt detected during streaming");
                    # Still deliver this chunk, but the flag will be checked after streaming completes
                }
                
                $base_callback->(@args);
            };
            
            # Define tool call callback to show tool names as they stream in
            my $tool_callback = sub {
                my ($tool_name) = @_;
                
                # Call UI callback if provided (Chat.pm tool display)
                if ($on_tool_call_from_ui) {
                    eval { $on_tool_call_from_ui->($tool_name); };
                    if ($@) {
                        log_debug('WorkflowOrchestrator', "UI callback error: $@");
                    }
                }
                
                # Also show in orchestrator context
                log_debug('WorkflowOrchestrator', "Tool called: $tool_name");
            };
            
            # DEBUG: Log messages being sent to API when debug mode is enabled
            if ($self->{debug}) {
                log_debug('WorkflowOrchestrator', "Sending to API: " . scalar(@$alternated_messages) . " messages");
                for my $i (0 .. $#{$alternated_messages}) {
                    my $msg = $alternated_messages->[$i];
                    log_debug('WorkflowOrchestrator', "API Message $i: role=" . $msg->{role});
                    if ($msg->{tool_calls}) {
                        log_debug('WorkflowOrchestrator', ", tool_calls=" . scalar(@{$msg->{tool_calls}}));
                        for my $tc (@{$msg->{tool_calls}}) {
                            log_debug('WorkflowOrchestrator', ", tc_id=" . (defined $tc->{id} ? $tc->{id} : "**MISSING**"));
                        }
                    }
                    if ($msg->{role} eq 'tool') {
                        log_debug('WorkflowOrchestrator', ", tool_call_id=" . (defined $msg->{tool_call_id} ? $msg->{tool_call_id} : "**MISSING**"));
                    }
                    log_debug('WorkflowOrchestrator', "");
                }
            }
            
            $self->{api_manager}->send_request_streaming(
                undef,  # No direct input (using messages)
                messages => $alternated_messages,  # Use alternation-enforced messages
                tools => $tools,
                tool_call_iteration => $iteration,  # Track iteration for billing
                on_chunk => $callback,
                on_tool_call => $tool_callback,
                on_thinking => $on_thinking,
            );
        };
        
        # Check for user interrupt after API call completes
        # The API call can take 30-60+ seconds, so this is a critical check point
        # Also check if interrupt was detected during streaming (via _interrupt_pending flag)
        if ($self->{_interrupt_pending} || $self->_check_and_handle_interrupt($session, \@messages)) {
            # If interrupt was pending from streaming, we still need to handle it
            if ($self->{_interrupt_pending} && !grep { $_->{content} && $_->{content} =~ /USER INTERRUPT/ } @messages) {
                $self->_handle_interrupt($session, \@messages);
            }
            # Interrupt detected - skip tool execution and go straight to next iteration
            # which will send the interrupt message to the AI
            $iteration--;  # Don't count this iteration
            next;
        }
        
        if ($@) {
            log_debug('WorkflowOrchestrator', "API error: $@");
            return {
                success => 0,
                error => "API request failed: $@",
                iterations => $iteration,
                tool_calls_made => \@tool_calls_made
            };
        }
        
        # Check for API errors
        if (!$api_response || $api_response->{error}) {
            my $error = $api_response->{error} || "Unknown API error";
            
            # Track session-level errors for budget enforcement
            $session_error_count++;
            $session->{_error_count} = $session_error_count;
            
            # Check if we've exceeded session error budget
            if ($session_error_count > $max_session_errors) {
                log_error('WorkflowOrchestrator', "Session error budget exhausted ($session_error_count errors). Stopping to prevent cascading failures.");
                return {
                    success => 0,
                    error => "Session error limit reached ($max_session_errors errors). Please start a new request or session. Last error: $error",
                    iterations => $iteration,
                    tool_calls_made => \@tool_calls_made
                };
            }
            
            # Check if this is a retryable error (rate limit or server error)
            if ($api_response->{retryable}) {
                $retry_count++;
                
                # Determine which retry limit to use based on error type
                # Rate limits and server errors get more retries (transient issues)
                my $error_type_for_limit = $api_response->{error_type} || '';
                my $retry_limit = ($error_type_for_limit eq 'server_error' || $error_type_for_limit eq 'rate_limit') 
                    ? $max_server_retries 
                    : $max_retries;
                
                # Check if we've exceeded max retries for this iteration
                if ($retry_count > $retry_limit) {
                    log_error('WorkflowOrchestrator', "Maximum retries ($retry_limit) exceeded for this iteration");
                    return {
                        success => 0,
                        error => "Maximum retries exceeded: $error",
                        iterations => $iteration,
                        tool_calls_made => \@tool_calls_made
                    };
                }
                
                my $retry_delay = $api_response->{retry_after} || 2;
                
                # Determine error type for logging
                my $error_type = $error =~ /rate limit/i ? "rate limit" : "server error";
                my $system_msg = "Temporary $error_type detected. Retrying in ${retry_delay}s... (attempt $retry_count/$retry_limit)";
                
                # Special handling for malformed tool JSON errors
                # ONE RETRY ONLY: Remove bad message, add guidance with tool schema, let AI fix it
                if ($api_response->{error_type} && $api_response->{error_type} eq 'malformed_tool_json') {
                    if ($retry_count == 1) {
                        # First attempt: Remove bad message and provide detailed guidance
                        
                        # Remove the malformed assistant message from history
                        if (@messages && $messages[-1]->{role} eq 'assistant') {
                            my $removed_msg = pop @messages;
                            log_info('WorkflowOrchestrator', "Removed malformed assistant message from history");
                        }
                        
                        # Extract the tool name from error if available to provide specific schema
                        my $failed_tool_name = $api_response->{failed_tool} || 'unknown';
                        my $tool_schema = '';
                        
                        # Get the specific tool's schema to help AI understand the correct format
                        if ($failed_tool_name ne 'unknown') {
                            my $tool_def = $self->{tool_registry}->get_tool($failed_tool_name);
                            if ($tool_def) {
                                # Extract just the parameters section for clarity
                                my $params = $tool_def->{function}{parameters};
                                if ($params) {
                                    require JSON::PP;
                                    $tool_schema = "\n\nCorrect schema for $failed_tool_name:\n" . 
                                                   JSON::PP->new->pretty->encode($params);
                                }
                            }
                        }
                        
                        # First retry: provide detailed guidance based on the failed tool
                        my $tool_guidance = _get_tool_specific_guidance($failed_tool_name);
                        
                        my $guidance_msg = {
                            role => 'system',
                            content => "ERROR: Your previous tool call had invalid JSON parameters.\n\n" .
                                       "Common issues:\n" .
                                       "- Missing parameter values (e.g., \"offset\":, instead of \"offset\":0)\n" .
                                       "- Unescaped quotes in strings\n" .
                                       "- Trailing commas\n" .
                                       "- Missing required parameters\n\n" .
                                       "ALL parameters must have valid values - no empty/missing values permitted.\n" .
                                       "$tool_schema\n\n" .
                                       "$tool_guidance" .
                                       "Please retry the operation with correct JSON, or try a different approach if the tool call isn't critical."
                        };
                        push @messages, $guidance_msg;
                        
                        $error_type = "malformed tool JSON";
                        $system_msg = "AI generated invalid JSON parameters. Removed bad message, adding guidance and retrying... (attempt $retry_count/$max_retries)";
                        
                        log_info('WorkflowOrchestrator', "Added JSON formatting guidance for tool: $failed_tool_name");
                    }
                    else {
                        # Second attempt failed: DON'T give up - let agent continue with error context
                        # Remove the failed assistant message again
                        if (@messages && $messages[-1]->{role} eq 'assistant') {
                            pop @messages;
                            log_info('WorkflowOrchestrator', "Removed second malformed assistant message");
                        }
                        
                        # Add a recovery message that preserves context
                        my $recovery_msg = {
                            role => 'system',
                            content => "TOOL CALL FAILED: The previous tool call still had invalid JSON after correction attempt. " .
                                       "The tool call has been removed from history. You can:\n" .
                                       "1. Try a different approach to accomplish the same goal\n" .
                                       "2. Continue with other work\n" .
                                       "3. Ask the user for clarification if needed\n\n" .
                                       "Your conversation context is preserved - continue your work."
                        };
                        push @messages, $recovery_msg;
                        
                        # Reset retry count and continue the workflow loop
                        # The agent can recover and try something else
                        $retry_count = 0;
                        
                        log_warning('WorkflowOrchestrator', "Malformed JSON persisted - agent informed, continuing workflow");
                        
                        # Don't return error - let the loop continue so AI can recover
                        # Skip the sleep and retry, just continue to next iteration
                        next;  # Skip sleep/retry, go to next iteration
                    }
                }
                # Special handling for token limit exceeded errors
                elsif ($api_response->{error_type} && $api_response->{error_type} eq 'token_limit_exceeded') {
                    # Trim conversation history to fit within model's context window
                    # Remove oldest messages while keeping system prompt, FIRST USER MESSAGE, and recent context
                    # Preserve tool_call/tool_result pairs to avoid orphans
                    
                    my $system_prompt = undef;
                    my @non_system = ();
                    my $first_user_msg = undef;
                    my $first_user_idx = -1;
                    
                    # Separate system prompt and find first user message
                    for my $msg (@messages) {
                        if ($msg->{role} eq 'system' && !$system_prompt) {
                            $system_prompt = $msg;
                        } else {
                            push @non_system, $msg;
                            # Track first user message (critical for context)
                            if (!$first_user_msg && $msg->{role} && $msg->{role} eq 'user' &&
                                ($msg->{_importance} // 0) >= 10.0) {
                                $first_user_msg = $msg;
                                $first_user_idx = $#non_system;
                            }
                        }
                    }
                    
                    my $original_count = scalar(@non_system);
                    
                    # Build map of tool_call_id -> message indices for smart trimming
                    my %tool_call_indices = ();  # tool_call_id => index in @non_system
                    my %tool_result_indices = (); # tool_call_id => index in @non_system
                    
                    for (my $i = 0; $i < @non_system; $i++) {
                        my $msg = $non_system[$i];
                        # Track tool_calls from assistant messages
                        if ($msg->{role} && $msg->{role} eq 'assistant' && 
                            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                            for my $tc (@{$msg->{tool_calls}}) {
                                $tool_call_indices{$tc->{id}} = $i if $tc->{id};
                            }
                        }
                        # Track tool_results
                        elsif ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
                            $tool_result_indices{$msg->{tool_call_id}} = $i;
                        }
                    }
                    
                    if ($retry_count == 1) {
                        # First retry: Keep last 50% of messages + first user message
                        my $keep_count = int($original_count / 2);
                        $keep_count = 10 if $keep_count < 10 && $original_count >= 10;  # Keep at least 10
                        
                        # Calculate starting index
                        my $start_idx = $original_count - $keep_count;
                        $start_idx = 0 if $start_idx < 0;
                        
                        # Find any tool_results in the kept range that need their tool_calls
                        my @must_include = ();
                        
                        # Always include first user message if it would be trimmed
                        if ($first_user_idx >= 0 && $first_user_idx < $start_idx) {
                            push @must_include, $first_user_idx;
                        }
                        
                        for (my $i = $start_idx; $i < $original_count; $i++) {
                            my $msg = $non_system[$i];
                            if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
                                my $tc_id = $msg->{tool_call_id};
                                if (exists $tool_call_indices{$tc_id}) {
                                    my $tc_idx = $tool_call_indices{$tc_id};
                                    if ($tc_idx < $start_idx) {
                                        push @must_include, $tc_idx;
                                    }
                                }
                            }
                        }
                        
                        # Include the essential messages (first user + tool_calls)
                        if (@must_include) {
                            @must_include = sort { $a <=> $b } @must_include;
                            my @preserved = ();
                            my %seen = ();
                            for my $idx (@must_include) {
                                next if $seen{$idx}++;
                                push @preserved, $non_system[$idx];
                            }
                            # Add the trimmed messages
                            push @preserved, @non_system[$start_idx..-1];
                            @non_system = @preserved;
                        } else {
                            @non_system = @non_system[$start_idx..-1];
                        }
                    } elsif ($retry_count == 2) {
                        # Second retry: Keep last 25% of messages + first user message
                        my $keep_count = int($original_count / 4);
                        $keep_count = 5 if $keep_count < 5 && $original_count >= 5;  # Keep at least 5
                        
                        my @kept = @non_system[-$keep_count..-1] if $keep_count > 0;
                        
                        # Ensure first user message is preserved
                        if ($first_user_msg && !grep { $_ == $first_user_msg } @kept) {
                            unshift @kept, $first_user_msg;
                        }
                        @non_system = @kept;
                    } else {
                        # Third retry: Keep first user message + last 2 messages (minimal context)
                        my @kept = ();
                        push @kept, $first_user_msg if $first_user_msg;
                        
                        # Add last 2 messages (if not the first user message)
                        my @last_two = @non_system[-2..-1];
                        for my $msg (@last_two) {
                            next if $first_user_msg && $msg == $first_user_msg;
                            push @kept, $msg;
                        }
                        @non_system = @kept;
                    }
                    
                    my $trimmed_count = $original_count - scalar(@non_system);
                    
                    # Rebuild messages array
                    @messages = ();
                    push @messages, $system_prompt if $system_prompt;
                    push @messages, @non_system;
                    
                    $error_type = "token limit exceeded";
                    my $preserved_info = $first_user_msg ? " (first user message preserved)" : "";
                    $system_msg = "Token limit exceeded. Trimmed $trimmed_count messages from conversation history and retrying$preserved_info... (attempt $retry_count/$max_retries)";
                    
                    log_info('WorkflowOrchestrator', "Trimmed $trimmed_count messages due to token limit (kept " . scalar(@non_system) . " messages, first_user=" . ($first_user_msg ? 'YES' : 'NO') . ")");
                    
                    # If we've trimmed to minimal context and still failing, give up
                    if ($retry_count > 2 && scalar(@non_system) <= 3) {
                        log_debug('WorkflowOrchestrator', "Token limit persists even with minimal context - giving up");
                        return {
                            success => 0,
                            error => "Token limit exceeded even with minimal conversation history. The request may be too large for this model. Try using a model with a larger context window.",
                            tool_calls_made => \@tool_calls_made
                        };
                    }
                }
                # Special handling for server errors (502, 503) - exponential backoff
                elsif ($api_response->{error_type} && $api_response->{error_type} eq 'server_error') {
                    # Apply exponential backoff: 2s, 4s, 8s, 16s...
                    my $backoff_multiplier = 2 ** ($retry_count - 1);
                    $retry_delay = $retry_delay * $backoff_multiplier;
                    
                    $error_type = "server error";
                    $system_msg = "Server temporarily unavailable. Retrying in ${retry_delay}s with exponential backoff... (attempt $retry_count/$max_server_retries)";
                    
                    log_info('WorkflowOrchestrator', "Applying exponential backoff for server error: ${retry_delay}s delay");
                }
                # Special handling for rate limit errors
                elsif ($api_response->{error_type} && $api_response->{error_type} eq 'rate_limit') {
                    # Rate limit already has appropriate retry_after from APIManager
                    # Just update the error_type for logging
                    $error_type = "rate limit";
                    # system_msg already set above
                }
                # Special handling for message structure errors (auto-repair attempted but failed)
                elsif ($api_response->{error_type} && $api_response->{error_type} eq 'message_structure_error') {
                    # Message structure was corrupted and couldn't be repaired
                    # Try to recover by rebuilding from session history
                    $error_type = "message structure error";
                    $system_msg = "Message structure error detected. Rebuilding from session history... (attempt $retry_count/$max_retries)";
                    
                    # Reload conversation history from session to get clean state
                    if ($session && $session->can('get_conversation_history')) {
                        my $fresh_history = $session->get_conversation_history() || [];
                        
                        # Rebuild messages: system prompt + fresh history + current user message
                        my $system_msg_content = $messages[0]->{role} eq 'system' ? $messages[0] : undef;
                        my $current_user_msg = $messages[-1]->{role} eq 'user' ? $messages[-1] : undef;
                        
                        @messages = ();
                        push @messages, $system_msg_content if $system_msg_content;
                        push @messages, @$fresh_history;
                        push @messages, $current_user_msg if $current_user_msg && 
                            (!@$fresh_history || $fresh_history->[-1]->{content} ne $current_user_msg->{content});
                        
                        log_info('WorkflowOrchestrator', "Rebuilt messages from session history (" . scalar(@messages) . " messages)");
                    }
                    
                    $retry_delay = 0;  # Instant retry after rebuild
                }
                
                # Call system message callback if provided
                if ($on_system_message) {
                    eval { $on_system_message->($system_msg); };
                    log_debug('WorkflowOrchestrator', "UI callback error: $@");
                } else {
                    log_info('WorkflowOrchestrator', "Retryable $error_type detected, retrying in ${retry_delay}s on next iteration (attempt $retry_count/$max_retries)");
                }
                
                # Enable signal delivery during retry wait
                local $SIG{ALRM} = sub { alarm(1); };
                alarm(1);
                
                # Wait before retrying
                sleep($retry_delay);
                
                alarm(0);  # Disable alarm after retry completes
                
                # Don't increment iteration counter - this failed attempt doesn't count
                $iteration--;
                # Continue to next iteration
                next;
            }
            
            # Non-retryable error - reset retry counter for next iteration
            $retry_count = 0;
            
            # Track consecutive identical errors to prevent infinite loops
            if ($error eq $self->{last_error}) {
                $self->{consecutive_errors}++;
                log_warning('WorkflowOrchestrator', "Consecutive error count: $self->{consecutive_errors}/$self->{max_consecutive_errors}");
            } else {
                $self->{consecutive_errors} = 1;
                $self->{last_error} = $error;
            }
            
            # Break infinite loop if same error repeats too many times
            if ($self->{consecutive_errors} >= $self->{max_consecutive_errors}) {
                log_debug('WorkflowOrchestrator', "Same error occurred $self->{consecutive_errors} times in a row. Breaking loop.");
                log_debug('WorkflowOrchestrator', "Persistent error: $error");
                log_debug('WorkflowOrchestrator', "This likely indicates a bug in the request construction or API incompatibility.");
                log_debug('WorkflowOrchestrator', "Check /tmp/clio_json_errors.log for details.");
                
                # Reset counters and return failure
                $self->{consecutive_errors} = 0;
                $self->{last_error} = '';
                return {
                    role => 'assistant',
                    content => "I encountered a persistent error that I cannot resolve:\n\n$error\n\n" .
                              "This error occurred $self->{consecutive_errors} times consecutively. " .
                              "There may be a bug in the system or an API incompatibility. " .
                              "Please check the error logs for more details."
                };
            }
            
            # Remove the last assistant message from @messages array if it exists
            # This prevents issues where a bad AI response keeps triggering the same error
            # The AI will see the error message and try a different approach
            if (@messages && $messages[-1]->{role} eq 'assistant') {
                my $removed_msg = pop @messages;
                log_warning('WorkflowOrchestrator', "Removed bad assistant message due to API error: $error");
                
                # Show what was removed for debugging
                if ($self->{debug}) {
                    my $content_preview = substr($removed_msg->{content} // '', 0, 100);
                    log_debug('WorkflowOrchestrator', "Removed message content: $content_preview...");
                    if ($removed_msg->{tool_calls}) {
                        log_debug('WorkflowOrchestrator', "Removed message had " . scalar(@{$removed_msg->{tool_calls}}) . " tool_calls");
                    }
                }
            }
            
            # Check if error is token/context limit related
            # IMPORTANT: Be precise here - we must NOT match:
            # - Auth errors mentioning "token" (401/403 with "token expired")
            # - Rate limit errors mentioning "limit" (429)
            # - Network errors (599 Internal Exception)
            # We ONLY want to match actual context window exceeded errors
            my $is_token_limit_error = (
                $error =~ /context.length.exceeded/i ||
                $error =~ /maximum.context.length/i ||
                $error =~ /token.limit.exceeded/i ||
                $error =~ /too.many.tokens/i ||
                $error =~ /exceeds?\s+(?:the\s+)?(?:maximum|max)\s+(?:number\s+of\s+)?tokens/i ||
                $error =~ /input.*too\s+(?:long|large)/i ||
                $error =~ /reduce.*(?:prompt|input|context)/i
            );
            
            # Only add error message if it's not a token limit error
            # Token limit errors need more aggressive context trimming, not error messages
            # (error messages just make the problem worse)
            if (!$is_token_limit_error) {
                # Add error message to conversation so AI knows what went wrong
                # Format it as a user message (to maintain alternation)
                push @messages, {
                    role => 'user',
                    content => "SYSTEM ERROR: Your previous response triggered an API error and was removed.\n\n" .
                               "Error details: $error\n\n" .
                               "Please try a different approach. Avoid repeating the same action that caused this error."
                };
                
                log_info('WorkflowOrchestrator', "Added error message to conversation, continuing workflow");
            } else {
                # Token limit error - trim messages instead of adding error
                log_warning('WorkflowOrchestrator', "Token limit error detected. Using smart context trimming...");
                
                # Smart trim: Keep system message + recent complete message groups
                # A "message group" is either:
                # - A user message
                # - An assistant message followed by all its tool results (if any)
                # This preserves tool call/result pairs to avoid API errors
                
                my $system_msg = undef;
                my @non_system = ();
                for my $msg (@messages) {
                    if ($msg->{role} && $msg->{role} eq 'system') {
                        $system_msg = $msg;
                    } else {
                        push @non_system, $msg;
                    }
                }
                
                # Group messages into logical units
                my @groups = ();  # Each group is an arrayref of messages
                my $current_group = [];
                
                for (my $i = 0; $i < @non_system; $i++) {
                    my $msg = $non_system[$i];
                    
                    if ($msg->{role} eq 'user') {
                        # User messages start a new group (except first)
                        if (@$current_group > 0) {
                            push @groups, $current_group;
                        }
                        $current_group = [$msg];
                    } elsif ($msg->{role} eq 'assistant') {
                        # Assistant messages either continue or start a group
                        if (@$current_group > 0 && $current_group->[-1]{role} eq 'user') {
                            # Continue the current group (user -> assistant)
                            push @$current_group, $msg;
                        } else {
                            # Start a new group
                            if (@$current_group > 0) {
                                push @groups, $current_group;
                            }
                            $current_group = [$msg];
                        }
                    } elsif ($msg->{role} eq 'tool') {
                        # Tool results always belong to the current group
                        push @$current_group, $msg;
                    } else {
                        # Unknown role - add to current group
                        push @$current_group, $msg;
                    }
                }
                # Don't forget the last group
                if (@$current_group > 0) {
                    push @groups, $current_group;
                }
                
                # Keep last 3 complete groups (typically user + assistant + tools)
                my $keep_count = 3;
                $keep_count = scalar(@groups) if $keep_count > scalar(@groups);
                
                my @kept_groups = @groups[-$keep_count..-1] if $keep_count > 0;
                
                # Rebuild messages array
                @messages = ();
                push @messages, $system_msg if $system_msg;
                for my $group (@kept_groups) {
                    push @messages, @$group;
                }
                
                my $removed_groups = scalar(@groups) - $keep_count;
                log_info('WorkflowOrchestrator', "Smart trim: kept $keep_count of " . scalar(@groups) . " message groups (removed $removed_groups)");
            }
            
            # Continue to next iteration - let AI try again with the error context
            next;
        }
        
        # API call succeeded - reset retry counter and clear session error count
        $retry_count = 0;
        $self->{consecutive_errors} = 0;
        $self->{last_error} = '';
        $session_error_count = 0;  # Reset on success to allow future errors
        delete $session->{_error_count} if $session;
        
        # Record API usage for billing tracking
        if ($api_response->{usage} && $session) {
            if ($session->can('record_api_usage')) {
                # Get current model and provider from API manager (dynamic lookup)
                my $model = $self->{api_manager}->get_current_model();
                my $provider = $self->{api_manager}->get_current_provider();
                $session->record_api_usage($api_response->{usage}, $model, $provider);
                log_debug('WorkflowOrchestrator', "Recorded API usage: model=$model, provider=$provider");
            }
        }
        
        # Debug: Log API response structure
        if ($self->{debug}) {
            log_debug('WorkflowOrchestrator', "API response received");
            if ($api_response->{tool_calls}) {
                log_debug('WorkflowOrchestrator', "Tool calls detected: " . scalar(@{$api_response->{tool_calls}}));
            } else {
                log_debug('WorkflowOrchestrator', "No structured tool calls in response");
            }
        }
        
        # Extract text-based tool calls from content if no structured tool_calls
        # This supports models that output tool calls as text instead of using OpenAI format
        if (!$api_response->{tool_calls} || !@{$api_response->{tool_calls}}) {
            require CLIO::Core::ToolCallExtractor;
            my $extractor = CLIO::Core::ToolCallExtractor->new(debug => $self->{debug});
            
            my $result = $extractor->extract($api_response->{content});
            
            if (@{$result->{tool_calls}}) {
                log_debug('WorkflowOrchestrator', "Extracted " . scalar(@{$result->{tool_calls}}) . " text-based tool calls (format: $result->{format})");
                
                # Update response to include extracted tool calls
                $api_response->{tool_calls} = $result->{tool_calls};
                # Update content to remove tool call text
                $api_response->{content} = $result->{cleaned_content};
            }
        }
        
        # Check if AI requested tool calls (structured or text-based)
        my $assistant_msg_pending = undef;  # Will be set if we need delayed save
        
        if ($api_response->{tool_calls} && @{$api_response->{tool_calls}}) {
            # Validate tool_calls arguments JSON before adding to history
            # This prevents malformed JSON from contaminating conversation history
            # which would cause API rejection on the next request
            my @validated_tool_calls = ();
            my $had_validation_errors = 0;
            
            for my $tool_call (@{$api_response->{tool_calls}}) {
                my $tool_name = $tool_call->{function}->{name} || 'unknown';
                my $arguments_str = $tool_call->{function}->{arguments} || '{}';
                
                # Attempt to parse arguments JSON
                # Handle UTF-8: JSON::PP expects bytes, not Perl's internal UTF-8 strings
                my $arguments_valid = 0;
                eval {
                    use CLIO::Util::JSON qw(decode_json);
                    use Encode qw(encode_utf8);
                    
                    # Convert to UTF-8 bytes if it's a wide string
                    my $json_bytes = utf8::is_utf8($arguments_str) ? encode_utf8($arguments_str) : $arguments_str;
                    my $parsed = decode_json($json_bytes);
                    $arguments_valid = 1;
                };
                
                if ($@) {
                    # JSON parsing failed - attempt repair first, only log error if repair fails
                    my $error = $@;
                    
                    # Attempt to repair common JSON errors
                    my $repaired = $self->_repair_tool_call_json($arguments_str);
                    
                    if ($repaired) {
                        # Repair succeeded - log at DEBUG level (user doesn't need to know)
                        log_debug('WorkflowOrchestrator', "Repaired malformed JSON for tool '$tool_name'");
                        $tool_call->{function}->{arguments} = $repaired;
                        push @validated_tool_calls, $tool_call;
                    } else {
                        # Repair failed - NOW log the error at ERROR level
                        $had_validation_errors = 1;
                        log_error('WorkflowOrchestrator', "Invalid JSON in tool call arguments for '$tool_name': $error");
                        log_error('WorkflowOrchestrator', "Malformed arguments: " . substr($arguments_str, 0, 200));
                        log_error('WorkflowOrchestrator', "Could not repair JSON for tool '$tool_name' - tool call will be skipped");
                        
                        # Add an error message to conversation explaining what happened
                        push @messages, {
                            role => 'tool',
                            tool_call_id => $tool_call->{id},
                            content => "ERROR: Tool call rejected due to invalid JSON in arguments. The AI generated malformed parameters that could not be parsed. Please retry with valid JSON."
                        };
                    }
                } else {
                    # JSON is valid - add to validated list
                    push @validated_tool_calls, $tool_call;
                }
            }
            
            # Replace tool_calls with validated version
            $api_response->{tool_calls} = \@validated_tool_calls;
            
            # If all tool calls were rejected, skip tool execution entirely
            if (@validated_tool_calls == 0) {
                log_error('WorkflowOrchestrator', "All tool calls were rejected due to invalid JSON - skipping tool execution");
                
                # Add simple text response to continue conversation
                push @messages, {
                    role => 'assistant',
                    content => $api_response->{content} || "I encountered an error with my tool calls. Let me try a different approach."
                };
                
                # Skip tool execution - continue to next iteration
                next;
            }
            
            log_debug('WorkflowOrchestrator', "Processing " . scalar(@validated_tool_calls) . " validated tool calls" .
                ($had_validation_errors ? " (some were rejected/repaired)" : "") . "\n");
            
            # Add assistant's message with VALIDATED tool_calls to conversation
            push @messages, {
                role => 'assistant',
                content => $api_response->{content},
                tool_calls => \@validated_tool_calls
            };
            
            # DELAYED SAVE: Do NOT save assistant message with tool_calls yet.
            # 
            # REASONING (prevents orphaned tool_calls on interrupt):
            # If we save the assistant message now, but tool execution is interrupted (Ctrl-C),
            # the tool results never get saved, leaving orphaned tool_calls in history.
            # On resume, these orphans cause API errors.
            #
            # SOLUTION: Delay saving the assistant message until AFTER the first tool
            # result is saved. This ensures assistant message + tool results are saved
            # together as an atomic unit, avoiding orphans entirely.
            #
            # If user interrupts during tool execution:
            # - Assistant message + tool_calls NOT yet saved
            # - History naturally ends at previous turn (clean state)
            # - No orphans, no cleanup needed on resume
            #
            # The flag below is used in tool result saving (see ~line 780) to ensure
            # the assistant message is saved when the first tool result completes.
            
            $assistant_msg_pending = {
                role => 'assistant',
                content => $api_response->{content} // '',
                tool_calls => \@validated_tool_calls  # Use validated version
            };
            
            log_debug('WorkflowOrchestrator', "Delaying save of assistant message with tool_calls until first tool result completes");
            
            # Classify tools by execution requirements (SAM pattern + CLIO enhancements)
            # - BLOCKING: Must complete before workflow continues (interactive tools)
            # - SERIAL: Execute one-at-a-time but don't block workflow
            # - PARALLEL: Execute concurrently (default)
            #
            # isInteractive parameter handling (Option C - hybrid approach):
            # 1. Check parameter: $params->{isInteractive} (per-call override)
            # 2. Fall back to metadata: $tool->{is_interactive} (default)
            # 3. Default to false if neither specified
            my @blocking_tools = ();
            my @serial_tools = ();
            my @parallel_tools = ();
            
            for my $tool_call (@{$api_response->{tool_calls}}) {
                my $tool_name = $tool_call->{function}->{name} || 'unknown';
                my $tool = $self->{tool_registry}->get_tool($tool_name);
                
                # Parse tool arguments to check for isInteractive parameter
                my $params = {};
                if ($tool_call->{function}->{arguments}) {
                    eval {
                        my $json_str = $tool_call->{function}->{arguments};

                        # Debug: Show original arguments before any processing
                        if ($self->{debug}) {
                            my $preview = substr($json_str, 0, 300);
                            log_debug('WorkflowOrchestrator', "Original arguments (first 300 chars): $preview");
                        }

                        # Check for Anthropic XML format first
                        # Claude sometimes uses native XML instead of JSON for tool calls
                        if (is_anthropic_xml_format($json_str)) {
                            log_info('WorkflowOrchestrator', "Detected Anthropic XML format, converting to JSON");
                            $json_str = parse_anthropic_xml_to_json($json_str, $self->{debug});
                            log_debug('WorkflowOrchestrator', "Converted XML to JSON: " . substr($json_str, 0, 300));
                        } else {
                            # Standard JSON path - try repair if needed
                            $json_str = repair_malformed_json($json_str, $self->{debug});

                            # Debug: Show repaired JSON
                            if ($self->{debug}) {
                                my $preview = substr($json_str, 0, 300);
                                log_debug('WorkflowOrchestrator', "Repaired JSON arguments (first 300 chars): $preview");
                            }
                        }
                        
                        # Encode to UTF-8 bytes to avoid "Wide character in subroutine entry"
                        my $json_bytes = encode_utf8($json_str);
                        
                        $params = decode_json($json_bytes);
                    };
                    if ($@) {
                        my $tool_name = $tool_call->{function}->{name} || 'unknown';
                        my $error = $@;
                        my $args_full = $tool_call->{function}->{arguments} || '';
                        
                        log_error('WorkflowOrchestrator', "Failed to parse arguments for tool '$tool_name': $error");
                        log_error('WorkflowOrchestrator', "Full arguments:\n$args_full");
                        
                        # Instead of skipping (which creates orphaned tool_use), create an error tool_result
                        # This keeps tool_use/tool_result pairs intact and prevents infinite loops
                        my $error_message = "JSON parsing failed for tool '$tool_name': $error\nArguments received:\n$args_full";
                        
                        # Add error result to conversation immediately
                        push @messages, {
                            role => 'tool',
                            tool_call_id => $tool_call->{id},
                            content => $error_message
                        };
                        
                        # Save error result to session
                        if ($session && $session->can('add_message')) {
                            eval {
                                # Save the assistant message with tool_calls on FIRST tool result (even if error)
                                if ($assistant_msg_pending) {
                                    $session->add_message(
                                        'assistant',
                                        $assistant_msg_pending->{content},
                                        { tool_calls => $assistant_msg_pending->{tool_calls} }
                                    );
                                    log_debug('WorkflowOrchestrator', "Saved assistant message with tool_calls to session (on error result)");
                                    $assistant_msg_pending = undef;
                                }
                                
                                # Save the error result
                                $session->add_message(
                                    'tool',
                                    $error_message,
                                    { tool_call_id => $tool_call->{id} }
                                );
                                log_debug('WorkflowOrchestrator', "Saved error tool result to session");
                            };
                            if ($@) {
                                log_debug('WorkflowOrchestrator', "Session save error (non-critical): $@");
                            }
                        }
                        
                        # Skip to next tool call (error has been recorded, no execution needed)
                        next;
                    }
                }
                
                # Determine if tool is interactive (hybrid: parameter overrides metadata)
                my $is_interactive = 0;
                if (exists $params->{isInteractive}) {
                    $is_interactive = $params->{isInteractive} ? 1 : 0;
                    log_debug('WorkflowOrchestrator', "Tool $tool_name isInteractive parameter: $is_interactive");
                } elsif ($tool && $tool->{is_interactive}) {
                    $is_interactive = 1;
                    log_debug('WorkflowOrchestrator', "Tool $tool_name default is_interactive: $is_interactive");
                }
                
                # Interactive tools are BLOCKING (must wait for user I/O)
                my $requires_blocking = ($tool && $tool->{requires_blocking}) || $is_interactive;
                
                if ($tool) {
                    if ($requires_blocking) {
                        push @blocking_tools, $tool_call;
                        log_debug('WorkflowOrchestrator', "Classified $tool_name as BLOCKING (interactive=$is_interactive)");
                    } elsif ($tool->{requires_serial}) {
                        push @serial_tools, $tool_call;
                        log_debug('WorkflowOrchestrator', "Classified $tool_name as SERIAL");
                    } else {
                        push @parallel_tools, $tool_call;
                        log_debug('WorkflowOrchestrator', "Classified $tool_name as PARALLEL");
                    }
                } else {
                    # Unknown tool - treat as parallel (will fail safely)
                    push @parallel_tools, $tool_call;
                    log_warning('WorkflowOrchestrator', "Unknown tool $tool_name, treating as PARALLEL");
                }
            }
            
            # Separate user_collaboration from other blocking tools
            # user_collaboration MUST execute LAST to ensure:
            # 1. All other tool results are available when showing to user
            # 2. User sees correct state before responding
            # 3. No race conditions between tool execution and user input
            my @user_collaboration_tools = ();
            my @other_blocking_tools = ();
            
            for my $tool_call (@blocking_tools) {
                my $tool_name = $tool_call->{function}->{name} || 'unknown';
                if ($tool_name eq 'user_collaboration') {
                    push @user_collaboration_tools, $tool_call;
                } else {
                    push @other_blocking_tools, $tool_call;
                }
            }
            
            # Combine in execution order: 
            # 1. Other blocking tools (non-user_collaboration interactive tools)
            # 2. Serial tools
            # 3. Parallel tools  
            # 4. user_collaboration tools (ALWAYS LAST)
            my @ordered_tool_calls = (@other_blocking_tools, @serial_tools, @parallel_tools, @user_collaboration_tools);
            
            log_debug('WorkflowOrchestrator', "Execution order: " . scalar(@other_blocking_tools) . " other blocking, " .
                scalar(@serial_tools) . " serial, " .
                scalar(@parallel_tools) . " parallel, " .
                scalar(@user_collaboration_tools) . " user_collaboration (LAST)\n");
            
            # Flush UI streaming buffer BEFORE executing any tools
            # This ensures agent text appears BEFORE tool execution output
            # Part of the handshake mechanism to fix message ordering (Bug 1 & 3)
            if ($self->{ui} && $self->{ui}->can('flush_output_buffer')) {
                log_debug('WorkflowOrchestrator', "Flushing UI buffer before tool execution");
                $self->{ui}->flush_output_buffer();
            }
            # Also flush STDOUT directly as a fallback
            STDOUT->flush() if STDOUT->can('flush');
            $| = 1;
            
            # Set flag to prevent UI pagination from clearing tool headers
            $self->{ui}->{_in_tool_execution} = 1 if $self->{ui};
            
            # Pre-analyze tool calls to know how many of each tool type will execute
            my %tool_call_count;
            foreach my $i (0..$#ordered_tool_calls) {
                my $tool = $ordered_tool_calls[$i]->{function}->{name} || 'unknown';
                $tool_call_count{$tool}++;
            }
            
            # Track if this is the first tool call in the iteration
            my $first_tool_call = 1;
            my $current_tool = '';
            
            # Execute tools in classified order with index tracking
            for my $i (0..$#ordered_tool_calls) {
                # Check for user interrupt between tool executions
                # This allows ESC to abort remaining tools mid-iteration
                if ($self->{_interrupt_pending} || $self->_check_and_handle_interrupt($session, \@messages)) {
                    log_info('WorkflowOrchestrator', "Interrupt detected between tool executions, skipping remaining tools");
                    last;  # Break out of tool execution loop
                }
                
                my $tool_call = $ordered_tool_calls[$i];
                my $tool_name = $tool_call->{function}->{name} || 'unknown';
                my $tool_display_name = uc($tool_name);
                $tool_display_name =~ s/_/ /g;
                
                log_debug('WorkflowOrchestrator', "Executing tool: $tool_name");
                
                # Handle first tool call: ensure proper line separation from agent content
                # The streaming callback prints "CLIO: " immediately on first chunk
                if ($first_tool_call) {
                    # Stop spinner BEFORE any tool output
                    # The spinner runs during AI API calls and must be stopped before
                    # we print tool execution messages to prevent spinner characters
                    # from appearing in the output
                    if ($self->{spinner} && $self->{spinner}->can('stop')) {
                        $self->{spinner}->stop();
                        log_debug('WorkflowOrchestrator', "Stopped spinner before tool output");
                    }
                    
                    my $content = $api_response->{content} // '';
                    log_debug('WorkflowOrchestrator', "First tool call - content: '" . substr($content, 0, 100) . "'");
                    
                    # No need to clear anything - "CLIO: " prefix is only printed when there's actual content
                    # If this is a tool-only response, no prefix was printed, so nothing to clear
                    
                    $first_tool_call = 0;
                }
                
                # Handle tool group transitions (new tool type starting)
                if ($tool_name ne $current_tool) {
                    # Transitioning to a new tool type
                    # Reset system message flag when tool output starts
                    if ($self->{ui}) {
                        $self->{ui}->{_last_was_system_message} = 0;
                    }
                    
                    my $is_first_tool = ($current_tool eq '');
                    $self->{formatter}->display_tool_header($tool_name, $tool_display_name, $is_first_tool);
                    $current_tool = $tool_name;
                }
                
                # Execute tool to get the result
                my $tool_result = $self->_execute_tool($tool_call);
                
                # Extract action_description from tool result
                my $action_detail = '';
                my $result_data;  # Declare here so it's available later
                my $is_error = 0;
                my $enhanced_error_for_ai = '';  # Enhanced error with schema guidance
                if ($tool_result) {
                    $result_data = eval { 
                        # Tool result might be JSON string or already decoded
                        ref($tool_result) eq 'HASH' ? $tool_result : decode_json($tool_result);
                    };
                    if ($result_data && ref($result_data) eq 'HASH') {
                        # Check if this is an error result
                        if (exists $result_data->{success} && !$result_data->{success}) {
                            $is_error = 1;
                            # For errors, create a friendly message using formatter
                            my $error_msg = $result_data->{error} || 'Unknown error';
                            $action_detail = $self->{formatter}->format_error($error_msg);
                            
                            # ENHANCEMENT: Provide schema guidance to help agent recover
                            # Get the tool definition for schema information
                            my $tool_obj = $self->{tool_registry}->get_tool($tool_name);
                            my $tool_def = undef;
                            if ($tool_obj && $tool_obj->can('get_tool_definition')) {
                                $tool_def = $tool_obj->get_tool_definition();
                            }
                            
                            # Get the attempted parameters (what agent tried)
                            my $attempted_params = {};
                            if ($tool_call->{function}->{arguments}) {
                                eval {
                                    $attempted_params = decode_json($tool_call->{function}->{arguments});
                                };
                            }
                            
                            # Use error guidance system to enhance the error message
                            $enhanced_error_for_ai = $self->{error_guidance}->enhance_tool_error(
                                error => $error_msg,
                                tool_name => $tool_name,
                                tool_definition => $tool_def,
                                attempted_params => $attempted_params
                            );
                            
                            log_debug('WorkflowOrchestrator', "Enhanced error for AI: " . substr($enhanced_error_for_ai, 0, 100) . "...");
                        } elsif ($result_data->{action_description}) {
                            $action_detail = $result_data->{action_description};
                        } elsif ($result_data->{metadata} && ref($result_data->{metadata}) eq 'HASH' && 
                                 $result_data->{metadata}->{action_description}) {
                            $action_detail = $result_data->{metadata}->{action_description};
                        }
                    }
                }
                
                # Display action detail if provided
                if ($action_detail) {
                    # Count remaining calls to this tool after current index
                    my $remaining_same_tool = 0;
                    for my $j ($i+1..$#ordered_tool_calls) {
                        if ($ordered_tool_calls[$j]->{function}->{name} eq $tool_name) {
                            $remaining_same_tool++;
                        }
                    }
                    
                    # Check for expanded_content (multi-line detail like agent messages)
                    my $expanded_content;
                    if ($result_data && ref($result_data) eq 'HASH') {
                        $expanded_content = $result_data->{expanded_content};
                    }
                    
                    $self->{formatter}->display_action_detail($action_detail, $is_error, $remaining_same_tool, $expanded_content);
                }
                
                # Extract the actual output for the AI (not the UI metadata)
                # For ERRORS: Use the enhanced error message with schema guidance
                # For SUCCESS: Use the regular output
                my $ai_content = $tool_result;
                if ($is_error && $enhanced_error_for_ai) {
                    # Use enhanced error with schema guidance
                    $ai_content = $enhanced_error_for_ai;
                } elsif ($result_data && ref($result_data) eq 'HASH' && exists $result_data->{output}) {
                    $ai_content = $result_data->{output};
                }
                
                # Track tool calls made
                push @tool_calls_made, {
                    name => $tool_name,
                    arguments => $tool_call->{function}->{arguments},
                    result => $ai_content  # Use the actual output, not the wrapper
                };
                
                # Sanitize tool result content to prevent JSON encoding issues (emojis, etc.)
                my $sanitized_content = sanitize_text($ai_content);
                
                # Content MUST be a string, not a number!
                # GitHub Copilot API requires content to be string type.
                # If tool returns a number (e.g., file size, boolean), stringify it.
                $sanitized_content = "$sanitized_content" if defined $sanitized_content;
                
                # Add tool result to conversation (AI sees the output, not the UI wrapper)
                push @messages, {
                    role => 'tool',
                    tool_call_id => $tool_call->{id},
                    content => $sanitized_content
                };
                
                # Save tool result to session immediately after adding to conversation
                # This ensures that if user presses Ctrl-C before next iteration,
                # the tool execution result is preserved in session history
                #
                # ATOMIC SAVING: On first tool result, also save the assistant message with tool_calls.
                # This ensures they're saved together, preventing orphaned tool_calls on interrupt.
                if ($session && $session->can('add_message')) {
                    eval {
                        # Save the assistant message with tool_calls on FIRST tool result
                        # This makes the assistant + tool results atomic (all or nothing)
                        if ($assistant_msg_pending) {
                            $session->add_message(
                                'assistant',
                                $assistant_msg_pending->{content},
                                { tool_calls => $assistant_msg_pending->{tool_calls} }
                            );
                            log_debug('WorkflowOrchestrator', "Saved assistant message with tool_calls to session (on first tool result)");
                            $assistant_msg_pending = undef;  # Mark as saved
                        }
                        
                        # Now save the tool result
                        $session->add_message(
                            'tool',
                            $sanitized_content,
                            { tool_call_id => $tool_call->{id} }
                        );
                        log_debug('WorkflowOrchestrator', "Saved tool result to session (tool_call_id=" . $tool_call->{id} . ")");
                    };
                    if ($@) {
                        log_warning('WorkflowOrchestrator', "Failed to save tool result: $@");
                    }
                }
                
                log_debug('WorkflowOrchestrator', "Tool result added to conversation (sanitized)");
            }
            
            # Clear flag that prevented UI pagination from clearing tool headers
            $self->{ui}->{_in_tool_execution} = 0 if $self->{ui};
            
            # Capture process stats after tool execution phase
            $self->{process_stats}->capture('after_tools', {
                iteration => $iteration,
                tool_count => scalar(@ordered_tool_calls),
            }) if $self->{process_stats};
            
            # Reset UI streaming state so next iteration shows new CLIO: prefix
            # This ensures proper message formatting after tool execution
            if ($self->{ui} && $self->{ui}->can('reset_streaming_state')) {
                log_debug('WorkflowOrchestrator', "Resetting UI streaming state for next iteration");
                $self->{ui}->reset_streaming_state();
            }
            
            # DO NOT show spinner here - it will be shown at the top of the loop
            # before the next API call. Showing it here causes it to appear while
            # user is typing their response to user_collaboration tool.
            # Instead, set a flag to indicate we need the "CLIO: " prefix on next iteration.
            if ($self->{ui}) {
                # Set flag so on_chunk callback knows to stop spinner on next chunk
                $self->{ui}->{_prepare_for_next_iteration} = 1;
                log_debug('WorkflowOrchestrator', "Set _prepare_for_next_iteration flag for next API call");
            }
            
            # Save session after each iteration to prevent data loss
            # This ensures tool execution history is preserved even if process crashes mid-workflow
            # Performance impact: ~2-5ms per iteration (negligible vs multi-second AI response times)
            # Benefits:
            # - Long workflows: Preserve partial progress on crash/Ctrl-C
            # - Batch operations: Never lose completed items in the batch
            # - Complex tasks: Full history available for debugging/resume
            if ($session && $session->can('save')) {
                eval {
                    $session->save();
                    log_debug('WorkflowOrchestrator', "Session saved after iteration $iteration (preserving tool execution history)");
                };
                if ($@) {
                    log_warning('WorkflowOrchestrator', "Failed to save session after iteration: $@");
                }
            }
            
            # Print newline to separate tool output from next iteration
            # This ensures the spinner (and subsequent "CLIO: " prefix clearing)
            # doesn't accidentally overwrite the last tool action detail
            print "\n";
            STDOUT->flush() if STDOUT->can('flush');
            
            # Loop back - AI will process tool results
            next;
        }
        
        # No tool calls - AI has final answer
        my $elapsed_time = time() - $start_time;
        
        log_debug('WorkflowOrchestrator', "Workflow complete after $iteration iterations (${elapsed_time}s)");
        
        # Capture final process stats
        $self->{process_stats}->capture('session_end', {
            iterations => $iteration,
            elapsed_time => sprintf("%.1f", $elapsed_time),
            tool_calls => scalar(@tool_calls_made),
        }) if $self->{process_stats};
        
        # Clean up response content
        my $final_content = $api_response->{content} || '';
        
        # Remove conversation tags if present
        $final_content =~ s/^\[conversation\]//;
        $final_content =~ s/\[\/conversation\]$//;
        $final_content =~ s/^\s+|\s+$//g;
        
        # Build result hash
        my $result = {
            success => 1,
            content => $final_content,
            iterations => $iteration,
            tool_calls_made => \@tool_calls_made,
            elapsed_time => $elapsed_time,
            # Flag to indicate messages were already saved during workflow execution.
            # This prevents Chat.pm from saving duplicates after the workflow completes.
            # Tool-calling workflows save messages atomically (assistant + tool results together),
            # so Chat.pm should NOT save another assistant message.
            messages_saved_during_workflow => (@tool_calls_made > 0) ? 1 : 0
        };
        
        # NOTE: We previously tracked lastResponseHadTools here, but it's no longer needed.
        # previous_response_id should ALWAYS be included when available (see APIManager.pm).
        # Skipping it for tool calls was causing premium charges.
        
        # Include metrics if streaming was used
        if ($api_response->{metrics}) {
            $result->{metrics} = $api_response->{metrics};
        }
        
        return $result;
    }
    
    # Hit iteration limit
    my $elapsed_time = time() - $start_time;
    
    # Capture final process stats
    $self->{process_stats}->capture('session_end', {
        iterations => $iteration,
        elapsed_time => sprintf("%.1f", $elapsed_time),
        tool_calls => scalar(@tool_calls_made),
        hit_limit => 1,
    }) if $self->{process_stats};
    
    my $error_msg = sprintf(
        "Maximum iterations (%d) reached after %.1fs. " .
        "The task may require more iterations - you can increase the limit in config or try breaking the task into smaller steps.",
        $self->{max_iterations},
        $elapsed_time
    );
    
    log_debug('WorkflowOrchestrator', "$error_msg");
    log_debug('WorkflowOrchestrator', "Tool calls made: " . scalar(@tool_calls_made));
    
    return {
        success => 0,
        error => $error_msg,
        iterations => $iteration,
        tool_calls_made => \@tool_calls_made,
        elapsed_time => $elapsed_time
    };
}

=head2 _execute_tool

Execute a tool call requested by the AI.

Arguments:
- $tool_call: Hashref with tool call details:
  * id: Tool call ID
  * type: 'function'
  * function: { name, arguments }

Returns:
- JSON string with tool execution result

=cut

sub _execute_tool {
    my ($self, $tool_call) = @_;
    
    # Extract tool_call_id for storage
    my $tool_call_id = $tool_call->{id};
    
    # Use ToolExecutor to execute the tool (Task 4 - now implemented!)
    return $self->{tool_executor}->execute_tool($tool_call, $tool_call_id);
}

=head2 _build_system_prompt

Build a comprehensive system prompt that tells the AI about available tools.
Loads from CLIO::Core::PromptManager (user-managed system prompts).
Includes custom instructions from .clio/instructions.md if present.

Returns:
- System prompt string

=cut
sub _build_system_prompt {
    my ($self, $session) = @_;
    
    # Load from PromptManager (includes custom instructions unless skip_custom)
    require CLIO::Core::PromptManager;
    my $pm = CLIO::Core::PromptManager->new(
        debug => $self->{debug},
        skip_custom => $self->{skip_custom},
    );
    
    if ($self->{skip_custom}) {
        log_debug('WorkflowOrchestrator', "Skipping custom instructions (--no-custom-instructions or --incognito)");
    }
    
    log_debug('WorkflowOrchestrator', "Loading system prompt from PromptManager");
    
    my $base_prompt = $pm->get_system_prompt();
    
    # Add current date/time and context management note at the beginning
    my $datetime_section = $self->_generate_datetime_section();
    $base_prompt = $datetime_section . "\n\n" . $base_prompt;
    
    # Dynamically add available tools section from tool registry
    my $tools_section = $self->_generate_tools_section();
    
    # Build LTM context section if session is available AND not skipping LTM
    my $ltm_section = '';
    if ($session && !$self->{skip_ltm}) {
        $ltm_section = $self->_generate_ltm_section($session);
    } elsif ($self->{skip_ltm}) {
        log_debug('WorkflowOrchestrator', "Skipping LTM injection (--no-ltm or --incognito)");
    }
    
    # Insert tools section after "## Core Instructions" or append if not found
    if ($base_prompt =~ /## Core Instructions/) {
        # Insert after Core Instructions section
        $base_prompt =~ s/(## Core Instructions.*?\n)/$1\n$tools_section\n/s;
    } else {
        # Append to end
        $base_prompt .= "\n\n$tools_section";
    }
    
    # Insert LTM section after tools section if available
    if ($ltm_section) {
        $base_prompt .= "\n\n$ltm_section";
        log_debug('WorkflowOrchestrator', "Added LTM context section to prompt");
    }
    
    # Add non-interactive mode instruction if running with --input flag
    if ($self->{non_interactive}) {
        my $non_interactive_section = $self->_generate_non_interactive_section();
        $base_prompt .= "\n\n$non_interactive_section";
        log_debug('WorkflowOrchestrator', "Added non-interactive mode section to prompt");
    }
    
    log_debug('WorkflowOrchestrator', "Added dynamic tools section to prompt");
    
    return $base_prompt;
}

=head2 _generate_tools_section

Generate a dynamic "Available Tools" section based on registered tools.

Returns:
- Markdown text listing all available tools

=cut

sub _generate_tools_section {
    my ($self) = @_;
    
    # Cache the tools section since tool registrations don't change during a session
    return $self->{_tools_section_cache} if $self->{_tools_section_cache};
    
    # Get all registered tool OBJECTS (not just names)
    my $tools = $self->{tool_registry}->get_all_tools();
    my $tool_count = scalar(@$tools);
    
    log_debug('WorkflowOrchestrator', "Generating tools section for $tool_count tools");
    
    my $section = "## Available Tools - READ THIS CAREFULLY\n\n";
    $section .= "You have access to exactly $tool_count function calling tools. ";
    $section .= "When users ask \"what tools do you have?\", list ALL of these by name:\n\n";
    
    my $num = 1;
    for my $tool (@$tools) {
        # Tools are blessed objects with hash internals
        my $name = $tool->{name};
        my $description = $tool->{description};
        
        # Extract first line of description (summary)
        my ($summary) = split /\n/, $description;
        $summary =~ s/^\s+|\s+$//g;  # Trim whitespace
        
        # Count operations if description has operation list
        my $op_count = '';
        if ($description =~ /===\s+\w+\s+\((\d+)\s+operations?\)/) {
            my @ops;
            while ($description =~ /===\s+\w+\s+\((\d+)\s+operations?\)/g) {
                push @ops, $1;
            }
            my $total = 0;
            $total += $_ for @ops;
            $op_count = " ($total operations)" if $total > 0;
        }
        
        $section .= "$num. **$name** - $summary$op_count\n";
        $num++;
    }
    
    $section .= "\n**Important:** You HAVE all $tool_count of these tools. ";
    $section .= "Do NOT say you don't have a tool that's on this list!\n\n";
    
    # Add operation-based tool explanation
    $section .= "## **HOW TO USE OPERATION-BASED TOOLS**\n\n";
    $section .= "Most tools use an **operation-based pattern**: one tool with multiple operations.\n\n";
    $section .= "**Example:** `file_operations` has 17 operations (read_file, write_file, grep_search, etc.)\n\n";
    $section .= "**CORRECT way to call:**\n";
    $section .= "```\n";
    $section .= "file_operations(\n";
    $section .= "  operation: \"read_file\",\n";
    $section .= "  path: \"lib/Example.pm\"\n";
    $section .= ")\n";
    $section .= "```\n\n";
    $section .= "**The `operation` parameter is ALWAYS REQUIRED.** Every tool call must specify which operation to perform.\n\n";
    $section .= "**Each operation needs different parameters** - check the tool's schema to see what parameters each operation requires.\n\n";
    
    # Add JSON formatting instruction with HIGH priority to prevent malformed JSON
    $section .= "## **CRITICAL - JSON FORMAT REQUIREMENT**\n\n";
    $section .= "When calling tools, you MUST generate valid JSON. This is NON-NEGOTIABLE.\n\n";
    $section .= "**FORBIDDEN:**  `{\"offset\":,\"length\":8192}`  ← Missing value = PARSER CRASH\n\n";
    $section .= "**CORRECT Options:**\n";
    $section .= "1. Omit optional param: `{\"operation\":\"read_tool_result\",\"length\":8192}`\n";
    $section .= "2. Include with value: `{\"operation\":\"read_tool_result\",\"offset\":0,\"length\":8192}`\n\n";
    $section .= "**Rule:** EVERY parameter key MUST have a value. No exceptions.\n\n";
    $section .= "**DECIMAL NUMBERS:** Always include leading zero: `0.1` not `.1`, `0.05` not `.05`\n";
    
    # Add MCP tools section if any are connected
    if ($self->{mcp_manager}) {
        my $mcp_tools = $self->{mcp_manager}->all_tools();
        if ($mcp_tools && @$mcp_tools) {
            $section .= "\n\n## MCP (Model Context Protocol) Tools\n\n";
            $section .= "The following tools are provided by connected MCP servers. ";
            $section .= "Call them like any other tool using their full name.\n\n";
            
            my $current_server = '';
            for my $entry (@$mcp_tools) {
                if ($entry->{server} ne $current_server) {
                    $current_server = $entry->{server};
                    $section .= "### MCP Server: $current_server\n\n";
                }
                my $name = "mcp_$entry->{name}";
                my $desc = $entry->{tool}{description} || 'No description';
                $section .= "- **$name** - $desc\n";
            }
            $section .= "\n";
        }
    }
    
    # Cache the generated section (MCP tools are included)
    $self->{_tools_section_cache} = $section;
    
    return $section;
}

=head2 _generate_ltm_section

Generate a dynamic "Long-Term Memory" section based on relevant patterns from LTM.

Arguments:
- $session: Session object containing LTM reference

Returns:
- Markdown text with relevant LTM patterns (empty string if no patterns)

=cut

sub _generate_datetime_section {
    my ($self) = @_;
    
    # Get current date and time in multiple useful formats
    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time);
    $year += 1900;
    $mon += 1;
    
    my $datetime_iso = sprintf("%04d-%02d-%02d %02d:%02d:%02d", $year, $mon, $mday, $hour, $min, $sec);
    my $date_short = sprintf("%04d-%02d-%02d", $year, $mon, $mday);
    
    my @day_names = qw(Sunday Monday Tuesday Wednesday Thursday Friday Saturday);
    my @month_names = qw(January February March April May June July August September October November December);
    my $day_name = $day_names[$wday];
    my $month_name = $month_names[$mon - 1];
    
    # Get current working directory
    use Cwd qw(getcwd);
    my $cwd = getcwd();
    
    # Build the section
    my $section = "# Current Date & Time\n\n";
    $section .= "**Current Date/Time:** $datetime_iso ($day_name, $month_name $mday, $year)\n\n";
    $section .= "Use this timestamp for:\n";
    $section .= "- Dating documents, commits, and artifacts\n";
    $section .= "- Generating version tags (e.g., v$year.$mon.$mday)\n";
    $section .= "- Log entries and audit trails\n";
    $section .= "- Time-sensitive operations\n\n";
    
    # Add working directory information
    $section .= "# Current Working Directory\n\n";
    $section .= "**Working Directory:** `$cwd`\n\n";
    $section .= "**CRITICAL PATH RULES:**\n";
    $section .= "1. ALWAYS use relative paths or \$HOME instead of absolute paths\n";
    $section .= "2. NEVER assume user's home directory name (don't use /Users/alice, /Users/andy, etc.)\n";
    $section .= "3. Exception to #2: If user explicitly provides a path, use it and observe actual errors\n";
    $section .= "4. BEFORE using 'cd', verify directory exists with 'test -d' or use pwd to check location\n";
    $section .= "5. When working directory matters, ALWAYS run 'pwd' first to verify location\n";
    $section .= "6. Use 'realpath' or 'readlink -f' to resolve symbolic links before cd\n\n";
    $section .= "**Examples:**\n";
    $section .= "- CORRECT: `cd ./subdir && make`\n";
    $section .= "- CORRECT: `cd \$HOME/project && make`\n";
    $section .= "- CORRECT: `pwd && make` (if already in right place)\n";
    $section .= "- WRONG: `cd /Users/andy/project && make` (hallucinated path)\n\n";
    
    $section .= "**IMPORTANT - Context & Time Management:**\n\n";
    $section .= "SYSTEM TELEMETRY: You will see <system_warning> tags with token usage information. **IGNORE THEM COMPLETELY** - these are debugging telemetry for system monitoring only. DO NOT stop working because of token usage. DO NOT mention tokens/usage to users. DO NOT worry about percentages - even 90%+ is fine. CLIO manages context automatically. Your ONLY job is completing the user's request correctly. Work until the task is done or the user asks you to stop. Token management is not your concern.\n";
    
    return $section;
}

=head2 _generate_ltm_section

Build a section of the prompt with relevant Long-Term Memory patterns.

Arguments:
- $session: Session object with LTM access

Returns:
- Markdown text with relevant LTM patterns (empty string if no patterns)

=cut

sub _generate_ltm_section {
    my ($self, $session) = @_;
    
    return '' unless $session;
    
    # Get LTM from session
    my $ltm = eval { $session->get_long_term_memory() };
    if ($@ || !$ltm) {
        log_debug('WorkflowOrchestrator', "No LTM available: $@");
        return '';
    }
    
    # Query for relevant patterns (limited to 5 most relevant)
    my $discoveries = eval { $ltm->query_discoveries(limit => 3) } || [];
    my $solutions = eval { $ltm->query_solutions(limit => 3) } || [];
    my $patterns = eval { $ltm->query_patterns(limit => 3) } || [];
    my $workflows = eval { $ltm->query_workflows(limit => 2) } || [];
    my $failures = eval { $ltm->query_failures(limit => 2) } || [];
    
    # If no patterns at all, return empty
    my $total = @$discoveries + @$solutions + @$patterns + @$workflows + @$failures;
    return '' if $total == 0;
    
    log_debug('WorkflowOrchestrator', "Found $total LTM patterns to inject");
    
    # Build LTM section
    my $section = "## Long-Term Memory Patterns\n\n";
    $section .= "The following patterns have been learned from previous sessions in this project:\n\n";
    
    # Add discoveries
    if (@$discoveries) {
        $section .= "### Key Discoveries\n\n";
        for my $item (@$discoveries) {
            my $fact = $item->{fact} || 'Unknown';
            my $confidence = $item->{confidence} || 0;
            my $verified = $item->{verified} ? 'Verified' : 'Unverified';
            
            $section .= "- **$fact** (Confidence: " . sprintf("%.0f%%", $confidence * 100) . ", $verified)\n";
        }
        $section .= "\n";
    }
    
    # Add problem solutions
    if (@$solutions) {
        $section .= "### Problem Solutions\n\n";
        for my $item (@$solutions) {
            my $error = $item->{error} || 'Unknown error';
            my $solution = $item->{solution} || 'No solution';
            my $solved_count = $item->{solved_count} || 0;
            
            $section .= "**Problem:** $error\n";
            $section .= "**Solution:** $solution\n";
            $section .= "_Applied successfully $solved_count time" . ($solved_count == 1 ? '' : 's') . "_\n\n";
        }
    }
    
    # Add code patterns
    if (@$patterns) {
        $section .= "### Code Patterns\n\n";
        for my $item (@$patterns) {
            my $pattern = $item->{pattern} || 'Unknown pattern';
            my $confidence = $item->{confidence} || 0;
            my $examples = $item->{examples} || [];
            
            $section .= "- **$pattern** (Confidence: " . sprintf("%.0f%%", $confidence * 100) . ")\n";
            if (@$examples) {
                $section .= "  Examples: " . join(", ", @$examples) . "\n";
            }
        }
        $section .= "\n";
    }
    
    # Add workflows
    if (@$workflows) {
        $section .= "### Successful Workflows\n\n";
        for my $item (@$workflows) {
            my $sequence = $item->{sequence} || [];
            my $success_rate = $item->{success_rate} || 0;
            my $count = $item->{count} || 0;
            
            if (@$sequence) {
                $section .= "- " . join(" → ", @$sequence) . "\n";
                $section .= "  _Success rate: " . sprintf("%.0f%%", $success_rate * 100) . " ($count attempts)_\n";
            }
        }
        $section .= "\n";
    }
    
    # Add failures (antipatterns)
    if (@$failures) {
        $section .= "### Known Failures (Avoid These)\n\n";
        for my $item (@$failures) {
            my $what_broke = $item->{what_broke} || 'Unknown failure';
            my $impact = $item->{impact} || 'Unknown impact';
            my $prevention = $item->{prevention} || 'No prevention documented';
            
            $section .= "**What broke:** $what_broke\n";
            $section .= "**Impact:** $impact\n";
            $section .= "**Prevention:** $prevention\n\n";
        }
    }
    
    $section .= "_These patterns are project-specific and should inform your approach to similar tasks._\n";
    
    return $section;
}

=head2 _generate_non_interactive_section

Generate instruction text for non-interactive mode (--input flag).
Tells the agent NOT to use user_collaboration since the user is not present.

Returns:
- Markdown text with non-interactive mode instructions

=cut

sub _generate_non_interactive_section {
    my ($self) = @_;
    
    return q{## Non-Interactive Mode (CRITICAL)

**You are running in non-interactive mode (--input flag).**

This means the user is NOT present to respond to questions. The command will exit after your response.

**CRITICAL RESTRICTIONS:**

1. **DO NOT use user_collaboration tool** - There is no user to respond. Any call to user_collaboration will fail or hang.

2. **DO NOT ask questions** - Complete the task to the best of your ability. If you need information you don't have, explain what you would need and proceed with reasonable assumptions.

3. **DO NOT checkpoint or wait for approval** - Make autonomous decisions. Act on what was asked.

4. **DO complete the task in one response** - You get one chance to respond. Make it count.

**What TO do:**

- Execute the task directly
- Use all other tools normally (file_operations, version_control, terminal_operations, etc.)
- Make reasonable assumptions when details are missing
- Complete the work and report results
- If you truly cannot proceed, explain why and what's needed

**Example - User asks: "Create a file test.txt with hello world"**

WRONG: Call user_collaboration asking "Should I proceed?"
RIGHT: Call file_operations to create the file, then report success.

**Remember: Work autonomously. The user will see your response after the fact, not during execution.**
};
}

=head2 _trim_conversation_for_api

Aggressively trim conversation history to fit within API token budget.

Called BEFORE first API call to prevent token limit errors on initial request.
Uses dynamic thresholds based on model's actual context window.

Strategy:
1. Keep all system messages (always at start)
2. Keep last N recent messages (preserve recent context)
3. Keep high-importance messages from middle
4. Remove low-importance messages to stay under safe limit

Arguments:
- $history: Arrayref of message objects from session
- $system_prompt: The system prompt text (to estimate its token cost)
- $opts{model_context_window}: Model's max context in tokens (default: 128000)
- $opts{max_response_tokens}: Model's max response in tokens (default: 16000)

Returns:
- Trimmed history (or original if already small)

=cut

sub _trim_conversation_for_api {
    my ($self, $history, $system_prompt, %opts) = @_;
    
    return $history unless $history && @$history;
    
    use CLIO::Memory::TokenEstimator;
    
    # Get model capabilities from options or use defaults
    my $model_context = $opts{model_context_window} // 128000;
    my $max_response = $opts{max_response_tokens} // 16000;
    
    # Calculate dynamic safe threshold based on model's context window
    # Use percentages for model-agnostic calculation:
    # - Start trimming at 58% of max context (leaves 42% safety margin)
    # - This accounts for max response (typically 12-16% of context)
    # - And provides buffer for system prompt + estimation errors
    my $safe_threshold_percent = 0.58;  # 58% of model's max context
    my $safe_threshold = int($model_context * $safe_threshold_percent);
    
    # Estimate current size
    my $system_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($system_prompt);
    my $history_tokens = CLIO::Memory::TokenEstimator::estimate_messages_tokens($history);
    my $current_total = $system_tokens + $history_tokens + 500;  # +500 for padding/estimation error
    
    if ($current_total <= $safe_threshold) {
        if ($self->{debug}) {
            log_debug('WorkflowOrchestrator::_trim_conversation_for_api', "History OK: $history_tokens tokens (total: $current_total of $safe_threshold safe limit, model context: $model_context)");
        }
        return $history;  # No trimming needed
    }
    
    if ($self->{debug}) {
        log_warning('WorkflowOrchestrator::_trim_conversation_for_api', "History exceeds safe limit: $current_total tokens (safe: $safe_threshold of $model_context total). Trimming...");
        log_debug('WorkflowOrchestrator', "Model context window: $model_context tokens");
        log_debug('WorkflowOrchestrator', "Max response: $max_response tokens");
        log_debug('WorkflowOrchestrator', "Safe trim threshold: " . int($safe_threshold_percent * 100) . "% = $safe_threshold tokens");
        log_debug('WorkflowOrchestrator', "System prompt: $system_tokens tokens");
        log_debug('WorkflowOrchestrator', "History: $history_tokens tokens");
        log_debug('WorkflowOrchestrator', "Messages in history: " . scalar(@$history) . "");
    }
    
    my @messages = @$history;
    my @trimmed = ();
    
    # Strategy: Preserve critical messages FIRST, then fill with recent
    # 1. ALWAYS preserve first user message (original task - importance >= 10.0)
    # 2. Keep recent messages for context continuity
    # 3. Fill remaining budget with high-importance older messages
    
    # Calculate target based on available space (safe threshold - system prompt)
    my $target_tokens = int(($safe_threshold - $system_tokens) * 0.9);  # 90% of remaining space
    
    # Ensure target_tokens is reasonable (minimum 5000 tokens for conversation)
    if ($target_tokens < 5000) {
        $target_tokens = 5000;
        log_warning('WorkflowOrchestrator::_trim_conversation_for_api', "Target tokens very low ($target_tokens), system prompt may be too large");
    }
    
    my $keep_recent = 10;      # Always keep at least last 10 messages
    my $current_count = scalar(@messages);
    
    # Step 1: Extract and preserve the first user message (critical for context)
    # This MUST be preserved regardless of token budget - without it, models lose the original task
    my $first_user_msg = undef;
    my $first_user_tokens = 0;
    my $first_user_idx = -1;
    
    for my $i (0 .. $#messages) {
        my $msg = $messages[$i];
        if ($msg->{role} && $msg->{role} eq 'user') {
            # Check if this is the critical first user message (importance >= 10.0)
            if (($msg->{_importance} // 0) >= 10.0) {
                $first_user_msg = $msg;
                $first_user_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($msg->{content} // '');
                $first_user_idx = $i;
                log_debug('WorkflowOrchestrator', "Preserving first user message (importance=" . ($msg->{_importance} // 0) . ", tokens=$first_user_tokens)");
            }
            last;  # Only looking for FIRST user message
        }
    }
    
    # Reserve budget for first user message
    my $reserved_tokens = $first_user_tokens;
    my $available_tokens = $target_tokens - $reserved_tokens;
    
    # If we have more messages than we want to keep
    if ($current_count > $keep_recent) {
        # Get recent messages (last N), excluding the first user message if it's in this range
        my @recent = ();
        for my $i (($current_count - $keep_recent) .. ($current_count - 1)) {
            next if $i == $first_user_idx;  # Skip first user message (handled separately)
            push @recent, $messages[$i] if $i >= 0;
        }
        
        # Get older messages (everything before recent), excluding first user message
        my @older = ();
        for my $i (0 .. ($current_count - $keep_recent - 1)) {
            next if $i == $first_user_idx;  # Skip first user message (handled separately)
            push @older, $messages[$i] if $i >= 0;
        }
        
        # Sort older messages by importance (highest first)
        my @sorted_older = sort {
            ($b->{_importance} // 0) <=> ($a->{_importance} // 0)
        } @older;
        
        # Start with recent messages (but respect token budget)
        my $trimmed_tokens = 0;
        my @kept_recent = ();
        
        # Add recent messages while respecting budget
        for my $msg (@recent) {
            my $msg_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($msg->{content} // '');
            if ($trimmed_tokens + $msg_tokens <= $available_tokens) {
                push @kept_recent, $msg;
                $trimmed_tokens += $msg_tokens;
            }
        }
        
        # Add older important messages until we reach target or run out
        my @kept_older = ();
        for my $msg (@sorted_older) {
            my $msg_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($msg->{content} // '');
            if ($trimmed_tokens + $msg_tokens <= $available_tokens) {
                push @kept_older, $msg;
                $trimmed_tokens += $msg_tokens;
            }
        }
        
        # Build trimmed list: first_user + older (in order) + recent
        @trimmed = ();
        push @trimmed, $first_user_msg if $first_user_msg;
        
        # Sort kept_older by original position
        @kept_older = sort { 
            my $idx_a = 0;
            my $idx_b = 0;
            for my $i (0 .. $#messages) {
                $idx_a = $i if $messages[$i] == $a;
                $idx_b = $i if $messages[$i] == $b;
            }
            $idx_a <=> $idx_b
        } @kept_older;
        
        push @trimmed, @kept_older;
        push @trimmed, @kept_recent;
        
        my $final_tokens = $reserved_tokens + $trimmed_tokens;
        if ($self->{debug}) {
            log_debug('WorkflowOrchestrator', "Trimmed: " . scalar(@messages) . " -> " . scalar(@trimmed) . " messages");
            log_debug('WorkflowOrchestrator', "First user preserved: " . ($first_user_msg ? 'YES' : 'NO') .
                         ($first_user_msg ? " ($first_user_tokens tokens)" : ""));
            log_debug('WorkflowOrchestrator', "Token reduction: $history_tokens -> $final_tokens tokens");
            log_debug('WorkflowOrchestrator', "Final total with system: " . ($system_tokens + $final_tokens) . " of $safe_threshold safe limit");
        }
        
        return \@trimmed;
    }
    
    # If we have few messages, return as-is (shouldn't happen at this point)
    return $history;
}

=head2 _load_conversation_history

Load conversation history from session object.

Arguments:
- $session: Session object (may be undef)

Returns:
- Arrayref of message objects (may be empty)

=cut

sub _load_conversation_history {
    my ($self, $session) = @_;
    
    return [] unless $session;
    
    # Try to get conversation history from session
    my $history = [];
    
    if ($session && ref($session) eq 'HASH') {
        if ($session->{conversation_history} && 
            ref($session->{conversation_history}) eq 'ARRAY') {
            $history = $session->{conversation_history};
        }
    } elsif ($session && $session->can('get_conversation_history')) {
        $history = $session->get_conversation_history() || [];
    }
    
    # Do NOT truncate history here!
    # Session::State handles context management with YaRN and importance-based trimming.
    # Arbitrarily limiting to N messages destroys context continuity and causes history loss.
    # The session provides exactly what should be included based on token budgets and importance.
    #
    # Previous buggy code (REMOVED):
    # if (@$history > 10) {
    #     my $start_idx = @$history - 10;
    #     $history = [@{$history}[$start_idx .. $#{$history}]];
    # }
    
    log_debug('WorkflowOrchestrator', "Raw history from session has " . scalar(@$history) . " messages");
    
    # DEBUG: Dump first assistant message (when debug enabled)
    if ($self->{debug}) {
        for my $i (0 .. $#{$history}) {
            my $msg = $history->[$i];
            if ($msg->{role} eq 'assistant') {
                use Data::Dumper;
                log_debug('WorkflowOrchestrator', "First assistant message structure:");
                log_debug('WorkflowOrchestrator', Dumper($msg));
                last;
            }
        }
    }
    
    log_debug('WorkflowOrchestrator', "Loaded " . scalar(@$history) . " messages from session");
    
    # Validate and filter messages
    # Skip system messages from history - we always build fresh with dynamic tools
    my @valid_messages = ();
    
    log_debug('WorkflowOrchestrator', "_load_conversation_history: Processing " . scalar(@$history) . " messages");
    
    for my $msg (@$history) {
        next unless $msg && ref($msg) eq 'HASH';
        next unless $msg->{role};
        
        if ($self->{debug}) {
            my $has_tool_calls = exists $msg->{tool_calls} ? 'YES' : 'NO';
            my $tc_count = $msg->{tool_calls} ? scalar(@{$msg->{tool_calls}}) : 0;
            log_debug('WorkflowOrchestrator', "  Message role=" . $msg->{role} .
                ", has_tool_calls=$has_tool_calls, count=$tc_count");
        }
        
        # Skip system messages - we build fresh system prompt in process_input
        next if $msg->{role} eq 'system';
        
        # Skip tool result messages without tool_call_id
        # GitHub Copilot API REQUIRES tool_call_id for role=tool messages
        # If missing, API returns "tool call must have a tool call ID" error
        if ($msg->{role} eq 'tool' && !$msg->{tool_call_id}) {
            if ($self->{debug}) {
                log_warning('WorkflowOrchestrator', "Skipping tool message without tool_call_id " . "(content: " . substr($msg->{content} // '', 0, 50) . "...)");
            }
            next;
        }
        
        # Preserve message structure for proper API correlation
        # The API requires:
        # 1. Assistant messages with tool_calls must be followed by tool messages
        # 2. Each tool message's tool_call_id must match an id in the preceding tool_calls array
        # 
        # We MUST preserve tool_calls on assistant messages - they're needed for correlation.
        # We also preserve tool_call_id on tool messages.
        if ($msg->{role} eq 'tool') {
            # Tool messages MUST preserve tool_call_id for the API
            push @valid_messages, {
                role => $msg->{role},
                content => $msg->{content} || '',
                tool_call_id => $msg->{tool_call_id}
            };
            log_debug('WorkflowOrchestrator', "Preserving tool message with tool_call_id=$msg->{tool_call_id}");
        } elsif ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            # Assistant message with tool_calls - KEEP the tool_calls for API correlation
            log_debug('WorkflowOrchestrator', "Preserving assistant message with " . scalar(@{$msg->{tool_calls}}) . " tool_calls for API correlation");
            
            push @valid_messages, {
                role => $msg->{role},
                content => $msg->{content} || '',
                tool_calls => $msg->{tool_calls}
            };
        } else {
            # Normal message without tool_calls
            # Skip messages without content (but tool messages are OK even with empty content)
            next unless $msg->{content} || $msg->{role} eq 'tool';
            
            push @valid_messages, {
                role => $msg->{role},
                content => $msg->{content} || ''
            };
        }
    }
    
    # Validate that assistant messages with tool_calls have corresponding tool_results
    # This prevents "tool_use ids were found without tool result blocks" API errors
    # caused by orphaned tool calls in loaded history (Bug #1)
    my @validated_messages = ();
    my $idx = 0;
    while ($idx < @valid_messages) {
        my $msg = $valid_messages[$idx];
        
        if ($msg->{role} eq "assistant" && $msg->{tool_calls} && @{$msg->{tool_calls}}) {
            # This assistant message has tool calls - verify results are present
            my %expected_tool_ids = ();
            for my $tc (@{$msg->{tool_calls}}) {
                $expected_tool_ids{$tc->{id}} = 1 if $tc->{id};
            }
            
            # Collect all immediately following tool messages
            my %found_tool_ids = ();
            my $next_idx = $idx + 1;
            while ($next_idx < @valid_messages && $valid_messages[$next_idx]->{role} eq "tool") {
                if ($valid_messages[$next_idx]->{tool_call_id}) {
                    $found_tool_ids{$valid_messages[$next_idx]->{tool_call_id}} = 1;
                }
                $next_idx++;
            }
            
            # Check if all expected tool results are present
            my $missing_results = 0;
            for my $id (keys %expected_tool_ids) {
                unless ($found_tool_ids{$id}) {
                    # This is normal after context trimming - log at DEBUG level only
                    log_debug('WorkflowOrchestrator', "Orphaned tool_call detected: $id (missing tool_result - normal after context trim)");
                    $missing_results++;
                }
            }
            
            if ($missing_results > 0) {
                # Remove tool_calls to prevent API error "tool_use ids were found without tool_result blocks"
                log_debug('WorkflowOrchestrator', "Removing tool_calls from loaded assistant message ($missing_results missing results - normal after context trim)");
                
                my $fixed_msg = {
                    role => $msg->{role},
                    content => $msg->{content}
                };
                push @validated_messages, $fixed_msg;
            } else {
                # All tool results present, keep as-is
                push @validated_messages, $msg;
            }
        } else {
            # Not an assistant message with tool_calls, keep as-is
            push @validated_messages, $msg;
        }
        
        $idx++;
    }
    
    # PASS 2: Check for orphaned tool_results (tool_results without matching tool_calls)
    # This catches the reverse case: "unexpected tool_use_id found in tool_result blocks"
    # First, collect all tool_call IDs from assistant messages
    my %all_tool_call_ids = ();
    for my $msg (@validated_messages) {
        if ($msg->{role} && $msg->{role} eq 'assistant' && 
            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                $all_tool_call_ids{$tc->{id}} = 1 if $tc->{id};
            }
        }
    }
    
    # Now filter out any tool messages whose tool_call_id doesn't exist
    my @final_messages = ();
    for my $msg (@validated_messages) {
        if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
            unless ($all_tool_call_ids{$msg->{tool_call_id}}) {
                log_warning('WorkflowOrchestrator', "Removing orphaned tool_result: $msg->{tool_call_id} (no matching tool_call)");
                next;  # Skip this orphaned tool_result
            }
        }
        push @final_messages, $msg;
    }
    
    return \@final_messages;
}

=head2 _inject_context_files

Inject context files from session into messages array.

Called after system prompt but before conversation history.
Context files are user-added files via /context add command.

Arguments:
- $session: Session object (CLIO::Session::State)
- $messages: Reference to messages array

=cut

sub _inject_context_files {
    my ($self, $session, $messages) = @_;
    
    return unless $session && $session->{context_files};
    
    my @context_files = @{$session->{context_files}};
    return unless @context_files;
    
    log_debug('WorkflowOrchestrator', "Injecting " . scalar(@context_files) . " context file(s)");
    
    my $context_content = "";
    my $total_tokens = 0;
    
    for my $file (@context_files) {
        unless (-f $file) {
            log_warning('WorkflowOrchestrator', "Context file not found: $file");
            next;
        }
        
        # Read file content
        eval {
            open my $fh, '<', $file or die "Cannot read file: $!";
            my $content = do { local $/; <$fh> };
            close $fh;
            
            # Estimate tokens (chars / 4)
            my $tokens = int(length($content) / 4);
            $total_tokens += $tokens;
            
            # Add to context content with clear markers
            $context_content .= "\n<context_file path=\"$file\" tokens=\"~$tokens\">\n";
            $context_content .= $content;
            $context_content .= "\n</context_file>\n";
            
            log_debug('WorkflowOrchestrator', "Injected context file: $file (~$tokens tokens)");
        };
        
        if ($@) {
            log_debug('WorkflowOrchestrator', "Failed to read context file $file (skipping): $@");
        }
    }
    
    if ($context_content) {
        # Inject as a user message immediately after system prompt
        # This makes the context available to the AI without modifying system prompt
        my $context_message = {
            role => 'user',
            content => "[CONTEXT FILES]\n" .
                       "The following files were added to context by the user.\n" .
                       "Reference these files when relevant to the conversation.\n" .
                       "Total estimated tokens: ~$total_tokens\n" .
                       $context_content
        };
        
        push @$messages, $context_message;
        
        log_debug('WorkflowOrchestrator', "Context injection complete (~$total_tokens tokens)");
    }
}

=head2 _generate_tool_call_id

Generate a unique ID for a tool call.

OpenAI uses IDs like "call_abc123xyz789". We'll generate similar.

Returns:
- String tool call ID

=cut

sub _generate_tool_call_id {
    my ($self) = @_;
    
    # Generate unique ID using MD5 hash of timestamp + random number
    my $unique = time() . rand();
    my $hash = md5_hex($unique);
    
    # Format as OpenAI-style ID
    return 'call_' . substr($hash, 0, 24);
}

=head2 _repair_tool_call_json

Attempt to repair common JSON errors in tool call arguments.

Common issues:
- Missing values: {"offset":,"length":8192}
- Trailing commas: {"offset":0,"length":8192}
- Unescaped quotes: {"text":"He said "hello""}
- Decimals without leading zero: {"progress":.1} (JavaScript-style)

Arguments:
- $json_str: Potentially malformed JSON string

Returns:
- Repaired JSON string if successful, undef if repair failed

=cut

sub _repair_tool_call_json {
    my ($self, $json_str) = @_;
    
    return undef unless defined $json_str;
    
    # Use JSONRepair utility if available
    eval {
        require CLIO::Util::JSONRepair;
        my $repaired = CLIO::Util::JSONRepair::repair_malformed_json($json_str, $self->{debug});
        return $repaired if $repaired;
    };
    if ($@) {
        log_debug('WorkflowOrchestrator', "JSONRepair module not available: $@");
    }
    
    # Fallback: Apply common repair patterns manually
    my $repaired = $json_str;
    
    # Fix 1: Missing values in key-value pairs (e.g., "offset":, -> "offset":null,)
    # This is the most common error from the logs
    $repaired =~ s/:\s*,/: null,/g;          # "key":, -> "key": null,
    $repaired =~ s/:\s*\}/: null}/g;          # "key":} -> "key": null}
    $repaired =~ s/:\s*\]/: null]/g;          # "key":] -> "key": null]
    
    # Fix 2: Decimals without leading zero (JavaScript-style decimals are invalid JSON)
    # Examples: "progress":.1 -> "progress":0.1, "progress":.05 -> "progress":0.05
    #           "value":-.5 -> "value":-0.5 (negative decimals)
    $repaired =~ s/:(\s*)\.(\d)/:${1}0.$2/g;
    $repaired =~ s/:(\s*)-\.(\d)/:${1}-0.$2/g;
    
    # Fix 3: Trailing commas before closing braces/brackets
    $repaired =~ s/,\s*\}/}/g;                 # {...} -> {...}
    $repaired =~ s/,\s*\]/]/g;                 # [...] -> [...]
    
    # Fix 3: Unescaped quotes in string values (simple cases only)
    # This is more complex and risky - only fix obvious cases
    # More sophisticated quote escaping is possible but risks over-correction
    
    # Validate that repair worked
    eval {
        use CLIO::Util::JSON qw(decode_json);
        decode_json($repaired);
    };
    
    if ($@) {
        # Repair failed
        log_debug('WorkflowOrchestrator', "JSON repair attempt failed: $@");
        return undef;
    }
    
    # Repair successful
    return $repaired;
}

=head2 _enforce_message_alternation

Enforce strict user/assistant alternation for Claude-compatible models.

Claude (via GitHub Copilot) requires alternating user/assistant roles.
This function:
1. Converts tool messages to user messages (Claude doesn't support role=tool)
2. Merges consecutive same-role messages into one
3. Ensures strict user→assistant→user→assistant pattern

Based on SAM MLXProvider.swift:399-445 (alternation enforcement).

Arguments:
- $messages: Reference to messages array

Returns:
- Reference to alternation-enforced messages array

=cut

sub _enforce_message_alternation {
    my ($self, $messages) = @_;
    
    return $messages unless $messages && @$messages;
    
    log_debug('WorkflowOrchestrator', "Enforcing message alternation (Claude compatibility)");
    
    my @alternating = ();
    my $last_role = undef;
    my $accumulated_content = '';
    my $accumulated_tool_calls = [];
    my $accumulated_tool_call_id = undef;
    
    # Determine current provider (some providers like Claude don't support role=tool)
    my $provider = $self->{api_manager}->get_current_provider() || 'github_copilot';
    my $provider_supports_tool_role = ($provider =~ /github|openai/i);
    
    for my $msg (@$messages) {
        my $role = $msg->{role};
        
        # Convert tool messages to user messages ONLY for providers that don't support role=tool
        # Claude doesn't support role=tool, but GitHub Copilot and OpenAI DO support it
        # Tool results must be role=tool for GitHub Copilot, or API returns 400 error
        if ($role eq 'tool' && !$provider_supports_tool_role) {
            $role = 'user';
            
            # Format tool result for clarity
            my $tool_content = $msg->{content} || '{}';
            my $tool_id = $msg->{tool_call_id} || 'unknown';
            
            $msg = {
                role => 'user',
                content => "Tool Result (ID: $tool_id):\n$tool_content"
            };
            
            log_debug('WorkflowOrchestrator', "Converted tool message to user message");
        }
        
        # Check if same role as previous (needs merging)
        # Do NOT merge tool messages - each has unique tool_call_id
        if (defined $last_role && $role eq $last_role && $role ne 'tool') {
            # Same role (and not tool) - accumulate content
            if ($msg->{content} && length($msg->{content}) > 0) {
                $accumulated_content .= "\n\n" if length($accumulated_content) > 0;
                $accumulated_content .= $msg->{content};
            }
            
            # Accumulate tool_calls if present
            if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                push @$accumulated_tool_calls, @{$msg->{tool_calls}};
            }
            
            log_debug('WorkflowOrchestrator', "Merged consecutive $role message");
        } else {
            # Different role - flush accumulated message if any
            if (defined $last_role) {
                my $flushed = {
                    role => $last_role,
                    content => $accumulated_content
                };
                
                # Add tool_calls if accumulated
                if (@$accumulated_tool_calls) {
                    $flushed->{tool_calls} = $accumulated_tool_calls;
                }
                
                # Add tool_call_id for tool messages (required by GitHub Copilot API)
                if ($last_role eq 'tool' && defined $accumulated_tool_call_id) {
                    $flushed->{tool_call_id} = $accumulated_tool_call_id;
                }
                
                push @alternating, $flushed;
            }
            
            # Start new accumulation
            $last_role = $role;
            $accumulated_content = $msg->{content} || '';
            $accumulated_tool_calls = $msg->{tool_calls} ? [@{$msg->{tool_calls}}] : [];
            # Preserve tool_call_id for tool messages (required by GitHub Copilot API)
            $accumulated_tool_call_id = $msg->{tool_call_id};
        }
    }
    
    # Flush final accumulated message
    if (defined $last_role) {
        my $flushed = {
            role => $last_role,
            content => $accumulated_content
        };
        
        if (@$accumulated_tool_calls) {
            $flushed->{tool_calls} = $accumulated_tool_calls;
        }
        
        # Add tool_call_id for tool messages (required by GitHub Copilot API)
        if ($last_role eq 'tool' && defined $accumulated_tool_call_id) {
            $flushed->{tool_call_id} = $accumulated_tool_call_id;
        }
        
        push @alternating, $flushed;
    }
    
    
    # If provider doesn't support role=tool, we converted tool messages to user messages above.
    # Now we must strip tool_calls from assistant messages, since there are no matching
    # role=tool messages anymore (they became user messages).
    # This prevents "orphaned tool_call" validation errors in APIManager.
    if (!$provider_supports_tool_role) {
        for my $msg (@alternating) {
            if ($msg->{role} eq 'assistant' && $msg->{tool_calls}) {
                delete $msg->{tool_calls};
                log_debug('WorkflowOrchestrator', "Stripped tool_calls from assistant message (provider doesn't support role=tool)");
            }
        }
    }
    log_debug('WorkflowOrchestrator', "Alternation complete: " . scalar(@$messages) . " → " . scalar(@alternating) . " messages");
    
    return \@alternating;
}


=head2 _check_and_handle_interrupt

Combined interrupt check + handle for use at multiple points during iteration.
Checks for ESC key press and if detected, adds interrupt message to conversation
and sets the _interrupt_pending flag to short-circuit remaining work.

Arguments:
- $session: Session object
- $messages_ref: Reference to messages array

Returns:
- 1 if interrupt detected and handled
- 0 if no interrupt

=cut

sub _check_and_handle_interrupt {
    my ($self, $session, $messages_ref) = @_;
    
    if ($self->_check_for_user_interrupt($session)) {
        $self->_handle_interrupt($session, $messages_ref);
        $self->{_interrupt_pending} = 1;
        
        log_info('WorkflowOrchestrator', "Interrupt detected mid-iteration, setting pending flag");
        
        return 1;
    }
    
    return 0;
}


=head2 _check_for_user_interrupt

Check for ESC key press (user interrupt) non-blocking.

Arguments:
- $session: Session object (to check and set interrupt flag)

Returns:
- 1 if interrupt detected (ESC key pressed)
- 0 if no interrupt

=cut

sub _check_for_user_interrupt {
    my ($self, $session) = @_;
    
    # Only check if we have a TTY
    return 0 unless -t STDIN;
    
    # Skip if already interrupted (prevent duplicate handling)
    if ($session && $session->state() && $session->state()->{user_interrupted}) {
        return 0;
    }
    
    # Non-blocking keyboard check
    my $key;
    eval {
        # Set cbreak mode (no echo, immediate input)
        ReadMode(1);
        
        # Non-blocking read (-1 = return immediately if no input)
        $key = ReadKey(-1);
        
        # Restore normal mode
        ReadMode(0);
    };
    
    # Ensure terminal mode restored even on error
    ReadMode(0);
    
    if ($@) {
        log_warning('WorkflowOrchestrator', "Error checking for interrupt: $@");
        return 0;
    }
    
    # Check for ESC key (character code 27 = 0x1b)
    if (defined $key && ord($key) == 27) {
        log_info('WorkflowOrchestrator', "User interrupt detected (ESC key pressed)");
        
        # Set interrupt flag in session
        if ($session && $session->state()) {
            $session->state()->{user_interrupted} = 1;
            
            eval {
                $session->save();
            };
            
            if ($@) {
                log_warning('WorkflowOrchestrator', "Failed to save interrupt flag to session: $@");
            }
        }
        
        return 1;  # Interrupt detected
    }
    
    return 0;  # No interrupt
}

=head2 _handle_interrupt

Handle user interrupt by injecting message into conversation.

Uses role=user (not role=system) to maintain message alternation.
Follows existing error message pattern from line 393-401.

Arguments:
- $session: Session object
- $messages_ref: Reference to messages array

Returns: Nothing (modifies messages array in place)

=cut

sub _handle_interrupt {
    my ($self, $session, $messages_ref) = @_;
    
    log_info('WorkflowOrchestrator', "Handling user interrupt");
    
    # Clear interrupt flag (it's been handled)
    if ($session && $session->state()) {
        $session->state()->{user_interrupted} = 0;
    }
    
    # Add interrupt message to conversation
    # Use role=user (not role=system) to maintain alternation
    # This follows the existing error message pattern (line 393-401)
    my $interrupt_message = {
        role => 'user',
        content => 
            "━━━ USER INTERRUPT ━━━\n\n" .
            "You pressed ESC to get the agent's attention.\n\n" .
            "AGENT: Stop your current work immediately and use the user_collaboration tool to ask what I need.\n\n" .
            "Example:\n" .
            "user_collaboration(operation: 'request_input', message: 'You pressed ESC - what do you need?')\n\n" .
            "The full conversation context has been preserved. I may want to:\n" .
            "- Give you new instructions\n" .
            "- Ask about your progress\n" .
            "- Change the approach\n" .
            "- Provide additional information\n\n" .
            "Please use user_collaboration to find out."
    };
    
    push @$messages_ref, $interrupt_message;
    
    # Save interrupt message to session
    if ($session) {
        eval {
            $session->add_message('user', $interrupt_message->{content});
            $session->save();
        };
        
        if ($@) {
            log_warning('WorkflowOrchestrator', "Failed to save interrupt message to session: $@");
        }
    }
    
    log_info('WorkflowOrchestrator', "Interrupt message added to conversation");
}

1;

__END__

=head1 WORKFLOW DIAGRAM

The orchestrator implements this flow:

    User Input
        ↓
    Build Messages (system + history + user)
        ↓
    ┌─────────────────────────────────┐
    │  Iteration Loop                 │
    │  (max 10 iterations)            │
    │                                 │
    │  1. Send to AI with tools       │
    │     ↓                           │
    │  2. Check response              │
    │     ↓                           │
    │  3. Has tool_calls?             │
    │     ├─ YES → Execute tools      │
    │     │        Add results        │
    │     │        Continue loop      │
    │     │                           │
    │     └─ NO → Return response    │
    │              (DONE)             │
    └─────────────────────────────────┘
        ↓
    Return to user

=head1 ARCHITECTURE

WorkflowOrchestrator is the NEW main entry point for AI interactions.

OLD (Pattern Matching):
    User → SimpleAIAgent → Regex Detection → Protocol Execution → Response

NEW (Tool Calling):
    User → WorkflowOrchestrator → AI with Tools → Tool Execution → AI → Response

The orchestrator:
- Replaces pattern matching with intelligent AI decisions
- Enables multi-turn tool use (tool → tool → answer)
- Scales to any number of tools
- Follows industry standard (OpenAI format)

=head1 INTEGRATION

Task 1: ✓ Tool Registry (CLIO::Tools::Registry)
Task 2: ✓ THIS MODULE (CLIO::Core::WorkflowOrchestrator)
Task 3: ⏳ Enhance APIManager to send/parse tools
Task 4: ⏳ Implement ToolExecutor to execute tools
Task 5: ⏳ Testing
Task 6: ⏳ Remove pattern matching, cleanup

=head1 AUTHOR

Fewtarius

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

1;
