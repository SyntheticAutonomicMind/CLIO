package CLIO::ACP::Agent;

use strict;
use warnings;
use utf8;

use JSON::PP qw(encode_json decode_json);
use CLIO::ACP::Transport;
use CLIO::ACP::JSONRPC;

=head1 NAME

CLIO::ACP::Agent - ACP-compliant agent implementation for CLIO

=head1 SYNOPSIS

    use CLIO::ACP::Agent;
    
    my $agent = CLIO::ACP::Agent->new(
        config => $config,
        debug => 1,
    );
    
    # Run the agent (blocking, reads from stdin, writes to stdout)
    $agent->run();

=head1 DESCRIPTION

Implements the Agent Client Protocol (ACP) specification, allowing CLIO
to function as an AI coding agent that can be integrated with compatible
code editors (Zed, JetBrains IDEs, etc.).

Methods implemented:
- initialize: Version/capability negotiation
- authenticate: Authentication (optional)
- session/new: Create new conversation session
- session/load: Resume existing session (optional)
- session/prompt: Handle user prompts
- session/cancel: Cancel ongoing operations (notification)

Notifications sent:
- session/update: Stream content chunks, tool calls, plans

=cut

# Protocol version
our $PROTOCOL_VERSION = 1;

# Agent info
our $AGENT_NAME = 'clio';
our $AGENT_TITLE = 'CLIO - Command Line Intelligence Orchestrator';
our $AGENT_VERSION = '1.0.0';

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        debug => $opts{debug} || 0,
        config => $opts{config},
        
        # CLIO components (initialized lazily when config is available)
        api_manager => undef,
        tool_registry => undef,
        tool_executor => undef,
        workflow_orchestrator => undef,
        
        # State
        initialized => 0,
        authenticated => 0,
        sessions => {},
        current_session => undef,
        pending_requests => {},
        
        # Capabilities (what we support)
        capabilities => {
            loadSession => 1,  # We support loading sessions
            promptCapabilities => {
                image => 0,       # No image support yet
                audio => 0,       # No audio support yet
                embeddedContext => 1,  # We support embedded resources
            },
            sessionCapabilities => {},
            mcpCapabilities => {
                http => 0,
                sse => 0,
            },
        },
        
        # Client capabilities (filled during initialize)
        client_capabilities => {},
        client_info => {},
        
        # Transport
        transport => undef,
        running => 0,
    };
    
    bless $self, $class;
    
    # Initialize CLIO components if config is available
    $self->_init_clio_components() if $self->{config};
    
    return $self;
}

=head2 _init_clio_components()

Initialize CLIO's core components (APIManager, ToolRegistry, etc.)

=cut

sub _init_clio_components {
    my ($self) = @_;
    
    return unless $self->{config};
    
    eval {
        # Load CLIO core modules
        require CLIO::Core::APIManager;
        require CLIO::Tools::Registry;
        require CLIO::Core::ToolExecutor;
        
        # Create tool registry with all CLIO tools
        $self->{tool_registry} = CLIO::Tools::Registry->new(debug => $self->{debug});
        
        # Create API manager
        $self->{api_manager} = CLIO::Core::APIManager->new(
            config => $self->{config},
            debug => $self->{debug},
        );
        
        $self->_debug("CLIO components initialized");
    };
    
    if ($@) {
        $self->_log("Failed to initialize CLIO components: $@");
    }
}

=head2 run()

Start the agent, processing messages from stdin until EOF.

=cut

sub run {
    my ($self) = @_;
    
    $self->{transport} = CLIO::ACP::Transport->new(debug => $self->{debug});
    $self->{running} = 1;
    
    $self->_log("CLIO ACP Agent started");
    
    while ($self->{running}) {
        my $msg = $self->{transport}->read();
        
        unless ($msg) {
            # EOF or read error
            $self->_log("Input closed, shutting down");
            last;
        }
        
        $self->_handle_message($msg);
    }
    
    $self->_log("CLIO ACP Agent stopped");
}

=head2 stop()

Stop the agent.

=cut

sub stop {
    my ($self) = @_;
    $self->{running} = 0;
}

=head2 _handle_message($msg)

Route incoming message to appropriate handler.

=cut

sub _handle_message {
    my ($self, $msg) = @_;
    
    if ($msg->{type} eq 'parse_error') {
        $self->{transport}->send_error(
            undef,
            -32700,
            "Parse error: $msg->{error}"
        );
        return;
    }
    
    if ($msg->{type} eq 'request') {
        $self->_handle_request($msg);
    } elsif ($msg->{type} eq 'notification') {
        $self->_handle_notification($msg);
    } elsif ($msg->{type} eq 'response') {
        $self->_handle_response($msg);
    } elsif ($msg->{type} eq 'error') {
        $self->_handle_error_response($msg);
    }
}

=head2 _handle_request($msg)

Handle a JSON-RPC request.

=cut

sub _handle_request {
    my ($self, $msg) = @_;
    
    my $method = $msg->{method};
    my $params = $msg->{params};
    my $id = $msg->{id};
    
    $self->_debug("Request: $method (id=$id)");
    
    # Method dispatch
    my %handlers = (
        'initialize'     => \&_method_initialize,
        'authenticate'   => \&_method_authenticate,
        'session/new'    => \&_method_session_new,
        'session/load'   => \&_method_session_load,
        'session/prompt' => \&_method_session_prompt,
        'session/set_mode' => \&_method_session_set_mode,
    );
    
    my $handler = $handlers{$method};
    
    unless ($handler) {
        $self->{transport}->send_error(
            $id,
            -32601,
            "Method not found: $method"
        );
        return;
    }
    
    # Check initialization (except for initialize itself)
    if ($method ne 'initialize' && !$self->{initialized}) {
        $self->{transport}->send_error(
            $id,
            -32600,
            "Agent not initialized. Call initialize first."
        );
        return;
    }
    
    # Execute handler
    my $result = eval { $handler->($self, $params, $id) };
    
    if ($@) {
        $self->_log("Handler error: $@");
        $self->{transport}->send_error($id, -32603, "Internal error: $@");
        return;
    }
    
    # Handler returns undef if it sends its own response
    if (defined $result) {
        $self->{transport}->send_response($id, $result);
    }
}

=head2 _handle_notification($msg)

Handle a JSON-RPC notification (no response expected).

=cut

sub _handle_notification {
    my ($self, $msg) = @_;
    
    my $method = $msg->{method};
    my $params = $msg->{params};
    
    $self->_debug("Notification: $method");
    
    if ($method eq 'session/cancel') {
        $self->_notif_session_cancel($params);
    } else {
        $self->_debug("Unknown notification: $method");
    }
}

=head2 _handle_response($msg)

Handle a JSON-RPC response (to a request we sent).

=cut

sub _handle_response {
    my ($self, $msg) = @_;
    
    my $id = $msg->{id};
    my $result = $msg->{result};
    
    $self->_debug("Response received for id=$id");
    
    # Handle client responses (e.g., permission requests, file operations)
    if (exists $self->{pending_requests}{$id}) {
        my $callback = delete $self->{pending_requests}{$id};
        $callback->($result) if $callback;
    }
}

=head2 _handle_error_response($msg)

Handle an error response from the client.

=cut

sub _handle_error_response {
    my ($self, $msg) = @_;
    
    my $id = $msg->{id};
    my $error = $msg->{error};
    
    $self->_log("Error response for id=$id: $error->{message}");
    
    if (exists $self->{pending_requests}{$id}) {
        my $callback = delete $self->{pending_requests}{$id};
        $callback->(undef, $error) if $callback;
    }
}

# ============================================================================
# ACP Methods
# ============================================================================

=head2 _method_initialize($params, $id)

Handle the initialize request.

=cut

sub _method_initialize {
    my ($self, $params, $id) = @_;
    
    my $client_version = $params->{protocolVersion};
    my $client_caps = $params->{clientCapabilities} || {};
    my $client_info = $params->{clientInfo} || {};
    
    $self->_debug("Initialize: client version=$client_version");
    
    # Store client capabilities
    $self->{client_capabilities} = $client_caps;
    $self->{client_info} = $client_info;
    
    # Negotiate version
    my $agreed_version = $client_version;
    if ($client_version > $PROTOCOL_VERSION) {
        $agreed_version = $PROTOCOL_VERSION;
    }
    
    $self->{initialized} = 1;
    
    return {
        protocolVersion => $agreed_version,
        agentCapabilities => $self->{capabilities},
        agentInfo => {
            name => $AGENT_NAME,
            title => $AGENT_TITLE,
            version => $AGENT_VERSION,
        },
        authMethods => [],  # No auth required
    };
}

=head2 _method_authenticate($params, $id)

Handle the authenticate request.

=cut

sub _method_authenticate {
    my ($self, $params, $id) = @_;
    
    # We don't require authentication
    $self->{authenticated} = 1;
    
    return {};
}

=head2 _method_session_new($params, $id)

Handle the session/new request.

=cut

sub _method_session_new {
    my ($self, $params, $id) = @_;
    
    my $cwd = $params->{cwd};
    my $mcp_servers = $params->{mcpServers} || [];
    
    unless ($cwd) {
        $self->{transport}->send_error($id, -32602, "Missing required parameter: cwd");
        return undef;
    }
    
    # Generate session ID
    my $session_id = $self->_generate_session_id();
    
    # Create session with conversation history
    $self->{sessions}{$session_id} = {
        id => $session_id,
        cwd => $cwd,
        mcp_servers => $mcp_servers,
        messages => [],  # Conversation history for API
        created_at => time(),
        cancelled => 0,
        pending_prompt_id => undef,
    };
    
    # Initialize tool executor for this session
    if ($self->{tool_registry}) {
        eval {
            $self->{sessions}{$session_id}{tool_executor} = CLIO::Core::ToolExecutor->new(
                session => { session_id => $session_id, cwd => $cwd },
                tool_registry => $self->{tool_registry},
                config => $self->{config},
                debug => $self->{debug},
            );
        };
        $self->_log("Tool executor error: $@") if $@;
    }
    
    $self->{current_session} = $session_id;
    
    $self->_debug("Created session: $session_id (cwd=$cwd)");
    
    return {
        sessionId => $session_id,
    };
}

=head2 _method_session_load($params, $id)

Handle the session/load request.

=cut

sub _method_session_load {
    my ($self, $params, $id) = @_;
    
    my $session_id = $params->{sessionId};
    my $cwd = $params->{cwd};
    my $mcp_servers = $params->{mcpServers} || [];
    
    unless ($session_id && $cwd) {
        $self->{transport}->send_error($id, -32602, "Missing required parameters: sessionId, cwd");
        return undef;
    }
    
    # Check if session exists
    my $session = $self->{sessions}{$session_id};
    
    unless ($session) {
        # Try to load from storage
        $session = $self->_load_session_from_storage($session_id);
    }
    
    unless ($session) {
        $self->{transport}->send_error($id, -32602, "Session not found: $session_id");
        return undef;
    }
    
    # Update session state
    $session->{cwd} = $cwd;
    $session->{mcp_servers} = $mcp_servers;
    $self->{sessions}{$session_id} = $session;
    $self->{current_session} = $session_id;
    
    # Replay conversation history via session/update notifications
    for my $msg (@{$session->{messages} || []}) {
        my $role = $msg->{role};
        my $content = $msg->{content};
        
        my $update_type;
        if ($role eq 'user') {
            $update_type = 'user_message_chunk';
        } elsif ($role eq 'assistant') {
            $update_type = 'agent_message_chunk';
        } else {
            next;  # Skip tool messages in replay
        }
        
        # Handle content (can be string or array)
        my $text_content;
        if (ref($content) eq 'ARRAY') {
            $text_content = join('', map { $_->{text} || '' } @$content);
        } else {
            $text_content = $content;
        }
        
        $self->{transport}->send_notification('session/update', {
            sessionId => $session_id,
            update => {
                sessionUpdate => $update_type,
                content => {
                    type => 'text',
                    text => $text_content,
                },
            },
        });
    }
    
    $self->_debug("Loaded session: $session_id");
    
    # Send null response after replaying history
    $self->{transport}->send_response($id, undef);
    return undef;
}

=head2 _method_session_prompt($params, $id)

Handle the session/prompt request.

=cut

sub _method_session_prompt {
    my ($self, $params, $id) = @_;
    
    my $session_id = $params->{sessionId};
    my $prompt = $params->{prompt} || [];
    
    unless ($session_id) {
        $self->{transport}->send_error($id, -32602, "Missing required parameter: sessionId");
        return undef;
    }
    
    my $session = $self->{sessions}{$session_id};
    unless ($session) {
        $self->{transport}->send_error($id, -32602, "Session not found: $session_id");
        return undef;
    }
    
    # Store the pending response id for cancellation
    $session->{pending_prompt_id} = $id;
    $session->{cancelled} = 0;
    
    # Process prompt
    $self->_process_prompt($session_id, $prompt, $id);
    
    # Response is sent by _process_prompt
    return undef;
}

=head2 _method_session_set_mode($params, $id)

Handle the session/set_mode request.

=cut

sub _method_session_set_mode {
    my ($self, $params, $id) = @_;
    
    # We don't implement modes yet
    return {};
}

# ============================================================================
# Notifications
# ============================================================================

=head2 _notif_session_cancel($params)

Handle session/cancel notification.

=cut

sub _notif_session_cancel {
    my ($self, $params) = @_;
    
    my $session_id = $params->{sessionId};
    
    my $session = $self->{sessions}{$session_id};
    if ($session) {
        $session->{cancelled} = 1;
        $self->_debug("Session cancelled: $session_id");
    }
}

# ============================================================================
# Prompt Processing
# ============================================================================

=head2 _process_prompt($session_id, $prompt, $request_id)

Process a user prompt and send responses.

=cut

sub _process_prompt {
    my ($self, $session_id, $prompt, $request_id) = @_;
    
    my $session = $self->{sessions}{$session_id};
    
    # Extract text from prompt content blocks
    my $user_message = '';
    my @resources;
    
    for my $block (@$prompt) {
        if ($block->{type} eq 'text') {
            $user_message .= $block->{text};
        } elsif ($block->{type} eq 'resource') {
            my $resource = $block->{resource};
            push @resources, $resource;
            $user_message .= "\n\n[File: $resource->{uri}]\n```\n$resource->{text}\n```\n"
                if $resource->{text};
        } elsif ($block->{type} eq 'resource_link') {
            # Client is linking to a resource - we may need to fetch it
            my $uri = $block->{uri};
            $user_message .= "\n\n[Resource: $uri]\n";
        }
    }
    
    # Add user message to conversation history
    push @{$session->{messages}}, {
        role => 'user',
        content => $user_message,
    };
    
    # Check for cancellation
    if ($session->{cancelled}) {
        $self->{transport}->send_response($request_id, { stopReason => 'cancelled' });
        return;
    }
    
    # Process with AI if available
    if ($self->{api_manager}) {
        eval {
            $self->_process_with_ai($session_id, $user_message, $request_id);
        };
        if ($@) {
            $self->_log("AI processing error: $@");
            # Send fallback response on error
            my $response = "I apologize, but I encountered an error processing your request: $@";
            $self->send_agent_chunk($session_id, $response);
            push @{$session->{messages}}, { role => 'assistant', content => $response };
            $self->{transport}->send_response($request_id, { stopReason => 'end_turn' });
        }
    } else {
        # Fallback response
        my $response = "Hello! I'm CLIO. I received your message but AI backend is not configured.\n\n";
        $response .= "Your message: $user_message";
        
        $self->send_agent_chunk($session_id, $response);
        
        push @{$session->{messages}}, {
            role => 'assistant',
            content => $response,
        };
        
        $self->{transport}->send_response($request_id, { stopReason => 'end_turn' });
    }
}

=head2 _process_with_ai($session_id, $user_message, $request_id)

Process a prompt using CLIO's AI backend with streaming.

=cut

sub _process_with_ai {
    my ($self, $session_id, $user_message, $request_id) = @_;
    
    my $session = $self->{sessions}{$session_id};
    my $accumulated_response = '';
    my $tool_calls = [];
    
    # Get tools from registry
    my $tools = [];
    if ($self->{tool_registry}) {
        $tools = $self->{tool_registry}->get_tool_definitions();
    }
    
    # Prepare messages for API (with system prompt)
    my @api_messages = (
        {
            role => 'system',
            content => $self->_get_system_prompt($session),
        },
    );
    
    # Add conversation history
    for my $msg (@{$session->{messages}}) {
        # Skip tool messages in this simplified version
        next if $msg->{role} eq 'tool';
        
        # Ensure content is a simple string
        my $content = $msg->{content};
        if (ref($content)) {
            # Convert array/hash to string
            $content = ref($content) eq 'ARRAY' 
                ? join('', map { $_->{text} || '' } @$content)
                : encode_json($content);
        }
        
        push @api_messages, {
            role => $msg->{role},
            content => $content,
        };
    }
    
    # Stream the response
    my $result;
    my $error_occurred = 0;
    
    eval {
        $result = $self->{api_manager}->send_request_streaming(
            \@api_messages,
            tools => $tools,
            on_chunk => sub {
                my ($chunk) = @_;
                
                # Check for cancellation
                if ($session->{cancelled}) {
                    return 0;  # Stop streaming
                }
                
                $accumulated_response .= $chunk;
                
                # Send chunk to client
                $self->send_agent_chunk($session_id, $chunk);
                
                return 1;  # Continue streaming
            },
            on_tool_call => sub {
                my ($tool_call) = @_;
                
                push @$tool_calls, $tool_call;
                
                # Notify client about tool call
                my $tool_call_id = $tool_call->{id} || 'call_' . int(rand(1000000));
                my $tool_name = $tool_call->{function}{name} || 'unknown';
                
                $self->send_tool_call($session_id, $tool_call_id, "Executing $tool_name", 'other', 'pending');
            },
        );
    };
    
    if ($@) {
        $self->_log("AI request error: $@");
        my $error_msg = "Error communicating with AI: $@";
        $self->send_agent_chunk($session_id, $error_msg);
        push @{$session->{messages}}, { role => 'assistant', content => $error_msg };
        $self->{transport}->send_response($request_id, { stopReason => 'end_turn' });
        return;
    }
    
    # Check for errors
    if (!$result || !$result->{success}) {
        my $error = $result ? ($result->{error} || 'Unknown error') : 'No response from AI';
        $self->_log("AI response error: $error");
        my $error_msg = "AI Error: $error";
        $self->send_agent_chunk($session_id, $error_msg);
        push @{$session->{messages}}, { role => 'assistant', content => $error_msg };
        $self->{transport}->send_response($request_id, { stopReason => 'end_turn' });
        return;
    }
    
    # Handle tool calls if any
    if (@$tool_calls) {
        $self->_handle_tool_calls($session_id, $tool_calls, $request_id);
        return;
    }
    
    # Store assistant message
    push @{$session->{messages}}, {
        role => 'assistant',
        content => $accumulated_response,
    };
    
    # Determine stop reason
    my $stop_reason = 'end_turn';
    if ($session->{cancelled}) {
        $stop_reason = 'cancelled';
    } elsif ($result->{finish_reason} && $result->{finish_reason} eq 'length') {
        $stop_reason = 'max_tokens';
    }
    
    $self->{transport}->send_response($request_id, { stopReason => $stop_reason });
}

=head2 _handle_tool_calls($session_id, $tool_calls, $request_id)

Execute tool calls and continue the conversation.

=cut

sub _handle_tool_calls {
    my ($self, $session_id, $tool_calls, $request_id) = @_;
    
    my $session = $self->{sessions}{$session_id};
    my $tool_executor = $session->{tool_executor};
    
    # Add assistant message with tool calls to history
    push @{$session->{messages}}, {
        role => 'assistant',
        content => '',
        tool_calls => $tool_calls,
    };
    
    # Execute each tool call
    for my $tc (@$tool_calls) {
        my $tool_call_id = $tc->{id};
        my $tool_name = $tc->{function}{name};
        my $arguments = $tc->{function}{arguments};
        
        # Update status
        $self->send_tool_call_update($session_id, $tool_call_id, 'in_progress');
        
        # Execute tool
        my $result;
        if ($tool_executor) {
            $result = $tool_executor->execute_tool($tc, $tool_call_id);
        } else {
            $result = encode_json({ error => 'Tool executor not available' });
        }
        
        # Add tool result to history
        push @{$session->{messages}}, {
            role => 'tool',
            tool_call_id => $tool_call_id,
            content => $result,
        };
        
        # Send completion update
        $self->send_tool_call_update($session_id, $tool_call_id, 'completed', [{
            type => 'content',
            content => { type => 'text', text => $result },
        }]);
    }
    
    # Continue conversation with tool results
    $self->_process_with_ai($session_id, '', $request_id);
}

=head2 _get_system_prompt($session)

Get the system prompt for the session.

=cut

sub _get_system_prompt {
    my ($self, $session) = @_;
    
    my $cwd = $session->{cwd} || '.';
    
    return <<SYSTEM;
You are CLIO (Command Line Intelligence Orchestrator), an advanced AI coding assistant.

You are working in the directory: $cwd

You have access to tools for:
- File operations (read, write, search)
- Version control (git)
- Terminal commands
- Web operations (fetch URLs, search)
- Memory operations (store/retrieve context)

Use tools when appropriate to accomplish tasks. Be direct and helpful.

When you need to execute code or commands, use the terminal_operations tool.
When you need to read or modify files, use the file_operations tool.
SYSTEM
}

# ============================================================================
# Session Updates (notifications to client)
# ============================================================================

=head2 send_agent_chunk($session_id, $text)

Send an agent message chunk to the client.

=cut

sub send_agent_chunk {
    my ($self, $session_id, $text) = @_;
    
    $self->{transport}->send_notification('session/update', {
        sessionId => $session_id,
        update => {
            sessionUpdate => 'agent_message_chunk',
            content => {
                type => 'text',
                text => $text,
            },
        },
    });
}

=head2 send_thought_chunk($session_id, $text)

Send a thought/reasoning chunk to the client.

=cut

sub send_thought_chunk {
    my ($self, $session_id, $text) = @_;
    
    $self->{transport}->send_notification('session/update', {
        sessionId => $session_id,
        update => {
            sessionUpdate => 'thought_message_chunk',
            content => {
                type => 'text',
                text => $text,
            },
        },
    });
}

=head2 send_tool_call($session_id, $tool_call_id, $title, $kind, $status)

Send a tool call notification.

=cut

sub send_tool_call {
    my ($self, $session_id, $tool_call_id, $title, $kind, $status) = @_;
    
    $self->{transport}->send_notification('session/update', {
        sessionId => $session_id,
        update => {
            sessionUpdate => 'tool_call',
            toolCallId => $tool_call_id,
            title => $title,
            kind => $kind || 'other',
            status => $status || 'pending',
        },
    });
}

=head2 send_tool_call_update($session_id, $tool_call_id, $status, $content)

Send a tool call status update.

=cut

sub send_tool_call_update {
    my ($self, $session_id, $tool_call_id, $status, $content) = @_;
    
    my $update = {
        sessionUpdate => 'tool_call_update',
        toolCallId => $tool_call_id,
        status => $status,
    };
    
    if ($content) {
        $update->{content} = $content;
    }
    
    $self->{transport}->send_notification('session/update', {
        sessionId => $session_id,
        update => $update,
    });
}

=head2 send_plan($session_id, $entries)

Send an agent plan.

=cut

sub send_plan {
    my ($self, $session_id, $entries) = @_;
    
    $self->{transport}->send_notification('session/update', {
        sessionId => $session_id,
        update => {
            sessionUpdate => 'plan',
            entries => $entries,
        },
    });
}

# ============================================================================
# Client Method Calls (Agent -> Client)
# ============================================================================

=head2 request_permission($session_id, $tool_call_id, $title, $description, $callback)

Request permission from the client to execute a tool.

Per ACP spec, this is the baseline method for requesting user authorization.

=cut

sub request_permission {
    my ($self, $session_id, $tool_call_id, $title, $description, $callback) = @_;
    
    my $req_id = $self->{transport}->send_request('session/request_permission', {
        sessionId => $session_id,
        toolCallId => $tool_call_id,
        title => $title,
        description => $description,
    });
    
    $self->{pending_requests}{$req_id} = $callback;
    return $req_id;
}

# ============================================================================
# Filesystem Methods (Optional - depends on client capabilities)
# ============================================================================

=head2 fs_read_text_file($session_id, $path, $callback, %opts)

Request the client to read a file (if client supports fs.readTextFile).

Options:
- line: Line number to start reading from (1-based)
- limit: Maximum number of lines to read

=cut

sub fs_read_text_file {
    my ($self, $session_id, $path, $callback, %opts) = @_;
    
    unless ($self->{client_capabilities}{fs}{readTextFile}) {
        $callback->(undef, { code => -32601, message => 'Client does not support fs.readTextFile' });
        return undef;
    }
    
    my $params = {
        sessionId => $session_id,
        path => $path,
    };
    
    $params->{line} = $opts{line} if exists $opts{line};
    $params->{limit} = $opts{limit} if exists $opts{limit};
    
    my $req_id = $self->{transport}->send_request('fs/read_text_file', $params);
    $self->{pending_requests}{$req_id} = $callback;
    return $req_id;
}

=head2 fs_write_text_file($session_id, $path, $content, $callback)

Request the client to write a file (if client supports fs.writeTextFile).

The client MUST create the file if it doesn't exist.

=cut

sub fs_write_text_file {
    my ($self, $session_id, $path, $content, $callback) = @_;
    
    unless ($self->{client_capabilities}{fs}{writeTextFile}) {
        $callback->(undef, { code => -32601, message => 'Client does not support fs.writeTextFile' });
        return undef;
    }
    
    my $req_id = $self->{transport}->send_request('fs/write_text_file', {
        sessionId => $session_id,
        path => $path,
        content => $content,
    });
    
    $self->{pending_requests}{$req_id} = $callback;
    return $req_id;
}

# Legacy aliases for backwards compatibility
sub read_file { shift->fs_read_text_file(@_) }
sub write_file { shift->fs_write_text_file(@_) }

# ============================================================================
# Terminal Methods (Optional - depends on client capabilities)
# ============================================================================

=head2 terminal_create($session_id, $command, $callback, %opts)

Create a new terminal and start a command.

Options:
- args: Array of command arguments
- env: Array of {name, value} environment variables
- cwd: Working directory (absolute path)
- outputByteLimit: Maximum output bytes to retain

Returns terminalId in the response.

=cut

sub terminal_create {
    my ($self, $session_id, $command, $callback, %opts) = @_;
    
    unless ($self->{client_capabilities}{terminal}) {
        $callback->(undef, { code => -32601, message => 'Client does not support terminal' });
        return undef;
    }
    
    my $params = {
        sessionId => $session_id,
        command => $command,
    };
    
    $params->{args} = $opts{args} if exists $opts{args};
    $params->{env} = $opts{env} if exists $opts{env};
    $params->{cwd} = $opts{cwd} if exists $opts{cwd};
    $params->{outputByteLimit} = $opts{outputByteLimit} if exists $opts{outputByteLimit};
    
    my $req_id = $self->{transport}->send_request('terminal/create', $params);
    $self->{pending_requests}{$req_id} = $callback;
    return $req_id;
}

=head2 terminal_output($session_id, $terminal_id, $callback)

Get the current output from a terminal.

Response includes:
- output: The terminal output captured so far
- truncated: Whether output was truncated due to byte limits
- exitStatus: Present if command has exited (exitCode, signal)

=cut

sub terminal_output {
    my ($self, $session_id, $terminal_id, $callback) = @_;
    
    unless ($self->{client_capabilities}{terminal}) {
        $callback->(undef, { code => -32601, message => 'Client does not support terminal' });
        return undef;
    }
    
    my $req_id = $self->{transport}->send_request('terminal/output', {
        sessionId => $session_id,
        terminalId => $terminal_id,
    });
    
    $self->{pending_requests}{$req_id} = $callback;
    return $req_id;
}

=head2 terminal_wait_for_exit($session_id, $terminal_id, $callback)

Wait for the terminal command to complete.

Response includes:
- exitCode: The process exit code (may be null)
- signal: The signal that terminated the process (may be null)

=cut

sub terminal_wait_for_exit {
    my ($self, $session_id, $terminal_id, $callback) = @_;
    
    unless ($self->{client_capabilities}{terminal}) {
        $callback->(undef, { code => -32601, message => 'Client does not support terminal' });
        return undef;
    }
    
    my $req_id = $self->{transport}->send_request('terminal/wait_for_exit', {
        sessionId => $session_id,
        terminalId => $terminal_id,
    });
    
    $self->{pending_requests}{$req_id} = $callback;
    return $req_id;
}

=head2 terminal_kill($session_id, $terminal_id, $callback)

Kill the command without releasing the terminal.

After killing, you can still call terminal_output or terminal_wait_for_exit.
You MUST still call terminal_release when done.

=cut

sub terminal_kill {
    my ($self, $session_id, $terminal_id, $callback) = @_;
    
    unless ($self->{client_capabilities}{terminal}) {
        $callback->(undef, { code => -32601, message => 'Client does not support terminal' });
        return undef;
    }
    
    my $req_id = $self->{transport}->send_request('terminal/kill', {
        sessionId => $session_id,
        terminalId => $terminal_id,
    });
    
    $self->{pending_requests}{$req_id} = $callback;
    return $req_id;
}

=head2 terminal_release($session_id, $terminal_id, $callback)

Release a terminal and all its resources.

This kills the command if still running and makes the terminal ID invalid.
The Agent MUST call this when done with a terminal.

=cut

sub terminal_release {
    my ($self, $session_id, $terminal_id, $callback) = @_;
    
    unless ($self->{client_capabilities}{terminal}) {
        $callback->(undef, { code => -32601, message => 'Client does not support terminal' });
        return undef;
    }
    
    my $req_id = $self->{transport}->send_request('terminal/release', {
        sessionId => $session_id,
        terminalId => $terminal_id,
    });
    
    $self->{pending_requests}{$req_id} = $callback;
    return $req_id;
}

# ============================================================================
# Helpers
# ============================================================================

=head2 _generate_session_id()

Generate a unique session ID.

=cut

sub _generate_session_id {
    my ($self) = @_;
    
    my @chars = ('a'..'z', '0'..'9');
    my $id = 'sess_';
    $id .= $chars[rand @chars] for 1..16;
    
    return $id;
}

=head2 _load_session_from_storage($session_id)

Try to load a session from persistent storage.

=cut

sub _load_session_from_storage {
    my ($self, $session_id) = @_;
    
    # TODO: Implement session persistence with CLIO's session manager
    return undef;
}

=head2 _debug($message)

Write debug message to stderr.

=cut

sub _debug {
    my ($self, $message) = @_;
    print STDERR "[ACP::Agent] $message\n" if $self->{debug};
}

=head2 _log($message)

Write log message to stderr.

=cut

sub _log {
    my ($self, $message) = @_;
    print STDERR "[ACP::Agent] $message\n";
}

1;

__END__

=head1 ACP PROTOCOL FLOW

    Client (Editor)                     Agent (CLIO)
    ---------------                     ------------
       |                                    |
       |  -- initialize -->                 |
       |  <-- initialize response --        |
       |                                    |
       |  -- session/new -->                |
       |  <-- sessionId --                  |
       |                                    |
       |  -- session/prompt -->             |
       |  <-- session/update (chunks) --    |
       |  <-- session/update (tool_call) -- |
       |  <-- session/update (tool_update)--|
       |  <-- prompt response --            |
       |                                    |
       |  -- session/cancel -->             |
       |  <-- prompt response (cancelled) --|
       |                                    |

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
