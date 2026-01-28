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
use CLIO::Compat::Terminal qw(ReadKey ReadMode);  # For interrupt detection

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
        config => $args{config},  # Forward config for web search API keys
        ui => $args{ui},  # Forward UI for user_collaboration
        spinner => $args{spinner},  # Forward spinner for interactive tools
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
    
    print STDERR "[DEBUG][WorkflowOrchestrator] Processing input: '$user_input'\n" 
        if $self->{debug};
    
    # Build initial messages array
    my @messages = ();
    
    # Build system prompt with dynamic tools FIRST
    # This must come before history to ensure tools are always available
    my $system_prompt = $self->_build_system_prompt($session);
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
        print STDERR "[DEBUG][WorkflowOrchestrator] Loaded " . scalar(@$history) . " messages from history (after pre-flight trim)\n"
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
    my $retry_count = 0;  # Track retries per iteration (prevents infinite loops)
    my $max_retries = 3;  # Maximum retries before giving up
    
    while ($iteration < $self->{max_iterations}) {
        $iteration++;
        
        print STDERR "[DEBUG][WorkflowOrchestrator] Iteration $iteration/$self->{max_iterations}\n"
            if $self->{debug};
        
        # Check for user interrupt (ESC key press)
        if ($self->_check_for_user_interrupt($session)) {
            $self->_handle_interrupt($session, \@messages);
            # Don't count this iteration - interrupt handling is free
            $iteration--;
        }
        
        # Enforce message alternation for Claude compatibility
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
            
            # DEBUG: Log messages being sent to API when debug mode is enabled
            if ($self->{debug}) {
                print STDERR "[DEBUG][WorkflowOrchestrator] Sending to API: " . scalar(@$alternated_messages) . " messages\n";
                for my $i (0 .. $#{$alternated_messages}) {
                    my $msg = $alternated_messages->[$i];
                    print STDERR "[DEBUG][WorkflowOrchestrator]   API Message $i: role=" . $msg->{role};
                    if ($msg->{tool_calls}) {
                        print STDERR ", tool_calls=" . scalar(@{$msg->{tool_calls}});
                        for my $tc (@{$msg->{tool_calls}}) {
                            print STDERR ", tc_id=" . (defined $tc->{id} ? $tc->{id} : "**MISSING**");
                        }
                    }
                    if ($msg->{role} eq 'tool') {
                        print STDERR ", tool_call_id=" . (defined $msg->{tool_call_id} ? $msg->{tool_call_id} : "**MISSING**");
                    }
                    print STDERR "\n";
                }
            }
            
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
            
            # Check if this is a retryable error (rate limit or server error)
            if ($api_response->{retryable}) {
                $retry_count++;
                
                # Check if we've exceeded max retries for this iteration
                if ($retry_count > $max_retries) {
                    print STDERR "[ERROR][WorkflowOrchestrator] Maximum retries ($max_retries) exceeded for this iteration\n";
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
                my $system_msg = "Temporary $error_type detected. Retrying in ${retry_delay}s... (attempt $retry_count/$max_retries)";
                
                # Special handling for malformed tool JSON errors
                # Add guidance message ONLY on first retry (avoid accumulating multiple guidance messages)
                if ($api_response->{error_type} && $api_response->{error_type} eq 'malformed_tool_json' && $retry_count == 1) {
                    # CRITICAL: Remove the bad assistant message that triggered this error
                    # The malformed tool call is IN the assistant's response, so we must remove it
                    # Otherwise the AI sees its own failed attempt and repeats the same mistake
                    if (@messages && $messages[-1]->{role} eq 'assistant') {
                        my $removed_msg = pop @messages;
                        print STDERR "[INFO][WorkflowOrchestrator] Removed malformed assistant message from history\n"
                            if should_log('INFO');
                    }
                    
                    my $guidance_msg = {
                        role => 'system',
                        content => 'CRITICAL ERROR: Your previous tool call had invalid JSON parameters. ' .
                                   'Common issues: missing parameter values (e.g., "offset":, instead of "offset":0), ' .
                                   'unescaped quotes, trailing commas. Please retry the tool call with properly formatted JSON. ' .
                                   'ALL parameters must have valid values - no empty/missing values permitted.'
                    };
                    push @messages, $guidance_msg;
                    
                    $error_type = "malformed tool JSON";
                    $system_msg = "AI generated invalid JSON parameters. Removed bad message, adding guidance and retrying... (attempt $retry_count/$max_retries)";
                    
                    print STDERR "[INFO][WorkflowOrchestrator] Added JSON formatting guidance to conversation\n"
                        if should_log('INFO');
                }
                elsif ($api_response->{error_type} && $api_response->{error_type} eq 'malformed_tool_json' && $retry_count > 1) {
                    # After first retry with guidance failed, limit to max 1 more attempt
                    # If AI can't fix JSON after seeing guidance, continuing to retry is wasteful
                    $error_type = "persistent malformed tool JSON";
                    $system_msg = "AI still generating invalid JSON after guidance. Final retry attempt... (attempt $retry_count/$max_retries)";
                    
                    # Reduce max_retries for this specific error to avoid waste
                    if ($retry_count > 2) {
                        print STDERR "[ERROR][WorkflowOrchestrator] Malformed JSON persists after guidance - giving up\n";
                        return {
                            success => 0,
                            error => "AI repeatedly generated malformed tool call JSON. The current conversation context may be causing this issue. Try rephrasing your request or starting a new session.",
                            tool_calls_made => \@tool_calls_made
                        };
                    }
                }
                # Special handling for token limit exceeded errors
                elsif ($api_response->{error_type} && $api_response->{error_type} eq 'token_limit_exceeded') {
                    # Trim conversation history to fit within model's context window
                    # Remove oldest messages while keeping system prompt and recent context
                    
                    my $system_prompt = undef;
                    my @non_system = ();
                    
                    # Separate system prompt from other messages
                    for my $msg (@messages) {
                        if ($msg->{role} eq 'system' && !$system_prompt) {
                            $system_prompt = $msg;
                        } else {
                            push @non_system, $msg;
                        }
                    }
                    
                    my $original_count = scalar(@non_system);
                    
                    if ($retry_count == 1) {
                        # First retry: Keep last 50% of messages
                        my $keep_count = int($original_count / 2);
                        $keep_count = 10 if $keep_count < 10 && $original_count >= 10;  # Keep at least 10
                        @non_system = @non_system[-$keep_count..-1] if $keep_count > 0;
                    } elsif ($retry_count == 2) {
                        # Second retry: Keep last 25% of messages
                        my $keep_count = int($original_count / 4);
                        $keep_count = 5 if $keep_count < 5 && $original_count >= 5;  # Keep at least 5
                        @non_system = @non_system[-$keep_count..-1] if $keep_count > 0;
                    } else {
                        # Third retry: Keep only last 3 messages (minimal context)
                        @non_system = @non_system[-3..-1] if scalar(@non_system) > 3;
                    }
                    
                    my $trimmed_count = $original_count - scalar(@non_system);
                    
                    # Rebuild messages array
                    @messages = ();
                    push @messages, $system_prompt if $system_prompt;
                    push @messages, @non_system;
                    
                    $error_type = "token limit exceeded";
                    $system_msg = "Token limit exceeded. Trimmed $trimmed_count messages from conversation history and retrying... (attempt $retry_count/$max_retries)";
                    
                    print STDERR "[INFO][WorkflowOrchestrator] Trimmed $trimmed_count messages due to token limit (kept " . scalar(@non_system) . " messages)\n"
                        if should_log('INFO');
                    
                    # If we've trimmed to minimal context and still failing, give up
                    if ($retry_count > 2 && scalar(@non_system) <= 3) {
                        print STDERR "[ERROR][WorkflowOrchestrator] Token limit persists even with minimal context - giving up\n";
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
                    $system_msg = "Server temporarily unavailable. Retrying in ${retry_delay}s with exponential backoff... (attempt $retry_count/$max_retries)";
                    
                    print STDERR "[INFO][WorkflowOrchestrator] Applying exponential backoff for server error: ${retry_delay}s delay\n"
                        if should_log('INFO');
                }
                # Special handling for rate limit errors
                elsif ($api_response->{error_type} && $api_response->{error_type} eq 'rate_limit') {
                    # Rate limit already has appropriate retry_after from APIManager
                    # Just update the error_type for logging
                    $error_type = "rate limit";
                    # system_msg already set above
                }
                
                # Call system message callback if provided
                if ($on_system_message) {
                    eval { $on_system_message->($system_msg); };
                    print STDERR "[ERROR][WorkflowOrchestrator] Error in on_system_message callback: $@\n" if $@;
                } else {
                    print STDERR "[INFO][WorkflowOrchestrator] Retryable $error_type detected, retrying in ${retry_delay}s on next iteration (attempt $retry_count/$max_retries)\n";
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
            # Remove the last assistant message from @messages array if it exists
            # This prevents issues where a bad AI response keeps triggering the same error
            # The AI will see the error message and try a different approach
            if (@messages && $messages[-1]->{role} eq 'assistant') {
                my $removed_msg = pop @messages;
                print STDERR "[WARN][WorkflowOrchestrator] Removed bad assistant message due to API error: $error\n"
                    if should_log('WARNING');
                
                # Show what was removed for debugging
                if ($self->{debug}) {
                    my $content_preview = substr($removed_msg->{content} // '', 0, 100);
                    print STDERR "[DEBUG][WorkflowOrchestrator] Removed message content: $content_preview...\n";
                    if ($removed_msg->{tool_calls}) {
                        print STDERR "[DEBUG][WorkflowOrchestrator] Removed message had " . 
                            scalar(@{$removed_msg->{tool_calls}}) . " tool_calls\n";
                    }
                }
            }
            
            # Check if error is token limit related
            my $is_token_limit_error = ($error =~ /token|exceed|limit|length/i);
            
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
                
                print STDERR "[INFO][WorkflowOrchestrator] Added error message to conversation, continuing workflow\n"
                    if should_log('INFO');
            } else {
                # Token limit error - trim messages instead of adding error
                print STDERR "[WARN][WorkflowOrchestrator] Token limit error detected. Aggressively trimming conversation...\n"
                    if should_log('WARNING');
                
                # Force aggressive trim - keep only last 5 messages
                my @kept_messages = grep { $_->{role} eq 'system' || $_->{role} eq 'user' } @messages;
                my @last_user_messages = grep { $_->{role} eq 'user' } @messages;
                
                if (@last_user_messages > 5) {
                    # Remove user messages beyond the last 5
                    my $remove_count = @last_user_messages - 5;
                    for (my $i = 0; $i < $remove_count; $i++) {
                        @messages = grep { $_ != $last_user_messages[$i] } @messages;
                    }
                    print STDERR "[DEBUG][WorkflowOrchestrator] Removed " . $remove_count . " older user messages\n"
                        if $self->{debug};
                }
            }
            
            # Continue to next iteration - let AI try again with the error context
            next;
        }
        
        # API call succeeded - reset retry counter
        $retry_count = 0;
        
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
        
        # Extract text-based tool calls from content if no structured tool_calls
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
        my $assistant_msg_pending = undef;  # Will be set if we need delayed save
        
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
                tool_calls => $api_response->{tool_calls}
            };
            
            print STDERR "[DEBUG][WorkflowOrchestrator] Delaying save of assistant message with tool_calls until first tool result completes\n"
                if should_log('DEBUG');
            
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
            
            # Flush UI streaming buffer BEFORE executing any tools
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
                # The streaming callback prints "CLIO: " immediately on first chunk
                if ($first_tool_call) {
                    # Stop spinner BEFORE any tool output
                    # The spinner runs during AI API calls and must be stopped before
                    # we print tool execution messages to prevent spinner characters
                    # from appearing in the output (e.g., "⠹  -> action_description")
                    if ($self->{spinner} && $self->{spinner}->can('stop')) {
                        $self->{spinner}->stop();
                        print STDERR "[DEBUG][WorkflowOrchestrator] Stopped spinner before tool output\n"
                            if $self->{debug};
                    }
                    
                    my $content = $api_response->{content} // '';
                    print STDERR "[DEBUG][WorkflowOrchestrator] First tool call - checking content: '" . substr($content, 0, 100) . "'\n"
                        if $self->{debug};
                    
                    # Only print newline if content is empty (tool-call-only response)
                    # When there's content, it already ends with newline from streaming flush
                    if (!$content || $content =~ /^\s*$/) {
                        # Tool-call only response - need to clear the orphaned "CLIO: " prefix
                        # Move up one line and clear it, then print newline for clean start
                        print "\e[1A\r\e[K";  # Clear orphaned CLIO: line
                    }
                    # If content exists and ends with \n, we're already at a clean line start
                    # No extra newline needed
                    
                    $first_tool_call = 0;
                }
                
                # Show user-visible feedback BEFORE tool execution (for interactive tools like user_collaboration)
                # Use themed output via UI when available, fallback to hardcoded ANSI codes
                if ($self->{ui} && $self->{ui}->can('colorize')) {
                    print $self->{ui}->colorize("SYSTEM: ", 'SYSTEM');
                    print $self->{ui}->colorize("[$tool_name]", 'DATA');  # DATA color for tool info
                } else {
                    # Fallback when UI is not available
                    print $COLORS{SYSTEM}, "SYSTEM: ", $COLORS{RESET};
                    print $COLORS{TOOL}, "[", $tool_name, "]", $COLORS{RESET};
                }
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
                    if ($self->{ui} && $self->{ui}->can('colorize')) {
                        print $self->{ui}->colorize("  → $action_detail", 'DIM'), "\n";
                    } else {
                        print $COLORS{DETAIL}, "  → ", $action_detail, $COLORS{RESET}, "\n";
                    }
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
                            print STDERR "[DEBUG][WorkflowOrchestrator] Saved assistant message with tool_calls to session (on first tool result)\n"
                                if should_log('DEBUG');
                            $assistant_msg_pending = undef;  # Mark as saved
                        }
                        
                        # Now save the tool result
                        $session->add_message(
                            'tool',
                            $sanitized_content,
                            { tool_call_id => $tool_call->{id} }
                        );
                        print STDERR "[DEBUG][WorkflowOrchestrator] Saved tool result to session (tool_call_id=" . $tool_call->{id} . ")\n"
                            if should_log('DEBUG');
                    };
                    if ($@) {
                        print STDERR "[WARN][WorkflowOrchestrator] Failed to save tool result: $@\n";
                    }
                }
                
                print STDERR "[DEBUG][WorkflowOrchestrator] Tool result added to conversation (sanitized)\n"
                    if $self->{debug};
            }
            
            # Reset UI streaming state so next iteration shows new CLIO: prefix
            # This ensures proper message formatting after tool execution
            if ($self->{ui} && $self->{ui}->can('reset_streaming_state')) {
                print STDERR "[DEBUG][WorkflowOrchestrator] Resetting UI streaming state for next iteration\n"
                    if $self->{debug};
                $self->{ui}->reset_streaming_state();
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
                    print STDERR "[DEBUG][WorkflowOrchestrator] Session saved after iteration $iteration (preserving tool execution history)\n"
                        if should_log('DEBUG');
                };
                if ($@) {
                    print STDERR "[WARN][WorkflowOrchestrator] Failed to save session after iteration: $@\n";
                }
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
    my ($self, $session) = @_;
    
    # Load from PromptManager (includes custom instructions)
    require CLIO::Core::PromptManager;
    my $pm = CLIO::Core::PromptManager->new(debug => $self->{debug});
    
    print STDERR "[DEBUG][WorkflowOrchestrator] Loading system prompt from PromptManager\n"
        if $self->{debug};
    
    my $base_prompt = $pm->get_system_prompt();
    
    # Add current date/time and context management note at the beginning
    my $datetime_section = $self->_generate_datetime_section();
    $base_prompt = $datetime_section . "\n\n" . $base_prompt;
    
    # Dynamically add available tools section from tool registry
    my $tools_section = $self->_generate_tools_section();
    
    # Build LTM context section if session is available
    my $ltm_section = '';
    if ($session) {
        $ltm_section = $self->_generate_ltm_section($session);
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
        print STDERR "[DEBUG][WorkflowOrchestrator] Added LTM context section to prompt\n"
            if $self->{debug};
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
    
    $section .= "\n**Important:** You HAVE all $tool_count of these tools. ";
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
    $section .= "3. BEFORE using 'cd', verify directory exists with 'test -d' or use pwd to check location\n";
    $section .= "4. When working directory matters, ALWAYS run 'pwd' first to verify location\n";
    $section .= "5. Use 'realpath' or 'readlink -f' to resolve symbolic links before cd\n\n";
    $section .= "**Examples:**\n";
    $section .= "- CORRECT: `cd ./subdir && make`\n";
    $section .= "- CORRECT: `cd \$HOME/project && make`\n";
    $section .= "- CORRECT: `pwd && make` (if already in right place)\n";
    $section .= "- WRONG: `cd /Users/andy/project && make` (hallucinated path)\n\n";
    
    $section .= "**IMPORTANT - Context & Time Management:**\n\n";
    $section .= "CLIO manages your context window and processing time automatically. You should NEVER:\n";
    $section .= "- Worry about token budgets or context limits\n";
    $section .= "- Apologize for length or complexity of responses\n";
    $section .= "- Cut work short due to perceived time constraints\n";
    $section .= "- Ask permission to continue due to token concerns\n\n";
    $section .= "Focus entirely on delivering complete, high-quality work. CLIO handles all resource management.\n";
    
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
        print STDERR "[DEBUG][WorkflowOrchestrator] No LTM available: $@\n" if $self->{debug};
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
    
    print STDERR "[DEBUG][WorkflowOrchestrator] Found $total LTM patterns to inject\n" if $self->{debug};
    
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
            print STDERR "[DEBUG][WorkflowOrchestrator::_trim_conversation_for_api] History OK: $history_tokens tokens (total: $current_total of $safe_threshold safe limit, model context: $model_context)\n";
        }
        return $history;  # No trimming needed
    }
    
    if ($self->{debug}) {
        print STDERR "[WARN][WorkflowOrchestrator::_trim_conversation_for_api] History exceeds safe limit: $current_total tokens (safe: $safe_threshold of $model_context total). Trimming...\n";
        print STDERR "[DEBUG]  Model context window: $model_context tokens\n";
        print STDERR "[DEBUG]  Max response: $max_response tokens\n";
        print STDERR "[DEBUG]  Safe trim threshold: " . int($safe_threshold_percent * 100) . "% = $safe_threshold tokens\n";
        print STDERR "[DEBUG]  System prompt: $system_tokens tokens\n";
        print STDERR "[DEBUG]  History: $history_tokens tokens\n";
        print STDERR "[DEBUG]  Messages in history: " . scalar(@$history) . "\n";
    }
    
    my @messages = @$history;
    my @trimmed = ();
    
    # Strategy: Keep recent messages, trim older ones
    # Recent messages are more important for context continuity
    # Calculate target based on available space (current safe threshold - system prompt)
    my $target_tokens = int(($safe_threshold - $system_tokens) * 0.9);  # 90% of remaining space
    my $keep_recent = 10;      # Always keep at least last 10 messages
    my $current_count = scalar(@messages);
    
    # If we have more messages than we want to keep
    if ($current_count > $keep_recent) {
        # Calculate how many messages to keep from the beginning
        # Keep older messages by importance, remove lower-importance older messages
        my @recent = @messages[-$keep_recent .. -1];  # Last N messages
        my @older = @messages[0 .. $current_count - $keep_recent - 1];  # Everything else
        
        # Sort older messages by importance (highest first)
        my @sorted_older = sort {
            ($b->{_importance} // 0) <=> ($a->{_importance} // 0)
        } @older;
        
        # Keep recent and some older high-importance messages
        @trimmed = @recent;
        
        # Estimate tokens in recent messages
        my $trimmed_tokens = CLIO::Memory::TokenEstimator::estimate_messages_tokens(\@recent);
        
        # Add older important messages until we reach target or run out
        for my $msg (@sorted_older) {
            my $msg_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($msg->{content} // '');
            if ($trimmed_tokens + $msg_tokens <= $target_tokens) {
                push @trimmed, $msg;
                $trimmed_tokens += $msg_tokens;
            }
        }
        
        # Maintain chronological order for trimmed messages
        @trimmed = sort { 
            my $idx_a = 0;
            my $idx_b = 0;
            for my $i (0 .. $#messages) {
                $idx_a = $i if $messages[$i] == $a;
                $idx_b = $i if $messages[$i] == $b;
            }
            $idx_a <=> $idx_b
        } @trimmed;
        
        my $final_tokens = CLIO::Memory::TokenEstimator::estimate_messages_tokens(\@trimmed);
        if ($self->{debug}) {
            print STDERR "[DEBUG][WorkflowOrchestrator::_trim_conversation_for_api] Trimmed: " . 
                         scalar(@messages) . " -> " . scalar(@trimmed) . " messages\n";
            print STDERR "[DEBUG]  Token reduction: $history_tokens -> $final_tokens tokens\n";
            print STDERR "[DEBUG]  Final total with system: " . ($system_tokens + $final_tokens) . " of $safe_threshold safe limit\n";
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
    
    print STDERR "[DEBUG][WorkflowOrchestrator] Raw history from session has " . scalar(@$history) . " messages\n"
        if $self->{debug};
    
    # DEBUG: Dump first assistant message (when debug enabled)
    if ($self->{debug}) {
        for my $i (0 .. $#{$history}) {
            my $msg = $history->[$i];
            if ($msg->{role} eq 'assistant') {
                use Data::Dumper;
                print STDERR "[DEBUG][WorkflowOrchestrator] First assistant message structure:\n";
                print STDERR Dumper($msg);
                last;
            }
        }
    }
    
    print STDERR "[DEBUG][WorkflowOrchestrator] Loaded " . scalar(@$history) . " messages from session\n"
        if $self->{debug};
    
    # Validate and filter messages
    # Skip system messages from history - we always build fresh with dynamic tools
    my @valid_messages = ();
    
    print STDERR "[DEBUG][WorkflowOrchestrator] _load_conversation_history: Processing " . scalar(@$history) . " messages\n"
        if $self->{debug};
    
    for my $msg (@$history) {
        next unless $msg && ref($msg) eq 'HASH';
        next unless $msg->{role};
        
        if ($self->{debug}) {
            my $has_tool_calls = exists $msg->{tool_calls} ? 'YES' : 'NO';
            my $tc_count = $msg->{tool_calls} ? scalar(@{$msg->{tool_calls}}) : 0;
            print STDERR "[DEBUG][WorkflowOrchestrator]   Message role=" . $msg->{role} . 
                ", has_tool_calls=$has_tool_calls, count=$tc_count\n";
        }
        
        # Skip system messages - we build fresh system prompt in process_input
        next if $msg->{role} eq 'system';
        
        # Skip tool result messages without tool_call_id
        # GitHub Copilot API REQUIRES tool_call_id for role=tool messages
        # If missing, API returns "tool call must have a tool call ID" error
        if ($msg->{role} eq 'tool' && !$msg->{tool_call_id}) {
            if ($self->{debug}) {
                print STDERR "[WARN][WorkflowOrchestrator] Skipping tool message without tool_call_id " .
                    "(content: " . substr($msg->{content} // '', 0, 50) . "...)\n";
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
            print STDERR "[DEBUG][WorkflowOrchestrator]   Preserving tool message with tool_call_id=$msg->{tool_call_id}\n"
                if $self->{debug};
        } elsif ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            # Assistant message with tool_calls - KEEP the tool_calls for API correlation
            print STDERR "[DEBUG][WorkflowOrchestrator]   Preserving assistant message with " . 
                scalar(@{$msg->{tool_calls}}) . " tool_calls for API correlation\n"
                if $self->{debug};
            
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
                    print STDERR "[WARN][WorkflowOrchestrator] Orphaned tool_call detected: $id (missing tool_result)\n"
                        if should_log("WARN");
                    $missing_results++;
                }
            }
            
            if ($missing_results > 0) {
                # Remove tool_calls to prevent API error "tool_use ids were found without tool_result blocks"
                print STDERR "[WARN][WorkflowOrchestrator] Removing tool_calls from loaded assistant message ($missing_results missing results)\n"
                    if should_log("WARN");
                
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
                print STDERR "[WARN][WorkflowOrchestrator] Removing orphaned tool_result: $msg->{tool_call_id} (no matching tool_call)\n"
                    if should_log("WARN");
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
            
            print STDERR "[DEBUG][WorkflowOrchestrator] Converted tool message to user message\n"
                if should_log('DEBUG');
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
        print STDERR "[WARN][WorkflowOrchestrator] Error checking for interrupt: $@\n"
            if should_log('WARNING');
        return 0;
    }
    
    # Check for ESC key (character code 27 = 0x1b)
    if (defined $key && ord($key) == 27) {
        print STDERR "[INFO][WorkflowOrchestrator] User interrupt detected (ESC key pressed)\n"
            if should_log('INFO');
        
        # Set interrupt flag in session
        if ($session && $session->state()) {
            $session->state()->{user_interrupted} = 1;
            
            eval {
                $session->save();
            };
            
            if ($@) {
                print STDERR "[WARN][WorkflowOrchestrator] Failed to save interrupt flag to session: $@\n"
                    if should_log('WARNING');
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
    
    print STDERR "[INFO][WorkflowOrchestrator] Handling user interrupt\n"
        if should_log('INFO');
    
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
            print STDERR "[WARN][WorkflowOrchestrator] Failed to save interrupt message to session: $@\n"
                if should_log('WARNING');
        }
    }
    
    print STDERR "[INFO][WorkflowOrchestrator] Interrupt message added to conversation\n"
        if should_log('INFO');
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
