package CLIO::UI::Chat;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use CLIO::Util::TextSanitizer qw(sanitize_text);
use CLIO::UI::Markdown;
use CLIO::UI::ANSI;
use CLIO::UI::Theme;
use CLIO::UI::ProgressSpinner;
use utf8;
use open ':std', ':encoding(UTF-8)';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Compat::Terminal qw(GetTerminalSize ReadMode ReadKey);  # Portable terminal control
use File::Spec;

# CRITICAL: Enable autoflush globally for STDOUT to prevent buffering issues
# This ensures streaming output appears immediately
$| = 1;
STDOUT->autoflush(1) if STDOUT->can('autoflush');

=head1 NAME

CLIO::UI::Chat - Retro BBS-style chat interface

=head1 DESCRIPTION

A clean, retro BBS-inspired chat interface that:
- Uses simple ASCII only (no unicode box-drawing)
- Provides color-coded user vs assistant messages  
- Supports slash commands (/help, /todo, /exec, etc)
- Feels like a classic BBS/MUD from the 80s/90s
- Supports theming with /style and /theme commands

This is THE ONLY UI module for CLIO.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        session => $args{session},
        ai_agent => $args{ai_agent},
        config => $args{config},  # Config object
        debug => $args{debug} || 0,
        terminal_width => 80,  # Default, will be updated
        terminal_height => 24, # Default rows for pagination
        use_color => 1,  # Enable colors by default
        ansi => CLIO::UI::ANSI->new(enabled => 1, debug => $args{debug}),
        enable_markdown => 1,  # Enable markdown rendering by default
        readline => undef,  # CLIO::Core::ReadLine instance
        completer => undef,  # TabCompletion instance
        screen_buffer => [],  # Message history for repaint
        line_count => 0,      # For pagination
        max_buffer_size => 100, # Keep last 100 messages
        # Arrow key pagination support
        pages => [],          # Buffer of pages for navigation
        current_page => [],   # Current page being built
        page_index => 0,      # Current page number for navigation
    };
    
    bless $self, $class;
    
    # Initialize theme manager
    # Load style/theme from session state, falling back to global config, then default
    my $saved_style = ($self->{session} ? $self->{session}->state()->{style} : undef)
                   || ($self->{config} ? $self->{config}->get('style') : undef)
                   || 'default';
    my $saved_theme = ($self->{session} ? $self->{session}->state()->{theme} : undef)
                   || ($self->{config} ? $self->{config}->get('theme') : undef)
                   || 'default';
    
    $self->{theme_mgr} = CLIO::UI::Theme->new(
        debug => $args{debug},
        ansi => $self->{ansi},
        style => $args{style} || $saved_style,
        theme => $args{theme} || $saved_theme,
    );
    
    # Initialize markdown renderer with theme manager
    $self->{markdown_renderer} = CLIO::UI::Markdown->new(
        debug => $args{debug},
        theme_mgr => $self->{theme_mgr},
    );
    
    # Get terminal size (width and height)
    eval {
        my ($width, $height) = GetTerminalSize();
        $self->{terminal_width} = $width if $width && $width > 0;
        $self->{terminal_height} = $height if $height && $height > 0;
    };
    
    # Fallback to LINES environment variable if available
    if ($ENV{LINES} && $ENV{LINES} > 0) {
        $self->{terminal_height} = $ENV{LINES};
    }
    
    # Setup tab completion if running interactively
    if (-t STDIN) {
        $self->setup_tab_completion();
    }
    
    return $self;
}

=head2 refresh_terminal_size

Refresh terminal dimensions (handle resize events)

=cut

sub refresh_terminal_size {
    my ($self) = @_;
    
    eval {
        my ($width, $height) = GetTerminalSize();
        $self->{terminal_width} = $width if $width && $width > 0;
        $self->{terminal_height} = $height if $height && $height > 0;
    };
    
    # Fallback to environment variables
    if ($ENV{COLUMNS} && $ENV{COLUMNS} > 0) {
        $self->{terminal_width} = $ENV{COLUMNS};
    }
    if ($ENV{LINES} && $ENV{LINES} > 0) {
        $self->{terminal_height} = $ENV{LINES};
    }
}

=head2 flush_output_buffer

Flush any pending streaming output to ensure message ordering.
Called by WorkflowOrchestrator before executing tools to prevent
tool output from appearing before agent text.

This is part of the handshake mechanism to fix message ordering issues
where streaming content was being displayed after tool execution output.

=cut

sub flush_output_buffer {
    my ($self) = @_;
    
    my $printed_content = 0;
    
    # Flush the streaming markdown buffer if it exists and has content
    if ($self->{_streaming_markdown_buffer} && $self->{_streaming_markdown_buffer} =~ /\S/) {
        my $output = $self->{_streaming_markdown_buffer};
        if ($self->{enable_markdown}) {
            $output = $self->render_markdown($self->{_streaming_markdown_buffer});
        }
        print $output;
        # DO NOT add extra newline - content already has proper line endings from streaming
        $self->{_streaming_markdown_buffer} = '';
        $printed_content = 1;
    }
    
    # Flush the line buffer if it has content (partial line)
    if ($self->{_streaming_line_buffer} && $self->{_streaming_line_buffer} =~ /\S/) {
        my $output = $self->{_streaming_line_buffer};
        if ($self->{enable_markdown}) {
            $output = $self->render_markdown($self->{_streaming_line_buffer});
        }
        print $output;
        # Add newline only for partial lines (those that don't already have one)
        print "\n" unless $output =~ /\n$/;
        $self->{_streaming_line_buffer} = '';
        $printed_content = 1;
    }
    
    # Force STDOUT flush
    STDOUT->flush() if STDOUT->can('flush');
    $| = 1;
    
    print STDERR "[DEBUG][Chat] Buffer flushed for tool execution handshake (printed=$printed_content)\n" 
        if $self->{debug};
    
    return 1;
}

=head2 reset_streaming_state

Reset the streaming state to allow a new "CLIO: " prefix to be printed.
Called by WorkflowOrchestrator after tool execution completes, before
the next AI iteration starts streaming.

This ensures that each new AI response chunk after tool execution
gets a proper "CLIO: " prefix.

=cut

sub reset_streaming_state {
    my ($self) = @_;
    
    # Mark that we need a new CLIO: prefix on next chunk
    $self->{_need_agent_prefix} = 1;
    
    print STDERR "[DEBUG][Chat] Streaming state reset - next chunk will get CLIO: prefix\n" 
        if $self->{debug};
    
    return 1;
}

=head2 run

Main chat loop - displays interface and processes user input

=cut

sub run {
    my ($self) = @_;
    
    # Display header
    $self->display_header();
    
    # Main loop
    while (1) {
        # Get user input
        my $input = $self->get_input();
        
        # Handle empty input
        next unless defined $input && length($input) > 0;
        
        # Handle standalone '?' as help command
        if ($input eq '?') {
            $input = '/help';
        }
        
        # Handle commands
        if ($input =~ /^\//) {
            my ($continue, $ai_prompt) = $self->handle_command($input);
            last unless $continue;
            
            # If command returned a prompt, use it as the next user input
            if ($ai_prompt) {
                $input = $ai_prompt;
                # Fall through to AI processing below
            } else {
                next;  # Command handled, get next input
            }
        }
        
        # Display user message (if not already from a command)
        unless ($input =~ /^\//) {
            $self->display_user_message($input);
        }
        
        # Process with AI agent (using streaming)
        if ($self->{ai_agent}) {
            print STDERR "[DEBUG][Chat] About to process user input with AI agent\n" if should_log('DEBUG');
            
            # Refresh terminal size before output (handle resize)
            $self->refresh_terminal_size();
            
            # Show progress indicator while waiting for AI response
            my $spinner = CLIO::UI::ProgressSpinner->new(
                frames => ['.', 'o', 'O', 'o', '.'],
                delay => 150000,  # 150ms between frames
            );
            $spinner->start();
            
            # Reset pagination state before streaming
            $self->{line_count} = 0;
            $self->{stop_streaming} = 0;
            $self->{pages} = [];
            $self->{current_page} = [];
            $self->{page_index} = 0;
            
            my $first_chunk_received = 0;
            my $accumulated_content = '';
            my $final_metrics = undef;
            
            # Smart buffering for markdown rendering (Option D)
            # Store buffers in $self so flush_output_buffer can access them
            $self->{_streaming_line_buffer} = '';      # Buffer for extracting complete lines
            $self->{_streaming_markdown_buffer} = '';  # Accumulates lines for batch rendering
            my $markdown_line_count = 0;   # Lines in current markdown buffer
            my $in_code_block = 0;         # Track if inside ```code block```
            my $in_table = 0;              # Track if inside table
            my $last_flush_time = time();  # Timestamp of last flush
            
            # Define streaming callback with smart batched markdown rendering
            my $on_chunk = sub {
                my ($chunk, $metrics) = @_;
                
                print STDERR "[DEBUG][Chat] Received chunk: " . substr($chunk, 0, 50) . "...\n" if $self->{debug};
                
                # Stop progress spinner on first chunk (AI is now responding)
                if (!$first_chunk_received) {
                    $spinner->stop();
                }
                
                # Display role label on first chunk OR when _need_agent_prefix is set
                # (reset after tool execution to show new CLIO: prefix for continuation)
                if (!$first_chunk_received || $self->{_need_agent_prefix}) {
                    $first_chunk_received = 1;
                    $self->{_need_agent_prefix} = 0;  # Clear the flag
                    print $self->colorize("CLIO: ", 'ASSISTANT');
                    STDOUT->flush() if STDOUT->can('flush');  # Ensure CLIO: appears immediately
                    $self->{line_count}++;  # Count the CLIO: line
                }
                
                # Add chunk to line buffer (using $self for access from flush_output_buffer)
                $self->{_streaming_line_buffer} .= $chunk;
                
                # Process complete lines
                while ($self->{_streaming_line_buffer} =~ /\n/) {
                    my $pos = index($self->{_streaming_line_buffer}, "\n");
                    my $line = substr($self->{_streaming_line_buffer}, 0, $pos);
                    $self->{_streaming_line_buffer} = substr($self->{_streaming_line_buffer}, $pos + 1);
                    
                    # Update markdown context state
                    if ($line =~ /^```/) {
                        $in_code_block = !$in_code_block;
                    }
                    $in_table = ($line =~ /^\|.*\|$/);
                    
                    # Add line to markdown buffer (using $self)
                    $self->{_streaming_markdown_buffer} .= $line . "\n";
                    $markdown_line_count++;
                    
                    # Determine if we should flush the buffer
                    my $current_time = time();
                    my $buffer_size_threshold = 10;     # Flush every 10 lines
                    my $time_threshold = 0.5;            # Or every 500ms
                    
                    # Flush buffer when:
                    # 1. Buffer has enough lines (size threshold)
                    # 2. Timeout reached (prevents stalling)
                    # Note: We DON'T flush on pattern complete - let patterns accumulate in buffer
                    my $should_flush = (
                        $markdown_line_count >= $buffer_size_threshold ||  # Buffer full
                        ($current_time - $last_flush_time >= $time_threshold)  # Timeout
                    );
                    
                    if ($should_flush) {
                        # Render accumulated markdown buffer
                        print STDERR "[DEBUG][Chat] Periodic flush of markdown_buffer (" . length($self->{_streaming_markdown_buffer}) . " bytes, $markdown_line_count lines)\n" if $self->{debug};
                        print STDERR "[DEBUG][Chat] Buffer ends with: " . substr($self->{_streaming_markdown_buffer}, -80) . "\n" if $self->{debug};
                        my $output = $self->{_streaming_markdown_buffer};
                        if ($self->{enable_markdown}) {
                            $output = $self->render_markdown($self->{_streaming_markdown_buffer});
                        }
                        
                        # Print rendered output and flush immediately
                        print $output;
                        STDOUT->flush() if STDOUT->can('flush');
                        
                        # Buffer lines for page navigation (split back to lines)
                        my @rendered_lines = split /\n/, $self->{_streaming_markdown_buffer};
                        push @{$self->{current_page}}, @rendered_lines;
                        $self->{line_count} += scalar(@rendered_lines);
                        
                        # Reset markdown buffer
                        $self->{_streaming_markdown_buffer} = '';
                        $markdown_line_count = 0;
                        $last_flush_time = $current_time;
                        
                        # Check pagination
                        if ($self->{line_count} >= $self->{terminal_height}) {
                            # Pause for user to read (streaming mode)
                            my $response = $self->pause(1);  # 1 = streaming mode
                            if ($response eq 'Q') {
                                $self->{stop_streaming} = 1;
                                return;  # Stop streaming
                            }
                            
                            # Reset for next page
                            $self->{line_count} = 0;
                            $self->{current_page} = [];
                        }
                    }
                }
                
                # Accumulate content
                $accumulated_content .= $chunk;
                
                # Store metrics
                $final_metrics = $metrics;
            };
            
            # Track tool calls and display which tool is being executed
            my $current_tool = '';
            my $on_tool_call = sub {
                my ($tool_name) = @_;
                
                return unless defined $tool_name;
                return if $tool_name eq $current_tool;  # Skip if same tool
                
                $current_tool = $tool_name;
                
                # Display which tool is being used
                print "\n" if $self->{_streaming_markdown_buffer} && $self->{_streaming_markdown_buffer} !~ /\n$/;  # Newline before tool if needed
                print $self->colorize("[TOOL] ", 'COMMAND') . $self->colorize("$tool_name", 'DATA') . "\n";
                $self->{line_count} += 2;
                
                print STDERR "[DEBUG][Chat] Tool called: $tool_name\n" if $self->{debug};
            };
            
            # Get conversation history from session
            my $conversation_history = [];
            if ($self->{session} && $self->{session}->can('get_conversation_history')) {
                $conversation_history = $self->{session}->get_conversation_history() || [];
                print STDERR "[DEBUG][Chat] Loaded " . scalar(@$conversation_history) . " messages from session history\n" if $self->{debug};
            }
            
            # Process request with streaming callback (match clio script pattern)
            print STDERR "[DEBUG][Chat] Calling process_user_request...\n" if should_log('DEBUG');
            my $result = $self->{ai_agent}->process_user_request($input, {
                on_chunk => $on_chunk,
                on_tool_call => $on_tool_call,  # Track which tools are being called
                conversation_history => $conversation_history,
                current_file => $self->{session}->{state}->{current_file},
                working_directory => $self->{session}->{state}->{working_directory},
                ui => $self  # Pass UI object for user_collaboration tool
            });
            print STDERR "[DEBUG][Chat] process_user_request returned, success=" . ($result->{success} ? "yes" : "no") . "\n" if $self->{debug};
            
            # Stop spinner in case it's still running (e.g., error before first chunk)
            $spinner->stop();
            
            # DEBUG: Check buffer states before flush
            if ($self->{debug}) {
                print STDERR "[DEBUG][Chat] AFTER streaming - markdown_buffer length=" . length($self->{_streaming_markdown_buffer} // '') . "\n";
                print STDERR "[DEBUG][Chat] AFTER streaming - line_buffer length=" . length($self->{_streaming_line_buffer} // '') . "\n";
                print STDERR "[DEBUG][Chat] AFTER streaming - first_chunk_received=$first_chunk_received\n";
            }
            
            # CRITICAL FIX: Flush any remaining content in buffers after streaming completes
            
            # 1. Flush markdown buffer if it has content
            if ($self->{_streaming_markdown_buffer} && $self->{_streaming_markdown_buffer} =~ /\S/) {
                print STDERR "[DEBUG][Chat] Flushing markdown_buffer (" . length($self->{_streaming_markdown_buffer}) . " bytes): " . 
                             substr($self->{_streaming_markdown_buffer}, -50) . "\n" if $self->{debug};
                my $output = $self->{_streaming_markdown_buffer};
                if ($self->{enable_markdown}) {
                    $output = $self->render_markdown($self->{_streaming_markdown_buffer});
                }
                print $output;
                STDOUT->flush() if STDOUT->can('flush');
            }
            
            # 2. Flush line buffer if it has content (incomplete final line)
            if ($self->{_streaming_line_buffer} && $self->{_streaming_line_buffer} =~ /\S/) {
                print STDERR "[DEBUG][Chat] Flushing line_buffer (" . length($self->{_streaming_line_buffer}) . " bytes): " . 
                             substr($self->{_streaming_line_buffer}, -50) . "\n" if $self->{debug};
                my $output = $self->{_streaming_line_buffer};
                if ($self->{enable_markdown}) {
                    $output = $self->render_markdown($self->{_streaming_line_buffer});
                }
                print $output, "\n";
                STDOUT->flush() if STDOUT->can('flush');
            }
            
            # Clear streaming buffers after final flush
            $self->{_streaming_markdown_buffer} = '';
            $self->{_streaming_line_buffer} = '';
            
            # Reset line count after streaming completes
            $self->{line_count} = 0;
            
            # NOTE: Don't add extra newline here - markdown buffer already has proper spacing
            # print "\n";  # REMOVED: Caused double spacing after responses
            
            print STDERR "[DEBUG][Chat] first_chunk_received=$first_chunk_received, accumulated_content_len=" . length($accumulated_content) . "\n" if $self->{debug};
            
            # Display metrics in debug mode
            if ($self->{debug} && $result->{metrics}) {
                my $m = $result->{metrics};
                print STDERR sprintf(
                    "[METRICS] TTFT: %.2fs | TPS: %.1f | Tokens: %d | Duration: %.2fs\n",
                    $m->{ttft} // 0,
                    $m->{tps} // 0,
                    $m->{tokens} // 0,
                    $m->{duration} // 0
                );
            }
            
            # Store complete message in session history
            # CRITICAL: Sanitize assistant responses before storing to prevent emoji encoding issues
            if ($result && $result->{final_response}) {
                print STDERR "[DEBUG][Chat] Storing final_response in session (length=" . length($result->{final_response}) . ")\n" if $self->{debug};
                my $sanitized = sanitize_text($result->{final_response});
                $self->{session}->add_message('assistant', $sanitized);
                $self->add_to_buffer('assistant', $result->{final_response});  # Display original with emojis
            } elsif ($accumulated_content) {
                print STDERR "[DEBUG][Chat] Storing accumulated_content in session (length=" . length($accumulated_content) . ")\n" if $self->{debug};
                # Fallback: use accumulated content
                my $sanitized = sanitize_text($accumulated_content);
                $self->{session}->add_message('assistant', $sanitized);
                $self->add_to_buffer('assistant', $accumulated_content);  # Display original with emojis
            }
            
            # Handle error case - show actual error message to user
            if (!$result || !$result->{success}) {
                my $error_msg = $result->{error} || $result->{final_response} || "No response received from AI";
                print STDERR "[DEBUG][Chat] Error occurred: $error_msg\n" if should_log('DEBUG');
                $self->display_error_message($error_msg);
                
                # Store error in session for context
                if ($self->{session}) {
                    $self->{session}->add_message('system', "Error: $error_msg");
                }
            }
            
            # Display usage summary after response
            $self->display_usage_summary();
            
            # Display premium charge notification if any
            if ($self->{session} && $self->{session}->can('state')) {
                my $state = $self->{session}->state();
                if ($state->{_premium_charge_message}) {
                    print "\n";
                    $self->display_system_message($state->{_premium_charge_message});
                    delete $state->{_premium_charge_message};  # Clear after displaying
                }
            }
        } else {
            $self->display_error_message("AI agent not initialized");
        }
        
        print "\n";
    }
    
    # Display goodbye
    print "\n";
    $self->display_system_message("Goodbye!");
}

=head2 display_header

Display the static retro BBS-style header (shown once at top)

=cut

sub display_header {
    my ($self) = @_;
    
    my $session_id = $self->{session} ? $self->{session}->{session_id} : 'unknown';
    my $model = $self->{config} ? $self->{config}->get('model') : 'unknown';
    
    # Get provider - try stored provider first, then detect from api_base
    my $provider = $self->{config} ? $self->{config}->get('provider') : undef;
    unless ($provider) {
        # Detect from api_base if not explicitly set
        my $api_base = $self->{config} ? $self->{config}->get('api_base') : '';
        my $presets = $self->{config} ? $self->{config}->get('provider_presets') : {};
        if ($api_base && $presets) {
            for my $p (keys %$presets) {
                if ($presets->{$p}->{base} eq $api_base) {
                    $provider = $p;
                    last;
                }
            }
        }
    }
    
    # Map provider names to display names
    my %provider_names = (
        'github_copilot' => 'GitHub Copilot',
        'openai' => 'OpenAI',
        'claude' => 'Anthropic Claude',
        'qwen' => 'Qwen',
        'deepseek' => 'DeepSeek',
        'gemini' => 'Google Gemini',
        'grok' => 'xAI Grok',
    );
    
    my $provider_display = $provider ? ($provider_names{$provider} || ucfirst($provider)) : 'Unknown';
    my $model_with_provider = "$model\@$provider_display";
    
    print "\n";
    
    # Dynamically render all banner lines (themes can have variable number)
    my $line_num = 1;
    while (1) {
        my $template_key = "banner_line$line_num";
        
        # Check if template exists first
        my $template = $self->{theme_mgr}->get_template($template_key);
        last unless $template;  # Stop when no more banner lines are defined
        
        my $rendered = $self->{theme_mgr}->render($template_key, {
            session_id => $session_id,
            model => $model_with_provider,
        });
        
        print $rendered, "\n";
        $line_num++;
    }
    
    print "\n";
}

sub get_input {
    my ($self) = @_;
    
    # Check if running in --input mode (non-interactive)
    if (!-t STDIN) {
        # Display simple prompt for non-interactive mode
        print $self->colorize(": ", 'PROMPT');
        my $input = <STDIN>;
        
        # Handle EOF (end of piped input)
        if (!defined $input) {
            print "\n";
            return '/exit';
        }
        
        chomp $input;
        return $input;
    }
    
    # Interactive mode with our custom readline and tab completion
    if ($self->{readline}) {
        my $prompt = $self->colorize(": ", 'PROMPT');
        my $input = $self->{readline}->readline($prompt);
        
        # Handle Ctrl-D (EOF)
        if (!defined $input) {
            print "\n";
            return '/exit';
        }
        
        chomp $input;
        return $input;
    }
    
    # Fallback to basic input if readline not available
    print $self->colorize(": ", 'PROMPT');
    my $input = <STDIN>;
    
    # Handle Ctrl-D (EOF)
    if (!defined $input) {
        print "\n";
        return '/exit';
    }
    
    chomp $input;
    return $input;
}

=head2 display_user_message

Display a user message with role label (no timestamp)

=cut

sub display_user_message {
    my ($self, $message) = @_;
    
    # Add to screen buffer
    $self->add_to_buffer('user', $message);
    
    # Add to session history for AI context
    if ($self->{session}) {
        print STDERR "[DEBUG][Chat] Adding user message to session history\n" if should_log('DEBUG');
        $self->{session}->add_message('user', $message);
    } else {
        print STDERR "[ERROR][Chat] No session object - cannot store message!\n" if should_log('ERROR');
    }
    
    # Display with role label
    print $self->colorize("YOU: ", 'USER'), $message, "\n";
}

=head2 display_assistant_message

Display an assistant message with role label (no timestamp)

=cut

sub display_assistant_message {
    my ($self, $message) = @_;
    
    # Add to screen buffer (display with original emojis)
    $self->add_to_buffer('assistant', $message);
    
    # Add to session history for AI context (sanitized to prevent encoding issues)
    if ($self->{session}) {
        print STDERR "[DEBUG][Chat] Adding assistant message to session history\n" if should_log('DEBUG');
        my $sanitized = sanitize_text($message);
        $self->{session}->add_message('assistant', $sanitized);
    } else {
        print STDERR "[ERROR][Chat] No session object - cannot store message!\n" if should_log('ERROR');
    }
    
    # Display with role label
    print $self->colorize("CLIO: ", 'ASSISTANT'), $message, "\n";
}

=head2 display_system_message

Display a system message

=cut

sub display_system_message {
    my ($self, $message) = @_;
    
    # Add to screen buffer
    $self->add_to_buffer('system', $message);
    
    print $self->colorize("SYSTEM: ", 'SYSTEM'), $message, "\n";
}

=head2 display_error_message

Display an error message

=cut

sub display_error_message {
    my ($self, $message) = @_;
    
    # Add to screen buffer
    $self->add_to_buffer('error', $message);
    
    print $self->colorize("ERROR: ", 'ERROR'), $message, "\n";
}

=head2 request_collaboration

Request user input mid-execution for agent collaboration.
This is called by the user_collaboration tool to pause workflow
and get user response WITHOUT consuming additional premium requests.

Arguments:
- $message: The collaboration message/question from agent
- $context: Optional context string

Returns: User's response string, or undef if cancelled

=cut

sub request_collaboration {
    my ($self, $message, $context) = @_;
    
    print STDERR "[DEBUG][Chat] request_collaboration called\n" if should_log('DEBUG');
    
    # Display the agent's message using full markdown rendering (includes @-code to ANSI conversion)
    my $rendered_message = $self->render_markdown($message);
    print $self->colorize("CLIO: ", 'ASSISTANT'), $rendered_message, "\n";
    
    # Display context if provided
    if ($context && length($context) > 0) {
        my $rendered_context = $self->render_markdown($context);
        print $self->colorize("Context: ", 'SYSTEM'), "$rendered_context\n";
    }
    
    # Use the main readline instance (with shared history) if available,
    # otherwise create a new one for basic input
    my $readline = $self->{readline};
    unless ($readline) {
        require CLIO::Core::ReadLine;
        $readline = CLIO::Core::ReadLine->new(
            prompt => '',
            debug => $self->{debug}
        );
    }
    
    # Define the collaboration prompt
    my $collab_prompt = $self->colorize(": ", 'COLLAB_PROMPT');
    
    # Loop to handle multiple inputs (slash commands return to prompt)
    while (1) {
        my $response = $readline->readline($collab_prompt);
        
        unless (defined $response) {
            print "\n";
            return undef;  # EOF or cancelled
        }
        
        # Handle empty response
        if (!length($response)) {
            print $self->colorize("(No response provided - collaboration cancelled)\n", 'WARNING');
            return undef;
        }
        
        # Check for slash commands - process them and return to prompt
        if ($response =~ /^\//) {
            print STDERR "[DEBUG][Chat] Slash command in collaboration: $response\n" if should_log('DEBUG');
            
            # Display user command
            print $self->colorize("YOU: ", 'USER'), $response, "\n";
            
            # Process the command (but don't exit - return to collaboration prompt)
            my ($continue, $ai_prompt) = $self->handle_command($response);
            
            # If command requested exit, cancel collaboration
            if (!$continue) {
                print $self->colorize("(Collaboration ended by /exit command)\n", 'SYSTEM');
                return undef;
            }
            
            # If command generated an AI prompt, return it as the collaboration response
            if ($ai_prompt) {
                return $ai_prompt;
            }
            
            # Otherwise, return to the collaboration prompt for more input
            print $self->colorize("CLIO: ", 'ASSISTANT'), "(Command processed. What's your response?)\n";
            next;
        }
        
        # Regular response - display and return
        print $self->colorize("YOU: ", 'USER'), $response, "\n";
        return $response;
    }
}

=head2 display_paginated_list

Display a list with pagination (15 items per page).
User can navigate with [N]ext, [P]revious, [Q]uit.

Arguments:
- $title: Title to display
- $items: Array ref of items to display
- $formatter: Code ref to format each item (optional)

Returns: Nothing

=cut

sub display_paginated_list {
    my ($self, $title, $items, $formatter) = @_;
    
    # Default formatter: just print the item
    $formatter ||= sub { return $_[0] };
    
    # Use dynamic page size based on terminal height (or 15 if can't detect)
    my $page_size = $self->{term_height} ? $self->{term_height} - 10 : 15;
    
    my $total = scalar @$items;
    my $total_pages = int(($total + $page_size - 1) / $page_size);
    my $current_page = 0;
    
    if ($total == 0) {
        $self->display_system_message("No items to display");
        return;
    }
    
    # Detect if running in interactive mode (stdin is a terminal)
    my $is_interactive = -t STDIN;
    
    # If not interactive (pipe mode) or list is small, just display all items
    if (!$is_interactive || $total <= $page_size) {
        print "\n";
        print "=" x 80, "\n";
        print $self->colorize($title, 'DATA'), "\n";
        print "=" x 80, "\n";
        print "\n";
        
        for my $i (0 .. $total - 1) {
            my $formatted = $formatter->($items->[$i], $i);
            print "  $formatted\n";
        }
        
        print "\n";
        print "-" x 80, "\n";
        print $self->colorize("Total: $total items", 'DIM'), "\n";
        print "\n";
        return;
    }
    
    # Put terminal in raw mode for single-key input
    ReadMode('cbreak');
    
    while (1) {
        # Calculate page bounds
        my $start = $current_page * $page_size;
        my $end = $start + $page_size - 1;
        $end = $total - 1 if $end >= $total;
        
        # Clear screen and display page
        print "\e[2J\e[H";  # Clear screen + home cursor
        print "\n";
        print "=" x 80, "\n";
        print $self->colorize($title, 'DATA'), "\n";
        print "=" x 80, "\n";
        print "\n";
        
        # Display items for this page
        for my $i ($start .. $end) {
            my $formatted = $formatter->($items->[$i], $i);
            print "  $formatted\n";
        }
        
        print "\n";
        print "-" x 80, "\n";
        
        # Navigation info
        my $showing = sprintf("Showing %d-%d of %d (Page %d/%d)", 
            $start + 1, $end + 1, $total, $current_page + 1, $total_pages);
        print $self->colorize($showing, 'DIM'), "\n";
        
        # Navigation prompt
        my @nav_options;
        push @nav_options, $self->colorize("[N]ext", 'PROMPT') if $current_page < $total_pages - 1;
        push @nav_options, $self->colorize("[P]revious", 'PROMPT') if $current_page > 0;
        push @nav_options, $self->colorize("[Q]uit", 'PROMPT');
        
        print join(" | ", @nav_options), ": ";
        
        # Get user input (single key)
        my $key = ReadKey(0);
        print "\n";
        
        # Handle navigation
        if ($key =~ /^[nN]$/ && $current_page < $total_pages - 1) {
            $current_page++;
        }
        elsif ($key =~ /^[pP]$/ && $current_page > 0) {
            $current_page--;
        }
        elsif ($key =~ /^[qQ]$/) {
            last;
        }
    }
    
    # Restore terminal mode
    ReadMode('restore');
}

=head2 handle_command

Process slash commands. Returns 0 to exit, 1 to continue

=cut

sub handle_command {
    my ($self, $command) = @_;
    
    # Remove leading slash
    $command =~ s/^\///;
    
    # Split into command and args
    my ($cmd, @args) = split /\s+/, $command;
    $cmd = lc($cmd);
    
    if ($cmd eq 'exit' || $cmd eq 'quit' || $cmd eq 'q') {
        return 0;  # Signal to exit
    }
    elsif ($cmd eq 'help' || $cmd eq 'h' || $cmd eq '?') {
        $self->display_help();
    }
    elsif ($cmd eq 'clear' || $cmd eq 'cls') {
        $self->repaint_screen();
    }
    elsif ($cmd eq 'shell' || $cmd eq 'sh') {
        $self->handle_shell_command();
    }
    elsif ($cmd eq 'debug') {
        $self->{debug} = !$self->{debug};
        $self->display_system_message("Debug mode: " . ($self->{debug} ? "ON" : "OFF"));
    }
    elsif ($cmd eq 'color') {
        $self->{use_color} = !$self->{use_color};
        $self->display_system_message("Color mode: " . ($self->{use_color} ? "ON" : "OFF"));
    }
    elsif ($cmd eq 'session') {
        my $session_id = $self->{session} ? $self->{session}->{session_id} : 'unknown';
        $self->display_system_message("Current session: $session_id");
    }
    elsif ($cmd eq 'config') {
        $self->handle_config_command(@args);
    }
    elsif ($cmd eq 'api') {
        $self->handle_api_command(@args);
    }
    elsif ($cmd eq 'loglevel') {
        $self->handle_loglevel_command(@args);
    }
    elsif ($cmd eq 'style') {
        $self->handle_style_command(@args);
    }
    elsif ($cmd eq 'theme') {
        $self->handle_theme_command(@args);
    }
    elsif ($cmd eq 'login') {
        $self->handle_login_command(@args);
    }
    elsif ($cmd eq 'logout') {
        $self->handle_logout_command(@args);
    }
    elsif ($cmd eq 'edit') {
        $self->handle_edit_command(join(' ', @args));
    }
    elsif ($cmd eq 'multi-line' || $cmd eq 'multiline' || $cmd eq 'ml') {
        $self->handle_multiline_command();
    }
    elsif ($cmd eq 'performance' || $cmd eq 'perf') {
        $self->handle_performance_command(@args);
    }
    elsif ($cmd eq 'todo') {
        $self->handle_todo_command(@args);
    }
    elsif ($cmd eq 'billing' || $cmd eq 'bill' || $cmd eq 'usage') {
        $self->handle_billing_command(@args);
    }
    elsif ($cmd eq 'models') {
        $self->handle_models_command(@args);
    }
    elsif ($cmd eq 'context' || $cmd eq 'ctx') {
        $self->handle_context_command(@args);
    }
    elsif ($cmd eq 'skills' || $cmd eq 'skill') {
        my $result = $self->handle_skills_command(@args);
        return $result if $result;  # May return (1, $prompt) for AI execution
    }
    elsif ($cmd eq 'prompt') {
        $self->handle_prompt_command(@args);
    }
    elsif ($cmd eq 'explain') {
        my $prompt = $self->handle_explain_command(@args);
        return (1, $prompt) if $prompt;  # Return prompt to be sent to AI
    }
    elsif ($cmd eq 'review') {
        my $prompt = $self->handle_review_command(@args);
        return (1, $prompt) if $prompt;  # Return prompt to be sent to AI
    }
    elsif ($cmd eq 'test') {
        my $prompt = $self->handle_test_command(@args);
        return (1, $prompt) if $prompt;  # Return prompt to be sent to AI
    }
    elsif ($cmd eq 'fix') {
        my $prompt = $self->handle_fix_command(@args);
        return (1, $prompt) if $prompt;  # Return prompt to be sent to AI
    }
    elsif ($cmd eq 'doc') {
        my $prompt = $self->handle_doc_command(@args);
        return (1, $prompt) if $prompt;  # Return prompt to be sent to AI
    }
    elsif ($cmd eq 'commit') {
        $self->handle_commit_command(@args);
    }
    elsif ($cmd eq 'diff') {
        $self->handle_diff_command(@args);
    }
    elsif ($cmd eq 'status' || $cmd eq 'st') {
        $self->handle_status_command(@args);
    }
    elsif ($cmd eq 'log') {
        $self->handle_log_command(@args);
    }
    elsif ($cmd eq 'gitlog' || $cmd eq 'gl') {
        $self->handle_gitlog_command(@args);
    }
    elsif ($cmd eq 'exec' || $cmd eq 'shell' || $cmd eq 'sh') {
        $self->handle_exec_command(@args);
    }
    elsif ($cmd eq 'switch') {
        $self->handle_switch_command(@args);
    }
    elsif ($cmd eq 'read' || $cmd eq 'view' || $cmd eq 'cat') {
        $self->handle_read_command(@args);
    }
    else {
        $self->display_error_message("Unknown command: /$cmd (type /help for help)");
    }
    
    print "\n";
    return 1;  # Continue
}

=head2 display_help

Display help message with available commands

=cut

sub display_help {
    my ($self) = @_;
    
    # Refresh terminal size before pagination (handle resize)
    $self->refresh_terminal_size();
    
    # Reset pagination state
    $self->{line_count} = 0;
    $self->{pages} = [];
    $self->{current_page} = [];
    $self->{page_index} = 0;
    
    # Build help text as array of lines for pagination
    my @help_lines = ();
    
    push @help_lines, "";
    push @help_lines, $self->colorize("CLIO Commands", 'DATA');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("CHAT COMMANDS", 'DATA');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/help, /h, /?', 'PROMPT'), 'Display this help');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/exit, /quit, /q', 'PROMPT'), 'Exit the chat');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/clear, /cls', 'PROMPT'), 'Clear the screen');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/shell, /sh', 'PROMPT'), 'Launch shell (exit to return)');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("TODO MANAGEMENT", 'DATA');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/todo', 'PROMPT'), "View agent's todo list");
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/todo add <text>', 'PROMPT'), 'Add new todo (Title | Description)');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/todo done <id>', 'PROMPT'), 'Mark todo as completed');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/todo clear', 'PROMPT'), 'Clear completed todos');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("DEVELOPER", 'DATA');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/explain [file]', 'PROMPT'), 'Explain code functionality');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/review [file]', 'PROMPT'), 'Review code for issues');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/test [file]', 'PROMPT'), 'Generate tests for code');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/fix <file>', 'PROMPT'), 'Propose fixes for problems');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/doc <file>', 'PROMPT'), 'Generate documentation');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("SKILLS", 'DATA');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/skills add <name> "<text>"', 'PROMPT'), 'Add custom skill');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/skills list', 'PROMPT'), 'List all skills');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/skills use <name> [file]', 'PROMPT'), 'Execute skill');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/skills show <name>', 'PROMPT'), 'Display skill');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/skills delete <name>', 'PROMPT'), 'Delete skill');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("PROMPT MANAGEMENT", 'DATA');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/prompt show', 'PROMPT'), 'Display current system prompt');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/prompt list', 'PROMPT'), 'List available prompts');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/prompt set <name>', 'PROMPT'), 'Switch to named prompt');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/prompt edit [name]', 'PROMPT'), 'Edit prompt in $EDITOR');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/prompt save <name>', 'PROMPT'), 'Save current as new');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/prompt delete <name>', 'PROMPT'), 'Delete custom prompt');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/prompt reset', 'PROMPT'), 'Reset to default');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("GIT INTEGRATION", 'DATA');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/status, /st', 'PROMPT'), 'Show git status');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/diff [file]', 'PROMPT'), 'Show git diff');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/log [n]', 'PROMPT'), 'Show recent commits (default: 10)');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/commit [message]', 'PROMPT'), 'Stage and commit changes');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("FILE VIEWER", 'DATA');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/read <file>', 'PROMPT'), 'View file with markdown rendering');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/view <file>', 'PROMPT'), 'Alias for /read');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("SYSTEM", 'DATA');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/billing, /usage', 'PROMPT'), 'Display API usage and billing stats');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/models', 'PROMPT'), 'List available models and capabilities');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/context <action>', 'PROMPT'), 'Manage context files (add/list/clear/remove)');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/exec <command>', 'PROMPT'), 'Execute shell command');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/switch', 'PROMPT'), 'Switch to different session');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/debug', 'PROMPT'), 'Toggle debug mode');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("CONFIGURATION", 'DATA');
    
    # Only show GitHub auth commands when using github_copilot provider
    my $current_provider = $self->{config} ? $self->{config}->get('provider') : '';
    if ($current_provider && $current_provider eq 'github_copilot') {
        push @help_lines, sprintf("  %-30s %s", $self->colorize('/login', 'PROMPT'), 'Authenticate with GitHub Copilot');
        push @help_lines, sprintf("  %-30s %s", $self->colorize('/logout', 'PROMPT'), 'Sign out from GitHub');
    }
    
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/config show', 'PROMPT'), 'Display global configuration');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/config show session', 'PROMPT'), 'Display session state');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/config save', 'PROMPT'), 'Save to global config (default)');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/config save session', 'PROMPT'), 'Save to session only');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/api key <value>', 'PROMPT'), 'Set API key (global)');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/api base <url>', 'PROMPT'), 'Set API base URL (global + session)');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/api model <name>', 'PROMPT'), 'Set AI model (global + session)');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/api provider <name>', 'PROMPT'), 'Switch provider (global + session)');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/api session-model <name>', 'PROMPT'), 'Set AI model (session only)');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/api session-provider <name>', 'PROMPT'), 'Switch provider (session only)');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/api session-base <url>', 'PROMPT'), 'Set API base (session only)');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/api show', 'PROMPT'), 'Show API settings');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/loglevel [level]', 'PROMPT'), 'Set/show log level');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/config workdir [path]', 'PROMPT'), 'Set/show working directory');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("THEMING", 'DATA');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/style list', 'PROMPT'), 'List available color schemes');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/style show', 'PROMPT'), 'Show current style');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/style set <name>', 'PROMPT'), 'Switch color scheme');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/style save <name>', 'PROMPT'), 'Save current colors as new style');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/theme list', 'PROMPT'), 'List available output themes');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/theme show', 'PROMPT'), 'Show current theme');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/theme set <name>', 'PROMPT'), 'Switch output theme');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/theme save <name>', 'PROMPT'), 'Save current templates as new theme');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("EDITING", 'DATA');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/edit <file>', 'PROMPT'), 'Open file in external editor');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/multi-line, /ml', 'PROMPT'), 'Edit multi-line prompt in editor');
    push @help_lines, "";
    
    # Output with pagination
    for my $line (@help_lines) {
        last unless $self->writeline($line);
    }
    
    # Reset line count after display
    $self->{line_count} = 0;
}

=head2 handle_api_command

Handle /api commands for API settings

=cut

sub handle_api_command {
    my ($self, $action, @args) = @_;
    
    $action ||= 'show';
    $action = lc($action);
    
    if ($action eq 'key') {
        my $key = $args[0];
        unless ($key) {
            $self->display_error_message("Usage: /api key <value>");
            return;
        }
        $self->{config}->set('api_key', $key);  # Marks as user-set
        
        # Auto-save config (user expects settings to persist)
        if ($self->{config}->save()) {
            $self->display_system_message("API key set and saved");
        } else {
            $self->display_system_message("API key set (warning: failed to save)");
        }
        
        # CRITICAL FIX: Re-initialize APIManager with new API key
        # This ensures the key is picked up immediately without restart
        print STDERR "[DEBUG][Chat] Re-initializing APIManager after api_key change\n" if $self->{debug};
        require CLIO::Core::APIManager;
        my $new_api = CLIO::Core::APIManager->new(
            debug => $self->{debug},
            session => $self->{session}->state(),
            config => $self->{config}
        );
        $self->{ai_agent}->{api} = $new_api;
    }
    elsif ($action eq 'base') {
        my $base = $args[0];
        unless ($base) {
            $self->display_error_message("Usage: /api base <url>");
            return;
        }
        $self->{config}->set('api_base', $base);  # Marks as user-set
        
        # Auto-save config (user expects settings to persist)
        if ($self->{config}->save()) {
            $self->display_system_message("API base URL set to: $base (saved)");
        } else {
            $self->display_system_message("API base URL set to: $base (warning: failed to save)");
        }
        
        # Re-initialize APIManager to pick up new api_base
        print STDERR "[DEBUG][Chat] Re-initializing APIManager after api_base change\n" if $self->{debug};
        require CLIO::Core::APIManager;
        my $new_api = CLIO::Core::APIManager->new(
            debug => $self->{debug},
            session => $self->{session}->state(),
            config => $self->{config}
        );
        $self->{ai_agent}->{api} = $new_api;
    }
    elsif ($action eq 'model') {
        my $model = $args[0];
        unless ($model) {
            $self->display_error_message("Usage: /api model <name>");
            return;
        }
        $self->{config}->set('model', $model);  # Marks as user-set
        
        # Auto-save config (user expects settings to persist)
        if ($self->{config}->save()) {
            $self->display_system_message("Model set to: $model (saved)");
        } else {
            $self->display_system_message("Model set to: $model (warning: failed to save)");
        }
        
        # Re-initialize APIManager to pick up new model
        print STDERR "[DEBUG][Chat] Re-initializing APIManager after model change\n" if $self->{debug};
        require CLIO::Core::APIManager;
        my $new_api = CLIO::Core::APIManager->new(
            debug => $self->{debug},
            session => $self->{session}->state(),
            config => $self->{config}
        );
        $self->{ai_agent}->{api} = $new_api;
    }
    elsif ($action eq 'provider') {
        my $provider = $args[0];
        unless ($provider) {
            $self->display_error_message("Usage: /api provider <name>");
            # Show available providers from Providers.pm
            require CLIO::Providers;
            my @providers = CLIO::Providers::list_providers();
            $self->display_system_message("Available providers: " . join(', ', @providers));
            return;
        }
        
        # Try to set the provider (this uses Providers.pm internally)
        if ($self->{config}->set_provider($provider)) {
            my $config = $self->{config}->get_all();
            
            # Auto-save config (user expects settings to persist)
            my $saved = $self->{config}->save();
            
            $self->display_system_message("Switched to provider: $provider" . ($saved ? " (saved)" : " (warning: failed to save)"));
            $self->display_system_message("  API Base: " . $config->{api_base} . " (from provider)");
            $self->display_system_message("  Model: " . $config->{model} . " (from provider)");
            if (!$saved) {
                $self->display_system_message("Use /config save to manually save if auto-save failed");
            }
            $self->display_system_message("(To override API base or model, use /api base or /api model)");
            
            # CRITICAL FIX: Re-initialize APIManager with new provider settings
            # This ensures api_base, model, and api_key are refreshed from config
            print STDERR "[DEBUG][Chat] Re-initializing APIManager after provider change\n" if $self->{debug};
            require CLIO::Core::APIManager;
            my $new_api = CLIO::Core::APIManager->new(
                debug => $self->{debug},
                session => $self->{session}->state(),
                config => $self->{config}
            );
            
            # Update ai_agent's API reference
            $self->{ai_agent}->{api} = $new_api;
            print STDERR "[DEBUG][Chat] Updated ai_agent with new APIManager instance\n" if $self->{debug};
            
            # If switching to github_copilot, check if authenticated and offer to login
            if ($provider eq 'github_copilot') {
                require CLIO::Core::GitHubAuth;
                my $gh_auth = CLIO::Core::GitHubAuth->new(debug => $self->{debug});
                unless ($gh_auth->is_authenticated()) {
                    print "\n";
                    $self->display_system_message("GitHub Copilot requires authentication");
                    print $self->colorize("  Would you like to login now? [Y/n]: ", 'PROMPT');
                    my $response = <STDIN>;
                    chomp $response if defined $response;
                    $response = lc($response || 'y');
                    
                    if ($response eq 'y' || $response eq 'yes' || $response eq '') {
                        # Trigger login flow
                        $self->handle_login_command();
                    } else {
                        $self->display_system_message("You can login later with: /login");
                    }
                }
            }
        } else {
            # Error message already printed by set_provider()
        }
    }
    elsif ($action eq 'show') {
        my $key = $self->{config}->get('api_key');
        my $base = $self->{config}->get('api_base');
        
        # Determine authentication status
        my $auth_status = '[NOT SET]';
        if ($key && length($key) > 0) {
            $auth_status = '[SET]';
        } else {
            # Check if using GitHub Copilot auth
            my $provider = $self->{config}->get('provider');
            
            if ($provider && $provider eq 'github_copilot') {
                eval {
                    require CLIO::Core::GitHubAuth;
                    my $gh_auth = CLIO::Core::GitHubAuth->new(debug => 0);
                    # Check if we have a usable token
                    my $token = $gh_auth->get_copilot_token();
                    if ($token) {
                        $auth_status = '[TOKEN]';
                    } else {
                        $auth_status = '[NO TOKEN - use /login]';
                    }
                };
            }
        }
        
        print "\n", $self->colorize("API CONFIGURATION", 'DATA'), "\n";
        print $self->colorize("=" x 50, 'DIM'), "\n\n";
        printf "  API Key:  %s\n", $auth_status;
        printf "  API Base: %s\n\n", $base || '[default]';
    }
    else {
        $self->display_error_message("Unknown action: $action");
        print "Usage: /api [key <value>|base <url>|model <name>|provider <name>|show]\n";
    }
}

=head2 handle_loglevel_command

Handle /loglevel command

=cut

sub handle_loglevel_command {
    my ($self, $level) = @_;
    
    unless ($level) {
        my $current = $self->{config}->get('loglevel') || $self->{config}->get('log_level') || 'WARNING';
        print "\n", $self->colorize("CURRENT LOG LEVEL", 'DATA'), "\n";
        print $self->colorize("=" x 50, 'DIM'), "\n\n";
        print "  $current\n\n";
        return;
    }
    
    my %valid = map { $_ => 1 } qw(DEBUG INFO WARNING ERROR CRITICAL);
    
    unless ($valid{uc($level)}) {
        $self->display_error_message("Invalid log level: $level");
        print "Valid levels: DEBUG, INFO, WARNING, ERROR, CRITICAL\n";
        return;
    }
    
    $self->{config}->set('loglevel', uc($level));
    $self->display_system_message("Log level set to: " . uc($level));
    $self->display_system_message("Use /config save to persist");
}

=head2 show_global_config

Display global configuration in formatted view

=cut

sub show_global_config {
    my ($self) = @_;
    
    print "\n", $self->colorize("GLOBAL CONFIGURATION", 'DATA'), "\n";
    print $self->colorize("=" x 70, 'DIM'), "\n\n";
    
    # API Settings
    print $self->colorize("API Settings:", 'SYSTEM'), "\n";
    
    # Detect provider from api_base if not explicitly set
    my $provider = $self->{config}->get('provider');
    unless ($provider) {
        my $api_base = $self->{config}->get('api_base') || '';
        my $presets = $self->{config}->get('provider_presets') || {};
        if ($api_base && $presets) {
            for my $p (keys %$presets) {
                if ($presets->{$p}->{base} eq $api_base) {
                    $provider = $p;
                    last;
                }
            }
        }
    }
    $provider ||= 'unknown';
    
    my $model = $self->{config}->get('model') || 'gpt-4';
    my $api_key = $self->{config}->get('api_key');
    my $api_base = $self->{config}->get('api_base');
    
    # Check for GitHub Copilot authentication if that's the provider
    my $auth_status = '[NOT SET]';
    if ($api_key && length($api_key) > 0) {
        $auth_status = '[SET]';
    } elsif ($provider eq 'github_copilot') {
        # Check for GitHub Copilot token file
        eval {
            require CLIO::Core::GitHubAuth;
            my $gh_auth = CLIO::Core::GitHubAuth->new(debug => 0);
            # Check if we have a usable token (get_copilot_token can fall back to github_token)
            my $token = $gh_auth->get_copilot_token();
            if ($token) {
                $auth_status = '[TOKEN]';
            } else {
                $auth_status = '[NO TOKEN - use /login]';
            }
        };
        # If eval failed, show that GitHub auth check failed
        if ($@) {
            $auth_status = '[NOT SET]';
        }
    }
    
    printf "  Provider:        %s\n", $provider;
    printf "  Model:           %s\n", $model;
    printf "  API Key:         %s\n", $auth_status;
    
    # Resolve API base URL to show actual endpoint
    my $display_url = $api_base || '[default]';
    if ($api_base && $api_base !~ m{^https?://}) {
        # It's a shorthand like 'sam' or 'github-copilot', resolve to actual endpoint
        my ($api_type, $models_url) = $self->_detect_api_type($api_base);
        if ($models_url) {
            # Extract base URL from models endpoint (remove /v1/models or /models suffix)
            $display_url = $models_url;
            $display_url =~ s{/v1/models$}{};
            $display_url =~ s{/models$}{};
            $display_url =~ s{/v1/chat/completions$}{};
            # If we removed something, show it resolved. Otherwise show original.
            $display_url = "$api_base → $display_url" if $display_url ne $models_url;
        }
    }
    printf "  API Base URL:    %s\n", $display_url;
    
    # UI Settings
    print "\n", $self->colorize("UI Settings:", 'SYSTEM'), "\n";
    my $style = $self->{config}->get('style') || 'default';
    my $theme = $self->{config}->get('theme') || 'default';
    my $loglevel = $self->{config}->get('loglevel') || $self->{config}->get('log_level') || 'WARNING';
    
    printf "  Color Style:     %s\n", $style;
    printf "  Output Theme:    %s\n", $theme;
    printf "  Log Level:       %s\n", $loglevel;
    
    # Paths
    print "\n", $self->colorize("Paths & Files:", 'SYSTEM'), "\n";
    require Cwd;
    my $workdir = $self->{config}->get('working_directory') || Cwd::getcwd();
    my $config_file = $self->{config}->{config_file};
    
    printf "  Working Dir:     %s\n", $workdir;
    printf "  Config File:     %s\n", $config_file;
    printf "  Sessions Dir:    %s\n", File::Spec->catdir('.', 'sessions');
    printf "  Styles Dir:      %s\n", File::Spec->catdir('.', 'styles');
    printf "  Themes Dir:      %s\n", File::Spec->catdir('.', 'themes');
    
    print "\n";
    print $self->colorize("Use '/config save' to persist changes", 'DIM'), "\n";
    print "\n";
}

=head2 show_session_config

Display session-specific configuration

=cut

sub show_session_config {
    my ($self) = @_;
    
    my $state = $self->{session}->state();
    
    print "\n", $self->colorize("SESSION CONFIGURATION", 'DATA'), "\n";
    print $self->colorize("=" x 70, 'DIM'), "\n\n";
    
    print $self->colorize("Session Info:", 'SYSTEM'), "\n";
    printf "  Session ID:   %s\n", $state->{session_id};
    printf "  Messages:     %d\n", scalar(@{$state->{history} || []});
    require Cwd;
    printf "  Working Dir:  %s\n", $state->{working_directory} || Cwd::getcwd();
    
    print "\n", $self->colorize("UI Settings:", 'SYSTEM'), "\n";
    # Fall back to global config if not set in session
    my $session_style = $state->{style} || $self->{config}->get('style') || 'default';
    my $session_theme = $state->{theme} || $self->{config}->get('theme') || 'default';
    printf "  Style:        %s%s\n", $session_style, ($state->{style} ? '' : ' (from global)');
    printf "  Theme:        %s%s\n", $session_theme, ($state->{theme} ? '' : ' (from global)');
    
    print "\n", $self->colorize("Model:", 'SYSTEM'), "\n";
    # Fall back to global config if not set in session (typical for new sessions)
    my $session_model = $state->{selected_model} || $self->{config}->get('model') || 'gpt-4';
    printf "  Selected:     %s%s\n", $session_model, ($state->{selected_model} ? '' : ' (from global)');
    
    print "\n";
}

=head2 handle_config_command

Handle /config commands (show and save only)

=cut

sub handle_config_command {
    my ($self, @args) = @_;
    
    unless ($self->{config}) {
        $self->display_error_message("Configuration system not available");
        return;
    }
    
    my $action = $args[0] || 'show';
    my $scope = $args[1] || 'global';
    
    $action = lc($action);
    $scope = lc($scope);
    
    if ($action eq 'show') {
        if ($scope eq 'session') {
            $self->show_session_config();
        } else {
            $self->show_global_config();
        }
    }
    elsif ($action eq 'save') {
        if ($scope eq 'session') {
            # Save current settings to session state only
            my $state = $self->{session}->state();
            $state->{style} = $self->{theme_mgr}->get_current_style();
            $state->{theme} = $self->{theme_mgr}->get_current_theme();
            require Cwd;
            $state->{working_directory} = Cwd::getcwd();
            $self->{session}->save();
            $self->display_system_message("Session configuration saved");
        } else {
            # Save to global config (existing behavior + style/theme)
            my $current_style = $self->{theme_mgr}->get_current_style();
            my $current_theme = $self->{theme_mgr}->get_current_theme();
            
            $self->{config}->set('style', $current_style);
            $self->{config}->set('theme', $current_theme);
            require Cwd;
            $self->{config}->set('working_directory', Cwd::getcwd());
            
            if ($self->{config}->save()) {
                $self->display_system_message("Global configuration saved successfully");
                $self->display_system_message("Style: $current_style, Theme: $current_theme");
            } else {
                $self->display_error_message("Failed to save configuration");
            }
        }
    }
    elsif ($action eq 'load') {
        $self->{config}->load();
        $self->display_system_message("Configuration reloaded");
    }
    elsif ($action eq 'workdir') {
        # Set or show working directory
        if ($scope && $scope ne 'global' && $scope ne 'session') {
            # scope is actually the directory path
            my $dir = $scope;
            # Expand tilde
            $dir =~ s/^~/$ENV{HOME}/;
            
            # Validate directory exists
            unless (-d $dir) {
                $self->display_error_message("Directory does not exist: $dir");
                return;
            }
            
            # Make absolute
            require Cwd;
            $dir = Cwd::abs_path($dir);
            
            # Update session state
            if ($self->{session} && $self->{session}->{state}) {
                $self->{session}->{state}->{working_directory} = $dir;
                $self->{session}->{state}->save();
                $self->display_system_message("Working directory set to: $dir");
            } else {
                $self->display_error_message("No active session");
            }
        } else {
            # Show current working directory
            if ($self->{session} && $self->{session}->{state}) {
                require Cwd;
                my $dir = $self->{session}->{state}->{working_directory} || Cwd::getcwd();
                $self->display_system_message("Current working directory: $dir");
            } else {
                $self->display_error_message("No active session");
            }
        }
    }
    else {
        $self->display_error_message("Unknown config command: $action");
        $self->display_system_message("Usage: /config [show|save|load|workdir] [session|<value>]");
        $self->display_system_message("For API settings, use: /api [key|base|model|provider] <value>");
        $self->display_system_message("Type /help to see all configuration commands");
    }
}

=head2 handle_login_command

Authenticate with GitHub using OAuth Device Code Flow

=cut

sub handle_login_command {
    my ($self, @args) = @_;
    
    # Load GitHubAuth module
    require CLIO::Core::GitHubAuth;
    
    my $auth = CLIO::Core::GitHubAuth->new(debug => $self->{debug});
    
    # Check if already authenticated
    if ($auth->is_authenticated()) {
        my $username = $auth->get_username() || 'unknown';
        $self->display_system_message("Already authenticated as: $username");
        $self->display_system_message("Use /logout to sign out first");
        return;
    }
    
    print "\n";
    print "=" x 80, "\n";
    print $self->colorize("GITHUB COPILOT AUTHENTICATION", 'DATA'), "\n";
    print "=" x 80, "\n";
    print "\n";
    
    # Start device flow
    print $self->colorize("Step 1:", 'PROMPT'), " Requesting device code from GitHub...\n";
    
    my $device_data;
    eval {
        $device_data = $auth->start_device_flow();
    };
    
    if ($@) {
        $self->display_error_message("Failed to start device flow: $@");
        return;
    }
    
    # Display verification instructions
    print "\n";
    print $self->colorize("Step 2:", 'PROMPT'), " Authorize in your browser\n\n";
    print "  1. Visit: ", $self->colorize($device_data->{verification_uri}, 'USER'), "\n";
    print "  2. Enter code: ", $self->colorize($device_data->{user_code}, 'DATA'), "\n";
    print "\n";
    print "  Waiting for authorization";
    
    # Poll for token with visual feedback
    my $github_token;
    
    print "\n  ";
    print $self->colorize("Waiting for authorization...", 'DIM');
    print " (this may take a few minutes)\n  ";
    
    eval {
        $github_token = $auth->poll_for_token(
            $device_data->{device_code}, 
            $device_data->{interval}
        );
    };
    
    if ($@) {
        print "\n";
        $self->display_error_message("Authentication failed: $@");
        return;
    }
    
    unless ($github_token) {
        print "\n";
        $self->display_error_message("Authentication timed out");
        return;
    }
    
    print $self->colorize("✓", 'PROMPT'), " Authorized!\n\n";
    
    # Exchange for Copilot token (optional - may fail with 404)
    print $self->colorize("Step 3:", 'PROMPT'), " Exchanging for Copilot token...\n";
    
    my $copilot_token;
    eval {
        $copilot_token = $auth->exchange_for_copilot_token($github_token);
    };
    
    if ($@) {
        $self->display_error_message("Failed to exchange for Copilot token: $@");
        return;
    }
    
    if ($copilot_token) {
        print "  ", $self->colorize("✓", 'PROMPT'), " Copilot token obtained\n\n";
    } else {
        print "  ", $self->colorize("[ ]", 'DIM'), " Copilot token unavailable (will use GitHub token directly)\n\n";
    }
    
    # Save tokens
    print $self->colorize("Step 4:", 'PROMPT'), " Saving tokens...\n";
    
    eval {
        $auth->save_tokens($github_token, $copilot_token);
    };
    
    if ($@) {
        $self->display_error_message("Failed to save tokens: $@");
        return;
    }
    
    print "  ", $self->colorize("✓", 'PROMPT'), " Tokens saved to ~/.clio/github_tokens.json\n\n";
    
    # Success!
    print "=" x 80, "\n";
    print $self->colorize("SUCCESS!", 'PROMPT'), "\n";
    print "=" x 80, "\n";
    print "\n";
    
    if ($copilot_token) {
        my $username = $copilot_token->{username} || 'unknown';
        my $expires_in = int(($copilot_token->{expires_at} - time()) / 60);
        $self->display_system_message("Authenticated as: $username");
        $self->display_system_message("Token expires in: ~$expires_in minutes");
        $self->display_system_message("Token will auto-refresh before expiration");
    } else {
        $self->display_system_message("Authenticated with GitHub token");
        $self->display_system_message("Using GitHub token directly (Copilot endpoint unavailable)");
    }
    print "\n";
    
    # CRITICAL: Reload APIManager to pick up new tokens
    print STDERR "[DEBUG][Chat] Reloading APIManager after /login to pick up new tokens\n" if $self->{debug};
    require CLIO::Core::APIManager;
    my $new_api = CLIO::Core::APIManager->new(
        debug => $self->{debug},
        session => $self->{session}->state(),
        config => $self->{config}
    );
    $self->{ai_agent}->{api} = $new_api;
    print STDERR "[DEBUG][Chat] APIManager reloaded successfully\n" if $self->{debug};
}

=head2 handle_logout_command

Sign out of GitHub authentication

=cut

sub handle_logout_command {
    my ($self, @args) = @_;
    
    # Load GitHubAuth module
    require CLIO::Core::GitHubAuth;
    
    my $auth = CLIO::Core::GitHubAuth->new(debug => $self->{debug});
    
    # Check if authenticated
    unless ($auth->is_authenticated()) {
        $self->display_system_message("Not currently authenticated");
        return;
    }
    
    my $username = $auth->get_username() || 'unknown';
    
    # Clear tokens
    $auth->clear_tokens();
    
    $self->display_system_message("Signed out from GitHub (was: $username)");
    $self->display_system_message("Use /login to authenticate again");
}

=head2 clear_screen

Clear the terminal screen and repaint from buffer

=cut

sub clear_screen {
    my ($self) = @_;
    
    # Clear screen using ANSI code
    print "\e[2J\e[H";  # Clear screen + home cursor
}

=head2 handle_edit_command

Open external editor to edit a file

=cut

sub handle_edit_command {
    my ($self, $filepath) = @_;
    
    unless ($filepath) {
        $self->display_error_message("Usage: /edit <filepath>");
        return;
    }
    
    # Expand tilde to home directory
    $filepath =~ s/^~/$ENV{HOME}/;
    
    # Make relative paths absolute if needed
    unless ($filepath =~ m{^/}) {
        require Cwd;
        my $cwd = Cwd::getcwd();
        $filepath = "$cwd/$filepath";
    }
    
    require CLIO::Core::Editor;
    my $editor = CLIO::Core::Editor->new(
        config => $self->{config},
        debug => $self->{debug}
    );
    
    # Check if editor is available
    unless ($editor->check_editor_available()) {
        $self->display_error_message("Editor not found: " . $editor->{editor});
        $self->display_system_message("Set editor with: /config editor <editor>");
        $self->display_system_message("Or set \$EDITOR or \$VISUAL environment variable");
        return;
    }
    
    my $result = $editor->edit_file($filepath);
    
    if ($result->{success}) {
        $self->display_system_message("File edited: $filepath");
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 handle_multiline_command

Open external editor for multi-line prompt input

=cut

sub handle_multiline_command {
    my ($self) = @_;
    
    require CLIO::Core::Editor;
    my $editor = CLIO::Core::Editor->new(
        config => $self->{config},
        debug => $self->{debug}
    );
    
    # Check if editor is available
    unless ($editor->check_editor_available()) {
        $self->display_error_message("Editor not found: " . $editor->{editor});
        $self->display_system_message("Set editor with: /config editor <editor>");
        $self->display_system_message("Or set \$EDITOR or \$VISUAL environment variable");
        return;
    }
    
    $self->display_system_message("Opening editor for multi-line input...");
    
    my $result = $editor->edit_multiline();
    
    if ($result->{success}) {
        my $content = $result->{content};
        
        # Display the prompt we're sending
        $self->display_system_message("Sending prompt to AI...");
        print "\n";
        
        # Display user message
        $self->display_user_message($content);
        
        # Send to AI agent
        if ($self->{ai_agent}) {
            my $ai_result = $self->{ai_agent}->process_user_request($content);
            
            if ($ai_result && $ai_result->{final_response}) {
                $self->display_assistant_message($ai_result->{final_response});
            } else {
                $self->display_error_message("No response from AI agent");
            }
        } else {
            $self->display_error_message("AI agent not available");
        }
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 handle_shell_command

Launch an interactive shell, giving user full terminal control.
User can exit the shell to return to CLIO.

=cut

sub handle_shell_command {
    my ($self) = @_;
    
    # Get user's shell (or default to /bin/bash)
    my $shell = $ENV{SHELL} || '/bin/bash';
    
    # Display message before launching
    print "\n";
    $self->display_system_message("Launching shell: $shell");
    $self->display_system_message("Type 'exit' or press Ctrl-D to return to CLIO");
    print "\n";
    
    # Launch shell with full TTY control
    # system() gives the shell complete control of the terminal
    system($shell);
    
    # Display message after returning
    print "\n";
    $self->display_system_message("Returned to CLIO");
    print "\n";
    
    return 1;  # Continue chat
}

=head2 handle_performance_command

Show API endpoint performance statistics

=cut

sub handle_performance_command {
    my ($self, $subcommand) = @_;
    
    # Get performance monitor from AI agent's API manager
    unless ($self->{ai_agent} && $self->{ai_agent}{api}) {
        $self->display_error_message("Performance monitoring not available (no API manager)");
        return;
    }
    
    my $monitor = $self->{ai_agent}{api}{performance_monitor};
    unless ($monitor) {
        $self->display_error_message("Performance monitor not initialized");
        return;
    }
    
    if ($subcommand && $subcommand eq 'best') {
        # Show best performing endpoint
        my $best = $monitor->get_best_endpoint();
        if ($best) {
            my $stats = $monitor->get_endpoint_stats($best);
            $self->display_system_message("Best Performing Endpoint: $best");
            print sprintf("  Success Rate: %.1f%%\n", $stats->{success_rate} * 100);
            print sprintf("  Avg Response: %.2fs\n", $stats->{avg_response_time});
            print sprintf("  Tokens/sec:   %.1f\n", $stats->{tokens_per_second} || 0);
        } else {
            $self->display_system_message("No performance data available yet");
        }
    } else {
        # Show all statistics
        my $stats_output = $monitor->format_stats('endpoint');
        print $stats_output;
        
        # Show model stats too
        my $model_stats = $monitor->format_stats('model');
        print $model_stats;
    }
}

=head2 handle_todo_command

Handle /todo commands for managing agent's todo list

=cut

sub handle_todo_command {
    my ($self, @args) = @_;
    
    unless ($self->{ai_agent}) {
        $self->display_error_message("AI agent not available");
        return;
    }
    
    # Get orchestrator and tool registry
    my $orchestrator = $self->{ai_agent}{orchestrator};
    unless ($orchestrator && $orchestrator->{tool_registry}) {
        $self->display_error_message("Tool system not available");
        return;
    }
    
    my $todo_tool = $orchestrator->{tool_registry}->get_tool('todo_operations');
    unless ($todo_tool) {
        $self->display_error_message("Todo tool not registered");
        return;
    }
    
    # Parse subcommand
    my $subcmd = @args ? lc($args[0]) : 'view';
    
    if ($subcmd eq 'view' || $subcmd eq 'list' || $subcmd eq '') {
        # View current todo list
        my $result = $todo_tool->execute(
            { operation => 'read' },
            { session => $self->{session}, ui => $self }
        );
        
        if ($result->{success}) {
            print $result->{output}, "\n";
        } else {
            $self->display_error_message($result->{error});
        }
    }
    elsif ($subcmd eq 'add' && @args >= 2) {
        # Add new todo: /todo add Title | Description
        my $todo_text = join(' ', @args[1..$#args]);
        my ($title, $description) = split /\s*\|\s*/, $todo_text, 2;
        
        unless ($title && $description) {
            $self->display_error_message("Usage: /todo add <title> | <description>");
            return;
        }
        
        # Get existing todos to determine next ID
        my $read_result = $todo_tool->execute(
            { operation => 'read' },
            { session => $self->{session}, ui => $self }
        );
        
        my @new_todo = ({
            title => $title,
            description => $description,
            status => 'not-started',
        });
        
        my $result = $todo_tool->execute(
            { operation => 'add', newTodos => \@new_todo },
            { session => $self->{session}, ui => $self }
        );
        
        if ($result->{success}) {
            $self->display_system_message("Todo added successfully");
            print $result->{output}, "\n";
        } else {
            $self->display_error_message($result->{error});
        }
    }
    elsif ($subcmd eq 'done' && @args >= 2) {
        # Mark todo as done: /todo done <id>
        my $todo_id = $args[1];
        
        unless ($todo_id =~ /^\d+$/) {
            $self->display_error_message("Invalid todo ID: $todo_id");
            return;
        }
        
        my $result = $todo_tool->execute(
            { operation => 'update', todoUpdates => [{ id => int($todo_id), status => 'completed' }] },
            { session => $self->{session}, ui => $self }
        );
        
        if ($result->{success}) {
            $self->display_system_message("Todo #$todo_id marked as completed");
        } else {
            $self->display_error_message($result->{error});
        }
    }
    elsif ($subcmd eq 'clear') {
        # Clear all completed todos
        my $read_result = $todo_tool->execute(
            { operation => 'read' },
            { session => $self->{session}, ui => $self }
        );
        
        if ($read_result->{success} && $read_result->{todos}) {
            my @incomplete = grep { $_->{status} ne 'completed' } @{$read_result->{todos}};
            
            my $result = $todo_tool->execute(
                { operation => 'write', todoList => \@incomplete },
                { session => $self->{session}, ui => $self }
            );
            
            if ($result->{success}) {
                $self->display_system_message("Cleared all completed todos");
            } else {
                $self->display_error_message($result->{error});
            }
        }
    }
    else {
        $self->display_error_message("Unknown todo command: $subcmd");
        $self->display_system_message("Usage: /todo [view|add|done|clear]");
    }
}

=head2 display_usage_summary

Display a brief usage summary after agent responses (similar to SAM format)

=cut

sub display_usage_summary {
    my ($self) = @_;
    
    return unless $self->{session} && $self->{session}->{state};
    
    my $billing = $self->{session}->{state}->{billing};
    return unless $billing;
    
    my $model = $billing->{model} || 'unknown';
    my $multiplier = $billing->{multiplier} || 0;
    
    # Only display for premium models (multiplier > 0)
    return if $multiplier == 0;
    
    # Only display if there was an ACTUAL charge in the last request (delta > 0)
    my $delta = $self->{session}{_last_quota_delta} || 0;
    return if $delta <= 0;
    
    # SAM style: Show the model's cost multiplier when there was a charge
    # Cost: 1x/3x/10x for premium models
    # For fractional multipliers (e.g., 0.33x), show with 2 decimal places
    # Status: Always shows current quota usage
    
    # Format multiplier: integers as "Nx", decimals as "N.NNx"
    my $cost_str;
    if ($multiplier == int($multiplier)) {
        # Integer multiplier: 1x, 3x, 10x
        $cost_str = sprintf("Cost: %dx", $multiplier);
    } else {
        # Fractional multiplier: 0.33x, 0.5x, etc.
        $cost_str = sprintf("Cost: %.2fx", $multiplier);
        $cost_str =~ s/\.?0+x$/x/;  # Strip trailing zeros: "1.00x" -> "1x"
    }
    my $quota_info = '';
    
    # Get quota status if available (stored by APIManager in session{quota})
    if ($self->{session}{quota}) {
        my $quota = $self->{session}{quota};
        my $used = $quota->{used} || 0;
        my $entitlement = $quota->{entitlement} || 0;
        my $percent_remaining = $quota->{percent_remaining} || 0;
        my $percent_used = 100.0 - $percent_remaining;
        
        # Format quota status - SAM style: "Status: X/Y Used: Z%"
        # For unlimited accounts, show ∞ for entitlement but still show used count
        my $used_fmt = $used;
        $used_fmt =~ s/(\d)(?=(\d{3})+$)/$1,/g;  # Add comma separators
        
        my $ent_display;
        if ($entitlement == -1) {
            $ent_display = "∞";
        } else {
            $ent_display = $entitlement;
            $ent_display =~ s/(\d)(?=(\d{3})+$)/$1,/g;  # Add comma separators
        }
        
        $quota_info = sprintf(" Status: %s/%s Used: %.1f%%", $used_fmt, $ent_display, $percent_used);
    }
    
    # SAM-style output: "SERVER: Cost: 1x Status: 379/1,500 Used: 25.3%"
    print $self->colorize("SERVER: ", 'SYSTEM');
    print $cost_str;
    print $quota_info;
    print "\n";
}

=head2 handle_billing_command

Display API usage and billing statistics

=cut

sub handle_billing_command {
    my ($self, @args) = @_;
    
    unless ($self->{session}) {
        $self->display_error_message("No active session");
        return;
    }
    
    unless ($self->{session}->can('get_billing_summary')) {
        $self->display_error_message("Billing tracking not available in this session");
        return;
    }
    
    my $billing = $self->{session}->get_billing_summary();
    
    print "\n";
    print $self->colorize("═" x 70, 'DATA'), "\n";
    print $self->colorize("GITHUB COPILOT BILLING", 'DATA'), "\n";
    print $self->colorize("═" x 70, 'DATA'), "\n";
    print "\n";
    
    # Get model and multiplier from session
    my $model = $self->{session}{state}{billing}{model} || 'unknown';
    my $multiplier = $self->{session}{state}{billing}{multiplier} || 0;
    
    # Format multiplier string:
    # - If 0: "Free (0x)"
    # - If integer (1.0, 2.0): "1x Premium", "2x Premium"
    # - If decimal (0.33, 1.5): "0.33x Premium", "1.5x Premium"
    my $multiplier_str;
    if ($multiplier == 0) {
        $multiplier_str = "Free (0x)";
    } elsif ($multiplier == int($multiplier)) {
        # Integer multiplier - no decimals needed
        $multiplier_str = sprintf("%dx Premium", $multiplier);
    } else {
        # Decimal multiplier - show up to 2 decimal places, strip trailing zeros
        $multiplier_str = sprintf("%.2fx Premium", $multiplier);
        $multiplier_str =~ s/\.?0+x/x/;  # Remove trailing zeros: "1.00x" -> "1x", "0.33x" stays
    }
    
    # Session summary
    print $self->colorize("Session Summary:", 'LABEL'), "\n";
    printf "  %-25s %s\n", "Model:", $self->colorize($model, 'DATA');
    printf "  %-25s %s\n", "Billing Rate:", $self->colorize($multiplier_str, 'DATA');
    
    # Show actual API requests vs GitHub Copilot premium requests charged
    my $total_api_requests = $billing->{total_requests} || 0;
    my $total_premium_charged = $billing->{total_premium_requests} || 0;
    
    printf "  %-25s %s\n", "API Requests (Total):", $self->colorize($total_api_requests, 'DATA');
    printf "  %-25s %s\n", "Premium Requests Charged:", $self->colorize($total_premium_charged, 'DATA');
    
    # Show quota allotment if available
    if ($self->{session}{quota}) {
        my $quota = $self->{session}{quota};
        my $entitlement = $quota->{entitlement} || 0;
        my $used = $quota->{used} || 0;
        my $available = $quota->{available} || 0;
        
        if ($entitlement > 0) {
            printf "  %-25s %s of %s\n", 
                "Premium Quota Status:", 
                $self->colorize("$used used", 'DATA'),
                $self->colorize("$entitlement total", 'DATA');
        }
    }
    
    printf "  %-25s %s\n", "Total Tokens:", $self->colorize($billing->{total_tokens}, 'DATA');
    printf "  %-25s %s tokens\n", "  - Prompt:", $billing->{total_prompt_tokens};
    printf "  %-25s %s tokens\n", "  - Completion:", $billing->{total_completion_tokens};
    print "\n";
    
    # Premium usage warning if applicable
    if ($multiplier > 0) {
        # Format multiplier for warning message
        my $mult_display;
        if ($multiplier == int($multiplier)) {
            $mult_display = sprintf("%dx", $multiplier);
        } else {
            $mult_display = sprintf("%.2fx", $multiplier);
            $mult_display =~ s/\.?0+x$/x/;  # Strip trailing zeros
        }
        
        print $self->colorize("⚠️  Premium Model Usage:", 'LABEL'), "\n";
        printf "  This model has a %s billing multiplier.\n", 
            $self->colorize($mult_display, 'DATA');
        print "  Excessive use may impact your GitHub Copilot subscription.\n";
        print "\n";
    }
    
    # Recent requests with multipliers
    if ($billing->{requests} && @{$billing->{requests}}) {
        my @recent = @{$billing->{requests}};
        if (@recent > 10) {
            @recent = @recent[-10..-1];  # Last 10 requests
        }
        
        if (@recent) {
            print $self->colorize("Recent Requests:", 'LABEL'), "\n";
            print $self->colorize(sprintf("  %-5s %-25s %-12s %-12s", 
                "#", "Model", "Tokens", "Rate"), 'LABEL'), "\n";
            
            my $count = 1;
            for my $req (@recent) {
                my $req_model = $req->{model} || 'unknown';
                my $req_multiplier = $req->{multiplier} || 0;
                
                # Format rate string with decimals for fractional multipliers
                my $rate_str;
                if ($req_multiplier == 0) {
                    $rate_str = "Free (0x)";
                } elsif ($req_multiplier == int($req_multiplier)) {
                    $rate_str = sprintf("%dx", $req_multiplier);
                } else {
                    $rate_str = sprintf("%.2fx", $req_multiplier);
                    $rate_str =~ s/\.?0+x$/x/;  # Strip trailing zeros
                }
                
                # Truncate model name if too long
                $req_model = substr($req_model, 0, 23) . "..." if length($req_model) > 25;
                
                printf "  %-5s %-25s %-12s %-12s\n",
                    $count,
                    $req_model,
                    $req->{total_tokens},
                    $rate_str;
                $count++;
            }
            print "\n";
        }
    }
    
    print $self->colorize("═" x 70, 'DATA'), "\n";
    print "\n";
    print $self->colorize("Note: GitHub Copilot uses subscription-based billing.", 'SYSTEM'), "\n";
    print $self->colorize("      Multipliers indicate premium model usage relative to free models.", 'SYSTEM'), "\n";
    print "\n";
}

=head2 handle_models_command

Display available models from configured API endpoint

=cut

sub handle_models_command {
    my ($self, @args) = @_;
    
    # Get provider type
    my $provider = $self->{config}->get('provider') || '';
    my $api_base = $self->{config}->get('api_base');
    
    # For GitHub Copilot, use GitHubCopilotModelsAPI (handles caching, billing, etc.)
    if ($provider eq 'github_copilot' || $api_base =~ /githubcopilot\.com/) {
        print STDERR "[DEBUG][Chat] Using GitHubCopilotModelsAPI for /models\n" if should_log('DEBUG');
        
        eval {
            require CLIO::Core::GitHubCopilotModelsAPI;
            my $models_api = CLIO::Core::GitHubCopilotModelsAPI->new(debug => $self->{debug});
            my $data = $models_api->fetch_models();
            
            unless ($data) {
                $self->display_error_message("Failed to fetch models from GitHub Copilot API");
                return;
            }
            
            my $models = $data->{data} || [];
            
            unless (@$models) {
                $self->display_error_message("No models returned from API");
                return;
            }
            
            # Display models using existing display logic
            $self->_display_models_list($models, 'https://api.githubcopilot.com');
        };
        
        if ($@) {
            $self->display_error_message("Error using GitHubCopilotModelsAPI: $@");
        }
        
        return;
    }
    
    # For other providers, use generic API call
    my $api_key = $self->{config}->get('api_key');
    
    unless ($api_key) {
        $self->display_error_message("API key not set");
        $self->display_system_message("Use /api key <value> to set API key");
        return;
    }
    
    # Determine API type and models endpoint
    my ($api_type, $models_url) = $self->_detect_api_type($api_base);
    
    unless ($models_url) {
        $self->display_error_message("Unable to determine models endpoint for: $api_base");
        return;
    }
    
    print STDERR "[DEBUG][Chat] Querying models from $models_url (type: $api_type)\n" if should_log('DEBUG');
    
    # Fetch models
    my $ua = CLIO::Compat::HTTP->new(timeout => 30);
    my %headers = ('Authorization' => "Bearer $api_key");
    my $resp = $ua->get($models_url, headers => \%headers);
    
    unless ($resp->is_success) {
        $self->display_error_message("Failed to fetch models: " . $resp->code . " " . $resp->message);
        print STDERR "[ERROR][Chat] Response: " . $resp->decoded_content . "\n" if $self->{debug};
        return;
    }
    
    my $data = eval { JSON::PP::decode_json($resp->decoded_content) };
    if ($@) {
        $self->display_error_message("Failed to parse models response: $@");
        return;
    }
    
    my $models = $data->{data} || [];
    
    unless (@$models) {
        $self->display_error_message("No models returned from API");
        return;
    }
    
    # Display models using extracted method
    $self->_display_models_list($models, $api_base);
}

=head2 _display_models_list

Internal method to display models list with billing categorization.
Extracted for reuse between GitHubCopilotModelsAPI and generic API paths.

=cut

sub _display_models_list {
    my ($self, $models, $api_base) = @_;
    
    # Categorize models by billing (if available)
    my @free_models;
    my @premium_models;
    my @unknown_models;
    
    for my $model (@$models) {
        # Check if billing info is available
        # Support two formats:
        # 1. GitHub Copilot: $model->{billing}{is_premium}
        # 2. SAM: $model->{is_premium}
        my $is_premium = undef;
        
        if (exists $model->{billing} && defined $model->{billing}{is_premium}) {
            # GitHub Copilot format
            $is_premium = $model->{billing}{is_premium};
        } elsif (exists $model->{is_premium}) {
            # SAM format
            $is_premium = $model->{is_premium};
        }
        
        if (defined $is_premium) {
            if ($is_premium) {
                push @premium_models, $model;
            } else {
                push @free_models, $model;
            }
        } else {
            # No billing info - put in unknown category
            push @unknown_models, $model;
        }
    }
    
    # Sort alphabetically within each tier
    @free_models = sort { $a->{id} cmp $b->{id} } @free_models;
    @premium_models = sort { $a->{id} cmp $b->{id} } @premium_models;
    @unknown_models = sort { $a->{id} cmp $b->{id} } @unknown_models;
    
    # Determine if we have billing info
    my $has_billing = (@free_models || @premium_models);
    
    # Reset pagination state for writeline
    $self->refresh_terminal_size();
    $self->{line_count} = 0;
    $self->{pages} = [];
    $self->{current_page} = [];
    $self->{page_index} = 0;
    
    # Build display lines
    my @lines;
    
    # Header
    push @lines, "";
    push @lines, "=" x 80;
    push @lines, $self->colorize("AVAILABLE MODELS", 'DATA') . " (" . $self->colorize($api_base, 'THEME') . ")";
    push @lines, "=" x 80;
    push @lines, "";
    
    # Column headers
    if ($has_billing) {
        my $header = sprintf("  %-64s %12s", "Model", "Rate");
        push @lines, $self->colorize($header, 'THEME');
        push @lines, sprintf("  %-64s %12s", "-" x 64, "-" x 12);
    } else {
        my $header = sprintf("  %-70s", "Model");
        push @lines, $self->colorize($header, 'THEME');
        push @lines, sprintf("  %-70s", "-" x 70);
    }
    
    # Free models section
    if (@free_models) {
        push @lines, "";
        push @lines, $self->colorize("FREE MODELS", 'THEME');
        for my $model (@free_models) {
            push @lines, "  " . $self->_format_model_for_display($model, $has_billing);
        }
    }
    
    # Premium models section
    if (@premium_models) {
        push @lines, "";
        push @lines, $self->colorize("PREMIUM MODELS", 'THEME');
        for my $model (@premium_models) {
            push @lines, "  " . $self->_format_model_for_display($model, $has_billing);
        }
    }
    
    # Unknown/other models section
    if (@unknown_models) {
        push @lines, "";
        push @lines, $self->colorize($has_billing ? 'OTHER MODELS' : 'ALL MODELS', 'THEME');
        for my $model (@unknown_models) {
            push @lines, "  " . $self->_format_model_for_display($model, $has_billing);
        }
    }
    
    # Footer
    push @lines, "";
    push @lines, "=" x 80;
    push @lines, sprintf("Total: %d models available", scalar(@$models));
    
    # Footer notes
    if ($has_billing) {
        push @lines, "";
        push @lines, $self->colorize("Note: Subscription-based billing", 'SYSTEM');
        push @lines, "      " . $self->colorize("FREE = Included in subscription", 'SYSTEM');
        push @lines, "      " . $self->colorize("1x/3x/10x = Premium multiplier on usage", 'SYSTEM');
    }
    push @lines, "";
    
    # Output with automatic pagination via writeline
    for my $line (@lines) {
        last unless $self->writeline($line);
    }
}

=head2 _format_model_for_display

Format a model for display (used by both paginated and non-paginated views)

=cut

sub _format_model_for_display {
    my ($self, $model, $has_billing) = @_;
    
    my $name = $model->{id} || 'Unknown';
    
    # Truncate long model names with ellipsis
    my $max_name_length = $has_billing ? 62 : 68;  # Leave room for rate column if present
    if (length($name) > $max_name_length) {
        $name = substr($name, 0, $max_name_length - 3) . "...";
    }
    
    if ($has_billing) {
        my $billing_rate = '-';
        
        # Support both GitHub Copilot and SAM billing formats
        # CORRECT: GitHub Copilot uses multiplier, not rate
        if ($model->{billing} && defined $model->{billing}{multiplier}) {
            # GitHub Copilot format: $model->{billing}{multiplier}
            my $mult = $model->{billing}{multiplier};
            
            # Format multiplier nicely
            if ($mult == 0) {
                $billing_rate = 'FREE';
            } elsif ($mult == int($mult)) {
                # Integer multiplier (1, 3, 10)
                $billing_rate = int($mult) . 'x';
            } else {
                # Fractional multiplier (0.33)
                $billing_rate = sprintf("%.2fx", $mult);
            }
        } elsif (defined $model->{premium_multiplier}) {
            # SAM format: $model->{premium_multiplier}
            my $mult = $model->{premium_multiplier};
            if ($mult == 0) {
                $billing_rate = 'FREE';
            } elsif ($mult == int($mult)) {
                $billing_rate = int($mult) . 'x';
            } else {
                $billing_rate = sprintf("%.2fx", $mult);
            }
        }
        
        # Apply color to name
        my $colored_name = $self->colorize($name, 'USER');
        
        # Calculate padding needed (colorize adds invisible ANSI codes)
        my $name_display_width = length($name);
        my $padding = 64 - $name_display_width;
        my $spaces = $padding > 0 ? (' ' x $padding) : '';
        
        return sprintf("%s%s %12s",
            $colored_name,
            $spaces,
            $billing_rate);
    } else {
        # Apply color to name
        my $colored_name = $self->colorize($name, 'USER');
        
        # Calculate padding needed (colorize adds invisible ANSI codes)
        my $name_display_width = length($name);
        my $padding = 70 - $name_display_width;
        my $spaces = $padding > 0 ? (' ' x $padding) : '';
        
        return sprintf("%s%s",
            $colored_name,
            $spaces);
    }
}

=head2 _format_number

Format number with commas for thousands

=cut

sub _format_number {
    my ($self, $num) = @_;
    my $text = reverse $num;
    $text =~ s/(\d{3})(?=\d)/$1,/g;
    return scalar reverse $text;
}

=head2 _detect_api_type

Detect API type and models endpoint from base URL

=cut

sub _detect_api_type {
    my ($self, $api_base) = @_;
    
    # Map of logical names to (type, models_url)
    my %api_configs = (
        'github-copilot' => ['github-copilot', 'https://api.githubcopilot.com/models'],
        'openai'         => ['openai', 'https://api.openai.com/v1/models'],
        'dashscope-cn'   => ['dashscope', 'https://dashscope.aliyuncs.com/compatible-mode/v1/models'],
        'dashscope-intl' => ['dashscope', 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models'],
        'sam'            => ['sam', 'http://localhost:8080/v1/models'],
    );
    
    # Check if it's a known logical name
    if (exists $api_configs{$api_base}) {
        return @{$api_configs{$api_base}};
    }
    
    # Try to detect from URL pattern
    if ($api_base =~ m{githubcopilot\.com}i) {
        return ('github-copilot', 'https://api.githubcopilot.com/models');
    } elsif ($api_base =~ m{openai\.com}i) {
        return ('openai', 'https://api.openai.com/v1/models');
    } elsif ($api_base =~ m{dashscope.*\.aliyuncs\.com}i) {
        # Extract base URL and append /models
        my $base_url = $api_base;
        $base_url =~ s{/+$}{};  # Remove trailing slashes
        $base_url =~ s{/compatible-mode/v1.*$}{};  # Remove path if present
        return ('dashscope', "$base_url/compatible-mode/v1/models");
    } elsif ($api_base =~ m{localhost:8080}i) {
        # SAM running on localhost:8080
        return ('sam', 'http://localhost:8080/v1/models');
    }
    
    # Generic OpenAI-compatible API - try appending /models
    if ($api_base =~ m{^https?://}) {
        my $models_url = $api_base;
        $models_url =~ s{/+$}{};  # Remove trailing slashes
        
        # If URL ends with /chat/completions, replace with /models
        if ($models_url =~ m{/chat/completions$}) {
            $models_url =~ s{/chat/completions$}{/models};
        }
        # If it already ends with /v1, append /models
        elsif ($models_url =~ m{/v1$}) {
            $models_url .= "/models";
        } elsif ($models_url !~ m{/models$}) {
            $models_url .= "/models";
        }
        
        return ('generic', $models_url);
    }
    
    return (undef, undef);
}

=head2 _display_model_row

Internal helper to display a single model row

=cut

sub _format_tokens {
    my ($self, $count) = @_;
    
    return "Unknown" unless defined $count;
    
    if ($count >= 1000000) {
        return sprintf("%.1fM tokens", $count / 1000000);
    } elsif ($count >= 1000) {
        return sprintf("%.0fK tokens", $count / 1000);
    } else {
        return sprintf("%d tokens", $count);
    }
}

=head2 handle_context_command

Manage context files for the conversation.
Subcommands: add, list, clear, remove

=cut

sub handle_context_command {
    my ($self, @args) = @_;
    
    my $action = shift @args || 'list';
    
    # Initialize context files in session if not present
    unless ($self->{session}{context_files}) {
        $self->{session}{context_files} = [];
    }
    
    if ($action eq 'add') {
        my $file = join(' ', @args);
        unless ($file) {
            $self->display_error_message("Usage: /context add <file>");
            return;
        }
        
        # Resolve relative paths
        unless ($file =~ m{^/}) {
            $file = "$ENV{PWD}/$file";
        }
        
        unless (-f $file) {
            $self->display_error_message("File not found: $file");
            return;
        }
        
        # Check if already in context
        if (grep { $_ eq $file } @{$self->{session}{context_files}}) {
            $self->display_system_message("File already in context: $file");
            return;
        }
        
        # Read file content
        open my $fh, '<', $file or do {
            $self->display_error_message("Cannot read file: $!");
            return;
        };
        my $content = do { local $/; <$fh> };
        close $fh;
        
        # Estimate token count (char / 4)
        my $tokens = int(length($content) / 4);
        
        # Add to context
        push @{$self->{session}{context_files}}, $file;
        
        # Save session to persist context
        if ($self->{session}) {
            $self->{session}->save();
        }
        
        $self->display_system_message(
            sprintf("Added to context: %s (~%s)",
                $file,
                $self->_format_tokens($tokens))
        );
        
    } elsif ($action eq 'list' || $action eq 'ls') {
        my @files = @{$self->{session}{context_files}};
        
        print "\n";
        print "=" x 80, "\n";
        print $self->colorize("CONVERSATION MEMORY", 'DATA'), "\n";
        print "=" x 80, "\n";
        
        # Show conversation memory stats
        if ($self->{session} && $self->{session}{state}) {
            my $state = $self->{session}{state};
            my $history = $state->get_history();
            my $yarn = $state->yarn();
            
            # Calculate stats
            my $active_messages = scalar(@$history);
            my $active_tokens = $state->get_conversation_size();
            my $max_tokens = $state->{max_tokens} || 128000;
            my $threshold = $state->{summarize_threshold} || 102400;
            my $usage_pct = sprintf("%.1f%%", ($active_tokens / $max_tokens) * 100);
            
            # Get YaRN stats
            my $thread_id = $state->{session_id};
            my $yarn_thread = $yarn->get_thread($thread_id);
            my $yarn_messages = ref $yarn_thread eq 'ARRAY' ? scalar(@$yarn_thread) : 0;
            my $yarn_tokens = 0;
            if (ref $yarn_thread eq 'ARRAY') {
                use CLIO::Memory::TokenEstimator;
                for my $msg (@$yarn_thread) {
                    $yarn_tokens += CLIO::Memory::TokenEstimator::estimate_tokens($msg->{content} // '');
                }
            }
            
            my $archived_messages = $yarn_messages > $active_messages ? $yarn_messages - $active_messages : 0;
            my $archived_tokens = $yarn_tokens > $active_tokens ? $yarn_tokens - $active_tokens : 0;
            
            # Determine status
            my $status;
            if ($active_tokens > $threshold) {
                $status = $self->colorize("⚠️  TRIMMING ACTIVE (over 80%)", 'WARN');
            } elsif ($active_tokens > $threshold * 0.6) {
                $status = $self->colorize("⚡ Approaching limit (60-80%)", 'THEME');
            } else {
                $status = $self->colorize("✅ Healthy (below 60%)", 'SUCCESS');
            }
            
            printf "\n%-24s %d messages (~%s)\n",
                "Active Messages:",
                $active_messages,
                $self->_format_tokens($active_tokens);
            
            if ($archived_messages > 0) {
                printf "%-24s %d messages (~%s)\n",
                    "Archived (YaRN):",
                    $archived_messages,
                    $self->_format_tokens($archived_tokens);
            }
            
            printf "%-24s %s / %s (%s)\n",
                "Context Usage:",
                $self->_format_tokens($active_tokens),
                $self->_format_tokens($max_tokens),
                $usage_pct;
            
            printf "%-24s %s\n", "Status:", $status;
            
            if ($archived_messages > 0) {
                print "\n";
                print $self->colorize("YaRN Recall Available", 'DATA'), 
                      " - Use [RECALL:query=<search>] to search archived history\n";
            }
            
            print "\n";
            print "=" x 80, "\n";
            print $self->colorize("CONTEXT FILES", 'DATA'), "\n";
            print "=" x 80, "\n";
        }
        
        unless (@files) {
            print "\nNo files in context\n";
            print "\n";
            return;
        }
        
        print "\n";
        
        my $total_tokens = 0;
        for my $i (0 .. $#files) {
            my $file = $files[$i];
            my $tokens = 0;
            
            if (-f $file) {
                open my $fh, '<', $file;
                my $content = do { local $/; <$fh> };
                close $fh;
                $tokens = int(length($content) / 4);
                $total_tokens += $tokens;
            }
            
            printf "%2d. %-60s %s\n",
                $i + 1,
                $file,
                $self->colorize($self->_format_tokens($tokens), 'THEME');
        }
        
        print "\n";
        print "-" x 80, "\n";
        printf "Total: %d files, ~%s\n",
            scalar(@files),
            $self->_format_tokens($total_tokens);
        print "\n";
        
    } elsif ($action eq 'clear') {
        my $count = scalar(@{$self->{session}{context_files}});
        $self->{session}{context_files} = [];
        
        # Save session to persist change
        if ($self->{session}) {
            $self->{session}->save();
        }
        
        $self->display_system_message("Cleared $count file(s) from context");
        
    } elsif ($action eq 'remove' || $action eq 'rm') {
        my $arg = join(' ', @args);
        
        unless ($arg) {
            $self->display_error_message("Usage: /context remove <file|index>");
            return;
        }
        
        my $removed = undef;
        
        # Check if it's a numeric index
        if ($arg =~ /^\d+$/) {
            my $index = $arg - 1;  # Convert to 0-based
            
            if ($index >= 0 && $index < @{$self->{session}{context_files}}) {
                $removed = splice(@{$self->{session}{context_files}}, $index, 1);
            } else {
                $self->display_error_message("Invalid index: $arg");
                return;
            }
        } else {
            # Try to match by filename
            my @new_files = ();
            for my $file (@{$self->{session}{context_files}}) {
                if ($file eq $arg || $file =~ /\Q$arg\E$/) {
                    $removed = $file;
                } else {
                    push @new_files, $file;
                }
            }
            $self->{session}{context_files} = \@new_files;
        }
        
        if ($removed) {
            # Save session to persist change
            if ($self->{session}) {
                $self->{session}->save();
            }
            
            $self->display_system_message("Removed from context: $removed");
        } else {
            $self->display_error_message("File not found in context: $arg");
        }
        
    } else {
        $self->display_error_message("Unknown action: $action");
        print "\n";
        print "Usage:\n";
        print "  /context add <file>      - Add file to context\n";
        print "  /context list            - List all context files\n";
        print "  /context remove <file|#> - Remove file from context\n";
        print "  /context clear           - Clear all context files\n";
    }
}

=head2 handle_explain_command

Explain code functionality (optionally for a specific file)

=cut

sub handle_explain_command {
    my ($self, @args) = @_;
    
    my $file = join(' ', @args);
    my $code_content = "";
    
    if ($file) {
        # Resolve relative path
        unless ($file =~ m{^/}) {
            $file = "$ENV{PWD}/$file";
        }
        
        unless (-f $file) {
            $self->display_error_message("File not found: $file");
            return;
        }
        
        # Read file content
        open my $fh, '<', $file or do {
            $self->display_error_message("Cannot read file: $!");
            return;
        };
        $code_content = do { local $/; <$fh> };
        close $fh;
        
        # Build prompt with code
        my $prompt = "Please explain the following code from $file:\n\n```\n$code_content\n```\n\n" .
                    "Provide a clear explanation of:\n" .
                    "1. What this code does (high-level overview)\n" .
                    "2. Key components and their purpose\n" .
                    "3. How the different parts work together\n" .
                    "4. Any notable patterns or techniques used";
        
        # Display info message
        $self->display_system_message("Explaining code from: $file");
        print "\n";
        
        # Send to AI (this will be handled by the chat loop)
        return $prompt;
    } else {
        # No file specified - explain current conversation context
        my $prompt = "Please explain the code we've been discussing. " .
                    "Provide a clear explanation of what it does, key components, and how it works.";
        
        return $prompt;
    }
}

=head2 handle_review_command

Review code for potential issues

=cut

sub handle_review_command {
    my ($self, @args) = @_;
    
    my $file = join(' ', @args);
    my $code_content = "";
    
    if ($file) {
        # Resolve relative path
        unless ($file =~ m{^/}) {
            $file = "$ENV{PWD}/$file";
        }
        
        unless (-f $file) {
            $self->display_error_message("File not found: $file");
            return;
        }
        
        # Read file content
        open my $fh, '<', $file or do {
            $self->display_error_message("Cannot read file: $!");
            return;
        };
        $code_content = do { local $/; <$fh> };
        close $fh;
        
        # Build prompt with code
        my $prompt = "Please review the following code from $file:\n\n```\n$code_content\n```\n\n" .
                    "Conduct a thorough code review focusing on:\n" .
                    "1. Potential bugs or logic errors\n" .
                    "2. Security vulnerabilities\n" .
                    "3. Performance issues\n" .
                    "4. Code quality and best practices\n" .
                    "5. Edge cases that might not be handled\n" .
                    "6. Suggestions for improvement\n\n" .
                    "Be specific and provide examples where possible.";
        
        # Display info message
        $self->display_system_message("Reviewing code from: $file");
        print "\n";
        
        # Send to AI
        return $prompt;
    } else {
        # No file specified - review current conversation context
        my $prompt = "Please review the code we've been discussing. " .
                    "Look for potential bugs, security issues, performance problems, " .
                    "and opportunities for improvement.";
        
        return $prompt;
    }
}

=head2 handle_test_command

Generate tests for code

=cut

sub handle_test_command {
    my ($self, @args) = @_;
    
    my $file = join(' ', @args);
    my $code_content = "";
    
    if ($file) {
        # Resolve relative path
        unless ($file =~ m{^/}) {
            $file = "$ENV{PWD}/$file";
        }
        
        unless (-f $file) {
            $self->display_error_message("File not found: $file");
            return;
        }
        
        # Read file content
        open my $fh, '<', $file or do {
            $self->display_error_message("Cannot read file: $!");
            return;
        };
        $code_content = do { local $/; <$fh> };
        close $fh;
        
        # Detect file type for appropriate test framework
        my $test_framework = "appropriate test framework";
        if ($file =~ /\.pm$/) {
            $test_framework = "Test::More or Test2::Suite";
        } elsif ($file =~ /\.pl$/) {
            $test_framework = "Test::More or prove";
        } elsif ($file =~ /\.py$/) {
            $test_framework = "pytest or unittest";
        } elsif ($file =~ /\.js$/) {
            $test_framework = "Jest or Mocha";
        } elsif ($file =~ /\.ts$/) {
            $test_framework = "Jest or Vitest";
        }
        
        # Build prompt with code
        my $prompt = "Please generate comprehensive tests for the following code from $file:\n\n```\n$code_content\n```\n\n" .
                    "Generate tests using $test_framework that cover:\n" .
                    "1. Normal/happy path scenarios\n" .
                    "2. Edge cases and boundary conditions\n" .
                    "3. Error handling and failure modes\n" .
                    "4. Different input variations\n" .
                    "5. Integration points (if applicable)\n\n" .
                    "Provide complete, runnable test code with clear descriptions.";
        
        # Display info message
        $self->display_system_message("Generating tests for: $file");
        print "\n";
        
        # Send to AI
        return $prompt;
    } else {
        # No file specified - generate tests for current conversation context
        my $prompt = "Please generate comprehensive tests for the code we've been discussing. " .
                    "Include normal cases, edge cases, error handling, and clear test descriptions.";
        
        return $prompt;
    }
}

=head2 handle_status_command

Show git status

=cut

sub handle_status_command {
    my ($self, @args) = @_;
    
    my $output = `git status 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Git error: $output");
        return;
    }
    
    print "\n";
    print "=" x 80, "\n";
    print $self->colorize("GIT STATUS", 'DATA'), "\n";
    print "=" x 80, "\n";
    print "\n";
    print $output;
    print "\n";
}

=head2 handle_diff_command

Show git diff

=cut

sub handle_diff_command {
    my ($self, @args) = @_;
    
    my $file = join(' ', @args) || '';
    my $cmd = $file ? "git diff -- '$file'" : "git diff";
    
    my $output = `$cmd 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Git error: $output");
        return;
    }
    
    unless ($output) {
        $self->display_system_message("No changes to display");
        return;
    }
    
    print "\n";
    print "=" x 80, "\n";
    print $self->colorize("GIT DIFF" . ($file ? " - $file" : ""), 'DATA'), "\n";
    print "=" x 80, "\n";
    print "\n";
    print $output;
    print "\n";
}

=head2 handle_log_command

Show recent git commits

=cut

sub handle_gitlog_command {
    my ($self, @args) = @_;
    
    my $count = $args[0] || 10;
    
    # Validate count is a number
    unless ($count =~ /^\d+$/) {
        $self->display_error_message("Invalid count: $count (must be a number)");
        return;
    }
    
    my $output = `git log --oneline -$count 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Git error: $output");
        return;
    }
    
    print "\n";
    print "=" x 80, "\n";
    print $self->colorize("GIT LOG (last $count commits)", 'DATA'), "\n";
    print "=" x 80, "\n";
    print "\n";
    print $output;
    print "\n";
}

sub handle_log_command {
    my ($self, @args) = @_;
    
    # Initialize ToolLogger
    unless ($self->{tool_logger}) {
        require CLIO::Logging::ToolLogger;
        my $session_id = $self->{session} ? $self->{session}->{session_id} : 'unknown';
        $self->{tool_logger} = CLIO::Logging::ToolLogger->new(
            session_id => $session_id,
            debug => $self->{debug}
        );
    }
    
    my $subcommand = $args[0] || '';
    
    # /log filter <tool>
    if ($subcommand eq 'filter' && $args[1]) {
        $self->display_tool_log_filter($args[1]);
    }
    # /log search <pattern>
    elsif ($subcommand eq 'search' && $args[1]) {
        $self->display_tool_log_search(join(' ', @args[1..$#args]));
    }
    # /log session
    elsif ($subcommand eq 'session') {
        $self->display_tool_log_session();
    }
    # /log [n] - show last n operations
    else {
        my $count = 20;  # default
        if ($subcommand =~ /^\d+$/) {
            $count = $subcommand;
        }
        $self->display_tool_log_recent($count);
    }
}

=head2 display_tool_log_recent

Display recent tool operations

=cut

sub display_tool_log_recent {
    my ($self, $count) = @_;
    
    my $entries = $self->{tool_logger}->get_recent($count);
    
    unless ($entries && @$entries) {
        $self->display_system_message("No tool operations logged yet");
        return;
    }
    
    print "\n";
    print "=" x 80, "\n";
    print $self->colorize("TOOL OPERATIONS (last $count)", 'DATA'), "\n";
    print "=" x 80, "\n";
    
    for my $entry (@$entries) {
        $self->_display_tool_log_entry($entry);
    }
}

=head2 display_tool_log_filter

Display tool operations filtered by tool name

=cut

sub display_tool_log_filter {
    my ($self, $tool_name) = @_;
    
    my $entries = $self->{tool_logger}->filter(tool => $tool_name);
    
    unless ($entries && @$entries) {
        $self->display_system_message("No operations found for tool: $tool_name");
        return;
    }
    
    print "\n";
    print "=" x 80, "\n";
    print $self->colorize("TOOL OPERATIONS - $tool_name (" . scalar(@$entries) . " found)", 'DATA'), "\n";
    print "=" x 80, "\n";
    
    # Show most recent first
    for my $entry (reverse @$entries) {
        $self->_display_tool_log_entry($entry);
    }
}

=head2 display_tool_log_search

Search tool operations

=cut

sub display_tool_log_search {
    my ($self, $pattern) = @_;
    
    my $entries = $self->{tool_logger}->search($pattern);
    
    unless ($entries && @$entries) {
        $self->display_system_message("No operations found matching: $pattern");
        return;
    }
    
    print "\n";
    print "=" x 80, "\n";
    print $self->colorize("TOOL OPERATIONS - search '$pattern' (" . scalar(@$entries) . " found)", 'DATA'), "\n";
    print "=" x 80, "\n";
    
    # Show most recent first
    for my $entry (reverse @$entries) {
        $self->_display_tool_log_entry($entry);
    }
}

=head2 display_tool_log_session

Display tool operations for current session

=cut

sub display_tool_log_session {
    my ($self) = @_;
    
    my $session_id = $self->{session} ? $self->{session}->{session_id} : 'unknown';
    my $entries = $self->{tool_logger}->filter(session => $session_id);
    
    unless ($entries && @$entries) {
        $self->display_system_message("No operations in current session");
        return;
    }
    
    print "\n";
    print "=" x 80, "\n";
    print $self->colorize("TOOL OPERATIONS - session $session_id (" . scalar(@$entries) . " ops)", 'DATA'), "\n";
    print "=" x 80, "\n";
    
    # Show most recent first
    for my $entry (reverse @$entries) {
        $self->_display_tool_log_entry($entry);
    }
}

=head2 _display_tool_log_entry

Display a single tool log entry (internal helper)

=cut

sub _display_tool_log_entry {
    my ($self, $entry) = @_;
    
    print "\n";
    
    # Header line with timestamp and tool
    my $status_icon = $entry->{success} ? '✓' : '✗';
    my $status_color = $entry->{success} ? 'SUCCESS' : 'ERROR';
    
    print $self->colorize("[$entry->{timestamp}] ", 'DIM');
    print $self->colorize("$status_icon ", $status_color);
    print $self->colorize("$entry->{tool_name}", 'TOOL');
    if ($entry->{operation}) {
        print $self->colorize("/$entry->{operation}", 'PROMPT');
    }
    print "\n";
    
    # Action description
    if ($entry->{action_description}) {
        print "  ", $self->colorize($entry->{action_description}, 'DATA'), "\n";
    }
    
    # Parameters (compact JSON)
    if ($entry->{parameters} && ref($entry->{parameters}) eq 'HASH') {
        use JSON::PP;
        my $params_json = JSON::PP->new->canonical->encode($entry->{parameters});
        # Truncate if too long
        if (length($params_json) > 100) {
            $params_json = substr($params_json, 0, 97) . "...";
        }
        print "  ", $self->colorize("Params: ", 'DIM'), $params_json, "\n";
    }
    
    # Execution time
    if ($entry->{execution_time_ms}) {
        print "  ", $self->colorize("Time: ", 'DIM'), "$entry->{execution_time_ms}ms\n";
    }
    
    # Error message if failed
    if (!$entry->{success} && $entry->{error}) {
        print "  ", $self->colorize("Error: ", 'ERROR'), $entry->{error}, "\n";
    }
}

=head2 handle_commit_command

Stage all changes and commit with message

=cut

sub handle_commit_command {
    my ($self, @args) = @_;
    
    # Check if there are changes to commit
    my $status = `git status --porcelain 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Git error: $status");
        return;
    }
    
    unless ($status) {
        $self->display_system_message("No changes to commit");
        return;
    }
    
    my $message = join(' ', @args);
    
    # If no message provided, prompt for one
    unless ($message) {
        print "\n";
        print $self->colorize("Enter commit message (empty to cancel):", 'PROMPT'), "\n";
        print "> ";
        $message = <STDIN>;
        chomp $message if defined $message;
        
        unless ($message && length($message) > 0) {
            $self->display_system_message("Commit cancelled");
            return;
        }
    }
    
    # Stage all changes
    my $add_output = `git add -A 2>&1`;
    $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Failed to stage changes: $add_output");
        return;
    }
    
    # Commit
    my $commit_output = `git commit -m '$message' 2>&1`;
    $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Commit failed: $commit_output");
        return;
    }
    
    print "\n";
    print "=" x 80, "\n";
    print $self->colorize("GIT COMMIT", 'DATA'), "\n";
    print "=" x 80, "\n";
    print "\n";
    print $commit_output;
    print "\n";
    
    $self->display_system_message("Changes committed successfully");
}

=head2 handle_exec_command

Execute shell commands without leaving the application

=cut

sub handle_exec_command {
    my ($self, @args) = @_;
    
    unless (@args) {
        $self->display_error_message("Usage: /exec <command>");
        return;
    }
    
    my $command = join(' ', @args);
    
    print $self->colorize("Executing: ", 'SYSTEM'), $command, "\n";
    print "\n";
    
    # Execute command and capture output
    my $output = `$command 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($output) {
        print $output;
        if ($output !~ /\n$/) {
            print "\n";
        }
    }
    
    print "\n";
    if ($exit_code == 0) {
        print $self->colorize("Command exited with code 0", 'SYSTEM'), "\n";
    } else {
        print $self->colorize("Command exited with code $exit_code", 'ERROR'), "\n";
    }
}

=head2 handle_switch_command

Switch to a different session

=cut

sub handle_switch_command {
    my ($self, @args) = @_;
    
    # List available sessions
    my $sessions_dir = '.clio/sessions';
    unless (-d $sessions_dir) {
        $self->display_error_message("Sessions directory not found");
        return;
    }
    
    opendir(my $dh, $sessions_dir) or do {
        $self->display_error_message("Cannot read sessions directory: $!");
        return;
    };
    
    my @sessions = grep { /\.json$/ && -f "$sessions_dir/$_" } readdir($dh);
    closedir($dh);
    
    unless (@sessions) {
        $self->display_system_message("No other sessions available");
        return;
    }
    
    # Display sessions
    print "\n";
    $self->display_system_message("Available sessions:");
    for my $i (0..$#sessions) {
        my $session_file = $sessions[$i];
        $session_file =~ s/\.json$//;
        my $current = ($self->{session} && $self->{session}->{session_id} eq $session_file) ? " (current)" : "";
        printf "  %d) %s%s\n", $i + 1, $session_file, $current;
    }
    
    $self->display_system_message("Session switching not yet fully implemented");
    $self->display_system_message("Use --resume <session_id> to switch sessions");
}

=head2 handle_read_command

Handle /read <file> command - Read and display a file with markdown rendering,
color processing, and pagination.

Arguments:
  @args - Filename to read (can contain spaces)

Features:
  - Automatically detects markdown files (.md extension)
  - Renders markdown with headers, lists, code blocks, etc.
  - Processes @-codes for color output
  - Paginates long content with keyboard navigation

=cut

sub handle_read_command {
    my ($self, @args) = @_;
    
    my $filepath = join(' ', @args);
    
    unless ($filepath) {
        $self->display_error_message("Usage: /read <filename>");
        $self->display_system_message("Reads and displays a file with markdown rendering and pagination.");
        return;
    }
    
    # Resolve path relative to working directory
    unless (File::Spec->file_name_is_absolute($filepath)) {
        my $working_dir = $self->{session} ? 
            ($self->{session}->{working_directory} || '.') : '.';
        $filepath = File::Spec->catfile($working_dir, $filepath);
    }
    
    # Check if file exists
    unless (-f $filepath) {
        $self->display_error_message("File not found: $filepath");
        return;
    }
    
    # Check if file is readable
    unless (-r $filepath) {
        $self->display_error_message("Cannot read file: $filepath");
        return;
    }
    
    # Read file content
    my $content;
    eval {
        open my $fh, '<:encoding(UTF-8)', $filepath or die "Cannot open file: $!";
        local $/;  # Slurp mode
        $content = <$fh>;
        close $fh;
    };
    if ($@) {
        $self->display_error_message("Error reading file: $@");
        return;
    }
    
    # Check if it's a markdown file
    my $is_markdown = ($filepath =~ /\.md$/i);
    
    # Process content
    my @lines;
    
    if ($is_markdown && $self->{markdown_renderer}) {
        # Render markdown
        my $rendered = $self->{markdown_renderer}->render($content);
        # Process @-codes
        $rendered = $self->{ansi}->parse($rendered) if $self->{ansi};
        @lines = split /\n/, $rendered, -1;
    } else {
        # Plain text - just process @-codes if present
        if ($self->{ansi} && $content =~ /\@\w+\@/) {
            $content = $self->{ansi}->parse($content);
        }
        @lines = split /\n/, $content, -1;
    }
    
    # Get filename for title
    my $filename = (File::Spec->splitpath($filepath))[2];
    my $title = $is_markdown ? "📄 $filename (Markdown)" : "📄 $filename";
    
    # Display with pagination
    $self->display_paginated_content($title, \@lines, $filepath);
}

=head2 display_paginated_content

Display content with full pagination (line by line).
User can navigate with [N]ext page, [P]revious page, [Q]uit.

Arguments:
- $title: Title to display at top
- $lines: Array ref of lines to display
- $filepath: (optional) File path for info line

Returns: Nothing

=cut

sub display_paginated_content {
    my ($self, $title, $lines, $filepath) = @_;
    
    # Refresh terminal size
    $self->refresh_terminal_size();
    
    # Use terminal height minus headers/footers (around 6 lines)
    my $page_size = ($self->{terminal_height} || 24) - 6;
    $page_size = 10 if $page_size < 10;  # Minimum page size
    
    my $total_lines = scalar @$lines;
    my $total_pages = int(($total_lines + $page_size - 1) / $page_size);
    $total_pages = 1 if $total_pages < 1;
    my $current_page = 0;
    
    # If content fits on one page or not interactive, display all
    my $is_interactive = -t STDIN;
    
    if (!$is_interactive || $total_lines <= $page_size) {
        # Non-paginated display
        print "\n";
        print $self->colorize("═" x 80, 'DIM'), "\n";
        print $self->colorize($title, 'DATA'), "\n";
        print $self->colorize("═" x 80, 'DIM'), "\n";
        print "\n";
        
        for my $line (@$lines) {
            print $line, "\n";
        }
        
        print "\n";
        print $self->colorize("─" x 80, 'DIM'), "\n";
        print $self->colorize("$total_lines lines", 'DIM');
        print $self->colorize(" | $filepath", 'DIM') if $filepath;
        print "\n\n";
        return;
    }
    
    # Put terminal in raw mode for single-key input
    eval { ReadMode('cbreak') };
    
    while (1) {
        # Calculate page bounds
        my $start = $current_page * $page_size;
        my $end = $start + $page_size - 1;
        $end = $total_lines - 1 if $end >= $total_lines;
        
        # Clear screen and display page
        print "\e[2J\e[H";  # Clear screen + home cursor
        
        # Header
        print "\n";
        print $self->colorize("═" x 80, 'DIM'), "\n";
        print $self->colorize($title, 'DATA'), "\n";
        print $self->colorize("═" x 80, 'DIM'), "\n";
        print "\n";
        
        # Display lines for this page
        for my $i ($start .. $end) {
            print $lines->[$i], "\n";
        }
        
        # Footer
        print "\n";
        print $self->colorize("─" x 80, 'DIM'), "\n";
        
        # Status line
        my $status = sprintf("Lines %d-%d of %d (Page %d/%d)", 
            $start + 1, $end + 1, $total_lines, $current_page + 1, $total_pages);
        print $self->colorize($status, 'DIM'), "\n";
        
        # Navigation prompt
        my @nav_options;
        push @nav_options, $self->colorize("[N]ext", 'PROMPT') if $current_page < $total_pages - 1;
        push @nav_options, $self->colorize("[P]revious", 'PROMPT') if $current_page > 0;
        push @nav_options, $self->colorize("[Q]uit", 'PROMPT');
        push @nav_options, $self->colorize("[G]o to line", 'PROMPT');
        
        print join(" | ", @nav_options), ": ";
        
        # Get user input (single key)
        my $key = ReadKey(0);
        
        # Handle navigation
        if ($key =~ /^[nN ]$/ && $current_page < $total_pages - 1) {
            $current_page++;
        }
        elsif ($key =~ /^[pPbB]$/ && $current_page > 0) {
            $current_page--;
        }
        elsif ($key =~ /^[qQ]$/ || ord($key) == 27) {  # q or Escape
            last;
        }
        elsif ($key =~ /^[gG]$/) {
            # Go to specific line
            print "\n";
            ReadMode('restore');
            print "Go to line (1-$total_lines): ";
            my $line_num = <STDIN>;
            chomp $line_num if defined $line_num;
            if ($line_num && $line_num =~ /^\d+$/ && $line_num >= 1 && $line_num <= $total_lines) {
                $current_page = int(($line_num - 1) / $page_size);
            }
            ReadMode('cbreak');
        }
        elsif ($key =~ /^[<]$/ || ord($key) == 2) {  # Home or Ctrl+B
            $current_page = 0;
        }
        elsif ($key =~ /^[>]$/ || ord($key) == 6) {  # End or Ctrl+F
            $current_page = $total_pages - 1;
        }
    }
    
    # Restore terminal mode
    eval { ReadMode('restore') };
    
    # Clear screen and return to normal view
    print "\e[2J\e[H";
    $self->repaint_screen();
}

=head2 handle_skills_command

Handle /skills commands for custom skill management

=cut

sub handle_skills_command {
    my ($self, @args) = @_;
    
    my $action = shift @args || 'list';
    
    # Load SkillManager
    require CLIO::Core::SkillManager;
    my $sm = CLIO::Core::SkillManager->new(
        debug => $self->{debug},
        session_skills_file => $self->{session} ? 
            File::Spec->catfile('sessions', $self->{session}{session_id}, 'skills.json') : 
            undef
    );
    
    if ($action eq 'add') {
        my $name = shift @args;
        my $skill_text = join(' ', @args);
        
        unless ($name && $skill_text) {
            $self->display_error_message("Usage: /skills add <name> \"<skill text>\"");
            return;
        }
        
        # Remove quotes if present
        $skill_text =~ s/^["']//;
        $skill_text =~ s/["']$//;
        
        my $result = $sm->add_skill($name, $skill_text);
        
        if ($result->{success}) {
            $self->display_system_message("Added skill '$name'");
        } else {
            $self->display_error_message($result->{error});
        }
        
    } elsif ($action eq 'list') {
        my $skills = $sm->list_skills();
        
        print "\n";
        print "=" x 80, "\n";
        print "CUSTOM SKILLS\n";
        print "=" x 80, "\n";
        
        if (@{$skills->{custom}}) {
            for my $name (sort @{$skills->{custom}}) {
                my $s = $sm->get_skill($name);
                printf "  %-20s %s\n", $name, $s->{description};
            }
        } else {
            print "  (none)\n";
        }
        
        print "\n";
        print "BUILT-IN SKILLS (read-only)\n";
        print "-" x 80, "\n";
        
        for my $name (sort @{$skills->{builtin}}) {
            my $s = $sm->get_skill($name);
            printf "  %-20s %s\n", $name, $s->{description};
        }
        
        print "\n";
        printf "Total: %d custom, %d built-in\n", 
            scalar(@{$skills->{custom}}),
            scalar(@{$skills->{builtin}});
        print "\n";
        
    } elsif ($action eq 'use' || $action eq 'exec') {
        my $name = shift @args;
        my $file = join(' ', @args);
        
        unless ($name) {
            $self->display_error_message("Usage: /skills use <name> [file]");
            return;
        }
        
        # Build context
        my $context = $self->_build_skill_context($file);
        
        # Execute skill
        my $result = $sm->execute_skill($name, $context);
        
        if ($result->{success}) {
            # Return prompt to be sent to AI
            return (1, $result->{rendered_prompt});
        } else {
            $self->display_error_message($result->{error});
        }
        
    } elsif ($action eq 'show') {
        my $name = shift @args;
        
        unless ($name) {
            $self->display_error_message("Usage: /skills show <name>");
            return;
        }
        
        my $skill = $sm->get_skill($name);
        unless ($skill) {
            $self->display_error_message("Skill '$name' not found");
            return;
        }
        
        print "\n";
        print "=" x 80, "\n";
        print "SKILL: $name\n";
        print "=" x 80, "\n";
        print "\n";
        print $skill->{prompt}, "\n";
        print "\n";
        print "-" x 80, "\n";
        print "Variables: ", join(", ", @{$skill->{variables}}), "\n";
        print "Type: $skill->{type}\n";
        if ($skill->{created}) {
            print "Created: ", scalar(localtime($skill->{created})), "\n";
        }
        if ($skill->{modified}) {
            print "Modified: ", scalar(localtime($skill->{modified})), "\n";
        }
        print "\n";
        
    } elsif ($action eq 'delete' || $action eq 'rm') {
        my $name = shift @args;
        
        unless ($name) {
            $self->display_error_message("Usage: /skills delete <name>");
            return;
        }
        
        # Confirm deletion
        print "Are you sure you want to delete skill '$name'? (yes/no): ";
        my $confirm = <STDIN>;
        chomp $confirm;
        
        unless ($confirm eq 'yes') {
            $self->display_system_message("Deletion cancelled");
            return;
        }
        
        my $result = $sm->delete_skill($name);
        
        if ($result->{success}) {
            $self->display_system_message("Deleted skill '$name'");
        } else {
            $self->display_error_message($result->{error});
        }
        
    } else {
        $self->display_error_message("Unknown action: $action");
        print "\n";
        print "Usage:\n";
        print "  /skills add <name> \"<text>\"  - Add custom skill\n";
        print "  /skills list                  - List all skills\n";
        print "  /skills use <name> [file]     - Execute skill\n";
        print "  /skills show <name>           - Display skill\n";
        print "  /skills delete <name>         - Delete skill\n";
    }
    
    return;
}

=head2 handle_prompt_command

Handle /prompt commands for system prompt management

=cut

sub handle_prompt_command {
    my ($self, @args) = @_;
    
    require CLIO::Core::PromptManager;
    my $pm = CLIO::Core::PromptManager->new(debug => $self->{debug});
    
    my $action = shift @args || 'show';
    
    if ($action eq 'show') {
        my $prompt = $pm->get_system_prompt();
        
        # Refresh terminal size before pagination (handle resize)
        $self->refresh_terminal_size();
        
        # Reset pagination state
        $self->{line_count} = 0;
        $self->{pages} = [];
        $self->{current_page} = [];
        $self->{page_index} = 0;
        
        # Build header and footer
        my @header = (
            "",
            "=" x 80,
            "ACTIVE SYSTEM PROMPT",
            "=" x 80,
            ""
        );
        
        # Split prompt into lines
        my @lines = split /\n/, $prompt;
        my $total_lines = scalar @lines;
        
        # Display header
        for my $line (@header) {
            last unless $self->writeline($line);
        }
        
        # Display prompt with automatic pagination
        for my $line (@lines) {
            last unless $self->writeline($line);
        }
        
        # Display footer
        my @footer = (
            "",
            "-" x 80,
            "Total: $total_lines lines",
            "Type: " . ($pm->{metadata}->{active_prompt} || 'default'),
            ""
        );
        
        for my $line (@footer) {
            last unless $self->writeline($line);
        }
        
        # Reset line count
        $self->{line_count} = 0;
        
    } elsif ($action eq 'list') {
        my $prompts = $pm->list_prompts();
        my $active = $pm->{metadata}->{active_prompt} || 'default';
        
        print "\n";
        print "SYSTEM PROMPTS\n";
        print "=" x 80, "\n";
        print "\n";
        print "BUILTIN (read-only):\n";
        for my $name (@{$prompts->{builtin}}) {
            my $marker = ($name eq $active) ? " (ACTIVE)" : "";
            printf "  %-20s%s\n", $name, $self->colorize($marker, 'PROMPT');
        }
        
        if (@{$prompts->{custom}}) {
            print "\nCUSTOM:\n";
            for my $name (@{$prompts->{custom}}) {
                my $marker = ($name eq $active) ? " (ACTIVE)" : "";
                printf "  %-20s%s\n", $name, $self->colorize($marker, 'PROMPT');
            }
        } else {
            print "\nNo custom prompts yet.\n";
            print "Use " . $self->colorize('/prompt edit <name>', 'PROMPT') . " to create one.\n";
        }
        
        print "\n";
        printf "Total: %d builtin, %d custom\n", 
            scalar @{$prompts->{builtin}}, 
            scalar @{$prompts->{custom}};
        print "\n";
        
    } elsif ($action eq 'set') {
        my $name = shift @args;
        unless ($name) {
            $self->display_error_message("Usage: /prompt set <name>");
            return;
        }
        
        my $result = $pm->set_active_prompt($name);
        if ($result->{success}) {
            $self->display_system_message("Switched to system prompt '$name'");
            $self->display_system_message("This will apply to future messages in this session.");
        } else {
            $self->display_error_message($result->{error});
        }
        
    } elsif ($action eq 'reset') {
        my $result = $pm->reset_to_default();
        if ($result->{success}) {
            $self->display_system_message("Reset to default system prompt");
        } else {
            $self->display_error_message($result->{error});
        }
        
    } elsif ($action eq 'edit') {
        my $name = shift @args;
        unless ($name) {
            $self->display_error_message("Usage: /prompt edit <name>");
            return;
        }
        
        $self->display_system_message("Opening '$name' in \$EDITOR...");
        my $result = $pm->edit_prompt($name);
        
        if ($result->{success}) {
            if ($result->{modified}) {
                $self->display_system_message("System prompt '$name' saved.");
                $self->display_system_message("Use " . $self->colorize("/prompt set $name", 'PROMPT') . " to activate.");
            } else {
                $self->display_system_message("No changes made to '$name'.");
            }
        } else {
            $self->display_error_message($result->{error});
        }
        
    } elsif ($action eq 'save') {
        my $name = shift @args;
        unless ($name) {
            $self->display_error_message("Usage: /prompt save <name>");
            return;
        }
        
        # Get current system prompt
        my $current = $pm->get_system_prompt();
        
        my $result = $pm->save_prompt($name, $current);
        if ($result->{success}) {
            $self->display_system_message("Saved current system prompt as '$name'");
            $self->display_system_message("Use " . $self->colorize("/prompt set $name", 'PROMPT') . " to activate later.");
        } else {
            $self->display_error_message($result->{error});
        }
        
    } elsif ($action eq 'delete') {
        my $name = shift @args;
        unless ($name) {
            $self->display_error_message("Usage: /prompt delete <name>");
            return;
        }
        
        # Confirm deletion
        print "Are you sure you want to delete prompt '$name'? (yes/no): ";
        my $confirm = <STDIN>;
        chomp($confirm);
        
        unless ($confirm =~ /^y(es)?$/i) {
            $self->display_system_message("Deletion cancelled.");
            return;
        }
        
        my $result = $pm->delete_prompt($name);
        if ($result->{success}) {
            $self->display_system_message("Deleted prompt '$name'.");
        } else {
            $self->display_error_message($result->{error});
        }
        
    } else {
        $self->display_error_message("Unknown action: $action");
        print "\n";
        print "Usage:\n";
        print "  /prompt show              - Display current system prompt\n";
        print "  /prompt list              - List available prompts\n";
        print "  /prompt set <name>        - Switch to named prompt\n";
        print "  /prompt edit <name>       - Edit prompt in \$EDITOR\n";
        print "  /prompt save <name>       - Save current as new\n";
        print "  /prompt delete <name>     - Delete custom prompt\n";
        print "  /prompt reset             - Reset to default\n";
    }
    
    return;
}

=head2 _build_skill_context

Build context hashref for skill variable substitution

=cut

sub _build_skill_context {
    my ($self, $file) = @_;
    
    my $context = {};
    
    # Add code if file specified
    if ($file && -f $file) {
        open my $fh, '<', $file;
        $context->{code} = do { local $/; <$fh> };
        close $fh;
        
        $context->{file} = $file;
        $context->{path} = File::Spec->rel2abs($file);
    }
    
    # Add git context
    $context->{diff} = `git diff --staged 2>/dev/null` || '';
    $context->{status} = `git status --short 2>/dev/null` || '';
    $context->{branch} = `git branch --show-current 2>/dev/null` || '';
    chomp($context->{branch});
    
    # Add workspace context
    # Use session working_directory if available, fallback to getcwd()
    my $workspace_dir = '';
    if ($self->{session} && $self->{session}{state}{working_directory}) {
        $workspace_dir = $self->{session}{state}{working_directory};
    } else {
        require Cwd;
        $workspace_dir = Cwd::getcwd() || $ENV{PWD} || '';
    }
    $context->{workspace} = $workspace_dir;
    $context->{project} = (File::Spec->splitdir($context->{workspace}))[-1] || '';
    
    # Add conversation context (last 5 messages)
    if ($self->{session} && $self->{session}{history}) {
        my @history = @{$self->{session}{history}};
        my $start = @history > 5 ? @history - 5 : 0;
        my @recent = @history[$start .. $#history];
        $context->{conversation} = join("\n\n", map { "$_->{role}: $_->{content}" } @recent);
    }
    
    # Add context files if any
    if ($self->{session} && $self->{session}{context_files}) {
        my @context_contents = ();
        for my $ctx_file (@{$self->{session}{context_files}}) {
            if (-f $ctx_file) {
                open my $fh, '<', $ctx_file;
                my $content = do { local $/; <$fh> };
                close $fh;
                push @context_contents, "File: $ctx_file\n\n$content";
            }
        }
        $context->{context} = join("\n\n" . ("=" x 80) . "\n\n", @context_contents);
    }
    
    return $context;
}

=head2 handle_fix_command

Propose fixes for code problems

=cut

sub handle_fix_command {
    my ($self, @args) = @_;
    
    my $file = join(' ', @args);
    
    unless ($file && -f $file) {
        $self->display_error_message("Usage: /fix <file>");
        return;
    }
    
    # Read file content
    open my $fh, '<', $file or do {
        $self->display_error_message("Cannot read file: $file");
        return;
    };
    my $code = do { local $/; <$fh> };
    close $fh;
    
    # Get errors/diagnostics (Perl only for now)
    my $errors = `perl -c $file 2>&1`;
    
    # Build prompt
    my $prompt = <<"PROMPT";
Analyze this code and propose fixes for any problems:

File: $file

Code:
```
$code
```

Problems detected:
$errors

Provide:
1. Clear explanation of each problem
2. Proposed fix for each issue
3. Complete corrected code

Focus on:
- Logic errors
- Security issues
- Performance problems
- Best practice violations
PROMPT

    return $prompt;
}

=head2 handle_doc_command

Generate documentation for code

=cut

sub handle_doc_command {
    my ($self, @args) = @_;
    
    my $file = join(' ', @args);
    
    unless ($file && -f $file) {
        $self->display_error_message("Usage: /doc <file>");
        return;
    }
    
    # Read file content
    open my $fh, '<', $file or do {
        $self->display_error_message("Cannot read file: $file");
        return;
    };
    my $code = do { local $/; <$fh> };
    close $fh;
    
    # Detect language from file extension
    my $format = 'POD';  # Default for Perl
    if ($file =~ /\.js$/) { $format = 'JSDoc'; }
    elsif ($file =~ /\.py$/) { $format = 'Python docstrings'; }
    elsif ($file =~ /\.ts$/) { $format = 'TSDoc'; }
    
    my $prompt = <<"PROMPT";
Generate comprehensive documentation for this code:

File: $file

Code:
```
$code
```

Generate:
1. Module/function overview
2. Parameter descriptions with types
3. Return value documentation
4. Usage examples
5. Edge cases and error handling
6. Dependencies and requirements

Format: $format

Make the documentation clear, comprehensive, and ready to use.
PROMPT

    return $prompt;
}

=head2 setup_tab_completion

Setup tab completion for interactive terminal

=cut

sub setup_tab_completion {
    my ($self) = @_;
    
    eval {
        require CLIO::Core::TabCompletion;
        require CLIO::Core::ReadLine;
        
        # Create tab completer
        $self->{completer} = CLIO::Core::TabCompletion->new(debug => $self->{debug});
        
        # Create custom readline with completer
        $self->{readline} = CLIO::Core::ReadLine->new(
            prompt => '',  # We'll provide prompt in get_input
            completer => $self->{completer},
            debug => $self->{debug}
        );
        
        print STDERR "[DEBUG][CleanChat] Custom readline with tab completion enabled\n" if should_log('DEBUG');
    };
    
    if ($@) {
        print STDERR "[WARN][CleanChat] Tab completion setup failed: $@\n" if $self->{debug};
        $self->{readline} = undef;
        $self->{completer} = undef;
    }
}

=head2 add_to_buffer

Add a message to the screen buffer for later repaint

=cut

sub add_to_buffer {
    my ($self, $type, $content) = @_;
    
    push @{$self->{screen_buffer}}, {
        type => $type,
        content => $content,
        timestamp => time(),
    };
    
    # Limit buffer size
    if (@{$self->{screen_buffer}} > $self->{max_buffer_size}) {
        shift @{$self->{screen_buffer}};
    }
}

=head2 repaint_screen

Clear screen and repaint from buffer (used by /clear command)

=cut

sub repaint_screen {
    my ($self) = @_;
    
    # Clear screen
    print "\e[2J\e[H";  # Clear screen + home cursor
    
    # Display header
    $self->display_header();
    
    # Replay buffer without adding to it again
    for my $msg (@{$self->{screen_buffer}}) {
        if ($msg->{type} eq 'user') {
            print $self->colorize("YOU: ", 'USER'), $msg->{content}, "\n";
        }
        elsif ($msg->{type} eq 'assistant') {
            print $self->colorize("CLIO: ", 'ASSISTANT'), $msg->{content}, "\n";
        }
        elsif ($msg->{type} eq 'system') {
            print $self->colorize("SYSTEM: ", 'SYSTEM'), $msg->{content}, "\n";
        }
        elsif ($msg->{type} eq 'error') {
            print $self->colorize("ERROR: ", 'ERROR'), $msg->{content}, "\n";
        }
    }
}

=head2 pause

Display pagination prompt and wait for keypress (PhotonBBS pattern)

=cut

sub pause {
    my ($self, $streaming) = @_;
    $streaming ||= 0;  # Default to non-streaming mode
    
    # Refresh terminal size before pagination (handle resize)
    $self->refresh_terminal_size();
    
    # In streaming mode, don't try to navigate (content still arriving)
    if ($streaming) {
        my $prompt = "(Q)uit or press any key to continue: ";
        print "\n";  # Ensure prompt is on its own line
        print $self->colorize($prompt, 'THEME');
        
        ReadMode('cbreak');
        my $key = ReadKey(0);
        ReadMode('normal');
        
        print "\e[2K\e[" . $self->{terminal_width} . "D";  # Clear prompt line
        
        $key = uc($key) if $key;
        return $key || 'C';
    }
    
    # Non-streaming mode: full arrow navigation
    my $total_pages = scalar(@{$self->{pages}});
    my $current = $self->{page_index} + 1;
    
    while (1) {
        # Display pause prompt with page info
        my $prompt = $total_pages > 0 
            ? "(Q)uit, ↑/↓ navigate, or press key [Page $current of $total_pages]: "
            : "(Q)uit, (C)ontinue, or press any key: ";
        print $self->colorize($prompt, 'THEME');
        
        # Wait for keypress
        ReadMode('cbreak');
        my $key = ReadKey(0);
        
        # Handle arrow keys (escape sequences)
        if ($key eq "\e") {
            # Read the rest of the escape sequence (still in cbreak mode)
            my $seq = ReadKey(0) . ReadKey(0);
            ReadMode('normal');  # Restore normal mode after reading sequence
            
            # Clear prompt line
            print "\e[2K\e[" . $self->{terminal_width} . "D";
            
            if ($seq eq '[A' && $self->{page_index} > 0) {
                # Up arrow - go to previous page
                $self->{page_index}--;
                $self->redraw_page();
                next;  # Stay in pause loop
            }
            elsif ($seq eq '[B' && $self->{page_index} < $total_pages - 1) {
                # Down arrow - go to next page
                $self->{page_index}++;
                $self->redraw_page();
                next;  # Stay in pause loop
            }
        }
        
        # Regular key handling - restore normal mode first
        ReadMode('normal');
        
        # Clear prompt line
        print "\e[2K\e[" . $self->{terminal_width} . "D";
        
        $key = uc($key) if $key;
        return $key || 'C';
    }
}

=head2 render_markdown

Render markdown text to ANSI if markdown is enabled

=cut

sub render_markdown {
    my ($self, $text) = @_;
    
    return $text unless $self->{enable_markdown};
    my $rendered = $self->{markdown_renderer}->render($text);
    
    # DEBUG: Check if @-codes are in rendered text
    if ($self->{debug} && $rendered =~ /\@[A-Z_]+\@/) {
        print STDERR "[DEBUG][Chat] render_markdown: Found @-codes in rendered text\n";
        print STDERR "[DEBUG][Chat] Sample: ", substr($rendered, 0, 100), "\n";
    }
    
    # Parse @COLOR@ markers to actual ANSI escape sequences
    my $parsed = $self->{ansi}->parse($rendered);
    
    # DEBUG: Verify @-codes were converted
    if ($self->{debug} && $parsed =~ /\@[A-Z_]+\@/) {
        print STDERR "[DEBUG][Chat] WARNING: @-codes still present after ANSI parse!\n";
        print STDERR "[DEBUG][Chat] Sample: ", substr($parsed, 0, 100), "\n";
    }
    
    return $parsed;
}

=head2 writeline

Write a line with pagination support (with optional markdown rendering)

=cut

sub writeline {
    my ($self, $text, $newline, $use_markdown) = @_;
    $newline = 1 unless defined $newline;
    $use_markdown = 0 unless defined $use_markdown;
    
    # Render markdown if requested and enabled
    if ($use_markdown && $self->{enable_markdown}) {
        $text = $self->{markdown_renderer}->render($text);
    }
    
    print $text;
    print "\n" if $newline;
    
    # Skip pagination if not interactive (pipe mode, redirected, etc.)
    my $is_interactive = -t STDIN;
    
    if ($newline && $is_interactive) {
        # Buffer line for page navigation
        push @{$self->{current_page}}, $text;
        $self->{line_count}++;
        
        if ($self->{line_count} >= $self->{terminal_height}) {
            # Save current page to buffer
            push @{$self->{pages}}, [@{$self->{current_page}}];
            $self->{page_index} = scalar(@{$self->{pages}}) - 1;
            
            my $response = $self->pause();
            
            if ($response eq 'Q') {
                $self->{line_count} = 0;
                $self->{current_page} = [];
                return 0;  # Signal to stop output
            }
            
            # Reset for next page
            $self->{line_count} = 0;
            $self->{current_page} = [];
        }
    }
    
    return 1;  # Continue
}

=head2 redraw_page

Redraw a buffered page for arrow key navigation

=cut

sub redraw_page {
    my ($self) = @_;
    
    my $page = $self->{pages}->[$self->{page_index}];
    return unless $page && ref($page) eq 'ARRAY';
    
    # Clear screen and home cursor
    print "\e[2J\e[H";
    
    # Redraw the page
    for my $line (@$page) {
        print $line, "\n";
    }
}

=head2 show_thinking

Display thinking indicator while AI processes

=cut

sub show_thinking {
    my ($self) = @_;
    
    print $self->colorize("CLIO: ", 'ASSISTANT');
    print $self->colorize("(thinking...)", 'DIM');
    $|= 1;  # Flush output
}

=head2 clear_thinking

Clear the thinking indicator line

=cut

sub clear_thinking {
    my ($self) = @_;
    
    # Clear line and move cursor back
    print "\e[2K\e[" . $self->{terminal_width} . "D";
}

=head2 handle_style_command

Handle /style command - manage color schemes

=cut

sub handle_style_command {
    my ($self, $action, @args) = @_;
    
    # Default to 'show' if no action provided
    $action ||= 'show';
    
    # If action is not a known command, treat it as "set <action>"
    unless ($action =~ /^(list|show|set|save)$/) {
        unshift @args, $action;
        $action = 'set';
    }
    
    if ($action eq 'list') {
        my @styles = $self->{theme_mgr}->list_styles();
        my $current = $self->{theme_mgr}->get_current_style();
        
        print $self->colorize("AVAILABLE STYLES", 'DATA'), "\n\n";
        for my $style (@styles) {
            my $marker = ($style eq $current) ? ' (current)' : '';
            printf "  %-20s%s\n", $style, $self->colorize($marker, 'PROMPT');
        }
        print "\n";
        print "Use ", $self->colorize("/style set <name>", 'PROMPT'), " to switch styles\n";
    }
    elsif ($action eq 'show') {
        my $current = $self->{theme_mgr}->get_current_style();
        print $self->colorize("CURRENT STYLE", 'DATA'), "\n\n";
        print "  ", $self->colorize($current, 'USER'), "\n\n";
    }
    elsif ($action eq 'set') {
        my $name = $args[0];
        unless ($name) {
            $self->display_error_message("Usage: /style set <name>");
            return;
        }
        
        if ($self->{theme_mgr}->set_style($name)) {
            # Save to session state
            $self->{session}->state()->{style} = $name;
            $self->{session}->save();
            
            $self->display_system_message("Style changed to: $name");
        } else {
            $self->display_error_message("Style '$name' not found. Use /style list to see available styles.");
        }
    }
    elsif ($action eq 'save') {
        my $name = $args[0];
        unless ($name) {
            $self->display_error_message("Usage: /style save <name>");
            return;
        }
        
        if ($self->{theme_mgr}->save_style($name)) {
            $self->display_system_message("Style saved as: $name");
            $self->display_system_message("Use " . $self->colorize("/style set $name", 'PROMPT') . " to activate later.");
        } else {
            $self->display_error_message("Failed to save style");
        }
    }
}

=head2 handle_theme_command

Handle /theme command - manage output templates

=cut

sub handle_theme_command {
    my ($self, $action, @args) = @_;
    
    # Default to 'show' if no action provided
    $action ||= 'show';
    
    # If action is not a known command, treat it as "set <action>"
    unless ($action =~ /^(list|show|set|save)$/) {
        unshift @args, $action;
        $action = 'set';
    }
    
    if ($action eq 'list') {
        my @themes = $self->{theme_mgr}->list_themes();
        my $current = $self->{theme_mgr}->get_current_theme();
        
        print $self->colorize("AVAILABLE THEMES", 'DATA'), "\n\n";
        for my $theme (@themes) {
            my $marker = ($theme eq $current) ? ' (current)' : '';
            printf "  %-20s%s\n", $theme, $self->colorize($marker, 'PROMPT');
        }
        print "\n";
        print "Use ", $self->colorize("/theme set <name>", 'PROMPT'), " to switch themes\n";
    }
    elsif ($action eq 'show') {
        my $current = $self->{theme_mgr}->get_current_theme();
        print $self->colorize("CURRENT THEME", 'DATA'), "\n\n";
        print "  ", $self->colorize($current, 'USER'), "\n\n";
    }
    elsif ($action eq 'set') {
        my $name = $args[0];
        unless ($name) {
            $self->display_error_message("Usage: /theme set <name>");
            return;
        }
        
        if ($self->{theme_mgr}->set_theme($name)) {
            # Save to session state
            $self->{session}->state()->{theme} = $name;
            $self->{session}->save();
            
            $self->display_system_message("Theme changed to: $name");
        } else {
            $self->display_error_message("Theme '$name' not found. Use /theme list to see available themes.");
        }
    }
    elsif ($action eq 'save') {
        my $name = $args[0];
        unless ($name) {
            $self->display_error_message("Usage: /theme save <name>");
            return;
        }
        
        if ($self->{theme_mgr}->save_theme($name)) {
            $self->display_system_message("Theme saved as: $name");
            $self->display_system_message("Use " . $self->colorize("/theme set $name", 'PROMPT') . " to activate later.");
        } else {
            $self->display_error_message("Failed to save theme");
        }
    }
}

=head2 colorize

Apply color to text using theme manager

=cut

sub colorize {
    my ($self, $text, $color_key) = @_;
    
    return $text unless $self->{use_color};
    
    # Legacy color key mapping (for backward compatibility)
    my %key_map = (
        ASSISTANT => 'agent_label',
        THEME => 'banner',
        DATA => 'data',
        USER => 'user_text',
        PROMPT => 'prompt_indicator',
        SYSTEM => 'system_message',
        ERROR => 'error_message',
        DIM => 'dim',
        LABEL => 'theme_header',
        SUCCESS => 'user_prompt',  # Green
        WARN => 'error_message',   # Red
        WARNING => 'error_message',  # Red
        SEPARATOR => 'dim',  # Dim for separator lines
        COLLAB_HEADER => 'banner',  # Bright/bold for collaboration header
        COLLAB_CONTEXT => 'data',   # Data color for context
        COLLAB_PROMPT => 'agent_label',  # Different from normal prompt
        COLLAB_ARROW => 'prompt_indicator',  # Arrow indicator
    );
    
    # Map legacy key to new key
    my $mapped_key = $key_map{$color_key} || $color_key;
    
    my $color = $self->{theme_mgr}->get_color($mapped_key);
    return $text unless $color;
    
    return $self->{ansi}->parse($color . $text . '@RESET@');
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
