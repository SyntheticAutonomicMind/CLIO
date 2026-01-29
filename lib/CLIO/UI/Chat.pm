package CLIO::UI::Chat;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use CLIO::Util::TextSanitizer qw(sanitize_text);
use CLIO::UI::Markdown;
use CLIO::UI::ANSI;
use CLIO::UI::Theme;
use CLIO::UI::ProgressSpinner;
use CLIO::UI::CommandHandler;
use CLIO::UI::Display;
use utf8;
use open ':std', ':encoding(UTF-8)';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Compat::Terminal qw(GetTerminalSize ReadMode ReadKey);  # Portable terminal control
use File::Spec;

# Enable autoflush globally for STDOUT to prevent buffering issues
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
        # Pagination control - OFF by default, enabled only for text responses
        pagination_enabled => 0,  # Only enable for final agent text, not tool output
        # Persistent spinner - shared across all requests
        # Keep spinner as persistent Chat property so tools can reliably access it
        spinner => undef,     # Will be created on first use, reused across requests
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
    # Initialize CommandHandler for slash command processing
    $self->{command_handler} = CLIO::UI::CommandHandler->new(
        chat => $self,
        session => $self->{session},
        config => $self->{config},
        ai_agent => $self->{ai_agent},
        debug => $self->{debug},
    );
    
    # Initialize Display for message formatting
    $self->{display} = CLIO::UI::Display->new(
        chat => $self,
        debug => $self->{debug},
    );
    
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

=head2 show_busy_indicator

Show the busy spinner to indicate system is processing.
Called when CLIO is busy (tool execution, API processing, etc.)

This ensures users always see visual feedback when the system is working.

=cut

sub show_busy_indicator {
    my ($self) = @_;
    
    # Ensure spinner is initialized
    unless ($self->{spinner}) {
        my $spinner_frames = $self->{theme_mgr}->get_spinner_frames();
        $self->{spinner} = CLIO::UI::ProgressSpinner->new(
            frames => $spinner_frames,
            delay => 100000,
            inline => 1,
        );
        print STDERR "[DEBUG][Chat] Created spinner in show_busy_indicator\n" if should_log('DEBUG');
    }
    
    # Only start if not already running
    if (!$self->{spinner}->{running}) {
        $self->{spinner}->start();
        print STDERR "[DEBUG][Chat] Busy indicator started\n" if should_log('DEBUG');
    }
    
    return 1;
}

=head2 hide_busy_indicator

Hide the busy spinner when system is no longer processing.
Called when outputting data or waiting for user input.

=cut

sub hide_busy_indicator {
    my ($self) = @_;
    
    # Stop spinner if it exists and is running
    if ($self->{spinner} && $self->{spinner}->{running}) {
        $self->{spinner}->stop();
        print STDERR "[DEBUG][Chat] Busy indicator stopped\n" if should_log('DEBUG');
    }
    
    return 1;
}

=head2 run

Main chat loop - displays interface and processes user input

=cut

sub run {
    my ($self) = @_;
    
    # Display header
    $self->display_header();
    
    # Background update check (non-blocking)
    $self->check_for_updates_async();
    
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
            # Use persistent spinner stored on Chat object
            # This ensures tools can access the SAME spinner instance via context
            # Previously, a new local spinner was created per request, causing reference issues
            unless ($self->{spinner}) {
                # Create persistent spinner on first use with frames from current style
                # Use inline mode so spinner animates after text we print
                my $spinner_frames = $self->{theme_mgr}->get_spinner_frames();
                $self->{spinner} = CLIO::UI::ProgressSpinner->new(
                    frames => $spinner_frames,
                    delay => 100000,  # 100ms between frames for smooth block animation
                    inline => 1,      # Inline mode: don't clear entire line, just the spinner
                );
                print STDERR "[DEBUG][Chat] Created persistent spinner in inline mode\n" if should_log('DEBUG');
            }
            
            # Print "CLIO: " prefix before starting spinner
            # Spinner will animate inline after this text
            print $self->colorize("CLIO: ", 'ASSISTANT');
            STDOUT->flush() if STDOUT->can('flush');
            $self->{line_count}++;
            
            # Start the inline spinner (animates after the prefix we just printed)
            $self->{spinner}->start();
            print STDERR "[DEBUG][Chat] Started inline spinner after CLIO: prefix\n" if should_log('DEBUG');
            
            # Reference for use in closures below
            my $spinner = $self->{spinner};
            
            # Reset pagination state before streaming
            $self->{line_count} = 0;
            $self->{stop_streaming} = 0;
            $self->{pages} = [];
            $self->{current_page} = [];
            $self->{page_index} = 0;
            
            # Track whether tools were called - disable pagination during tool workflows
            # This prevents having to press space after every page of tool output
            # Pagination only applies to "final" responses without tool calls
            $self->{_tools_invoked_this_request} = 0;
            
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
                # Spinner animates inline after "CLIO: " prefix which was already printed
                # Just stop the spinner to remove it, the prefix stays
                # Also check _prepare_for_next_iteration flag set by WorkflowOrchestrator
                # after tool execution - this ensures spinner stops even on continuation chunks
                if (!$first_chunk_received || $self->{_prepare_for_next_iteration}) {
                    $spinner->stop();  # Removes spinner
                    
                    # If this is a continuation after tool execution, clear the entire line
                    # to remove the "CLIO: " prefix that was printed before the spinner
                    if ($self->{_prepare_for_next_iteration}) {
                        print "\r\e[K";  # Carriage return + clear entire line
                        # Now print fresh "CLIO: " prefix
                        print $self->colorize("CLIO: ", 'ASSISTANT');
                        STDOUT->flush() if STDOUT->can('flush');
                        $self->{_prepare_for_next_iteration} = 0;  # Clear the flag
                    }
                    # Otherwise just leave the "CLIO: " prefix intact from initial prompt
                    
                    # Enable pagination for text responses (agent is speaking directly)
                    # This will be left enabled unless/until tools are invoked
                    if (!$first_chunk_received) {
                        $self->{pagination_enabled} = 1;
                        print STDERR "[DEBUG][Chat] Pagination ENABLED for text response\n" if $self->{debug};
                    }
                    
                    print STDERR "[DEBUG][Chat] First chunk received, spinner removed (CLIO: prefix remains)\n" if $self->{debug};
                    $first_chunk_received = 1;
                }
                
                # Display role label only when _need_agent_prefix is set
                # (this happens after tool execution when we need a new CLIO: prefix for continuation)
                # NOTE: This should no longer be needed since we handle it above with _prepare_for_next_iteration
                if ($self->{_need_agent_prefix}) {
                    $self->{_need_agent_prefix} = 0;  # Clear the flag
                    # Don't print prefix here - it's already handled above
                    print STDERR "[DEBUG][Chat] _need_agent_prefix was set but prefix already printed\n" if $self->{debug};
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
                    
                    # Track table state more accurately:
                    # - Start table when we see a | row
                    # - End table when we see a non-| row (excluding blank lines)
                    my $line_is_table_row = ($line =~ /^\|.*\|$/);
                    my $line_is_blank = ($line =~ /^\s*$/);
                    
                    if ($line_is_table_row) {
                        $in_table = 1;
                    } elsif (!$line_is_blank && $in_table) {
                        # Non-blank, non-table line ends the table
                        $in_table = 0;
                    }
                    # Blank lines don't change table state (tables can have blank lines)
                    
                    # Add line to markdown buffer (using $self)
                    $self->{_streaming_markdown_buffer} .= $line . "\n";
                    $markdown_line_count++;
                    
                    # Determine if we should flush the buffer
                    my $current_time = time();
                    my $buffer_size_threshold = 10;     # Flush every 10 lines
                    my $time_threshold = 0.5;            # Or every 500ms
                    my $max_buffer_size = 50;            # Force flush at 50 lines even in table
                    
                    # Flush buffer when:
                    # 1. Buffer has enough lines (size threshold) AND not in code block or table
                    # 2. Timeout reached AND not in code block or table
                    # 3. Force flush if buffer is very large (prevents memory issues)
                    # Note: We DON'T flush while inside code blocks or tables
                    my $in_special_block = $in_code_block || $in_table;
                    my $should_flush = (
                        ($markdown_line_count >= $buffer_size_threshold && !$in_special_block) ||  # Normal flush
                        ($current_time - $last_flush_time >= $time_threshold && !$in_special_block) ||  # Timeout flush
                        ($markdown_line_count >= $max_buffer_size)  # Force flush to prevent memory issues
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
                        
                        # Check pagination - ONLY when explicitly enabled for text responses
                        # pagination_enabled is set to 1 for agent text responses (no tools)
                        # and remains 0 during tool execution to let output scroll freely
                        # Pause BEFORE terminal_height to leave room for pause message
                        # This prevents content from scrolling off screen before user can read
                        my $pause_threshold = $self->{terminal_height} - 2;  # Leave 2 lines for pause prompt
                        if ($self->{line_count} >= $pause_threshold && 
                            $self->{pagination_enabled} &&
                            !$self->{_tools_invoked_this_request}) {
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
                
                # Mark that tools have been invoked - disables streaming pagination
                # so user doesn't have to press space during AI "work"
                $self->{_tools_invoked_this_request} = 1;
                
                # Disable pagination during tool execution
                $self->{pagination_enabled} = 0;
                print STDERR "[DEBUG][Chat] Pagination DISABLED for tool execution: $tool_name\n" if $self->{debug};
                
                print STDERR "[DEBUG][Chat] Tool called: $tool_name\n" if $self->{debug};
            };
            
            # Display system messages (rate limits, server errors, etc.)
            my $on_system_message = sub {
                my ($message) = @_;
                
                return unless defined $message;
                
                # Hide busy indicator before displaying system message
                # This clears the spinner, leaving "CLIO: " on the line
                $self->hide_busy_indicator() if $self->can('hide_busy_indicator');
                
                # Clear the "CLIO: " prefix that was printed before the spinner
                # This ensures system messages start on a clean line
                print "\r\e[K";  # Carriage return + clear entire line
                
                # Display system message with proper styling
                print $self->colorize("SYSTEM: ", 'SYSTEM') . $message . "\n";
                STDOUT->flush() if STDOUT->can('flush');
                $self->{line_count}++;
                
                print STDERR "[DEBUG][Chat] System message: $message\n" if $self->{debug};
            };
            
            # Get conversation history from session
            my $conversation_history = [];
            if ($self->{session} && $self->{session}->can('get_conversation_history')) {
                $conversation_history = $self->{session}->get_conversation_history() || [];
                print STDERR "[DEBUG][Chat] Loaded " . scalar(@$conversation_history) . " messages from session history\n" if $self->{debug};
            }
            
            # Enable periodic signal delivery during streaming
            # Without this, Ctrl-C during HTTP streaming won't save session because:
            # - HTTP::Tiny blocks in socket read syscall
            # - Perl signal handlers only run between Perl opcodes
            # - ALRM interrupts the syscall, allowing signal handlers to run
            # Trade-off: 1-second worst-case latency for Ctrl-C response
            my $alarm_count = 0;
            my $alarm_handler = sub {
                $alarm_count++;
                print STDERR "[DEBUG][Chat] ALRM #$alarm_count - syscall interrupted for signal delivery\n" if should_log('DEBUG');
                alarm(1);  # Re-arm for next second
            };
            local $SIG{ALRM} = $alarm_handler;
            alarm(1);  # Start periodic interruption
            
            # Process request with streaming callback (match clio script pattern)
            print STDERR "[DEBUG][Chat] Calling process_user_request...\n" if should_log('DEBUG');
            my $result = $self->{ai_agent}->process_user_request($input, {
                on_chunk => $on_chunk,
                on_tool_call => $on_tool_call,  # Track which tools are being called
                on_system_message => $on_system_message,  # Display system messages
                conversation_history => $conversation_history,
                current_file => $self->{session}->{state}->{current_file},
                working_directory => $self->{session}->{state}->{working_directory},
                ui => $self,  # Pass UI object for user_collaboration tool
                spinner => $spinner  # Pass spinner for interactive tools to stop
            });
            print STDERR "[DEBUG][Chat] process_user_request returned, success=" . ($result->{success} ? "yes" : "no") . "\n" if $self->{debug};
            
            # Disable periodic alarm after streaming completes
            alarm(0);
            print STDERR "[DEBUG][Chat] Disabled periodic ALRM after streaming ($alarm_count interrupts)\n" if should_log('DEBUG');
            
            # Stop spinner in case it's still running (e.g., error before first chunk)
            $spinner->stop();
            
            # DEBUG: Check buffer states before flush
            if ($self->{debug}) {
                print STDERR "[DEBUG][Chat] AFTER streaming - markdown_buffer length=" . length($self->{_streaming_markdown_buffer} // '') . "\n";
                print STDERR "[DEBUG][Chat] AFTER streaming - line_buffer length=" . length($self->{_streaming_line_buffer} // '') . "\n";
                print STDERR "[DEBUG][Chat] AFTER streaming - first_chunk_received=$first_chunk_received\n";
            }
            
            # Flush any remaining content in buffers after streaming completes
            
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
            # Sanitize assistant responses before storing to prevent emoji encoding issues
            # BUT only if messages weren't already saved during the workflow execution.
            # Tool-calling workflows save messages atomically (assistant + tool results together),
            # so we should NOT save another assistant message here to avoid duplicates.
            if ($result && $result->{messages_saved_during_workflow}) {
                print STDERR "[DEBUG][Chat] Skipping session save - messages already saved during workflow\n" if $self->{debug};
                # Still add to buffer for display (content was streamed, not saved)
                $self->add_to_buffer('assistant', $result->{final_response} // '') if $result->{final_response};
            } elsif ($result && $result->{final_response}) {
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
                    
                    # Save session immediately after error to prevent history loss
                    # This ensures error context is available on next startup
                    $self->{session}->save();
                    print STDERR "[DEBUG][Chat] Session saved after error (preserving context)\n" if should_log('DEBUG');
                }
            } else {
                # CRITICAL FIX #1: Save session after SUCCESSFUL responses
                # Without this, if user doesn't call /exit, all work-in-progress is lost
                # on next session restart. This ensures session continuity even if terminal
                # is closed abruptly without explicit /exit command.
                if ($self->{session}) {
                    $self->{session}->save();
                    print STDERR "[DEBUG][Chat] Session saved after successful response (preserving work-in-progress)\n" if should_log('DEBUG');
                }
                
                # HYBRID LTM APPROACH: AutoCapture disabled. Agents store discoveries
                # explicitly via memory_operations tool when important facts are learned.
                # This ensures clean LTM with no heuristic noise or truncation.
                # See: memory_operations(operation: "add_discovery") or related methods
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
            
            # Disable pagination after response completes
            # Will be re-enabled on first chunk of next text response
            $self->{pagination_enabled} = 0;
            print STDERR "[DEBUG][Chat] Pagination DISABLED after response complete\n" if $self->{debug};
            
            # Ensure spinner is stopped before returning to input prompt
            # This prevents spinner from still running when waiting for user input
            $self->hide_busy_indicator();
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

=head2 check_for_updates_async

Check for updates in background (non-blocking)

=cut

sub check_for_updates_async {
    my ($self) = @_;
    
    # Load Update module
    eval {
        require CLIO::Update;
    };
    if ($@) {
        # Silently fail if module not available
        print STDERR "[DEBUG][Chat] Update module not available: $@\n" if should_log('DEBUG');
        return;
    }
    
    my $updater = CLIO::Update->new(debug => $self->{debug});
    
    # Check if we have cached update info
    my $update_info = $updater->get_available_update();
    
    if ($update_info && $update_info->{cached} && !$update_info->{up_to_date}) {
        # Display update notification
        my $version = $update_info->{version} || 'unknown';
        $self->display_system_message("An update is available ($version). Run " . 
            $self->colorize('/update install', 'command') . " to upgrade.");
    }
    
    # Fork background process to check for updates
    # Parent returns immediately, child checks and caches result
    my $pid = fork();
    
    if (!defined $pid) {
        # Fork failed - silently continue
        print STDERR "[WARNING][Chat] Failed to fork update checker: $!\n" if should_log('WARNING');
        return;
    }
    
    if ($pid == 0) {
        # Child process - check for updates
        # Close stdin/stdout/stderr to avoid interfering with parent's terminal
        # The child doesn't need terminal I/O and keeping these open can cause
        # readline issues in the parent process (e.g., Ctrl-D hanging on first input)
        close(STDIN);
        close(STDOUT);
        close(STDERR);
        
        eval {
            $updater->check_for_updates();
        };
        # Can't print errors since STDERR is closed, just exit
        exit 0;  # Child exits
    }
    
    # Parent continues - don't wait for child
}

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

=head2 _build_prompt

Build the enhanced prompt with model, directory, and git branch.

Format: [model-name] directory-name (git-branch): 

Components:
- Model name in brackets (themed)
- Current directory basename (themed)
- Git branch in parentheses if in repo (themed)
- Colon prompt indicator (themed based on input mode)

Arguments:
- $mode: Optional mode ('normal' or 'collaboration'), defaults to 'normal'
         - 'normal': Uses 'prompt_indicator' color (user's theme)
         - 'collaboration': Uses 'COLLAB_PROMPT' color (bright cyan/blue)

Returns: Formatted prompt string with theme colors

=cut

sub _build_prompt {
    my ($self, $mode) = @_;
    $mode ||= 'normal';  # Default to normal mode
    
    my @parts;
    
    # 1. Model name in brackets
    my $model = 'unknown';
    if ($self->{ai_agent} && $self->{ai_agent}->{api}) {
        $model = $self->{ai_agent}->{api}->get_current_model() || 'unknown';
        # Abbreviate long model names
        $model =~ s/-20\d{6}$//;  # Remove date suffix (e.g., -20250219)
    }
    push @parts, $self->colorize("[$model]", 'prompt_model');
    
    # 2. Directory name (basename only)
    use File::Basename;
    use Cwd 'getcwd';
    my $cwd = getcwd();
    my $dir_name = basename($cwd);
    push @parts, $self->colorize($dir_name, 'prompt_directory');
    
    # 3. Git branch (if in git repo)
    my $branch = `git branch --show-current 2>/dev/null`;
    chomp $branch if $branch;
    if ($branch && length($branch) > 0) {
        push @parts, $self->colorize("($branch)", 'prompt_git_branch');
    }
    
    # 4. Prompt indicator (colon) - color depends on mode
    my $indicator_color = $mode eq 'collaboration' ? 'COLLAB_PROMPT' : 'prompt_indicator';
    push @parts, $self->colorize(":", $indicator_color);
    
    # Join with spaces (except before colon)
    my $prompt_text = join(' ', @parts[0..$#parts-1]);  # All but last
    $prompt_text .= $parts[-1];  # Add colon without space
    $prompt_text .= ' ';  # Add space after colon for input
    
    return $prompt_text;
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
        my $prompt = $self->_build_prompt();
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
    my $prompt = $self->_build_prompt();
    print $prompt;
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
    my ($self, @args) = @_;
    return $self->{display}->display_user_message(@args);
}

=head2 display_assistant_message

Display an assistant message with role label (no timestamp)

=cut

sub display_assistant_message {
    my ($self, @args) = @_;
    return $self->{display}->display_assistant_message(@args);
}

=head2 display_system_message

Display a system message

=cut

sub display_system_message {
    my ($self, @args) = @_;
    return $self->{display}->display_system_message(@args);
}

=head2 display_error_message

Display an error message

=cut

sub display_error_message {
    my ($self, @args) = @_;
    return $self->{display}->display_error_message(@args);
}

=head2 display_success_message

Display a success message with prefix

=cut

sub display_success_message {
    my ($self, @args) = @_;
    return $self->{display}->display_success_message(@args);
}

=head2 display_warning_message

Display a warning message with [WARN] prefix

=cut

sub display_warning_message {
    my ($self, @args) = @_;
    return $self->{display}->display_warning_message(@args);
}

=head2 display_info_message

Display an informational message with [INFO] prefix

=cut

sub display_info_message {
    my ($self, @args) = @_;
    return $self->{display}->display_info_message(@args);
}

=head2 display_command_header

Display a major command output header with double-line border

Arguments:
- $text: Header text
- $width: Optional width (default: 70)

=cut

sub display_command_header {
    my ($self, @args) = @_;
    return $self->{display}->display_command_header(@args);
}

=head2 display_section_header

Display a section/subsection header with single-line border

Arguments:
- $text: Header text
- $width: Optional width (default: 70)

=cut

sub display_section_header {
    my ($self, @args) = @_;
    return $self->{display}->display_section_header(@args);
}

=head2 display_key_value

Display a key-value pair with consistent formatting

Arguments:
- $key: Label/key text
- $value: Value text
- $key_width: Optional key column width (default: 20)

=cut

sub display_key_value {
    my ($self, @args) = @_;
    return $self->{display}->display_key_value(@args);
}

=head2 display_list_item

Display a list item (bulleted or numbered)

Arguments:
- $item: Item text
- $num: Optional number (if provided, creates numbered list)

=cut

sub display_list_item {
    my ($self, @args) = @_;
    return $self->{display}->display_list_item(@args);
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
    
    # Enable pagination for collaboration responses
    $self->{pagination_enabled} = 1;
    $self->{line_count} = 0;  # Reset line count for pagination
    print STDERR "[DEBUG][Chat] Pagination ENABLED for collaboration\n" if $self->{debug};
    
    # Display the agent's message using full markdown rendering (includes @-code to ANSI conversion)
    my $rendered_message = $self->render_markdown($message);
    
    # Display with pagination support
    my @lines = split /\n/, $rendered_message;
    print $self->colorize("CLIO: ", 'ASSISTANT');
    
    # Print first line inline with prefix
    if (@lines) {
        print shift(@lines), "\n";
        $self->{line_count}++;
    }
    
    # Print remaining lines with pagination checks
    for my $line (@lines) {
        print $line, "\n";
        $self->{line_count}++;
        
        # Check if we need to paginate
        # Pause BEFORE terminal_height to leave room for pause message
        my $pause_threshold = $self->{terminal_height} - 2;  # Leave 2 lines for pause prompt
        if ($self->{line_count} >= $pause_threshold && 
            $self->{pagination_enabled} && 
            -t STDIN) {  # Only paginate if interactive
            
            my $response = $self->pause(0);  # 0 = non-streaming mode
            if ($response eq 'Q') {
                # User quit - stop displaying
                last;
            }
            
            # Reset for next page
            $self->{line_count} = 0;
        }
    }
    
    # Display context if provided
    if ($context && length($context) > 0) {
        my $rendered_context = $self->render_markdown($context);
        my @context_lines = split /\n/, $rendered_context;
        
        print $self->colorize("Context: ", 'SYSTEM');
        if (@context_lines) {
            print shift(@context_lines), "\n";
            $self->{line_count}++;
        }
        
        for my $line (@context_lines) {
            print $line, "\n";
            $self->{line_count}++;
            
            # Pause BEFORE terminal_height to leave room for pause message
            my $pause_threshold = $self->{terminal_height} - 2;  # Leave 2 lines for pause prompt
            if ($self->{line_count} >= $pause_threshold && 
                $self->{pagination_enabled} && 
                -t STDIN) {
                
                my $response = $self->pause(0);
                if ($response eq 'Q') {
                    last;
                }
                $self->{line_count} = 0;
            }
        }
    }
    
    # Disable pagination after displaying message (user will respond)
    $self->{pagination_enabled} = 0;
    print STDERR "[DEBUG][Chat] Pagination DISABLED after collaboration message\n" if $self->{debug};
    
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
    
    # Define the collaboration prompt (enhanced format with blue indicator)
    my $collab_prompt = $self->_build_prompt('collaboration');
    
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
    
    # Refresh terminal size before pagination (handle resize)
    $self->refresh_terminal_size();
    
    # Default formatter: just print the item
    $formatter ||= sub { return $_[0] };
    
    # Calculate page size:
    # Overhead = 5 (header: blank, ===, title, ===, blank) + 4 (footer: blank, ===, status, prompt)
    # Total overhead = 9 lines
    my $overhead = 9;
    my $page_size = ($self->{terminal_height} || 24) - $overhead;
    $page_size = 10 if $page_size < 10;  # Minimum page size
    
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
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        print $self->colorize($title, 'DATA'), "\n";
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        print "\n";
        
        for my $i (0 .. $total - 1) {
            my $formatted = $formatter->($items->[$i], $i);
            print "  $formatted\n";
        }
        
        print "\n";
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        print $self->colorize("Total: $total items", 'DIM'), "\n";
        print "\n";
        return;
    }
    
    # Put terminal in raw mode for single-key input
    ReadMode('cbreak');
    
    # Switch to alternate screen buffer for clean pagination
    print "\e[?1049h";  # Enter alternate screen buffer
    
    while (1) {
        # Calculate page bounds
        my $start = $current_page * $page_size;
        my $end = $start + $page_size - 1;
        $end = $total - 1 if $end >= $total;
        
        # Clear screen and display page
        print "\e[2J\e[H";  # Clear screen + home cursor
        print "\n";
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        print $self->colorize($title, 'DATA'), "\n";
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        print "\n";
        
        # Display items for this page
        for my $i ($start .. $end) {
            my $formatted = $formatter->($items->[$i], $i);
            print "  $formatted\n";
        }
        
        print "\n";
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        
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
    
    # Exit alternate screen buffer (restores original screen)
    print "\e[?1049l";
}

=head2 handle_command

Process slash commands. Returns 0 to exit, 1 to continue

=cut

sub handle_command {
    my ($self, $command) = @_;
    
    # Delegate to CommandHandler for routing
    return $self->{command_handler}->handle_command($command);
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
    
    # Header
    push @help_lines, "";
    push @help_lines, $self->colorize("═" x 62, 'command_header');
    push @help_lines, $self->colorize("CLIO COMMANDS", 'command_header');
    push @help_lines, $self->colorize("═" x 62, 'command_header');
    push @help_lines, "";
    
    # Sections
    push @help_lines, $self->colorize("BASICS", 'command_subheader');
    push @help_lines, $self->colorize("─" x 62, 'dim');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/help, /h', 'help_command'), 'Display this help');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/exit, /quit, /q', 'help_command'), 'Exit the chat');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/clear', 'help_command'), 'Clear the screen');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/init', 'help_command'), 'Initialize CLIO for this project');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("KEYBOARD SHORTCUTS", 'command_subheader');
    push @help_lines, $self->colorize("─" x 62, 'dim');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('Left/Right', 'help_command'), 'Move cursor by character');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('Shift+Left/Right', 'help_command'), 'Move cursor by word');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('Ctrl+A / Home', 'help_command'), 'Move to start of line');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('Ctrl+E / End', 'help_command'), 'Move to end of line');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('Up/Down', 'help_command'), 'Navigate command history');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('Tab', 'help_command'), 'Auto-complete commands/paths');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('Escape', 'help_command'), 'Interrupt the agent');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('Ctrl+C', 'help_command'), 'Cancel input or interrupt');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('Ctrl+D', 'help_command'), 'Exit (on empty line)');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("API & CONFIG", 'command_subheader');
    push @help_lines, $self->colorize("─" x 62, 'dim');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/api', 'help_command'), 'API settings (model, provider, login)');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/api set model <name>', 'help_command'), 'Set AI model');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/api models', 'help_command'), 'List available models');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/config', 'help_command'), 'Global configuration');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("SESSION", 'command_subheader');
    push @help_lines, $self->colorize("─" x 62, 'dim');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/session', 'help_command'), 'Session management');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/session list', 'help_command'), 'List all sessions');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/session switch', 'help_command'), 'Switch sessions');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("FILE & GIT", 'command_subheader');
    push @help_lines, $self->colorize("─" x 62, 'dim');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/file', 'help_command'), 'File operations');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/file read <path>', 'help_command'), 'View file');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/git', 'help_command'), 'Git operations');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/git status', 'help_command'), 'Show git status');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("TODO", 'command_subheader');
    push @help_lines, $self->colorize("─" x 62, 'dim');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/todo', 'help_command'), "View agent's todo list");
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/todo add <text>', 'help_command'), 'Add todo');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/todo done <id>', 'help_command'), 'Complete todo');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("MEMORY", 'command_subheader');
    push @help_lines, $self->colorize("─" x 62, 'dim');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/memory', 'help_command'), 'View long-term memory patterns');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/memory list [type]', 'help_command'), 'List all or filtered patterns');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/memory store <type>', 'help_command'), 'Store pattern (via AI)');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/memory clear', 'help_command'), 'Clear all patterns');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("UPDATES", 'command_subheader');
    push @help_lines, $self->colorize("─" x 62, 'dim');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/update', 'help_command'), 'Show update status and help');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/update check', 'help_command'), 'Check for available updates');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/update list', 'help_command'), 'List all available versions');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/update install', 'help_command'), 'Install latest version');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/update switch <ver>', 'help_command'), 'Switch to a specific version');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("DEVELOPER", 'command_subheader');
    push @help_lines, $self->colorize("─" x 62, 'dim');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/explain [file]', 'help_command'), 'Explain code');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/review [file]', 'help_command'), 'Review code');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/test [file]', 'help_command'), 'Generate tests');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/fix <file>', 'help_command'), 'Propose fixes');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/doc <file>', 'help_command'), 'Generate docs');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/design', 'help_command'), 'Create/update project PRD');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("SKILLS & PROMPTS", 'command_subheader');
    push @help_lines, $self->colorize("─" x 62, 'dim');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/skills', 'help_command'), 'Manage custom skills');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/prompt', 'help_command'), 'Manage system prompts');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("OTHER", 'command_subheader');
    push @help_lines, $self->colorize("─" x 62, 'dim');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/billing', 'help_command'), 'API usage stats');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/context', 'help_command'), 'Manage context files');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/exec <cmd>', 'help_command'), 'Run shell command');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/style, /theme', 'help_command'), 'Appearance settings');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/debug', 'help_command'), 'Toggle debug mode');
    push @help_lines, "";
    
    # Output with pagination
    for my $line (@help_lines) {
        last unless $self->writeline($line);
    }
    
    # Reset line count after display
    $self->{line_count} = 0;
}

=head2 handle_api_command

Handle /api commands for API configuration.

New noun-first pattern:
  /api                    - Show help for /api commands
  /api show               - Display current API configuration
  /api set model <name>   - Set model (global + session by default)
  /api set model <name> --session  - Set model for this session only
  /api set provider <name> - Set provider
  /api set base <url>     - Set API base URL
  /api set key <value>    - Set API key (global only)
  /api set serpapi_key <value> - Set SerpAPI key for web search
  /api set search_engine <google|bing|duckduckgo> - Set SerpAPI search engine
  /api set search_provider <auto|serpapi|duckduckgo_direct> - Set search provider
  /api models             - List available models
  /api login              - Authenticate with GitHub Copilot
  /api logout             - Sign out from GitHub

=cut

sub handle_api_command {
    my ($self, $action, @args) = @_;
    
    $action ||= '';
    $action = lc($action);
    
    # Parse --session flag from args
    my $session_only = 0;
    @args = grep {
        if ($_ eq '--session') {
            $session_only = 1;
            0;  # Remove from args
        } else {
            1;  # Keep in args
        }
    } @args;
    
    # /api (no args) - show help
    if ($action eq '' || $action eq 'help') {
        $self->_display_api_help();
        return;
    }
    
    # /api show - display current config
    if ($action eq 'show') {
        $self->_display_api_config();
        return;
    }
    
    # /api set <setting> <value> [--session]
    if ($action eq 'set') {
        my $setting = shift @args || '';
        my $value = shift @args;
        $self->_handle_api_set($setting, $value, $session_only);
        return;
    }
    
    # /api models - list available models
    if ($action eq 'models') {
        $self->handle_models_command(@args);
        return;
    }
    
    # /api providers - list available providers
    if ($action eq 'providers') {
        $self->_display_api_providers(@args);
        return;
    }
    
    # /api login - GitHub Copilot authentication
    if ($action eq 'login') {
        $self->handle_login_command(@args);
        return;
    }
    
    # /api logout - sign out
    if ($action eq 'logout') {
        $self->handle_logout_command(@args);
        return;
    }
    
    # BACKWARD COMPATIBILITY: Support old syntax during transition
    # /api key <value> -> /api set key <value>
    if ($action eq 'key') {
        $self->display_system_message("Note: Use '/api set key <value>' (new syntax)");
        $self->_handle_api_set('key', $args[0], 0);
        return;
    }
    # /api base <url> -> /api set base <url>
    if ($action eq 'base') {
        $self->display_system_message("Note: Use '/api set base <url>' (new syntax)");
        $self->_handle_api_set('base', $args[0], $session_only);
        return;
    }
    # /api model <name> -> /api set model <name>
    if ($action eq 'model') {
        $self->display_system_message("Note: Use '/api set model <name>' (new syntax)");
        $self->_handle_api_set('model', $args[0], $session_only);
        return;
    }
    # /api provider <name> -> /api set provider <name>
    if ($action eq 'provider') {
        $self->display_system_message("Note: Use '/api set provider <name>' (new syntax)");
        $self->_handle_api_set('provider', $args[0], $session_only);
        return;
    }
    
    # Unknown action
    $self->display_error_message("Unknown action: /api $action");
    $self->_display_api_help();
}

=head2 _display_api_help

Display help for /api commands

=cut

sub _display_api_help {
    my ($self) = @_;
    
    $self->display_command_header("API COMMANDS");
    
    $self->display_list_item("/api show - Display current API configuration");
    $self->display_list_item("/api set model <name> - Set AI model");
    $self->display_list_item("/api set provider <name> - Set provider (github_copilot, openai, etc.)");
    $self->display_list_item("/api set base <url> - Set API base URL");
    $self->display_list_item("/api set key <value> - Set API key (global only)");
    $self->display_list_item("/api providers - Show available providers and their details");
    $self->display_list_item("/api models - List available models");
    $self->display_list_item("/api login - Authenticate with GitHub Copilot");
    $self->display_list_item("/api logout - Sign out from GitHub");
    
    print "\n";
    $self->display_section_header("WEB SEARCH CONFIGURATION");
    $self->display_list_item("/api set serpapi_key <key> - Set SerpAPI key (serpapi.com)");
    $self->display_list_item("/api set search_engine <name> - Set engine (google|bing|duckduckgo)");
    $self->display_list_item("/api set search_provider <name> - Set provider (auto|serpapi|duckduckgo_direct)");
    
    print "\n";
    $self->display_section_header("FLAGS");
    print "  --session    Save setting to this session only (not global)\n";
    print "\n";
    $self->display_section_header("EXAMPLES");
    print "  /api set model claude-sonnet-4          # Global + session\n";
    print "  /api set model gpt-4o --session         # This session only\n";
    print "  /api set provider github_copilot        # Switch provider\n";
    print "  /api set serpapi_key YOUR_KEY           # Enable reliable web search\n";
    print "\n";
}

=head2 _display_api_config

Display current API configuration

=cut

sub _display_api_config {
    my ($self) = @_;
    
    my $key = $self->{config}->get('api_key');
    my $base = $self->{config}->get('api_base');
    my $model = $self->{config}->get('model');
    my $provider = $self->{config}->get('provider');
    
    # Determine authentication status
    my $auth_status = '[NOT SET]';
    if ($key && length($key) > 0) {
        $auth_status = '[SET]';
    } else {
        # Check if using GitHub Copilot auth
        if ($provider && $provider eq 'github_copilot') {
            eval {
                require CLIO::Core::GitHubAuth;
                my $gh_auth = CLIO::Core::GitHubAuth->new(debug => 0);
                my $token = $gh_auth->get_copilot_token();
                if ($token) {
                    $auth_status = '[TOKEN]';
                } else {
                    $auth_status = '[NO TOKEN - use /api login]';
                }
            };
        }
    }
    
    $self->display_command_header("API CONFIGURATION");
    
    $self->display_key_value("Provider", $provider || '[not set]');
    $self->display_key_value("API Key", $auth_status);
    $self->display_key_value("API Base", $base || '[default]');
    $self->display_key_value("Model", $model || '[default]');
    
    # Show session-specific overrides if any
    if ($self->{session} && $self->{session}->state()) {
        my $state = $self->{session}->state();
        my $api_config = $state->{api_config} || {};
        
        if (%$api_config) {
            print "\n";
            $self->display_section_header("SESSION OVERRIDES");
            for my $key (sort keys %$api_config) {
                $self->display_key_value($key, $api_config->{$key});
            }
            print "\n";
        }
    }
}

=head2 _display_api_providers

Display available providers and their configurations.
Supports optional provider name argument for detailed info.

Usage:
  /api providers           - Show all providers
  /api providers openai   - Show details for openai

=cut

sub _display_api_providers {
    my ($self, $provider_name) = @_;
    
    require CLIO::Providers;
    
    print "\n";
    print $self->colorize("API PROVIDERS", 'DATA'), "\n";
    print $self->colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", 'DIM'), "\n\n";
    
    # If specific provider requested, show details
    if ($provider_name) {
        $self->_show_provider_details($provider_name);
        return;
    }
    
    # Get current provider for comparison
    my $current_provider = $self->{config}->get('provider') if $self->{config};
    
    # Show all providers in organized table format
    my @providers = CLIO::Providers::list_providers();
    
    # Calculate column width based on longest provider name
    my $max_provider_length = 0;
    for my $prov_name (@providers) {
        my $prov = CLIO::Providers::get_provider($prov_name);
        next unless $prov;
        my $display_name = $prov->{name} || $prov_name;
        $max_provider_length = length($display_name) if length($display_name) > $max_provider_length;
    }
    
    # Table header
    print $self->colorize("PROVIDER", 'LABEL');
    print " " x ($max_provider_length - 8 + 4);  # Pad to align with data rows
    print $self->colorize("DEFAULT MODEL", 'LABEL');
    print "\n";
    print $self->colorize("─" x 77, 'DIM'), "\n";
    
    for my $prov_name (@providers) {
        my $prov = CLIO::Providers::get_provider($prov_name);
        next unless $prov;
        
        my $display_name = $prov->{name} || $prov_name;
        my $is_current = ($current_provider && $prov_name eq $current_provider) ? 1 : 0;
        
        # Indent all rows consistently (2 spaces)
        print "  ";
        
        # Provider name with padding to align model column
        print $self->colorize(sprintf("%-" . $max_provider_length . "s", $display_name), 'PROMPT');
        print "  ";
        
        # Model
        print $prov->{model} || 'N/A';
        print "\n";
    }
    
    print "\n";
    print $self->colorize("LEARN MORE", 'DATA'), "\n";
    print $self->colorize("─" x 77, 'DIM'), "\n";
    print "  /api providers <name>   - Show setup instructions for a specific provider\n";
    print "\n";
    print $self->colorize("EXAMPLES", 'DATA'), "\n";
    print $self->colorize("─" x 77, 'DIM'), "\n";
    print "  /api set provider github_copilot    - Setup GitHub Copilot\n";
    print "  /api set provider openai            - Switch to OpenAI\n";
    print "\n";
}


=head2 _show_provider_details

Display detailed information about a specific provider

=cut

sub _show_provider_details {
    my ($self, $provider_name) = @_;
    
    require CLIO::Providers;
    
    my $prov = CLIO::Providers::get_provider($provider_name);
    
    unless ($prov) {
        $self->display_error_message("Provider not found: $provider_name");
        print "Use '/api providers' to see available providers\n";
        return;
    }
    
    my $display_name = $prov->{name} || $provider_name;
    
    print "\n";
    print $self->colorize($display_name, 'DATA'), "\n";
    print $self->colorize("─" x 90, 'DIM'), "\n\n";
    
    # Basic information
    print $self->colorize("OVERVIEW", 'LABEL'), "\n";
    printf "  ID:          %s\n", $provider_name;
    printf "  Model:       %s\n", $prov->{model} || 'N/A';
    printf "  API Base:    %s\n", $prov->{api_base} || '[not specified]';
    
    # Authentication
    my $auth = $prov->{requires_auth} || 'none';
    my $auth_text = $self->_format_auth_requirement($auth);
    print "\n";
    print $self->colorize("AUTHENTICATION", 'LABEL'), "\n";
    printf "  Method:      %s\n", $auth_text;
    
    if ($auth eq 'copilot') {
        print "\n";
        print $self->colorize("  Setup Steps", 'PROMPT'), "\n";
        print "    1. Run: /api login\n";
        print "    2. Follow the browser authentication flow\n";
        print "    3. Token will be stored securely\n";
    } elsif ($auth eq 'apikey') {
        print "\n";
        print $self->colorize("  Setup Steps", 'PROMPT'), "\n";
        print "    1. Obtain API key from the provider website\n";
        print "    2. Set it with: /api set key <your-api-key>\n";
        print "    3. Key is stored globally (not in session)\n";
    } elsif ($auth eq 'none') {
        print "\n";
        print $self->colorize("  Status", 'SUCCESS'), "\n";
        print "    Ready to use - no authentication needed\n";
    }
    
    # Capabilities
    print "\n";
    print $self->colorize("CAPABILITIES", 'LABEL'), "\n";
    my $tools_str = $prov->{supports_tools} ? "Yes" : "No";
    my $stream_str = $prov->{supports_streaming} ? "Yes" : "No";
    printf "  Functions:   %s (tool calling)\n", $tools_str;
    printf "  Streaming:   %s\n", $stream_str;
    
    # Quick start
    print "\n";
    print $self->colorize("QUICK START", 'LABEL'), "\n";
    print "  1. Switch to this provider:\n";
    print "     /api set provider $provider_name\n";
    print "\n";
    if ($auth eq 'apikey' || $auth eq 'copilot') {
        print "  2. Authenticate (if not done already):\n";
        print "     /api login\n";
        print "\n";
        print "  3. Verify setup:\n";
        print "     /api show\n";
    } else {
        print "  2. Verify setup:\n";
        print "     /api show\n";
    }
    
    print "\n";
}

=head2 _format_auth_requirement

Format authentication requirement as human-readable text

=cut

sub _format_auth_requirement {
    my ($self, $auth_type) = @_;
    
    return 'None (local)' if !$auth_type || $auth_type eq 'none';
    return 'GitHub OAuth' if $auth_type eq 'copilot';
    return 'API Key' if $auth_type eq 'apikey';
    return $auth_type;  # Fallback to raw value
}

=head2 _get_setup_complexity

Format setup complexity indicator for provider list

Returns a colored label indicating how easy it is to set up the provider

=cut

sub _get_setup_complexity {
    my ($self, $auth_type) = @_;
    
    if (!$auth_type || $auth_type eq 'none') {
        return $self->colorize("Ready", 'SUCCESS');
    } elsif ($auth_type eq 'copilot') {
        return $self->colorize("Browser", 'WARNING');
    } elsif ($auth_type eq 'apikey') {
        return $self->colorize("Key Needed", 'WARNING');
    }
    return $self->colorize("Setup", 'DATA');
}

=head2 _format_provider_features

Format provider features for compact display

=cut

sub _format_provider_features {
    my ($self, $prov) = @_;
    
    my @features;
    push @features, 'Tools' if $prov->{supports_tools};
    push @features, 'Stream' if $prov->{supports_streaming};
    
    return join(', ', @features) ? '[' . join(', ', @features) . ']' : '';
}

=head2 _handle_api_set

Handle /api set <setting> <value> [--session]

=cut

sub _handle_api_set {
    my ($self, $setting, $value, $session_only) = @_;
    
    $setting = lc($setting || '');
    
    unless ($setting) {
        $self->display_error_message("Usage: /api set <setting> <value>");
        print "Settings: model, provider, base, key, serpapi_key, search_engine, search_provider\n";
        return;
    }
    
    unless (defined $value && $value ne '') {
        $self->display_error_message("Usage: /api set $setting <value>");
        return;
    }
    
    # Handle each setting type
    if ($setting eq 'key') {
        # API key is always global (secrets shouldn't be session-scoped)
        if ($session_only) {
            $self->display_system_message("Note: API key is always global (ignoring --session)");
        }
        
        $self->{config}->set('api_key', $value);
        
        if ($self->{config}->save()) {
            $self->display_system_message("API key set and saved");
        } else {
            $self->display_system_message("API key set (warning: failed to save)");
        }
        
        $self->_reinit_api_manager();
    }
    elsif ($setting eq 'serpapi_key' || $setting eq 'serpapi') {
        # SerpAPI key for web search (always global)
        if ($session_only) {
            $self->display_system_message("Note: API keys are always global (ignoring --session)");
        }
        
        $self->{config}->set('serpapi_key', $value);
        
        if ($self->{config}->save()) {
            my $display_key = substr($value, 0, 8) . '...' . substr($value, -4);
            $self->display_system_message("SerpAPI key set: $display_key (saved)");
            $self->display_system_message("Web search will now use SerpAPI for reliable results");
        } else {
            $self->display_system_message("SerpAPI key set (warning: failed to save)");
        }
    }
    elsif ($setting eq 'search_engine') {
        # SerpAPI engine selection
        my @valid = qw(google bing duckduckgo);
        unless (grep { $_ eq lc($value) } @valid) {
            $self->display_error_message("Invalid search engine: $value");
            $self->display_system_message("Valid engines: " . join(", ", @valid));
            return;
        }
        
        $self->{config}->set('search_engine', lc($value));
        
        if ($self->{config}->save()) {
            $self->display_system_message("Search engine set to: $value (saved)");
            $self->display_system_message("SerpAPI will now use $value for searches");
        } else {
            $self->display_system_message("Search engine set (warning: failed to save)");
        }
    }
    elsif ($setting eq 'search_provider') {
        # Web search provider preference
        my @valid = qw(auto serpapi duckduckgo_direct);
        unless (grep { $_ eq lc($value) } @valid) {
            $self->display_error_message("Invalid search provider: $value");
            $self->display_system_message("Valid providers: " . join(", ", @valid));
            return;
        }
        
        $self->{config}->set('search_provider', lc($value));
        
        if ($self->{config}->save()) {
            $self->display_system_message("Search provider set to: $value (saved)");
        } else {
            $self->display_system_message("Search provider set (warning: failed to save)");
        }
    }
    elsif ($setting eq 'base') {
        $self->_set_api_setting('api_base', $value, $session_only);
        $self->display_system_message("API base set to: $value" . ($session_only ? " (session only)" : " (saved)"));
        $self->_reinit_api_manager();
    }
    elsif ($setting eq 'model') {
        $self->_set_api_setting('model', $value, $session_only);
        $self->display_system_message("Model set to: $value" . ($session_only ? " (session only)" : " (saved)"));
        $self->_reinit_api_manager();
    }
    elsif ($setting eq 'provider') {
        # Provider setting uses Config's set_provider for validation
        if ($session_only) {
            # Session-only: just update session state, don't touch global
            if ($self->{session} && $self->{session}->state()) {
                my $state = $self->{session}->state();
                $state->{api_config} ||= {};
                $state->{api_config}{provider} = $value;
                $self->{session}->save();
                $self->display_system_message("Provider set to: $value (session only)");
            }
        } else {
            # Global: use Config's set_provider
            if ($self->{config}->set_provider($value)) {
                my $config = $self->{config}->get_all();
                
                if ($self->{config}->save()) {
                    $self->display_system_message("Switched to provider: $value (saved)");
                    $self->display_system_message("  API Base: " . $config->{api_base} . " (from provider)");
                    $self->display_system_message("  Model: " . $config->{model} . " (from provider)");
                } else {
                    $self->display_system_message("Switched to provider: $value (warning: failed to save)");
                }
                
                # Offer GitHub login if needed
                if ($value eq 'github_copilot') {
                    $self->_check_github_auth();
                }
            }
        }
        $self->_reinit_api_manager();
    }
    else {
        $self->display_error_message("Unknown setting: $setting");
        print "Valid settings: model, provider, base, key, serpapi_key, search_engine, search_provider\n";
    }
}

=head2 _set_api_setting

Set an API setting, optionally session-only

=cut

sub _set_api_setting {
    my ($self, $key, $value, $session_only) = @_;
    
    if ($session_only) {
        # Session-only: just update session state
        if ($self->{session} && $self->{session}->state()) {
            my $state = $self->{session}->state();
            $state->{api_config} ||= {};
            $state->{api_config}{$key} = $value;
            $self->{session}->save();
        }
    } else {
        # Global + session: update config and save
        $self->{config}->set($key, $value);
        $self->{config}->save();
        
        # Also save to session for resume
        if ($self->{session} && $self->{session}->state()) {
            my $state = $self->{session}->state();
            $state->{api_config} ||= {};
            $state->{api_config}{$key} = $value;
            $self->{session}->save();
        }
    }
}

=head2 _reinit_api_manager

Reinitialize APIManager after config changes

=cut

sub _reinit_api_manager {
    my ($self) = @_;
    
    print STDERR "[DEBUG][Chat] Re-initializing APIManager after config change\n" if $self->{debug};
    
    require CLIO::Core::APIManager;
    my $new_api = CLIO::Core::APIManager->new(
        debug => $self->{debug},
        session => $self->{session}->state(),
        config => $self->{config}
    );
    $self->{ai_agent}->{api} = $new_api;
    
    # BUGFIX: Also update the orchestrator's api_manager reference
    # The orchestrator holds its own reference to the APIManager, which becomes stale
    # after config changes if we don't update it here.
    if ($self->{ai_agent}->{orchestrator}) {
        $self->{ai_agent}->{orchestrator}->{api_manager} = $new_api;
        print STDERR "[DEBUG][Chat] Orchestrator's api_manager updated after config change\n" if $self->{debug};
    }
}

=head2 _check_github_auth

Check GitHub authentication and offer to login

=cut

sub _check_github_auth {
    my ($self) = @_;
    
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
            $self->handle_login_command();
        } else {
            $self->display_system_message("You can login later with: /api login");
        }
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
        print $self->colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", 'DIM'), "\n\n";
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
    
    $self->display_command_header("GLOBAL CONFIGURATION");
    
    # API Settings
    $self->display_section_header("API Settings");
    
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
    
    $self->display_key_value("Provider", $provider, 18);
    $self->display_key_value("Model", $model, 18);
    $self->display_key_value("API Key", $auth_status, 18);
    
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
    $self->display_key_value("API Base URL", $display_url, 18);
    
    # UI Settings
    print "\n";
    $self->display_section_header("UI Settings");
    my $style = $self->{config}->get('style') || 'default';
    my $theme = $self->{config}->get('theme') || 'default';
    my $loglevel = $self->{config}->get('loglevel') || $self->{config}->get('log_level') || 'WARNING';
    
    $self->display_key_value("Color Style", $style, 18);
    $self->display_key_value("Output Theme", $theme, 18);
    $self->display_key_value("Log Level", $loglevel, 18);
    
    # Paths
    print "\n";
    $self->display_section_header("Paths & Files");
    require Cwd;
    my $workdir = $self->{config}->get('working_directory') || Cwd::getcwd();
    my $config_file = $self->{config}->{config_file};
    
    $self->display_key_value("Working Dir", $workdir, 18);
    $self->display_key_value("Config File", $config_file, 18);
    $self->display_key_value("Sessions Dir", File::Spec->catdir('.', 'sessions'), 18);
    $self->display_key_value("Styles Dir", File::Spec->catdir('.', 'styles'), 18);
    $self->display_key_value("Themes Dir", File::Spec->catdir('.', 'themes'), 18);
    
    print "\n";
    $self->display_info_message("Use '/config save' to persist changes");
    print "\n";
}

=head2 show_session_config

Display session-specific configuration

=cut

sub show_session_config {
    my ($self) = @_;
    
    my $state = $self->{session}->state();
    
    print "\n", $self->colorize("SESSION CONFIGURATION", 'DATA'), "\n";
    print $self->colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", 'DIM'), "\n\n";
    
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

Handle /config commands for global configuration.

New noun-first pattern:
  /config                 - Show help for /config commands
  /config show            - Display global configuration
  /config set <key> <val> - Set a config value
  /config save            - Save current configuration
  /config workdir [path]  - Get/set working directory
  /config loglevel [level] - Get/set log level

=cut

sub handle_config_command {
    my ($self, @args) = @_;
    
    unless ($self->{config}) {
        $self->display_error_message("Configuration system not available");
        return;
    }
    
    my $action = $args[0] || '';
    my $arg1 = $args[1] || '';
    my $arg2 = $args[2] || '';
    
    $action = lc($action);
    
    # /config (no args) - show help
    if ($action eq '' || $action eq 'help') {
        $self->_display_config_help();
        return;
    }
    
    # /config show - display global config
    if ($action eq 'show') {
        $self->show_global_config();
        return;
    }
    
    # /config set <key> <value> - set a config value
    if ($action eq 'set') {
        $self->_handle_config_set($arg1, $arg2);
        return;
    }
    
    # /config save - save configuration
    if ($action eq 'save') {
        my $current_style = $self->{theme_mgr}->get_current_style();
        my $current_theme = $self->{theme_mgr}->get_current_theme();
        
        $self->{config}->set('style', $current_style);
        $self->{config}->set('theme', $current_theme);
        require Cwd;
        $self->{config}->set('working_directory', Cwd::getcwd());
        
        if ($self->{config}->save()) {
            $self->display_system_message("Configuration saved successfully");
        } else {
            $self->display_error_message("Failed to save configuration");
        }
        return;
    }
    
    # /config load - reload configuration
    if ($action eq 'load') {
        $self->{config}->load();
        $self->display_system_message("Configuration reloaded");
        return;
    }
    
    # /config workdir [path] - get/set working directory
    if ($action eq 'workdir') {
        if ($arg1) {
            # Set working directory
            my $dir = $arg1;
            $dir =~ s/^~/$ENV{HOME}/;  # Expand tilde
            
            unless (-d $dir) {
                $self->display_error_message("Directory does not exist: $dir");
                return;
            }
            
            require Cwd;
            $dir = Cwd::abs_path($dir);
            
            if ($self->{session} && $self->{session}->state()) {
                my $state = $self->{session}->state();
                $state->{working_directory} = $dir;
                $self->{session}->save();
                $self->display_system_message("Working directory set to: $dir");
            } else {
                $self->display_error_message("No active session");
            }
        } else {
            # Show working directory
            require Cwd;
            my $dir = '.';
            if ($self->{session} && $self->{session}->state()) {
                $dir = $self->{session}->state()->{working_directory} || Cwd::getcwd();
            }
            $self->display_system_message("Working directory: $dir");
        }
        return;
    }
    
    # /config loglevel [level] - get/set log level
    if ($action eq 'loglevel') {
        $self->handle_loglevel_command($arg1);
        return;
    }
    
    # Unknown action
    $self->display_error_message("Unknown action: /config $action");
    $self->_display_config_help();
}

=head2 _display_config_help

Display help for /config commands

=cut

sub _display_config_help {
    my ($self) = @_;
    
    $self->display_command_header("CONFIG COMMANDS");
    
    $self->display_list_item("/config show - Display global configuration");
    $self->display_list_item("/config set <key> <value> - Set a configuration value");
    $self->display_list_item("/config save - Save current configuration to disk");
    $self->display_list_item("/config load - Reload configuration from disk");
    $self->display_list_item("/config workdir [path] - Get or set working directory");
    $self->display_list_item("/config loglevel [level] - Get or set log level");
    
    print "\n";
    $self->display_section_header("SETTABLE KEYS");
    print "  style                    UI color scheme (default, dark, light, amber-terminal, etc.)\n";
    print "  theme                    Banner and template theme\n";
    print "  workdir                  Current working directory path\n";
    print "  terminal_passthrough     Force direct terminal access for all commands (true/false)\n";
    print "  terminal_autodetect      Auto-detect interactive commands for passthrough (true/false)\n";
    
    print "\n";
    $self->display_section_header("EXAMPLES");
    print "  /config set style dark                      # Switch to dark color scheme\n";
    print "  /config set theme photon                    # Use photon theme\n";
    print "  /config set workdir ~/projects              # Change working directory\n";
    print "  /config set terminal_passthrough true       # Enable passthrough for all commands\n";
    print "  /config set terminal_autodetect false       # Disable interactive command detection\n";
    print "  /config workdir                             # Show current working directory\n";
    
    print "\n";
    $self->display_info_message("For API settings, use /api set");
    print "\n";
    
    print "\n";
    $self->display_section_header("TERMINAL SETTINGS");
    print "  terminal_passthrough: When enabled, commands execute with direct terminal access.\n";
    print "    - User can interact (editor, GPG prompts, etc.)\n";
    print "    - Agent sees exit codes but no output\n";
    print "    - Default: false (use auto-detection instead)\n";
    print "\n";
    print "  terminal_autodetect: When enabled, interactive commands are detected automatically.\n";
    print "    - Detects: git commit (no -m), vim, nano, GPG, ssh, etc.\n";
    print "    - Uses passthrough only for detected commands\n";
    print "    - Default: true (smart detection enabled)\n";
    print "\n";
}

=head2 _handle_config_set

Handle /config set <key> <value>

=cut

sub _handle_config_set {
    my ($self, $key, $value) = @_;
    
    $key = lc($key || '');
    
    unless ($key) {
        $self->display_error_message("Usage: /config set <key> <value>");
        print "Keys: style, theme, working_directory, terminal_passthrough, terminal_autodetect\n";
        return;
    }
    
    unless (defined $value && $value ne '') {
        $self->display_error_message("Usage: /config set $key <value>");
        return;
    }
    
    # Validate allowed keys
    my %allowed = (
        style => 1,
        theme => 1,
        working_directory => 1,
        terminal_passthrough => 1,
        terminal_autodetect => 1,
    );
    
    unless ($allowed{$key}) {
        $self->display_error_message("Unknown config key: $key");
        print "Allowed keys: " . join(', ', sort keys %allowed) . "\n";
        return;
    }
    
    # Handle boolean values for terminal settings
    if ($key =~ /^terminal_/) {
        # Normalize boolean values
        if ($value =~ /^(true|1|yes|on)$/i) {
            $value = 1;
        } elsif ($value =~ /^(false|0|no|off)$/i) {
            $value = 0;
        } else {
            $self->display_error_message("Invalid boolean value for $key: $value");
            print "Use: true/false, 1/0, yes/no, on/off\n";
            return;
        }
        
        # Provide helpful feedback about what this setting does
        if ($key eq 'terminal_passthrough') {
            if ($value) {
                $self->display_info_message("Passthrough mode: All commands will execute with direct terminal access");
                $self->display_info_message("Agent will see exit codes but not command output");
            } else {
                $self->display_info_message("Passthrough mode disabled: Output will be captured for agent");
                $self->display_info_message("Auto-detection (terminal_autodetect) may still enable passthrough for interactive commands");
            }
        } elsif ($key eq 'terminal_autodetect') {
            if ($value) {
                $self->display_info_message("Auto-detect enabled: Interactive commands (git commit, vim, GPG) will use passthrough automatically");
            } else {
                $self->display_info_message("Auto-detect disabled: All commands will capture output unless terminal_passthrough is enabled");
            }
        }
    }
    
    # Set the value
    $self->{config}->set($key, $value);
    
    if ($self->{config}->save()) {
        $self->display_system_message("$key set to: $value (saved)");
    } else {
        $self->display_system_message("$key set to: $value (warning: failed to save)");
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
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
    print $self->colorize("GITHUB COPILOT AUTHENTICATION", 'DATA'), "\n";
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
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
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
    print $self->colorize("SUCCESS!", 'PROMPT'), "\n";
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
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
    
    # Reload APIManager to pick up new tokens
    print STDERR "[DEBUG][Chat] Reloading APIManager after /login to pick up new tokens\n" if $self->{debug};
    require CLIO::Core::APIManager;
    my $new_api = CLIO::Core::APIManager->new(
        debug => $self->{debug},
        session => $self->{session}->state(),
        config => $self->{config}
    );
    $self->{ai_agent}->{api} = $new_api;
    
    # BUGFIX: Also update the orchestrator's api_manager reference
    # The orchestrator holds its own reference to the APIManager, which becomes stale
    # after login if we don't update it here.
    if ($self->{ai_agent}->{orchestrator}) {
        $self->{ai_agent}->{orchestrator}->{api_manager} = $new_api;
        print STDERR "[DEBUG][Chat] Orchestrator's api_manager updated after /login\n" if $self->{debug};
    }
    
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

=head2 handle_file_command

Handle /file commands for file operations.

New noun-first pattern:
  /file                   - Show help for /file commands
  /file read <path>       - Read and display file (with markdown rendering)
  /file edit <path>       - Open file in $EDITOR
  /file list [path]       - List directory contents

=cut

sub handle_file_command {
    my ($self, $action, @args) = @_;
    
    $action ||= '';
    $action = lc($action);
    
    # /file (no args) - show help
    if ($action eq '' || $action eq 'help') {
        $self->_display_file_help();
        return;
    }
    
    # /file read <path> - read and display file
    if ($action eq 'read' || $action eq 'view' || $action eq 'cat') {
        $self->handle_read_command(@args);
        return;
    }
    
    # /file edit <path> - edit file
    if ($action eq 'edit') {
        $self->handle_edit_command(join(' ', @args));
        return;
    }
    
    # /file list [path] - list directory
    if ($action eq 'list' || $action eq 'ls') {
        my $path = join(' ', @args) || '.';
        $self->_list_directory($path);
        return;
    }
    
    # Unknown action
    $self->display_error_message("Unknown action: /file $action");
    $self->_display_file_help();
}

=head2 _display_file_help

Display help for /file commands

=cut

sub _display_file_help {
    my ($self) = @_;
    
    print "\n";
    print $self->colorize("FILE COMMANDS", 'DATA'), "\n";
    print $self->colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", 'DIM'), "\n\n";
    
    print $self->colorize("  /file read <path>", 'PROMPT'), "       Read and display file (markdown rendered)\n";
    print $self->colorize("  /file edit <path>", 'PROMPT'), "       Open file in external editor (\$EDITOR)\n";
    print $self->colorize("  /file list [path]", 'PROMPT'), "       List directory contents (default: .)\n";
    
    print "\n";
    print $self->colorize("EXAMPLES", 'DATA'), "\n";
    print $self->colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", 'DIM'), "\n";
    print "  /file read README.md                 # View a file\n";
    print "  /file edit lib/CLIO/UI/Chat.pm       # Edit a file\n";
    print "  /file list lib/CLIO/                 # List directory\n";
}

=head2 _list_directory

List directory contents

=cut

sub _list_directory {
    my ($self, $path) = @_;
    
    # Resolve path
    unless (File::Spec->file_name_is_absolute($path)) {
        my $working_dir = $self->{session} ? 
            ($self->{session}->state()->{working_directory} || '.') : '.';
        $path = File::Spec->catfile($working_dir, $path);
    }
    
    unless (-d $path) {
        $self->display_error_message("Not a directory: $path");
        return;
    }
    
    opendir(my $dh, $path) or do {
        $self->display_error_message("Cannot read directory: $!");
        return;
    };
    
    my @entries = sort grep { !/^\.\.?$/ } readdir($dh);
    closedir($dh);
    
    print "\n";
    print $self->colorize("Directory: $path", 'DATA'), "\n";
    print $self->colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", 'DIM'), "\n\n";
    
    my @dirs;
    my @files;
    
    for my $entry (@entries) {
        my $full_path = File::Spec->catfile($path, $entry);
        if (-d $full_path) {
            push @dirs, $entry;
        } else {
            push @files, $entry;
        }
    }
    
    # Show directories first
    for my $dir (@dirs) {
        print "  ", $self->colorize("$dir/", 'USER'), "\n";
    }
    
    # Then files
    for my $file (@files) {
        print "  $file\n";
    }
    
    print "\n";
    $self->display_system_message(scalar(@dirs) . " directories, " . scalar(@files) . " files");
}

=head2 handle_git_command

Handle /git commands for git operations.

New noun-first pattern:
  /git                    - Show help for /git commands
  /git status             - Show git status
  /git diff [file]        - Show git diff
  /git log [n]            - Show recent commits
  /git commit [message]   - Stage and commit changes

=cut

sub handle_git_command {
    my ($self, $action, @args) = @_;
    
    $action ||= '';
    $action = lc($action);
    
    # /git (no args) - show help
    if ($action eq '' || $action eq 'help') {
        $self->_display_git_help();
        return;
    }
    
    # /git status
    if ($action eq 'status' || $action eq 'st') {
        $self->handle_status_command(@args);
        return;
    }
    
    # /git diff [file]
    if ($action eq 'diff') {
        $self->handle_diff_command(@args);
        return;
    }
    
    # /git log [n]
    if ($action eq 'log') {
        $self->handle_gitlog_command(@args);
        return;
    }
    
    # /git commit [message]
    if ($action eq 'commit') {
        $self->handle_commit_command(@args);
        return;
    }
    
    # Unknown action
    $self->display_error_message("Unknown action: /git $action");
    $self->_display_git_help();
}

=head2 _display_git_help

Display help for /git commands

=cut

sub _display_git_help {
    my ($self) = @_;
    
    $self->display_command_header("GIT COMMANDS");
    
    $self->display_list_item("/git status - Show git status");
    $self->display_list_item("/git diff [file] - Show git diff");
    $self->display_list_item("/git log [n] - Show recent commits (default: 10)");
    $self->display_list_item("/git commit [msg] - Stage and commit changes");
    
    print "\n";
    $self->display_section_header("EXAMPLES");
    print "  /git status                          # See changes\n";
    print "  /git diff lib/CLIO/UI/Chat.pm        # Diff specific file\n";
    print "  /git log 5                           # Last 5 commits\n";
    print "  /git commit \"fix: resolve bug\"       # Commit with message\n";
    print "\n";
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
    my ($self, @args) = @_;
    return $self->{display}->display_usage_summary(@args);
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
        
        print $self->colorize("[WARN] Premium Model Usage:", 'LABEL'), "\n";
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

=head2 handle_memory_command

Manage long-term memory (LTM) patterns for the project.

Usage:
  /memory [list|ls] [type]     - List all patterns (optionally filter by type)
  /memory store <type> [data]  - Store a new pattern
  /memory clear                - Clear all LTM patterns

Types: discovery, solution, pattern, workflow, failure, rule

=cut

sub handle_memory_command {
    my ($self, @args) = @_;
    
    unless ($self->{session}) {
        $self->display_error_message("No active session");
        return;
    }
    
    # Get LTM from session
    my $ltm = eval { $self->{session}->get_long_term_memory() };
    if ($@ || !$ltm) {
        $self->display_error_message("Long-term memory not available: $@");
        return;
    }
    
    # Parse subcommand
    my $subcmd = @args ? lc($args[0]) : 'list';
    
    if ($subcmd eq 'list' || $subcmd eq 'ls' || $subcmd eq '') {
        # List patterns (optionally filter by type)
        my $filter_type = $args[1] ? lc($args[1]) : undef;
        
        # Gather all patterns
        my @all_patterns;
        
        # Discoveries
        my $discoveries = eval { $ltm->query_discoveries() } || [];
        for my $item (@$discoveries) {
            push @all_patterns, { type => 'discovery', data => $item };
        }
        
        # Solutions
        my $solutions = eval { $ltm->query_solutions() } || [];
        for my $item (@$solutions) {
            push @all_patterns, { type => 'solution', data => $item };
        }
        
        # Patterns
        my $patterns = eval { $ltm->query_patterns() } || [];
        for my $item (@$patterns) {
            push @all_patterns, { type => 'pattern', data => $item };
        }
        
        # Workflows
        my $workflows = eval { $ltm->query_workflows() } || [];
        for my $item (@$workflows) {
            push @all_patterns, { type => 'workflow', data => $item };
        }
        
        # Failures
        my $failures = eval { $ltm->query_failures() } || [];
        for my $item (@$failures) {
            push @all_patterns, { type => 'failure', data => $item };
        }
        
        # Context rules
        my $rules = eval { $ltm->query_context_rules() } || [];
        for my $item (@$rules) {
            push @all_patterns, { type => 'rule', data => $item };
        }
        
        # Filter by type if specified
        if ($filter_type) {
            @all_patterns = grep { $_->{type} eq $filter_type } @all_patterns;
        }
        
        # Display
        $self->display_command_header("LONG-TERM MEMORY PATTERNS");
        
        if (@all_patterns == 0) {
            $self->display_info_message("No patterns stored yet");
            print "\n";
            print "Use /memory store <type> to add patterns:\n";
            $self->display_list_item("Types: discovery, solution, pattern, workflow, failure, rule");
            print "\n";
        } else {
            printf "Total: %d pattern%s", scalar(@all_patterns), (@all_patterns == 1 ? '' : 's');
            print " (filtered by: $filter_type)" if $filter_type;
            print "\n\n";
            
            for my $entry (@all_patterns) {
                my $type = uc($entry->{type});
                my $data = $entry->{data};
                
                print $self->colorize("[$type] ", 'command_subheader');
                print $self->colorize($data->{title} || 'Untitled', 'command_value'), "\n";
                
                if ($entry->{type} eq 'discovery') {
                    print "  " . ($data->{content} || 'No content') . "\n";
                    print $self->colorize("  Context: " . ($data->{context} || 'None'), 'muted'), "\n" if $data->{context};
                }
                elsif ($entry->{type} eq 'solution') {
                    print "  Problem: " . ($data->{problem} || 'Not specified') . "\n";
                    print "  Solution: " . ($data->{solution} || 'Not specified') . "\n";
                }
                elsif ($entry->{type} eq 'pattern') {
                    print "  " . ($data->{pattern} || 'No pattern') . "\n";
                    print $self->colorize("  Usage: " . ($data->{usage} || 'None'), 'muted'), "\n" if $data->{usage};
                }
                elsif ($entry->{type} eq 'workflow') {
                    my $steps = $data->{steps} || [];
                    if (ref($steps) eq 'ARRAY' && @$steps) {
                        my $num = 1;
                        for my $step (@$steps) {
                            $self->display_list_item($step, $num);
                            $num++;
                        }
                    }
                }
                elsif ($entry->{type} eq 'failure') {
                    print "  Mistake: " . ($data->{mistake} || 'Not specified') . "\n";
                    print "  Lesson: " . ($data->{lesson} || 'Not specified') . "\n";
                }
                elsif ($entry->{type} eq 'rule') {
                    print "  Condition: " . ($data->{condition} || 'Not specified') . "\n";
                    print "  Action: " . ($data->{action} || 'Not specified') . "\n";
                }
                
                print "\n";
            }
        }
        
    } elsif ($subcmd eq 'store') {
        # Store requires AI assistance - return prompt to be sent to AI
        my $type = $args[1] || '';
        my $data_text = join(' ', @args[2..$#args]);
        
        my $prompt = "Please store this in long-term memory:\n";
        $prompt .= "Type: $type\n" if $type;
        $prompt .= "Data: $data_text\n" if $data_text;
        $prompt .= "\nUse the memory_operations tool to store this pattern.";
        
        $self->display_info_message("Requesting AI to store pattern in long-term memory...");
        return (1, $prompt);  # Return prompt to be sent to AI
        
    } elsif ($subcmd eq 'clear') {
        # Confirm before clearing
        print "\n";
        $self->display_warning_message("This will clear ALL long-term memory patterns for this project!");
        print "Are you sure? (yes/no): ";
        
        my $response = <STDIN>;
        chomp $response;
        
        if (lc($response) eq 'yes') {
            # Clear all patterns
            eval {
                # Create new empty LTM
                require CLIO::Memory::LongTerm;
                my $new_ltm = CLIO::Memory::LongTerm->new(
                    project_root => $ltm->{project_root},
                    debug => $ltm->{debug}
                );
                
                # Save (overwrites with empty patterns)
                $new_ltm->save();
                
                # Update session reference
                $self->{session}{ltm} = $new_ltm;
            };
            
            if ($@) {
                $self->display_error_message("Failed to clear LTM: $@");
            } else {
                $self->display_success_message("Long-term memory cleared successfully");
            }
        } else {
            $self->display_info_message("Cancelled - no changes made");
        }
        
    } else {
        $self->display_error_message("Unknown subcommand: $subcmd");
        print "Usage:\n";
        $self->display_list_item("/memory [list|ls] [type] - List patterns");
        $self->display_list_item("/memory store <type> [data] - Store pattern (requires AI)");
        $self->display_list_item("/memory clear - Clear all patterns");
    }
}

=head2 handle_update_command

Handle /update command for checking and installing updates

=cut

sub handle_update_command {
    my ($self, @args) = @_;
    
    # Load Update module
    eval {
        require CLIO::Update;
    };
    if ($@) {
        $self->display_error_message("Update module not available: $@");
        return;
    }
    
    my $updater = CLIO::Update->new(debug => $self->{debug});
    
    # Parse subcommand
    my $subcmd = @args ? lc($args[0]) : 'status';
    
    if ($subcmd eq 'check') {
        # Force update check
        $self->display_command_header("UPDATE CHECK");
        $self->display_info_message("Checking for updates...");
        print "\n";
        
        my $result = $updater->check_for_updates();
        
        if ($result->{error}) {
            $self->display_error_message("Update check failed: $result->{error}");
            return;
        }
        
        my $current = $result->{current_version} || 'unknown';
        my $latest = $result->{latest_version} || 'unknown';
        
        print "Current version: " . $self->colorize($current, 'command_value') . "\n";
        print "Latest version:  " . $self->colorize($latest, 'command_value') . "\n";
        print "\n";
        
        if ($result->{update_available}) {
            $self->display_success_message("Update available: $latest");
            print "\n";
            print "Run " . $self->colorize('/update install', 'command') . " to install\n";
        } else {
            $self->display_success_message("You are running the latest version");
        }
        print "\n";
    }
    elsif ($subcmd eq 'install') {
        # Install latest version
        $self->display_command_header("UPDATE INSTALLATION");
        
        # First check what's available
        my $check_result = $updater->check_for_updates();
        
        if ($check_result->{error}) {
            $self->display_error_message("Cannot check for updates: $check_result->{error}");
            return;
        }
        
        unless ($check_result->{update_available}) {
            $self->display_info_message("You are already running the latest version ($check_result->{current_version})");
            return;
        }
        
        print "Current version: " . $self->colorize($check_result->{current_version}, 'muted') . "\n";
        print "New version:     " . $self->colorize($check_result->{latest_version}, 'command_value') . "\n";
        print "\n";
        
        # Confirm installation
        print "Install update? [y/N]: ";
        my $confirm = <STDIN>;
        chomp $confirm if $confirm;
        
        unless ($confirm && $confirm =~ /^y/i) {
            $self->display_info_message("Update cancelled");
            return;
        }
        
        print "\n";
        $self->display_info_message("Installing update...");
        print "\n";
        
        my $result = $updater->install_latest();
        
        if ($result->{success}) {
            $self->display_success_message("Update installed successfully!");
            print "\n";
            $self->display_info_message("Please restart CLIO to use the new version");
            print "\n";
            print "Run: " . $self->colorize('./clio', 'command') . "\n";
        } else {
            $self->display_error_message("Update installation failed: " . ($result->{error} || 'Unknown error'));
            print "\n";
            if ($result->{rollback}) {
                $self->display_info_message("Previous version restored (rollback successful)");
            }
        }
        print "\n";
    }
    elsif ($subcmd eq 'status' || $subcmd eq '') {
        # Show update status
        $self->display_command_header("UPDATE STATUS");
        
        my $current = $updater->get_current_version();
        print "Current version: " . $self->colorize($current, 'command_value') . "\n";
        
        # Check if cached update info exists
        my $cache_info = $updater->get_available_update();
        
        if (!$cache_info->{cached}) {
            # No cache exists - never checked
            print "\n";
            $self->display_info_message("No update information cached");
            print "\n";
            print "Run " . $self->colorize('/update check', 'command') . " to check for updates\n";
        }
        elsif ($cache_info->{up_to_date}) {
            # Checked, and we're up-to-date
            print "Latest version:  " . $self->colorize($cache_info->{version}, 'command_value') . "\n";
            print "\n";
            $self->display_success_message("You are running the latest version");
        }
        else {
            # Update available
            print "Latest version:  " . $self->colorize($cache_info->{version}, 'success') . "\n";
            print "\n";
            $self->display_success_message("Update available!");
            print "\n";
            print "Run " . $self->colorize('/update install', 'command') . " to install\n";
        }
        print "\n";
    }
    elsif ($subcmd eq 'list') {
        # List all available versions
        $self->display_command_header("AVAILABLE VERSIONS");
        $self->display_info_message("Fetching releases from GitHub...");
        print "\n";
        
        my $releases = $updater->get_all_releases();
        
        unless ($releases && @$releases) {
            $self->display_error_message("Failed to fetch releases from GitHub");
            return;
        }
        
        my $current = $updater->get_current_version();
        
        print "Current version: " . $self->colorize($current, 'command_value') . "\n\n";
        print "Available versions:\n\n";
        
        my $count = 0;
        for my $release (@$releases) {
            my $version = $release->{version};
            my $name = $release->{release_name} || $version;
            my $date = $release->{published_at} || '';
            $date =~ s/T.*//;  # Strip time portion
            
            # Mark current version
            my $marker = '';
            my $version_color = 'command_value';
            if ($version eq $current) {
                $marker = ' (current)';
                $version_color = 'success';
            }
            
            # Mark prereleases
            if ($release->{prerelease}) {
                $marker .= ' [pre-release]';
            }
            
            print "  " . $self->colorize($version, $version_color);
            print $self->colorize($marker, 'muted') if $marker;
            print "  " . $self->colorize($date, 'muted') if $date;
            print "\n";
            
            $count++;
            last if $count >= 20;  # Limit to 20 versions
        }
        
        if (scalar(@$releases) > 20) {
            print "\n  " . $self->colorize("... and " . (scalar(@$releases) - 20) . " more", 'muted') . "\n";
        }
        
        print "\n";
        print "Use " . $self->colorize('/update switch <version>', 'command') . " to switch to a specific version\n";
        print "\n";
    }
    elsif ($subcmd eq 'switch') {
        # Switch to a specific version
        my $target_version = $args[1];
        
        unless ($target_version) {
            $self->display_error_message("Version number required");
            print "\n";
            print "Usage: " . $self->colorize('/update switch <version>', 'command') . "\n";
            print "Example: " . $self->colorize('/update switch 20260125.8', 'command') . "\n";
            print "\n";
            print "Use " . $self->colorize('/update list', 'command') . " to see available versions\n";
            return;
        }
        
        $self->display_command_header("VERSION SWITCH");
        
        # Verify version exists
        $self->display_info_message("Verifying version $target_version...");
        
        my $release = $updater->get_release_by_version($target_version);
        
        unless ($release) {
            print "\n";
            $self->display_error_message("Version $target_version not found on GitHub");
            print "\n";
            print "Use " . $self->colorize('/update list', 'command') . " to see available versions\n";
            return;
        }
        
        my $current = $updater->get_current_version();
        
        print "\n";
        print "Current version: " . $self->colorize($current, 'muted') . "\n";
        print "Target version:  " . $self->colorize($target_version, 'command_value') . "\n";
        
        if ($release->{prerelease}) {
            print $self->colorize("WARNING: This is a pre-release version", 'warning') . "\n";
        }
        
        print "\n";
        
        # Confirm switch
        print "Switch to version $target_version? [y/N]: ";
        my $confirm = <STDIN>;
        chomp $confirm if $confirm;
        
        unless ($confirm && $confirm =~ /^y/i) {
            $self->display_info_message("Version switch cancelled");
            return;
        }
        
        print "\n";
        $self->display_info_message("Downloading and installing version $target_version...");
        print "\n";
        
        my $result = $updater->install_version($target_version);
        
        if ($result->{success}) {
            $self->display_success_message("Switched to version $target_version!");
            print "\n";
            $self->display_info_message("Please restart CLIO to use the new version");
            print "\n";
            print "Run: " . $self->colorize('./clio', 'command') . "\n";
        } else {
            $self->display_error_message("Version switch failed: " . ($result->{error} || 'Unknown error'));
        }
        print "\n";
    }
    else {
        $self->display_error_message("Unknown subcommand: $subcmd");
        print "\n";
        print "Available commands:\n";
        $self->display_list_item("/update - Show current version and update help");
        $self->display_list_item("/update status - Show current version and update status");
        $self->display_list_item("/update check - Check for available updates");
        $self->display_list_item("/update list - List all available versions");
        $self->display_list_item("/update install - Install the latest version");
        $self->display_list_item("/update switch <version> - Switch to a specific version");
        print "\n";
    }
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
    push @lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━";
    push @lines, $self->colorize("AVAILABLE MODELS", 'DATA') . " (" . $self->colorize($api_base, 'THEME') . ")";
    push @lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━";
    push @lines, "";
    
    # Column headers
    if ($has_billing) {
        my $header = sprintf("  %-64s %12s", "Model", "Rate");
        push @lines, $self->colorize($header, 'THEME');
        push @lines, sprintf("  %-64s %12s", "━" x 64, "━" x 12);
    } else {
        my $header = sprintf("  %-70s", "Model");
        push @lines, $self->colorize($header, 'THEME');
        push @lines, sprintf("  %-70s", "━" x 70);
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
    push @lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━";
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
            my $cwd = Cwd::getcwd() || $ENV{PWD} || '.';
            $file = "$cwd/$file";
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
        
        $self->display_command_header("CONVERSATION MEMORY");
        
        # Show conversation memory stats
        if ($self->{session} && $self->{session}{state}) {
            my $state = $self->{session}{state};
            my $history = $state->get_history();
            my $yarn = $state->yarn();
            
            # Calculate stats
            my $active_messages = scalar(@$history);
            my $active_tokens = $state->get_conversation_size();
            
            # Get actual model max_tokens from APIManager (not hardcoded fallback)
            my $max_tokens = 128000;  # Default fallback
            if ($self->{api_manager}) {
                my $model = $self->{api_manager}->get_current_model();
                my $caps = $self->{api_manager}->get_model_capabilities($model);
                if ($caps && $caps->{max_prompt_tokens}) {
                    $max_tokens = $caps->{max_prompt_tokens};
                }
            }
            
            my $threshold = $state->{summarize_threshold} || int($max_tokens * 0.8);
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
                $status = $self->colorize("TRIMMING ACTIVE (over 80%)", 'WARN');
            } elsif ($active_tokens > $threshold * 0.6) {
                $status = $self->colorize("Approaching limit (60-80%)", 'THEME');
            } else {
                $status = $self->colorize("Healthy (below 60%)", 'SUCCESS');
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
            print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
            print $self->colorize("CONTEXT FILES", 'DATA'), "\n";
            print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
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
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
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
            my $cwd = Cwd::getcwd() || $ENV{PWD} || '.';
            $file = "$cwd/$file";
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
            my $cwd = Cwd::getcwd() || $ENV{PWD} || '.';
            $file = "$cwd/$file";
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
            my $cwd = Cwd::getcwd() || $ENV{PWD} || '.';
            $file = "$cwd/$file";
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
    
    $self->display_command_header("GIT STATUS");
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
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
    my $header = "GIT DIFF" . ($file ? " - $file" : "");
    $self->display_command_header($header);
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
    
    $self->display_command_header("GIT LOG (last $count commits)");
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
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
    print $self->colorize("TOOL OPERATIONS (last $count)", 'DATA'), "\n";
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
    
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
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
    print $self->colorize("TOOL OPERATIONS - $tool_name (" . scalar(@$entries) . " found)", 'DATA'), "\n";
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
    
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
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
    print $self->colorize("TOOL OPERATIONS - search '$pattern' (" . scalar(@$entries) . " found)", 'DATA'), "\n";
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
    
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
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
    print $self->colorize("TOOL OPERATIONS - session $session_id (" . scalar(@$entries) . " ops)", 'DATA'), "\n";
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
    
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
    
    $self->display_command_header("GIT COMMIT");
    print $commit_output;
    print "\n";
    
    $self->display_success_message("Changes committed successfully");
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

=head2 handle_session_command

Handle /session commands for session management.

New noun-first pattern:
  /session                - Show help for /session commands
  /session show           - Display current session info
  /session switch         - Interactive session picker
  /session switch <id>    - Switch to specific session
  /session list           - List all sessions
  /session new            - Create new session
  /session clear          - Clear current session history

=cut

sub handle_session_command {
    my ($self, $action, @args) = @_;
    
    $action ||= '';
    $action = lc($action);
    
    # /session (no args) - show help
    if ($action eq '' || $action eq 'help') {
        $self->_display_session_help();
        return;
    }
    
    # /session show - display current session info
    if ($action eq 'show') {
        $self->_display_session_info();
        return;
    }
    
    # /session list - list all sessions
    if ($action eq 'list') {
        $self->_list_sessions();
        return;
    }
    
    # /session switch [id] - switch sessions
    if ($action eq 'switch') {
        $self->handle_switch_command(@args);
        return;
    }
    
    # /session new - create new session (guidance)
    if ($action eq 'new') {
        $self->display_system_message("To create a new session, exit and run:");
        $self->display_system_message("  ./clio --new");
        return;
    }
    
    # /session clear - clear history
    if ($action eq 'clear') {
        $self->_clear_session_history();
        return;
    }
    
    # Unknown action
    $self->display_error_message("Unknown action: /session $action");
    $self->_display_session_help();
}

=head2 _display_session_help

Display help for /session commands

=cut

sub _display_session_help {
    my ($self) = @_;
    
    $self->display_command_header("SESSION COMMANDS");
    
    $self->display_list_item("/session show - Display current session info");
    $self->display_list_item("/session list - List all available sessions");
    $self->display_list_item("/session switch - Interactive session picker");
    $self->display_list_item("/session switch <id> - Switch to specific session");
    $self->display_list_item("/session new - Show how to create new session");
    $self->display_list_item("/session clear - Clear current session history");
    
    print "\n";
    $self->display_section_header("EXAMPLES");
    print "  /session show                        # See current session\n";
    print "  /session list                        # See all sessions\n";
    print "  /session switch abc123-def456        # Switch by ID\n";
    print "\n";
}

=head2 _display_session_info

Display current session information

=cut

sub _display_session_info {
    my ($self) = @_;
    
    my $session_id = $self->{session} ? $self->{session}->{session_id} : 'unknown';
    my $state = $self->{session} ? $self->{session}->state() : {};
    
    $self->display_command_header("SESSION INFORMATION");
    
    $self->display_key_value("Session ID", $session_id);
    
    # Working directory
    my $workdir = $state->{working_directory} || '.';
    $self->display_key_value("Working Dir", $workdir);
    
    # Created at
    if ($state->{created_at}) {
        my $created = localtime($state->{created_at});
        $self->display_key_value("Created", $created);
    }
    
    # History count
    my $history_count = $state->{history} ? scalar(@{$state->{history}}) : 0;
    $self->display_key_value("History", "$history_count messages");
    
    # API config (session-specific)
    if ($state->{api_config} && %{$state->{api_config}}) {
        print "\n";
        $self->display_section_header("SESSION API CONFIG");
        for my $key (sort keys %{$state->{api_config}}) {
            $self->display_key_value($key, $state->{api_config}{$key});
        }
    }
    
    # Billing info
    if ($state->{billing}) {
        print "\n";
        $self->display_section_header("SESSION USAGE");
        my $billing = $state->{billing};
        $self->display_key_value("Requests", $billing->{request_count} || 0);
        $self->display_key_value("Input tokens", $billing->{input_tokens} || 0);
        $self->display_key_value("Output tokens", $billing->{output_tokens} || 0);
    }
    
    print "\n";
}

=head2 _list_sessions

List all available sessions

=cut

sub _list_sessions {
    my ($self) = @_;
    
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
        $self->display_system_message("No sessions found");
        return;
    }
    
    # Get session info
    my @session_info;
    for my $session_file (@sessions) {
        my $id = $session_file;
        $id =~ s/\.json$//;
        
        my $filepath = "$sessions_dir/$session_file";
        my $mtime = (stat($filepath))[9] || 0;
        my $size = (stat($filepath))[7] || 0;
        
        push @session_info, {
            id => $id,
            mtime => $mtime,
            size => $size,
            is_current => ($self->{session} && $self->{session}->{session_id} eq $id),
        };
    }
    
    # Sort by modification time (most recent first)
    @session_info = sort { $b->{mtime} <=> $a->{mtime} } @session_info;
    
    # Create formatted items for paginated display
    my @items;
    for my $i (0 .. $#session_info) {
        my $sess = $session_info[$i];
        my $marker = $sess->{is_current} ? ' (current)' : '';
        my $time = _format_relative_time($sess->{mtime});
        
        # Format: "  1) abc123-def456-... [5 min ago] (current)"
        push @items, sprintf("%3d) %s [%s]%s", 
            $i + 1, $sess->{id}, $time, $marker);
    }
    
    # Use standard pagination
    my $formatter = sub {
        my ($item, $idx) = @_;
        return $item;  # Already formatted
    };
    
    $self->display_paginated_list("AVAILABLE SESSIONS", \@items, $formatter);
    
    print "\n";
    $self->display_system_message("Use '/session switch <number>' or '/session switch <id>' to switch");
}

=head2 _clear_session_history

Clear the current session's conversation history

=cut

sub _clear_session_history {
    my ($self) = @_;
    
    unless ($self->{session}) {
        $self->display_error_message("No active session");
        return;
    }
    
    # Confirm
    print $self->colorize("Clear all conversation history for this session? [y/N]: ", 'PROMPT');
    my $response = <STDIN>;
    chomp $response if defined $response;
    $response = lc($response || 'n');
    
    unless ($response eq 'y' || $response eq 'yes') {
        $self->display_system_message("Cancelled");
        return;
    }
    
    # Clear history
    my $state = $self->{session}->state();
    $state->{history} = [];
    $self->{session}->save();
    
    $self->display_system_message("Session history cleared");
}

=head2 handle_switch_command

Switch to a different session

=cut

sub handle_switch_command {
    my ($self, @args) = @_;
    
    require CLIO::Session::Manager;
    
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
    
    my @session_files = grep { /\.json$/ && -f "$sessions_dir/$_" } readdir($dh);
    closedir($dh);
    
    unless (@session_files) {
        $self->display_system_message("No sessions available");
        return;
    }
    
    # Extract session IDs and get info
    my @sessions = map { 
        my $id = $_;
        $id =~ s/\.json$//;
        my $file = "$sessions_dir/$_";
        my $mtime = (stat($file))[9];
        { id => $id, file => $file, mtime => $mtime }
    } @session_files;
    
    # Sort by most recent first
    @sessions = sort { $b->{mtime} <=> $a->{mtime} } @sessions;
    
    my $target_session_id;
    
    # If session ID provided as argument, use it
    if (@args && $args[0]) {
        $target_session_id = $args[0];
        
        # Check if it's a number (selecting from list)
        if ($target_session_id =~ /^\d+$/) {
            my $idx = $target_session_id - 1;
            if ($idx >= 0 && $idx < @sessions) {
                $target_session_id = $sessions[$idx]{id};
            } else {
                $self->display_error_message("Invalid session number: $args[0] (valid: 1-" . scalar(@sessions) . ")");
                return;
            }
        }
        
        # Verify session exists
        my ($found) = grep { $_->{id} eq $target_session_id } @sessions;
        unless ($found) {
            $self->display_error_message("Session not found: $target_session_id");
            return;
        }
    } else {
        # Display sessions and ask for choice
        print "\n";
        $self->display_command_header("AVAILABLE SESSIONS");
        
        my $current_id = $self->{session} ? $self->{session}->{session_id} : '';
        
        for my $i (0..$#sessions) {
            my $s = $sessions[$i];
            my $current = ($s->{id} eq $current_id) ? ' @BOLD@(current)@RESET@' : "";
            my $time = _format_relative_time($s->{mtime});
            printf "  %d) %s %s%s\n", 
                $i + 1, 
                substr($s->{id}, 0, 20) . "...",
                $self->colorize("[$time]", 'dim'),
                $self->{ansi}->parse($current);
        }
        
        print "\n";
        $self->display_system_message("Enter session number or ID to switch:");
        $self->display_system_message("  /session switch 1");
        $self->display_system_message("  /session switch abc123-def456...");
        return;
    }
    
    # Don't switch to current session
    if ($self->{session} && $self->{session}->{session_id} eq $target_session_id) {
        $self->display_system_message("Already in session: $target_session_id");
        return;
    }
    
    # Perform the switch
    $self->display_system_message("Switching to session: $target_session_id...");
    
    # 1. Save current session
    if ($self->{session}) {
        $self->display_system_message("  Saving current session...");
        $self->{session}->save();
        
        # Release lock if possible
        if ($self->{session}->{lock} && $self->{session}->{lock}->can('release')) {
            $self->{session}->{lock}->release();
        }
    }
    
    # 2. Load new session
    my $new_session = eval {
        CLIO::Session::Manager->load($target_session_id, debug => $self->{debug});
    };
    
    if ($@ || !$new_session) {
        my $err = $@ || "Unknown error";
        $self->display_error_message("Failed to load session: $err");
        
        # Re-acquire lock on original session
        if ($self->{session}) {
            $self->display_system_message("Staying in current session");
        }
        return;
    }
    
    # 3. Update Chat's session reference
    $self->{session} = $new_session;
    
    # 4. Reload theme/style from new session
    my $state = $new_session->state();
    if ($state->{style} && $self->{theme_manager}) {
        $self->{theme_manager}->set_style($state->{style});
    }
    if ($state->{theme} && $self->{theme_manager}) {
        $self->{theme_manager}->set_theme($state->{theme});
    }
    
    # 5. Success
    print "\n";
    $self->display_success_message("Switched to session: $target_session_id");
    
    # Show session info
    my $history_count = $state->{history} ? scalar(@{$state->{history}}) : 0;
    $self->display_system_message("  Messages in history: $history_count");
    $self->display_system_message("  Working directory: " . ($state->{working_directory} || '.'));
}

# Helper to format relative time
sub _format_relative_time {
    my ($timestamp) = @_;
    
    my $now = time();
    my $diff = $now - $timestamp;
    
    if ($diff < 60) {
        return "just now";
    } elsif ($diff < 3600) {
        my $mins = int($diff / 60);
        return "$mins min ago";
    } elsif ($diff < 86400) {
        my $hours = int($diff / 3600);
        return "$hours hr ago";
    } elsif ($diff < 604800) {
        my $days = int($diff / 86400);
        return "$days day" . ($days > 1 ? "s" : "") . " ago";
    } else {
        my @t = localtime($timestamp);
        return sprintf("%04d-%02d-%02d", $t[5]+1900, $t[4]+1, $t[3]);
    }
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
    
    # Calculate page size:
    # Overhead = 5 (header: blank, ===, title, ===, blank) + 4 (footer: blank, ---, status, prompt)
    # Total overhead = 9 lines
    my $overhead = 9;
    my $page_size = ($self->{terminal_height} || 24) - $overhead;
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
    # Switch to alternate screen buffer for clean pagination
    # This prevents content from showing up in scrollback
    print "\e[?1049h";  # Enter alternate screen buffer
    
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
    
    # Exit alternate screen buffer and return to normal view
    print "\e[?1049l";  # Exit alternate screen buffer (restores original screen)
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
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        print "CUSTOM SKILLS\n";
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        
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
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        
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
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        print "SKILL: $name\n";
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        print "\n";
        print $skill->{prompt}, "\n";
        print "\n";
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
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
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
            "ACTIVE SYSTEM PROMPT",
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
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
            "\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501",
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
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
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
        $context->{context} = join("\n\n" . ("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━") . "\n\n", @context_contents);
    }
    
    return $context;
}

=head2 handle_init_command

Initialize CLIO for a project - analyzes codebase, fetches CLIO methodology docs,
generates custom project instructions, and sets up git properly.

This runs as an AI task so the user can see all the work being done.

=cut

sub handle_init_command {
    my ($self, @args) = @_;
    
    # Check if already initialized
    my $cwd = Cwd::getcwd() || $ENV{PWD} || '.';
    my $clio_dir = "$cwd/.clio";
    my $instructions_file = "$clio_dir/instructions.md";
    
    # Check for --force flag
    my $force = grep { $_ eq '--force' || $_ eq '-f' } @args;
    
    if (-f $instructions_file && !$force) {
        $self->display_system_message("Project already initialized!");
        $self->display_system_message("Found existing instructions at: .clio/instructions.md");
        print "\n";
        $self->display_system_message("To re-initialize, use:");
        $self->display_system_message("  /init --force");
        print "\n";
        return;
    }
    
    # If force flag and instructions exist, back them up
    if ($force && -f $instructions_file) {
        my $timestamp = time();
        my $backup_file = "$instructions_file.backup.$timestamp";
        rename($instructions_file, $backup_file);
        $self->display_system_message("Backed up existing instructions to:");
        $self->display_system_message("  .clio/instructions.md.backup.$timestamp");
        print "\n";
    }
    
    # Check for PRD
    my $prd_path = "$clio_dir/PRD.md";
    my $has_prd = -f $prd_path;
    
    # Build comprehensive prompt for the AI to do the initialization work
    my $prompt = <<'INIT_PROMPT';
I need you to initialize CLIO for this project. This is a comprehensive setup task that involves analyzing the codebase and creating custom project instructions.
INIT_PROMPT

    # Add PRD-specific instructions if PRD exists
    if ($has_prd) {
        $prompt .= <<'PRD_SECTION';

**IMPORTANT: This project has a PRD at `.clio/PRD.md`**

When creating `.clio/instructions.md`, you MUST:
1. Read `.clio/PRD.md` first using file_operations
2. Extract key information:
   - Project name, purpose, goals (Section 1)
   - Technology stack (Section 4.1)
   - Architecture overview (Section 4.2-4.3)
   - Testing strategy (Section 8)
   - Development phases (Section 10)
3. Incorporate this information into the instructions:
   - Add "**Based on PRD:** `.clio/PRD.md` (version X)" near the top
   - Use PRD's project overview as context in project description
   - Use PRD's tech stack details for code standards section
   - Use PRD's testing strategy for testing commands/workflow
   - Reference PRD's architecture in development workflow section

PRD_SECTION
    }
    
    $prompt .= <<'INIT_REST';

## Your Tasks:

### 1. Fetch CLIO's Core Methodology
First, fetch these two reference documents:
- CLIO's instructions template: https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/.clio/instructions.md
- The Unbroken Method: https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/ai-assisted/THE_UNBROKEN_METHOD.md

Read and understand both documents - they define the methodology you should follow.

### 2. Analyze This Codebase
Do a thorough analysis of this project:
- What programming language(s) is it?
- What is the project structure?
- What frameworks/libraries does it use?
- What is the apparent purpose of this project?
- Are there existing tests? CI/CD configs? Documentation?
- What code style patterns are used?
- Is there a build system or package manager?

### 3. Create Custom Project Instructions
Create a `.clio/instructions.md` file tailored specifically for THIS project. The instructions should:

- Be based on The Unbroken Method principles (continuous context, complete ownership, investigation first, etc.)
- Include project-specific coding standards discovered from the codebase
- Document the tech stack and architecture
- Include project-specific testing commands
- Include common workflows for this project type
- Add project-specific anti-patterns to avoid
- Include handoff documentation requirements

**IMPORTANT**: This project is NOT CLIO and is NOT part of Synthetic Autonomic Mind. The instructions must be tailored to the user's independent project, using CLIO's methodology as a template but customized for their specific needs.

### 4. Set Up .gitignore
Ensure `.gitignore` includes these CLIO-specific entries (add them if not present):
```
# CLIO
.clio/logs/
.clio/sessions/
.clio/memory/
.clio/*.json
```

### 5. Initialize or Update Git
- If this is NOT a git repository yet, initialize it with `git init`, add all files, and make an initial commit
- If this IS already a git repository, just add the new .clio/ directory and .gitignore changes, then commit

### 6. Report What You Did
After completing all tasks, provide a summary of:
- The project analysis findings
- The instructions you created
- The git operations performed

Begin now - use your tools to complete all these tasks.
INIT_REST

    $self->display_system_message("Starting project initialization...");
    if ($has_prd) {
        $self->display_system_message("Found PRD - will incorporate into instructions.");
    }
    $self->display_system_message("CLIO will analyze your codebase and create custom instructions.");
    print "\n";
    
    return $prompt;
}

=head2 handle_design_command

Create or review Product Requirements Document (PRD)

=cut

sub handle_design_command {
    my ($self, @args) = @_;
    
    my $prd_path = '.clio/PRD.md';
    
    # Check if PRD already exists
    if (-f $prd_path) {
        # Review mode - collaborative architect-led review via user_collaboration
        my $prompt = <<'REVIEW_PROMPT';
You are acting as an **Application Architect** reviewing the user's existing PRD through the **user_collaboration protocol**.

## CRITICAL: Use user_collaboration Tool

**ALL questions and interactions MUST use the user_collaboration tool.** Do NOT ask questions in your regular responses.

Example:
```perl
# CORRECT:
user_collaboration(
    operation => "request_input",
    message => "I've analyzed your PRD. What's changed since this was written? New requirements? Technical insights? Scope adjustments?"
)

# WRONG:
"What's changed since this was written?"  # Bypasses collaboration protocol
```

## Your Role

You are reviewing the project design with fresh eyes, helping the user:
- Identify gaps or inconsistencies
- Suggest improvements based on best practices
- Challenge assumptions that may no longer be valid
- Ensure the architecture still serves the project goals
- Update the PRD to reflect new insights

## Approach

### 1. Load and Analyze

Read `.clio/PRD.md` using file_operations and analyze it critically:
- Does the architecture still make sense for the stated goals?
- Are there any obvious gaps or missing considerations?
- Has the scope crept beyond what's documented?
- Are the technical choices still appropriate?

### 2. Present Findings

Use user_collaboration to show the user:
- **Project Summary:** Name, purpose, current status
- **Key Decisions:** Current tech stack, architecture pattern, deployment strategy
- **Scope:** MVP features vs future enhancements
- **Last Updated:** When was this last reviewed?

Then use user_collaboration to ask: "What's changed since this PRD was written? New requirements? Technical insights? Scope adjustments?"

### 3. Collaborative Review

Based on their response, use user_collaboration for conversational review:

- If requirements changed: "Let's talk about how this affects your architecture..."
- If new features: "Where do these fit - MVP or phase 2? How do they impact your current design?"
- If technical insights: "That's a good point about [X]. Let's think through the implications..."
- If architecture concerns: "Have you run into any issues with the current approach? Let's explore alternatives..."

**Proactively suggest improvements via user_collaboration:**
- "I notice your PRD doesn't mention [important aspect] - should we address that?"
- "Your current architecture has [component]. Have you considered [alternative]?"
- "For your scale requirements, you might want to think about [concern]..."

### 4. Update the PRD

After the conversation, update `.clio/PRD.md` using file_operations with:
- New or modified sections based on the discussion
- Updated architecture if design changed
- New features in appropriate priority buckets
- Completed features marked with checkmarks
- Updated change log with today's date and summary of changes

Save incrementally as you make significant updates.

### 5. Wrap Up

After updates, use user_collaboration to:
- Summarize what changed
- Highlight any significant architecture decisions
- If architecture changed: "Your architecture has evolved - consider running '/init' to update project instructions"
- Ask: "Anything else you'd like to revisit, or are we good?"

## Important Guidelines

- **ALWAYS use user_collaboration for questions** - never ask in regular responses
- **Be an architect, not a scribe** - provide design feedback
- **Think critically** - question whether current decisions still make sense
- **Identify evolution** - projects change, help the PRD evolve with it
- **Maintain quality** - ensure updated PRD is comprehensive and coherent
- **Document rationale** - capture *why* decisions were made

Begin by loading and analyzing the current PRD, then use user_collaboration to present your findings and ask what's changed.
REVIEW_PROMPT
        
        $self->display_system_message("Found existing PRD at $prd_path");
        $self->display_system_message("Starting PRD review mode...");
        print "\n";
        
        return $prompt;
    }
    
    # Create new PRD - collaborative application architect mode
    my $prompt = <<'DESIGN_PROMPT';
You are now acting as an **Application Architect** helping the user design their software project through the **user_collaboration protocol**.

## CRITICAL: Use user_collaboration Tool

**ALL questions and interactions MUST use the user_collaboration tool.** Do NOT ask questions in your regular responses.

Example:
```perl
# CORRECT:
user_collaboration(
    operation => "request_input",
    message => "Let's design your application together. Tell me about your project idea - what problem are you trying to solve?"
)

# WRONG:
"Tell me about your project idea..."  # This bypasses collaboration protocol
```

## Your Role

You are an experienced application architect who:
- Uses user_collaboration to ask probing questions
- Suggests architecture patterns and best practices  
- Helps think through technical trade-offs
- Identifies potential challenges early
- Guides the user to make informed decisions
- Documents the design in a comprehensive PRD

## Approach

### 1. Discovery Phase

Start by calling user_collaboration with:
"Let's design your application together. Tell me about your project idea - what problem are you trying to solve?"

Then have a **conversational, iterative dialogue using user_collaboration**:

- **Understand the problem:** What pain point? Who experiences it?
- **Explore solutions:** What approaches considered? What constraints?
- **Define scope:** MVP vs phase 2 vs out of scope?
- **Identify users:** Who will use this? Technical sophistication?
- **Technical context:** Current stack? Team expertise? Infrastructure?
- **Architecture questions:**
  - Scale requirements? (users, requests, data volume)
  - Performance requirements? (latency, throughput)
  - Reliability needs? (uptime, disaster recovery)
  - Security considerations? (auth, data protection, compliance)
  - Integration points? (external APIs, existing systems)

**Use user_collaboration for each question.** Let the conversation flow naturally - ask follow-up questions, suggest alternatives, challenge assumptions constructively.

### 2. Architecture Design Phase

After gathering information, use user_collaboration to suggest architecture patterns:

"Based on what you've described, I'd recommend a [pattern] architecture because... What do you think?"

"Have you considered [alternative approach]? It might be better for [reason]..."

"For your scale requirements, you'll want to think about [concern]..."

**Collaborate on** (using user_collaboration for each topic):
- System architecture (monolith vs microservices, layers, components)
- Data architecture (database choice, schema design, caching)
- Technology stack (language, framework, libraries - with rationale)
- Deployment strategy (cloud, on-prem, containerization)
- Development workflow (CI/CD, testing, branching)

### 3. PRD Creation Phase

After the collaborative design conversation, create a comprehensive PRD at `.clio/PRD.md`.

**Write the PRD directly using file_operations** - don't use templates. Base it on your conversation:

```markdown
# Product Requirements Document

**Project Name:** [from conversation]
**Version:** 0.1.0
**Last Updated:** [today's date]
**Status:** Draft

## 1. Project Overview

### 1.1 Purpose
[Synthesize from conversation]

### 1.2 Goals
[Concrete, measurable goals]

### 1.3 Non-Goals
[Explicitly out of scope]

## 2. User Stories & Use Cases

### 2.1 Primary Users
[User personas identified]

### 2.2 Key User Stories
[Real user stories from discussion]

### 2.3 Use Cases
[Concrete use cases with flows]

## 3. Features & Requirements

### 3.1 Must-Have (MVP)
[Features agreed upon for MVP]

### 3.2 Should-Have (Phase 2)
[Post-MVP features]

### 3.3 Nice-to-Have (Future)
[Future enhancements]

## 4. Technical Architecture

### 4.1 Technology Stack
[Specific stack with rationale]

### 4.2 System Architecture
[Architecture pattern with explanation]

### 4.3 Key Components
[Components with responsibilities]

### 4.4 Data Model
[Data entities and relationships]

### 4.5 APIs & Integrations
[Integration points]

## 5. Design & UX

### 5.1 Design Principles
[Design principles discussed]

### 5.2 User Interface
[UI approach and key screens]

### 5.3 Accessibility
[A11y requirements]

## 6. Security & Privacy

### 6.1 Security Requirements
[Security measures]

### 6.2 Privacy Considerations
[Privacy and compliance]

## 7. Performance & Scale

### 7.1 Performance Targets
[Specific metrics]

### 7.2 Scalability Requirements
[Scale strategy]

## 8. Testing Strategy

### 8.1 Test Coverage
[Testing approach]

### 8.2 Quality Metrics
[Quality gates]

## 9. Deployment & Operations

### 9.1 Deployment Process
[Deployment strategy]

### 9.2 Monitoring
[Observability approach]

### 9.3 Rollback Plan
[Disaster recovery]

## 10. Timeline & Milestones

### 10.1 Development Phases
[Phases discussed]

### 10.2 Key Milestones
[Milestone dates]

## 11. Dependencies & Risks

### 11.1 External Dependencies
[Dependencies identified]

### 11.2 Known Risks
[Risks with mitigation]

## 12. Success Metrics

### 12.1 Launch Criteria
[Definition of done]

### 12.2 Post-Launch Metrics
[Success KPIs]

## Appendices

### A. Glossary
[Terms and definitions]

### B. References
[Relevant documentation]

### C. Change Log
- [today's date]: Initial PRD created through collaborative design session
```

**Save the PRD using file_operations:**
```perl
file_operations(
    operation => "write_file",
    path => ".clio/PRD.md",
    content => $prd_content
)
```

### 4. Wrap Up

After creating the PRD, use user_collaboration to:
- Summarize what was documented
- Highlight key decisions or trade-offs
- Suggest next steps: "Your PRD is ready at `.clio/PRD.md`. Would you like to initialize the project now? (Type '/init')"

## Important Guidelines

- **ALWAYS use user_collaboration for questions** - never ask in regular responses
- **Be an architect, not a form-filler** - guide the design
- **Think critically** - question assumptions, suggest alternatives
- **Be collaborative** - this is a conversation via user_collaboration
- **Document comprehensively** - capture all design thinking
- **Provide rationale** - explain why approaches are recommended

Begin now by calling user_collaboration with: "Let's design your application together. Tell me about your project idea - what problem are you trying to solve?"
DESIGN_PROMPT

    $self->display_system_message("Starting collaborative architecture session...");
    print "\n";
    
    return $prompt;
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
    
    # Return original text if markdown disabled or text is undefined
    return $text unless $self->{enable_markdown};
    return $text unless defined $text;
    
    # Defensive: Wrap rendering in eval to prevent failures from bypassing formatting
    my $rendered;
    eval {
        $rendered = $self->{markdown_renderer}->render($text);
        
        # DEBUG: Check if @-codes are in rendered text
        if ($self->{debug} && defined $rendered && $rendered =~ /\@[A-Z_]+\@/) {
            print STDERR "[DEBUG][Chat] render_markdown: Found @-codes in rendered text\n";
            print STDERR "[DEBUG][Chat] Sample: ", substr($rendered, 0, 100), "\n";
        }
        
        # Parse @COLOR@ markers to actual ANSI escape sequences
        $rendered = $self->{ansi}->parse($rendered) if defined $rendered;
        
        # Restore escaped @ symbols from inline code
        # Markdown.pm escapes @ as \x00AT\x00 to prevent ANSI interpretation
        $rendered =~ s/\x00AT\x00/\@/g if defined $rendered;
        
        # DEBUG: Verify @-codes were converted
        if ($self->{debug} && defined $rendered && $rendered =~ /\@[A-Z_]+\@/) {
            print STDERR "[DEBUG][Chat] WARNING: @-codes still present after ANSI parse!\n";
            print STDERR "[DEBUG][Chat] Sample: ", substr($rendered, 0, 100), "\n";
        }
    };
    
    # If rendering failed or returned undef/empty, fall back to original text
    if ($@ || !defined $rendered || $rendered eq '') {
        print STDERR "[ERROR][Chat] Markdown rendering failed: $@\n" if $@;
        print STDERR "[WARN][Chat] Markdown render returned empty/undef, using raw text\n" 
            if !$@ && (!defined $rendered || $rendered eq '');
        return $text;  # Fallback to raw text rather than breaking output
    }
    
    return $rendered;
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
    my ($self, @args) = @_;
    return $self->{display}->show_thinking(@args);
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
        
        print $self->colorize("━ AVAILABLE STYLES ━" . ("━" x 41), 'DATA'), "\n\n";
        for my $style (@styles) {
            my $marker = ($style eq $current) ? ' (current)' : '';
            printf "  %-20s%s\n", $style, $self->colorize($marker, 'PROMPT');
        }
        print "\n";
        print "Use ", $self->colorize("/style set <name>", 'PROMPT'), " to switch styles\n";
    }
    elsif ($action eq 'show') {
        my $current = $self->{theme_mgr}->get_current_style();
        print $self->colorize("━ CURRENT STYLE ━" . ("━" x 47), 'DATA'), "\n\n";
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
        
        print $self->colorize("━ AVAILABLE THEMES ━" . ("━" x 41), 'DATA'), "\n\n";
        for my $theme (@themes) {
            my $marker = ($theme eq $current) ? ' (current)' : '';
            printf "  %-20s%s\n", $theme, $self->colorize($marker, 'PROMPT');
        }
        print "\n";
        print "Use ", $self->colorize("/theme set <name>", 'PROMPT'), " to switch themes\n";
    }
    elsif ($action eq 'show') {
        my $current = $self->{theme_mgr}->get_current_theme();
        print $self->colorize("━ CURRENT THEME ━" . ("━" x 47), 'DATA'), "\n\n";
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

=head2 _prompt_session_learnings

Prompt user for session learnings before exit.

This is an optional memory capture that asks the user what important
discoveries or patterns were learned during the session. Responses
are stored as discoveries in LTM.

=cut

sub _prompt_session_learnings {
    my ($self) = @_;
    
    # Only prompt if we have a session with LTM
    return unless $self->{session};
    return unless $self->{session}->can('ltm');
    my $ltm = $self->{session}->ltm();
    return unless $ltm;
    
    # Check if there's been meaningful work (more than just hello/goodbye)
    my $history = $self->{session}->get_conversation_history();
    return unless $history && @$history > 4;  # Skip if very short session
    
    # Display learning prompt
    print "\n";
    $self->display_system_message("Session ending. Any important discoveries to remember?");
    print $self->colorize("(Press Enter to skip, or type learnings)\n", 'DIM');
    print $self->colorize(": ", 'PROMPT');
    
    # Get user input (simple readline, not going through AI)
    my $response = <STDIN>;
    chomp $response if defined $response;
    
    # Skip if empty
    return unless $response && $response =~ /\S/;
    
    # Store as discovery in LTM
    # Parse simple format: treat each sentence/line as a separate discovery
    my @learnings;
    
    # Split by newlines or periods followed by space
    my @parts = split /(?:\n|\.)\s*/, $response;
    
    for my $part (@parts) {
        $part =~ s/^\s+|\s+$//g;  # Trim whitespace
        next unless $part && length($part) > 5;  # Skip very short fragments
        push @learnings, $part;
    }
    
    return unless @learnings;
    
    # Store each learning as a discovery
    for my $learning (@learnings) {
        eval {
            $ltm->add_discovery($learning, 0.85, 1);  # confidence=0.85, verified=1
        };
        print STDERR "[DEBUG][Chat] Stored learning: $learning\n" if $self->{debug};
    }
    
    # Save LTM
    eval {
        my $ltm_file = File::Spec->catfile($self->{session}->{state}->{working_directory}, '.clio', 'ltm.json');
        $ltm->save($ltm_file);
    };
    
    $self->display_system_message("Stored " . scalar(@learnings) . " learning(s) in long-term memory.");
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


=head1 AUTHOR

Fewtarius

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

1;
