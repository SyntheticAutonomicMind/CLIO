package CLIO::Core::WorkflowOrchestrator;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(should_log);
use CLIO::Util::TextSanitizer qw(sanitize_text);
use CLIO::Util::JSONRepair qw(repair_malformed_json);
use JSON::PP qw(encode_json decode_json);
use Encode qw(encode_utf8);  # For handling Unicode in JSON
use Time::HiRes qw(time);
use Digest::MD5 qw(md5_hex);

# ANSI color codes for terminal output (matching Chat.pm color scheme)
my %COLORS = (
    RESET     => "\e[0m",
    SYSTEM    => "\e[1;35m",  # Bright Magenta - System messages
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
    };
    
    bless $self, $class;
    
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
        ui => $args{ui},  # Forward UI for user_collaboration
        debug => $args{debug}
    );
    
    print STDERR "[DEBUG][WorkflowOrchestrator] Initialized with max_iterations=$self->{max_iterations}\n" 
        if $self->{debug};
    
    return $self;
}

=head2 _register_default_tools

Register default tools (file_operations, etc.) with the tool registry.

=cut

sub _register_default_tools {
    my ($self) = @_;
    
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
    
    print STDERR "[DEBUG][WorkflowOrchestrator] Registered default tools\n" if should_log('DEBUG');
}

=head2 process_input

Main workflow loop for tool calling.

Arguments:
- $user_input: User's request (string)
- $session: Session object with conversation history
- %opts: Optional parameters
  * on_chunk: Callback for streaming responses (receives content chunk and metrics)

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
    
    # Extract on_chunk callback if provided
    my $on_chunk = $opts{on_chunk};
    my $on_tool_call_from_ui = $opts{on_tool_call};  # Tool call tracker from UI
    
    print STDERR "[DEBUG][WorkflowOrchestrator] Processing input: '$user_input'\n" 
        if $self->{debug};
    
    # Build initial messages array
    my @messages = ();
    
    # CRITICAL: Build system prompt with dynamic tools FIRST
    # This must come before history to ensure tools are always available
    my $system_prompt = $self->_build_system_prompt();
    push @messages, {
        role => 'system',
        content => $system_prompt
    };
    
    print STDERR "[DEBUG][WorkflowOrchestrator] Added system prompt with tools (" . length($system_prompt) . " chars)\n"
        if $self->{debug};
    
    # Inject context files from session
    $self->_inject_context_files($session, \@messages);
    
    # Load conversation history from session (excluding any system messages from history)
    my $history = $self->_load_conversation_history($session);
    if ($history && @$history) {
        push @messages, @$history;
        print STDERR "[DEBUG][WorkflowOrchestrator] Loaded " . scalar(@$history) . " messages from history\n"
            if $self->{debug};
    }
    
    # Add current user message
    push @messages, {
        role => 'user',
        content => $user_input
    };
    
    # Get tool definitions from registry (for API)
    my $tools = $self->{tool_registry}->get_tool_definitions();
    print STDERR "[DEBUG][WorkflowOrchestrator] Loaded " . scalar(@$tools) . " tool definitions\n"
        if $self->{debug};
    
    # Main workflow loop
    my $iteration = 0;
    my @tool_calls_made = ();
    my $start_time = time();
    
    while ($iteration < $self->{max_iterations}) {
        $iteration++;
        
        print STDERR "[DEBUG][WorkflowOrchestrator] Iteration $iteration/$self->{max_iterations}\n"
            if $self->{debug};
        
        # CRITICAL: Enforce message alternation for Claude compatibility
        # Must be done before EVERY API call, as messages array is modified during tool calling
        my $alternated_messages = $self->_enforce_message_alternation(\@messages);
        
        # Send to AI with tools (ALWAYS use streaming for proper quota headers from GitHub Copilot)
        my $api_response = eval {
            # Use streaming mode always (GitHub Copilot requires stream:true for real quota data)
            # If no callback provided, use a no-op callback
            print STDERR "[DEBUG][WorkflowOrchestrator] Using streaming mode (iteration $iteration)\n"
                if $self->{debug};
            
            # Provide a default no-op callback if none specified
            my $callback = $on_chunk || sub { };  # No-op callback
            
            # Define tool call callback to show tool names as they stream in
            my $tool_callback = sub {
                my ($tool_name) = @_;
                
                # Call UI callback if provided (Chat.pm tool display)
                if ($on_tool_call_from_ui) {
                    eval { $on_tool_call_from_ui->($tool_name); };
                    if ($@) {
                        print STDERR "[ERROR][WorkflowOrchestrator] Error in on_tool_call callback: $@\n";
                    }
                }
                
                # Also show in orchestrator context
                print STDERR "[DEBUG][WorkflowOrchestrator] Tool called: $tool_name\n"
                    if $self->{debug};
            };
            
            $self->{api_manager}->send_request_streaming(
                undef,  # No direct input (using messages)
                messages => $alternated_messages,  # Use alternation-enforced messages
                tools => $tools,
                tool_call_iteration => $iteration,  # Track iteration for billing
                on_chunk => $callback,
                on_tool_call => $tool_callback
            );
        };
        
        if ($@) {
            print STDERR "[ERROR][WorkflowOrchestrator] API error: $@\n";
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
            
            # Check if this is a rate limit error - if so, DON'T count as iteration and retry
            if ($error =~ /rate limit/i) {
                print STDERR "[INFO][WorkflowOrchestrator] Rate limit detected, will retry on next iteration\n";
                # Don't increment iteration counter - this failed attempt doesn't count
                $iteration--;
                # Continue to next iteration (which will trigger rate limit wait in APIManager)
                next;
            }
            
            print STDERR "[ERROR][WorkflowOrchestrator] API error: $error\n";
            
            # Return error with final_response so Chat.pm can display it to user
            return {
                success => 0,
                error => $error,
                final_response => "ERROR: $error",
                iterations => $iteration,
                tool_calls_made => \@tool_calls_made
            };
        }
        
        # Record API usage for billing tracking
        if ($api_response->{usage} && $session) {
            if ($session->can('record_api_usage')) {
                # Get current model and provider from API manager (dynamic lookup)
                my $model = $self->{api_manager}->get_current_model();
                my $provider = $self->{api_manager}->get_current_provider();
                $session->record_api_usage($api_response->{usage}, $model, $provider);
                print STDERR "[DEBUG][WorkflowOrchestrator] Recorded API usage: model=$model, provider=$provider\n"
                    if should_log('DEBUG');
            }
        }
        
        # Debug: Log API response structure
        if ($self->{debug}) {
            print STDERR "[DEBUG][WorkflowOrchestrator] API response received\n";
            if ($api_response->{tool_calls}) {
                print STDERR "[DEBUG][WorkflowOrchestrator] Tool calls detected: " . 
                    scalar(@{$api_response->{tool_calls}}) . "\n";
            } else {
                print STDERR "[DEBUG][WorkflowOrchestrator] No structured tool calls in response\n";
            }
        }
        
        # CRITICAL FIX: Extract text-based tool calls from content if no structured tool_calls
        # This supports models that output tool calls as text instead of using OpenAI format
        if (!$api_response->{tool_calls} || !@{$api_response->{tool_calls}}) {
            require CLIO::Core::ToolCallExtractor;
            my $extractor = CLIO::Core::ToolCallExtractor->new(debug => $self->{debug});
            
            my $result = $extractor->extract($api_response->{content});
            
            if (@{$result->{tool_calls}}) {
                print STDERR "[DEBUG][WorkflowOrchestrator] Extracted " . 
                    scalar(@{$result->{tool_calls}}) . " text-based tool calls (format: $result->{format})\n"
                    if $self->{debug};
                
                # Update response to include extracted tool calls
                $api_response->{tool_calls} = $result->{tool_calls};
                # Update content to remove tool call text
                $api_response->{content} = $result->{cleaned_content};
            }
        }
        
        # Check if AI requested tool calls (structured or text-based)
        if ($api_response->{tool_calls} && @{$api_response->{tool_calls}}) {
            print STDERR "[DEBUG][WorkflowOrchestrator] Processing " . 
                scalar(@{$api_response->{tool_calls}}) . " tool calls\n"
                if $self->{debug};
            
            # Add assistant's message with tool_calls to conversation
            push @messages, {
                role => 'assistant',
                content => $api_response->{content},
                tool_calls => $api_response->{tool_calls}
            };
            
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
                        # Repair malformed JSON from AI (e.g., "offset":, → "offset":0,)
                        my $json_str = $tool_call->{function}->{arguments};
                        
                        # Debug: Show original JSON before repair
                        if ($self->{debug}) {
                            my $preview = substr($json_str, 0, 300);
                            print STDERR "[DEBUG][WorkflowOrchestrator] Original JSON arguments (first 300 chars): $preview\n";
                        }
                        
                        $json_str = repair_malformed_json($json_str, $self->{debug});
                        
                        # Debug: Show repaired JSON
                        if ($self->{debug}) {
                            my $preview = substr($json_str, 0, 300);
                            print STDERR "[DEBUG][WorkflowOrchestrator] Repaired JSON arguments (first 300 chars): $preview\n";
                        }
                        
                        # Encode to UTF-8 bytes to avoid "Wide character in subroutine entry"
                        my $json_bytes = encode_utf8($json_str);
                        
                        $params = decode_json($json_bytes);
                    };
                    if ($@) {
                        my $tool_name = $tool_call->{function}->{name} || 'unknown';
                        my $error = $@;
                        my $args_full = $tool_call->{function}->{arguments} || '';
                        
                        print STDERR "[ERROR][WorkflowOrchestrator] Failed to parse arguments for tool '$tool_name': $error\n";
                        print STDERR "[ERROR][WorkflowOrchestrator] Full arguments:\n$args_full\n";
                        
                        # Skip this malformed tool call
                        next;
                    }
                }
                
                # Determine if tool is interactive (hybrid: parameter overrides metadata)
                my $is_interactive = 0;
                if (exists $params->{isInteractive}) {
                    $is_interactive = $params->{isInteractive} ? 1 : 0;
                    print STDERR "[DEBUG][WorkflowOrchestrator] Tool $tool_name isInteractive parameter: $is_interactive\n"
                        if $self->{debug};
                } elsif ($tool && $tool->{is_interactive}) {
                    $is_interactive = 1;
                    print STDERR "[DEBUG][WorkflowOrchestrator] Tool $tool_name default is_interactive: $is_interactive\n"
                        if $self->{debug};
                }
                
                # Interactive tools are BLOCKING (must wait for user I/O)
                my $requires_blocking = ($tool && $tool->{requires_blocking}) || $is_interactive;
                
                if ($tool) {
                    if ($requires_blocking) {
                        push @blocking_tools, $tool_call;
                        print STDERR "[DEBUG][WorkflowOrchestrator] Classified $tool_name as BLOCKING (interactive=$is_interactive)\n"
                            if $self->{debug};
                    } elsif ($tool->{requires_serial}) {
                        push @serial_tools, $tool_call;
                        print STDERR "[DEBUG][WorkflowOrchestrator] Classified $tool_name as SERIAL\n"
                            if $self->{debug};
                    } else {
                        push @parallel_tools, $tool_call;
                        print STDERR "[DEBUG][WorkflowOrchestrator] Classified $tool_name as PARALLEL\n"
                            if $self->{debug};
                    }
                } else {
                    # Unknown tool - treat as parallel (will fail safely)
                    push @parallel_tools, $tool_call;
                    print STDERR "[WARN]WorkflowOrchestrator] Unknown tool $tool_name, treating as PARALLEL\n";
                }
            }
            
            # Combine in execution order: BLOCKING first (serially), then SERIAL, then PARALLEL
            # For now, all execute serially since we don't have async execution
            # But BLOCKING tools are clearly separated for future enhancement
            my @ordered_tool_calls = (@blocking_tools, @serial_tools, @parallel_tools);
            
            print STDERR "[DEBUG][WorkflowOrchestrator] Execution order: " .
                scalar(@blocking_tools) . " blocking, " .
                scalar(@serial_tools) . " serial, " .
                scalar(@parallel_tools) . " parallel\n" if $self->{debug};
            
            # CRITICAL FIX: Flush UI streaming buffer BEFORE executing any tools
            # This ensures agent text appears BEFORE tool execution output
            # Part of the handshake mechanism to fix message ordering (Bug 1 & 3)
            if ($self->{ui} && $self->{ui}->can('flush_output_buffer')) {
                print STDERR "[DEBUG][WorkflowOrchestrator] Flushing UI buffer before tool execution\n"
                    if $self->{debug};
                $self->{ui}->flush_output_buffer();
            }
            # Also flush STDOUT directly as a fallback
            STDOUT->flush() if STDOUT->can('flush');
            $| = 1;
            
            # Track if this is the first tool call in the iteration
            my $first_tool_call = 1;
            
            # Execute tools in classified order
            for my $tool_call (@ordered_tool_calls) {
                my $tool_name = $tool_call->{function}->{name} || 'unknown';
                
                print STDERR "[DEBUG][WorkflowOrchestrator] Executing tool: $tool_name\n"
                    if $self->{debug};
                
                # Handle first tool call: ensure proper line separation from agent content
                # The streaming callback prints "AGENT: " immediately on first chunk, but if the response
                # was tool calls only (no text content), we need clean separation
                if ($first_tool_call) {
                    my $content = $api_response->{content} // '';
                    print STDERR "[DEBUG][WorkflowOrchestrator] First tool call - checking content: '" . substr($content, 0, 100) . "'\n"
                        if $self->{debug};
                    
                    # Always print a newline before SYSTEM output to ensure clean separation
                    # This handles both cases:
                    # 1. Content exists but may not end with newline
                    # 2. Content is empty but "AGENT: " was printed
                    print "\n";
                    STDOUT->flush() if STDOUT->can('flush');
                    
                    $first_tool_call = 0;
                }
                
                # Show user-visible feedback BEFORE tool execution (for interactive tools like user_collaboration)
                # NOTE: Update existing "(streaming...)" message to show execution started
                print $COLORS{SYSTEM}, "SYSTEM: ", $COLORS{RESET};
                print $COLORS{TOOL}, "[", $tool_name, "]", $COLORS{RESET};
                print "\n";
                STDOUT->flush() if STDOUT->can('flush');  # Ensure tool header appears immediately
                
                # Execute tool to get the result
                my $tool_result = $self->_execute_tool($tool_call);
                
                # Extract action_description from tool result (Task 4 implementation)
                my $action_detail = '';
                my $result_data;  # Declare here so it's available later
                if ($tool_result) {
                    $result_data = eval { 
                        # Tool result might be JSON string or already decoded
                        ref($tool_result) eq 'HASH' ? $tool_result : decode_json($tool_result);
                    };
                    if ($result_data && ref($result_data) eq 'HASH') {
                        if ($result_data->{action_description}) {
                            $action_detail = $result_data->{action_description};
                        } elsif ($result_data->{metadata} && ref($result_data->{metadata}) eq 'HASH' && 
                                 $result_data->{metadata}->{action_description}) {
                            $action_detail = $result_data->{metadata}->{action_description};
                        }
                    }
                }
                
                # Display action detail if provided (as indented follow-up to SYSTEM message)
                if ($action_detail) {
                    print $COLORS{DETAIL}, "  → ", $action_detail, $COLORS{RESET}, "\n";
                    $| = 1;
                }
                
                # Extract the actual output for the AI (not the UI metadata)
                my $ai_content = $tool_result;
                if ($result_data && ref($result_data) eq 'HASH' && exists $result_data->{output}) {
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
                
                # CRITICAL: Content MUST be a string, not a number!
                # GitHub Copilot API requires content to be string type.
                # If tool returns a number (e.g., file size, boolean), stringify it.
                $sanitized_content = "$sanitized_content" if defined $sanitized_content;
                
                # Add tool result to conversation (AI sees the output, not the UI wrapper)
                push @messages, {
                    role => 'tool',
                    tool_call_id => $tool_call->{id},
                    content => $sanitized_content
                };
                
                print STDERR "[DEBUG][WorkflowOrchestrator] Tool result added to conversation (sanitized)\n"
                    if $self->{debug};
            }
            
            # Reset UI streaming state so next iteration shows new AGENT: prefix
            # This ensures proper message formatting after tool execution
            if ($self->{ui} && $self->{ui}->can('reset_streaming_state')) {
                print STDERR "[DEBUG][WorkflowOrchestrator] Resetting UI streaming state for next iteration\n"
                    if $self->{debug};
                $self->{ui}->reset_streaming_state();
            }
            
            # Loop back - AI will process tool results
            next;
        }
        
        # No tool calls - AI has final answer
        my $elapsed_time = time() - $start_time;
        
        print STDERR "[DEBUG][WorkflowOrchestrator] Workflow complete after $iteration iterations (${elapsed_time}s)\n"
            if $self->{debug};
        
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
            elapsed_time => $elapsed_time
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
    
    my $error_msg = sprintf(
        "Maximum iterations (%d) reached after %.1fs. " .
        "The task may require more iterations - you can increase the limit in config or try breaking the task into smaller steps.",
        $self->{max_iterations},
        $elapsed_time
    );
    
    print STDERR "[ERROR][WorkflowOrchestrator] $error_msg\n";
    print STDERR "[ERROR][WorkflowOrchestrator] Tool calls made: " . scalar(@tool_calls_made) . "\n";
    
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
    my ($self) = @_;
    
    # Load from PromptManager (includes custom instructions)
    require CLIO::Core::PromptManager;
    my $pm = CLIO::Core::PromptManager->new(debug => $self->{debug});
    
    print STDERR "[DEBUG][WorkflowOrchestrator] Loading system prompt from PromptManager\n"
        if $self->{debug};
    
    my $base_prompt = $pm->get_system_prompt();
    
    # Dynamically add available tools section from tool registry
    my $tools_section = $self->_generate_tools_section();
    
    # Insert tools section after "## Core Instructions" or append if not found
    if ($base_prompt =~ /## Core Instructions/) {
        # Insert after Core Instructions section
        $base_prompt =~ s/(## Core Instructions.*?\n)/$1\n$tools_section\n/s;
    } else {
        # Append to end
        $base_prompt .= "\n\n$tools_section";
    }
    
    print STDERR "[DEBUG][WorkflowOrchestrator] Added dynamic tools section to prompt\n"
        if $self->{debug};
    
    return $base_prompt;
}

=head2 _generate_tools_section

Generate a dynamic "Available Tools" section based on registered tools.

Returns:
- Markdown text listing all available tools

=cut

sub _generate_tools_section {
    my ($self) = @_;
    
    # Get all registered tool OBJECTS (not just names)
    my $tools = $self->{tool_registry}->get_all_tools();
    my $tool_count = scalar(@$tools);
    
    print STDERR "[DEBUG][WorkflowOrchestrator] Generating tools section for $tool_count tools\n"
        if $self->{debug};
    
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
    
    $section .= "\n**CRITICAL:** You HAVE all $tool_count of these tools. ";
    $section .= "Do NOT say you don't have a tool that's on this list!\n\n";
    
    # Add JSON formatting instruction with HIGH priority to prevent malformed JSON
    $section .= "## **CRITICAL - JSON FORMAT REQUIREMENT**\n\n";
    $section .= "When calling tools, you MUST generate valid JSON. This is NON-NEGOTIABLE.\n\n";
    $section .= "**FORBIDDEN:**  `{\"offset\":,\"length\":8192}`  ← Missing value = PARSER CRASH\n\n";
    $section .= "**CORRECT Options:**\n";
    $section .= "1. Omit optional param: `{\"operation\":\"read_tool_result\",\"length\":8192}`\n";
    $section .= "2. Include with value: `{\"operation\":\"read_tool_result\",\"offset\":0,\"length\":8192}`\n\n";
    $section .= "**Rule:** EVERY parameter key MUST have a value. No exceptions.\n";
    
    return $section;
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
    
    # Limit history to last 10 messages to avoid context overflow
    if (@$history > 10) {
        my $start_idx = @$history - 10;
        $history = [@{$history}[$start_idx .. $#{$history}]];
        
        print STDERR "[DEBUG][WorkflowOrchestrator] Trimmed history to last 10 messages\n"
            if $self->{debug};
    }
    
    # Validate and filter messages
    # CRITICAL: Skip system messages from history - we always build fresh with dynamic tools
    my @valid_messages = ();
    for my $msg (@$history) {
        next unless $msg && ref($msg) eq 'HASH';
        next unless $msg->{role} && $msg->{content};
        
        # Skip system messages - we build fresh system prompt in process_input
        next if $msg->{role} eq 'system';
        
        push @valid_messages, {
            role => $msg->{role},
            content => $msg->{content}
        };
    }
    
    return \@valid_messages;
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
    
    print STDERR "[DEBUG][WorkflowOrchestrator] Injecting " . scalar(@context_files) . " context file(s)\n"
        if $self->{debug};
    
    my $context_content = "";
    my $total_tokens = 0;
    
    for my $file (@context_files) {
        unless (-f $file) {
            print STDERR "[WARN]WorkflowOrchestrator] Context file not found: $file\n";
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
            
            print STDERR "[DEBUG][WorkflowOrchestrator] Injected context file: $file (~$tokens tokens)\n"
                if $self->{debug};
        };
        
        if ($@) {
            print STDERR "[ERROR][WorkflowOrchestrator] Failed to read context file $file: $@\n";
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
        
        print STDERR "[DEBUG][WorkflowOrchestrator] Context injection complete (~$total_tokens tokens)\n"
            if $self->{debug};
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
    
    print STDERR "[DEBUG][WorkflowOrchestrator] Enforcing message alternation (Claude compatibility)\n"
        if should_log('DEBUG');
    
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
        
        # CRITICAL: Convert tool messages to user messages ONLY for providers that don't support role=tool
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
            
            print STDERR "[DEBUG][WorkflowOrchestrator] Converted tool message to user message\n"
                if should_log('DEBUG');
        }
        
        # Check if same role as previous (needs merging)
        # CRITICAL: Do NOT merge tool messages - each has unique tool_call_id
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
            
            print STDERR "[DEBUG][WorkflowOrchestrator] Merged consecutive $role message\n"
                if should_log('DEBUG');
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
    
    print STDERR "[DEBUG][WorkflowOrchestrator] Alternation complete: " . 
        scalar(@$messages) . " → " . scalar(@alternating) . " messages\n"
        if should_log('DEBUG');
    
    return \@alternating;
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

Task 1: ✅ Tool Registry (CLIO::Tools::Registry)
Task 2: ✅ THIS MODULE (CLIO::Core::WorkflowOrchestrator)
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
