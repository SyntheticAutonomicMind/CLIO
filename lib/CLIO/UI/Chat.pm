# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Chat;

use strict;
use warnings;
use CLIO::Core::Logger qw(log_debug log_info log_warning);
use CLIO::Security::InvisibleCharFilter qw(filter_invisible_chars has_invisible_chars);
use CLIO::Util::TextSanitizer qw(sanitize_text set_sanitize_mode strip_session_markers);
use CLIO::UI::Markdown;
use CLIO::UI::ANSI;
use CLIO::UI::Theme;
use CLIO::UI::Terminal qw(box_char ui_char);
use CLIO::UI::ProgressSpinner;
use POSIX qw(_exit);
use CLIO::UI::CommandHandler;
use CLIO::UI::Display;
use CLIO::UI::HostProtocol;
use CLIO::UI::StreamingController;
use CLIO::UI::PaginationManager;
use CLIO::UI::Chat::Header;
use CLIO::UI::Chat::Security;
use CLIO::UI::Chat::Help;
use utf8;
use open ':std', ':encoding(UTF-8)';
use Carp qw(croak);
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
        max_buffer_size => 100, # Keep last 100 messages
        # Pagination control - managed by PaginationManager ($self->{pager})
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
    
    # Initialize markdown renderer with theme manager and terminal width
    $self->{markdown_renderer} = CLIO::UI::Markdown->new(
        debug => $args{debug},
        theme_mgr => $self->{theme_mgr},
        terminal_width => $self->{terminal_width} - 4,  # 4-space indent used by writeline/writeagent
    );
    
    # Initialize host protocol (structured GUI communication)
    $self->{host_proto} = CLIO::UI::HostProtocol->new(debug => $args{debug});
    
    # Get terminal size (width and height)
    eval {
        my ($width, $height) = GetTerminalSize();
        $self->{terminal_width} = $width if $width && $width > 0;
        $self->{terminal_height} = $height if $height && $height > 0;
    };
    
    # Update markdown renderer with actual terminal width
    $self->{markdown_renderer}{terminal_width} = $self->{terminal_width} - 4;  # 4-space indent
    
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
    
    # Initialize streaming controller
    $self->{streaming} = CLIO::UI::StreamingController->new(ui => $self);

    # Initialize pagination manager
    $self->{pager} = CLIO::UI::PaginationManager->new(ui => $self);
    $self->{header} = CLIO::UI::Chat::Header->new($self);
    $self->{security} = CLIO::UI::Chat::Security->new($self);
    $self->{help} = CLIO::UI::Chat::Help->new($self);
    
    if (-t STDIN) {
        $self->setup_tab_completion();
    }
    
    # Apply saved sanitize_mode from config
    if ($self->{config}) {
        my $mode = $self->{config}->get('sanitize_mode');
        set_sanitize_mode($mode) if $mode;
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
    
    # Update markdown renderer with new terminal width
    $self->{markdown_renderer}{terminal_width} = $self->{terminal_width} - 4 if $self->{markdown_renderer};  # 4-space indent
}

=head2 flush_output_buffer

Flush pending streaming output.
Called by WorkflowOrchestrator before executing tools to prevent
tool output from appearing before agent text.

This is part of the handshake mechanism to fix message ordering issues
where streaming content was being displayed after tool execution output.

=cut

sub flush_output_buffer {
    my ($self) = @_;
    return $self->{streaming}->flush_for_tools();
}

=head2 agent_name

Return the agent display name (e.g. "CLIO").

Reads from $ENV{CLIO_AGENT_NAME} on every call so environment changes
(e.g. setting the var via /init or a wrapper script after startup)
are picked up immediately.

=cut

sub agent_name {
    my ($self) = @_;
    return $self->{header}->agent_name();
}

=head2 _get_broker_client

Resolve the broker client from available sources (ai_agent or subagent command handler).

=cut

sub _get_broker_client {
    my ($self) = @_;
    
    if ($self->{ai_agent} && $self->{ai_agent}->can('broker_client')) {
        my $bc = $self->{ai_agent}->broker_client();
        return $bc if $bc;
    }
    if ($self->{command_handler} && $self->{command_handler}{subagent_cmd}) {
        return $self->{command_handler}{subagent_cmd}{broker_client};
    }
    return undef;
}

=head2 streaming_controller

Return the streaming controller instance.
=cut

sub streaming_controller { $_[0]->{streaming} }

=head2 reset_streaming_state

Reset the streaming state to allow a new agent prefix to be printed.
Called by WorkflowOrchestrator after tool execution completes, before
the next AI iteration starts streaming.

This ensures that each new AI response chunk after tool execution
gets a proper agent prefix.

=cut

sub reset_streaming_state {
    my ($self) = @_;
    
    # Mark that we need a new CLIO: prefix on next chunk
    $self->{_need_agent_prefix} = 1;
    
    log_debug('Chat', "Streaming state reset - next chunk will get agent prefix");
    
    return 1;
}

=head2 begin_tool_execution

Signal that the agent is entering tool execution mode. Called by
WorkflowOrchestrator before processing tool calls.

=cut

sub begin_tool_execution {
    my ($self) = @_;
    $self->{_in_tool_execution} = 1;
}

=head2 end_tool_execution

Signal that tool execution has completed. Called by WorkflowOrchestrator
after all tool calls in a round are processed.

=cut

sub end_tool_execution {
    my ($self) = @_;
    $self->{_in_tool_execution} = 0;
}

=head2 prepare_for_iteration

Signal that the next streaming response should get fresh UI state
(new prefix, blank line separator). Called by WorkflowOrchestrator
when continuing after tool execution.

=cut

sub prepare_for_iteration {
    my ($self) = @_;
    $self->{_prepare_for_next_iteration} = 1;
    log_debug('Chat', "Set prepare_for_next_iteration flag for next API call");
}

=head2 clear_system_message_flag

Clear the flag indicating that the last displayed content was a system
message. Called by WorkflowOrchestrator when the agent produces visible
output that supersedes a system message.

=cut

sub clear_system_message_flag {
    my ($self) = @_;
    $self->{_last_was_system_message} = 0;
}

=head2 show_busy_indicator

Show the busy spinner to indicate system is processing.
Called when CLIO is busy (tool execution, API processing, etc.)

This ensures users always see visual feedback when the system is working.

=cut

sub show_busy_indicator {
    my ($self) = @_;
    
    # Skip spinner in non-interactive mode (--input, sub-agents)
    # No human is watching, and the forked spinner child can orphan
    return 0 unless -t STDOUT;
    
    # In host mode, skip ASCII spinner - host renders its own
    if ($self->{host_proto}->active()) {
        $self->{host_proto}->emit_status('thinking');
        $self->{host_proto}->emit_spinner_start('Thinking...');
        return 1;
    }
    
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
            $self->{spinner}->stop() if $self->{spinner}->is_running();
        }
    }
    
    if ($needs_recreation) {
        $self->{spinner} = CLIO::UI::ProgressSpinner->new(
            theme_mgr => $self->{theme_mgr},  # Use theme-managed frames
            delay => 100000,
            inline => 1,
        );
        log_debug('Chat', "Created spinner in show_busy_indicator");
    }
    
    # Only start if not already running
    if (!$self->{spinner}->is_running()) {
        $self->{spinner}->start();
        log_debug('Chat', "Busy indicator started");
    }
    
    return 1;
}

=head2 hide_busy_indicator

Hide the busy spinner when system is no longer processing.
Called when outputting data or waiting for user input.

=cut

sub hide_busy_indicator {
    my ($self) = @_;
    
    # In host mode, just emit the protocol event
    if ($self->{host_proto}->active()) {
        $self->{host_proto}->emit_spinner_stop();
        return 1;
    }
    
    # Stop spinner if it exists and is running
    # Use is_running() (validates child process is alive)
    if ($self->{spinner} && $self->{spinner}->is_running()) {
        $self->{spinner}->stop();
        log_debug('Chat', "Busy indicator stopped");
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
    
    # If no provider is configured, show a helpful system message
    my $provider = $self->{config} ? $self->{config}->get('provider') : undef;
    if (!$provider) {
        $self->display_system_message("To get started, use /api to configure a provider.");
    }
    
    # Emit session metadata to host application
    if ($self->{host_proto}->active() && $self->{session}) {
        my $session_name = $self->{session}->session_name() // '';
        $self->{host_proto}->emit_session(
            id   => $self->{session}->id() || '',
            name => $session_name,
            dir  => $self->{session}->state()->{working_directory} || '',
        );
        my $model = ($self->{config} ? $self->{config}->get('model') : '') || '';
        $self->{host_proto}->emit_title($self->agent_name() . " - " .
            ($session_name || 'New Session') .
            ($model ? " ($model)" : ''));
    }
    
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
        
        # Get broker client for agent message routing
        my $broker_client = $self->_get_broker_client();
        
        # Agent messages are now handled via readline's event_callback
        # which polls the broker during input wait. No need to poll here.
        
        # Get user input
        my $input = $self->get_input();

        # Parse image attachments from input (@path/to/image.png syntax)
        my @image_attachments;
        if (defined $input && length($input) > 0) {
            eval {
                require CLIO::Util::ImageAttachment;
                my ($cleaned, @paths) = CLIO::Util::ImageAttachment::parse_attachments_from_text($input);
                if (@paths) {
                    $input = $cleaned;
                    for my $path (@paths) {
                        my $attachment = CLIO::Util::ImageAttachment->new($path);
                        if ($attachment) {
                            push @image_attachments, $attachment;
                        } else {
                            $self->display_error_message("Cannot attach image: $path");
                        }
                    }
                }
            };
            if ($@) {
                log_warning('Chat', "Image attachment parsing failed: $@");
            }
        }

        # Handle empty input
        next unless defined $input && length($input) > 0;

        # Sync readline history to session state for persistence (cap at 500 entries)
        if ($self->{readline} && $self->{session} && $self->{session}->state()) {
            my @hist = @{$self->{readline}->{history}};
            splice(@hist, 0, @hist - 500) if @hist > 500;
            $self->{session}->state()->{input_history} = \@hist;
        }
        
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
                log_debug('Chat', "Command returned ai_prompt, length=" . length($ai_prompt));
                $input = $ai_prompt;
                # Fall through to AI processing below
            } else {
                next;  # Command handled, get next input
            }
        }
        
        # Handle @agent-N message routing (direct user-to-agent chat)
        if ($input =~ /^\@(agent-\S+)\s+(.+)/s) {
            my ($target_agent, $msg_text) = ($1, $2);
            if ($broker_client) {
                eval {
                    $broker_client->send_message(
                        to => $target_agent,
                        content => $msg_text,
                        message_type => 'guidance',
                    );
                };
                if ($@) {
                    $self->display_error_message("Failed to send to $target_agent: $@");
                } else {
                    print $self->colorize("YOU -> " . uc($target_agent) . ": ", 'USER'), $msg_text, "\n";
                }
            } else {
                $self->display_error_message("No broker connection - spawn a sub-agent first");
            }
            next;
        }
        
        # Display user message (if not already from a command)
        # Note: After multiline command, $input contains the content, not the /command
        log_debug('Chat', "Before display check: input starts with /? " . ($input =~ /^\// ? "YES" : "NO"));
        unless ($input =~ /^\//) {
            log_debug('Chat', "Calling display_user_message with input length=" . length($input));
            $self->display_user_message($input);
        }
        
        # NOTE: User message is added to session history by WorkflowOrchestrator AFTER processing
        # Do NOT add here - that would create duplicates
        # WorkflowOrchestrator handles adding both user message and assistant response atomically
        
        # Process with AI agent (using streaming)
        if ($self->{ai_agent}) {
            $self->_process_ai_request($input, \@image_attachments);
        } else {
            $self->display_error_message("AI agent not initialized");
        }
        
        print "\n";
    }
    
    # Exit gracefully (goodbye message will be shown by caller)
    print "\n";
}


=head2 _process_ai_request($input)

Process user input through the AI agent with streaming callbacks.
Handles spinner, callbacks, session save, and error display.

=cut


=head2 _make_thinking_callback($spinner)

Build the on_thinking callback for reasoning model output display.
Returns a closure and a reference to the thinking_active flag.

=cut

sub _make_thinking_callback {
    my ($self, $spinner) = @_;
    my $thinking_active = 0;
    # Anthropic's adaptive thinking summarizer can return an empty string
    # for trivial reasoning (e.g. "which tool next" decisions) even though
    # the round-trip still produces a valid signature we bill for. Printing
    # the THINKING header on the start signal would render an empty box in
    # that case, so we defer the header/hrule until the first real content
    # chunk arrives. If 'end' fires without ever producing content we print
    # nothing at all.
    my $header_printed = 0;

    my $indent = '    ';

    # Use the StreamingController so thinking renders through the same
    # line-batching + Markdown + word-wrap pipeline as ordinary output.
    # This guarantees tables, bold/italic, lists, code blocks, and word
    # wrapping all behave identically between thinking and answer paths.
    my $think_stream = CLIO::UI::StreamingController->new(ui => $self);
    # Suppress the agent prefix / pager enable that the main callback
    # does on the first chunk - we render inside the THINKING box, not
    # next to a CLIO: prompt.
    $think_stream->reset();

    # Strip session markers from visible output. The AI may emit
    # <!--session:name--> or <!--session:{"title":"name"}--> markers;
    # these are internal control signals and must not appear in the
    # rendered thinking stream.
    my $strip_session_markers = \&strip_session_markers;

    my $flush_thinking = sub {
        # Route accumulated buffer through the StreamingController so it
        # is batched as Markdown (preserving tables / code blocks) and
        # then word-wrap+indented to match the rest of CLIO output.
        return unless defined $think_stream && $self->{streaming};
        # Temporarily swap the main controller's buffer state for the
        # thinking buffer, let flush() render it through the same
        # Markdown + word-wrap path the answer stream uses, then swap
        # back. We isolate the swap so the main controller's state
        # (in_table, in_code_block, md_line_count, first_line_printed)
        # cannot leak into the answer stream that immediately follows.
        # Note: first_chunk_received is intentionally NOT saved or
        # restored - StreamingController::flush never modifies it, and
        # the 'end' handler explicitly resets it to 0 below so the next
        # answer chunk re-emits the "CLIO: " prefix.
        my $saved_md  = $self->{streaming}{markdown_buffer};
        my $saved_ln  = $self->{streaming}{line_buffer};
        my $saved_flp = $self->{streaming}{first_line_printed};
        my $saved_tbl = $self->{streaming}{in_table};
        my $saved_cb  = $self->{streaming}{in_code_block};
        my $saved_cnt = $self->{streaming}{md_line_count};

        $self->{streaming}{markdown_buffer}     = $think_stream->{markdown_buffer};
        $self->{streaming}{line_buffer}         = $think_stream->{line_buffer};
        $self->{streaming}{first_line_printed}  = 1;
        $self->{streaming}{in_table}            = $think_stream->{in_table};
        $self->{streaming}{in_code_block}       = $think_stream->{in_code_block};
        $self->{streaming}{md_line_count}       = $think_stream->{md_line_count};

        # Strip session markers before rendering so the box never leaks
        # the structured form (the simple form is already handled by
        # the per-line strip inside StreamingController).
        $self->{streaming}{markdown_buffer} = $strip_session_markers->($self->{streaming}{markdown_buffer});
        $self->{streaming}{line_buffer}     = $strip_session_markers->($self->{streaming}{line_buffer});

        # Flush through the live StreamingController so the thinking
        # text is rendered with the same line-batching, Markdown, and
        # word-wrap as ordinary assistant output.
        $self->{streaming}->flush();

        # Capture post-flush state back into the thinking controller
        # so subsequent thinking chunks see an empty buffer.
        $think_stream->{markdown_buffer} = $self->{streaming}{markdown_buffer};
        $think_stream->{line_buffer}     = $self->{streaming}{line_buffer};
        $think_stream->{md_line_count}   = $self->{streaming}{md_line_count};
        $think_stream->{in_table}        = $self->{streaming}{in_table};
        $think_stream->{in_code_block}   = $self->{streaming}{in_code_block};

        # Restore the main streaming controller's pre-call state.
        $self->{streaming}{markdown_buffer}     = $saved_md;
        $self->{streaming}{line_buffer}         = $saved_ln;
        $self->{streaming}{first_line_printed}  = $saved_flp;
        $self->{streaming}{in_table}            = $saved_tbl;
        $self->{streaming}{in_code_block}       = $saved_cb;
        $self->{streaming}{md_line_count}       = $saved_cnt;
    };

    # Helper: print a dim hrule indented by 4 spaces (inline format only)
    my $print_thinking_hrule = sub {
        my $tool_format = 'inline';
        if ($self->{theme_mgr} && $self->{theme_mgr}->can('get_tool_display_format')) {
            $tool_format = $self->{theme_mgr}->get_tool_display_format();
        }
        return unless $tool_format eq 'inline';

        my ($term_cols) = GetTerminalSize();
        $term_cols ||= 80;
        my $rule_len = $term_cols - length($indent) - 1;
        $rule_len = 20 if $rule_len < 20;
        my $hz = box_char('horizontal');
        print $self->colorize("$indent" . ($hz x $rule_len), 'DIM') . "\n";
        STDOUT->flush() if STDOUT->can('flush');
    };

    # Helper: print the thinking header in three-color format
    my $print_thinking_header = sub {
        my $tool_format = 'inline';
        if ($self->{theme_mgr} && $self->{theme_mgr}->can('get_tool_display_format')) {
            $tool_format = $self->{theme_mgr}->get_tool_display_format();
        }
        if ($tool_format eq 'inline') {
            my $bullet = ui_char('bullet');
            my $b = $self->colorize($bullet, 'DIM');
            my $n = $self->colorize(" THINKING", 'ASSISTANT');
            print "$b$n\n";
        } else {
            print $self->colorize(box_char("topleft") . box_char("horizontal") x 2 . box_char("tleft") . " ", 'DIM');
            print $self->colorize("THINKING", 'ASSISTANT');
            print "\n";
        }
        STDOUT->flush() if STDOUT->can('flush');
    };

    my $callback = sub {
        my ($content, $signal) = @_;
        
        my $show_thinking = $self->{config} ? $self->{config}->get('show_thinking') : 0;
        return unless $show_thinking;
        
        if (defined $signal) {
            if ($signal eq 'start') {
                $think_stream->{line_buffer}     = '';
                $think_stream->{markdown_buffer} = '';
                $think_stream->{in_code_block}   = 0;
                $think_stream->{in_table}        = 0;
                $think_stream->{md_line_count}   = 0;
                $spinner->stop();
                # Defer header/hrule until the first real content chunk;
                # if no content ever arrives, skip them entirely (the
                # summarizer returned an empty string).
                # Do NOT mark thinking_active here: the empty-summary case
                # fires 'start' followed by 'end' with no content between
                # them, and we want the 'end' handler to suppress output
                # in that case.
                $header_printed = 0;
                return;
            }
            elsif ($signal eq 'end') {
                if ($header_printed) {
                    $flush_thinking->();
                    print "\n";
                    $print_thinking_hrule->();
                    print "\n";
                    STDOUT->flush() if STDOUT->can('flush');
                }
                $thinking_active = 0;
                $think_stream->{line_buffer}     = '';
                $think_stream->{markdown_buffer} = '';
                $think_stream->{in_code_block}   = 0;
                $think_stream->{in_table}        = 0;
                $think_stream->{md_line_count}   = 0;
                $header_printed = 0;
                # Don't reset first_chunk_received here. The thinking
                # callback must not mutate main-streaming iteration
                # state - that's owned by WorkflowOrchestrator's
                # reset_streaming_state + prepare_for_iteration. If we
                # reset mid-iteration, MiniMax-style interleaved
                # reasoning+content streams (Qwen3, MiniMax M3, etc.)
                # print a duplicate "CLIO: " prefix after every thinking
                # box mid-stream. Iteration control stays with the
                # WorkflowOrchestrator.
                return;
            }
        }

        return unless defined $content && length($content);

        if (!$header_printed) {
            $thinking_active = 1;
            $spinner->stop();
            # First real content chunk: print header and top hrule now.
            # If $header_printed is already set, we've already emitted them
            # for an earlier stream within the same callback's lifetime.
            $print_thinking_header->();
            $print_thinking_hrule->();
            $header_printed = 1;
        }

        # Feed the chunk into the thinking StreamingController so it
        # is batched with the same line + Markdown grouping the main
        # output stream uses, then flushed via the unified pipeline.
        # StreamingController already handles per-line session marker
        # stripping (both simple and structured forms), so we do not
        # need a second strip here.
        $think_stream->{line_buffer} .= $content;
        while ((my $pos = index($think_stream->{line_buffer}, "\n")) >= 0) {
            my $line = substr($think_stream->{line_buffer}, 0, $pos);
            $think_stream->{line_buffer} = substr($think_stream->{line_buffer}, $pos + 1);

            # Track Markdown context (table / code block) so partial
            # tables do not get flushed in the middle of a row.
            if ($line =~ /^```/) {
                $think_stream->{in_code_block} = !$think_stream->{in_code_block};
            }
            my $line_is_table_row = ($line =~ /^\|.*\|$/);
            my $line_is_blank     = ($line =~ /^\s*$/);
            if ($line_is_table_row) {
                $think_stream->{in_table} = 1;
            } elsif (!$line_is_blank && $think_stream->{in_table}) {
                $think_stream->{in_table} = 0;
            }

            # Strip HTML session comment markers on the per-line path
            # because the StreamingController's own line branch only
            # matches when the marker appears at end-of-line. The
            # thinking callback also receives markers mid-line (e.g.
            # in OpenRouter reasoning_summary deltas).
            $line = $strip_session_markers->($line);

            $think_stream->{markdown_buffer} .= $line . "\n";
            $think_stream->{md_line_count}++;
        }
        STDOUT->flush() if STDOUT->can('flush');
    };
    
    return $callback;
}

=head2 _make_system_message_callback($spinner)

Build the on_system_message callback for rate limits, server errors, etc.

=cut

sub _make_system_message_callback {
    my ($self, $spinner) = @_;
    
    return sub {
        my ($message) = @_;
        return unless defined $message;
        
        $self->hide_busy_indicator() if $self->can('hide_busy_indicator');
        print "\r\e[K";
        
        my $tool_format = 'box';
        if ($self->{theme_mgr} && $self->{theme_mgr}->can('get_tool_display_format')) {
            $tool_format = $self->{theme_mgr}->get_tool_display_format();
        }
        
        if ($tool_format eq 'inline') {
            my $bullet = ui_char('bullet');
            my $sep    = ui_char('separator');
            my $b = $self->colorize($bullet, 'DIM');
            my $n = $self->colorize(" SYSTEM ", 'SYSTEM');
            my $s = $self->colorize("$sep ", 'DIM');
            my $c = $self->colorize($message, 'WARNING');
            print "$b$n$s$c\n\n";
            STDOUT->flush() if STDOUT->can('flush');
            $self->{pager}->increment_lines(2);
        } else {
            my $header_conn = $self->colorize(box_char("topleft") . box_char("horizontal") x 2 . box_char("tleft") . " ", 'DIM');
            my $header_name = $self->colorize("SYSTEM", 'ASSISTANT');
            my $footer_conn = $self->colorize(box_char("bottomleft") . box_char("horizontal") . " ", 'DIM');
            my $footer_msg = $self->colorize($message, 'WARNING');
            
            print "$header_conn$header_name\n";
            print "$footer_conn$footer_msg\n\n";
            STDOUT->flush() if STDOUT->can('flush');
            $self->{pager}->increment_lines(3);
        }
        $self->{_last_was_system_message} = 1;
        log_debug('Chat', "System message: $message");
    };
}

=head2 _handle_ai_response($result, $alarm_count, $spinner)

Post-process AI response: save session, handle errors, display usage.

=cut

sub _handle_ai_response {
    my ($self, $result, $alarm_count, $spinner) = @_;

    # Disable the periodic ALRM handler installed by _process_ai_request.
    # The new helper is idempotent and safe to call multiple times.
    require CLIO::Core::Interrupt;
    CLIO::Core::Interrupt::uninstall_alrm_handler();
    log_debug('Chat', "Disabled periodic ALRM after streaming ($alarm_count interrupts)");
    
    $spinner->stop();
    $self->{streaming}->flush();
    $self->{pager}->line_count(0);
    
    my $accumulated_content = $self->{streaming}->content();
    my $first_chunk_received = $self->{streaming}->first_chunk_received();
    log_debug('Chat', "first_chunk_received=$first_chunk_received, accumulated_content_len=" . length($accumulated_content));
    
    if ($self->{debug} && $result->{metrics}) {
        my $m = $result->{metrics};
        log_debug('Chat', sprintf(
            "[METRICS] TTFT: %.2fs | TPS: %.1f | Tokens: %d | Duration: %.2fs\n",
            $m->{ttft} // 0, $m->{tps} // 0, $m->{tokens} // 0, $m->{duration} // 0
        ));
    }
    
    if ($accumulated_content) {
        $accumulated_content = strip_session_markers($accumulated_content);
        $accumulated_content = $self->_detect_system_warning_references($accumulated_content);
    }
    
    if ($result && $result->{messages_saved_during_workflow}) {
        log_debug('Chat', "Skipping session save - messages already saved during workflow");
        my $display_response = $result->{final_response} // '';
        $display_response = strip_session_markers($display_response);
        $display_response = $self->_detect_system_warning_references($display_response);
        $display_response = $self->_detect_and_display_images($display_response);
        $self->add_to_buffer('assistant', $display_response) if $display_response;
    } elsif ($result && $result->{final_response}) {
        log_debug('Chat', "Storing final_response in session (length=" . length($result->{final_response}) . ")");
        my $sanitized = sanitize_text($result->{final_response});
        $self->{session}->add_message('assistant', $sanitized);
        my $display_response = strip_session_markers($result->{final_response});
        $display_response = $self->_detect_system_warning_references($display_response);
        $display_response = $self->_detect_and_display_images($display_response);
        $self->add_to_buffer('assistant', $display_response);
    } elsif ($accumulated_content) {
        log_debug('Chat', "Storing accumulated_content in session (length=" . length($accumulated_content) . ")");
        my $sanitized = sanitize_text($accumulated_content);
        $self->{session}->add_message('assistant', $sanitized);
        $accumulated_content = $self->_detect_and_display_images($accumulated_content);
        $accumulated_content = $self->_detect_system_warning_references($accumulated_content);
        $self->add_to_buffer('assistant', $accumulated_content);
    }
    
    if (!$result || !$result->{success}) {
        my $error_msg = $result->{error} || $result->{final_response} || "No response received from AI";
        log_debug('Chat', "Error occurred: $error_msg");
        $self->display_error_message($error_msg);
        if ($self->{session}) {
            $self->{session}->add_message('system', "Error: $error_msg");
            $self->{session}->save();
            log_debug('Chat', "Session saved after error (preserving context)");
        }
    } else {
        if ($self->{session}) {
            $self->{session}->save();
            log_debug('Chat', "Session saved after successful response");
        }
    }
    
    $self->display_usage_summary();
    
    if ($self->{host_proto}->active() && $self->{session} && $self->{session}->{state}) {
        my $billing = $self->{session}->{state}->{billing};
        if ($billing && $billing->{requests} && @{$billing->{requests}}) {
            my $last = $billing->{requests}[-1];
            $self->{host_proto}->emit_tokens(
                prompt     => $last->{prompt_tokens} || 0,
                completion => $last->{completion_tokens} || 0,
                total      => $last->{total_tokens} || 0,
                model      => $billing->{model} || '',
            );
        }
    }
    
    if ($self->{session} && $self->{session}->can('state')) {
        my $state = $self->{session}->state();
        if ($state->{_premium_charge_message}) {
            print "\n";
            $self->display_system_message($state->{_premium_charge_message});
            delete $state->{_premium_charge_message};
        }
    }
    
    $self->{pager}->disable();
    log_debug('Chat', "Pagination DISABLED after response complete");
    $self->hide_busy_indicator();
}

=head2 _detect_system_warning_references($content)

Detect and log <system_warning>...</system_warning> tags in model responses.
These are provider-injected infrastructure messages that the model should
not be reproducing or acting on in its output. When found, logs the content
in debug mode and displays a SYSTEM notification.

Arguments:
- $content: Model response text

Returns: $content (unchanged - logging and display are side effects)

=cut

sub _detect_system_warning_references {
    my ($self, $content) = @_;
    return $content unless $content;
    
    my @matches = $content =~ /<system_warning>(.*?)<\/system_warning>/gs;
    
    if (@matches) {
        log_debug('Chat', "Model response contains " . scalar(@matches) . " <system_warning> reference(s)");
        for my $match (@matches) {
            my $truncated = length($match) > 200 ? substr($match, 0, 200) . "..." : $match;
            log_debug('Chat', "  system_warning content: $truncated");
        }
        $self->display_system_message("Model referenced API provider telemetry in its response");
    }
    
    return $content;
}

=head2 _detect_and_display_images($text)

Detect image URLs or base64 data in assistant response text and display them.
Handles markdown image syntax ![alt](url) and data URLs.

Only removes markdown image syntax when the image is successfully displayed
inline or saved. If display fails, the original markdown is preserved so the
user can still see the reference.

Returns the text with successfully displayed image references removed.

=cut

sub _detect_and_display_images {
    my ($self, $text) = @_;
    
    return $text unless defined $text && length($text) > 0;
    
    # Quick check: skip processing if no image patterns are present
    return $text unless $text =~ /!\[|data:image\//;
    
    eval {
        require CLIO::Util::ImageDisplay;
    };
    return $text if $@;  # ImageDisplay not available
    
    # Cache ImageDisplay instance on Chat object to avoid re-creating per response
    $self->{_image_display} //= CLIO::Util::ImageDisplay->new();
    my $display = $self->{_image_display};
    
    # Pattern 1: Markdown image syntax ![alt](url)
    # Only remove the markdown if the image was successfully displayed
    while ($text =~ /!\[([^\]]*)\]\(([^)]+)\)/) {
        my ($alt, $url) = ($1, $2);
        my $markdown = "!\[$alt\]($url)";
        my $displayed = 0;
        
        if ($url =~ /^data:image\/([^;]+);base64,(.+)/) {
            # Data URL - display directly (data is base64-encoded)
            my ($fmt, $b64) = ($1, $2);
            my $mime = "image/$fmt";
            my ($ok, $info) = $display->show_image($b64, $mime, filename => $alt, is_base64 => 1);
            if ($ok) {
                $displayed = 1;
                if ($info->{path}) {
                    print $self->colorize("[Image: ", 'DIM');
                    print $self->colorize($info->{path}, 'DATA');
                    print $self->colorize("]", 'DIM'), "\n";
                }
            }
        } elsif ($url =~ /^https?:\/\//) {
            # HTTP URL - download and display
            eval {
                require HTTP::Tiny;
                my $http = HTTP::Tiny->new(timeout => 30);
                my $response = $http->get($url);
                if ($response->{success}) {
                    my $mime = $response->{headers}{'content-type'} || 'image/png';
                    $mime =~ s/;.*$//;  # Remove charset
                    my ($ok, $info) = $display->show_image(
                        $response->{content}, $mime, filename => $alt
                    );
                    if ($ok) {
                        $displayed = 1;
                        if ($info->{path}) {
                            print $self->colorize("[Image: ", 'DIM');
                            print $self->colorize($info->{path}, 'DATA');
                            print $self->colorize("]", 'DIM'), "\n";
                        }
                    }
                } else {
                    log_warning('Chat', "Failed to download image $url: $response->{status} $response->{reason}");
                }
            };
            if ($@) {
                log_warning('Chat', "Error downloading image $url: $@");
            }
        }
        
        # Only remove markdown if image was successfully displayed
        if ($displayed) {
            $text =~ s/\Q$markdown\E//;
        } else {
            last;  # Stop processing - can't match same pattern again safely
        }
    }
    
    # Pattern 2: Standalone data URLs not in markdown
    # Only remove if successfully displayed
    while ($text =~ /(^|\s)(data:image\/([^;]+);base64,([A-Za-z0-9+\/=]+))($|\s)/) {
        my ($prefix, $full_data_url, $fmt, $b64, $suffix) = ($1, $2, $3, $4, $5);
        my $mime = "image/$fmt";
        my ($ok, $info) = $display->show_image($b64, $mime, is_base64 => 1);
        if ($ok) {
            $text =~ s/\Q$full_data_url\E//;
            if ($info->{path}) {
                print $self->colorize("[Image displayed]", 'DIM'), "\n";
            }
        } else {
            last;  # Stop if display failed
        }
    }
    
    return $text;
}

sub _process_ai_request {
    my ($self, $input, $image_attachments) = @_;

    log_debug("Chat", "About to process user input with AI agent");

    
    # Show progress indicator while waiting for AI response
    # Use persistent spinner stored on Chat object
    # This ensures tools can access the SAME spinner instance via context
    unless ($self->{spinner}) {
        # Create persistent spinner on first use with frames from current style
        # Use inline mode so spinner animates after text we print
        my $spinner_frames = $self->{theme_mgr}->get_spinner_frames();
        $self->{spinner} = CLIO::UI::ProgressSpinner->new(
            frames => $spinner_frames,
            delay => 100000,  # 100ms between frames for smooth block animation
            inline => 1,      # Inline mode: don't clear entire line, just the spinner
        );
        log_debug('Chat', "Created persistent spinner in inline mode");
    }
    
    # DON'T print agent prefix here - we'll print it in on_chunk when actual content arrives
    # This prevents the prefix from appearing for tool-only responses or system messages
    # Start the inline spinner (will animate until first chunk arrives)
    $self->{spinner}->start();
    log_debug('Chat', "Started spinner (will print agent prefix on first content chunk)");
    
    # Reference for use in closures below
    my $spinner = $self->{spinner};
    
    # Reset pagination state before streaming
    $self->{pager}->reset();
    $self->{stop_streaming} = 0;
    
    # Track whether tools were called - disable pagination during tool workflows
    $self->{_tools_invoked_this_request} = 0;
    
    my $final_metrics = undef;
    
    # Reset streaming controller and build on_chunk callback
    $self->{streaming}->reset();
    my $on_chunk = $self->{streaming}->make_on_chunk_callback(
        spinner    => $spinner,
        host_proto => $self->{host_proto},
    );
    
    # Track tool calls and display which tool is being executed
    my $current_tool = '';
    my $on_tool_call = sub {
        my ($tool_name) = @_;
        
        return unless defined $tool_name;
        return if $tool_name eq $current_tool;  # Skip if same tool
        
        $current_tool = $tool_name;
        
        # Mark that tools have been invoked - this suppresses pagination
        # in both streaming (agent text) and non-streaming (tool output)
        # paths via PaginationManager::should_trigger(). The model is
        # actively working, so the user should not have to press space
        # mid-workflow. The flag persists across iterations of a multi-step
        # tool workflow until the next user input resets it.
        $self->{_tools_invoked_this_request} = 1;

        $self->{host_proto}->emit_status('tools');
        $self->{host_proto}->emit_tool_start($tool_name);

        log_debug('Chat', "Tool execution marked (pagination suppressed for model workflow)");
        log_debug('Chat', "Tool called: $tool_name");
    };
    
    # Callback when a tool finishes execution
    my $on_tool_end = sub {
        my ($tool_name) = @_;
        return unless defined $tool_name;
        $self->{host_proto}->emit_tool_end($tool_name);
    };
    
    # Build thinking and system message callbacks via extracted methods
    my $on_thinking = $self->_make_thinking_callback($spinner);
    my $on_system_message = $self->_make_system_message_callback($spinner);
    
    # Get conversation history from session
    my $conversation_history = [];
    if ($self->{session} && $self->{session}->can('get_conversation_history')) {
        $conversation_history = $self->{session}->get_conversation_history() || [];
        log_debug('Chat', "Loaded " . scalar(@$conversation_history) . " messages from session history");
    }
    
    # Enable periodic signal delivery during streaming.
    # The ALRM handler is now provided by CLIO::Core::Interrupt, which
    # centralises the keystroke detection and keeps the signal handler
    # safe (no blocking ReadKey in signal context). The 250ms interval
    # gives sub-second worst-case latency for ESC detection across
    # streaming and long tool execution.
    #
    # Why we still keep an alarm_count tally: legacy callers and
    # _handle_ai_response() log how many ticks we fired during the
    # request. CLIO::Core::Interrupt exposes is_alrm_handler_active() so
    # _handle_ai_response() can detect a request that disabled the
    # interrupt machinery (e.g. piped -input mode) and skip the log line.
    require CLIO::Core::Interrupt;
    CLIO::Core::Interrupt::install_alrm_handler(
        session => $self->{session},
        interval => CLIO::Core::WorkflowOrchestrator::INTERRUPT_ALRM_INTERVAL(),
    );
    my $alarm_count = 0;  # Legacy metric; see _handle_ai_response()
    
    # Set cbreak mode for interrupt detection during agent execution
    # In normal/canonical mode, keypresses are buffered until Enter and
    # sysread() (used by ReadKey) can't see them. Cbreak mode makes each
    # keypress immediately available so _check_for_user_interrupt works.
    # ReadLine (for interact) manages its own mode internally.
    ReadMode(1);
    
    # Process request with streaming callback (match clio script pattern)
    log_debug('Chat', "Calling process_user_request...");
    my $result;
    eval {
        $result = $self->{ai_agent}->process_user_request($input, {
            on_chunk => $on_chunk,
            on_tool_call => $on_tool_call,  # Track which tools are being called
            on_tool_end => $on_tool_end,    # Track when tools finish
            on_thinking => $on_thinking,  # Display reasoning/thinking content
            on_system_message => $on_system_message,  # Display system messages
            conversation_history => $conversation_history,
            current_file => $self->{session}->{state}->{current_file},
            working_directory => $self->{session}->{state}->{working_directory},
            ui => $self,  # Pass UI object for interact tool
            spinner => $spinner,  # Pass spinner for interactive tools to stop
            image_attachments => $image_attachments,
        });
    };
    my $process_error = $@;
    
    # ALWAYS restore normal terminal mode, even on exception
    ReadMode(0);
    log_debug('Chat', "process_user_request returned, success=" . ($result ? ($result->{success} ? "yes" : "no") : "exception"));
    
    # Re-throw if process_user_request died
    croak $process_error if $process_error;
    
    # Post-process: save session, handle errors, display usage
    $self->_handle_ai_response($result, $alarm_count, $spinner);
}

=head2 check_agent_messages($broker_client)

Check for and display messages from sub-agents.

=cut

sub check_agent_messages {
    my ($self, $broker_client) = @_;
    return $self->{security}->check_agent_messages($broker_client);
}

=head2 _handle_agent_authorization($msg, $broker_client)

=cut

sub _handle_agent_authorization {
    my ($self, $msg, $broker_client) = @_;
    return $self->{security}->_handle_agent_authorization($msg, $broker_client);
}

=head2 display_agent_message($msg)

=cut

sub display_agent_message {
    my ($self, $msg) = @_;
    return $self->{security}->display_agent_message($msg);
}

=head2 display_header

Display the static retro BBS-style header (shown once at top)

=cut

=head2 check_for_updates_async

Check for updates in background (non-blocking)

=cut

sub check_for_updates_async {
    my ($self) = @_;
    return $self->{header}->check_for_updates_async();
}

=head2 check_for_update_notification

Check if background update check has completed and notify user if update available.

This is called periodically during the main loop to detect when the background
update check (forked process) completes and writes a new result to the cache.

=cut

sub check_for_update_notification {
    my ($self) = @_;
    return $self->{header}->check_for_update_notification();
}

sub display_header {
    my ($self) = @_;
    return $self->{header}->display_header();
}

=head2 _check_auth_migration

Check if GitHub Copilot authentication needs migration or if tokens are invalid.
Shows a one-time notice if the stored tokens are from an older auth method.
If tokens are expired/invalid, offers automatic re-authentication.

=cut

sub _check_auth_migration {
    my ($self) = @_;
    return $self->{header}->_check_auth_migration();
}

=head2 _prepopulate_session_data

Prepopulate session data from APIs before first AI request.

This fetches:
- GitHub Copilot quota from copilot_internal/user API
- Model billing information
- User account info (login, plan)

Called at session start to provide accurate /usage data immediately.

=cut

sub _prepopulate_session_data {
    my ($self) = @_;
    return $self->{header}->_prepopulate_session_data();
}

=head2 _build_prompt

=cut

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
    } elsif (!$self->{ai_agent}) {
        $model = 'NO PROVIDER';
    }
    push @parts, $self->colorize("[$model]", 'prompt_model');
    
    # 2. Directory name (basename only)
    use File::Basename;
    use Cwd 'getcwd';
    my $cwd = getcwd();
    my $dir_name = basename($cwd);
    push @parts, $self->colorize($dir_name, 'prompt_directory');
    
    # 3. Git branch (if in git repo) - read .git/HEAD directly (no subprocess)
    my $now = time();
    if (!defined $self->{_git_branch_cache} || ($now - ($self->{_git_branch_cache_time} || 0)) > 5) {
        my $branch = '';
        if (open my $fh, '<', '.git/HEAD') {
            my $head = <$fh>;
            close $fh;
            chomp $head if $head;
            if ($head && $head =~ m{^ref: refs/heads/(.+)$}) {
                $branch = $1;
            }
        }
        $self->{_git_branch_cache} = $branch;
        $self->{_git_branch_cache_time} = $now;
    }
    my $branch = $self->{_git_branch_cache};
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

# Strip invisible and dangerous Unicode characters from raw user input.
# This is the first security gate in the pipeline - runs before command
# handling and AI dispatch. Logs a warning if an injection attempt is detected.
sub _sanitize_user_input {
    my ($input) = @_;
    return $input unless defined $input;
    return $input if $input =~ /^\//;  # Pass slash-commands through unmodified

    if (has_invisible_chars($input)) {
        use CLIO::Security::InvisibleCharFilter qw(describe_invisible_chars);
        my $report = describe_invisible_chars($input);
        my @high = grep { $_->{severity} eq 'HIGH' } @{$report->{detections}};
        if (@high) {
            log_warning('Chat', "Invisible character injection attempt detected in user input - stripping: $report->{summary}");
        } else {
            log_debug('Chat', "Stripping invisible Unicode chars from user input: $report->{summary}");
        }
        $input = filter_invisible_chars($input);
    }
    return $input;
}

sub get_input {
    my ($self) = @_;
    
        # Stop spinner before any input operation
    # The spinner MUST be stopped before readline/input to prevent interference with typing
    if ($self->{spinner} && $self->{spinner}->is_running()) {
        $self->{spinner}->stop();
        log_debug('Chat', "Spinner stopped at get_input entry");
    }
    
    # Signal host that we're idle (waiting for user input)
    $self->{host_proto}->emit_status('idle');
    
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
        return _sanitize_user_input($input);
    }
    
    # Interactive mode with our custom readline and tab completion
    if ($self->{readline}) {
        my $prompt = $self->_build_prompt();
        
        # If broker is active, poll for agent messages during readline
        my $input;
        my $broker_client = $self->_get_broker_client();
        # ReadLine returns a hash ref { type => '__AGENT_EVENT__' } when an
        # agent event requires AI attention. Loop until we get real string
        # input - never leak control signals to the caller as if they were
        # user input.
        while (1) {
            if ($broker_client && !$self->{_broker_dead}) {
                my $event_cb = sub {
                    my $events = $self->_poll_broker_events($broker_client);
                    return 0 unless $events && @$events;
                    for my $event (@$events) {
                        if (($event->{message_type} || '') eq 'authorization_request') {
                            print "\r\e[K";
                            $self->_handle_agent_authorization($event->{_raw_msg}, $broker_client);
                        } else {
                            my $rendered = $self->_render_broker_event($event);
                            if ($rendered) {
                                print "\r\e[K";
                                print $rendered;
                            }
                        }
                    }
                    return 1;
                };
                $input = $self->{readline}->readline($prompt, event_callback => $event_cb);
            } else {
                $input = $self->{readline}->readline($prompt);
            }

            # Defensive: ReadLine should only return undef (EOF) or a string here.
            # If we ever see a hash ref, treat it as a control signal. Never
            # leak it to the caller.
            if (ref $input eq 'HASH') {
                my $sig_type = $input->{type} // '<unknown>';
                log_warning('Chat', "ReadLine control signal '$sig_type' - re-prompting");
                next;
            }
            last;  # Real string input (or undef for EOF)
        }
        
        # Handle Ctrl-D (EOF)
        if (!defined $input) {
            print "\n";
            return '/exit';
        }
        
        chomp $input;
        my $sanitized = _sanitize_user_input($input);
        
        # Check for // shortcut to launch multiline editor (before returning)
        if ($sanitized eq '//') {
            log_debug('Chat', "// shortcut detected, launching multiline editor");
            
            require CLIO::Core::Editor;
            my $editor = CLIO::Core::Editor->new(
                config => $self->{config},
                debug => $self->{debug}
            );
            
            if ($editor->check_editor_available()) {
                my $result = $editor->edit_multiline();
                if ($result->{success} && $result->{content} && length($result->{content}) > 0) {
                    my $multiline_content = $result->{content};
                    
                    # Return the multiline content - main input loop will display it
                    log_debug('Chat', "Multiline input received, length=" . length($multiline_content));
                    return $multiline_content;
                }
            } else {
                $self->display_system_message("Editor not available. Set \$EDITOR or /config editor <editor>");
            }
            
            # Empty or cancelled - return empty to prompt for new input
            return '';
        }
        
        return $sanitized;
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
    $input = _sanitize_user_input($input);
    
    # Check for // shortcut to launch multiline editor
    if ($input eq '//') {
        log_debug('Chat', "// shortcut detected, launching multiline editor");
        
        require CLIO::Core::Editor;
        my $editor = CLIO::Core::Editor->new(
            config => $self->{config},
            debug => $self->{debug}
        );
        
        if ($editor->check_editor_available()) {
            my $result = $editor->edit_multiline();
            if ($result->{success} && $result->{content} && length($result->{content}) > 0) {
                my $multiline_content = $result->{content};
                
                # Display the multiline content to user so it appears in chat history
                $self->display_user_message($multiline_content);
                
                log_debug('Chat', "Multiline input received, length=" . length($multiline_content));
                return $multiline_content;
            }
        } else {
            $self->display_system_message("Editor not available. Set \$EDITOR or /config editor <editor>");
        }
        
        # Empty or cancelled - return empty to prompt for new input
        return '';
    }
    
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
    
    my $tool_format = 'inline';
    if ($self->{theme_mgr} && $self->{theme_mgr}->can('get_tool_display_format')) {
        $tool_format = $self->{theme_mgr}->get_tool_display_format();
    }
    
    if ($tool_format eq 'inline') {
        my $bullet = ui_char('bullet');
        my $sep    = ui_char('separator');
        for my $msg (@$messages) {
            my $b = $self->colorize($bullet, 'DIM');
            my $n = $self->colorize(" SYSTEM ", 'SYSTEM');
            my $s = $self->colorize("$sep ", 'DIM');
            my $c = $self->colorize($msg, 'WARNING');
            print "$b$n$s$c\n";
        }
    } else {
        # Box format
        my $header_conn = $self->colorize(box_char("topleft") . box_char("horizontal") x 2 . box_char("tleft") . " ", 'DIM');
        my $header_name = $self->colorize("SYSTEM", 'ASSISTANT');
        print "$header_conn$header_name\n";
        
        for my $i (0 .. $#{$messages}) {
            my $is_last = ($i == $#{$messages});
            my $connector = $is_last ? box_char("bottomleft") . box_char("horizontal") . " " : box_char("tright") . box_char("horizontal") . " ";
            my $conn_colored = $self->colorize($connector, 'DIM');
            my $msg_colored = $self->colorize($messages->[$i], 'WARNING');
            print "$conn_colored$msg_colored\n";
        }
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

Display a warning message

=cut

sub display_warning_message {
    my ($self, @args) = @_;
    return $self->{display}->display_warning_message(@args);
}

=head2 display_info_message

Display an informational message

=cut

sub display_info_message {
    my ($self, @args) = @_;
    return $self->{display}->display_info_message(@args);
}

=head2 display_image

Display an image inline in the terminal or save to file.
Delegates to Display::display_image.

=cut

sub display_image {
    my ($self, @args) = @_;
    return $self->{display}->display_image(@args);
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
This is called by the interact tool to pause workflow
and get user response WITHOUT consuming additional AI Credits.

Arguments:
- $message: The collaboration message/question from agent
- $context: Optional context string

Returns: User's response string, or undef if cancelled

=cut

sub request_collaboration {
    my ($self, $message, $context, $options) = @_;
    $options ||= {};
    
    log_debug('Chat', "request_collaboration called");
    
    # Stop spinner before displaying collaboration prompt
    # The spinner MUST be stopped and MUST NOT restart until user response is complete
    if ($self->{spinner} && $self->{spinner}->is_running()) {
        $self->{spinner}->stop();
        log_debug('Chat', "Spinner stopped at request_collaboration entry");
    }
    
    # Enable pagination for collaboration responses
    $self->{pager}->enable();
    log_debug('Chat', "Pagination ENABLED for collaboration");
    
    # Display the agent's message using full markdown rendering (includes @-code to ANSI conversion)
    my $rendered_message = $self->render_markdown($message);
    
    # Display with pagination support
    my @lines = split /\n/, $rendered_message;
    print $self->colorize($self->agent_name() . ": ", 'ASSISTANT');
    
    # Print first line inline with prefix
    if (@lines) {
        print shift(@lines), "\n";
        $self->{pager}->increment_lines();
    }
    
    # Print remaining lines with pagination checks (indented, word-wrapped)
    my ($term_cols) = GetTerminalSize();
    $term_cols ||= 80;
    my $collab_indent = '    ';
    my $collab_avail = ($term_cols - 1) - length($collab_indent);
    $collab_avail = 20 if $collab_avail < 20;
    
    for my $line (@lines) {
        # Compute visible length
        my $visible = $line;
        $visible =~ s/\e\[[0-9;]*[A-Za-z]//g;
        $visible =~ s/\e\[\?\d+[lh]//g;
        $visible =~ s/\e\]8;;[^\e]*\e\\//g;
        
        # Skip wrapping for code/table lines
        my $is_preformatted = ($visible =~ /^  \S/ || $visible =~ /^\|/
                               || $visible =~ /^Code Block/);
        
        if ($is_preformatted || length($visible) <= $collab_avail) {
            print "$collab_indent$line\n";
        } else {
            # Word-wrap using StreamingController's method via a temp wrapper
            my @words = split /( +)/, $line;
            my $current = '';
            my $current_vis = 0;
            for my $w (@words) {
                my $wvis = $w;
                $wvis =~ s/\e\[[0-9;]*[A-Za-z]//g;
                $wvis =~ s/\e\[\?\d+[lh]//g;
                $wvis =~ s/\e\]8;;[^\e]*\e\\//g;
                my $wlen = length($wvis);
                
                if ($current eq '' && $w =~ /^ +$/) { next; }
                if ($current eq '') {
                    $current = $w;
                    $current_vis = $wlen;
                } elsif ($current_vis + $wlen > $collab_avail) {
                    $current =~ s/ +$//;
                    print "$collab_indent$current\n";
                    $self->{pager}->increment_lines();
                    if ($w =~ /^ +$/) {
                        $current = '';
                        $current_vis = 0;
                    } else {
                        $current = $w;
                        $current_vis = $wlen;
                    }
                } else {
                    $current .= $w;
                    $current_vis += $wlen;
                }
            }
            if (length($current)) {
                $current =~ s/ +$//;
                print "$collab_indent$current\n";
            }
        }
        $self->{pager}->increment_lines();
        
        # Check if we need to paginate
        if ($self->{pager}->should_trigger()) {
            my $response = $self->{pager}->pause(0);
            if ($response eq 'Q') {
                last;
            }
            $self->{pager}->reset_page();
        }
    }
    
    # Always display context indicator so users can identify collaboration tool usage
    my $context_text = ($context && length($context) > 0) ? $context : '(interact)';
    {
        my $rendered_context = $self->render_markdown($context_text);
        my @context_lines = split /\n/, $rendered_context;
        
        # Display context header with color
        my $context_line = $self->colorize("Session Interaction: ", 'SYSTEM');
        
        if (@context_lines) {
            $context_line .= shift(@context_lines);
            print $context_line, "\n";
            $self->{pager}->increment_lines();
            
            if ($self->{pager}->should_trigger()) {
                my $response = $self->{pager}->pause(0);
                if ($response eq 'Q') {
                    return;
                }
                $self->{pager}->reset_page();
            }
        } else {
            print $context_line, "\n";
            $self->{pager}->increment_lines();
        }
        
        # Print remaining context lines with pagination
        for my $line (@context_lines) {
            print $line, "\n";
            $self->{pager}->increment_lines();
            
            if ($self->{pager}->should_trigger()) {
                my $response = $self->{pager}->pause(0);
                if ($response eq 'Q') {
                    return;
                }
                $self->{pager}->reset_page();
            }
        }
    }
    
    # Disable pagination after displaying message (user will respond)
    $self->{pager}->disable();
    log_debug('Chat', "Pagination DISABLED after collaboration message");
    
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
    
    # Set up broker event multiplexing if requested
    my $listen_broker = $options->{listen_broker};
    my $broker_client = $options->{broker_client};
    my @accumulated_events;
    my $event_callback;
    
    # Resolve broker_client from SubAgent command handler if not explicitly provided
    if ($listen_broker && !$broker_client) {
        if ($self->{command_handler} && $self->{command_handler}{subagent_cmd}) {
            $broker_client = $self->{command_handler}{subagent_cmd}{broker_client};
        }
    }
    
    if ($listen_broker && $broker_client) {
        $event_callback = sub {
            # Poll broker for events (request-response, not push)
            my $events = $self->_poll_broker_events($broker_client);
            return 0 unless $events && @$events;
            
            my $need_redraw = 0;
            my $needs_ai_attention = 0;
            for my $event (@$events) {
                push @accumulated_events, $event;
                
                # Authorization requests need special interactive handling
                if (($event->{message_type} || '') eq 'authorization_request') {
                    # Clear readline, handle auth prompt, then redraw
                    print "\r\e[K";
                    $self->_handle_agent_authorization($event->{_raw_msg}, $broker_client);
                    $need_redraw = 1;
                } else {
                    my $rendered = $self->_render_broker_event($event);
                    if ($rendered) {
                        print "\r\e[K";  # Clear current line
                        print $rendered;
                        $need_redraw = 1;
                    }
                    
                    # Actionable agent messages should interrupt readline
                    # so the AI can process them without waiting for user input
                    if (($event->{type} || '') eq 'agent_message') {
                        my $mt = $event->{message_type} || '';
                        if ($mt eq 'question' || $mt eq 'complete' || $mt eq 'completion'
                            || $mt eq 'blocked' || $mt eq 'discovery') {
                            $needs_ai_attention = 1;
                        }
                    }
                }
            }
            
            # Return 'BREAK' to abort readline when agent needs AI attention
            return 'BREAK' if $needs_ai_attention;
            return $need_redraw;
        };
    }
    
    # Loop to handle multiple inputs (slash commands and @agent messages return to prompt)
    my $prefill = '';  # Preserved input from interrupted readline
    while (1) {
        # ReadLine sets raw mode internally and restores to normal on exit.
        # Since we're in cbreak mode for agent interrupt detection, we need
        # to re-enter cbreak after each readline call.
        my $response;
        if ($event_callback) {
            $response = $readline->readline($collab_prompt,
                event_callback => $event_callback,
                prefill => $prefill,
            );
        } else {
            $response = $readline->readline($collab_prompt);
        }
        $prefill = '';  # Reset prefill after each readline
        ReadMode(1);  # Re-enter cbreak for interrupt detection
        
        # Check for agent event interruption - readline was aborted because
        # an actionable agent message arrived that needs AI attention
        if (ref $response eq 'HASH' && ($response->{type} || '') eq '__AGENT_EVENT__') {
            my $partial = $response->{partial_input} || '';
            return { source => 'agent_event', input => undef, events => \@accumulated_events, partial_input => $partial };
        }
        
        unless (defined $response) {
            print "\n";
            if ($listen_broker) {
                return { source => 'user', input => undef, events => \@accumulated_events };
            }
            return undef;  # EOF or cancelled
        }
        
        # Handle empty response
        if (!length($response)) {
            if ($listen_broker) {
                # In broker mode, empty input is not cancellation - it's just enter
                print $self->colorize("(Empty input - type a response or \@agent-N to message an agent)\n", 'DIM');
                next;
            }
            print $self->colorize("(No response provided - collaboration cancelled)\n", 'WARNING');
            return undef;
        }
        
        # Handle @agent-N message routing (only when broker is active)
        if ($listen_broker && $broker_client && $response =~ /^\@(agent-\S+)\s+(.+)/) {
            my ($target_agent, $msg_text) = ($1, $2);
            eval {
                $broker_client->send_message(
                    to => $target_agent,
                    content => $msg_text,
                    message_type => 'guidance',
                );
            };
            if ($@) {
                print $self->colorize("[error] Failed to send to $target_agent: $@\n", 'RED');
            } else {
                print $self->colorize("YOU -> " . uc($target_agent) . ": ", 'USER'), $msg_text, "\n";
            }
            next;  # Return to readline, don't return to caller
        }
        
        # Check for slash commands - process them and return to prompt
        if ($response =~ /^\//) {
            log_debug('Chat', "Slash command in collaboration: $response");
            
            # Check for // shortcut to launch multiline editor (before command handling)
            if ($response eq '//') {
                log_debug('Chat', "// shortcut detected, launching multiline editor");
                
                require CLIO::Core::Editor;
                my $editor = CLIO::Core::Editor->new(
                    config => $self->{config},
                    debug => $self->{debug}
                );
                
                if ($editor->check_editor_available()) {
                    my $result = $editor->edit_multiline();
                    if ($result->{success} && $result->{content} && length($result->{content}) > 0) {
                        my $multiline_content = $result->{content};
                        
                        # Display the multiline content so it appears in chat history
                        $self->display_user_message($multiline_content);
                        
                        log_debug('Chat', "Multiline input received, length=" . length($multiline_content));
                        if ($listen_broker) {
                            return { source => 'user', input => $multiline_content, events => \@accumulated_events };
                        }
                        return $multiline_content;
                    }
                } else {
                    $self->display_system_message("Editor not available. Set \$EDITOR or /config editor <editor>");
                }
                # Empty or cancelled - continue to prompt
                next;
            }
            
            # Suspend ALRM timer and cbreak mode before running the command.
            # Interactive commands like /shell, /exec need normal terminal input.
            # The ALRM handler calls ReadKey(-1) which does sysread(STDIN) -
            # if /shell hands the foreground to bash via tcsetpgrp(), CLIO becomes
            # a background process and sysread triggers SIGTTIN, stopping CLIO.
            #
            # The agent turn is over by the time we reach this branch, so the
            # ALRM handler is already uninstalled. We use uninstall here as
            # a defensive no-op (idempotent) and skip the re-arm that the old
            # code did - re-arming without a handler would terminate the
            # process on the next SIGALRM.
            require CLIO::Core::Interrupt;
            CLIO::Core::Interrupt::uninstall_alrm_handler();
            ReadMode(0);
            my ($continue, $ai_prompt) = $self->handle_command($response);
            ReadMode(1);  # Re-enter cbreak for readline
            
            # If command requested exit, cancel collaboration
            if (!$continue) {
                print $self->colorize("(Collaboration ended by /exit command)\n", 'SYSTEM');
                if ($listen_broker) {
                    return { source => 'user', input => undef, events => \@accumulated_events };
                }
                return undef;
            }
            
            # If command generated an AI prompt (e.g., /multi-line), display and return it
            if ($ai_prompt) {
                # Display the multiline content so it appears in chat history
                $self->display_user_message($ai_prompt);
                
                # Return the prompt without echoing it back
                if ($listen_broker) {
                    return { source => 'user', input => $ai_prompt, events => \@accumulated_events };
                }
                return $ai_prompt;
            }
            
            # Otherwise, command was handled silently - don't display it, just return to prompt
            # Commands like /context, /git diff process and output their own results
            # No need to show "YOU: /command" in the chat
            print $self->colorize($self->agent_name() . ": ", 'ASSISTANT'), "(Command processed. What's your response?)\n";
            next;
        }
        
        # Regular response - display and return
        # Return user response without echoing
        if ($listen_broker) {
            return { source => 'user', input => $response, events => \@accumulated_events };
        }
        return $response;
    }
}

=head2 _poll_broker_events

Poll the broker client for pending events (messages, status updates, exits).
Returns an arrayref of event hashrefs.

=cut

sub _poll_broker_events {
    my ($self, $broker_client) = @_;
    
    my @events;
    
    # Track consecutive failures to avoid hammering a dead broker
    $self->{_broker_poll_failures} //= 0;
    if ($self->{_broker_poll_failures} > 3) {
        # After 3 failures, stop polling entirely until reconnect or new agent spawn
        return \@events;
    }
    
    my $had_error = 0;
    
    # Poll user inbox for agent messages
    my @message_ids;
    eval {
        my $messages = $broker_client->poll_user_inbox();
        for my $msg (@$messages) {
            push @message_ids, $msg->{id} if $msg->{id};
            my $event = {
                type => 'agent_message',
                agent_id => $msg->{from} || 'unknown',
                message_type => $msg->{type} || $msg->{message_type} || 'generic',
                content => $msg->{content} || '',
                timestamp => $msg->{timestamp} || time(),
            };
            # Preserve raw message for authorization handling
            if (($msg->{type} || '') eq 'authorization_request') {
                $event->{_raw_msg} = $msg;
            }
            push @events, $event;
        }
    };
    if ($@) {
        log_warning('Chat', "Error polling broker user inbox: $@");
        $had_error = 1;
    }
    
    # Acknowledge messages so they don't re-appear on next poll
    if (@message_ids) {
        eval { $broker_client->acknowledge_messages(@message_ids) };
    }
    
    # Poll for status updates (agent state transitions)
    eval {
        if ($broker_client->can('poll_status_updates')) {
            my $updates = $broker_client->poll_status_updates();
            for my $update (@$updates) {
                my $event_type = 'status_update';
                if (($update->{status} || '') eq 'exited' || ($update->{status} || '') eq 'completed') {
                    $event_type = 'agent_exit';
                }
                push @events, {
                    type => $event_type,
                    agent_id => $update->{agent_id} || 'unknown',
                    status => $update->{status} || '',
                    detail => $update->{detail} || '',
                    timestamp => $update->{timestamp} || time(),
                };
            }
        }
    };
    if ($@) {
        log_warning('Chat', "Error polling broker status updates: $@");
        $had_error = 1;
    }
    
    # Poll for activity stream events
    eval {
        if ($broker_client->can('poll_activity')) {
            my $activities = $broker_client->poll_activity();
            for my $activity (@$activities) {
                push @events, {
                    type => 'activity',
                    agent_id => $activity->{agent_id} || 'unknown',
                    action => $activity->{action} || '',
                    detail => $activity->{detail} || '',
                    timestamp => $activity->{timestamp} || time(),
                };
            }
        }
    };
    if ($@) {
        log_warning('Chat', "Error polling broker activity: $@");
        $had_error = 1;
    }
    
    # Track failures for backoff
    if ($had_error && !@events) {
        $self->{_broker_poll_failures}++;
    } else {
        $self->{_broker_poll_failures} = 0;
    }
    
    return \@events;
}

=head2 _render_broker_event

Format a broker event for inline display during collaboration.
Returns a colored string for terminal output.

Event types:
- agent_message: Message from an agent (question, completion, etc.)
- agent_exit: Agent process exited
- status_update: Agent state transition
- activity: Tool usage or processing activity

=cut

sub _render_broker_event {
    my ($self, $event) = @_;
    
    return unless $event && ref($event) eq 'HASH';
    
    my $type = $event->{type} || 'unknown';
    my $agent_id = $event->{agent_id} || 'unknown';
    my $content = $event->{content} || $event->{detail} || '';
    
    if ($type eq 'agent_message') {
        my $msg_type = $event->{message_type} || 'generic';
        my $agent_label = uc($agent_id);
        
        # Add project context to label if known
        my $project = $self->get_agent_project($agent_id);
        if ($project) {
            $agent_label .= " ($project)";
        }
        
        # Skip authorization_request - handled separately with interactive prompt
        return undef if $msg_type eq 'authorization_request';
        
        # Strip HTML comments (e.g. <!--session:...--> markers from agent output)
        if (!ref($content)) {
            $content =~ s/<!--.*?-->//gs;
            $content =~ s/^\s*\n//gm;  # Clean up blank lines left behind
        }
        
        # Render like a chat participant: "AGENT-1: <full message>"
        my $color = 'CYAN';
        if ($msg_type eq 'completion' || $msg_type eq 'complete') {
            $color = 'GREEN';
        } elsif ($msg_type eq 'question') {
            $color = 'YELLOW';
        } elsif ($msg_type eq 'blocked') {
            $color = 'RED';
        }
        
        my $header = $self->colorize("$agent_label: ", $color);
        
        # Render content - full text, no truncation
        if (ref($content) eq 'HASH') {
            my @lines;
            for my $key (sort keys %$content) {
                next unless defined $content->{$key};
                push @lines, "  $key: $content->{$key}";
            }
            my $indent = '    ';
            return "\n$header\n" . join("\n", map { "$indent$_" } @lines) . "\n";
        }
        
        # Render markdown for rich agent output
        my $rendered_content = $self->render_markdown($content);
        
        # Indent content lines to match CLIO's own message formatting
        my $indent = '    ';
        my @lines = split /\n/, $rendered_content;
        my $first = shift @lines // '';
        my $output = "\n$header$first\n";
        for my $line (@lines) {
            $output .= "$indent$line\n";
        }
        return $output;
    }
    elsif ($type eq 'agent_exit') {
        my $status = $event->{status} || 'exited';
        my $agent_label = uc($agent_id);
        my $project = $self->get_agent_project($agent_id);
        $agent_label .= " ($project)" if $project;
        return $self->colorize("$agent_label: ", 'GREEN') . $self->colorize("exited ($status)", 'DIM') . "\n";
    }
    elsif ($type eq 'status_update') {
        my $status = $event->{status} || 'unknown';
        # Brief inline status - keep dim and compact
        return $self->colorize("[$agent_id] $status", 'DIM') . ($content ? " $content" : '') . "\n";
    }
    elsif ($type eq 'activity') {
        my $action = $event->{action} || '';
        # Brief inline activity - keep dim and compact
        return $self->colorize("[$agent_id] $action", 'DIM') . ($content ? " $content" : '') . "\n";
    }
    
    # Unknown event type
    return $self->colorize("[$agent_id]", 'DIM') . " $content\n";
}

=head2 register_agent_project

Register an agent's project context for display labels.
Called by SubAgentOperations after spawning an agent.

=cut

sub register_agent_project {
    my ($self, $agent_id, $project) = @_;
    return unless $agent_id && $project;
    $self->{_agent_projects} //= {};
    # Extract just the project name from path (e.g. "./ALICE" -> "ALICE")
    (my $name = $project) =~ s{^\.?/}{};
    $name =~ s{/$}{};
    $self->{_agent_projects}{$agent_id} = $name;
}

=head2 get_agent_project

Get the project name for an agent, or undef if not known.

=cut

sub get_agent_project {
    my ($self, $agent_id) = @_;
    return unless $agent_id;
    return ($self->{_agent_projects} || {})->{$agent_id};
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
    return $self->{pager}->display_list($title, $items, $formatter);
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
    return $self->{help}->display_help();
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
    return $self->{pager}->display_content($title, $lines, $filepath);
}


=head2 handle_fix_command

Propose fixes for code problems

=cut


=head2 setup_tab_completion

Setup tab completion for interactive terminal

=cut

sub setup_tab_completion {
    my ($self) = @_;
    
    # Skip custom readline on Windows - terminal raw mode not available,
    # which causes double-echo. Fall through to basic <STDIN> input.
    if ($^O eq 'MSWin32') {
        log_debug('CleanChat', "Skipping custom readline on Windows");
        return;
    }
    
    eval {
        require CLIO::Core::TabCompletion;
        require CLIO::Core::ReadLine;
        
        # Create tab completer
        $self->{completer} = CLIO::Core::TabCompletion->new(debug => $self->{debug});
        
        # Create custom readline with completer and restored history
        my @saved_history;
        if ($self->{session} && $self->{session}->state() && 
            $self->{session}->state()->{input_history}) {
            @saved_history = @{$self->{session}->state()->{input_history}};
        }
        $self->{readline} = CLIO::Core::ReadLine->new(
            prompt => '',  # We'll provide prompt in get_input
            completer => $self->{completer},
            history => \@saved_history,
            debug => $self->{debug}
        );
        
        log_debug('CleanChat', "Custom readline with tab completion enabled");
    };
    
    if ($@) {
        log_warning('CleanChat', "Tab completion setup failed: $@");
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
    
    # Emit session metadata to host application
    if ($self->{host_proto}->active() && $self->{session}) {
        my $session_name = $self->{session}->session_name() // '';
        $self->{host_proto}->emit_session(
            id   => $self->{session}->id() || '',
            name => $session_name,
            dir  => $self->{session}->state()->{working_directory} || '',
        );
        my $model = ($self->{config} ? $self->{config}->get('model') : '') || '';
        $self->{host_proto}->emit_title($self->agent_name() . " - " .
            ($session_name || 'New Session') .
            ($model ? " ($model)" : ''));
    }
    
    # Replay buffer without adding to it again
    my $tool_format = 'inline';
    if ($self->{theme_mgr} && $self->{theme_mgr}->can('get_tool_display_format')) {
        $tool_format = $self->{theme_mgr}->get_tool_display_format();
    }
    
    for my $msg (@{$self->{screen_buffer}}) {
        if ($msg->{type} eq 'user') {
            # User messages are not echoed on repaint
        }
        elsif ($msg->{type} eq 'assistant') {
            my $content = $msg->{content};
            # Normalize indentation on continuation lines
            my @lines = split /\n/, $content, -1;
            for my $i (1 .. $#lines) {
                next unless length($lines[$i]) > 0;
                $lines[$i] =~ s/^\s+//;
                $lines[$i] = "    " . $lines[$i];
            }
            $content = join "\n", @lines;
            print $self->colorize($self->agent_name() . ": ", 'ASSISTANT'), $content, "\n";
        }
        elsif ($msg->{type} eq 'system') {
            if ($tool_format eq 'inline') {
                my $b = $self->colorize(ui_char('bullet'), 'DIM');
                my $n = $self->colorize(" SYSTEM ", 'SYSTEM');
                my $s = $self->colorize(ui_char('separator') . " ", 'DIM');
                my $c = $self->colorize($msg->{content}, 'WARNING');
                print "$b$n$s$c\n";
            } else {
                my $header_conn = $self->colorize(box_char("topleft") . box_char("horizontal") x 2 . box_char("tleft") . " ", 'DIM');
                my $header_name = $self->colorize("SYSTEM", 'ASSISTANT');
                my $footer_conn = $self->colorize(box_char("bottomleft") . box_char("horizontal") . " ", 'DIM');
                my $footer_msg = $self->colorize($msg->{content}, 'WARNING');
                print "$header_conn$header_name\n$footer_conn$footer_msg\n";
            }
        }
        elsif ($msg->{type} eq 'error') {
            if ($tool_format eq 'inline') {
                my $b = $self->colorize(ui_char('bullet'), 'DIM');
                my $n = $self->colorize(" ERROR ", 'ERROR');
                my $s = $self->colorize(ui_char('separator') . " ", 'DIM');
                my $c = $self->colorize($msg->{content}, 'ERROR');
                print "$b$n$s$c\n";
            } else {
                my $header_conn = $self->colorize(box_char("topleft") . box_char("horizontal") x 2 . box_char("tleft") . " ", 'DIM');
                my $header_name = $self->colorize("ERROR", 'ERROR');
                my $footer_conn = $self->colorize(box_char("bottomleft") . box_char("horizontal") . " ", 'DIM');
                my $footer_msg = $self->colorize($msg->{content}, 'ERROR');
                print "$header_conn$header_name\n$footer_conn$footer_msg\n";
            }
        }
        elsif ($msg->{type} eq 'warning') {
            if ($tool_format eq 'inline') {
                my $b = $self->colorize(ui_char('bullet'), 'DIM');
                my $n = $self->colorize(" WARNING ", 'WARNING');
                my $s = $self->colorize(ui_char('separator') . " ", 'DIM');
                my $c = $self->colorize($msg->{content}, 'WARNING');
                print "$b$n$s$c\n";
            } else {
                my $header_conn = $self->colorize(box_char("topleft") . box_char("horizontal") x 2 . box_char("tleft") . " ", 'DIM');
                my $header_name = $self->colorize("WARNING", 'WARNING');
                my $footer_conn = $self->colorize(box_char("bottomleft") . box_char("horizontal") . " ", 'DIM');
                my $footer_msg = $self->colorize($msg->{content}, 'WARNING');
                print "$header_conn$header_name\n$footer_conn$footer_msg\n";
            }
        }
        elsif ($msg->{type} eq 'success') {
            if ($tool_format eq 'inline') {
                my $b = $self->colorize(ui_char('bullet'), 'DIM');
                my $n = $self->colorize(" OK ", 'SUCCESS');
                my $s = $self->colorize(ui_char('separator') . " ", 'DIM');
                my $c = $self->colorize($msg->{content}, 'DATA');
                print "$b$n$s$c\n";
            } else {
                my $header_conn = $self->colorize(box_char("topleft") . box_char("horizontal") x 2 . box_char("tleft") . " ", 'DIM');
                my $header_name = $self->colorize("SUCCESS", 'SUCCESS');
                my $footer_conn = $self->colorize(box_char("bottomleft") . box_char("horizontal") . " ", 'DIM');
                my $footer_msg = $self->colorize($msg->{content}, 'DATA');
                print "$header_conn$header_name\n$footer_conn$footer_msg\n";
            }
        }
        elsif ($msg->{type} eq 'info') {
            if ($tool_format eq 'inline') {
                my $b = $self->colorize(ui_char('bullet'), 'DIM');
                my $n = $self->colorize(" INFO ", 'ASSISTANT');
                my $s = $self->colorize(ui_char('separator') . " ", 'DIM');
                my $c = $self->colorize($msg->{content}, 'DATA');
                print "$b$n$s$c\n";
            } else {
                my $header_conn = $self->colorize(box_char("topleft") . box_char("horizontal") x 2 . box_char("tleft") . " ", 'DIM');
                my $header_name = $self->colorize("INFO", 'ASSISTANT');
                my $footer_conn = $self->colorize(box_char("bottomleft") . box_char("horizontal") . " ", 'DIM');
                my $footer_msg = $self->colorize($msg->{content}, 'DATA');
                print "$header_conn$header_name\n$footer_conn$footer_msg\n";
            }
        }
    }
}

=head2 pause

Display pagination prompt and wait for keypress (BBS-style prompt)

=cut

sub pause {
    my ($self, $streaming) = @_;
    return $self->{pager}->pause($streaming);
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
            log_debug('Chat', "render_markdown: Found @-codes in rendered text");
            log_debug('Chat', "Sample: " . substr($rendered, 0, 100));
        }
        
        # Parse @COLOR@ markers to actual ANSI escape sequences
        $rendered = $self->{ansi}->parse($rendered) if defined $rendered;
        
        # Restore escaped @ symbols from inline code
        # Markdown.pm escapes @ as \x00AT\x00 to prevent ANSI interpretation
        $rendered =~ s/\x00AT\x00/\@/g if defined $rendered;
        
        # DEBUG: Verify @-codes were converted
        if ($self->{debug} && defined $rendered && $rendered =~ /\@[A-Z_]+\@/) {
            log_debug('Chat', "WARNING: @-codes still present after ANSI parse!");
            log_debug('Chat', "Sample: " . substr($rendered, 0, 100));
        }
    };
    
    # If rendering failed or returned undef/empty, fall back to original text
    if ($@ || !defined $rendered || $rendered eq '') {
        log_debug('Chat', "Markdown rendering issue (falling back to raw): $@");
        log_debug('Chat', "Markdown render returned empty/undef, using raw text");
        return $text;  # Fallback to raw text rather than breaking output
    }
    
    return $rendered;
}

=head2 _get_pagination_threshold

Get the threshold at which pagination should pause (internal helper).

Returns the line count threshold based on terminal height. Centralized so streaming and writeline use the same pagination point.

=cut

sub _get_pagination_threshold {
    my ($self) = @_;
    return $self->{pager}->threshold();
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
- Whether tools were invoked in this request (suppresses pagination)
- Terminal interactivity

Returns: 1 if pause needed, 0 otherwise

=cut

sub _should_pagination_trigger {
    my ($self) = @_;
    return $self->{pager}->should_trigger();
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
    if (!%opts && defined $_[2]) {
        $opts{newline} = $_[2];
        $opts{markdown} = $_[3] if defined $_[3];
    }
    
    my $newline = exists $opts{newline} ? $opts{newline} : 1;
    my $use_markdown = exists $opts{markdown} ? $opts{markdown} : 1;
    my $raw = $opts{raw} || 0;
    
    my $pager = $self->{pager};
    my $should_paginate = $opts{force_paginate} || $pager->enabled();

    $text //= '';

    if ($raw) {
        print $text;
        print "\n" if $newline;
        return 1;
    }

    if ($use_markdown && $self->{enable_markdown} && length($text) > 0) {
        $text = $self->render_markdown($text);
    }

    my $is_interactive = -t STDIN;
    my @lines = split /\n/, $text, -1;
    my $last_idx = $#lines;

    for my $i (0 .. $last_idx) {
        my $line = $lines[$i];
        my $is_last = ($i == $last_idx);
        my $print_newline = $is_last ? $newline : 1;

        if ($print_newline && $is_interactive && $should_paginate) {
            my $pause_threshold = $pager->threshold();

            if ($pager->line_count() >= $pause_threshold
                && !$self->{_tools_invoked_this_request}) {
                $pager->save_page();

                my $response = $pager->pause();

                if ($response eq 'Q') {
                    $pager->reset_page();
                    return 0;
                }

                $pager->reset_page();
            }
        }

        print $line;
        print "\n" if $print_newline;

        if ($print_newline && $is_interactive && $should_paginate) {
            $pager->track_line($line);
        }
    }

    return 1;
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
    
    my $page = $self->{pager}{pages}[$self->{pager}{page_index}];
    return unless $page && ref($page) eq 'ARRAY';
    
    print "\e[2J\e[H";
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
    
    my $prompt = $self->{theme_mgr}->get_confirmation_prompt(
        "Record session learnings?",
        "yes/no",
        "skip"
    );
    
    print $prompt;
    my $response = <STDIN>;
    chomp $response if defined $response;
    
    # Skip if user declined
    return unless $response && $response =~ /^y(es)?$/i;
    
    # Now prompt for the actual learning text
    my $lprompt = $self->{theme_mgr}->get_confirmation_prompt(
        "Enter learnings (Ctrl+D when done)",
        "",
        "skip"
    );
    print $lprompt;
    
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
        log_debug('Chat', "Stored learning: $learning");
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
        SEPARATOR => 'dim',
        BOLD => 'command_value',    # Emphasis (bright white)
        GREEN => 'success',
        CYAN => 'info',
        YELLOW => 'warning',
        RED => 'error',
        MAGENTA => 'primary',
        WHITE => 'normal',
        SECTION_HEADER => 'command_subheader',
        CLIO => 'agent_label',
        TOOL => 'command',
        COLLAB_HEADER => 'banner',
        COLLAB_CONTEXT => 'data',
        COLLAB_PROMPT => 'agent_label',
        COLLAB_ARROW => 'prompt_indicator',
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

GPL-3.0-only

=cut

1;
