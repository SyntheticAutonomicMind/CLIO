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
    
    # Check for NO_COLOR environment variable (standard convention for disabling color)
    my $use_color_default = ($ENV{NO_COLOR} || $args{no_color}) ? 0 : 1;
    
    my $self = {
        session => $args{session},
        ai_agent => $args{ai_agent},
        config => $args{config},  # Config object
        debug => $args{debug} || 0,
        terminal_width => 80,  # Default, will be updated
        terminal_height => 24, # Default rows for pagination
        use_color => $use_color_default,  # Enable colors by default, disable with NO_COLOR or --no-color
        ansi => CLIO::UI::ANSI->new(enabled => $use_color_default, debug => $args{debug}),
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

=head2 get_command_handler

Return the command handler hash for tools that need to access it

=cut

sub get_command_handler {
    my ($self) = @_;
    return $self->{command_handler};
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
    
    # Ensure spinner is initialized or recreate if theme changed
    # Check if spinner needs to be recreated due to theme change
    my $spinner_frames = $self->{theme_mgr}->get_spinner_frames();
    my $needs_recreation = 0;
    
    if (!$self->{spinner}) {
        $needs_recreation = 1;
    } elsif ($self->{spinner}->{frames}) {
        # Check if frames changed (theme/style was switched)
        my $current_frames = join(',', @{$self->{spinner}->{frames}});
        my $new_frames = join(',', @$spinner_frames);
        if ($current_frames ne $new_frames) {
            $needs_recreation = 1;
            # Stop old spinner before recreating
            $self->{spinner}->stop() if $self->{spinner}->{running};
        }
    }
    
    if ($needs_recreation) {
        $self->{spinner} = CLIO::UI::ProgressSpinner->new(
            theme_mgr => $self->{theme_mgr},  # Use theme-managed frames
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
    
    # Check for authentication migrations (one-time notices)
    $self->_check_auth_migration();
    
    # Prepopulate session data from API (quota, model info)
    $self->_prepopulate_session_data();
    
    # Background update check (non-blocking)
    $self->check_for_updates_async();
    
    # Main loop
    while (1) {
        # Check for update notifications from background check
        $self->check_for_update_notification();
        
        # Check for agent messages (if broker client available)
        # Look in multiple places: ai_agent (for sub-agents) or subagent_cmd (for primary user)
        my $broker_client;
        if ($self->{ai_agent} && $self->{ai_agent}->can('broker_client')) {
            $broker_client = $self->{ai_agent}->broker_client();
        }
        # Also check SubAgent command handler for primary user session
        if (!$broker_client && $self->{command_handler} && $self->{command_handler}{subagent_cmd}) {
            $broker_client = $self->{command_handler}{subagent_cmd}{broker_client};
        }
        if ($broker_client) {
            $self->check_agent_messages($broker_client);
        }
        
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
                print STDERR "[DEBUG][Chat] Command returned ai_prompt, length=" . length($ai_prompt) . "\n" if should_log('DEBUG');
                $input = $ai_prompt;
                # Fall through to AI processing below
            } else {
                next;  # Command handled, get next input
            }
        }
        
        # Display user message (if not already from a command)
        # Note: After multiline command, $input contains the content, not the /command
        print STDERR "[DEBUG][Chat] Before display check: input starts with /? " . ($input =~ /^\// ? "YES" : "NO") . "\n" if should_log('DEBUG');
        unless ($input =~ /^\//) {
            print STDERR "[DEBUG][Chat] Calling display_user_message with input length=" . length($input) . "\n" if should_log('DEBUG');
            $self->display_user_message($input);
        }
        
        # NOTE: User message is added to session history by WorkflowOrchestrator AFTER processing
        # Do NOT add here - that would create duplicates
        # WorkflowOrchestrator handles adding both user message and assistant response atomically
        
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
            
            # DON'T print "CLIO: " prefix here - we'll print it in on_chunk when actual content arrives
            # This prevents the prefix from appearing for tool-only responses or system messages
            # Start the inline spinner (will animate until first chunk arrives)
            $self->{spinner}->start();
            print STDERR "[DEBUG][Chat] Started spinner (will print CLIO: prefix on first content chunk)\n" if should_log('DEBUG');
            
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
                
                # Reset system message flag when we start outputting text
                $self->{_last_was_system_message} = 0;
                
                # Stop progress spinner on first chunk (AI is now responding)
                # Now that we have actual content, print "CLIO: " prefix and stop spinner
                # Also check _prepare_for_next_iteration flag set by WorkflowOrchestrator
                # after tool execution - this ensures proper prefix on continuation chunks
                if (!$first_chunk_received || $self->{_prepare_for_next_iteration}) {
                    $spinner->stop();  # Removes spinner character
                    
                    # Print "CLIO: " prefix now that we know there's actual content
                    print $self->colorize("CLIO: ", 'ASSISTANT');
                    STDOUT->flush() if STDOUT->can('flush');
                    
                    if ($self->{_prepare_for_next_iteration}) {
                        # This is a continuation after tool execution
                        $self->{_prepare_for_next_iteration} = 0;  # Clear the flag
                        print STDERR "[DEBUG][Chat] Printed CLIO: prefix for continuation after tools\n" if $self->{debug};
                    }
                    
                    # Enable pagination for text responses (agent is speaking directly)
                    # This will be left enabled unless/until tools are invoked
                    if (!$first_chunk_received) {
                        $self->{pagination_enabled} = 1;
                        print STDERR "[DEBUG][Chat] Pagination ENABLED for text response\n" if $self->{debug};
                    }
                    
                    print STDERR "[DEBUG][Chat] First chunk received, printed CLIO: prefix and removed spinner\n" if $self->{debug};
                    $first_chunk_received = 1;
                }
                
                # Clear the _need_agent_prefix flag if set (no longer needed)
                if ($self->{_need_agent_prefix}) {
                    $self->{_need_agent_prefix} = 0;  # Clear the flag
                    print STDERR "[DEBUG][Chat] Cleared _need_agent_prefix flag\n" if $self->{debug};
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
                        
                        # Use helper for consistent line counting
                        my $line_count_delta = $self->_count_visual_lines($self->{_streaming_markdown_buffer});
                        $self->{line_count} += $line_count_delta;
                        
                        # Reset markdown buffer
                        $self->{_streaming_markdown_buffer} = '';
                        $markdown_line_count = 0;
                        $last_flush_time = $current_time;
                        
                        # Check pagination using agent streaming helper (ignores tool flag)
                        # Agent text should paginate even when tools are executing
                        if ($self->_should_pagination_trigger_for_agent_streaming()) {
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
                
                # Mark that tools have been invoked - disables pagination in writeline()
                # so user doesn't have to press space during tool output.
                # Note: _tools_invoked_this_request is checked in _should_pagination_trigger()
                # Agent streaming output is NOT affected by this flag and remains paginated
                $self->{_tools_invoked_this_request} = 1;
                
                print STDERR "[DEBUG][Chat] Tool execution marked (pagination still enabled for agent text)\n" if $self->{debug};
                print STDERR "[DEBUG][Chat] Tool called: $tool_name\n" if $self->{debug};
            };
            
            # Display thinking/reasoning content from reasoning models
            # Shows content dimmed to distinguish from actual response
            my $thinking_active = 0;
            my $on_thinking = sub {
                my ($content, $signal) = @_;
                
                # Handle start/end signals from native providers (Anthropic)
                if (defined $signal) {
                    if ($signal eq 'start') {
                        $thinking_active = 1;
                        # Stop spinner if running and show thinking header
                        $spinner->stop();
                        print $self->colorize("CLIO: ", 'ASSISTANT');
                        print $self->colorize("\x{26A1} Reasoning...\n", 'DIM');
                        STDOUT->flush() if STDOUT->can('flush');
                        return;
                    }
                    elsif ($signal eq 'end') {
                        $thinking_active = 0;
                        # Print separator before regular content
                        print $self->colorize("\x{2500}" x 40 . "\n", 'DIM');
                        STDOUT->flush() if STDOUT->can('flush');
                        # Reset first_chunk_received so CLIO: prefix prints for actual response
                        $first_chunk_received = 0;
                        return;
                    }
                }
                
                # Thinking content delta
                return unless defined $content && length($content);
                
                # For OpenAI-compatible reasoning_content (no start/end signals),
                # auto-detect start on first chunk
                if (!$thinking_active) {
                    $thinking_active = 1;
                    $spinner->stop();
                    print $self->colorize("CLIO: ", 'ASSISTANT');
                    print $self->colorize("\x{26A1} Reasoning...\n", 'DIM');
                    STDOUT->flush() if STDOUT->can('flush');
                }
                
                # Print thinking content dimmed
                print $self->colorize($content, 'DIM');
                STDOUT->flush() if STDOUT->can('flush');
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
                
                # Display system message with format based on theme
                # Check if theme uses inline format (like console theme)
                my $tool_format = 'box';  # default
                if ($self->{theme_mgr} && $self->{theme_mgr}->can('get_tool_display_format')) {
                    $tool_format = $self->{theme_mgr}->get_tool_display_format();
                }
                
                if ($tool_format eq 'inline') {
                    # Inline format: [SYSTEM] message
                    my $prefix = $self->colorize("[SYSTEM] ", 'SYSTEM');
                    my $msg = $self->colorize($message, 'DATA');
                    print "$prefix$msg\n";
                    print "\n";  # Add blank line AFTER system message for separation
                    STDOUT->flush() if STDOUT->can('flush');
                    $self->{line_count} += 2;  # Message + blank line
                } else {
                    # Box-drawing format (default):
                    # {dim}┌──┤ {agent_label}SYSTEM{reset}
                    # {dim}└─ {data}message{reset}
                    my $header_conn = $self->colorize("\x{250C}\x{2500}\x{2500}\x{2524} ", 'DIM');
                    my $header_name = $self->colorize("SYSTEM", 'ASSISTANT');
                    my $footer_conn = $self->colorize("\x{2514}\x{2500} ", 'DIM');
                    my $footer_msg = $self->colorize($message, 'DATA');
                    
                    print "$header_conn$header_name\n";
                    print "$footer_conn$footer_msg\n";
                    print "\n";  # Add blank line AFTER system message for separation
                    STDOUT->flush() if STDOUT->can('flush');
                    $self->{line_count} += 3;  # Header + footer + blank line
                }
                $self->{_last_was_system_message} = 1;  # Mark that we just displayed a system message
                
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
                on_thinking => $on_thinking,  # Display reasoning/thinking content
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
                # Save session after successful responses
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
    
    # Exit gracefully (goodbye message will be shown by caller)
    print "\n";
}

=head2 check_agent_messages($broker_client)

Check for and display messages from sub-agents.

=cut

sub check_agent_messages {
    my ($self, $broker_client) = @_;
    
    return unless $broker_client;
    
    # Poll user inbox
    my $messages = eval { $broker_client->poll_user_inbox() };
    
    # Handle errors gracefully
    if ($@) {
        print STDERR "[WARN][Chat] Failed to poll agent inbox: $@\n" if $self->{debug};
        return;
    }
    
    return unless $messages && @$messages;
    
    # Display each message
    for my $msg (@$messages) {
        $self->display_agent_message($msg);
    }
}

=head2 display_agent_message($msg)

Display a single message from a sub-agent with proper formatting.

=cut

sub display_agent_message {
    my ($self, $msg) = @_;
    
    my $from = $msg->{from} || 'unknown';
    my $type = $msg->{type} || 'generic';
    my $content = $msg->{content} || '';
    my $time = localtime($msg->{timestamp}) if $msg->{timestamp};
    my $id = $msg->{id};
    
    # Color and icon by message type
    my ($color, $icon, $label);
    if ($type eq 'question') {
        $color = 'YELLOW';
        $icon = '❓';
        $label = 'QUESTION';
    } elsif ($type eq 'blocked') {
        $color = 'RED';
        $icon = '🚫';
        $label = 'BLOCKED';
    } elsif ($type eq 'complete') {
        $color = 'GREEN';
        $icon = '✓';
        $label = 'COMPLETE';
    } elsif ($type eq 'status') {
        $color = 'CYAN';
        $icon = 'ℹ';
        $label = 'STATUS';
    } elsif ($type eq 'discovery') {
        $color = 'MAGENTA';
        $icon = '💡';
        $label = 'DISCOVERY';
    } else {
        $color = 'WHITE';
        $icon = '📨';
        $label = uc($type);
    }
    
    # Print separator
    print $self->colorize("─" x 80, 'DIM'), "\n";
    
    # Print header
    my $header = "$icon Agent Message: " . $self->colorize("$from", 'BOLD') . 
                 " [$label]";
    if ($time) {
        $header .= $self->colorize(" ($time)", 'DIM');
    }
    print $header, "\n";
    
    # Print content
    if (ref($content) eq 'HASH') {
        # Structured content (e.g., status updates)
        for my $key (sort keys %$content) {
            next unless defined $content->{$key};
            my $value = $content->{$key};
            print "  " . $self->colorize("$key:", 'DIM') . " $value\n";
        }
    } else {
        # Simple text content
        print $self->colorize($content, $color), "\n";
    }
    
    # Print footer with reply hint for questions
    if ($type eq 'question' || $type eq 'blocked') {
        # Ring terminal bell to alert user
        print "\a";  # Bell character
        print $self->colorize("ACTION REQUIRED: ", 'YELLOW');
        print "Reply with: " . $self->colorize("/subagent reply $from <your-response>", 'BOLD'), "\n";
    }
    
    print $self->colorize("─" x 80, 'DIM'), "\n";
    print "\n";
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
    
    # Track cache file modification time for periodic checking
    # This allows us to detect when background check completes and finds an update
    my $cache_file = File::Spec->catfile('.clio', 'update_check_cache');
    if (-f $cache_file) {
        $self->{_update_cache_mtime} = (stat($cache_file))[9];
        print STDERR "[DEBUG][Chat] Tracking update cache mtime: $self->{_update_cache_mtime}\n" 
            if should_log('DEBUG');
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
                # Reset terminal state first, while still connected to parent TTY
        # This must happen BEFORE closing any file descriptors
        # Use light reset - no ANSI codes needed since we're about to close output
        eval {
            require CLIO::Compat::Terminal;
            CLIO::Compat::Terminal::reset_terminal_light();  # ReadMode(0) only
        };
        
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

=head2 check_for_update_notification

Check if background update check has completed and notify user if update available.

This is called periodically during the main loop to detect when the background
update check (forked process) completes and writes a new result to the cache.

=cut

sub check_for_update_notification {
    my ($self) = @_;
    
    # Only check periodically - not on every loop iteration
    # Track last check time in $self->{_last_update_check}
    my $now = time();
    my $last_check = $self->{_last_update_check} || 0;
    my $check_interval = 30;  # Check every 30 seconds
    
    return if ($now - $last_check) < $check_interval;
    
    $self->{_last_update_check} = $now;
    
    # Load Update module
    eval {
        require CLIO::Update;
    };
    return if $@;
    
    my $cache_file = File::Spec->catfile('.clio', 'update_check_cache');
    
    # Check if cache file has been modified since we last checked
    return unless -f $cache_file;
    
    my $current_mtime = (stat($cache_file))[9];
    my $last_known_mtime = $self->{_update_cache_mtime} || 0;
    
    # No change - return early
    return if $current_mtime <= $last_known_mtime;
    
    # Cache file has been updated - check if there's a new update available
    print STDERR "[DEBUG][Chat] Update cache modified, checking for new updates\n"
        if should_log('DEBUG');
    
    my $updater = CLIO::Update->new(debug => $self->{debug});
    my $update_info = $updater->get_available_update();
    
    # Update our tracked mtime
    $self->{_update_cache_mtime} = $current_mtime;
    
    # If update is available and we haven't already notified, display message
    if ($update_info && $update_info->{cached} && !$update_info->{up_to_date}) {
        # Only notify if we haven't already shown this version
        my $version = $update_info->{version} || 'unknown';
        my $notified_version = $self->{_notified_update_version} || '';
        
        if ($version ne $notified_version) {
            $self->display_system_message("An update is available ($version). Run " . 
                $self->colorize('/update install', 'command') . " to upgrade.");
            $self->{_notified_update_version} = $version;
        }
    }
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
        'openrouter' => 'OpenRouter',
        'claude' => 'Anthropic Claude',
        'anthropic' => 'Anthropic',
        'qwen' => 'Qwen',
        'deepseek' => 'DeepSeek',
        'gemini' => 'Google Gemini',
        'google' => 'Google Gemini',
        'grok' => 'xAI Grok',
        'sam' => 'SAM (Local)',
        'llama.cpp' => 'llama.cpp (Local)',
        'lmstudio' => 'LM Studio',
    );
    
    my $provider_display = $provider ? ($provider_names{$provider} || ucfirst($provider)) : 'Unknown';
    
    # Strip CLIO provider prefix from model name for display
    # "github_copilot/gpt-4.1" -> "gpt-4.1" (provider shown after @)
    my $display_model = $model;
    require CLIO::Providers;
    if ($display_model =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i && CLIO::Providers::provider_exists($1)) {
        $display_model = $2;
        # Also update provider_display from the model prefix if provider wasn't set
        unless ($provider) {
            $provider_display = $provider_names{$1} || ucfirst($1);
        }
    }
    my $model_with_provider = "$display_model\@$provider_display";
    
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

=head2 _prepopulate_session_data

Prepopulate session data from APIs before first AI request.

This fetches:
- GitHub Copilot quota from copilot_internal/user API
- Model billing information
- User account info (login, plan)

Called at session start to provide accurate /usage data immediately.

=cut

=head2 _check_auth_migration

Check if GitHub Copilot authentication needs migration or if tokens are invalid.
Shows a one-time notice if the stored tokens are from an older auth method.
If tokens are expired/invalid, offers automatic re-authentication.

=cut

sub _check_auth_migration {
    my ($self) = @_;
    
    # Only check for GitHub Copilot provider
    my $provider = $self->{config} ? $self->{config}->get('api_provider') : '';
    return unless $provider && $provider eq 'github_copilot';
    
    eval {
        require CLIO::Core::GitHubAuth;
        my $auth = CLIO::Core::GitHubAuth->new(debug => 0);
        
        # Check for migration needs first
        my $reason = $auth->needs_reauth();
        if ($reason) {
            $self->display_system_message($reason);
            return;
        }
        
        # Validate stored tokens are actually still valid
        # This catches the case where CLIO hasn't been used in a while
        # and the GitHub OAuth token has been revoked
        if ($auth->is_authenticated()) {
            my $validation = $auth->validate_github_token();
            
            if ($validation && !$validation->{valid}) {
                my $status = $validation->{status} || 'unknown';
                
                if ($status == 401 || $status == 403) {
                    # Token is expired/revoked - offer re-authentication
                    $self->display_system_message(
                        "Your GitHub authentication has expired (HTTP $status). "
                        . "Starting re-authentication..."
                    );
                    
                    # Clear stale tokens
                    $auth->clear_tokens();
                    
                    # Trigger login flow through Command handler
                    eval {
                        if ($self->{command_handler} && $self->{command_handler}{api_cmd}) {
                            $self->{command_handler}{api_cmd}->handle_login_command();
                        } else {
                            $self->display_system_message(
                                "Please run /api login to re-authenticate."
                            );
                        }
                    };
                    if ($@) {
                        print STDERR "[WARN][Chat] Auto re-auth failed: $@\n" if should_log('WARNING');
                        $self->display_system_message(
                            "Automatic re-authentication failed. Please run /api login manually."
                        );
                    }
                } elsif ($validation->{error} && $validation->{error} =~ /Network/) {
                    # Network error - silently skip (might be offline)
                    print STDERR "[DEBUG][Chat] Skipping token validation - network error\n" if should_log('DEBUG');
                }
            }
        }
    };
    # Silently ignore errors - auth check is non-critical
}

sub _prepopulate_session_data {
    my ($self) = @_;
    
    return unless $self->{session};
    
    my $provider = $self->{config} ? $self->{config}->get('provider') : '';
    
    # Only prepopulate for GitHub Copilot provider
    return unless $provider && $provider eq 'github_copilot';
    
    print STDERR "[DEBUG][Chat] Prepopulating session data from CopilotUserAPI\n" if should_log('DEBUG');
    
    eval {
        require CLIO::Core::CopilotUserAPI;
        my $user_api = CLIO::Core::CopilotUserAPI->new(debug => $self->{debug});
        
        # Try cached first, then fetch if no cache
        my $user_data = $user_api->get_cached_user() || $user_api->fetch_user();
        
        return unless $user_data;
        
        # Get session state
        my $state;
        if ($self->{session}->can('state')) {
            $state = $self->{session}->state();
        } else {
            $state = $self->{session};  # Might be State directly
        }
        
        return unless $state;
        
        # Prepopulate quota info
        my $premium = $user_data->get_premium_quota();
        if ($premium) {
            $state->{quota} = {
                entitlement => $premium->{entitlement},
                used => $premium->{used},
                available => $premium->{entitlement} - $premium->{used},
                percent_remaining => $premium->{percent_remaining},
                overage_used => $premium->{overage_count} || 0,
                overage_permitted => $premium->{overage_permitted},
                reset_date => $user_data->{quota_reset_date_utc} || 'unknown',
                last_updated => time(),
            };
            
            # Also store user info for display
            $state->{copilot_user} = {
                login => $user_data->{login},
                copilot_plan => $user_data->{copilot_plan},
                access_type_sku => $user_data->{access_type_sku},
            };
            
            print STDERR "[DEBUG][Chat] Prepopulated quota: " . 
                "$premium->{used}/$premium->{entitlement} " .
                "($premium->{percent_remaining}% remaining)\n" if should_log('DEBUG');
        }
        
        # Prepopulate model info from config
        my $model = $self->{config}->get('model') || 'unknown';
        if ($model ne 'unknown' && !$state->{billing}{model}) {
            $state->{billing}{model} = $model;
            
            # Get billing multiplier (strip provider prefix for API lookup)
            eval {
                require CLIO::Core::GitHubCopilotModelsAPI;
                my $models_api = CLIO::Core::GitHubCopilotModelsAPI->new(debug => $self->{debug});
                # Strip provider prefix: "github_copilot/gpt-4.1" -> "gpt-4.1"
                my $api_model = $model;
                require CLIO::Providers;
                if ($api_model =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i && CLIO::Providers::provider_exists($1)) {
                    $api_model = $2;
                }
                my $billing = $models_api->get_model_billing($api_model);
                if ($billing && defined $billing->{multiplier}) {
                    $state->{billing}{multiplier} = $billing->{multiplier};
                    print STDERR "[DEBUG][Chat] Prepopulated model billing: $api_model -> " .
                        "$billing->{multiplier}x\n" if should_log('DEBUG');
                }
            };
            # Ignore errors - just means no multiplier info
        }
    };
    
    if ($@) {
        print STDERR "[DEBUG][Chat] Prepopulation failed (non-fatal): $@\n" if should_log('DEBUG');
    }
}

sub _build_prompt {
    my ($self, $mode) = @_;
    $mode ||= 'normal';  # Default to normal mode
    
    my @parts;
    
    # 1. Model name in brackets
    my $model = 'unknown';
    if ($self->{ai_agent} && $self->{ai_agent}->{api}) {
        $model = $self->{ai_agent}->{api}->get_current_model() || 'unknown';
        # Remove date suffix (e.g., -20250219)
        $model =~ s/-20\d{6}$//;
        # For prompt display, abbreviate provider prefix
        # "github_copilot/gpt-4.1" -> "gpt-4.1"
        # "openrouter/deepseek/deepseek-r1" -> "deepseek/deepseek-r1"
        require CLIO::Providers;
        if ($model =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i && CLIO::Providers::provider_exists($1)) {
            $model = $2;
        }
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
    my $indicator_color = $mode eq 'collaboration' ? 'collab_prompt' : 'prompt_indicator';
    push @parts, $self->colorize(":", $indicator_color);
    
    # Join with spaces (except before colon)
    my $prompt_text = join(' ', @parts[0..$#parts-1]);  # All but last
    $prompt_text .= $parts[-1];  # Add colon without space
    $prompt_text .= ' ';  # Add space after colon for input
    
    return $prompt_text;
}

sub get_input {
    my ($self) = @_;
    
        # Stop spinner before any input operation
    # The spinner MUST be stopped before readline/input to prevent interference with typing
    if ($self->{spinner} && $self->{spinner}->{running}) {
        $self->{spinner}->stop();
        print STDERR "[DEBUG][Chat] Spinner stopped at get_input entry\n" if should_log('DEBUG');
    }
    
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

=head2 display_system_messages

Display multiple system messages as a grouped output with box-drawing format.

Arguments:
- $messages: Arrayref of message strings

Example output:
  ┌──┤ SYSTEM
  ├─ Saving session...
  └─ Session saved.

=cut

sub display_system_messages {
    my ($self, $messages) = @_;
    
    return unless $messages && ref($messages) eq 'ARRAY' && @$messages;
    
    # Header
    my $header_conn = $self->colorize("\x{250C}\x{2500}\x{2500}\x{2524} ", 'DIM');
    my $header_name = $self->colorize("SYSTEM", 'ASSISTANT');
    print "$header_conn$header_name\n";
    
    # Messages
    for my $i (0 .. $#{$messages}) {
        my $is_last = ($i == $#{$messages});
        my $connector = $is_last ? "\x{2514}\x{2500} " : "\x{251C}\x{2500} ";
        my $conn_colored = $self->colorize($connector, 'DIM');
        my $msg_colored = $self->colorize($messages->[$i], 'DATA');
        print "$conn_colored$msg_colored\n";
    }
    
    STDOUT->flush() if STDOUT->can('flush');
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

=head2 display_command_row

Display a command with description (for help output)

Arguments:
- $command: Command string (e.g., "/cmd <args>")
- $description: Description text
- $cmd_width: Optional command column width (default: 25)

=cut

sub display_command_row {
    my ($self, @args) = @_;
    return $self->{display}->display_command_row(@args);
}

=head2 display_tip

Display a tip/hint line with muted styling

Arguments:
- $text: Tip text

=cut

sub display_tip {
    my ($self, @args) = @_;
    return $self->{display}->display_tip(@args);
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
    
    # Stop spinner before displaying collaboration prompt
    # The spinner MUST be stopped and MUST NOT restart until user response is complete
    if ($self->{spinner} && $self->{spinner}->{running}) {
        $self->{spinner}->stop();
        print STDERR "[DEBUG][Chat] Spinner stopped at request_collaboration entry\n" if should_log('DEBUG');
    }
    
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
        
        # Check if we need to paginate using helper for consistent threshold
        my $pause_threshold = $self->_get_pagination_threshold();
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
        # Context is rendered markdown, need pagination support
        my $rendered_context = $self->render_markdown($context);
        my @context_lines = split /\n/, $rendered_context;
        
        # Display context header with color
        my $context_line = $self->colorize("Context: ", 'SYSTEM');
        
        if (@context_lines) {
            # Print header with first line inline (same pattern as message display)
            $context_line .= shift(@context_lines);
            print $context_line, "\n";
            $self->{line_count}++;
            
            # Check pagination AFTER first line using helper for consistent threshold
            my $pause_threshold = $self->_get_pagination_threshold();
            if ($self->{line_count} >= $pause_threshold && 
                $self->{pagination_enabled} && 
                -t STDIN) {
                
                my $response = $self->pause(0);
                if ($response eq 'Q') {
                    return;  # User quit during context display
                }
                $self->{line_count} = 0;
            }
        } else {
            # Just the header with no content
            print $context_line, "\n";
            $self->{line_count}++;
        }
        
        # Print remaining context lines with pagination
        for my $line (@context_lines) {
            print $line, "\n";
            $self->{line_count}++;
            
            # Check if we need to paginate BEFORE hitting terminal height using helper
            my $pause_threshold = $self->_get_pagination_threshold();
            if ($self->{line_count} >= $pause_threshold && 
                $self->{pagination_enabled} && 
                -t STDIN) {
                
                my $response = $self->pause(0);  # Non-streaming mode
                if ($response eq 'Q') {
                    # User quit - stop displaying context
                    return;
                }
                # Reset line count for next page
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
            
            # Process the command (but don't exit - return to collaboration prompt)
            my ($continue, $ai_prompt) = $self->handle_command($response);
            
            # If command requested exit, cancel collaboration
            if (!$continue) {
                print $self->colorize("(Collaboration ended by /exit command)\n", 'SYSTEM');
                return undef;
            }
            
            # If command generated an AI prompt (e.g., /multi-line), display and return it
            if ($ai_prompt) {
                # Display the actual content, not the command
                print $self->colorize("YOU: ", 'USER'), $ai_prompt, "\n";
                return $ai_prompt;
            }
            
            # Otherwise, command was handled silently - don't display it, just return to prompt
            # Commands like /context, /git diff process and output their own results
            # No need to show "YOU: /command" in the chat
            print $self->colorize("CLIO: ", 'ASSISTANT'), "(Command processed. What's your response?)\n";
            next;
        }
        
        # Regular response - display and return
        print $self->colorize("YOU: ", 'USER'), $response, "\n";
        return $response;
    }
}

=head2 display_paginated_list

Display a list with BBS-style pagination.
Uses unified pagination prompt: arrows to navigate, Q to quit, any key for more.

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
    $total_pages = 1 if $total_pages < 1;
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
    
    # Switch to alternate screen buffer for clean pagination
    print "\e[?1049h";  # Enter alternate screen buffer
    
    # Track if hint has been shown
    my $show_hint = !$self->{_pagination_hint_shown};
    
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
        my $showing = sprintf("Showing %d-%d of %d", $start + 1, $end + 1, $total);
        print $self->colorize($showing, 'DIM'), "\n";
        
        # Show hint on first pagination (unified BBS-style)
        if ($show_hint) {
            print $self->{theme_mgr}->get_pagination_hint(0) . "\n";  # full hint with arrows
            $self->{_pagination_hint_shown} = 1;
            $show_hint = 0;
        }
        
        # BBS-style pagination prompt (unified with pause())
        my $current = $current_page + 1;
        my $prompt = $self->{theme_mgr}->get_pagination_prompt($current, $total_pages, ($total_pages > 1));
        print $prompt;
        
        # Get user input (single key)
        ReadMode('cbreak');
        my $key = ReadKey(0);
        
        # Handle arrow keys (escape sequences)
        if ($key eq "\e") {
            my $seq = ReadKey(0) . ReadKey(0);
            ReadMode('normal');
            
            # Clear prompt line
            print "\e[2K\e[" . $self->{terminal_width} . "D";
            
            if ($seq eq '[A' && $current_page > 0) {
                # Up arrow - previous page
                $current_page--;
                next;
            }
            elsif ($seq eq '[B' && $current_page < $total_pages - 1) {
                # Down arrow - next page
                $current_page++;
                next;
            }
            # Other escape sequences - treat as continue
        } else {
            ReadMode('normal');
        }
        
        # Handle Q to quit
        if ($key && $key =~ /^[qQ]$/) {
            last;
        }
        
        # Any other key - advance to next page or exit if at end
        if ($current_page < $total_pages - 1) {
            $current_page++;
        } else {
            last;  # At last page, any key exits
        }
    }
    
    # Ensure terminal mode is restored
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
    
    # Reset pagination state and ENABLE pagination for help output
    $self->{line_count} = 0;
    $self->{pages} = [];
    $self->{current_page} = [];
    $self->{page_index} = 0;
    $self->{pagination_enabled} = 1;  # Enable pagination for help
    
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
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/reset', 'help_command'), 'Reset terminal state');
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
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/undo', 'help_command'), 'Revert AI changes from last turn');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/undo diff', 'help_command'), 'Show changes since last turn');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/undo list', 'help_command'), 'List recent snapshots');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/mcp', 'help_command'), 'MCP server status');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/mcp list', 'help_command'), 'List MCP tools');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/mcp add <name> <cmd>', 'help_command'), 'Add MCP server');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/mcp remove <name>', 'help_command'), 'Remove MCP server');
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
    
    push @help_lines, $self->colorize("DEVICES & REMOTE", 'command_subheader');
    push @help_lines, $self->colorize("─" x 62, 'dim');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/device', 'help_command'), 'List registered devices');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/device add <name> <host>', 'help_command'), 'Register device');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/device info <name>', 'help_command'), 'Device details');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/group', 'help_command'), 'List device groups');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/group add <name> <devs...>', 'help_command'), 'Create group');
    push @help_lines, "";
    
    push @help_lines, $self->colorize("OTHER", 'command_subheader');
    push @help_lines, $self->colorize("─" x 62, 'dim');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/billing', 'help_command'), 'API usage stats');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/stats', 'help_command'), 'Process memory stats');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/stats history', 'help_command'), 'Memory usage timeline');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/context', 'help_command'), 'Manage context files');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/exec <cmd>', 'help_command'), 'Run shell command');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/style, /theme', 'help_command'), 'Appearance settings');
    push @help_lines, sprintf("  %-30s %s", $self->colorize('/debug', 'help_command'), 'Toggle debug mode');
    push @help_lines, "";
    
    # Output with pagination
    for my $line (@help_lines) {
        last unless $self->writeline($line, markdown => 0);
    }
    
    # Reset pagination state after display
    $self->{line_count} = 0;
    $self->{pagination_enabled} = 0;
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

=head2 clear_screen

Clear the terminal screen and repaint from buffer

=cut

sub clear_screen {
    my ($self) = @_;
    
    # Clear screen using ANSI code
    print "\e[2J\e[H";  # Clear screen + home cursor
}

sub display_usage_summary {
    my ($self, @args) = @_;
    return $self->{display}->display_usage_summary(@args);
}

=head2 handle_billing_command



=head2 handle_read_command

=head2 display_paginated_content

Display content with BBS-style full pagination.
Uses unified pagination prompt: arrows to navigate, Q to quit, any key for more.

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
    
    # Switch to alternate screen buffer for clean pagination
    print "\e[?1049h";  # Enter alternate screen buffer
    
    # Track if hint has been shown
    my $show_hint = !$self->{_pagination_hint_shown};
    
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
        my $status = sprintf("Lines %d-%d of %d", $start + 1, $end + 1, $total_lines);
        $status .= " | $filepath" if $filepath;
        print $self->colorize($status, 'DIM'), "\n";
        
        # Show hint on first pagination (unified BBS-style)
        if ($show_hint) {
            print $self->{theme_mgr}->get_pagination_hint(0) . "\n";  # full hint with arrows
            $self->{_pagination_hint_shown} = 1;
            $show_hint = 0;
        }
        
        # BBS-style pagination prompt (unified with pause())
        my $current = $current_page + 1;
        my $prompt = $self->{theme_mgr}->get_pagination_prompt($current, $total_pages, ($total_pages > 1));
        print $prompt;
        
        # Get user input (single key)
        ReadMode('cbreak');
        my $key = ReadKey(0);
        
        # Handle arrow keys (escape sequences)
        if ($key eq "\e") {
            my $seq = ReadKey(0) . ReadKey(0);
            ReadMode('normal');
            
            # Clear prompt line
            print "\e[2K\e[" . $self->{terminal_width} . "D";
            
            if ($seq eq '[A' && $current_page > 0) {
                # Up arrow - previous page
                $current_page--;
                next;
            }
            elsif ($seq eq '[B' && $current_page < $total_pages - 1) {
                # Down arrow - next page
                $current_page++;
                next;
            }
            # Escape key (no sequence) - quit
            if ($seq !~ /^\[/) {
                last;
            }
            # Other sequences - treat as continue
        } else {
            ReadMode('normal');
        }
        
        # Handle Q to quit
        if ($key && $key =~ /^[qQ]$/) {
            last;
        }
        
        # Any other key - advance to next page or exit if at end
        if ($current_page < $total_pages - 1) {
            $current_page++;
        } else {
            last;  # At last page, any key exits
        }
    }
    
    # Ensure terminal mode is restored
    ReadMode('restore');
    
    # Exit alternate screen buffer and return to normal view
    print "\e[?1049l";  # Exit alternate screen buffer (restores original screen)
}


=head2 handle_fix_command

Propose fixes for code problems

=cut


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
            # Display system message with three-color box-drawing format:
            # {dim}┌──┤ {agent_label}SYSTEM{reset}
            # {dim}└─ {data}message{reset}
            my $header_conn = $self->colorize("\x{250C}\x{2500}\x{2500}\x{2524} ", 'DIM');
            my $header_name = $self->colorize("SYSTEM", 'ASSISTANT');
            my $footer_conn = $self->colorize("\x{2514}\x{2500} ", 'DIM');
            my $footer_msg = $self->colorize($msg->{content}, 'DATA');
            
            print "$header_conn$header_name\n";
            print "$footer_conn$footer_msg\n";
        }
        elsif ($msg->{type} eq 'error') {
            # Display error with box-drawing format
            my $header_conn = $self->colorize("\x{250C}\x{2500}\x{2500}\x{2524} ", 'DIM');
            my $header_name = $self->colorize("ERROR", 'ERROR');
            my $footer_conn = $self->colorize("\x{2514}\x{2500} ", 'DIM');
            my $footer_msg = $self->colorize($msg->{content}, 'DATA');
            
            print "$header_conn$header_name\n";
            print "$footer_conn$footer_msg\n";
        }
        elsif ($msg->{type} eq 'warning') {
            # Display warning with box-drawing format
            my $header_conn = $self->colorize("\x{250C}\x{2500}\x{2500}\x{2524} ", 'DIM');
            my $header_name = $self->colorize("WARNING", 'WARNING');
            my $footer_conn = $self->colorize("\x{2514}\x{2500} ", 'DIM');
            my $footer_msg = $self->colorize($msg->{content}, 'DATA');
            
            print "$header_conn$header_name\n";
            print "$footer_conn$footer_msg\n";
        }
        elsif ($msg->{type} eq 'success') {
            # Display success with box-drawing format
            my $header_conn = $self->colorize("\x{250C}\x{2500}\x{2500}\x{2524} ", 'DIM');
            my $header_name = $self->colorize("SUCCESS", 'SUCCESS');
            my $footer_conn = $self->colorize("\x{2514}\x{2500} ", 'DIM');
            my $footer_msg = $self->colorize($msg->{content}, 'DATA');
            
            print "$header_conn$header_name\n";
            print "$footer_conn$footer_msg\n";
        }
        elsif ($msg->{type} eq 'info') {
            # Display info with box-drawing format
            my $header_conn = $self->colorize("\x{250C}\x{2500}\x{2500}\x{2524} ", 'DIM');
            my $header_name = $self->colorize("INFO", 'ASSISTANT');
            my $footer_conn = $self->colorize("\x{2514}\x{2500} ", 'DIM');
            my $footer_msg = $self->colorize($msg->{content}, 'DATA');
            
            print "$header_conn$header_name\n";
            print "$footer_conn$footer_msg\n";
        }
    }
}

=head2 pause

Display pagination prompt and wait for keypress (BBS-style prompt)

=cut

sub pause {
    my ($self, $streaming) = @_;
    $streaming ||= 0;  # Default to non-streaming mode
    
    # Refresh terminal size before pagination (handle resize)
    $self->refresh_terminal_size();
    
    # Track if this is the first pagination prompt in the session
    # Show a hint the first time to help users learn the controls
    my $show_hint = !$self->{_pagination_hint_shown};
    my $hint_was_shown = 0;  # Track if we showed hint this time (for cleanup)
    
    my $total_pages = scalar(@{$self->{pages}}) || 1;
    my $current = ($self->{page_index} || 0) + 1;
    
    # In streaming mode, simplified prompt (can't navigate)
    if ($streaming) {
        # Show hint on first pagination
        if ($show_hint) {
            print $self->{theme_mgr}->get_pagination_hint(1) . "\n";  # streaming=true
            $self->{_pagination_hint_shown} = 1;
            $hint_was_shown = 1;
        }
        
        # Compact streaming prompt
        my $prompt = $self->{theme_mgr}->get_pagination_prompt($current, 1, 0);
        print $prompt;
        
        ReadMode('cbreak');
        my $key = ReadKey(0);
        ReadMode('normal');
        
        # Always clear pagination prompt lines (even during tool execution)
        # The _in_tool_execution flag should not prevent clearing user prompts
        if ($hint_was_shown) {
            print "\e[2K";  # Clear prompt line
            print "\e[" . $self->{terminal_width} . "D";  # Move to start of prompt line
            print "\e[1A";  # Move up to hint line
            print "\e[2K";  # Clear hint line
        } else {
            print "\e[2K\e[" . $self->{terminal_width} . "D";  # Clear prompt line only and move to start
        }
        
        $key = uc($key) if $key;
        return $key || 'C';
    }
    
    # Non-streaming mode: full arrow navigation
    while (1) {
        # Show hint on first pagination
        if ($show_hint) {
            print $self->{theme_mgr}->get_pagination_hint(0) . "\n";  # streaming=false
            $self->{_pagination_hint_shown} = 1;
            $hint_was_shown = 1;
            $show_hint = 0;  # Don't show again in this loop
        }
        
        # Build pagination prompt using theme
        my $prompt = $self->{theme_mgr}->get_pagination_prompt($current, $total_pages, ($total_pages > 1));
        print $prompt;
        
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
                $current = $self->{page_index} + 1;
                $self->redraw_page();
                next;  # Stay in pause loop
            }
            elsif ($seq eq '[B' && $self->{page_index} < $total_pages - 1) {
                # Down arrow - go to next page
                $self->{page_index}++;
                $current = $self->{page_index} + 1;
                $self->redraw_page();
                next;  # Stay in pause loop
            }
            # Unrecognized escape sequence - continue output
        }
        
        # Regular key handling - restore normal mode first
        ReadMode('normal');
        
        # Always clear pagination prompt lines (even during tool execution)
        # The _in_tool_execution flag should not prevent clearing user prompts
        if ($hint_was_shown) {
            print "\e[2K";  # Clear prompt line
            print "\e[" . $self->{terminal_width} . "D";  # Move to start of prompt line
            print "\e[1A";  # Move up to hint line
            print "\e[2K";  # Clear hint line
        } else {
            print "\e[2K\e[" . $self->{terminal_width} . "D";  # Clear prompt line only and move to start
        }
        
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
        print STDERR "[DEBUG][Chat] Markdown rendering issue (falling back to raw): $@\n" if $@;
        print STDERR "[DEBUG][Chat] Markdown render returned empty/undef, using raw text\n" 
            if !$@ && (!defined $rendered || $rendered eq '');
        return $text;  # Fallback to raw text rather than breaking output
    }
    
    return $rendered;
}

=head2 _get_pagination_threshold

Get the threshold at which pagination should pause (internal helper).

Returns the line count threshold based on terminal height. Centralized
to ensure streaming and writeline use the same pagination point.

=cut

sub _get_pagination_threshold {
    my ($self) = @_;
    
    # Reserve 2 lines for pagination prompt and buffer
    return ($self->{terminal_height} // 24) - 2;
}

=head2 _count_visual_lines($text)

Count the visual lines in text (internal helper).

Splits text by newline and returns the count. Used to normalize line 
counting between streaming (chunks) and writeline (full text) paths.

Arguments:
- $text: Text to count (may be undef/empty)

Returns: Number of visual lines (0 for empty/undef)

=cut

sub _count_visual_lines {
    my ($self, $text) = @_;
    
    return 0 unless defined $text && length($text) > 0;
    
    # Split by newline and count, preserving empty lines
    my @lines = split /\n/, $text, -1;
    
    # If text ends with newline, the last element is empty - don't double-count
    # Example: "line1\nline2\n" splits to ['line1', 'line2', ''] (3 elements, 2 lines)
    pop @lines if @lines && $lines[-1] eq '';
    
    return scalar(@lines);
}

=head2 _should_pagination_trigger

Check if pagination should be triggered (internal helper).

Determines if we should pause for pagination based on:
- Current line count vs threshold
- Whether pagination is enabled
- Whether we're in tool execution mode
- Terminal interactivity

Returns: 1 if pause needed, 0 otherwise

=cut

sub _should_pagination_trigger {
    my ($self) = @_;
    
    return 0 unless -t STDIN;  # Not interactive
    return 0 unless $self->{pagination_enabled};  # Pagination disabled
    return 0 if $self->{_tools_invoked_this_request};  # During tool execution
    
    my $threshold = $self->_get_pagination_threshold();
    return 1 if $self->{line_count} >= $threshold;
    
    return 0;
}

=head2 _should_pagination_trigger_for_agent_streaming

Check if pagination should trigger for agent streaming output (on_chunk callback).

This is DIFFERENT from _should_pagination_trigger which also checks _tools_invoked_this_request.
Agent streaming should always be paginated when enabled, regardless of tool execution state.
Tool output gets separate pagination control via the tool flag.

Returns: 1 if pause needed, 0 otherwise

=cut

sub _should_pagination_trigger_for_agent_streaming {
    my ($self) = @_;
    
    return 0 unless -t STDIN;  # Not interactive
    return 0 unless $self->{pagination_enabled};  # Pagination disabled
    # NOTE: Do NOT check _tools_invoked_this_request - agent text should paginate even during tool execution
    
    my $threshold = $self->_get_pagination_threshold();
    return 1 if $self->{line_count} >= $threshold;
    
    return 0;
}

=head2 writeline

Write a line with pagination support and automatic markdown rendering.

This is the STANDARD output method for all CLIO output. All print statements
in Commands modules should be migrated to use writeline for consistent
pagination and markdown rendering.

Arguments:
- $text: Text to output (required)
- %opts: Optional hash with:
  - newline => 0|1 (default: 1) - append newline
  - markdown => 0|1 (default: 1) - render markdown
  - raw => 0|1 (default: 0) - skip all processing, direct print

Returns: 1 to continue, 0 if user quit (pressed Q)

=cut

sub writeline {
    my ($self, $text, %opts) = @_;
    
    # Handle legacy positional args for backwards compatibility
    # Old signature: writeline($text, $newline, $use_markdown)
    if (!%opts && defined $_[2]) {
        # Legacy call with positional args
        $opts{newline} = $_[2];
        $opts{markdown} = $_[3] if defined $_[3];
    }
    
    # Defaults: newline on, markdown on
    my $newline = exists $opts{newline} ? $opts{newline} : 1;
    my $use_markdown = exists $opts{markdown} ? $opts{markdown} : 1;
    my $raw = $opts{raw} || 0;
    
    # Check if pagination should be active
    # Pagination is controlled by pagination_enabled flag OR force_paginate option
    # This prevents pagination during tool execution while allowing it for user-facing output
    my $should_paginate = $opts{force_paginate} || $self->{pagination_enabled};
    
    # Handle undef text gracefully
    $text //= '';
    
    # Raw mode: direct print, no processing
    if ($raw) {
        print $text;
        print "\n" if $newline;
        return 1;
    }
    
    # Render markdown if enabled (default: yes)
    if ($use_markdown && $self->{enable_markdown} && length($text) > 0) {
        $text = $self->render_markdown($text);
    }
    
    # Skip pagination if not interactive (pipe mode, redirected, etc.)
    my $is_interactive = -t STDIN;
    
    # Split rendered text into actual lines (markdown can produce multiple lines)
    # This ensures pagination counts VISUAL lines, not input lines
    my @lines = split /\n/, $text, -1;  # -1 preserves trailing empty strings
    
    # If text doesn't end with newline and caller wants one, the last "line" gets a newline
    # If text had multiple newlines, we print all those lines
    my $last_idx = $#lines;
    
    for my $i (0 .. $last_idx) {
        my $line = $lines[$i];
        my $is_last = ($i == $last_idx);
        my $print_newline = $is_last ? $newline : 1;  # All but last get newline, last gets caller's choice
        
        # Check pagination BEFORE printing to prevent scrolling past content
        # Only paginate when: interactive, pagination enabled, and outputting a line
        if ($print_newline && $is_interactive && $should_paginate) {
            my $pause_threshold = $self->_get_pagination_threshold();
            
            if ($self->{line_count} >= $pause_threshold) {
                # Save current page to buffer before pausing
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
        
        # Now print the line
        print $line;
        print "\n" if $print_newline;
        
        # Track the line for page navigation (only when pagination active)
        if ($print_newline && $is_interactive && $should_paginate) {
            push @{$self->{current_page}}, $line;
            $self->{line_count}++;
        }
    }
    
    return 1;  # Continue
}

=head2 writeln

Alias for writeline with simpler signature. Outputs text with newline,
auto-renders markdown, and supports pagination.

=cut

sub writeln {
    my ($self, $text, %opts) = @_;
    return $self->writeline($text, %opts);
}

=head2 blank

Output a blank line with pagination tracking.

=cut

sub blank {
    my ($self) = @_;
    return $self->writeline('', markdown => 0);
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
    
    my ($header, $input_line) = @{$self->{theme_mgr}->get_confirmation_prompt(
        "Record session learnings?",
        "yes/no",
        "skip"
    )};
    
    print $header, "\n";
    print $input_line;
    my $response = <STDIN>;
    chomp $response if defined $response;
    
    # Skip if user declined
    return unless $response && $response =~ /^y(es)?$/i;
    
    # Now prompt for the actual learning text
    print $self->colorize("\nEnter learnings (Ctrl+D when done):\n> ", 'PROMPT');
    
    # Read multi-line input
    my @lines;
    while (my $line = <STDIN>) {
        push @lines, $line;
    }
    my $learning_text = join('', @lines);
    chomp $learning_text if defined $learning_text;
    
    # Skip if empty
    return unless $learning_text && $learning_text =~ /\S/;
    
    # Store as discovery in LTM
    # Parse simple format: treat each sentence/line as a separate discovery
    my @learnings;
    
    # Split by newlines or periods followed by space
    my @parts = split /(?:\n|\.)\s*/, $learning_text;
    
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
    
    # Save LTM - use current working directory for cross-platform compatibility
    eval {
        my $ltm_file = File::Spec->catfile(Cwd::getcwd(), '.clio', 'ltm.json');
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
