# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::SessionReplay;

use strict;
use warnings;
use utf8;
use open ':std', ':encoding(UTF-8)';

use CLIO::Compat::Terminal qw(GetTerminalSize);
use CLIO::UI::Terminal qw(box_char ui_char);
use CLIO::Util::JSON qw(decode_json);
use CLIO::Util::TextSanitizer qw(sanitize_text);
use CLIO::UI::ToolOutputFormatter;

=head1 NAME

CLIO::UI::SessionReplay - Render session history for visual replay

=head1 DESCRIPTION

Walks the session's persisted conversation history and re-renders it to the
terminal using the same CLIO::UI::Display and CLIO::UI::ToolOutputFormatter
pipelines that produced the original live output. This produces a 100%
visually identical replay of what the user saw during the original session.

The replay relies on display metadata stored alongside tool result messages
(tool_name, action_description, expanded_content, suppressed_display, is_error,
error_message). Sessions saved with this metadata produce pixel-perfect
replays. Sessions saved before this feature are handled with best-effort
reconstruction from available data.

=head1 SYNOPSIS

    use CLIO::UI::SessionReplay;

    my $replay = CLIO::UI::SessionReplay->new(
        chat => $chat_instance,
        debug => 0,
    );

    $replay->render_history($session->state->{history}, max_messages => 100);

=cut

sub new {
    my ($class, %args) = @_;

    my $chat = $args{chat} || die "chat instance required";

    my $self = {
        chat => $chat,
        debug => $args{debug} || 0,
        formatter => CLIO::UI::ToolOutputFormatter->new(ui => $chat),
        display => $chat->{display},
        max_messages => $args{max_messages},
        non_interactive => $chat->{non_interactive} || 0,
    };

    bless $self, $class;
    return $self;
}

=head2 render_history($history, %opts)

Render session history to the terminal for replay.

Arguments:
- $history: Arrayref of message hashrefs from session state
- %opts:
  - max_messages: Integer or undef (no limit)
  - show_system: Whether to render system (thread_summary) messages (default: 1)

Returns: Number of messages rendered

=cut

sub render_history {
    my ($self, $history, %opts) = @_;

    return 0 unless $history && ref($history) eq 'ARRAY' && @$history;

    # Auto-disable in non-interactive mode
    return 0 if $self->{non_interactive};

    my $max = $opts{max_messages};
    $max = $self->{max_messages} unless defined $max;
    my $show_system = exists $opts{show_system} ? $opts{show_system} : 1;

    # Build a lookup map: tool_call_id -> tool result message
    # This lets us match assistant tool_calls to their results during iteration.
    my %tool_results;
    for my $msg (@$history) {
        if ($msg->{role} eq 'tool' && $msg->{tool_call_id}) {
            $tool_results{$msg->{tool_call_id}} = $msg;
        }
    }

    # Track which tool result IDs we've already rendered (so we skip them
    # as standalone messages — they're rendered inline with their assistant
    # message's tool_calls).
    my %rendered_tool_results;

    # Determine tool display format from theme
    my $tool_format = 'inline';
    if ($self->{chat}->{theme_mgr}
        && $self->{chat}->{theme_mgr}->can('get_tool_display_format')) {
        $tool_format = $self->{chat}->{theme_mgr}->get_tool_display_format();
    }

    my $rendered_count = 0;
    my $current_tool = '';
    my $first_tool_in_group = 1;

    # Suppress pagination during replay (we handle our own pagination
    # via max_messages). The live session sets this flag when tools are
    # invoked; we reset it so writeline doesn't pause mid-replay.
    $self->{chat}->{_tools_invoked_this_request} = 1;

    my $msg_idx = 0;
    my $rendered_so_far = 0;

    MSG: for my $msg (@$history) {
        last if defined $max && $rendered_so_far >= $max;

        my $role = $msg->{role} || '';

        if ($role eq 'user') {
            $self->_render_user_message($msg->{content});
            $rendered_count++;
            $rendered_so_far++;
            $msg_idx++;
            next;
        }

        if ($role eq 'assistant') {
            $self->_render_assistant_message($msg, \%tool_results,
                \%rendered_tool_results, \$current_tool,
                \$first_tool_in_group, $tool_format);
            $rendered_count++;
            $rendered_so_far++;
            $msg_idx++;
            next;
        }

        if ($role eq 'tool') {
            # Skip standalone tool results — they're rendered as part
            # of their preceding assistant message's tool_calls.
            # If we reach here, it means the tool_call_id wasn't matched
            # (orphaned result). Render it as a fallback.
            if (!$rendered_tool_results{$msg->{tool_call_id}}) {
                $self->_render_orphan_tool_result($msg);
                $rendered_count++;
                $rendered_so_far++;
            }
            $msg_idx++;
            next;
        }

        if ($role eq 'system') {
            next unless $show_system;
            # Only render thread_summary system messages (others are stripped on load)
            if ($msg->{content} && $msg->{content} =~ /thread_summary|CONTEXT TRIM|thread-summary/i) {
                $self->_render_system_message($msg->{content});
                $rendered_count++;
                $rendered_so_far++;
            }
            $msg_idx++;
            next;
        }

        $msg_idx++;
    }

    # Reset pagination suppression
    $self->{chat}->{_tools_invoked_this_request} = 0;

    # Ensure output is flushed
    STDOUT->flush() if STDOUT->can('flush');

    return $rendered_count;
}

=head2 _render_user_message($content)

Render a user message (replays the "YOU: " prefix + markdown content).
Does NOT add to screen_buffer (replay is a one-time visual projection).

=cut

sub _render_user_message {
    my ($self, $content) = @_;

    return unless defined $content && length($content) > 0;

    my $chat = $self->{chat};

    # Display with "YOU: " prefix, matching live session rendering
    my $prefix = $chat->colorize("YOU: ", 'user_text');
    my $display_message = $content;
    if ($chat->{enable_markdown}) {
        $display_message = $chat->render_markdown($display_message);
    }
    $chat->writeline($prefix . $display_message, markdown => 0);
}

=head2 _render_thinking($thinking_content)

Render thinking/reasoning content in a THINKING box, matching the live
session's format: header, hrule, indented content, hrule.

=cut

sub _render_thinking {
    my ($self, $thinking_content) = @_;

    return unless defined $thinking_content && length($thinking_content) > 0;

    my $chat = $self->{chat};
    my $indent = '    ';

    # Determine tool format for box style
    my $tool_format = 'inline';
    if ($chat->{theme_mgr} && $chat->{theme_mgr}->can('get_tool_display_format')) {
        $tool_format = $chat->{theme_mgr}->get_tool_display_format();
    }

    # Print thinking header (same format as live session)
    if ($tool_format eq 'inline') {
        my $bullet = ui_char('bullet');
        print $chat->colorize($bullet, 'DIM') . $chat->colorize(" THINKING", 'ASSISTANT') . "\n";
        STDOUT->flush() if STDOUT->can('flush');
    } else {
        print $chat->colorize(box_char('topleft') . box_char('horizontal') x 2 . box_char('tleft') . " ", 'DIM');
        print $chat->colorize("THINKING", 'ASSISTANT') . "\n";
        STDOUT->flush() if STDOUT->can('flush');
    }

    # Print top hrule
    my ($term_cols) = GetTerminalSize();
    $term_cols ||= 80;
    my $rule_len = $term_cols - length($indent) - 1;
    $rule_len = 20 if $rule_len < 20;
    my $hz = box_char('horizontal');
    print $chat->colorize("$indent" . ($hz x $rule_len), 'DIM') . "\n";
    STDOUT->flush() if STDOUT->can('flush');

    # Print thinking content (indented + markdown rendered)
    my $display_content = $thinking_content;
    if ($chat->{enable_markdown}) {
        $display_content = $chat->render_markdown($thinking_content);
    }
    # Indent each non-empty line (empty lines pass through unindented,
    # matching the live StreamingController::_indent_and_wrap behavior)
    my @lines = split /\n/, $display_content, -1;
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        if (length($line) == 0) {
            print "\n";
        } else {
            print $indent . $line . "\n";
        }
    }
    STDOUT->flush() if STDOUT->can('flush');

    # Print blank line before bottom hrule (matches live session)
    print "\n";
    STDOUT->flush() if STDOUT->can('flush');

    # Print bottom hrule
    print $chat->colorize("$indent" . ($hz x $rule_len), 'DIM') . "\n";
    STDOUT->flush() if STDOUT->can('flush');

    # Print blank line after bottom hrule (matches live session)
    print "\n";
    STDOUT->flush() if STDOUT->can('flush');
}

=head2 _render_assistant_message($msg, ...)

Render an assistant message: thinking content (optional), text content,
and tool calls (headers, action details, expanded content).

=cut

sub _render_assistant_message {
    my ($self, $msg, $tool_results, $rendered_map, $current_tool_ref,
        $first_tool_ref, $tool_format) = @_;

    my $chat = $self->{chat};

    # Render thinking/reasoning content (if show_thinking is enabled and content exists)
    my $show_thinking = $chat->{config} ? $chat->{config}->get('show_thinking') : 0;
    if ($show_thinking) {
        my $reasoning = '';
        if ($msg->{reasoning_content} && length($msg->{reasoning_content})) {
            $reasoning = $msg->{reasoning_content};
        } elsif ($msg->{reasoning_details}) {
            if (ref($msg->{reasoning_details}) eq 'ARRAY') {
                # Anthropic-style: array of {text => "...", ...} objects
                for my $rd (@{$msg->{reasoning_details}}) {
                    if (ref($rd) eq 'HASH' && $rd->{text}) {
                        $reasoning .= $rd->{text};
                    }
                }
            } elsif (!ref($msg->{reasoning_details})) {
                $reasoning = $msg->{reasoning_details};
            }
        }
        if ($reasoning && length($reasoning)) {
            $self->_render_thinking($reasoning);
        }
    }

    # Display assistant text content (if any)
    my $content = $msg->{content} // '';
    # Strip session markers that may have been added
    $content = $self->_strip_session_markers($content);

    if (length($content) > 0) {
        $self->_render_assistant_text($content);
    }

    # Handle tool_calls
    my $tool_calls = $msg->{tool_calls};
    return unless $tool_calls && ref($tool_calls) eq 'ARRAY' && @$tool_calls;

    # Reset current_tool so the first tool call in this assistant message
    # is treated as a new tool group (not a continuation from a previous
    # message's tool calls). Without this, a terminal_operations call in
    # a later message inherits the continuation header from an earlier one.
    $$current_tool_ref = '';
    $$first_tool_ref = 1;

    # Process each tool call
    for my $i (0 .. $#$tool_calls) {
        my $tc = $tool_calls->[$i];
        my $tool_name = $tc->{function}->{name} || 'unknown';
        my $tool_display_name = uc($tool_name);
        $tool_display_name =~ s/_/ /g;

        # Parse tool arguments
        my $raw_args = $tc->{function}->{arguments} || '{}';
        my $tool_args = ref($raw_args) ? $raw_args : eval { decode_json($raw_args) };
        if ($@ || !defined $tool_args) {
            $tool_args = {};
        }
        my $tool_operation = ($tool_args && $tool_args->{operation}) ? $tool_args->{operation} : '';

        # Infer missing operation (mirrors Tool.pm's default_operation +
        # _infer_operation_from_params). Sessions saved before operation
        # inference was stored in tool args will have operation missing,
        # but the model's intent is recoverable from the params.
        if (!$tool_operation && $tool_name eq 'terminal_operations') {
            # terminal_operations has default_operation => 'exec'
            if ($tool_args->{command}) {
                $tool_operation = 'exec';
            } elsif ($tool_args->{pattern}) {
                $tool_operation = 'grep_search';
            }
        }

        # Find matching tool result
        my $tool_result = $tool_results->{$tc->{id}};

        # Determine suppress_display
        my $suppress_display = $self->_should_suppress($tool_name, $tool_operation, $tool_result);

        # Track tool group changes for box format
        my $tool_changed = ($tool_name ne $$current_tool_ref);
        if ($tool_changed) {
            # In box format, print a newline before new tool group
            if ($tool_format ne 'inline' && $$current_tool_ref ne '') {
                print "\n";
                STDOUT->flush() if STDOUT->can('flush');
            }
            $$first_tool_ref = 0;
        }

        # Render the tool call
        $self->_render_tool_call(
            $tool_name, $tool_display_name, $tool_operation,
            $tool_args, $suppress_display, $tool_changed,
            $tool_format, $i, $#$tool_calls,
            $tool_result, $rendered_map, $current_tool_ref,
            $first_tool_ref, $tool_calls
        );
    }
    
    # Print trailing newline after tool calls (matches live session's
    # _execute_tool_round which prints "\n" at the end of the tool loop,
    # skipping for interact which provides its own separation)
    my $last_tool_name = $tool_calls->[-1]->{function}->{name} || '';
    if ($last_tool_name ne 'interact') {
        print "\n";
        STDOUT->flush() if STDOUT->can('flush');
    }
}

=head2 _should_suppress($tool_name, $operation, $tool_result)

Determine whether a tool call should be suppressed from display.
Uses stored suppressed_display metadata if available, otherwise
re-derives from tool name and operation.

=cut

sub _should_suppress {
    my ($self, $tool_name, $tool_operation, $tool_result) = @_;

    # If the tool result has stored suppressed_display, use it
    if ($tool_result && defined $tool_result->{suppressed_display}) {
        return $tool_result->{suppressed_display} ? 1 : 0;
    }

    # Fallback: re-derive from tool name and operation
    return 1 if $tool_name eq 'interact';
    return 1 if $tool_name eq 'terminal_operations' && $tool_operation eq 'validate';
    return 0;
}

=head2 _render_tool_call(...)

Render a single tool call with header, pre-action, action detail, and expanded content.
Mirrors the display logic in WorkflowOrchestrator::_execute_tool_round.

=cut

sub _render_tool_call {
    my ($self, $tool_name, $tool_display_name, $tool_operation,
        $tool_args, $suppress_display, $tool_changed,
        $tool_format, $idx, $last_idx,
        $tool_result, $rendered_map, $current_tool_ref, $first_tool_ref,
        $tool_calls) = @_;

    my $is_inline = ($tool_format eq 'inline');
    my $is_first_tool = ($$first_tool_ref && !$is_inline) || ($idx == 0);

    # Display tool header (unless suppressed)
    # Header comes first, matching live session rendering.
    if (!$suppress_display && ($is_inline || $tool_changed)) {
        my $is_continuation = $is_inline && !$tool_changed && $$current_tool_ref ne '';
        $self->{formatter}->display_tool_header(
            $tool_name, $tool_display_name, $is_first_tool, $is_continuation
        );
    }

    $$current_tool_ref = $tool_name;

    # Mark tool result as rendered (even if suppressed — the tool result
    # should not be rendered again as an orphan in the main loop).
    if ($tool_result && $tool_result->{tool_call_id}) {
        $rendered_map->{$tool_result->{tool_call_id}} = 1;
    }

    # If suppressed, there's no action detail or expanded content to show
    if ($suppress_display) {
        $rendered_map->{_last_tool_suppressed} = 1;
        return;
    }

    $rendered_map->{_last_tool_suppressed} = 0;

    # Determine pre_action (displayed after header, before execution result)
    my $pre_action_printed = 0;
    my $pre_action_detail = undef;

    if (!$suppress_display) {
        # terminal_operations exec: show the command after header
        if ($tool_name eq 'terminal_operations' && $tool_operation eq 'exec') {
            if ($tool_result && $tool_result->{pre_action_description}) {
                $pre_action_detail = $tool_result->{pre_action_description};
            } elsif ($tool_args->{command}) {
                $pre_action_detail = $tool_args->{command};
            }
            if ($pre_action_detail) {
                $self->{formatter}->display_action_detail($pre_action_detail, 0, 0);
                $pre_action_printed = 1;
            }
        }
        # apply_patch: show "patching N files" after header
        elsif ($tool_name eq 'apply_patch' && $tool_args->{patch}) {
            my @files;
            while ($tool_args->{patch} =~ /\*\*\* (?:Add|Update|Delete) File:\s*(.+)/g) {
                push @files, $1;
            }
            if (@files) {
                $pre_action_detail = @files == 1 ? $files[0] : scalar(@files) . " files";
                $self->{formatter}->display_action_detail("patching $pre_action_detail", 0, 0);
                $pre_action_printed = 1;
            }
        }
    }

    # Compute action_detail and expanded_content
    my $action_detail = '';
    my $is_error = 0;
    my $expanded_content = undef;

    if ($tool_result) {
        # Use stored metadata for 100% accurate replay
        $is_error = $tool_result->{is_error} ? 1 : 0;

        if ($is_error) {
            # Error: reconstruct the format_error transformation
            my $error_msg = $tool_result->{error_message} || '';
            my $error_prefix = $tool_operation ? "$tool_operation: " : '';
            $action_detail = $error_prefix . $self->{formatter}->format_error($error_msg);
        } elsif ($tool_result->{action_description}) {
            $action_detail = $tool_result->{action_description};
        }

        # Get expanded_content from stored metadata
        if ($tool_result->{expanded_content} && ref($tool_result->{expanded_content}) eq 'ARRAY' && @{$tool_result->{expanded_content}}) {
            $expanded_content = $tool_result->{expanded_content};
        }
    }

    # Fallback: derive action_detail from tool args (for sessions without metadata)
    if (!$action_detail && $is_inline && !$pre_action_printed) {
        if ($tool_operation) {
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

    # Fallback: derive expanded_content from tool result content (for sessions
    # saved before metadata was stored). Only applies to terminal_operations
    # exec, where the content string IS the displayed command output and
    # expanded_content was not persisted separately. Other tools' content may
    # be data that was never shown in expanded form (e.g. file_operations
    # directory listings shown only as action_description).
    if (!$expanded_content && $tool_result && $tool_name eq 'terminal_operations'
        && $tool_operation eq 'exec' && $tool_result->{content}) {
        my $content = $tool_result->{content};
        if (length($content) > 0) {
            my @lines = split /\n/, $content;
            my $max_lines = 15;
            my @preview;
            for my $j (0 .. ($#lines < $max_lines - 1 ? $#lines : $max_lines - 1)) {
                push @preview, $lines[$j];
            }
            if (@lines > $max_lines) {
                push @preview, "... (" . scalar(@lines) . " lines total)";
            }
            $expanded_content = \@preview;
        }
    }

    # Display action detail + expanded content
    my $printed_action = 0;

    # Special case: apply_patch with pre_action - action_detail becomes expanded_content
    if ($pre_action_printed && $action_detail && !$suppress_display && $tool_name eq 'apply_patch') {
        my @expanded;
        if ($expanded_content && ref($expanded_content) eq 'ARRAY') {
            @expanded = @$expanded_content;
        }
        unshift @expanded, $action_detail;
        $self->{formatter}->display_expanded_content(\@expanded);
        $printed_action = 1;
        $action_detail = undef;
    } elsif ($action_detail && !$suppress_display) {
        # Compute remaining_same_tool for box format (count remaining calls to same tool)
        # This mirrors the live session's computation from ordered_tools.
        my $remaining_same_tool = 0;
        if (!$is_inline && defined $tool_calls && ref($tool_calls) eq 'ARRAY') {
            for my $j ($idx + 1 .. $#$tool_calls) {
                if ($tool_calls->[$j]->{function}->{name} eq $tool_name) {
                    $remaining_same_tool++;
                }
            }
        }

        $self->{formatter}->display_action_detail(
            $action_detail, $is_error, $remaining_same_tool, $expanded_content
        );
        $printed_action = 1;
    }

    # If pre_action was printed but no action_detail, show expanded_content
    if (!$printed_action && $pre_action_printed && $expanded_content && ref($expanded_content) eq 'ARRAY' && @$expanded_content) {
        $self->{formatter}->display_expanded_content($expanded_content);
    }

    # In inline mode, if no action detail was printed after the header,
    # close the line so the next tool header starts on a new line
    if ($is_inline && !$printed_action && !$pre_action_printed) {
        print "\n";
        STDOUT->flush() if STDOUT->can('flush');
    }

    # Note: File diffs are NOT recomputed during replay because files may
    # have changed since the session was recorded. This is a known
    # limitation - the diff visual is sacrificed for correctness.
}

=head2 _render_assistant_text($content)

Render assistant text content (with agent prefix, markdown, indentation).
Does NOT add to screen_buffer.

=cut

sub _render_assistant_text {
    my ($self, $content) = @_;

    my $chat = $self->{chat};

    my $display_message = $content;
    if ($chat->{enable_markdown}) {
        $display_message = $chat->render_markdown($display_message);
    }

    # Indent continuation lines (matching Display::display_assistant_message)
    my @lines = split /\n/, $display_message, -1;
    for my $i (1 .. $#lines) {
        $lines[$i] = "    " . $lines[$i] if length($lines[$i]) > 0;
    }
    $display_message = join "\n", @lines;

    my $agent = $chat->agent_name();
    my $line = $chat->colorize("$agent: ", 'ASSISTANT') . $display_message;
    $chat->writeline($line, markdown => 0);
}

=head2 _render_orphan_tool_result($msg)

Render a tool result that has no matching tool_call in an assistant message.
This is a fallback for corrupted history.

=cut

sub _render_orphan_tool_result {
    my ($self, $msg) = @_;

    my $chat = $self->{chat};
    my $tool_name = $msg->{tool_name} || $msg->{name} || 'unknown';
    my $tool_display_name = uc($tool_name);
    $tool_display_name =~ s/_/ /g;

    # Display header
    $self->{formatter}->display_tool_header($tool_name, $tool_display_name, 1, 0);

    my $content = $msg->{content} // '';
    if (length($content) > 0) {
        my @lines = split /\n/, $content;
        $self->{formatter}->display_expanded_content(\@lines);
    }
}

=head2 _render_system_message($content)

Render a system/thread_summary message.

=cut

sub _render_system_message {
    my ($self, $content) = @_;

    my $chat = $self->{chat};
    my $tool_format = 'inline';
    if ($chat->{theme_mgr} && $chat->{theme_mgr}->can('get_tool_display_format')) {
        $tool_format = $chat->{theme_mgr}->get_tool_display_format();
    }

    if ($tool_format eq 'inline') {
        my $b = $chat->colorize(ui_char('bullet'), 'DIM');
        my $n = $chat->colorize(" SYSTEM ", 'SYSTEM');
        my $s = $chat->colorize(ui_char('separator') . " ", 'DIM');
        my $c = $chat->colorize($content, 'WARNING');
        print "$b$n$s$c\n";
    } else {
        my $header_conn = $chat->colorize(box_char("topleft") . box_char("horizontal") x 2 . box_char("tleft") . " ", 'DIM');
        my $header_name = $chat->colorize("SYSTEM", 'ASSISTANT');
        my $footer_conn = $chat->colorize(box_char("bottomleft") . box_char("horizontal") . " ", 'DIM');
        my $footer_msg = $chat->colorize($content, 'WARNING');
        print "$header_conn$header_name\n$footer_conn$footer_msg\n";
    }
    STDOUT->flush() if STDOUT->can('flush');
}

=head2 _strip_session_markers($text)

Remove session management markers from text content.

=cut

sub _strip_session_markers {
    my ($self, $text) = @_;

    return '' unless defined $text;

    # Remove <!--thinking--> markers
    $text =~ s/^<!--thinking-->\s*//;
    $text =~ s/<!--\/thinking-->\s*$//;

    # Remove [conversation] wrapper tags
    $text =~ s/^\[conversation\]//;
    $text =~ s/\[\/conversation\]$//;

    return $text;
}

1;
