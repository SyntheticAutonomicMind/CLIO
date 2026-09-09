# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::WorkflowOrchestrator;

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use CLIO::UI::Terminal qw(box_char);
use CLIO::Core::Logger qw(log_error log_warning log_debug should_log);
use CLIO::Core::ErrorContext qw(classify_error format_error);
use CLIO::Util::TextSanitizer qw(sanitize_text);
use CLIO::Util::JSONRepair qw(repair_malformed_json);
use CLIO::Util::AnthropicXMLParser qw(is_anthropic_xml_format parse_anthropic_xml_to_json);
use CLIO::UI::ToolOutputFormatter;
use CLIO::Core::ToolErrorGuidance;
use CLIO::Core::ConversationManager qw(
    load_conversation_history
    strip_messages_noise
    enforce_message_alternation
    generate_tool_call_id
    repair_tool_call_json
);
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);
use CLIO::Core::PromptBuilder;
use CLIO::Core::ContextBuilder qw();
use CLIO::Core::MessageHistory qw(messages_to_prose_dynamic);
use CLIO::Util::JSON qw(encode_json decode_json safe_decode_json safe_encode_json);
use CLIO::Core::Diagnostics qw(dump_diagnostic deduplicate_paragraphs);
use CLIO::Core::API::ErrorHandler;
use Encode qw(encode_utf8);  # For handling Unicode in JSON
use Time::HiRes qw(time sleep);
use Digest::MD5 qw(md5_hex);
use CLIO::Core::Interrupt qw(check pending clear set install_alrm_handler uninstall_alrm_handler with_alrm_handler);
use CLIO::Compat::Terminal qw(ReadKey ReadMode);  # Backward compat for legacy callers
use CLIO::Util::AtomicWrite qw(atomic_write);
use CLIO::Core::Defaults qw(DEFAULT_CONTEXT_WINDOW DEFAULT_MAX_RESPONSE_TOKENS);
use CLIO::Logging::ProcessStats;
use POSIX qw(strftime);

# Default ALRM interval (seconds) for interrupt scanning during tool execution.
# 250ms gives sub-second worst-case latency. Trade-off: 4x more wakeups per
# minute vs 1s. Cost is negligible (single non-blocking ReadKey per fire).
use constant INTERRUPT_ALRM_INTERVAL => 0.25;

# Default poll interval (milliseconds) for tools that need to check for
# interrupt during blocking I/O. Tools should call CLIO::Core::Interrupt::check()
# at least this often.
use constant INTERRUPT_POLL_INTERVAL_MS => 100;

# ANSI color codes for terminal output - FALLBACK only when UI is unavailable
=head1 NAME

CLIO::Core::WorkflowOrchestrator - Autonomous tool calling workflow orchestrator

=head1 DESCRIPTION

Implements the main workflow loop for OpenAI-compatible tool calling.
This replaces pattern matching with tool use by the AI.

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
        spinner => $args{spinner},  # Store spinner for interactive tools (interact)
        skip_custom => $args{skip_custom} || 0,  # Skip custom instructions (--no-custom-instructions)
        skip_ltm => $args{skip_ltm} || 0,        # Skip LTM injection (--no-ltm)
        non_interactive => $args{non_interactive} || 0,  # Non-interactive mode (--input flag)
        broker_client => $args{broker_client},   # Broker client for multi-agent coordination
        enable_tools => $args{enable_tools},     # Tool allowlist (comma-separated string or undef)
        disable_tools => $args{disable_tools},   # Tool blocklist (comma-separated string or undef)
        prompt_override => $args{prompt_override}, # System prompt name override
        consecutive_errors => 0,  # Track consecutive identical errors
        last_error => '',         # Track last error message
        max_consecutive_errors => 3,  # Break loop after 3 identical errors
    };
    
    bless $self, $class;
    
    # Apply default iteration limit for non-interactive mode
    # Prevents runaway oneshot agents that loop indefinitely
    if ($self->{non_interactive} && !$self->{max_iterations}) {
        $self->{max_iterations} = 200;  # Generous limit for complex tasks
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
        ui => $args{ui},  # Forward UI for interact
        spinner => $args{spinner},  # Forward spinner for interactive tools
        broker_client => $args{broker_client},  # Forward broker client for coordination
        api_manager => $args{api_manager},  # Forward api_manager for current model info
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
    
    # Initialize Plugin Manager
    eval {
        require CLIO::Core::PluginManager;
        $self->{plugin_manager} = CLIO::Core::PluginManager->new(
            config => $args{config},
            debug  => $args{debug},
        );
        my $loaded = $self->{plugin_manager}->load_plugins();
        if ($loaded > 0) {
            # Pass plugin manager to tool executor for plugin tool calls
            $self->{tool_executor}{plugin_manager} = $self->{plugin_manager};
        }
    };
    if ($@) {
        log_warning('WorkflowOrchestrator', "Plugin initialization failed: $@");
    }
    
    # Initialize prompt builder for system prompt construction
    my $enable_subagents = $self->{config} ? ($self->{config}->get('enable_subagents') // 1) : 1;
    my $auto_discover_skills = $self->{config} ? ($self->{config}->get('auto_discover_skills') // 1) : 1;
    # Read show_thinking here so PromptBuilder can include the
    # optional reasoning-steering paragraph when the user has chosen
    # to surface the thinking stream.
    #
    # Gate the steering paragraph on reasoning_mode='adaptive' AND
    # the model name matches the Anthropic family pattern
    # (sonnet/opus/haiku/fable/mythos). The Anthropic adaptive
    # summarizer genuinely needs the brief note (it collapses
    # trivial reasoning to empty otherwise); other providers' thinking
    # actively mis-trains when given the same instruction. reasoning_mode
    # alone is not enough - M3 also resolves to 'adaptive' but its
    # "adaptive" is the native reasoning format, not Anthropic's
    # summarizer-collapse case.
    my $show_thinking = $self->{config} ? ($self->{config}->get('show_thinking') // 0) : 0;
    my $needs_thinking_steering = 0;
    if ($show_thinking && $args{api_manager}) {
        eval {
            my $cur_model = $args{api_manager}->get_current_model();
            my $reasoning_mode = $args{api_manager}->_get_reasoning_mode($cur_model);
            if (defined $reasoning_mode && $reasoning_mode eq 'adaptive') {
                # Lazy require MCM - avoid hard dep at startup if not used
                require CLIO::Core::ModelCapabilitiesManager;
                my $mcm = CLIO::Core::ModelCapabilitiesManager->new(debug => 0);
                # _anthropic_model_reasoning_mode returns 'adaptive'/'enabled'/undef.
                # Only 'adaptive' here means the model is in the Anthropic family
                # and its adaptive summarizer is the one that collapses trivially.
                my $family_mode = $mcm->_anthropic_model_reasoning_mode($cur_model);
                $needs_thinking_steering = 1 if defined $family_mode && $family_mode eq 'adaptive';
            }
        };
        if ($@) {
            log_debug('WorkflowOrchestrator', "Failed to compute needs_thinking_steering: $@");
        }
    }
    log_debug('WorkflowOrchestrator', "needs_thinking_steering=" . ($needs_thinking_steering ? '1' : '0')
        . " (show_thinking=" . ($show_thinking ? '1' : '0') . ")");
    $self->{prompt_builder} = CLIO::Core::PromptBuilder->new(
        debug           => $args{debug},
        skip_custom     => $self->{skip_custom},
        skip_ltm        => $self->{skip_ltm},
        non_interactive => $self->{non_interactive},
        tool_registry   => $self->{tool_registry},
        mcp_manager     => $self->{mcp_manager},
        prompt_override => $self->{prompt_override},
        enable_tools    => $self->{enable_tools},  # Tool allowlist (for --chat mode)
        enable_subagents => $enable_subagents,
        auto_discover_skills => $auto_discover_skills,
        show_thinking   => $show_thinking,
        needs_thinking_steering => $needs_thinking_steering,
    );

    if ($auto_discover_skills) {
        log_debug('WorkflowOrchestrator', 'Auto-discover skills enabled - skill catalog will be injected into system prompt');
    }
    
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

=head2 _looks_premature_stop($content, $tool_calls_count)

Heuristic for detecting when the model has stopped mid-workflow after
executing tool calls. Returns 1 if the response looks like a premature
stop that should be nudged with a continuation message, 0 if the
response is a legitimate final answer.

Detection rules (any one triggers premature=1):
  - Empty content after at least one tool call (model went silent)
  - Short content (< 200 chars) after tool calls that ends mid-sentence
    (no terminal punctuation, or ends with `:`)

Long content (>= 200 chars) is always treated as a legitimate final
answer, even mid-sentence, because models writing that much are usually
actually finishing their thought. The complementary streaming-side
guard in APIManager (truncation detection) catches the case where the
connection drops mid-stream - this heuristic is the second line of
defense for responses that complete cleanly but look incomplete.

Arguments:
    $content           - The assistant's response content (string, may be empty)
    $tool_calls_count  - Number of tool calls executed so far in the workflow

Returns:
    1 if the response looks like a premature stop, 0 otherwise.

=cut

sub _looks_premature_stop {
    my ($self, $content, $tool_calls_count) = @_;

    return 0 unless $tool_calls_count && $tool_calls_count > 0;

    my $content_length = length($content // '');

    # Completely empty response after tool calls - definitely premature.
    if ($content_length == 0) {
        return 1;
    }

    # Long responses are treated as genuine final answers even if they
    # look mid-sentence - a model that wrote 200+ chars was probably
    # actually finishing its thought, not stopping mid-work.
    return 0 if $content_length >= 200;

    # Short response: check if it ends mid-sentence.
    my $trimmed = $content // '';
    $trimmed =~ s/\s+$//;
    # Ends with `:` (colon, e.g. "Let me check:") or no terminal
    # punctuation (`.`, `!`, `?` possibly followed by `)`/`]`) -> mid-work.
    if ($trimmed =~ /[:]\s*$/ || $trimmed !~ /[.!?][)\]]*\s*$/) {
        return 1;
    }

    return 0;
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
    
    # Build tool enable/disable sets from CLI flags and config
    # CLI flags (--enable/--disable) override config values
    my %enabled_set;   # allowlist: only these tools if non-empty
    my %disabled_set;  # blocklist: skip these tools
    
    my $enable_str = $self->{enable_tools}
        || ($self->{config} ? $self->{config}->get('enabled_tools') : undef);
    my $disable_str = $self->{disable_tools}
        || ($self->{config} ? $self->{config}->get('disabled_tools') : undef);
    
    if ($enable_str) {
        %enabled_set = map { $_ => 1 } split(/\s*,\s*/, $enable_str);
        log_debug('WorkflowOrchestrator', "Tool allowlist: " . join(', ', sort keys %enabled_set));
    }
    if ($disable_str && !$enable_str) {
        %disabled_set = map { $_ => 1 } split(/\s*,\s*/, $disable_str);
        log_debug('WorkflowOrchestrator', "Tool blocklist: " . join(', ', sort keys %disabled_set));
    }
    
    # Helper: check if a tool should be registered
    my $should_register = sub {
        my ($tool_name) = @_;
        if (%enabled_set) {
            return $enabled_set{$tool_name} ? 1 : 0;
        }
        if (%disabled_set) {
            return $disabled_set{$tool_name} ? 0 : 1;
        }
        return 1;  # Default: register
    };
    
    # All default tools with their module paths
    my @default_tools = (
        { name => 'file_operations',    module => 'CLIO::Tools::FileOperations' },
        { name => 'version_control',    module => 'CLIO::Tools::VersionControl' },
        { name => 'terminal_operations', module => 'CLIO::Tools::TerminalOperations' },
        { name => 'memory_operations',  module => 'CLIO::Tools::MemoryOperations' },
        { name => 'web_operations',     module => 'CLIO::Tools::WebOperations' },
        { name => 'todo_operations',    module => 'CLIO::Tools::TodoList' },
        { name => 'code_intelligence',  module => 'CLIO::Tools::CodeIntelligence' },
        { name => 'interact', module => 'CLIO::Tools::Interact' },
        { name => 'apply_patch',        module => 'CLIO::Tools::ApplyPatch' },
    );
    
    # Conditionally-available tools (existing config switches + sub-agent restrictions)
    my @conditional_tools = (
        {
            name => 'remote_execution',
            module => 'CLIO::Tools::RemoteExecution',
            config_key => 'enable_remote',
            subagent_blocked => 1,
        },
        {
            name => 'agent_operations',
            module => 'CLIO::Tools::SubAgentOperations',
            config_key => 'enable_subagents',
            subagent_blocked => 1,
        },
        {
            name => 'skill_operations',
            module => 'CLIO::Tools::SkillOperations',
            config_key => 'auto_discover_skills',
            subagent_blocked => 0,
        },
    );
    
    # Register standard tools
    for my $tool_def (@default_tools) {
        unless ($should_register->($tool_def->{name})) {
            log_debug('WorkflowOrchestrator', "Skipped $tool_def->{name}: filtered by --enable/--disable");
            next;
        }
        eval { (my $f = "$tool_def->{module}.pm") =~ s{::}{/}g; require $f };
        if ($@) {
            log_warning('WorkflowOrchestrator', "Failed to load $tool_def->{module}: $@");
            next;
        }
        $self->{tool_registry}->register_tool(
            $tool_def->{module}->new(debug => $self->{debug})
        );
    }
    
    # Register conditional tools (respect config switches AND enable/disable filtering)
    for my $tool_def (@conditional_tools) {
        unless ($should_register->($tool_def->{name})) {
            log_debug('WorkflowOrchestrator', "Skipped $tool_def->{name}: filtered by --enable/--disable");
            next;
        }
        
        # Check config-level feature switch
        my $config_enabled = $self->{config}
            ? $self->{config}->get($tool_def->{config_key})
            : 1;
        
        if (!$config_enabled) {
            log_debug('WorkflowOrchestrator', "Blocked $tool_def->{name}: disabled in config");
            next;
        }
        
        # Check sub-agent restriction
        if ($is_subagent && $tool_def->{subagent_blocked}) {
            log_debug('WorkflowOrchestrator', "Blocked $tool_def->{name}: sub-agent restriction");
            next;
        }
        
        eval { (my $f = "$tool_def->{module}.pm") =~ s{::}{/}g; require $f };
        if ($@) {
            log_warning('WorkflowOrchestrator', "Failed to load $tool_def->{module}: $@");
            next;
        }
        $self->{tool_registry}->register_tool(
            $tool_def->{module}->new(debug => $self->{debug})
        );
    }
    
    my $registered = $self->{tool_registry}->count_tools();
    log_debug('WorkflowOrchestrator', "Registered $registered tools (subagent=$is_subagent)");
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
    my $image_attachments = $opts{image_attachments};  # Array of ImageAttachment objects

    # Build messages array (system prompt + history + user input) and tool definitions
    my ($messages_ref, $tools) = $self->_build_turn_context($user_input, $session, $image_attachments);
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
    
    my $max_iter = $self->{max_iterations};
    while (!$max_iter || $iteration < $max_iter) {
        $iteration++;

        # Clear interrupt pending flag at start of each iteration
        $self->{_interrupt_pending} = 0;

        # Clear any stale user_interrupted session flag from a previous iteration.
        # This prevents the flag from being left over if an interrupt was partially
        # handled in a previous cycle (e.g. detected during streaming but the
        # _handle_interrupt path was skipped due to error recovery).
        # Use Interrupt::clear() so both the session-state flag and the
        # package-level global flag are reset - leaving the global flag set
        # would cause pending() to return a false positive on the next
        # iteration and incorrectly short-circuit the interrupt check.
        if ($session && $session->state() && $session->state()->{user_interrupted}) {
            log_debug('WorkflowOrchestrator', "Clearing stale user_interrupted flag from previous iteration");
            CLIO::Core::Interrupt::clear(session => $session);
        } elsif (CLIO::Core::Interrupt::pending()) {
            # Global flag set but session flag not (e.g. HTTP.pm streaming
            # loop detected the interrupt without a session reference).
            CLIO::Core::Interrupt::clear(session => $session);
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
        
        # Proactive trim: keep @messages within context budget on EVERY
        # iteration, including iteration 1. The projection in _build_turn_context
        # uses heuristic token estimates that can be inaccurate (especially for
        # local inference models where the resolved context_window may differ
        # from the runtime n_ctx). Running validate_and_truncate here is a
        # safety net: if the estimate was wrong and we're already over budget,
        # we trim before the API call instead of getting a 400 back.
        # validate_and_truncate pins the system prompt, first user message,
        # and last user message — it will not remove the current user input.
        if ($self->{api_manager}) {
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
                dump_diagnostic(
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
                dump_diagnostic(
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
                log_debug('WorkflowOrchestrator', "Proactive trim (pre-API): $pre_count -> " . scalar(@messages) . " messages");

                # No dynamic UC re-rendering after trim — the user context
                # (Working Directory, Language, Date) is cached per-minute by
                # PromptBuilder::get_user_context() and prepended to the user
                # input as a single user message at _build_turn_context
                # time. The compressed_tail (YaRN summary of dropped turns)
                # is included in the dynamic UC which is prepended to the
                # user message. It survives because the last user message
                # is pinned by MessageValidator::_role_based_tail_walk.
            }
        }

        # Enforce message alternation
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
        
        # Send to AI with tools (streaming required for GitHub Copilot quota headers)
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
                    log_debug('WorkflowOrchestrator', "Interrupt detected during streaming");
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
        
        # Check for user interrupt after API call completes. The API
        # call can take 30-60+ seconds, so this is a critical check
        # point. Also check if interrupt was detected during streaming
        # (via _interrupt_pending flag).
        if ($self->{_interrupt_pending}) {
            # Interrupt was detected during streaming (the on_chunk
            # callback set _interrupt_pending when it saw the ALRM
            # flag). Call _handle_interrupt directly so the user gets
            # prompted via the interact tool on the first ESC instead
            # of having to press ESC repeatedly to bypass the short-
            # circuit in _check_and_handle_interrupt.
            $self->_handle_interrupt($session, \@messages);
            $self->{_interrupt_pending} = 0;
            $iteration--;  # Don't count this iteration
            next;
        }
        if ($self->_check_and_handle_interrupt($session, \@messages)) {
            $self->{_interrupt_pending} = 0;
            $iteration--;  # Don't count this iteration
            next;
        }
        
        # Capture payload before returning on API eval failure so the
        # session can be resumed via fast-path instead of falling back to
        # the rebuild path (which may diverge from what was sent to the API).
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
                # Capture payload before fatal error return so the session
                # can be resumed via fast-path on a later turn.
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
        delete $session->{routing_attempts} if $session;  # Reset model routing counter on success
        delete $session->{provider_rate_limits} if $session;  # Clear per-provider rate limit cooldowns on success

        # Snapshot capture happens at the success-path return below, not here.
        # At this point @messages still reflects only what was sent to the API
        # for this iteration - the tool_results that _execute_tool_round will
        # append on the next line have not yet been merged in. Capturing here
        # would store a stale pre-tool state and cause the resume fast path
        # to drop the tool_results on the next turn (the divergence bug fixed
        # by moving snapshot capture to end-of-turn).

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
            my $extractor = CLIO::Core::ToolCallExtractor->new(
                debug => $self->{debug},
                known_tools => $self->{tools} || [],
            );
            
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
        
        # Extract session naming marker from response content (regardless of tool calls)
        # The AI may include the marker in its first response alongside tool calls
        # Always strip the marker and always set the name (allows renaming during session)
        if ($session && $session->can('session_name')) {
            my $content = $api_response->{content} // '';
            my ($cleaned, $named) = $self->_extract_session_marker($content, $session);
            $api_response->{content} = $cleaned if $named;
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

            # Check for tool error loop break before looping back.
            if (my $break = delete $self->{_tool_error_loop_break}) {
                my $msg = sprintf(
                    "Tool error loop broken: %d consecutive identical errors from '%s' "
                    . "(sig: %s). Enhanced error guidance with schema help has been "
                    . "injected into the message array and saved to session history. "
                    . "Please review the error and try a different approach.",
                    $break->{count} // 3,
                    $break->{tool} || 'unknown',
                    $break->{sig} || '',
                );
                # Capture payload before breaking the tool error loop so
                # the session can be resumed via fast-path on a later turn.
                return {
                    success => 0,
                    error => $msg,
                    error_type => 'tool_error_loop',
                    tool_name => $break->{tool},
                    tool_error => $break->{error},
                    iterations => $iteration,
                    tool_calls_made => \@tool_calls_made,
                };
            }

            # Loop back - AI will process tool results
            next;
        }
        
        # No tool calls - check for premature workflow stop. Upstream
        # APIs sometimes return finish_reason=stop with empty or
        # minimal content when the model is mid-workflow. Also
        # catches mid-sentence truncation from Z.AI and MiniMax that
        # return finish_reason=stop after very short responses.
        if ($premature_stop_retries < $max_premature_stop_retries) {
            my $content = $api_response->{content} // '';
            my $content_length = length($content);
            my $tool_calls_count = scalar @tool_calls_made;
            my $looks_premature = $self->_looks_premature_stop($content, $tool_calls_count);

            if ($looks_premature) {
                if ($content_length == 0) {
                    log_debug('WorkflowOrchestrator', "Premature stop detected: empty response after $tool_calls_count tool calls");
                } else {
                    log_debug('WorkflowOrchestrator', "Premature stop detected: short mid-sentence response ($content_length chars) after $tool_calls_count tool calls");
                }
                $premature_stop_retries++;
                log_debug('WorkflowOrchestrator', "Premature workflow stop detected (retry $premature_stop_retries/$max_premature_stop_retries). Nudging model to continue.");
                
                # Save any partial content as assistant message
                if ($content_length > 0) {
                    push @messages, {
                        role => 'assistant',
                        content => $content,
                    };
                }
                
                # Inject a continuation nudge as a NEW user message at
                # the end. The model sees the history block, then its
                # own previous response, then the nudge. A short active
                # instruction works better than passive variants
                # ("please continue", "as you were") - those often
                # cause the model to echo its last message and re-emit
                # a tool-call.
                push @messages, {
                    role => 'user',
                    content => "Your previous response ended without completing your work. "
                             . "Continue from where you stopped, producing the remaining text or tool calls "
                             . "needed to finish. Do not repeat what you already wrote."
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
        if ($session && $session->can('session_name')) {
            my ($cleaned, $named) = $self->_extract_session_marker($final_content, $session);
            $final_content = $cleaned if $named;
        }

        # Remove conversation tags if present
        $final_content =~ s/^\[conversation\]//;
        $final_content =~ s/\[\/conversation\]$//;
        $final_content =~ s/^\s+|\s+$//g;
        
        # Deduplicate repeated paragraphs within the response.
        # Models sometimes echo the same paragraph twice in a row, especially
        # after tool-calling workflows where they see their own prior output.
        $final_content = deduplicate_paragraphs($final_content);
        
        # Save the final assistant text response to session history.
        # During tool-calling workflows, _execute_tool_round saves intermediate
        # assistant+tool message pairs. But the FINAL text-only response (the one
        # that ends the loop) is not saved there - it exits through here.
        # Without this save, the final message is streamed to screen but never
        # persisted, causing context loss on the next turn.
        if (@tool_calls_made > 0 && length($final_content) > 0 && $session && $session->can('add_message')) {
            eval {
                my $sanitized = sanitize_text($final_content);
                # Persist thinking/reasoning metadata alongside the final text so
                # the next turn can replay it (Anthropic thinking continuity,
                # OpenAI Responses reasoning chaining, OpenRouter reasoning_details).
                $session->add_message('assistant', $sanitized, {
                    reasoning_content  => $api_response->{reasoning_content}  // $api_response->{accumulated_reasoning},
                    reasoning_details  => $api_response->{reasoning_details},
                    reasoning_blocks   => $api_response->{reasoning_blocks},
                    responses_reasoning_items => $api_response->{responses_reasoning_items},
                });
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
            # All messages are saved during workflow execution. This flag
            # prevents Chat.pm from saving duplicates.
            messages_saved_during_workflow => (@tool_calls_made > 0) ? 1 : 0
        };

        # Session is already saved via add_message calls in _execute_tool_round
        # and the final assistant save above.
        # Snapshot the exact @messages for fast-path resume on next session
        # startup. The snapshot includes everything the model just saw:
        # system prompt, history, user input, dynamic userContext, and all
        # assistant/tool/results from this turn. Stored in Session::State
        # and checked by _build_turn_context for trim decisions.

        # previous_response_id should ALWAYS be included when available (see APIManager.pm).
        # Skipping it for tool calls was causing unnecessary credit charges.

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

    # Even on iteration-limit exit, capture the payload so a resume
    # picks up from the current state rather than rebuilding from
    # load_conversation_history (which may diverge and cause looping).

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
user message injection, image attachments, and MCP tool merging.

Returns: ($messages_arrayref, $tools_arrayref)

=cut

sub _build_turn_context {
    my ($self, $user_input, $session, $image_attachments) = @_;

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

    # Build tool definitions.
    my $tools = $self->_build_tools_for_api();

    log_debug('WorkflowOrchestrator', "Processing input: '$user_input'");

    # Build messages: system prompt + history + user input
    my @messages = ();

    my $system_prompt = $self->{prompt_builder}->build_system_prompt($session);
    push @messages, { role => 'system', content => $system_prompt };
    log_debug('WorkflowOrchestrator', "Added system prompt with tools (" . length($system_prompt) . " chars)");

    # context_files are folded into the dynamic userContext block below
    # via context_files_block in the projection, so they sit at the
    # recency anchor without polluting the cache-stable prefix.

    # Get model capabilities for token budget sync
    my $model_caps = $self->{api_manager}
        ? ($self->{api_manager}->get_model_capabilities() || {})
        : {};

    # Update session state's max_tokens to match model's actual context window.
    # This ensures State::add_message trims at the correct threshold instead
    # of the default 128k, which would underutilize large-context models.
    my $ctx_window = $model_caps->{max_context_window_tokens};
    log_debug('WorkflowOrchestrator', "State max_tokens check: ctx_window=" . ($ctx_window // 'undef') . ", session=" . (defined $session ? ref($session) : 'undef'));
    if ($ctx_window && $session && $session->can('state')) {
        my $state = $session->state();
        log_debug('WorkflowOrchestrator', "State object: " . (defined $state ? ref($state) . ", max_tokens=" . ($state->{max_tokens} // 'undef') : 'undef'));
        if ($state && ($state->{max_tokens} // 0) != $ctx_window) {
            $state->{max_tokens} = $ctx_window;
            log_debug('WorkflowOrchestrator', "Updated session max_tokens to $ctx_window (model context window)");
        }
    }

    # Also sync max_output_tokens so SessionState::add_message's internal
    # trim uses the correct output reserve. Without this, State falls
    # back to DEFAULT_MAX_OUTPUT_TOKENS (16K) regardless of the model's
    # actual output cap - critically wrong for models with large output
    # windows (e.g. MiniMax-M3 1M ctx / 128K output) where the 16K default
    # would over-trim dialog, or for models with small output caps where
    # 16K would under-reserve.
    if ($session && $session->can('state')) {
        my $state = $session->state();
        my $max_output = $model_caps->{max_output_tokens};
        if ($max_output && $state && ($state->{max_output_tokens} // 0) != $max_output) {
            log_debug('WorkflowOrchestrator',
                "Updated session max_output_tokens from " . ($state->{max_output_tokens} // 0) . " to $max_output");
            $state->{max_output_tokens} = $max_output;
        }
    }
    
    my $history = load_conversation_history($session, debug => $self->{debug});

    if ($history && @$history) {
        # messageHistory feature: noise-strip reasoning_content from
        # old assistant messages before the projection. This preserves
        # more of the actual conversation (user/assistant text + tool
        # results) at the same token cost. NO tail-walk drop here —
        # the full noise-stripped history reaches ContextBuilder, which
        # selects the recent window and compresses the rest via YaRN.
        # A pre-trim tail walk would drop old messages before the
        # projection can summarize them (permanent data loss). The
        # proactive _role_based_tail_walk enforces the token budget
        # with its own compression.
        $history = strip_messages_noise(
            $history,
            debug => $self->{debug},
        );
    }

    # Build the relevance-aware projection. This selects the anchor
    # turn (original substantive task), the most recent complete turn(s),
    # collapses repeated tool calls within each recent turn, scores LTM
    # entries against the current request, and prepares the structured
    # context. Raw $history is never mutated; the projection is discarded
    # after serialization.
    #
    # The projection always runs, including on the first turn when
    # history is empty. Build_projection handles empty anchor/turns
    # gracefully. The first turn still gets the user context (working
    # directory, language, datetime) via get_user_context(), which is
    # cached per-minute for byte stability.

    my $projection;

    my $ltm_entries = $self->_read_ltm_entries_for_projection($session);
    $projection = CLIO::Core::ContextBuilder::build_projection(
        history             => $history,
        user_input          => $user_input,
        active_task         => $self->_active_task_text($session, $user_input),
        active_todos        => $self->_read_active_todos_for_projection($session),
        ltm                 => $ltm_entries,
        unresolved          => $self->_collect_unresolved_state($history, $session),
        context_files_block => $self->_render_context_files_for_user_context($session),
        session             => $session,
    );

    # Push the projection's selected history (anchor + recent turns)
    # directly as role-based messages. The projection's `anchor` and
    # `turns` fields are already arrayrefs of role-based messages
    # (selected + deduped by build_projection); we just splice them
    # in. The user_context (CWD, Date, Lang) is prepended to the user
    # input as a single user message.
    #
   # Resulting message layout (ONE layout, every turn):
   #   [0]     system_prompt                        (cache-stable)
   #   [1..N]  anchor + recent turn messages         (role-based)
    #   [N+1]   user_context + dynamic UC + user_input   (single user msg)
    #   [N+2..] assistant/tool/final_assistant            (current turn)
    # The dynamic UC (active_todos, compressed_tail, context_files) is
    # prepended to the user message. It must NOT be a separate system
    # message placed between history and user input — that breaks
    # message ordering for OpenAI-compatible providers (tool_calling
    # breaks when system appears after history messages).
   #
   # user_context (CWD, Date, Lang) is cached per-minute by
   # PromptBuilder::get_user_context() — no per-iteration re-rendering,
   # no position drift. The user message is never re-positioned.

    # Dynamic UC (active_todos, compressed_tail, context_files) rendered
    # from the projection. Prepended to the user message below.
    my $dynamic_uc = '';

    if ($projection) {
        if (my $anchor = $projection->{anchor}) {
            if (ref($anchor) eq 'ARRAY' && @$anchor) {
                push @messages, @$anchor;
            }
        }
        # Push each recent turn's messages (latest 1-2 complete turns).
        # Each turn is an arrayref of role-based messages starting
        # with the user message; we splice them in directly.
        for my $turn (@{ $projection->{turns} || [] }) {
            next unless ref($turn) eq 'ARRAY' && @$turn;
            push @messages, @$turn;
        }

       # Inject the dynamic UC so the model has the compressed summary
       # of dropped turns, active todos, and context files. It is
       # prepended to the user message below, NOT pushed as a separate
       # system message — system-after-history breaks message alternation
       # and tool_calling for OpenAI-compatible APIs.
       $dynamic_uc = messages_to_prose_dynamic($projection);
        # Dynamic UC is prepended to the user message below, not pushed
        # as a separate system message — system-after-history breaks
        # message alternation and tool_calling for OpenAI-compatible APIs.
        if (length($dynamic_uc)) {
            log_debug('WorkflowOrchestrator', "Dynamic UC rendered (" . length($dynamic_uc) . " chars), will prepend to user message");
        }

        # Stash the projection on $self for interrupt handling.
        # The interrupt handler uses the stashed active_task to
        # build a cancel/continue message.
        $self->{_current_projection} = $projection;
        log_debug('WorkflowOrchestrator',
            "Added role-based history (" . scalar(@{$projection->{turns} || []}) . " recent turn(s))");
        log_debug('WorkflowOrchestrator', "Stashed projection for interrupt handling only");
    }
    # Projection is always built above, so this branch is unreachable.

   # User context (cached per-minute) + user input concatenated as a
   # SINGLE user message at a stable position. Context files are
   # rendered into the dynamic UC system message above, not here.
   my $user_context = $self->{prompt_builder}->get_user_context();
    my $user_message = $user_context;
    if (length($dynamic_uc)) {
        $user_message .= $dynamic_uc;
    }
    $user_message .= $user_input;
   push @messages, { role => 'user', content => $user_message };

    # If image attachments are present, convert user message to array-format content
    # Only build multimodal content if the model supports vision
    if ($image_attachments && @$image_attachments) {
        my $supports_vision = 0;
        if ($self->{api_manager} && $self->{api_manager}->can('model_supports_vision')) {
            $supports_vision = $self->{api_manager}->model_supports_vision();
        }
        
        if ($supports_vision) {
            my $last_msg = $messages[-1];
            if ($last_msg && $last_msg->{role} eq 'user') {
                my @content_parts = (
                    { type => 'text', text => $last_msg->{content} },
                );
                for my $attachment (@$image_attachments) {
                    my $part = $attachment->to_openai_part();
                    if ($part) {
                        push @content_parts, $part;
                        log_debug('WorkflowOrchestrator', "Added image attachment: " . $attachment->file_path);
                    }
                }
                $last_msg->{content} = \@content_parts;
            }
        } else {
            log_debug('WorkflowOrchestrator', "Model does not support vision - image attachments will be sent as text descriptions");
            # Append text descriptions of images to the user message instead
            my $last_msg = $messages[-1];
            if ($last_msg && $last_msg->{role} eq 'user') {
                my $descriptions = join("\n", map { $_->to_text_description() } @$image_attachments);
                $last_msg->{content} .= "\n\n$descriptions";
            }
        }
    }

    # Save user message to session history NOW (before processing)
    if ($session && $session->can('add_message')) {
        # Defense in depth: $user_input must be a string. Refs (hash/array) would
        # corrupt the session JSON and pollute the model's context. If we see one,
        # log it loudly and coerce to a stringified representation so the session
        # remains at least recoverable. The real fix is upstream (Chat.pm must not
        # leak ReadLine control signals), but this prevents silent corruption.
        if (ref $user_input) {
            log_error('WorkflowOrchestrator', sprintf(
                "BUG: user_input is a %s ref (not a string) - this indicates a ReadLine "
                . "control signal leaked into user input. Stringifying to preserve session.",
                ref $user_input
            ));
            if (ref $user_input eq 'HASH' && defined $user_input->{type}) {
                $user_input = "[INVALID INPUT: ReadLine control signal '$user_input->{type}' "
                    . "leaked into user input - this is a bug, please report]";
            } else {
                $user_input = "[INVALID INPUT: non-string ref of type " . ref($user_input) . "]";
            }
        }
        # Store text description of images for session history (not base64 data)
        my $history_content = $user_input;
        if ($image_attachments && @$image_attachments) {
            $history_content .= "\n\n" . join("\n", map { $_->to_text_description() } @$image_attachments);
        }
        $session->add_message('user', $history_content);
        log_debug('WorkflowOrchestrator', "Saved user message to session history (raw input)");

        # Derive a session name from the first user message. Marker-
        # based renames still work via _extract_session_marker when a
        # user explicitly emits one.
        if ($session->can('state') && $session->state()) {
            $session->state()->auto_name_session();
        }
    }

    # Tools already built at the top of _build_turn_context (needed for
    # fast-path signature check). Reuse here.
    log_debug('WorkflowOrchestrator', "Loaded " . scalar(@$tools) . " tool definitions");

    return (\@messages, $tools);
}

=head2 _build_tools_for_api($session)

Build the full tool definitions array including core tool registry + MCP
tools + plugin tools. Used by _build_turn_context for every turn.

Returns: Arrayref of tool definition hashes.

=cut

sub _build_tools_for_api {
    my ($self) = @_;

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

    if ($self->{plugin_manager}) {
        eval {
            require CLIO::Tools::PluginBridge;
            my $plugin_defs = CLIO::Tools::PluginBridge->generate_tool_definitions($self->{plugin_manager});
            if ($plugin_defs && @$plugin_defs) {
                for my $plugin_def (@$plugin_defs) {
                    push @$tools, {
                        type     => 'function',
                        function => {
                            name        => $plugin_def->{name},
                            description => $plugin_def->{description},
                            parameters  => $plugin_def->{parameters},
                        },
                    };
                }
                log_debug('WorkflowOrchestrator', "Added " . scalar(@$plugin_defs) . " plugin tool(s) to API definitions");
            }
        };
        log_warning('WorkflowOrchestrator', "Plugin tool definition error: $@") if $@;
    }

    return $tools;
}

=head2 invalidate_tool_cache

Invalidate the cached tool definitions. Call this when MCP servers or plugins
are added/removed, or when tool definitions change.

=cut

sub invalidate_tool_cache {
    my ($self) = @_;
    delete $self->{_current_projection};
    log_debug('WorkflowOrchestrator', "Projection cache invalidated");
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
        if ($self->{_interrupt_pending}) {
            # Interrupt detected during a previous streaming chunk - handle
            # it directly (same fix as the post-API-call check above).
            $self->_handle_interrupt($session, $messages);
            $self->{_interrupt_pending} = 0;
            last;
        }
        if ($self->_check_and_handle_interrupt($session, $messages)) {
            log_debug('WorkflowOrchestrator', "Interrupt detected between tool executions, skipping remaining tools");
            last;
        }
        
        # Check for pending authorization requests from child agents
        # This allows the primary to service auth prompts even during its own tool loop
        $self->_check_authorization_requests();

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
                    if ($self->{non_interactive}) {
                        # Machine-readable: emit [THINKING] or [CONTENT] tag
                        if ($content =~ /^<!--thinking-->/s) {
                            $content =~ s/^<!--thinking-->\s*//;
                            $content =~ s/<!--\/thinking-->\s*$//;
                            print "[THINKING] $content\n" if length($content) > 0;
                        } else {
                            print "[CONTENT] $content\n";
                        }
                        STDOUT->flush() if STDOUT->can('flush');
                    } else {
                        $self->{ui}->display_assistant_message($content);
                        print "\n";
                    }
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
        my $raw_args = $tool_call->{function}->{arguments};
        my $tool_args = ref($raw_args) ? $raw_args : safe_decode_json($raw_args // '{}');
        my $tool_operation = ($tool_args && $tool_args->{operation}) ? $tool_args->{operation} : '';
        
        # Skip display for internal-only operations and self-displaying tools
        my $suppress_display = ($tool_name eq 'terminal_operations' && $tool_operation eq 'validate')
                            || ($tool_name eq 'interact');
        
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
            log_debug('WorkflowOrchestrator', "UI on_tool_end callback error: $@") if $@;
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
        # action_description into expanded_content for hrule formatting
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
            
            # For interact tool results, extract session marker from user response
            # and strip it from the content sent to AI
            if ($tool_name eq 'interact' && $session && $session->can('session_name') && defined $ai_content) {
                my ($cleaned, $named) = $self->_extract_session_marker($ai_content, $session);
                if ($named) {
                    $ai_content = $cleaned;
                    log_debug('WorkflowOrchestrator', "Extracted session marker from interact output");
                }
            }
        }

        # Track tool calls made
        push @$tool_calls_made, {
            name => $tool_name,
            arguments => $tool_call->{function}->{arguments},
            result => $ai_content
        };

        # Detect repeated identical-shape tool errors and break the loop.
        # When a model emits a malformed tool call (e.g. missing 'operation'
        # field, using 'command' instead of 'operation', or malformed JSON),
        # CLIO returns a TOOL ERROR + full schema help to @messages. The same
        # error repeating N=3 times means the model is stuck and just burning
        # context budget on schema dumps. After N=3, we set a break flag that
        # causes process_input to return an error result instead of continuing
        # the loop with another API call. The caller surfaces the error to the
        # user and the turn ends — the model can't ignore a break the way it
        # can ignore "STOP" text in a tool result.
        #
        # Loop signature: tool|operation|error_category. The category is
        # computed by ToolErrorGuidance::categorize_error which produces a
        # stable enum (missing_required, invalid_operation, directory_not_found,
        # etc.). The OLD signature used the first 80 chars of the raw error,
        # which had two failure modes:
        #   1. Slight variance in the error text (timestamps, IDs, line
        #      numbers) reset the count to 1.
        #   2. Different operation names that resolved to the same root
        #      cause (e.g. "exec" vs "execute") reset the count.
        # The category-based signature is robust to both: the categorizer
        # reduces the noisy raw text to one of ~20 stable enums.
        if ($is_error && $result_data && ref($result_data) eq 'HASH') {
            my $err_category = 'unknown';
            if ($self->{error_guidance} && $self->{error_guidance}->can('categorize_error')) {
                eval {
                    $err_category = $self->{error_guidance}->categorize_error(
                        $result_data->{error} // '',
                        $tool_name,
                    );
                };
                $err_category = 'unknown' if $@;
            }
           my $err_sig = join("|",
               $tool_name,
               $tool_operation || '',
               $err_category
           );
            # Track the iteration alongside the error signature so parallel
            # tool calls in the same iteration don't inflate the consecutive
            # count. Only errors from DIFFERENT iterations (true sequential
            # retries) count toward the loop-break threshold.
            my $last_iter = $self->{_tool_error_loop_last_iteration};
            my $same_sig  = (defined $self->{_tool_error_loop_last_sig}
                             && $self->{_tool_error_loop_last_sig} eq $err_sig);
            my $same_iter = (defined $last_iter && $last_iter == $iteration);
            if (!defined $self->{_tool_error_loop_count}) {
                $self->{_tool_error_loop_count} = {};
                $self->{_tool_error_loop_last_sig} = undef;
                $self->{_tool_error_loop_last_iteration} = undef;
            }
            if ($same_sig && !$same_iter) {
                # Same error, different iteration = sequential retry
                $self->{_tool_error_loop_count}{$err_sig}++;
            } elsif (!($same_sig && $same_iter)) {
                # New error type, or first error in this iteration.
                # (If same_sig && same_iter: parallel call, leave count unchanged.)
                $self->{_tool_error_loop_count}{$err_sig} = 1;
            }
            # If same_sig && same_iter (parallel call), don't increment.
            $self->{_tool_error_loop_last_sig} = $err_sig;
            $self->{_tool_error_loop_last_iteration} = $iteration;
            my $count = $self->{_tool_error_loop_count}{$err_sig};
            if ($count >= 3) {
                # Break the error loop instead of injecting "STOP" text
                # (which the model can ignore). Set a flag that causes
                # process_input to return an error result, so the caller
                # surfaces the error to the user and the turn ends.
                $self->{_tool_error_loop_break} = {
                    tool  => $tool_name,
                    error => $result_data->{error} // '',
                    count => $count,
                    sig   => $err_sig,
                };
                log_warning('WorkflowOrchestrator',
                    "Tool error loop: $count consecutive errors from $tool_name ($err_category). "
                    . "Breaking to user.");
            }
        } else {
            # Reset loop tracking on a successful tool call.
            $self->{_tool_error_loop_count} = {};
            $self->{_tool_error_loop_last_sig} = undef;
            $self->{_tool_error_loop_last_iteration} = undef;
        }

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
                        {
                            tool_calls => $$pending_msg_ref->{tool_calls},
                            reasoning_content => $$pending_msg_ref->{reasoning_content},
                            # Persist every reasoning format present on the
                            # pending message so providers can replay them on
                            # the next turn (Anthropic thinking, OpenAI
                            # Responses chaining, OpenRouter reasoning_details).
                            reasoning_details => $$pending_msg_ref->{reasoning_details},
                            reasoning_blocks  => $$pending_msg_ref->{reasoning_blocks},
                            responses_reasoning_items => $$pending_msg_ref->{responses_reasoning_items},
                        }
                    );
                    log_debug('WorkflowOrchestrator', "Saved assistant message with tool_calls to session (on first tool result)");
                    $$pending_msg_ref = undef;
                }

                # Save error results to session. When the tool error
                # loop breaks, the enhanced guidance (with schema help)
                # must persist in session history so the model sees it on
                # resume. For non-loop-break errors, we still save the
                # enhanced content so the model gets schema guidance on
                # the next iteration — but we cap it to avoid bloating
                # session files with huge schema dumps across many turns.
                my $session_content = $sanitized_content;
                if ($is_error && $result_data && ref($result_data) eq 'HASH') {
                    my $loop_break = $self->{_tool_error_loop_break};
                    my $enhanced = $enhanced_error_for_ai;
                    if ($enhanced && (!$loop_break || $loop_break->{tool} eq $tool_name)) {
                        # Save enhanced guidance when it helps the model fix
                        # the error. Truncate very large schema dumps.
                        $session_content = sanitize_text($enhanced);
                        if (length($session_content) > 4096) {
                            $session_content = substr($session_content, 0, 4096)
                                . "\n... [truncated for session storage]";
                        }
                    } else {
                        $session_content = sanitize_text(
                            $result_data->{error} // "$tool_name: tool call failed"
                        );
                    }
                }
                $session->add_message(
                    'tool',
                    $session_content,
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
    # Skip if last tool was interact (its output already provides separation)
    my $last_tool = @$ordered_tools ? ($ordered_tools->[-1]->{function}->{name} || '') : '';
    if ($last_tool ne 'interact') {
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
#   6. Ordering: other blocking -> serial -> parallel -> interact (last)
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

    # Stash invalid-JSON tool_results here. Phase 1 fills this when it
    # rejects a tool_call whose arguments can't be parsed/repaired. Phase 2
    # flushes this AFTER pushing the assistant message so Anthropic's
    # tool_use/tool_result position-pairing check passes. Cleared at the
    # end of every call so no leak across iterations.
    $self->{_deferred_invalid_tool_results} = [];

    # ── Phase 1: Validate tool_call argument JSON ────────────────────
    my @validated_tool_calls = ();
    my $had_validation_errors = 0;

   for my $tool_call (@{$api_response->{tool_calls}}) {
      my $tool_name = $tool_call->{function}->{name} || 'unknown';

        # Guard: reject tool calls with suspicious names. When the model
        # is near the context window limit it can emit malformed output —
        # code fragments, regex patterns, or XML markup leak through as
        # the tool name. These pass JSON-argument validation (args like
        # {"key":"value"}) but produce a cascade of "Unknown tool" errors
        # that corrupt the conversation. A valid tool name is alphanumeric
        # plus underscore/hyphen only.
        unless ($tool_name =~ /^[a-zA-Z_][a-zA-Z0-9_-]*$/) {
           log_warning('WorkflowOrchestrator',
               "Rejecting tool call with suspicious name: '$tool_name' " .
               "(contains markup/regex/non-identifier chars - likely " .
               "model degradation near context limit)");
           $had_validation_errors = 1;
            push @{$self->{_deferred_invalid_tool_results}}, {
                role => 'tool',
                tool_call_id => $tool_call->{id},
                name => $tool_name,
                content => "ERROR: Tool call rejected — the tool name '$tool_name' is not a valid identifier. The model likely emitted malformed output. Retrying with a corrected request."
            };
            next;
        }
       my $arguments_raw = $tool_call->{function}->{arguments};

        # Defensive: some servers (e.g., llama.cpp) send arguments as a parsed
        # JSON object instead of a string.  Re-encode to a string if needed.
        if (ref($arguments_raw)) {
            log_debug('WorkflowOrchestrator',
                "Tool '$tool_name' arguments is " . ref($arguments_raw) . " - re-encoding to JSON string");
            $arguments_raw = safe_encode_json($arguments_raw, '{}');
            $tool_call->{function}->{arguments} = $arguments_raw;
        }

        my $arguments_str = $arguments_raw // '{}';

        my $arguments_valid = 0;
        my $parsed_args;
        eval {
            my $json_bytes = utf8::is_utf8($arguments_str) ? encode_utf8($arguments_str) : $arguments_str;
            $parsed_args = decode_json($json_bytes);
            $arguments_valid = 1;
        };

       if ($@) {
           my $error = $@;
           my $repaired = repair_tool_call_json($arguments_str, debug => $self->{debug});

           if ($repaired) {
               log_debug('WorkflowOrchestrator', "Repaired malformed JSON for tool '$tool_name'");
               $tool_call->{function}->{arguments} = $repaired;
                # Parse the repaired JSON once and stash it as _parsed_args
                # so execute_tool reuses it without re-parsing (and without
                # re-running repair_malformed_json, which is not idempotent:
                # double-repair on already-repaired JSON can corrupt it by
                # matching garbage-stripping patterns inside valid JSON).
                eval {
                    my $repaired_bytes = utf8::is_utf8($repaired) ? encode_utf8($repaired) : $repaired;
                    $tool_call->{_parsed_args} = decode_json($repaired_bytes);
                };
                if ($@) {
                    # Repaired JSON still doesn't parse — treat as unrepaired.
                    $tool_call->{_parsed_args} = undef;
                    log_debug('WorkflowOrchestrator', "Repaired JSON for '$tool_name' still failed to parse on second decode — rejecting");
                    push @{$self->{_deferred_invalid_tool_results}}, {
                        role => 'tool',
                        tool_call_id => $tool_call->{id},
                        name => $tool_name,
                        content => "ERROR: Tool call rejected due to invalid JSON in arguments. The repaired parameters could not be parsed. Please check JSON syntax."
                    };
                    $had_validation_errors = 1;
                    next;
                }
               push @validated_tool_calls, $tool_call;
           } else {
                $had_validation_errors = 1;
                log_debug('WorkflowOrchestrator', "Invalid JSON in tool call arguments for '$tool_name': $error");
                log_debug('WorkflowOrchestrator', "Malformed arguments: " . substr($arguments_str, 0, 200));
                log_debug('WorkflowOrchestrator', "Could not repair JSON for tool '$tool_name' - tool call will be skipped");

                # DEFER the tool_result push. The Phase-2 assistant message is
                # built with @validated_tool_calls only (no invalid tool_calls),
                # so pushing the tool_result BEFORE the assistant message
                # orphans the tool_result: Anthropic's "tool_use block must have
                # a corresponding tool_result in the next message" check fails
                # because the tool_result lands in a user message BEFORE any
                # assistant message carries the matching tool_use. Stash
                # here and flush after the assistant message lands.
                push @{$self->{_deferred_invalid_tool_results}}, {
                    role => 'tool',
                    tool_call_id => $tool_call->{id},
                    name => $tool_name,
                    content => "ERROR: Tool call rejected due to invalid JSON in arguments. The AI generated malformed parameters that could not be parsed. Please retry with valid JSON."
                };
            }
        } else {
            # Stash parsed args for downstream reuse (avoids re-parsing in Phase 3 and ToolExecutor)
            $tool_call->{_parsed_args} = $parsed_args;
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
        # Discard any deferred invalid-JSON tool_results - with no
        # assistant-with-tool_calls message in the conversation, they
        # would be orphan. Anthropic rejects orphan tool_results (they
        # require a preceding assistant with tool_use), so we drop them
        # here. The assistant content above already tells the model to
        # retry with valid JSON.
        $self->{_deferred_invalid_tool_results} = [];
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
        # Also set reasoning_content for DeepSeek API compatibility
        $assistant_msg->{reasoning_content} = $api_response->{reasoning_content} // $api_response->{accumulated_reasoning};
    }
    # Native providers (Anthropic, Google) capture thinking blocks with
    # signature / redacted_thinking / thoughtSignature for multi-turn round-trip.
    # The OpenAI-format providers carry reasoning_details; the native ones
    # carry reasoning_blocks. Both are persisted here and replayed by the
    # provider's convert_messages for the next turn.
    if ($api_response->{reasoning_blocks} && ref($api_response->{reasoning_blocks}) eq 'ARRAY') {
        $assistant_msg->{reasoning_blocks} = $api_response->{reasoning_blocks};
    }
    # Responses API: encrypted_content + phase for the next-turn replay
    # (used by Responses API endpoints like codex, gpt-5.x).
    if ($api_response->{responses_reasoning_items} && ref($api_response->{responses_reasoning_items}) eq 'ARRAY') {
        $assistant_msg->{responses_reasoning_items} = $api_response->{responses_reasoning_items};
    }
    push @$messages, $assistant_msg;

    # Flush deferred invalid-JSON tool_results now that the assistant
    # message has been pushed. Order matters: tool_result must come AFTER
    # the assistant message that carried the matching tool_use blocks.
    # Anthropic's pairing check is by position, so a tool_result before
    # any assistant with tool_use triggers a "tool_result for tool_use_id
    # N found in user message that doesn't immediately follow an
    # assistant message with that tool_use" error. Anthropic accepts
    # tool_results with no matching tool_use rather than rejecting.
    if ($self->{_deferred_invalid_tool_results} && @{$self->{_deferred_invalid_tool_results}}) {
        push @$messages, @{$self->{_deferred_invalid_tool_results}};
        $self->{_deferred_invalid_tool_results} = [];
    }

    # Delayed save: assistant message saved with first tool result to prevent orphans
    my $assistant_msg_pending = {
        role => 'assistant',
        content => $api_response->{content} // '',
        tool_calls => \@validated_tool_calls
    };
    if ($api_response->{reasoning_details}) {
        $assistant_msg_pending->{reasoning_details} = $api_response->{reasoning_details};
    }
    if ($api_response->{reasoning_content} || $api_response->{accumulated_reasoning}) {
        $assistant_msg_pending->{reasoning_content} = $api_response->{reasoning_content} // $api_response->{accumulated_reasoning};
    }
    if ($api_response->{reasoning_blocks} && ref($api_response->{reasoning_blocks}) eq 'ARRAY') {
        $assistant_msg_pending->{reasoning_blocks} = $api_response->{reasoning_blocks};
    }
    if ($api_response->{responses_reasoning_items} && ref($api_response->{responses_reasoning_items}) eq 'ARRAY') {
        $assistant_msg_pending->{responses_reasoning_items} = $api_response->{responses_reasoning_items};
    }

    log_debug('WorkflowOrchestrator', "Delaying save of assistant message with tool_calls until first tool result completes");

    # ── Phase 3: Resolve aliases and classify tools ───────────────────
    my @blocking_tools = ();
    my @serial_tools = ();
    my @parallel_tools = ();

    for my $tool_call (@{$api_response->{tool_calls}}) {
        my $tool_name = $tool_call->{function}->{name} || 'unknown';

        # Resolve tool aliases
        my $params = {};

        my $alias_info = $self->{tool_registry}->get_alias_info($tool_name);
        if ($alias_info) {
            log_debug('WorkflowOrchestrator', "Alias detected: '$tool_name' -> '$alias_info->{tool}' with operation='$alias_info->{operation}'");
            $tool_call->{function}->{name} = $alias_info->{tool};
            $tool_name = $alias_info->{tool};

            # Inject operation + alias defaults DIRECTLY into _parsed_args.
            # Phase 1 already repaired and parsed the JSON, so re-parsing from
            # the raw string (and re-running repair_malformed_json) is both
            # wasteful and dangerous: the decimal regex s/:(\s*)\.(\d)/:0.$2/g
            # matches inside string values and can corrupt already-valid JSON
            # like {"query":"error: .500 status"} -> {"query":"error: 0.500 status"}.
            my @inject_keys = grep { $_ ne 'tool' && $_ ne 'operation' } keys %$alias_info;
            my @inject_pairs = map { $_ => $alias_info->{$_} } @inject_keys;

            if ($tool_call->{_parsed_args} && ref($tool_call->{_parsed_args}) eq 'HASH') {
                # Fast path: Phase 1 already parsed the args. Inject into the
                # hash directly — NO re-parse, NO re-repair.
                $params = $tool_call->{_parsed_args};
                unless (exists $params->{operation}) {
                    $params->{operation} = $alias_info->{operation};
                }
                for my $pair (@inject_pairs) {
                    my ($k, $v) = @$pair;
                    $params->{$k} = $v unless exists $params->{$k};
                }
                log_debug('WorkflowOrchestrator', "Injected operation + extras into _parsed_args (no re-parse)");
            } else {
                # Fallback: _parsed_args was not set (defensive — Phase 1 should
                # always set it for validated tool calls). Parse once.
                $params = safe_decode_json($tool_call->{function}->{arguments} || '{}') || {};
                unless (exists $params->{operation}) {
                    $params->{operation} = $alias_info->{operation};
                }
                for my $pair (@inject_pairs) {
                    my ($k, $v) = @$pair;
                    $params->{$k} = $v unless exists $params->{$k};
                }
                $tool_call->{function}->{arguments} = encode_json($params);
                log_debug('WorkflowOrchestrator', "Injected operation + extras via string re-encode (fallback)");
            }
            # Sync _parsed_args so ToolExecutor (which prefers it) sees the
            # augmented params, not the stale pre-injection copy.
            $tool_call->{_parsed_args} = $params;
        }

        my $tool = $self->{tool_registry}->get_tool($tool_name);

        # Parse arguments for classification (reuse Phase 1 result when available)
        unless ($params && ref($params) eq 'HASH') {
            $params = {};
            if ($tool_call->{_parsed_args} && ref($tool_call->{_parsed_args}) eq 'HASH') {
                # Reuse pre-parsed args from Phase 1 validation (avoids redundant
                # JSON decode AND avoids re-running repair_malformed_json on
                # already-valid JSON, which is not idempotent).
                $params = $tool_call->{_parsed_args};
            } elsif ($tool_call->{function}->{arguments}) {
                # Fallback: _parsed_args was never set (shouldn't happen for
                # validated tool calls, but defensive). This is the ONLY path
                # that runs repair_malformed_json in Phase 3.
                eval {
                    my $json_str = $tool_call->{function}->{arguments};

                    if (is_anthropic_xml_format($json_str)) {
                        log_debug('WorkflowOrchestrator', "Detected Anthropic XML format, converting to JSON");
                        $json_str = parse_anthropic_xml_to_json($json_str, $self->{debug});
                        log_debug('WorkflowOrchestrator', "Converted XML to JSON: " . substr($json_str, 0, 300));
                    } else {
                        $json_str = repair_malformed_json($json_str, $self->{debug});
                        if ($self->{debug}) {
                            my $preview = substr($json_str, 0, 300);
                            log_debug('WorkflowOrchestrator', "Repaired JSON arguments (first 300 chars): $preview");
                        }
                    }

                    # decode_json expects BYTES (not Perl's internal UTF-8 character strings).
                    my $json_bytes = utf8::is_utf8($json_str) ? encode_utf8($json_str) : $json_str;
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
            log_debug('WorkflowOrchestrator', "Unknown tool $tool_name, treating as PARALLEL");
        }
    }

    # ── Phase 4: Order for execution ──────────────────────────────────
    # interact always last
    my @interact_tools = ();
    my @other_blocking_tools = ();

    for my $tool_call (@blocking_tools) {
        my $tool_name = $tool_call->{function}->{name} || 'unknown';
        if ($tool_name eq 'interact') {
            push @interact_tools, $tool_call;
        } else {
            push @other_blocking_tools, $tool_call;
        }
    }

    my @ordered_tool_calls = (@other_blocking_tools, @serial_tools, @parallel_tools, @interact_tools);

    log_debug('WorkflowOrchestrator', "Execution order: " . scalar(@other_blocking_tools) . " other blocking, " .
        scalar(@serial_tools) . " serial, " .
        scalar(@parallel_tools) . " parallel, " .
        scalar(@interact_tools) . " interact (LAST)\n");

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

    # Delegates to CLIO::Core::API::ErrorHandler (extracted to reduce module size)
    return CLIO::Core::API::ErrorHandler::handle_api_error($self, $api_response, $ctx);
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
    
    # Use ToolExecutor to execute the tool.
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

=head2 _check_authorization_requests

Check for and process pending authorization requests from child agents.
Delegates to Chat.pm's authorization handler if requests are pending.
Only active for primary sessions that have a broker client and UI.

=cut

sub _check_authorization_requests {
    my ($self) = @_;
    
    # Only for primary sessions with broker and UI
    return unless $self->{ui} && $self->{broker_client};
    
    # Sub-agents have broker_client too, but no UI - skip them
    return unless $self->{ui}->can('check_agent_messages');
    
    # Quick poll - non-blocking
    eval {
        $self->{ui}->check_agent_messages($self->{broker_client});
    };
    if ($@) {
        log_warning('WorkflowOrchestrator', "Auth relay check failed: $@");
    }
}

=head2 _check_and_handle_interrupt

Check for and handle user interrupt between tool executions.

=cut

sub _check_and_handle_interrupt {
    my ($self, $session, $messages_ref) = @_;
    
    # Skip if we already have a pending interrupt for this iteration
    # (prevents duplicate interrupt message injection)
    return 1 if $self->{_interrupt_pending};
    
    if ($self->_check_for_user_interrupt($session)) {
        $self->_handle_interrupt($session, $messages_ref);
        $self->{_interrupt_pending} = 1;
        
        log_debug('WorkflowOrchestrator', "Interrupt detected mid-iteration, setting pending flag");
        
        return 1;
    }
    
    return 0;
}


=head2 _check_for_user_interrupt

Check for user interrupt (ESC) non-blocking.

Only ESC (char 27) triggers an interrupt. Ctrl+C is intentionally
NOT an interrupt here - it falls through to the global SIGINT handler
in C<clio> which terminates the session cleanly via C<cleanup_handler>.
This matches classic Unix behaviour: Ctrl+C breaks out of the
foreground process, ESC interrupts the in-flight AI response. Other
characters (mouse events, focus events, resize sequences, etc.) are
drained and ignored to prevent false interrupts.

Arguments:
- $session: Session object (to check and set interrupt flag)

Returns:
- 1 if interrupt detected (ESC key pressed)
- 0 if no interrupt

=cut

sub _check_for_user_interrupt {
    my ($self, $session) = @_;

    # Delegate to the shared interrupt helper. The helper centralises the
    # TTY check, the ALRM-state fast path, and the non-blocking read so
    # that the escape-sequence disambiguation can happen in regular code
    # (not a signal handler).
    return CLIO::Core::Interrupt::check(session => $session);
}

=head2 _handle_interrupt

Handle user interrupt by calling interact tool directly (forced).

Instead of injecting a message and hoping the AI calls interact,
we call interact directly. This ensures the user ALWAYS gets prompted
for input when they press ESC, regardless of what the AI was doing.

Arguments:
- $session: Session object
- $messages_ref: Reference to messages array

Returns: Nothing (modifies messages array in place)

=cut

sub _handle_interrupt {
    my ($self, $session, $messages_ref) = @_;

    log_debug('WorkflowOrchestrator', "Handling user interrupt via forced interact");

    # Clear interrupt flag (it's been handled) via the shared helper. This
    # also logs the clear event so we have a single trail of interrupts.
    CLIO::Core::Interrupt::clear(session => $session);
    
    # Stop spinner before showing interact prompt
    if ($self->{spinner} && $self->{spinner}->can('stop')) {
        $self->{spinner}->stop();
    }
    
    # Build the interrupt message for the user
    my $interrupt_text = 
        "You pressed ESC to interrupt the agent.\n\n" .
        "What do you need? (new instructions, progress check, approach change, additional info, etc.)";
    
    log_debug('WorkflowOrchestrator', "Calling interact tool directly for user input");
    
    # Get the Interact tool from the registry and call it directly
    my $tool_registry = $self->{tool_registry};
    if ($tool_registry) {
        my $interact_tool = $tool_registry->get_tool('interact');
        if ($interact_tool) {
            # Call interact directly - this is a forced call, not from AI
            my $result = $interact_tool->execute(
                { operation => 'request_input', message => $interrupt_text },
                {
                    session => $session,
                    config => $self->{config},
                    ui => $self->{ui},
                    spinner => $self->{spinner},
                    broker_client => $self->{broker_client},
                }
            );
            
            if ($result && $result->{success} && $result->{output}) {
                my $user_response = $result->{output};
                
                # Add user's response as a user message
                push @$messages_ref, {
                    role => 'user',
                    content => $user_response,
                };
                
                log_debug('WorkflowOrchestrator', "User responded to interrupt, continuing workflow");
                return;
            } else {
                log_debug('WorkflowOrchestrator', "Interact returned no output or was cancelled");
                # User cancelled or interact failed - add a message that
                # includes the current task context so the model can
                # resume without losing track of what it was doing.
                # Previous behaviour used a bare placeholder
                # "[No response - user cancelled interrupt]" which gave
                # the model no directive and no task reminder. Without
                # the active_task in the dynamic userContext (which
                # happened on first-turn / post-trim sessions), the model
                # had nothing to act on and fell back to the Session Start
                # Protocol in the system prompt — a complete context loss.
                my $task_text = '';
                if ($self->{_current_projection}
                    && length($self->{_current_projection}{active_task} // '')) {
                    $task_text = $self->{_current_projection}{active_task};
                }
                my $msg = "The user pressed ESC to interrupt and then cancelled the prompt.\n\n";
                if (length $task_text) {
                    $msg .= "Continue your work on: $task_text";
                } else {
                    $msg .= "Continue with the current task.";
                }
                push @$messages_ref, {
                    role => 'user',
                    content => $msg,
                };
                return;
            }
        } else {
            log_debug('WorkflowOrchestrator', "Interact tool not found in registry");
        }
    } else {
        log_debug('WorkflowOrchestrator', "Tool registry not available for interrupt handling");
    }
    
    # Fallback: if tool registry is not available, inject message and let AI handle it
    # (This preserves the old behavior as a fallback)
    log_debug('WorkflowOrchestrator', "Falling back to message injection for interrupt");
    my $interrupt_message = {
        role => 'user',
        content =>
            "You pressed ESC to interrupt the agent.\n\n" .
            "Use the interact tool to ask what the user needs.\n\n" .
            "The user may want to: give new instructions, check progress, change approach, or provide additional information.",
        metadata => {
            collaboration => 'interrupt',
        },
    };
    push @$messages_ref, $interrupt_message;
}

=head2 _compress_dropped_for_recovery

Creates a compressed summary of dropped messages for context recovery after
reactive trimming due to token limit exceeded errors.

Uses the unified CLIO::Memory::YaRN::compress_for_context_recovery which
extracts previous thread_summary blocks for cross-cycle carryover. The
output is a clean system message containing only the thread_summary block —
no XML tags, no framework narration, no separate topic/todo/git sections
(those are already in the dynamic userContext system message).

Arguments:
- $dropped_messages: Arrayref of message hashes that were dropped
- $last_user_msg:    The most recent user message (for current task context)
- $session:          Session object (unused — kept for API compatibility)
- $all_messages:     Arrayref of ALL messages before trimming (for
                     previous_summary extraction when the old summary
                     was kept, not dropped)
- $prompt_builder:   Unused — kept for API compatibility

Returns: Message hashref with role 'system' containing the thread_summary,
         or undef if compression fails or produces empty content.

=cut

sub _compress_dropped_for_recovery {
    my ($dropped_messages, $last_user_msg, $session, $all_messages, $prompt_builder) = @_;

    return undef unless $dropped_messages && @$dropped_messages;

    my $original_task = '';
    if ($last_user_msg && ref($last_user_msg) eq 'HASH') {
        $original_task = $last_user_msg->{content} || '';
    }

    # If the last user message is an interrupt placeholder (e.g.
    # "[No response - user cancelled interrupt]" or the new
    # continuation prompt we inject on cancel), scan earlier user
    # messages for the real task. Using the placeholder as
    # original_task causes YaRN to summarise "user cancelled"
    # instead of the actual work, producing a thread_summary that
    # gives the model no actionable context — the same root cause
    # as the context-loss bug.
    if (length $original_task) {
        my $is_placeholder = $original_task =~ /user cancelled interrupt/i
            || $original_task =~ /^The user pressed ESC to interrupt and then cancelled/;
        if ($is_placeholder && $all_messages && ref($all_messages) eq 'ARRAY') {
            for my $msg (reverse @$all_messages) {
                next unless ref($msg) eq 'HASH';
                next unless ($msg->{role} // '') eq 'user';
                my $c = $msg->{content} || '';
                next if $c =~ /user cancelled interrupt/i;
                next if $c =~ /^The user pressed ESC to interrupt and then cancelled/;
                next unless length($c) >= 50;
                $original_task = $c;
                last;
            }
        }
    }

    # If still empty, try to recover the substantive task from the
    # session's durable YaRN thread (never trimmed).
    if (!length $original_task && $session && ref($session)) {
        if ($session->can('id')) {
            my $recovered = eval {
                require CLIO::Memory::YaRN;
                CLIO::Memory::YaRN::recover_substantive_task($session);
            };
            if (defined $recovered && length $recovered) {
                $original_task = $recovered;
            }
        }
    }

    my $compressed;
    eval {
        require CLIO::Memory::YaRN;
        my $yarn = CLIO::Memory::YaRN->new();

        # Extract previous_summary from the full message array — the
        # old thread_summary may have been kept (pinned) rather than
        # dropped, so scanning @dropped_messages alone may miss it.
        my $prev = '';
        if ($all_messages && ref($all_messages) eq 'ARRAY') {
            $prev = $yarn->_extract_thread_summary_from_messages($all_messages);
        }

        $compressed = $yarn->compress_for_context_recovery($dropped_messages,
            original_task    => $original_task,
            previous_summary => $prev,
        );
    };
    if ($@) {
        log_warning('WorkflowOrchestrator', "YaRN compression failed: $@");
    }

    return undef unless $compressed && ref($compressed) eq 'HASH';
    return undef unless defined $compressed->{content} && length($compressed->{content});

    log_debug('WorkflowOrchestrator',
        "Recovery context created: " . length($compressed->{content}) .
        " chars from " . scalar(@$dropped_messages) . " dropped messages");

    # Return a clean system message with just the thread_summary content.
    # No XML tags, no narration, no framework instructions.
    return {
        role => 'system',
        content => $compressed->{content},
    };
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

        # Include todo state inline (no helper indirection).
        if ($session && ref($session) && $session->can('state')) {
            my $session_state = $session->state();
            my $todos = $session_state->{session_goals} || [];
            if ($todos && ref($todos) eq 'ARRAY' && @$todos) {
                push @parts, "## Task State";
                for my $todo (@$todos) {
                    next unless ref($todo) eq 'HASH';
                    my $status = $todo->{status} // 'pending';
                    my $title  = $todo->{title}  // 'Untitled';
                    push @parts, "- [$status] $title";
                }
                push @parts, "";
            }
        }

        # Git state and conversation topic are surfaced via the
        # dynamic userContext system message (which survives
        # trimming). The checkpoint file is for out-of-band
        # inspection only.

        my $content = join("\n", @parts);

        atomic_write("$memory_dir/session_progress.md", $content, encoding => 'UTF-8');

        log_debug('WorkflowOrchestrator', "Session progress checkpoint saved (iteration $iteration, " . length($content) . " chars)");
    };
    if ($@) {
        log_debug('WorkflowOrchestrator', "Failed to checkpoint session progress: $@");
    }
}

=head2 _render_context_files_for_user_context

Render session's context_files (added via /context add) as a block
suitable for inclusion in the prose-rendered history. The block is
appended after # Environment via get_user_context()
context_files_block projection field.

Returns empty string if no files are configured or none are readable.

The format mirrors the legacy inject_context_files() block:
  [CONTEXT FILES]
  The following files were added to context by the user.
  Reference these files when relevant to the conversation.
  Total estimated tokens: ~N
  <context_file path="..." tokens="~N">...</context_file>

Arguments:
- $session: Session object (used to access $session->{context_files},
            which is the live storage used by the /context add command)

Returns: String, or empty string if no files

=cut

sub _render_context_files_for_user_context {
    my ($self, $session) = @_;

    # Read from $session->{context_files} directly - this is the same
    # storage the /context add command writes to. Reading from
    # $session->state()->{context_files} (the old location) returned an
    # always-empty array, silently dropping every /context add file
    # from the dynamic userContext.
    return '' unless $session;
    return '' unless $session->{context_files} && ref($session->{context_files}) eq 'ARRAY';
    my @files = @{$session->{context_files}};
    return '' unless @files;

    my $context_content = '';
    my $total_tokens = 0;
    my $loaded = 0;

    for my $file (@files) {
        next unless -f $file;
        my $content;
        eval {
            open my $fh, '<:encoding(UTF-8)', $file or die "Cannot read: $!";
            local $/;
            $content = <$fh>;
            close $fh;
        };
        next if $@ || !defined $content;

        # Strip control chars that would corrupt the XML structure.
        $content =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;

        my $tokens = int(length($content) / 4);
        $total_tokens += $tokens;

        $context_content .= "\n<context_file path=\"$file\" tokens=\"~$tokens\">\n";
        $context_content .= $content;
        $context_content .= "\n</context_file>\n";
        $loaded++;
    }

    return '' unless $loaded;

    return "[CONTEXT FILES]\n"
        . "The following files were added to context by the user.\n"
        . "Reference these files when relevant to the conversation.\n"
        . "Total estimated tokens: ~$total_tokens\n"
        . $context_content;
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
sub _extract_session_marker {
    my ($self, $content, $session) = @_;
    
    # Try structured format first: <!--session:{"title":"name here"}-->
    if ($content =~ s/\s*<!--session:\{[^}]*"title"\s*:\s*"([^"]{3,80})"[^}]*\}-->\s*//s) {
        my $title = $1;
        $title =~ s/^\s+|\s+$//g;
        if (length($title) >= 3) {
            $session->session_name($title);
            log_debug('WorkflowOrchestrator', "Session named by AI: $title");
        }
        return ($content, 1);
    }
    
    # Try simple format: <!--session:simple-name-->
    # Character class allows '.' for date-version tags (e.g.
    # "doc-sync-20260904.1"); see CLIO::Util::TextSanitizer for the
    # matching strip regex used elsewhere.
    if ($content =~ s/\s*<!--session:([a-z][a-z0-9._-]{2,50})-->\s*//si) {
        my $title = $1;
        $title =~ s/^\s+|\s+$//g;
        if (length($title) >= 3) {
            $session->session_name($title);
            log_debug('WorkflowOrchestrator', "Session named by AI: $title");
        }
        return ($content, 1);
    }
    
    return ($content, 0);
}

=head2 _read_ltm_entries_for_projection

Read the session's LTM (if any) and return the flat list of
{confidence, content, type} hashes suitable for ContextBuilder's
relevance scoring. Returns [] when the session has no LTM or the
LTM has no entries.

=cut

sub _read_ltm_entries_for_projection {
    my ($self, $session) = @_;
    return [] unless $session && $session->can('ltm');
    my $ltm = eval { $session->ltm() };
    return [] unless $ltm && $ltm->can('get_entries_for_projection');
    return eval { $ltm->get_entries_for_projection() } || [];
}

=head2 _active_task_text

Return the active task text for the projection. Reads the most recent
active session goal, falling back to the most recent substantive user
message from $history if no goals are set. Returns '' when neither is
available.

The "most recent active goal" rule is what makes this function correct
in long sessions where the user has moved on to a new task. The earlier
"first active goal" implementation pinned the active task label to the
user's first request, which caused the model to treat all subsequent
work as scope creep and revert it (observed in CLIO session
e45204bf-94ea-45da-99a8-c7d512e54cfb, 2026-09-05). The fix iterates
the goals array in reverse so the most recent active goal wins.

Why the model can rely on this: the agent records a new active goal
via todo_operations(session_goals) when it recognises a substantive
new user request (>=200 chars, not a short acknowledgement like
"proceed" or "ship it"). The length guard lives upstream in the
goal-recording path, not here - this function trusts that what is in
session_goals is the current focus.

=cut

sub _active_task_text {
    my ($self, $session, $user_input) = @_;
    return '' unless $session;

    my $goals = '';
    if ($session->can('state')) {
        my $state = $session->state();
        if (ref($state) && $state->can('session_goals')) {
            my $list = eval { $state->session_goals() };
            if (ref($list) eq 'ARRAY') {
                # Iterate REVERSED so the most recent active goal wins.
                # Session goals are appended in order; the newest
                # task transition is the last entry. Scanning
                # newest-first matches the YaRN fallback below and
                # gives the model a live "current focus" signal
                # rather than a frozen "first task" anchor.
                for my $g (reverse @$list) {
                    if (ref($g) eq 'HASH' && ($g->{status} // '') eq 'active') {
                        $goals = $g->{title} || '';
                        if (length $goals) {
                            $goals .= ': ' . ($g->{description} || '') if length($g->{description} // '');
                            last;
                        }
                    }
                }
            }
        }
    }
    return $goals if length $goals;

    # Fallback 1: use the current user input as the task (if substantive,
    # i.e. >= 50 chars). This is critical for the first turn of a
    # session, where the session's conversation history is empty because
    # the user input has not been saved yet (State::add_message runs
    # after _build_turn_context). Without this fallback the
    # projection's active_task is empty and the dynamic userContext
    # system message contains only environment info (Working directory,
    # Language, Date). If a trim then condenses the full conversation
    # into a short thread_summary, the model receives the
    # [No response - user cancelled interrupt] message with a 93-char
    # userContext and no task reminder, causing it to fall back to the
    # Session Start Protocol from the system prompt (complete context loss).
    if (defined $user_input && length($user_input // '') >= 50) {
        return $user_input;
    }

    # Fallback 2: ask YaRN for the substantive task from the session's
    # full history. YaRN::find_substantive_task scans newest-first
    # (>=50 chars), so when no goals are set, the most recent
    # substantive user message wins - same precedence rule as above.
    require CLIO::Memory::YaRN;
    return '' unless $session->can('get_conversation_history');
    my $history = eval { $session->get_conversation_history() };
    my $candidate = $user_input // '';
    my $task = CLIO::Memory::YaRN::find_substantive_task($candidate, $history);

    # Fallback 3: recover from the durable YaRN thread. The session's
    # conversation history is subject to State::trim_context, which may
    # have dropped the original user task message. The YaRN thread is
    # never trimmed, so recover_substantive_task can always find the
    # original task even after aggressive context trimming.
    if (!length($task) && $session->can('id')) {
        $task = CLIO::Memory::YaRN::recover_substantive_task($session);
    }

    return $task;
}

=head2 _read_active_todos_for_projection

Read the active todo list and return it in the shape ContextBuilder
expects (arrayref of {id, status, content}). Returns [] when no
session or no todos.

TodoStore stores items as {title, description, status, ...} (see
CLIO::Session::TodoStore's POD). Earlier this function read
$todo->{content} (which doesn't exist on TodoStore records) and so
returned blank content for every todo - the model's "# Active todos"
section rendered as `- [in-progress]` with no title or description.
Fixed: prefer `title` (with `description` appended when present) and
fall back to `content` for backwards compatibility with any
non-TodoStore data sources.

Also: TodoStore's constructor takes `sessions_dir`, NOT `clio_dir`.
Passing `clio_dir` was silently dropped and TodoStore read from
`<cwd>/sessions/<id>/todos.json`, which is empty for puppeteer child
projects (tests/, scratch/) whose session data lives under their own
`.clio/`. Fixed: derive sessions_dir from clio_dir.

=cut

sub _read_active_todos_for_projection {
    my ($self, $session) = @_;
    return [] unless $session;

    eval {
        require CLIO::Session::TodoStore;
        require Cwd;
        require CLIO::Util::PathResolver;
    };
    return [] if $@;

    my $clio_dir = CLIO::Util::PathResolver::find_clio_dir(Cwd::getcwd());
    my $store = CLIO::Session::TodoStore->new(
        sessions_dir => "$clio_dir/sessions",
        session_id   => $session->can('id') ? $session->id() : undef,
    );
    my $todos = eval { $store->read() };
    return [] unless $todos && ref($todos) eq 'ARRAY';

    my @out;
    for my $todo (@$todos) {
        next unless ref($todo) eq 'HASH';
        # TodoStore normalizes 'pending' to 'not-started' on write;
        # accept both spellings for forward compatibility.
        next unless grep { ($todo->{status} // '') eq $_ }
            ('in-progress', 'pending', 'not-started', 'blocked');
        # Resolve content: TodoStore uses title + description. Some
        # legacy code paths may have stored under `content`, so honor
        # that too.
        my $content = $todo->{title} || $todo->{content} || '';
        if ($todo->{description} && length $todo->{description}) {
            $content .= ': ' . $todo->{description} if length $content;
            $content .= $todo->{description} unless length $content;
        }
        push @out, {
            id      => $todo->{id},
            status  => $todo->{status},
            content => $content,
        };
    }
    return \@out;
}

=head2 _collect_unresolved_state

Walk the recent history and collect strings describing unresolved
state: failed tool results (containing "ERROR", "FAILED", or
"undefined"), blocked todos, and recent [SYSTEM: ...] nudges. Used
by ContextBuilder for LTM relevance scoring.

Arguments:
- $history: ArrayRef of message hashes from session history.
- $session: Session object (required for blocked-todo surfacing).
  The previous version read $self->{_session}, which is never set
  anywhere in WorkflowOrchestrator, so the blocked-todo surfacing
  path was silently dead code. Pass $session explicitly so this
  method actually sees the session's TodoStore.

Returns arrayref of strings, capped at 10 to keep the keyword overlap
scoring bounded.

=cut

sub _collect_unresolved_state {
    my ($self, $history, $session) = @_;
    return [] unless $history && ref($history) eq 'ARRAY';

    require CLIO::Memory::LongTerm;
    my $sanitizer = CLIO::Memory::LongTerm->new();

    # Read blocked todos from TodoStore and surface them as
    # unresolved state. The user explicitly marked the todo as
    # blocked - that's a signal the model needs to see when
    # LTM relevance scoring runs, so framework-related memories
    # (like "model-facing prompt paths must NEVER tell the
    # model about framework-internal events") get the category
    # boost and surface to help the model recover from the
    # blocked state.
    #
    # Skipped if TodoStore is unreachable (e.g. test environments
    # without a session dir). The eval guards the load.

    my @unresolved;
    eval {
        require CLIO::Session::TodoStore;
        require Cwd;
        require CLIO::Util::PathResolver;
        my $clio_dir = CLIO::Util::PathResolver::find_clio_dir(Cwd::getcwd());
        my $store = CLIO::Session::TodoStore->new(
            sessions_dir => "$clio_dir/sessions",
            session_id   => $session && $session->can('id') ? $session->id() : undef,
        );
        my $todos = $store->read();
        if ($todos && ref($todos) eq 'ARRAY') {
            for my $todo (@$todos) {
                next unless ref($todo) eq 'HASH';
                next unless ($todo->{status} // '') eq 'blocked';
                my $content = $todo->{title} || $todo->{content} || '';
                next unless length $content;
                # Include description and blockedReason when present so
                # LTM relevance scoring has more signal to match against
                # (the "blocked todo: <title>" line is short and unlikely to
                # score above the relevance floor for framework-meta
                # memories).
                if (length $todo->{description} // '') {
                    $content .= ' - ' . $todo->{description};
                }
                if (length $todo->{blockedReason} // '') {
                    $content .= ' (reason: ' . $todo->{blockedReason} . ')';
                }
                push @unresolved, "blocked todo: $content";
                last if @unresolved >= 10;
            }
        }
    };
    log_debug('WorkflowOrchestrator', "TodoStore load for blocked todos: $@") if $@;

    my $n = scalar(@$history);
    my $start = $n - 30;
    $start = 0 if $start < 0;
    for my $i ($start .. $n - 1) {
        my $msg = $history->[$i];
        next unless ref($msg) eq 'HASH';
        my $role = $msg->{role} // '';
        my $content = $msg->{content} // '';
        if ($role eq 'tool' && $content =~ /\b(ERROR|FAILED|FATAL|UNDEFINED|Exception|croak|Died at|stack trace|traceback|status:\s*failed|HTTP\/\S+\s+5\d\d|connection refused|timeout|out of memory)\b/i) {
            # Tool error: include the error text directly. The prose
            # renderer's "- " bullet already structures the list; a
            # "tool_error:" prefix would be framework-mechanic
            # narration that the model treats as instruction.
            # Sanitize so any internal tool names / LTM references
            # in the error message get cleaned.
            my $line = $sanitizer->sanitize_narration(substr($content, 0, 200));
            push @unresolved, $line if length $line;
        }
        # [SYSTEM: ...] user nudges are framework narration. Per the
        # LTM pattern "model-facing prompt paths must NEVER tell the
        # model about framework-internal events" we deliberately do
        # not surface them as unresolved state. The model should
        # never see them at all - if one leaked into the history it
        # belongs in the sanitizer, not in the unresolved list.
        last if @unresolved >= 10;
    }
    return \@unresolved;
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
- AI-directed tool decisions
- Enables multi-turn tool use (tool → tool → answer)
- Scales to any number of tools
- Follows industry standard (OpenAI format)

=head1 INTEGRATION

See L<CLIO::Tools::Registry> for tool registration,
L<CLIO::Core::APIManager> for API communication,
and L<CLIO::Core::ToolExecutor> for tool execution.

=head1 LICENSE

GPL-3.0-only

=cut
