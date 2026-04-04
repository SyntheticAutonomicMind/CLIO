# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::WorkflowOrchestrator;

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use CLIO::UI::Terminal qw(box_char ui_char);
use CLIO::Core::Logger qw(log_error log_warning log_info log_debug);
use CLIO::Core::ErrorContext qw(classify_error format_error);
use CLIO::Util::TextSanitizer qw(sanitize_text);
use CLIO::Util::JSONRepair qw(repair_malformed_json);
use CLIO::Util::AnthropicXMLParser qw(is_anthropic_xml_format parse_anthropic_xml_to_json);
use CLIO::UI::ToolOutputFormatter;
use CLIO::Core::ToolErrorGuidance;
use CLIO::Core::ConversationManager qw(
    load_conversation_history
    trim_conversation_for_api
    enforce_message_alternation
    inject_context_files
    generate_tool_call_id
    repair_tool_call_json
);
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);
use CLIO::Memory::TokenEstimator qw(estimate_tokens);
use CLIO::Core::PromptBuilder;
use CLIO::Util::JSON qw(encode_json decode_json);
use Encode qw(encode_utf8);  # For handling Unicode in JSON
use Time::HiRes qw(time sleep);
use Digest::MD5 qw(md5_hex);
use CLIO::Compat::Terminal qw(ReadKey ReadMode);  # For interrupt detection
use CLIO::Logging::ProcessStats;
use POSIX qw(strftime);

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
        max_iterations => $args{max_iterations} // 0,  # 0 = unlimited (interactive); overridden below for non-interactive
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
    
    # Apply default iteration limit for non-interactive mode
    # Prevents runaway oneshot agents that loop indefinitely
    if ($self->{non_interactive} && !$self->{max_iterations}) {
        $self->{max_iterations} = 75;  # Generous limit for complex tasks
        log_debug('WorkflowOrchestrator', "Non-interactive mode: defaulting max_iterations to $self->{max_iterations}");
    }
    
    # Initialize tool output formatter
    $self->{formatter} = CLIO::UI::ToolOutputFormatter->new(ui => $args{ui});
    
    # Initialize tool error guidance
    $self->{error_guidance} = CLIO::Core::ToolErrorGuidance->new();

    # Store config reference for tool registration decisions
    $self->{config} = $args{config};
    
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
    
    # Initialize prompt builder for system prompt construction
    $self->{prompt_builder} = CLIO::Core::PromptBuilder->new(
        debug           => $args{debug},
        skip_custom     => $self->{skip_custom},
        skip_ltm        => $self->{skip_ltm},
        non_interactive => $self->{non_interactive},
        tool_registry   => $self->{tool_registry},
        mcp_manager     => $self->{mcp_manager},
    );
    
    # Initialize FileVault for targeted file backup and undo support
    eval {
        require CLIO::Session::FileVault;
        $self->{file_vault} = CLIO::Session::FileVault->new(
            debug => $args{debug},
        );
        log_debug('WorkflowOrchestrator', "FileVault initialized - undo always available");
    };
    if ($@) {
        log_debug('WorkflowOrchestrator', "FileVault failed to load: $@");
        $self->{file_vault} = undef;
    }
    
    # Ensure .gitignore is set up correctly for .clio/ (if in a git repo)
    eval {
        require CLIO::Util::GitIgnore;
        CLIO::Util::GitIgnore::ensure_clio_ignored();
    };
    log_debug('WorkflowOrchestrator', "GitIgnore check failed: $@") if $@;
    
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
    my $remote_enabled = $self->{config} ? $self->{config}->get('enable_remote') : 1;
    unless (($is_subagent && $blocked_for_subagent{'remote_execution'}) || !$remote_enabled) {
        require CLIO::Tools::RemoteExecution;
        $self->{tool_registry}->register_tool(
            CLIO::Tools::RemoteExecution->new(debug => $self->{debug})
        );
    } else {
        my $reason = !$remote_enabled ? "disabled in config" : "sub-agent restriction";
        log_debug('WorkflowOrchestrator', "Blocked remote_execution: $reason");
    }
    
    # Register SubAgentOperations tool (blocked for sub-agents to prevent fork bombs)
    my $subagents_enabled = $self->{config} ? $self->{config}->get('enable_subagents') : 1;
    unless (($is_subagent && $blocked_for_subagent{'agent_operations'}) || !$subagents_enabled) {
        require CLIO::Tools::SubAgentOperations;
        $self->{tool_registry}->register_tool(
            CLIO::Tools::SubAgentOperations->new(debug => $self->{debug})
        );
    } else {
        my $reason = !$subagents_enabled ? "disabled in config" : "sub-agent restriction";
        log_debug('WorkflowOrchestrator', "Blocked agent_operations: $reason");
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
    
    # Protect against SIGPIPE from broken broker socket connections
    # This prevents crashes when the broker process dies or network fails
    local $SIG{PIPE} = 'IGNORE';
    
    # Extract callbacks
    my $on_chunk = $opts{on_chunk};
    my $on_system_message = $opts{on_system_message};  # Callback for system messages
    my $on_tool_call_from_ui = $opts{on_tool_call};  # Tool call tracker from UI
    my $on_tool_end_from_ui = $opts{on_tool_end};    # Tool end tracker from UI
    my $on_thinking = $opts{on_thinking};  # Callback for reasoning/thinking content
    
    # Build messages array (system prompt + history + user input) and tool definitions
    my ($messages_ref, $tools) = $self->_build_turn_context($user_input, $session);
    my @messages = @$messages_ref;
    
    # Main workflow loop
    my $iteration = 0;
    my @tool_calls_made = ();
    my $start_time = time();
    my $retry_count = 0;  # Track retries per iteration (prevents infinite loops)
    my $max_retries = 3;  # Maximum retries for API errors (malformed JSON, etc.)
    my $premature_stop_retries = 0;  # Track retries for premature workflow stops
    my $max_premature_stop_retries = 2;  # Max auto-retries for premature stops
    my $max_server_retries = 0;  # Infinite retries for server/network errors (0 = unlimited)
    my $max_rate_limit_retries = 0;  # Infinite retries for rate limits (0 = unlimited)
    
    # Session-level error budget: Limit total errors across all iterations
    # This prevents cascading failures from consuming the entire session
    my $session_error_count = $session->{_error_count} // 0;
    my $max_session_errors = 10;  # Hard limit per request processing
    
    # Wall-clock timeout for sub-agents (10 minutes)
    # Prevents sub-agents from running indefinitely on stuck API calls
    my $max_wall_time = $self->{broker_client} ? 600 : 0;  # 0 = no limit for interactive
    
    my $max_iter = $self->{max_iterations};
    while (!$max_iter || $iteration < $max_iter) {
        $iteration++;
        
        # Clear interrupt pending flag at start of each iteration
        $self->{_interrupt_pending} = 0;
        
        # Clear any stale user_interrupted session flag from a previous iteration.
        # This prevents the flag from being left over if an interrupt was partially
        # handled in a previous cycle (e.g. detected during streaming but the
        # _handle_interrupt path was skipped due to error recovery).
        if ($session && $session->state() && $session->state()->{user_interrupted}) {
            log_debug('WorkflowOrchestrator', "Clearing stale user_interrupted flag from previous iteration");
            $session->state()->{user_interrupted} = 0;
        }
        
        # Check wall-clock timeout (sub-agents only)
        if ($max_wall_time && (time() - $start_time) > $max_wall_time) {
            log_warning('WorkflowOrchestrator', "Wall-clock timeout reached (" . int((time() - $start_time)) . "s). Forcing exit.");
            return {
                success => 0,
                error => "Execution time limit reached (${max_wall_time}s). Partial results may be available.",
                iterations => $iteration,
                tool_calls_made => \@tool_calls_made
            };
        }
        
        # Capture process stats at iteration boundary
        $self->{process_stats}->capture('iteration_start', { iteration => $iteration })
            if $self->{process_stats};
        
        log_debug('WorkflowOrchestrator', "Iteration $iteration/$self->{max_iterations}");

        # Check for user interrupt (any keypress)
        if ($self->_check_for_user_interrupt($session)) {
            $self->_handle_interrupt($session, \@messages);
            # Don't count this iteration - interrupt handling is free
            $iteration--;
        }
        
        # Proactive trim: keep @messages within context budget BEFORE API call.
        # This is the single authoritative trim point. Previously, trimming only happened
        # inside APIManager on a copy, and the sync back to @messages only happened on
        # successful API calls. That meant @messages grew unbounded during tool execution
        # iterations, and when the API finally rejected with token_limit_exceeded, the
        # reactive trim had to drop hundreds of messages at once (e.g., 434).
        # Now @messages stays trim every iteration, so reactive trims are small.
        if ($self->{api_manager} && $iteration > 1) {
            my $pre_count = scalar(@messages);
            my $model = $self->{api_manager}->get_current_model();
            my $caps = $self->{api_manager}->get_model_capabilities($model);
            my $trimmed = validate_and_truncate(
                messages           => \@messages,
                model_capabilities => $caps,
                tools              => $tools,
                token_ratio        => $self->{api_manager}{learned_token_ratio},
                config             => $self->{api_manager}{config},
                api_base           => $self->{api_manager}{api_base},
                debug              => $self->{debug},
                model              => $model,
            );
            if ($trimmed && scalar(@$trimmed) < $pre_count) {
                # DIAGNOSTIC: Dump state before and after proactive trim (CLIO_TRIM_DIAG=1 to enable)
                _dump_diagnostic(
                    trigger     => 'trim',
                    phase       => 'proactive_before',
                    messages    => \@messages,
                    api_manager => $self->{api_manager},
                    iteration   => $iteration,
                    retry_count => $retry_count,
                    extra       => {
                        max_prompt_tokens => ($caps && $caps->{max_prompt_tokens}) || 'unknown',
                    },
                ) if $ENV{CLIO_TRIM_DIAG};
                @messages = @$trimmed;
                _dump_diagnostic(
                    trigger     => 'trim',
                    phase       => 'proactive_after',
                    messages    => \@messages,
                    api_manager => $self->{api_manager},
                    iteration   => $iteration,
                    retry_count => $retry_count,
                    extra       => {
                        original_count => $pre_count,
                        trimmed_to     => scalar(@messages),
                    },
                ) if $ENV{CLIO_TRIM_DIAG};
                log_info('WorkflowOrchestrator', "Proactive trim (pre-API): $pre_count -> " . scalar(@messages) . " messages");
            }
        }

        # Enforce message alternation for Claude compatibility
        # Must be done before EVERY API call, as messages array is modified during tool calling
        my $provider = $self->{api_manager}->get_current_provider() || 'github_copilot';
        my $alternated_messages = enforce_message_alternation(\@messages, $provider, debug => $self->{debug});
        
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
            # and allows interrupt detection within ~1 second during content generation
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
            my $error_class = classify_error($@);
            log_debug('WorkflowOrchestrator', "API error ($error_class): $@");
            return {
                success => 0,
                error => format_error($@, 'API request'),
                error_class => $error_class,
                iterations => $iteration,
                tool_calls_made => \@tool_calls_made
            };
        }
        
        # Check for API errors
        if (!$api_response || $api_response->{error}) {
            my $result = $self->_handle_api_error($api_response, {
                messages            => \@messages,
                retry_count         => \$retry_count,
                session_error_count => \$session_error_count,
                iteration           => $iteration,
                tool_calls_made     => \@tool_calls_made,
                session             => $session,
                on_system_message   => $on_system_message,
                max_retries         => $max_retries,
                max_server_retries  => $max_server_retries,
                max_session_errors  => $max_session_errors,
                max_rate_limit_retries => $max_rate_limit_retries,
            });

            # Fatal - propagate return value from process_input
            if (ref($result) eq 'HASH') {
                return $result;
            }

            # Retryable - don't count this as a real iteration
            if ($result eq 'retry') {
                $iteration--;
            }

            # Both 'retry' and 'continue' proceed to next loop iteration
            next;
        }
        
        # API call succeeded - reset retry counter and clear session error count
        $retry_count = 0;
        $self->{consecutive_errors} = 0;
        $self->{last_error} = '';
        $self->{_bad_request_escalations} = 0;
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
        
        # Accumulate performance metrics for /stats
        $self->_record_turn_metrics($api_response, $session);
        
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
        
        # Extract session naming marker from response content (regardless of tool calls)
        # The AI may include the marker in its first response alongside tool calls
        # Always strip the marker and always set the name (allows renaming during session)
        if ($session && $session->can('session_name')) {
            my $content = $api_response->{content} // '';
            if ($content =~ s/\s*<!--session:\{[^}]*"title"\s*:\s*"([^"]{3,80})"[^}]*\}-->\s*//s) {
                $api_response->{content} = $content;
                my $title = $1;
                $title =~ s/^\s+|\s+$//g;
                if (length($title) >= 3) {
                    $session->session_name($title);
                    log_info('WorkflowOrchestrator', "Session named by AI: $title");
                }
            }
        }

        if ($api_response->{tool_calls} && @{$api_response->{tool_calls}}) {
            my $tool_round = $self->_prepare_tool_round($api_response, \@messages, $session);
            unless ($tool_round) {
                next;  # All tool calls rejected - skip to next iteration
            }
            my @ordered_tool_calls = @{$tool_round->{ordered_tools}};
            my $assistant_msg_pending = $tool_round->{pending_msg};


            $self->_execute_tool_round(
                ordered_tools   => \@ordered_tool_calls,
                pending_msg     => \$assistant_msg_pending,
                messages        => \@messages,
                session         => $session,
                api_response    => $api_response,
                iteration       => $iteration,
                tool_calls_made => \@tool_calls_made,
                on_tool_end     => $on_tool_end_from_ui,
            );

            # Loop back - AI will process tool results
            next;
        }
        
        # No tool calls - check for premature workflow stop
        # 
        # PROBLEM: Upstream APIs sometimes return finish_reason=stop with empty or
        # minimal content when the model is mid-workflow (actively using tools).
        # This causes the workflow loop to exit prematurely, leaving work incomplete.
        # The user then has to spend another premium request to say "continue".
        #
        # DETECTION: If previous iterations executed tool calls (workflow was active)
        # and the current response has no tool calls AND empty/minimal content,
        # this is likely a premature stop - not a genuine final answer.
        #
        # RECOVERY: Inject a continuation nudge and retry, up to a limit.
        if (@tool_calls_made > 0 && $premature_stop_retries < $max_premature_stop_retries) {
            my $content = $api_response->{content} // '';
            my $content_length = length($content);
            
            # Heuristic: A genuine final answer after tool use typically has substance.
            # An empty or very short response after active tool calling is suspicious.
            # Also detect responses that end mid-sentence (no terminal punctuation).
            my $looks_premature = 0;
            
            if ($content_length == 0) {
                # Completely empty response after tool calls - definitely premature
                $looks_premature = 1;
                log_info('WorkflowOrchestrator', "Premature stop detected: empty response after " . scalar(@tool_calls_made) . " tool calls");
            }
            
            if ($looks_premature) {
                $premature_stop_retries++;
                log_debug('WorkflowOrchestrator', "Premature workflow stop detected (retry $premature_stop_retries/$max_premature_stop_retries). Nudging model to continue.");
                
                # Save any partial content as assistant message
                if ($content_length > 0) {
                    push @messages, {
                        role => 'assistant',
                        content => $content,
                    };
                }
                
                # Inject a system-level continuation nudge
                push @messages, {
                    role => 'user',
                    content => "[SYSTEM: Your previous response ended without completing your work. " .
                               "You were actively using tools and appear to have stopped mid-workflow. " .
                               "Please continue where you left off - review your recent tool results and proceed with your plan.]"
                };
                
                # Don't count this as a full iteration
                $iteration--;
                next;
            }
        }
        
        # Reset premature stop counter on genuine completion
        $premature_stop_retries = 0;
        
        # AI has final answer
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
        
        # Extract session naming marker before any other cleanup
        # The AI includes <!--session:{"title":"..."}--> in its first response
        # Always strip the marker and always set the name (allows renaming during session)
        if ($session && $session->can('session_name')) {
            if ($final_content =~ s/\s*<!--session:\{[^}]*"title"\s*:\s*"([^"]{3,80})"[^}]*\}-->\s*//s) {
                my $title = $1;
                $title =~ s/^\s+|\s+$//g;
                if (length($title) >= 3) {
                    $session->session_name($title);
                    log_info('WorkflowOrchestrator', "Session named by AI: $title");
                }
            }
        }

        # Remove conversation tags if present
        $final_content =~ s/^\[conversation\]//;
        $final_content =~ s/\[\/conversation\]$//;
        $final_content =~ s/^\s+|\s+$//g;
        
        # Save the final assistant text response to session history.
        # During tool-calling workflows, _execute_tool_round saves intermediate
        # assistant+tool message pairs. But the FINAL text-only response (the one
        # that ends the loop) is not saved there - it exits through here.
        # Without this save, the final message is streamed to screen but never
        # persisted, causing context loss on the next turn.
        if (@tool_calls_made > 0 && length($final_content) > 0 && $session && $session->can('add_message')) {
            eval {
                my $sanitized = sanitize_text($final_content);
                $session->add_message('assistant', $sanitized);
                log_debug('WorkflowOrchestrator', "Saved final assistant response to session (" . length($sanitized) . " chars)");
            };
            if ($@) {
                log_warning('WorkflowOrchestrator', "Failed to save final assistant response: $@");
            }
        }

        # Build result hash
        my $result = {
            success => 1,
            content => $final_content,
            iterations => $iteration,
            tool_calls_made => \@tool_calls_made,
            elapsed_time => $elapsed_time,
            # All messages (including the final response above) are now saved during
            # workflow execution. This flag prevents Chat.pm from saving duplicates.
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
        "Iteration limit (%d) reached after %.1fs. " .
        "To remove the limit, run: /api set max_iterations 0",
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

=head2 _build_turn_context($user_input, $session)

Build the messages array and tool definitions for a new turn.
Handles vault snapshot, system prompt, history loading/trimming,
user message injection, and MCP tool merging.

Returns: ($messages_arrayref, $tools_arrayref)

=cut

sub _build_turn_context {
    my ($self, $user_input, $session) = @_;

    # Start a new vault turn before processing
    if ($self->{file_vault}) {
        my $turn_snapshot = eval { $self->{file_vault}->start_turn($user_input) };
        if ($turn_snapshot) {
            if ($session && ref($session) && $session->can('state')) {
                my $state = $session->state();
                $state->{last_turn_id} = $turn_snapshot;
                $state->{turn_history} ||= [];
                push @{$state->{turn_history}}, {
                    turn_id => $turn_snapshot,
                    timestamp => time(),
                    user_input => substr($user_input, 0, 100),
                };
                if (@{$state->{turn_history}} > 20) {
                    splice(@{$state->{turn_history}}, 0, @{$state->{turn_history}} - 20);
                }
            }
            $self->{tool_executor}{file_vault} = $self->{file_vault};
            $self->{tool_executor}{vault_turn_id} = $turn_snapshot;
            log_debug('WorkflowOrchestrator', "FileVault turn started: $turn_snapshot");
        } elsif ($@) {
            log_debug('WorkflowOrchestrator', "FileVault turn start failed: $@");
        }
    }

    log_debug('WorkflowOrchestrator', "Processing input: '$user_input'");

    # Build messages: system prompt + history + user input
    my @messages = ();

    my $system_prompt = $self->{prompt_builder}->build_system_prompt($session);
    push @messages, { role => 'system', content => $system_prompt };
    log_debug('WorkflowOrchestrator', "Added system prompt with tools (" . length($system_prompt) . " chars)");

    inject_context_files($session, \@messages, debug => $self->{debug});

    my $history = load_conversation_history($session, debug => $self->{debug});

    if ($history && @$history) {
        my $model_caps = {};
        if ($self->{api_manager}) {
            $model_caps = $self->{api_manager}->get_model_capabilities() || {};
        }
        $history = trim_conversation_for_api(
            $history,
            $system_prompt,
            model_context_window => $model_caps->{max_context_window_tokens} // 128000,
            max_response_tokens  => $model_caps->{max_output_tokens} // 16000,
            debug => $self->{debug},
        );
    }

    if ($history && @$history) {
        push @messages, @$history;
        log_debug('WorkflowOrchestrator', "Loaded " . scalar(@$history) . " messages from history (after pre-flight trim)");
    }

    push @messages, { role => 'user', content => $user_input };

    # Save user message to session history NOW (before processing)
    if ($session && $session->can('add_message')) {
        $session->add_message('user', $user_input);
        log_debug('WorkflowOrchestrator', "Saved user message to session history");
    }

    # Build tool definitions
    my $tools = $self->{tool_registry}->get_tool_definitions();

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

    return (\@messages, $tools);
}

=head2 _capture_file_before

Snapshot file content before a write operation so we can show diffs after.

Returns a hashref with captured file paths and content, or undef if
not a diff-eligible operation.

=cut

# Operations that modify files and should show diffs
my %DIFF_OPERATIONS = (
    'file_operations' => {
        'write_file'           => 'path',
        'replace_string'       => 'path',
        'multi_replace_string' => 'replacements',
        'append_file'          => 'path',
        'insert_at_line'       => 'path',
    },
);

# Execute a round of tool calls: flush UI, iterate tools, save results.
#
# Called after _prepare_tool_round returns the ordered tool list.
# Handles: interrupt checks, UI headers/transitions, diff display,
# error enhancement, session persistence (atomic assistant+tool saves),
# and periodic checkpoints.
#
# Args (hash):
#   ordered_tools  => \@ordered_tool_calls
#   pending_msg    => \$assistant_msg_pending  (scalar ref - cleared on first save)
#   messages       => \@messages               (arrayref - pushed to)
#   session        => $session                 (object or undef)
#   api_response   => $api_response            (for content)
#   iteration      => $iteration               (integer)
#   tool_calls_made => \@tool_calls_made       (arrayref - pushed to)
#   on_tool_end    => $callback                (coderef or undef)
#
sub _execute_tool_round {
    my ($self, %args) = @_;

    my $ordered_tools   = $args{ordered_tools};
    my $pending_msg_ref = $args{pending_msg};     # scalar ref
    my $messages        = $args{messages};         # arrayref
    my $session         = $args{session};
    my $api_response    = $args{api_response};
    my $iteration       = $args{iteration};
    my $tool_calls_made = $args{tool_calls_made};  # arrayref
    my $on_tool_end     = $args{on_tool_end};

    # Flush UI streaming buffer BEFORE executing any tools
    if ($self->{ui} && $self->{ui}->can('flush_output_buffer')) {
        log_debug('WorkflowOrchestrator', "Flushing UI buffer before tool execution");
        $self->{ui}->flush_output_buffer();
    }
    STDOUT->flush() if STDOUT->can('flush');
    $| = 1;

    # Signal tool execution mode to UI
    $self->{ui}->begin_tool_execution() if $self->{ui};

    # Pre-analyze tool calls to know how many of each tool type will execute
    my %tool_call_count;
    foreach my $i (0..$#$ordered_tools) {
        my $tool = $ordered_tools->[$i]->{function}->{name} || 'unknown';
        $tool_call_count{$tool}++;
    }

    my $first_tool_call = 1;
    my $current_tool = '';

    for my $i (0..$#$ordered_tools) {
        # Check for user interrupt between tool executions
        if ($self->{_interrupt_pending} || $self->_check_and_handle_interrupt($session, $messages)) {
            log_info('WorkflowOrchestrator', "Interrupt detected between tool executions, skipping remaining tools");
            last;
        }

        my $tool_call = $ordered_tools->[$i];
        my $tool_name = $tool_call->{function}->{name} || 'unknown';
        my $tool_display_name = uc($tool_name);
        $tool_display_name =~ s/_/ /g;

        log_debug('WorkflowOrchestrator', "Executing tool: $tool_name");

        # Handle first tool call: stop spinner, display unstreamed content
        if ($first_tool_call) {
            if ($self->{spinner} && $self->{spinner}->can('stop')) {
                $self->{spinner}->stop();
                log_debug('WorkflowOrchestrator', "Stopped spinner before tool output");
            }

            my $content = $api_response->{content} // '';
            $content =~ s/^\s+|\s+$//g;
            log_debug('WorkflowOrchestrator', "First tool call - content: '" . substr($content, 0, 100) . "'");
            
            # If the model sent text content alongside tool_calls but streaming
            # didn't deliver it (or no streaming callback), display it now
            if (length($content) > 0 && $self->{ui}) {
                my $already_streamed = 0;
                if ($self->{ui}->can('streaming_controller')) {
                    my $sc = $self->{ui}->streaming_controller();
                    $already_streamed = $sc && $sc->first_chunk_received();
                }
                if (!$already_streamed) {
                    $self->{ui}->display_assistant_message($content);
                    print "\n";
                }
            }
            
            $first_tool_call = 0;
        }

        # Handle tool group transitions (new tool type starting)
        my $is_inline = ($self->{formatter}->get_tool_format() eq 'inline');
        my $tool_changed = ($tool_name ne $current_tool);
        
        if ($tool_changed) {
            $self->{ui}->clear_system_message_flag() if $self->{ui};
        }
        
        # Parse tool arguments early (needed for suppress_display and pre-action)
        my $tool_args = eval { decode_json($tool_call->{function}->{arguments} || '{}') };
        my $tool_operation = ($tool_args && $tool_args->{operation}) ? $tool_args->{operation} : '';
        
        # Skip display for internal-only operations and self-displaying tools
        my $suppress_display = ($tool_name eq 'terminal_operations' && $tool_operation eq 'validate')
                            || ($tool_name eq 'user_collaboration');
        
        # In inline mode, show a bullet for every tool call.
        # In box mode, only show header on tool group transitions.
        if (!$suppress_display && ($is_inline || $tool_changed)) {
            my $is_first_tool = ($current_tool eq '' && !$is_inline) || ($i == 0);
            my $is_continuation = ($is_inline && !$tool_changed && $current_tool ne '');
            $self->{formatter}->display_tool_header($tool_name, $tool_display_name, $is_first_tool, $is_continuation);
            $current_tool = $tool_name;
        }

        # For terminal_operations: show the command BEFORE execution
        my $pre_action_printed = 0;
        if ($tool_name eq 'terminal_operations' && !$suppress_display) {
            my $cmd_preview = ($tool_args && $tool_args->{command}) ? $tool_args->{command} : undef;
            if ($cmd_preview) {
                $self->{formatter}->display_action_detail($cmd_preview, 0, 0);
                $pre_action_printed = 1;
            }
        }
        # For apply_patch: extract file list from patch text for pre-action
        elsif ($tool_name eq 'apply_patch' && $tool_args && $tool_args->{patch}) {
            my @files;
            while ($tool_args->{patch} =~ /\*\*\* (?:Add|Update|Delete) File:\s*(.+)/g) {
                push @files, $1;
            }
            if (@files) {
                my $preview = @files == 1 ? $files[0] : scalar(@files) . " files";
                $self->{formatter}->display_action_detail("patching $preview", 0, 0);
                $pre_action_printed = 1;
            }
        }

        # Capture file state before write operations for diff display
        my $diff_before = $self->_capture_file_before($tool_name, $tool_operation, $tool_args);

        # Execute tool
        my $tool_result = $self->_execute_tool($tool_call);

        # Notify UI that tool execution is complete
        if ($on_tool_end) {
            eval { $on_tool_end->($tool_name); };
        }

        # Extract action_description from tool result
        my $action_detail = '';
        my $result_data;
        my $is_error = 0;
        my $enhanced_error_for_ai = '';
        if ($tool_result) {
            $result_data = eval {
                ref($tool_result) eq 'HASH' ? $tool_result : decode_json($tool_result);
            };
            if ($result_data && ref($result_data) eq 'HASH') {
                if (exists $result_data->{success} && !$result_data->{success}) {
                    $is_error = 1;
                    my $error_msg = $result_data->{error} || 'Unknown error';
                    my $error_prefix = $tool_operation ? "$tool_operation: " : '';
                    $action_detail = $error_prefix . $self->{formatter}->format_error($error_msg);

                    # Enhanced error with schema guidance
                    my $tool_obj = $self->{tool_registry}->get_tool($tool_name);
                    my $tool_def = undef;
                    if ($tool_obj && $tool_obj->can('get_tool_definition')) {
                        $tool_def = $tool_obj->get_tool_definition();
                    }

                    my $attempted_params = {};
                    if ($tool_call->{function}->{arguments}) {
                        eval { $attempted_params = decode_json($tool_call->{function}->{arguments}); };
                    }

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

        # Fallback: if no action_detail, build one from tool args
        # Skip if pre-action was already printed (e.g. terminal_operations command)
        if (!$action_detail && $is_inline && !$pre_action_printed) {
            if ($tool_operation) {
                # Include key context args (path, host, query, etc.)
                my $ctx = '';
                for my $key (qw(path host query url pattern key name)) {
                    if ($tool_args && $tool_args->{$key}) {
                        $ctx = $tool_args->{$key};
                        last;
                    }
                }
                $action_detail = $ctx ? "$tool_operation: $ctx" : $tool_operation;
            } elsif ($tool_name eq 'apply_patch') {
                $action_detail = 'applying patch';
            }
        }

        # Display action detail
        my $printed_action = 0;
        # For tools with pre-action printed (apply_patch), convert the result's
        # action_description into expanded_content for proper hrule formatting
        if ($pre_action_printed && $action_detail && !$suppress_display && $tool_name eq 'apply_patch') {
            my $expanded_content;
            if ($result_data && ref($result_data) eq 'HASH') {
                $expanded_content = $result_data->{expanded_content} || [];
            }
            $expanded_content ||= [];
            # Use action_detail as expanded content line
            unshift @$expanded_content, $action_detail;
            $self->{formatter}->display_expanded_content($expanded_content);
            $printed_action = 1;
            $action_detail = undef;
        }
        elsif ($action_detail && !$suppress_display) {
            my $remaining_same_tool = 0;
            # In inline mode, each call has its own bullet, so remaining is 0
            if (!$is_inline) {
                for my $j ($i+1..$#$ordered_tools) {
                    if ($ordered_tools->[$j]->{function}->{name} eq $tool_name) {
                        $remaining_same_tool++;
                    }
                }
            }

            my $expanded_content;
            if ($result_data && ref($result_data) eq 'HASH') {
                $expanded_content = $result_data->{expanded_content};
            }

            $self->{formatter}->display_action_detail($action_detail, $is_error, $remaining_same_tool, $expanded_content);
            $printed_action = 1;
        }

        # For tools that printed before execution (terminal_operations), show
        # expanded_content from the result (captured command output)
        if (!$printed_action && $pre_action_printed && $result_data && ref($result_data) eq 'HASH') {
            my $expanded_content = $result_data->{expanded_content};
            if ($expanded_content && ref($expanded_content) eq 'ARRAY' && @$expanded_content) {
                $self->{formatter}->display_expanded_content($expanded_content);
            }
        }

        # In inline mode, if no action detail was printed after the header,
        # close the line so the next tool header starts on a new line
        if ($is_inline && !$printed_action && !$pre_action_printed) {
            print "\n";
            STDOUT->flush() if STDOUT->can('flush');
        }

        # Display diff for file-writing operations
        if ($diff_before && !$is_error) {
            # Skip opening hrule if expanded_content with hrules was just displayed
            my $skip_open = ($tool_name eq 'apply_patch' && $printed_action);
            $self->_display_file_diff($diff_before, $tool_name, $tool_operation, $tool_args,
                $skip_open ? { skip_opening_hrule => 1 } : undef);
        }

        # Extract output for the AI
        my $ai_content = $tool_result;
        if ($is_error && $enhanced_error_for_ai) {
            $ai_content = $enhanced_error_for_ai;
        } elsif ($result_data && ref($result_data) eq 'HASH' && exists $result_data->{output}) {
            $ai_content = $result_data->{output};
        }

        # Track tool calls made
        push @$tool_calls_made, {
            name => $tool_name,
            arguments => $tool_call->{function}->{arguments},
            result => $ai_content
        };

        # Sanitize tool result content
        my $sanitized_content = sanitize_text($ai_content);
        $sanitized_content = "$sanitized_content" if defined $sanitized_content;

        # Add tool result to conversation
        push @$messages, {
            role => 'tool',
            tool_call_id => $tool_call->{id},
            name => $tool_name,
            content => $sanitized_content
        };

        # Save tool result to session (atomic with assistant message on first result)
        if ($session && $session->can('add_message')) {
            eval {
                if ($$pending_msg_ref) {
                    $session->add_message(
                        'assistant',
                        $$pending_msg_ref->{content},
                        { tool_calls => $$pending_msg_ref->{tool_calls} }
                    );
                    log_debug('WorkflowOrchestrator', "Saved assistant message with tool_calls to session (on first tool result)");
                    $$pending_msg_ref = undef;
                }

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

    # Signal end of tool execution to UI
    $self->{ui}->end_tool_execution() if $self->{ui};

    # Capture process stats after tool execution phase
    $self->{process_stats}->capture('after_tools', {
        iteration => $iteration,
        tool_count => scalar(@$ordered_tools),
    }) if $self->{process_stats};

    # Reset UI streaming state for next iteration
    if ($self->{ui} && $self->{ui}->can('reset_streaming_state')) {
        log_debug('WorkflowOrchestrator', "Resetting UI streaming state for next iteration");
        $self->{ui}->reset_streaming_state();
    }

    $self->{ui}->prepare_for_iteration() if $self->{ui};

    # Save session after each iteration
    if ($session && $session->can('save')) {
        eval {
            $session->save();
            log_debug('WorkflowOrchestrator', "Session saved after iteration $iteration (preserving tool execution history)");
        };
        if ($@) {
            log_warning('WorkflowOrchestrator', "Failed to save session after iteration: $@");
        }
    }

    # Checkpoint session progress to memory every 15 iterations
    if ($iteration % 15 == 0 && $session) {
        _checkpoint_session_progress($session, $tool_calls_made, $iteration, $messages);
    }

    # Print newline to separate tool output from next iteration
    # Skip if last tool was user_collaboration (its output already provides separation)
    my $last_tool = @$ordered_tools ? ($ordered_tools->[-1]->{function}->{name} || '') : '';
    if ($last_tool ne 'user_collaboration') {
        print "\n";
        STDOUT->flush() if STDOUT->can('flush');
    }
}


# Validate, classify, and order tool calls from an API response.
#
# Performs:
#   1. JSON validation on each tool_call argument string
#   2. JSON repair for common malformations
#   3. Tool alias resolution (e.g., 'file_search' -> 'file_operations')
#   4. Argument parsing with Anthropic XML detection
#   5. Classification into blocking/serial/parallel categories
#   6. Ordering: other blocking -> serial -> parallel -> user_collaboration (last)
#
# Args:
#   $api_response - API response hashref with tool_calls array
#   $messages     - arrayref of conversation messages (may be appended to)
#   $session      - session object (for saving error results) or undef
#
# Returns:
#   undef - all tool calls rejected; caller should skip to next iteration
#   hashref with:
#     ordered_tools => \@ordered_tool_calls  (tool calls in execution order)
#     pending_msg   => $assistant_msg_pending (assistant message to save on first result)
#
sub _prepare_tool_round {
    my ($self, $api_response, $messages, $session) = @_;

    # ── Phase 1: Validate tool_call argument JSON ────────────────────
    my @validated_tool_calls = ();
    my $had_validation_errors = 0;

    for my $tool_call (@{$api_response->{tool_calls}}) {
        my $tool_name = $tool_call->{function}->{name} || 'unknown';
        my $arguments_str = $tool_call->{function}->{arguments} || '{}';

        my $arguments_valid = 0;
        eval {
            use CLIO::Util::JSON qw(decode_json);
            use Encode qw(encode_utf8);
            my $json_bytes = utf8::is_utf8($arguments_str) ? encode_utf8($arguments_str) : $arguments_str;
            my $parsed = decode_json($json_bytes);
            $arguments_valid = 1;
        };

        if ($@) {
            my $error = $@;
            my $repaired = repair_tool_call_json($arguments_str, debug => $self->{debug});

            if ($repaired) {
                log_debug('WorkflowOrchestrator', "Repaired malformed JSON for tool '$tool_name'");
                $tool_call->{function}->{arguments} = $repaired;
                push @validated_tool_calls, $tool_call;
            } else {
                $had_validation_errors = 1;
                log_debug('WorkflowOrchestrator', "Invalid JSON in tool call arguments for '$tool_name': $error");
                log_debug('WorkflowOrchestrator', "Malformed arguments: " . substr($arguments_str, 0, 200));
                log_debug('WorkflowOrchestrator', "Could not repair JSON for tool '$tool_name' - tool call will be skipped");

                push @$messages, {
                    role => 'tool',
                    tool_call_id => $tool_call->{id},
                    name => $tool_name,
                    content => "ERROR: Tool call rejected due to invalid JSON in arguments. The AI generated malformed parameters that could not be parsed. Please retry with valid JSON."
                };
            }
        } else {
            push @validated_tool_calls, $tool_call;
        }
    }

    $api_response->{tool_calls} = \@validated_tool_calls;

    # All tool calls rejected
    if (@validated_tool_calls == 0) {
        log_debug('WorkflowOrchestrator', "All tool calls were rejected due to invalid JSON - skipping tool execution");
        push @$messages, {
            role => 'assistant',
            content => $api_response->{content} || "I encountered an error with my tool calls. Let me try a different approach."
        };
        return undef;
    }

    log_debug('WorkflowOrchestrator', "Processing " . scalar(@validated_tool_calls) . " validated tool calls" .
        ($had_validation_errors ? " (some were rejected/repaired)" : "") . "\n");

    # ── Phase 2: Build assistant message ──────────────────────────────
    my $assistant_msg = {
        role => 'assistant',
        content => $api_response->{content},
        tool_calls => \@validated_tool_calls
    };
    if ($api_response->{reasoning_details}) {
        $assistant_msg->{reasoning_details} = $api_response->{reasoning_details};
    }
    push @$messages, $assistant_msg;

    # Delayed save: assistant message saved with first tool result to prevent orphans
    my $assistant_msg_pending = {
        role => 'assistant',
        content => $api_response->{content} // '',
        tool_calls => \@validated_tool_calls
    };
    if ($api_response->{reasoning_details}) {
        $assistant_msg_pending->{reasoning_details} = $api_response->{reasoning_details};
    }

    log_debug('WorkflowOrchestrator', "Delaying save of assistant message with tool_calls until first tool result completes");

    # ── Phase 3: Resolve aliases and classify tools ───────────────────
    my @blocking_tools = ();
    my @serial_tools = ();
    my @parallel_tools = ();

    for my $tool_call (@{$api_response->{tool_calls}}) {
        my $tool_name = $tool_call->{function}->{name} || 'unknown';

        # Resolve tool aliases
        my $alias_info = $self->{tool_registry}->get_alias_info($tool_name);
        if ($alias_info) {
            log_debug('WorkflowOrchestrator', "Alias detected: '$tool_name' -> '$alias_info->{tool}' with operation='$alias_info->{operation}'");
            $tool_call->{function}->{name} = $alias_info->{tool};
            $tool_name = $alias_info->{tool};

            my $args_str = $tool_call->{function}->{arguments};
            if ($args_str) {
                eval {
                    my $args = decode_json($args_str);
                    unless (exists $args->{operation}) {
                        $args->{operation} = $alias_info->{operation};
                        $tool_call->{function}->{arguments} = encode_json($args);
                        log_debug('WorkflowOrchestrator', "Injected operation='$alias_info->{operation}' into args");
                    }
                };
            } else {
                $tool_call->{function}->{arguments} = encode_json({ operation => $alias_info->{operation} });
                log_debug('WorkflowOrchestrator', "Created args with operation='$alias_info->{operation}'");
            }
        }

        my $tool = $self->{tool_registry}->get_tool($tool_name);

        # Parse arguments for classification
        my $params = {};
        if ($tool_call->{function}->{arguments}) {
            eval {
                my $json_str = $tool_call->{function}->{arguments};

                if ($self->{debug}) {
                    my $preview = substr($json_str, 0, 300);
                    log_debug('WorkflowOrchestrator', "Original arguments (first 300 chars): $preview");
                }

                if (is_anthropic_xml_format($json_str)) {
                    log_info('WorkflowOrchestrator', "Detected Anthropic XML format, converting to JSON");
                    $json_str = parse_anthropic_xml_to_json($json_str, $self->{debug});
                    log_debug('WorkflowOrchestrator', "Converted XML to JSON: " . substr($json_str, 0, 300));
                } else {
                    $json_str = repair_malformed_json($json_str, $self->{debug});
                    if ($self->{debug}) {
                        my $preview = substr($json_str, 0, 300);
                        log_debug('WorkflowOrchestrator', "Repaired JSON arguments (first 300 chars): $preview");
                    }
                }

                my $json_bytes = encode_utf8($json_str);
                $params = decode_json($json_bytes);
            };
            if ($@) {
                my $error = $@;
                my $args_full = $tool_call->{function}->{arguments} || '';

                log_error('WorkflowOrchestrator', "Failed to parse arguments for tool '$tool_name': $error");
                log_error('WorkflowOrchestrator', "Full arguments:\n$args_full");

                my $error_message = "JSON parsing failed for tool '$tool_name': $error\nArguments received:\n$args_full";

                push @$messages, {
                    role => 'tool',
                    tool_call_id => $tool_call->{id},
                    name => $tool_name,
                    content => $error_message
                };

                if ($session && $session->can('add_message')) {
                    eval {
                        if ($assistant_msg_pending) {
                            $session->add_message(
                                'assistant',
                                $assistant_msg_pending->{content},
                                { tool_calls => $assistant_msg_pending->{tool_calls} }
                            );
                            log_debug('WorkflowOrchestrator', "Saved assistant message with tool_calls to session (on error result)");
                            $assistant_msg_pending = undef;
                        }
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
                next;
            }
        }

        # Determine interactive status (parameter overrides metadata)
        my $is_interactive = 0;
        if (exists $params->{isInteractive}) {
            $is_interactive = $params->{isInteractive} ? 1 : 0;
            log_debug('WorkflowOrchestrator', "Tool $tool_name isInteractive parameter: $is_interactive");
        } elsif ($tool && $tool->{is_interactive}) {
            $is_interactive = 1;
            log_debug('WorkflowOrchestrator', "Tool $tool_name default is_interactive: $is_interactive");
        }

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
            push @parallel_tools, $tool_call;
            log_warning('WorkflowOrchestrator', "Unknown tool $tool_name, treating as PARALLEL");
        }
    }

    # ── Phase 4: Order for execution ──────────────────────────────────
    # user_collaboration always last
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

    my @ordered_tool_calls = (@other_blocking_tools, @serial_tools, @parallel_tools, @user_collaboration_tools);

    log_debug('WorkflowOrchestrator', "Execution order: " . scalar(@other_blocking_tools) . " other blocking, " .
        scalar(@serial_tools) . " serial, " .
        scalar(@parallel_tools) . " parallel, " .
        scalar(@user_collaboration_tools) . " user_collaboration (LAST)\n");

    return {
        ordered_tools => \@ordered_tool_calls,
        pending_msg   => $assistant_msg_pending,
    };
}



# Extracted from process_input error handling block (lines 701-1430).
# Handles API errors: retryable (rate limit, server, token limit) and non-retryable.
#
# Args:
#   $api_response - the failed API response hashref
#   $ctx          - shared context hash with scalar refs for mutables:
#       messages            => \@messages       (arrayref, modified in place)
#       retry_count         => \$retry_count    (scalar ref, incremented/reset)
#       session_error_count => \$session_error_count (scalar ref)
#       iteration           => $iteration       (read-only integer)
#       tool_calls_made     => \@tool_calls_made (arrayref, read-only)
#       session             => $session          (object or undef)
#       on_system_message   => $callback         (coderef or undef)
#       max_retries         => $max_retries
#       max_server_retries  => $max_server_retries
#       max_session_errors  => $max_session_errors
#
# Returns:
#   'retry'    - retryable error handled; caller should decrement $iteration and next
#   'continue' - non-retryable error handled; caller should just next
#   hashref    - fatal error; caller should return this hashref from process_input
sub _handle_api_error {
    my ($self, $api_response, $ctx) = @_;

    my $messages            = $ctx->{messages};
    my $retry_count_ref     = $ctx->{retry_count};
    my $session_error_ref   = $ctx->{session_error_count};
    my $iteration           = $ctx->{iteration};
    my $tool_calls_made     = $ctx->{tool_calls_made};
    my $session             = $ctx->{session};
    my $on_system_message   = $ctx->{on_system_message};
    my $max_retries         = $ctx->{max_retries};
    my $max_server_retries  = $ctx->{max_server_retries};
    my $max_session_errors  = $ctx->{max_session_errors};

    my $max_rate_limit_retries = $ctx->{max_rate_limit_retries} // 0;

    my $error = $api_response->{error} || "Unknown API error";

    # ── Retryable errors ──────────────────────────────────────────────
    if ($api_response->{retryable}) {
        $$retry_count_ref++;

        # Escalate repeated bare 400s to context trim
        my $error_type_check = $api_response->{error_type} || '';
        if ($error_type_check eq 'bad_request' && $$retry_count_ref >= 2) {
            $self->{_bad_request_escalations} = ($self->{_bad_request_escalations} || 0) + 1;

            if ($self->{_bad_request_escalations} <= 1) {
                log_warning('WorkflowOrchestrator', "Repeated 400 Bad Request ($$retry_count_ref attempts) - escalating to context trim (escalation #$self->{_bad_request_escalations})");
                $api_response->{error_type} = 'token_limit_exceeded';
            } else {
                log_error('WorkflowOrchestrator', "Persistent 400 Bad Request after $self->{_bad_request_escalations} context trim attempts ($$retry_count_ref total retries). Giving up.");

                _dump_diagnostic(
                    trigger      => 'persistent_400',
                    messages     => $messages,
                    api_manager  => $self->{api_manager},
                    iteration    => $iteration,
                    retry_count  => $$retry_count_ref,
                    error        => $error,
                    api_response => $api_response,
                    append       => 1,
                    extra        => { escalations => $self->{_bad_request_escalations} },
                );

                return {
                    success         => 0,
                    error           => "Persistent 400 Bad Request from API after $$retry_count_ref retries and $self->{_bad_request_escalations} context trims. The API backend may be experiencing issues. Diagnostic dump written to /tmp/clio_diag_persistent_400.log. Try again in a few minutes, or use a different model.",
                    iterations      => $iteration,
                    tool_calls_made => $tool_calls_made,
                };
            }
        }

        # Determine retry limit based on error type
        my $error_type_for_limit = $api_response->{error_type} || '';
        my $retry_limit;
        my $allow_infinite_retry = 0;
        if ($error_type_for_limit eq 'rate_limit') {
            $retry_limit = $max_rate_limit_retries;
            $allow_infinite_retry = 1 if $max_rate_limit_retries == 0;
        } elsif ($error_type_for_limit eq 'server_error' || $error_type_for_limit eq 'connection_error') {
            $retry_limit = $max_server_retries;
            $allow_infinite_retry = 1 if $max_server_retries == 0;
        } elsif ($error_type_for_limit eq 'bad_request') {
            $retry_limit = 4;
        } else {
            $retry_limit = $max_retries;
        }

        # Skip retry limit check for rate limits when infinite retry is enabled
        if (!$allow_infinite_retry && $$retry_count_ref > $retry_limit) {
            log_error('WorkflowOrchestrator', "Maximum retries ($retry_limit) exceeded for this iteration");
            return {
                success         => 0,
                error           => "Maximum retries exceeded: $error",
                iterations      => $iteration,
                tool_calls_made => $tool_calls_made,
            };
        }

        my $retry_delay = $api_response->{retry_after} || 2;
        my $error_type  = $error =~ /rate limit/i ? "rate limit" : "server error";

        # Add 1s buffer for rate limits
        if ($api_response->{error_type} && $api_response->{error_type} eq 'rate_limit' && $retry_delay > 0) {
            $retry_delay += 1;
        }

        # Format retry count display (show ∞ for infinite retries)
        my $retry_display = $allow_infinite_retry ? ui_char('infinity') : $retry_limit;
        my $system_msg = "Temporary $error_type detected. Retrying in ${retry_delay}s... (attempt $$retry_count_ref" . ($allow_infinite_retry ? "" : "/$retry_display") . ")";

        # ── Per-error-type handling ──
        if ($api_response->{error_type} && $api_response->{error_type} eq 'unsupported_param') {
            $error_type  = "unsupported parameter";
            $system_msg  = undef;
            $retry_delay = 0;
            log_info('WorkflowOrchestrator', "Retrying without unsupported parameter");
        }
        elsif ($api_response->{error_type} && $api_response->{error_type} eq 'bad_request') {
            $system_msg = undef;
            log_info('WorkflowOrchestrator', "API 400 Bad Request - retrying silently (attempt $$retry_count_ref)");
        }
        elsif ($api_response->{error_type} && $api_response->{error_type} eq 'malformed_tool_json') {
            if ($$retry_count_ref == 1) {
                # First attempt: remove bad message, provide schema guidance
                if (@$messages && $messages->[-1]{role} eq 'assistant') {
                    pop @$messages;
                    log_info('WorkflowOrchestrator', "Removed malformed assistant message from history");
                }

                my $failed_tool_name = $api_response->{failed_tool} || 'unknown';
                my $tool_schema      = '';

                if ($failed_tool_name ne 'unknown') {
                    my $tool_def = $self->{tool_registry}->get_tool($failed_tool_name);
                    if ($tool_def) {
                        my $params = $tool_def->{function}{parameters};
                        if ($params) {
                            require JSON::PP;
                            $tool_schema = "\n\nCorrect schema for $failed_tool_name:\n" .
                                           JSON::PP->new->pretty->encode($params);
                        }
                    }
                }

                my $tool_guidance = _get_tool_specific_guidance($failed_tool_name);

                push @$messages, {
                    role    => 'system',
                    content => "ERROR: Your previous tool call had invalid JSON parameters.\n\n" .
                               "Common issues:\n" .
                               "- Missing parameter values (e.g., \"offset\":, instead of \"offset\":0)\n" .
                               "- Unescaped quotes in strings\n" .
                               "- Trailing commas\n" .
                               "- Missing required parameters\n\n" .
                               "ALL parameters must have valid values - no empty/missing values permitted.\n" .
                               "$tool_schema\n\n" .
                               "${tool_guidance}" .
                               "Please retry the operation with correct JSON, or try a different approach if the tool call isn't critical.",
                };

                $error_type = "malformed tool JSON";
                $system_msg = "AI generated invalid JSON parameters. Removed bad message, adding guidance and retrying... (attempt $$retry_count_ref/$max_retries)";
                log_info('WorkflowOrchestrator', "Added JSON formatting guidance for tool: $failed_tool_name");
            }
            else {
                # Second attempt failed: let agent recover
                if (@$messages && $messages->[-1]{role} eq 'assistant') {
                    pop @$messages;
                    log_info('WorkflowOrchestrator', "Removed second malformed assistant message");
                }

                push @$messages, {
                    role    => 'system',
                    content => "TOOL CALL FAILED: The previous tool call still had invalid JSON after correction attempt. " .
                               "The tool call has been removed from history. You can:\n" .
                               "1. Try a different approach to accomplish the same goal\n" .
                               "2. Continue with other work\n" .
                               "3. Ask the user for clarification if needed\n\n" .
                               "Your conversation context is preserved - continue your work.",
                };

                $$retry_count_ref = 0;
                log_warning('WorkflowOrchestrator', "Malformed JSON persisted - agent informed, continuing workflow");
                return 'retry';  # Don't decrement iteration, just continue
            }
        }
        elsif ($api_response->{error_type} && $api_response->{error_type} eq 'token_limit_exceeded') {
            my $trim_result = $self->_trim_for_token_limit(
                messages        => $messages,
                retry_count     => $$retry_count_ref,
                session         => $session,
                tool_calls_made => $tool_calls_made,
                iteration       => $iteration,
                max_retries     => $max_retries,
                max_server_retries => $max_server_retries,
                error           => $error,
            );

            # Bail out if trim decided further retries are pointless
            return $trim_result->{response} if $trim_result->{bail};

            $error_type = "token limit exceeded";
            $system_msg = $trim_result->{system_msg};
        }
        elsif ($api_response->{error_type} && ($api_response->{error_type} eq 'server_error' || $api_response->{error_type} eq 'connection_error')) {
            my $backoff_multiplier = 2 ** ($$retry_count_ref - 1);
            $retry_delay = $retry_delay * $backoff_multiplier;
            # Cap backoff at 5 minutes
            $retry_delay = 300 if $retry_delay > 300;

            $error_type = $api_response->{error_type} eq 'connection_error' ? "connection error" : "server error";
            $system_msg = "Temporary $error_type. Retrying in ${retry_delay}s with exponential backoff... (attempt $$retry_count_ref)";
            log_info('WorkflowOrchestrator', "Applying exponential backoff for server error: ${retry_delay}s delay");
        }
        elsif ($api_response->{error_type} && $api_response->{error_type} eq 'rate_limit') {
            $error_type = "rate limit";
        }
        elsif ($api_response->{error_type} && $api_response->{error_type} eq 'auth_recovered') {
            $error_type  = "auth recovery";
            $system_msg  = undef;
            $retry_delay = 0;
            log_info('WorkflowOrchestrator', "Auth token refreshed, retrying request silently");
        }
        elsif ($api_response->{error_type} && $api_response->{error_type} eq 'message_structure_error') {
            $error_type = "message structure error";
            $system_msg = "Message structure error detected. Rebuilding from session history... (attempt $$retry_count_ref/$max_retries)";

            if ($session && $session->can('get_conversation_history')) {
                my $fresh_history    = $session->get_conversation_history() || [];
                my $system_msg_saved = $messages->[0]{role} eq 'system' ? $messages->[0] : undef;
                my $current_user_msg = $messages->[-1]{role} eq 'user'  ? $messages->[-1] : undef;

                @$messages = ();
                push @$messages, $system_msg_saved if $system_msg_saved;
                push @$messages, @$fresh_history;
                push @$messages, $current_user_msg
                    if $current_user_msg &&
                       (!@$fresh_history || $fresh_history->[-1]{content} ne $current_user_msg->{content});

                log_info('WorkflowOrchestrator', "Rebuilt messages from session history (" . scalar(@$messages) . " messages)");
            }

            $retry_delay = 0;
        }

        # Notify UI
        if ($system_msg && $on_system_message) {
            eval { $on_system_message->($system_msg); };
            log_debug('WorkflowOrchestrator', "UI callback error: $@") if $@;
        } elsif ($system_msg) {
            log_info('WorkflowOrchestrator', "Retryable $error_type detected, retrying in ${retry_delay}s on next iteration (attempt $$retry_count_ref/$max_retries)");
        }

        # Wait before retrying (interruptible)
        if ($retry_delay > 0) {
            log_debug('WorkflowOrchestrator', "Waiting ${retry_delay}s before retry...");
            my $remaining = $retry_delay;
            while ($remaining > 0) {
                my $chunk = ($remaining > 1) ? 1 : $remaining;
                sleep($chunk);
                $remaining -= $chunk;

                if ($self->_check_for_user_interrupt($session)) {
                    log_info('WorkflowOrchestrator', "Retry wait interrupted by user");
                    $self->_handle_interrupt($session, $messages);
                    last;
                }
            }
            log_debug('WorkflowOrchestrator', "Retry delay complete, sending request...");
        }

        return 'retry';
    }

    # ── Non-retryable errors ──────────────────────────────────────────
    $$retry_count_ref = 0;

    $$session_error_ref++;
    $session->{_error_count} = $$session_error_ref if $session;
    if ($$session_error_ref > $max_session_errors) {
        log_error('WorkflowOrchestrator', "Session error budget exhausted ($$session_error_ref errors). Stopping to prevent cascading failures.");
        return {
            success         => 0,
            error           => "Session error limit reached ($max_session_errors errors). Please start a new request or session. Last error: $error",
            iterations      => $iteration,
            tool_calls_made => $tool_calls_made,
        };
    }

    # Track consecutive identical errors
    if ($error eq $self->{last_error}) {
        $self->{consecutive_errors}++;
        log_debug('WorkflowOrchestrator', "Consecutive error count: $self->{consecutive_errors}/$self->{max_consecutive_errors}");
    } else {
        $self->{consecutive_errors} = 1;
        $self->{last_error} = $error;
    }

    if ($self->{consecutive_errors} >= $self->{max_consecutive_errors}) {
        log_debug('WorkflowOrchestrator', "Same error occurred $self->{consecutive_errors} times in a row. Breaking loop.");
        log_debug('WorkflowOrchestrator', "Persistent error: $error");
        log_debug('WorkflowOrchestrator', "This likely indicates a bug in the request construction or API incompatibility.");
        log_debug('WorkflowOrchestrator', "Check /tmp/clio_json_errors.log for details.");

        $self->{consecutive_errors} = 0;
        $self->{last_error} = '';
        return {
            success         => 0,
            error           => $error,
            content         => '',
            iterations      => $iteration,
            tool_calls_made => $tool_calls_made,
        };
    }

    # Remove bad assistant message
    if (@$messages && $messages->[-1]{role} eq 'assistant') {
        my $removed_msg = pop @$messages;
        log_warning('WorkflowOrchestrator', "Removed bad assistant message due to API error: $error");

        if ($self->{debug}) {
            my $content_preview = substr($removed_msg->{content} // '', 0, 100);
            log_debug('WorkflowOrchestrator', "Removed message content: $content_preview...");
            if ($removed_msg->{tool_calls}) {
                log_debug('WorkflowOrchestrator', "Removed message had " . scalar(@{$removed_msg->{tool_calls}}) . " tool_calls");
            }
        }
    }

    # Check if error is token/context limit related
    my $is_token_limit_error = (
        $error =~ /context.length.exceeded/i ||
        $error =~ /maximum.context.length/i ||
        $error =~ /token.limit.exceeded/i ||
        $error =~ /too.many.tokens/i ||
        $error =~ /exceeds?\s+(?:the\s+)?(?:maximum|max)\s+(?:number\s+of\s+)?tokens/i ||
        $error =~ /input.*too\s+(?:long|large)/i ||
        $error =~ /reduce.*(?:prompt|input|context)/i
    );

    if (!$is_token_limit_error) {
        push @$messages, {
            role    => 'user',
            content => "SYSTEM ERROR: Your previous response triggered an API error and was removed.\n\n" .
                       "Error details: $error\n\n" .
                       "Please try a different approach. Avoid repeating the same action that caused this error.",
        };
        log_info('WorkflowOrchestrator', "Added error message to conversation, continuing workflow");
    } else {
        # Smart group-based trim for non-retryable token limit errors
        log_warning('WorkflowOrchestrator', "Token limit error detected. Using smart context trimming...");

        my $sys_msg    = undef;
        my @non_system = ();
        for my $msg (@$messages) {
            if ($msg->{role} && $msg->{role} eq 'system') {
                $sys_msg = $msg;
            } else {
                push @non_system, $msg;
            }
        }

        # Group messages into logical units
        my @groups        = ();
        my $current_group = [];

        for (my $i = 0; $i < @non_system; $i++) {
            my $msg = $non_system[$i];

            if ($msg->{role} eq 'user') {
                push @groups, $current_group if @$current_group > 0;
                $current_group = [$msg];
            } elsif ($msg->{role} eq 'assistant') {
                if (@$current_group > 0 && $current_group->[-1]{role} eq 'user') {
                    push @$current_group, $msg;
                } else {
                    push @groups, $current_group if @$current_group > 0;
                    $current_group = [$msg];
                }
            } elsif ($msg->{role} eq 'tool') {
                push @$current_group, $msg;
            } else {
                push @$current_group, $msg;
            }
        }
        push @groups, $current_group if @$current_group > 0;

        # Keep last 3 complete groups
        my $keep_count = 3;
        $keep_count = scalar(@groups) if $keep_count > scalar(@groups);

        my @kept_groups = @groups[-$keep_count..-1] if $keep_count > 0;

        @$messages = ();
        push @$messages, $sys_msg if $sys_msg;
        for my $group (@kept_groups) {
            push @$messages, @$group;
        }

        my $removed_groups = scalar(@groups) - $keep_count;
        log_info('WorkflowOrchestrator', "Smart trim: kept $keep_count of " . scalar(@groups) . " message groups (removed $removed_groups)");
    }

    return 'continue';
}


sub _capture_file_before {
    my ($self, $tool_name, $operation, $args) = @_;
    
    return undef unless $args;
    
    # apply_patch captures handled separately (multiple files)
    if ($tool_name eq 'apply_patch') {
        return $self->_capture_patch_files_before($args);
    }
    
    my $op_info = $DIFF_OPERATIONS{$tool_name};
    return undef unless $op_info && $op_info->{$operation};
    
    my $path_key = $op_info->{$operation};
    my %before;
    
    if ($path_key eq 'path') {
        my $path = $args->{path};
        return undef unless $path;
        my $content = $self->_safe_read_file($path);
        $before{$path} = $content if defined $content;
    } elsif ($path_key eq 'replacements') {
        my $replacements = $args->{replacements};
        return undef unless $replacements && ref($replacements) eq 'ARRAY';
        for my $r (@$replacements) {
            next unless $r->{path};
            next if exists $before{$r->{path}};
            my $content = $self->_safe_read_file($r->{path});
            $before{$r->{path}} = $content if defined $content;
        }
    }
    
    return keys %before ? \%before : undef;
}

sub _capture_patch_files_before {
    my ($self, $args) = @_;
    
    my $patch = $args->{patch} || '';
    my %before;
    
    while ($patch =~ /^\*\*\*\s+(?:Update|Delete)\s+File:\s*(.+)$/gm) {
        my $path = $1;
        $path =~ s/^\s+|\s+$//g;
        next if exists $before{$path};
        my $content = $self->_safe_read_file($path);
        $before{$path} = $content if defined $content;
    }
    
    return keys %before ? \%before : undef;
}

sub _safe_read_file {
    my ($self, $path) = @_;
    return undef unless $path && -f $path;
    my $content = eval {
        open my $fh, '<:encoding(UTF-8)', $path or return undef;
        local $/;
        my $data = <$fh>;
        close $fh;
        $data;
    };
    return $content;
}

=head2 _display_file_diff

Display unified diffs for files changed by a tool operation.

=cut

sub _display_file_diff {
    my ($self, $before_map, $tool_name, $operation, $args, $opts) = @_;
    
    return unless $before_map && ref($before_map) eq 'HASH';
    
    my $skip_opening_hrule = $opts && $opts->{skip_opening_hrule};
    my $has_diffs = 0;
    for my $path (sort keys %$before_map) {
        my $old = $before_map->{$path};
        my $new = $self->_safe_read_file($path);
        next unless defined $new;
        next if (!defined $old && !length($new));
        
        $old //= '';
        
        # Opening hrule before first diff
        if (!$has_diffs) {
            $self->{formatter}->display_hrule() unless $skip_opening_hrule;
            $has_diffs = 1;
        }
        $self->{formatter}->display_diff($old, $new, $path);
    }
    # Closing hrule after all diffs
    $self->{formatter}->display_hrule() if $has_diffs;
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

=head2 _check_and_handle_interrupt

Combined interrupt check + handle for use at multiple points during iteration.
Checks for any keypress and if detected, adds interrupt message to conversation
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
    
    # Skip if we already have a pending interrupt for this iteration
    # (prevents duplicate interrupt message injection)
    return 1 if $self->{_interrupt_pending};
    
    if ($self->_check_for_user_interrupt($session)) {
        $self->_handle_interrupt($session, $messages_ref);
        $self->{_interrupt_pending} = 1;
        
        log_info('WorkflowOrchestrator', "Interrupt detected mid-iteration, setting pending flag");
        
        return 1;
    }
    
    return 0;
}


=head2 _check_for_user_interrupt

Check for any keypress (user interrupt) non-blocking.

Any keypress during agent execution triggers an interrupt. This is more
reliable than ESC-only detection since terminal escape sequences can be
ambiguous and ESC may be consumed by the terminal multiplexer.

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
    
    # Check if the ALRM signal handler (in Chat.pm) already detected a keypress
    # and set the interrupt flag. This is the primary detection path - the ALRM
    # fires every second and checks ReadKey(-1) even during blocking I/O.
    if ($session && $session->state() && $session->state()->{user_interrupted}) {
        log_debug('WorkflowOrchestrator', "Interrupt flag already set (detected by ALRM handler)");
        return 1;
    }
    
    # Secondary check: non-blocking keyboard read
    # Terminal is already in cbreak mode (set by Chat.pm before agent execution)
    # so keypresses are immediately available without needing ReadMode switching
    my $key = eval { ReadKey(-1) };
    
    if ($@) {
        log_warning('WorkflowOrchestrator', "Error checking for interrupt: $@");
        return 0;
    }
    
    # Any keypress triggers an interrupt
    if (defined $key) {
        my $key_desc = (ord($key) == 27) ? 'ESC' : 
                       (ord($key) < 32)  ? sprintf('Ctrl+%c', ord($key) + 64) :
                       "'$key'";
        log_info('WorkflowOrchestrator', "User interrupt detected ($key_desc key pressed)");
        
        # Drain any remaining buffered input (e.g. escape sequences)
        while (defined(eval { ReadKey(-1) })) { }
        
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
            box_char("hhorizontal") x 3 . " USER INTERRUPT " . box_char("hhorizontal") x 3 . "\n\n" .
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

=head2 _compress_dropped_for_recovery

Creates a compressed summary of dropped messages for context recovery after
reactive trimming due to token limit exceeded errors.

This prevents the AI from losing context of what it was working on when
aggressive trimming is needed. It uses YaRN compression to create a
thread_summary, extracts the current conversation topic, and optionally
includes current task state from todos.

Arguments:
- $dropped_messages: Arrayref of message hashes that were dropped
- $last_user_msg: The most recent user message (for current task context)
- $session: Session object (optional, for todo state)
- $all_messages: Arrayref of ALL messages before trimming (for topic extraction)

Returns: Message hashref with role 'system' containing compressed summary,
         or undef if compression fails

=cut

# Reactive context trim for token_limit_exceeded errors.
# Trims messages in place using a 3-tier strategy based on retry_count.
# Returns { system_msg => '...' } on success,
# or { bail => 1, response => {...} } when further retries are pointless.
sub _trim_for_token_limit {
    my ($self, %args) = @_;

    my $messages        = $args{messages};
    my $retry_count     = $args{retry_count};
    my $session         = $args{session};
    my $tool_calls_made = $args{tool_calls_made};
    my $iteration       = $args{iteration};
    my $max_retries     = $args{max_retries};
    my $max_server_retries = $args{max_server_retries};
    my $error           = $args{error};

    _dump_diagnostic(
        trigger     => 'trim',
        phase       => 'reactive_before',
        messages    => $messages,
        api_manager => $self->{api_manager},
        iteration   => $iteration,
        retry_count => $retry_count,
        extra       => {
            max_retries        => $max_retries,
            max_server_retries => $max_server_retries,
            error_message      => $error || '',
        },
    ) if $ENV{CLIO_TRIM_DIAG};

    _checkpoint_session_progress($session, $tool_calls_made, $iteration, $messages)
        if $session;

    # Separate system prompt and find most recent user message
    my $system_prompt = undef;
    my @non_system    = ();
    my $last_user_msg = undef;
    my $last_user_idx = -1;

    for my $msg (@$messages) {
        if ($msg->{role} eq 'system' && !$system_prompt) {
            $system_prompt = $msg;
        } else {
            push @non_system, $msg;
            if ($msg->{role} && $msg->{role} eq 'user') {
                $last_user_msg = $msg;
                $last_user_idx = $#non_system;
            }
        }
    }

    my $original_count = scalar(@non_system);

    # Build tool_call_id -> message index maps
    my %tool_call_indices   = ();
    my %tool_result_indices = ();

    for (my $i = 0; $i < @non_system; $i++) {
        my $msg = $non_system[$i];
        if ($msg->{role} && $msg->{role} eq 'assistant' &&
            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                $tool_call_indices{$tc->{id}} = $i if $tc->{id};
            }
        }
        elsif ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
            $tool_result_indices{$msg->{tool_call_id}} = $i;
        }
    }

    if ($retry_count == 1) {
        # First retry: keep recent messages that fit in 40% of model context
        my $_retry_caps = $self->{api_manager}
            ? ($self->{api_manager}->get_model_capabilities() || {}) : {};
        my $max_ctx     = $_retry_caps->{max_prompt_tokens} || 128000;
        my $keep_budget = int($max_ctx * 0.40);
        $keep_budget = 40000 if $keep_budget < 40000;

        my $kept_tokens = 0;
        my $start_idx   = $original_count;
        for (my $i = $original_count - 1; $i >= 0; $i--) {
            my $msg_tokens = estimate_tokens($non_system[$i]{content} || '') + 10;
            if ($kept_tokens + $msg_tokens <= $keep_budget) {
                $kept_tokens += $msg_tokens;
                $start_idx = $i;
            } else {
                last;
            }
        }
        my $min_start = $original_count - 10;
        $start_idx = $min_start if $start_idx > $min_start && $min_start >= 0;
        $start_idx = 0 if $start_idx < 0;

        my @dropped_messages;
        @dropped_messages = @non_system[0..($start_idx - 1)] if $start_idx > 0;

        my @must_include = ();
        push @must_include, $last_user_idx
            if $last_user_idx >= 0 && $last_user_idx < $start_idx;

        for (my $i = $start_idx; $i < $original_count; $i++) {
            my $msg = $non_system[$i];
            if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
                my $tc_id = $msg->{tool_call_id};
                if (exists $tool_call_indices{$tc_id}) {
                    my $tc_idx = $tool_call_indices{$tc_id};
                    push @must_include, $tc_idx if $tc_idx < $start_idx;
                }
            }
        }

        if (@must_include) {
            @must_include = sort { $a <=> $b } @must_include;
            my @preserved = ();
            my %seen      = ();
            for my $idx (@must_include) {
                next if $seen{$idx}++;
                push @preserved, $non_system[$idx];
            }
            push @preserved, @non_system[$start_idx..-1];
            @non_system = @preserved;
        } else {
            @non_system = @non_system[$start_idx..-1];
        }

        if (@dropped_messages) {
            my $compressed = _compress_dropped_for_recovery(\@dropped_messages, $last_user_msg, $session, $messages);
            if ($compressed) {
                push @non_system, $compressed;
                log_info('WorkflowOrchestrator', "Injected compression summary for " . scalar(@dropped_messages) . " dropped messages");
            }
        }
    }
    elsif ($retry_count == 2) {
        # Second retry: keep last 25% + most recent user message
        my $keep_count = int($original_count / 4);
        $keep_count = 5 if $keep_count < 5 && $original_count >= 5;

        my $drop_count = $original_count - $keep_count;
        my @dropped_messages;
        @dropped_messages = @non_system[0..($drop_count - 1)] if $drop_count > 0;

        my @kept;
        @kept = @non_system[-$keep_count..-1] if $keep_count > 0;

        if ($last_user_msg && !grep { $_ == $last_user_msg } @kept) {
            unshift @kept, $last_user_msg;
        }
        @non_system = @kept;

        if (@dropped_messages) {
            my $compressed = _compress_dropped_for_recovery(\@dropped_messages, $last_user_msg, $session, $messages);
            if ($compressed) {
                push @non_system, $compressed;
                log_info('WorkflowOrchestrator', "Injected compression summary for " . scalar(@dropped_messages) . " dropped messages (retry 2)");
            }
        }
    }
    else {
        # Third retry: minimal context - last user message + last 2 messages
        my @dropped_messages = @non_system;

        my @kept = ();
        push @kept, $last_user_msg if $last_user_msg;

        my @last_two = @non_system[-2..-1];
        for my $msg (@last_two) {
            next if $last_user_msg && $msg == $last_user_msg;
            push @kept, $msg;
        }
        @non_system = @kept;

        if (@dropped_messages > 2) {
            my $compressed = _compress_dropped_for_recovery(\@dropped_messages, $last_user_msg, $session, $messages);
            if ($compressed) {
                push @non_system, $compressed;
                log_info('WorkflowOrchestrator', "Injected compression summary for " . scalar(@dropped_messages) . " dropped messages (retry 3 - minimal)");
            }
        }
    }

    my $trimmed_count = $original_count - scalar(@non_system);

    # Rebuild messages array in place
    @$messages = ();
    push @$messages, $system_prompt if $system_prompt;
    push @$messages, @non_system;

    _dump_diagnostic(
        trigger     => 'trim',
        phase       => 'reactive_after',
        messages    => $messages,
        api_manager => $self->{api_manager},
        iteration   => $iteration,
        retry_count => $retry_count,
        extra       => {
            original_count      => $original_count,
            trimmed_count       => $trimmed_count,
            kept_count          => scalar(@non_system),
            last_user_preserved => ($last_user_msg ? 'YES' : 'NO'),
        },
    ) if $ENV{CLIO_TRIM_DIAG};

    my $preserved_info = $last_user_msg ? " (most recent user message preserved)" : "";
    my $recovery_info  = ($trimmed_count > 0) ? " Context summary injected." : "";
    my $system_msg = "Token limit exceeded. Trimmed $trimmed_count messages from conversation history and retrying$preserved_info...$recovery_info (attempt $retry_count/$max_retries)";

    log_info('WorkflowOrchestrator', "Trimmed $trimmed_count messages due to token limit (kept " . scalar(@non_system) . " messages, last_user=" . ($last_user_msg ? 'YES' : 'NO') . ")");

    # Nothing trimmed means context isn't the problem
    if ($trimmed_count == 0) {
        log_warning('WorkflowOrchestrator', "Context trim removed 0 messages - problem is not context size. Escalating to non-retryable.");

        _dump_diagnostic(
            trigger      => 'persistent_400',
            phase        => 'trim_zero',
            messages     => $messages,
            api_manager  => $self->{api_manager},
            iteration    => $iteration,
            retry_count  => $retry_count,
            error        => $error,
            append       => 1,
            extra        => {
                escalations    => $self->{_bad_request_escalations} || 0,
                original_count => $original_count,
                trimmed_count  => 0,
            },
        );

        return {
            bail     => 1,
            response => {
                success         => 0,
                error           => "API error persists after context trim (0 messages removed, $retry_count retries). This is likely a backend issue, not a context size problem. Diagnostic dump written to /tmp/clio_diag_persistent_400.log. Try again in a few minutes, or use a different model.",
                iterations      => $iteration,
                tool_calls_made => $tool_calls_made,
            },
        };
    }

    # Minimal context and still failing
    if ($retry_count > 2 && scalar(@non_system) <= 3) {
        log_debug('WorkflowOrchestrator', "Token limit persists even with minimal context - giving up");
        return {
            bail     => 1,
            response => {
                success         => 0,
                error           => "Token limit exceeded even with minimal conversation history. The request may be too large for this model. Try using a model with a larger context window.",
                tool_calls_made => $tool_calls_made,
            },
        };
    }

    return { system_msg => $system_msg };
}

sub _compress_dropped_for_recovery {
    my ($dropped_messages, $last_user_msg, $session, $all_messages) = @_;
    
    return undef unless $dropped_messages && @$dropped_messages;
    
    # Extract previous thread_summary from dropped messages (system-role messages
    # containing <thread_summary> tags). These are ignored by YaRN's role-based
    # extraction, so we pass them explicitly to preserve accumulated history.
    my $previous_summary = '';
    my @actual_messages;
    for my $msg (@$dropped_messages) {
        my $content = $msg->{content} || '';
        if ($msg->{role} && $msg->{role} eq 'system' && $content =~ /<thread_summary>/) {
            $previous_summary = $content;
        } else {
            push @actual_messages, $msg;
        }
    }
    
    # Use filtered messages (without old summary) for extraction
    my $messages_to_compress = @actual_messages ? \@actual_messages : $dropped_messages;
    
    my $compressed;
    eval {
        require CLIO::Memory::YaRN;
        my $yarn = CLIO::Memory::YaRN->new();
        
        # Get task context from most recent user message, falling back to
        # a substantive message from the dropped set if it's too short.
        my $original_task = '';
        if ($last_user_msg && ref($last_user_msg) eq 'HASH') {
            $original_task = $last_user_msg->{content} || '';
        }
        $original_task = CLIO::Memory::YaRN::find_substantive_task($original_task, $messages_to_compress);
        
        $compressed = $yarn->compress_messages($messages_to_compress,
            original_task    => $original_task,
            previous_summary => $previous_summary,
        );
    };
    if ($@) {
        log_warning('WorkflowOrchestrator', "YaRN compression failed: $@");
    }
    
    # Build recovery context
    my @recovery_parts = ();

    # FIRST: Extract and inject the current conversation topic
    # This is the most critical piece - tells the agent exactly what was being discussed
    my $topic = _extract_conversation_topic($all_messages || $dropped_messages);
    if ($topic) {
        push @recovery_parts, "<current_topic>";
        push @recovery_parts, $topic;
        push @recovery_parts, "</current_topic>";
        push @recovery_parts, "";
    }
    
    if ($compressed && $compressed->{content}) {
        push @recovery_parts, $compressed->{content};
    }
    
    # Add current todo/task state if session is available
    if ($session) {
        my $todo_context = _get_todo_recovery_context($session);
        if ($todo_context) {
            push @recovery_parts, "";
            push @recovery_parts, "<task_recovery>";
            push @recovery_parts, $todo_context;
            push @recovery_parts, "</task_recovery>";
        }
    }
    
    # Extract recent user messages and collaboration responses from dropped messages
    # These provide additional context beyond what YaRN compression captures
    my @recent_user_msgs = ();
    for my $msg (reverse @$dropped_messages) {
        last if @recent_user_msgs >= 5;
        if ($msg->{role} && $msg->{role} eq 'user' && $msg->{content}) {
            my $summary = substr($msg->{content}, 0, 1000);
            $summary .= '...' if length($msg->{content}) > 1000;
            unshift @recent_user_msgs, $summary;
        }
    }
    if (@recent_user_msgs) {
        push @recovery_parts, "";
        push @recovery_parts, "<recent_context>";
        push @recovery_parts, "Most recent user messages before trimming:";
        for my $i (0..$#recent_user_msgs) {
            push @recovery_parts, ($i + 1) . ". " . $recent_user_msgs[$i];
        }
        push @recovery_parts, "</recent_context>";
    }

    # Add lightweight git context so agent knows what was committed/modified
    # without needing to read handoff documentation
    my $git_context = _get_git_recovery_context($session);
    if ($git_context) {
        push @recovery_parts, "";
        push @recovery_parts, "<git_recovery>";
        push @recovery_parts, $git_context;
        push @recovery_parts, "</git_recovery>";
    }

    # Add recovery session progress if stored in memory
    my $progress_context = _get_memory_recovery_context($session);
    if ($progress_context) {
        push @recovery_parts, "";
        push @recovery_parts, "<session_progress>";
        push @recovery_parts, $progress_context;
        push @recovery_parts, "</session_progress>";
    }

    return undef unless @recovery_parts;

    # Build the recovery content as a user message so it won't get merged into
    # the system prompt by enforce_message_alternation (which merges consecutive
    # system messages). As a user message, the agent MUST respond to it.
    my @final_parts = ();
    push @final_parts, "Older conversation history has been summarized below to free context space.";
    push @final_parts, "Continue your current work seamlessly - do not announce or acknowledge this summary.";
    push @final_parts, "";
    push @final_parts, @recovery_parts;
    push @final_parts, "";
    push @final_parts, "IMPORTANT: Continue working on whatever you were doing. Do NOT say things like";
    push @final_parts, "'I've recovered context' or 'Let me review what happened'. Just keep working";
    push @final_parts, "as if nothing changed. If you had a task in progress, continue it. If the user";
    push @final_parts, "asked a question, answer it. Use todo_operations and git tools for details.";

    my $recovery_content = join("\n", @final_parts);

    log_debug('WorkflowOrchestrator', "Recovery context created: " . length($recovery_content) . " chars from " . scalar(@$dropped_messages) . " dropped messages");

    return {
        role => 'user',
        content => $recovery_content,
    };
}

=head2 _get_todo_recovery_context

Extracts current task/todo state from session for context recovery.
This allows the AI to resume its current task after aggressive trimming.

Arguments:
- $session: Session object

Returns: String with todo context, or undef if no todos

=cut

=head2 _extract_conversation_topic

Extracts the current conversation topic from the last N messages in the
message array. This captures what the agent and user were actively discussing
right before context trimming occurred.

Looks for:
- Collaboration exchanges (highest priority - active design discussions)
- Recent assistant content (what the agent was saying/presenting)
- Recent user content (what the user was asking/responding)

Arguments:
- $messages: Arrayref of messages (the full message list before trimming)
- $max_messages: How many messages to look back (default: 20)

Returns: String describing the current conversation topic, or undef

=cut

sub _extract_conversation_topic {
    my ($messages, $max_messages) = @_;

    return undef unless $messages && @$messages;
    $max_messages ||= 20;

    my $start = @$messages > $max_messages ? @$messages - $max_messages : 0;
    my @recent = @{$messages}[$start .. $#$messages];

    # Look for collaboration exchanges in the last messages
    my @collab_questions;
    my @collab_responses;
    my @user_messages;
    my @assistant_snippets;

    # Track tool_call IDs for user_collaboration
    my %pending_collab_ids;

    for my $msg (@recent) {
        my $role = $msg->{role} || '';
        my $content = $msg->{content} || '';

        if ($role eq 'assistant') {
            # Check for collaboration tool calls
            if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                for my $tc (@{$msg->{tool_calls}}) {
                    my $name = $tc->{function}{name} || '';
                    if ($name eq 'user_collaboration' && $tc->{id}) {
                        my $args_str = $tc->{function}{arguments} || '{}';
                        if ($args_str =~ /"message"\s*:\s*"((?:[^"\\]|\\.)*)"/s) {
                            my $q = $1;
                            $q =~ s/\\n/\n/g;
                            $q =~ s/\\"/"/g;
                            $q =~ s/\\\\/\\/g;
                            $pending_collab_ids{$tc->{id}} = $q;
                            # Keep up to 2000 chars to capture design discussions
                            my $truncated = substr($q, 0, 2000);
                            $truncated .= '...' if length($q) > 2000;
                            push @collab_questions, $truncated;
                        }
                    }
                }
            }

            # Non-empty assistant content (could be mid-conversation text)
            if ($content && length($content) > 10) {
                my $snippet = substr($content, 0, 1500);
                $snippet .= '...' if length($content) > 1500;
                push @assistant_snippets, $snippet;
            }
        }
        elsif ($role eq 'tool') {
            # Match collaboration responses
            if ($msg->{tool_call_id} && exists $pending_collab_ids{$msg->{tool_call_id}}) {
                my $truncated = substr($content, 0, 2000);
                $truncated .= '...' if length($content) > 2000;
                push @collab_responses, $truncated;
                delete $pending_collab_ids{$msg->{tool_call_id}};
            }
        }
        elsif ($role eq 'user') {
            my $truncated = substr($content, 0, 1000);
            $truncated .= '...' if length($content) > 1000;
            push @user_messages, $truncated if $content;
        }
    }

    my @topic_parts;

    # Collaboration is highest priority - it represents active discussion
    if (@collab_questions || @collab_responses) {
        push @topic_parts, "Active discussion:";
        # Show last 5 exchanges to capture full design discussions
        my $q_start = @collab_questions > 5 ? @collab_questions - 5 : 0;

        for my $i ($q_start .. $#collab_questions) {
            push @topic_parts, "Agent asked: " . $collab_questions[$i];
            if ($collab_responses[$i]) {
                push @topic_parts, "User replied: " . $collab_responses[$i];
            }
        }
    }

    # Always include recent user messages (even if we have collaboration)
    if (@user_messages) {
        my $start_at = @user_messages > 3 ? @user_messages - 3 : 0;
        if (@collab_questions || @collab_responses) {
            # Separate section when we also have collaboration
            push @topic_parts, "";
            push @topic_parts, "Recent user messages:";
        } else {
            push @topic_parts, "Recent user messages:";
        }
        for my $i ($start_at .. $#user_messages) {
            push @topic_parts, "- " . $user_messages[$i];
        }
    }

    # Also show what the agent was doing/saying
    if (@assistant_snippets && @assistant_snippets > 0) {
        my $last_snippet = $assistant_snippets[-1];
        push @topic_parts, "";
        push @topic_parts, "Agent's last message: " . $last_snippet;
    }

    return undef unless @topic_parts;
    return join("\n", @topic_parts);
}

sub _get_todo_recovery_context {
    my ($session) = @_;
    
    return undef unless $session;
    
    my $todo_context;
    eval {
        require CLIO::Session::TodoStore;
        my $session_id = $session->can('session_id') ? $session->session_id() : undef;
        return undef unless $session_id;
        
        my $store = CLIO::Session::TodoStore->new(session_id => $session_id);
        my $todos = $store->read();
        
        return undef unless $todos && ref($todos) eq 'HASH' && $todos->{todoList} && @{$todos->{todoList}};
        
        my @parts = ("Current task list:");
        my $in_progress;
        
        for my $todo (@{$todos->{todoList}}) {
            my $status = $todo->{status} || 'not-started';
            my $title = $todo->{title} || 'Untitled';
            my $desc = $todo->{description} || '';
            
            my $marker = $status eq 'completed' ? '[x]' :
                         $status eq 'in-progress' ? '[>]' :
                         $status eq 'blocked' ? '[!]' : '[ ]';
            
            push @parts, "$marker #$todo->{id}: $title" . ($desc ? " - $desc" : "");
            
            if ($status eq 'in-progress') {
                $in_progress = $todo;
            }
        }
        
        if ($in_progress) {
            push @parts, "";
            push @parts, "CURRENTLY WORKING ON: #$in_progress->{id} - $in_progress->{title}";
            if ($in_progress->{description}) {
                push @parts, "Details: $in_progress->{description}";
            }
        }
        
        $todo_context = join("\n", @parts);
    };
    if ($@) {
        log_debug('WorkflowOrchestrator', "Could not retrieve todo state for recovery: $@");
    }
    
    return $todo_context;
}

=head2 _checkpoint_session_progress

Saves a lightweight progress snapshot to .clio/memory/session_progress.md.
Called periodically during long sessions and before context trim events.
This creates a recovery anchor the agent can retrieve after context is trimmed.

Arguments:
- $session: Session object
- $tool_calls_made: Arrayref of tool calls executed so far
- $iteration: Current iteration number
- $messages: Arrayref of current message history (for conversation topic)

=cut

sub _checkpoint_session_progress {
    my ($session, $tool_calls_made, $iteration, $messages) = @_;

    eval {
        my $memory_dir = '.clio/memory';
        unless (-d $memory_dir) {
            require File::Path;
            File::Path::make_path($memory_dir);
        }

        my @parts = ();
        push @parts, "# Session Progress Checkpoint";
        push @parts, "Updated: " . localtime();
        push @parts, "Iteration: $iteration";
        push @parts, "";

        # Summarize tool calls made
        if ($tool_calls_made && @$tool_calls_made) {
            my %tool_summary;
            my @recent_files;
            for my $tc (@$tool_calls_made) {
                $tool_summary{$tc->{tool} || 'unknown'}++;
                if ($tc->{tool} && $tc->{tool} =~ /file_operations|apply_patch/ && $tc->{args}) {
                    my $path = $tc->{args}{path} || '';
                    push @recent_files, $path if $path && $path !~ /^\./;
                }
            }
            push @parts, "## Tool Activity";
            push @parts, "Total tool calls: " . scalar(@$tool_calls_made);
            for my $t (sort { $tool_summary{$b} <=> $tool_summary{$a} } keys %tool_summary) {
                push @parts, "- $t: $tool_summary{$t} calls";
            }
            push @parts, "";

            # Recent files touched (deduplicated)
            if (@recent_files) {
                my %seen;
                @recent_files = grep { !$seen{$_}++ } reverse @recent_files;
                @recent_files = @recent_files[0..19] if @recent_files > 20;
                push @parts, "## Files Touched";
                push @parts, "- $_" for @recent_files;
                push @parts, "";
            }
        }

        # Include todo state
        my $todo_ctx = _get_todo_recovery_context($session);
        if ($todo_ctx) {
            push @parts, "## Task State";
            push @parts, $todo_ctx;
            push @parts, "";
        }

        # Include git state
        my $git_ctx = _get_git_recovery_context($session);
        if ($git_ctx) {
            push @parts, "## Git State";
            push @parts, $git_ctx;
            push @parts, "";
        }

        # Include current conversation topic
        if ($messages && @$messages) {
            my $topic = _extract_conversation_topic($messages);
            if ($topic) {
                push @parts, "## Current Discussion";
                push @parts, $topic;
                push @parts, "";
            }
        }

        my $content = join("\n", @parts);

        # Atomic write
        my $file = "$memory_dir/session_progress.md";
        my $temp = "$file.tmp.$$";
        open my $fh, '>:encoding(UTF-8)', $temp or croak "Cannot write: $!";
        print $fh $content;
        close $fh;
        rename $temp, $file or croak "Cannot rename: $!";

        log_debug('WorkflowOrchestrator', "Session progress checkpoint saved (iteration $iteration, " . length($content) . " chars)");
    };
    if ($@) {
        log_debug('WorkflowOrchestrator', "Failed to checkpoint session progress: $@");
    }
}

=head2 _record_turn_metrics($api_response, $session)

=head2 _get_memory_recovery_context

Retrieves stored session progress from memory for context recovery.
If the orchestrator has been checkpointing progress to session memory,
this returns the most recent checkpoint.

Arguments:
- $session: Session object

Returns: String with progress context, or undef if none stored

=cut

sub _get_memory_recovery_context {
    my ($session) = @_;

    return undef unless $session;

    my $content;
    eval {
        my $memory_dir = '.clio/memory';
        my $progress_file = "$memory_dir/session_progress.md";
        if (-f $progress_file) {
            open my $fh, '<:encoding(UTF-8)', $progress_file or return undef;
            local $/;
            $content = <$fh>;
            close $fh;
            # Only return if not stale (within last 2 hours)
            my $mtime = (stat($progress_file))[9];
            if (time() - $mtime > 7200) {
                log_debug('WorkflowOrchestrator', "Session progress file is stale (> 2h old), skipping");
                $content = undef;
            }
        }
    };
    if ($@) {
        log_debug('WorkflowOrchestrator', "Could not read session progress for recovery: $@");
    }

    return $content;
}

=head2 _get_git_recovery_context

Gets lightweight git state for recovery injection: recent commits and current
working tree status. This prevents the agent from needing to read handoff
documentation after a context trim to understand what was already committed.

Arguments:
- $session: Session object (used to find working directory)

Returns: String with git context, or undef if not a git repo or git unavailable

=cut

sub _get_git_recovery_context {
    my ($session) = @_;

    my $working_dir;
    eval {
        $working_dir = $session->{working_directory} if ref($session);
    };
    $working_dir ||= '.';

    my @parts = ();

    # Recent commits (last 5) - tells agent what was completed
    my $log = eval {
        my $out = '';
        my $nulldev = $^O eq 'MSWin32' ? 'nul' : '/dev/null';
        open my $fh, '-|', "git -C \Q$working_dir\E log --oneline -5 2>$nulldev"
            or return undef;
        while (<$fh>) { $out .= $_ }
        close $fh;
        $out;
    };
    if ($log && length($log) > 5) {
        push @parts, "Recent commits:";
        push @parts, $log;
    }

    # Working tree status - tells agent what's modified/staged
    my $status = eval {
        my $out = '';
        my $nulldev = $^O eq 'MSWin32' ? 'nul' : '/dev/null';
        open my $fh, '-|', "git -C \Q$working_dir\E status --short 2>$nulldev"
            or return undef;
        while (<$fh>) { $out .= $_ }
        close $fh;
        $out;
    };
    if (defined $status) {
        if (length($status) > 2) {
            push @parts, "Modified/staged files:";
            push @parts, $status;
        } else {
            push @parts, "Working tree: clean";
        }
    }

    return undef unless @parts;
    return join("\n", @parts);
}

=head2 _record_turn_metrics($api_response, $session)

Record performance metrics from an API response into session state.
Tracks per-iteration TTFT, TPS, tokens, and duration. Maintains
running averages and stores the last iteration's metrics for /stats.

=cut

sub _record_turn_metrics {
    my ($self, $api_response, $session) = @_;
    return unless $api_response && $session;

    my $metrics = $api_response->{metrics} || {};
    my $usage = $api_response->{usage} || {};

    # Extract what we have
    my $ttft = $metrics->{ttft};
    my $tps = $metrics->{tps};
    my $duration = $metrics->{duration};
    my $output_tokens = $metrics->{tokens} || $usage->{completion_tokens} || 0;
    my $input_tokens = $usage->{prompt_tokens} || 0;
    my $tool_calls_count = $api_response->{tool_calls} ? scalar(@{$api_response->{tool_calls}}) : 0;

    # Get or initialize session performance state
    my $state = $session->can('state') ? $session->state() : undef;
    return unless $state;

    $state->{perf} ||= {
        total_turns     => 0,
        total_duration  => 0,
        total_tokens_in => 0,
        total_tokens_out => 0,
        total_ttft      => 0,
        ttft_count      => 0,   # Only count turns that had TTFT data
        total_tps       => 0,
        tps_count       => 0,   # Only count turns that had TPS data
    };

    my $perf = $state->{perf};

    # Update totals
    $perf->{total_turns}++;
    $perf->{total_duration} += ($duration || 0);
    $perf->{total_tokens_in} += $input_tokens;
    $perf->{total_tokens_out} += $output_tokens;

    if (defined $ttft && $ttft > 0) {
        $perf->{total_ttft} += $ttft;
        $perf->{ttft_count}++;
    }

    if (defined $tps && $tps > 0) {
        $perf->{total_tps} += $tps;
        $perf->{tps_count}++;
    }

    # Store last iteration metrics (overwritten each turn)
    $perf->{last} = {
        ttft         => $ttft,
        tps          => $tps,
        duration     => $duration,
        tokens_in    => $input_tokens,
        tokens_out   => $output_tokens,
        tool_calls   => $tool_calls_count,
        timestamp    => time(),
    };

    log_debug('WorkflowOrchestrator', sprintf(
        "Turn metrics: TTFT=%.2fs TPS=%.1f tokens_in=%d tokens_out=%d duration=%.1fs tools=%d",
        $ttft // 0, $tps // 0, $input_tokens, $output_tokens, $duration // 0, $tool_calls_count
    ));
}

=head2 get_performance_summary

Get a summary of session performance metrics for /stats display.

Returns: Hashref with averages, totals, and last iteration data.

=cut

sub get_performance_summary {
    my ($self) = @_;

    my $session = $self->{session};
    return undef unless $session && $session->can('state');

    my $state = $session->state();
    my $perf = $state->{perf};
    return undef unless $perf && $perf->{total_turns};

    return {
        # Averages
        avg_ttft     => $perf->{ttft_count} > 0 ? ($perf->{total_ttft} / $perf->{ttft_count}) : undef,
        avg_tps      => $perf->{tps_count} > 0 ? ($perf->{total_tps} / $perf->{tps_count}) : undef,
        avg_duration => $perf->{total_turns} > 0 ? ($perf->{total_duration} / $perf->{total_turns}) : undef,

        # Totals
        total_turns      => $perf->{total_turns},
        total_duration   => $perf->{total_duration},
        total_tokens_in  => $perf->{total_tokens_in},
        total_tokens_out => $perf->{total_tokens_out},
        total_tokens     => $perf->{total_tokens_in} + $perf->{total_tokens_out},

        # Last iteration
        last => $perf->{last},
    };
}

# =============================================================================
# DIAGNOSTIC: Token limit exceeded state dump
# Writes full state to /tmp/clio_trim_*.log for root cause analysis
# =============================================================================

=head2 _dump_diagnostic

Unified diagnostic dump for debugging API and context management issues.

Supports multiple trigger modes:

  trigger => 'trim'            Context trim diagnostic (CLIO_TRIM_DIAG env var)
  trigger => 'persistent_400'  Persistent 400 errors (always-on)

Options:
  phase       => 'before'|'after'  (for trim diagnostics)
  messages    => \@messages
  api_manager => $api_manager
  iteration   => $iteration
  retry_count => $retry_count
  extra       => { ... }          Additional key-value pairs
  api_response => { ... }         API response hash (for 400 diagnostics)
  error       => 'error string'   Error message
  append      => 1                Append to file instead of creating new

=cut

sub _dump_diagnostic {
    my (%args) = @_;

    my $trigger     = $args{trigger} || 'unknown';
    my $phase       = $args{phase} || '';
    my $messages    = $args{messages} || [];
    my $api_manager = $args{api_manager};
    my $iteration   = $args{iteration} // 0;
    my $retry_count = $args{retry_count} // 0;
    my $extra       = $args{extra} || {};
    my $api_response = $args{api_response};
    my $error_msg   = $args{error} || '';
    my $append      = $args{append} || 0;

    # Determine output file
    my $file;
    if ($append) {
        $file = "/tmp/clio_diag_${trigger}.log";
    } else {
        my $ts = POSIX::strftime('%Y%m%d_%H%M%S', localtime);
        my $label = $phase ? "${trigger}_${phase}" : $trigger;
        $file = "/tmp/clio_diag_${label}_${ts}_$$.log";
    }

    my $open_mode = $append ? '>>:encoding(UTF-8)' : '>:encoding(UTF-8)';
    open my $fh, $open_mode, $file or do {
        log_warning('WorkflowOrchestrator', "Cannot write diagnostic to $file: $!");
        return;
    };

    # Header
    my $title = uc($trigger);
    $title .= " - " . uc($phase) if $phase;
    print $fh "\n" if $append;
    print $fh "=" x 80, "\n";
    print $fh "CLIO DIAGNOSTIC: $title\n";
    print $fh "Timestamp: ", scalar(localtime), "\n";
    print $fh "PID: $$\n";
    print $fh "Iteration: $iteration, Retry: $retry_count\n";
    print $fh "Error: $error_msg\n" if $error_msg;
    print $fh "=" x 80, "\n\n";

    # API response details (if provided)
    if ($api_response && ref($api_response) eq 'HASH') {
        print $fh "-" x 40, "\n";
        print $fh "API RESPONSE\n";
        print $fh "-" x 40, "\n";
        for my $key (sort keys %$api_response) {
            next if $key eq 'content';  # Skip large content
            my $val = $api_response->{$key};
            if (ref($val)) {
                $val = eval { encode_json($val) } // ref($val);
                $val = substr($val, 0, 500) . "..." if length($val) > 500;
            }
            $val //= 'undef';
            print $fh "  $key: $val\n";
        }
        print $fh "\n";
    }

    # Model capabilities
    print $fh "-" x 40, "\n";
    print $fh "MODEL & CAPABILITIES\n";
    print $fh "-" x 40, "\n";
    if ($api_manager) {
        my $model = $api_manager->get_current_model() || 'unknown';
        my $provider = $api_manager->{provider_name} || 'unknown';
        print $fh "  Model: $model\n";
        print $fh "  Provider: $provider\n";
        my $caps = $api_manager->get_model_capabilities($model);
        if ($caps) {
            for my $key (sort keys %$caps) {
                my $val = $caps->{$key};
                if (ref($val) eq 'ARRAY') {
                    $val = '[' . join(', ', @$val) . ']';
                } elsif (ref($val)) {
                    $val = eval { encode_json($val) } // ref($val);
                }
                print $fh "  $key: $val\n";
            }
        } else {
            print $fh "  (no capabilities available)\n";
        }
        print $fh "  learned_token_ratio: " . ($api_manager->{learned_token_ratio} // 'undef') . "\n";
    } else {
        print $fh "  (no api_manager)\n";
    }
    print $fh "\n";

    # Token estimator state
    print $fh "-" x 40, "\n";
    print $fh "TOKEN ESTIMATOR\n";
    print $fh "-" x 40, "\n";
    my $effective_ratio = CLIO::Memory::TokenEstimator::get_effective_ratio();
    print $fh "  effective_ratio: $effective_ratio\n\n";

    # Extra parameters
    if (keys %$extra) {
        print $fh "-" x 40, "\n";
        print $fh "EXTRA CONTEXT\n";
        print $fh "-" x 40, "\n";
        for my $key (sort keys %$extra) {
            print $fh "  $key: " . ($extra->{$key} // 'undef') . "\n";
        }
        print $fh "\n";
    }

    # Messages detail
    print $fh "-" x 40, "\n";
    print $fh "MESSAGES (" . scalar(@$messages) . " total)\n";
    print $fh "-" x 40, "\n";

    my $grand_total_tokens = 0;
    my %role_counts;
    my %role_tokens;

    for (my $i = 0; $i < @$messages; $i++) {
        my $msg = $messages->[$i];
        my $role = $msg->{role} || 'unknown';
        my $content = $msg->{content} || '';
        my $content_len = length($content);
        my $msg_tokens = estimate_tokens($content) + 4;
        $msg_tokens += 8 if $role eq 'tool';

        my $tc_count = 0;
        my $tc_tokens = 0;
        if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            $tc_count = scalar(@{$msg->{tool_calls}});
            for my $tc (@{$msg->{tool_calls}}) {
                my $json = eval { encode_json($tc) } // '';
                $tc_tokens += estimate_tokens($json);
            }
            $msg_tokens += $tc_tokens;
        }

        $grand_total_tokens += $msg_tokens;
        $role_counts{$role}++;
        $role_tokens{$role} = ($role_tokens{$role} || 0) + $msg_tokens;

        my $tc_info = $tc_count ? " tool_calls=$tc_count(${tc_tokens}tok)" : "";
        my $tool_id = $msg->{tool_call_id} ? " tool_call_id=$msg->{tool_call_id}" : "";
        my $importance = defined $msg->{_importance} ? " importance=$msg->{_importance}" : "";
        print $fh sprintf("[%4d] role=%-10s tokens=%-6d chars=%-7d%s%s%s\n",
            $i, $role, $msg_tokens, $content_len, $tc_info, $tool_id, $importance);

        my $preview = substr($content, 0, 200);
        $preview =~ s/\n/\\n/g;
        print $fh "       content: $preview" . ($content_len > 200 ? "..." : "") . "\n";
    }

    print $fh "\n";
    print $fh "-" x 40, "\n";
    print $fh "SUMMARY\n";
    print $fh "-" x 40, "\n";
    print $fh "Total messages: " . scalar(@$messages) . "\n";
    print $fh "Total estimated tokens: $grand_total_tokens\n";
    for my $role (sort keys %role_counts) {
        print $fh sprintf("  %-12s %4d messages, %7d tokens\n",
            "$role:", $role_counts{$role}, $role_tokens{$role});
    }
    print $fh "\n";

    # Tool pair validation (critical for diagnosing 400 errors)
    {
        my %tc_ids;   # tool_call_id => message index
        my %tr_ids;   # tool_call_id => message index (from results)
        for (my $i = 0; $i < @$messages; $i++) {
            my $msg = $messages->[$i];
            if ($msg->{role} && $msg->{role} eq 'assistant' &&
                $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                for my $tc (@{$msg->{tool_calls}}) {
                    $tc_ids{$tc->{id}} = $i if $tc->{id};
                }
            }
            if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
                $tr_ids{$msg->{tool_call_id}} = $i;
            }
        }
        my @orphaned_calls  = grep { !exists $tr_ids{$_} } keys %tc_ids;
        my @orphaned_results = grep { !exists $tc_ids{$_} } keys %tr_ids;
        
        if (@orphaned_calls || @orphaned_results) {
            print $fh "-" x 40, "\n";
            print $fh "TOOL PAIR VALIDATION (ERRORS)\n";
            print $fh "-" x 40, "\n";
            for my $id (@orphaned_calls) {
                print $fh "  ORPHANED tool_call: $id (assistant at msg $tc_ids{$id})\n";
            }
            for my $id (@orphaned_results) {
                print $fh "  ORPHANED tool_result: $id (tool at msg $tr_ids{$id})\n";
            }
            print $fh "Total tool_calls: " . scalar(keys %tc_ids) . ", tool_results: " . scalar(keys %tr_ids) . "\n";
            print $fh "\n";
        } else {
            print $fh "-" x 40, "\n";
            print $fh "TOOL PAIR VALIDATION: OK (" . scalar(keys %tc_ids) . " pairs matched)\n";
            print $fh "-" x 40, "\n\n";
        }
    }

    # Recent API 400 log (included for 400-related diagnostics)
    if ($trigger =~ /400/ && -f '/tmp/clio_api_400.log') {
        print $fh "-" x 40, "\n";
        print $fh "RECENT API 400 LOG\n";
        print $fh "-" x 40, "\n";
        if (open my $log_fh, '<', '/tmp/clio_api_400.log') {
            my @lines = <$log_fh>;
            close $log_fh;
            my $start = @lines > 20 ? @lines - 20 : 0;
            for my $i ($start..$#lines) {
                print $fh $lines[$i];
            }
        }
        print $fh "\n";
    }

    print $fh "=" x 80, "\n";
    close $fh;

    log_info('WorkflowOrchestrator', "Diagnostic ($trigger" . ($phase ? "/$phase" : "") . ") written to $file");
    return $file;
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
