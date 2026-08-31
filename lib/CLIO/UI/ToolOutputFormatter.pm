# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::ToolOutputFormatter;

use strict;
use warnings;
use utf8;
# ToolOutputFormatter prints Unicode box-drawing characters (e.g. \x{2500}
# for hrule). Without UTF-8 STDOUT encoding, `perl -W` reports
# "Wide character in print" on every hrule emit. Match the convention used
# in CLIO::UI::Chat.pm / CLIO::UI::Markdown.pm so the warnings go away
# whether or not the caller already called configure_io_encoding().
use open ':std', ':encoding(UTF-8)';
use CLIO::UI::Terminal qw(box_char ui_char supports_unicode);
use CLIO::Compat::Terminal qw(GetTerminalSize);

=head1 NAME

CLIO::UI::ToolOutputFormatter - Unified formatter for tool execution output

=head1 DESCRIPTION

Provides consistent formatting for tool execution output across different themes and display modes.

Extracted from WorkflowOrchestrator.pm to centralize tool output formatting logic.

=head1 SYNOPSIS

    use CLIO::UI::ToolOutputFormatter;
    
    my $formatter = CLIO::UI::ToolOutputFormatter->new(ui => $ui);
    
    # Display tool header
    $formatter->display_tool_header($tool_name, $tool_display_name, $is_first_tool);
    
    # Display action detail
    $formatter->display_action_detail($action_detail, $is_error, $is_last_action);

=head1 METHODS

=head2 new(%args)

Create new formatter instance.

Arguments:
- ui: CLIO::UI::Chat instance (required for colorization and theme access)

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        ui => $args{ui},  # CLIO::UI::Chat instance
    };
    
    bless $self, $class;
    return $self;
}

=head2 get_tool_format()

Get the tool display format from theme (box or inline).

Returns: 'box' or 'inline'

=cut

sub get_tool_format {
    my ($self) = @_;
    
    my $tool_format = 'box';  # default
    if ($self->{ui} && 
        $self->{ui}->{theme_mgr} && 
        $self->{ui}->{theme_mgr}->can('get_tool_display_format')) {
        $tool_format = $self->{ui}->{theme_mgr}->get_tool_display_format();
    }
    
    return $tool_format;
}

=head2 _is_non_interactive

Check whether we're in non-interactive (machine-readable) mode.

=cut

sub _is_non_interactive {
    my ($self) = @_;
    return ($self->{ui} && $self->{ui}{non_interactive}) ? 1 : 0;
}

=head2 _emit_noninteractive($tag, $content)

Emit a machine-readable tagged line. In non-interactive mode,
tool tracking output uses [TAG] prefixed lines so downstream
consumers (pipes, host apps, embedding) can parse tool activity.

Format: [TAG] content\n  (or just [TAG] if content is empty)

=cut

sub _emit_noninteractive {
    my ($self, $tag, $content) = @_;
    $tag = uc($tag);
    $tag =~ s/[^A-Z0-9_]/_/g;
    if (defined $content && length($content)) {
        print "[$tag] $content\n";
    } else {
        print "[$tag]\n";
    }
    STDOUT->flush() if STDOUT->can('flush');
    $self->{_last_noninteractive_tool} = $tag;
}

=head2 _ui_char($name)

Get a UI symbol from theme, falling back to Terminal.pm defaults.

=cut

sub _ui_char {
    my ($self, $name) = @_;
    
    # Try theme override first
    if ($self->{ui} &&
        $self->{ui}->{theme_mgr} &&
        $self->{ui}->{theme_mgr}->can('get_ui_char')) {
        return $self->{ui}->{theme_mgr}->get_ui_char($name);
    }
    
    # Direct fallback to Terminal.pm
    return ui_char($name eq 'tool_bullet' ? 'bullet' :
                   $name eq 'tool_separator' ? 'separator' : $name);
}

=head2 display_tool_header($tool_name, $tool_display_name, $is_first_tool)

Display the tool header (box-drawing or inline prefix).

Arguments:
- tool_name: Internal tool name (for tracking)
- tool_display_name: Display name for the tool
- is_first_tool: Boolean - whether this is the first tool output (affects spacing)

=cut

sub display_tool_header {
    my ($self, $tool_name, $tool_display_name, $is_first_tool, $is_continuation) = @_;
    
    # Non-interactive mode: emit machine-readable [TOOL_NAME] header
    if ($self->_is_non_interactive()) {
        my $tag = $tool_name;
        $tag =~ s/^(?:CLIO::Tools::|CLIO::UI::Commands::)//;
        $tag =~ s/::/_/g;
        $self->_emit_noninteractive($tag, '');
        return;
    }
    
    my $tool_format = $self->get_tool_format();
    
    if ($tool_format eq 'inline') {
        my $bullet = $self->_ui_char('tool_bullet');
        my $sep    = $self->_ui_char('tool_separator');
        
        # Track prefix width for word-wrap in display_action_detail
        $self->{_inline_prefix_width} = length("$bullet $tool_display_name $sep ");
        
        if ($is_continuation) {
            # Continuation: align separator under the first header
            my $pad_len = length("$bullet $tool_display_name ");
            my $pad = ' ' x $pad_len;
            if ($self->{ui} && $self->{ui}->can('colorize')) {
                my $s = $self->{ui}->colorize("$sep ", 'DIM');
                print "$pad$s";
            } else {
                print "$pad$sep ";
            }
        } else {
            # Full header with three-color style
            if ($self->{ui} && $self->{ui}->can('colorize')) {
                my $b = $self->{ui}->colorize($bullet, 'DIM');
                my $n = $self->{ui}->colorize(" $tool_display_name ", 'ASSISTANT');
                my $s = $self->{ui}->colorize("$sep ", 'DIM');
                print "$b$n$s";
            } else {
                print "$bullet $tool_display_name $sep ";
            }
        }
        STDOUT->flush() if STDOUT->can('flush');
    } else {
        # Box format (default): box-drawing header for this tool
        if ($self->{ui} && $self->{ui}->can('colorize')) {
            if (!$is_first_tool) {
                print "\n";
                STDOUT->flush() if STDOUT->can('flush');
            }
            
            my $tl = box_char('topleft');
            my $hz = box_char('horizontal');
            my $tl_conn = box_char('tleft');
            my $connector = $self->{ui}->colorize("${tl}${hz}${hz}${tl_conn} ", 'DIM');
            my $name = $self->{ui}->colorize($tool_display_name, 'ASSISTANT');
            print "$connector$name\n";
        } else {
            if (!$is_first_tool) {
                print "\n";
                STDOUT->flush() if STDOUT->can('flush');
            }
            my $tl = box_char('topleft');
            my $hz = box_char('horizontal');
            my $tl_conn = box_char('tleft');
            print "${tl}${hz}${hz}${tl_conn} $tool_display_name\n";
        }
        STDOUT->flush() if STDOUT->can('flush');
    }
}

=head2 display_action_detail($action_detail, $is_error, $remaining_same_tool, $expanded_content)

Display the action detail line (what the tool did).

Arguments:
- action_detail: Description of what the tool did
- is_error: Boolean - whether this is an error message
- remaining_same_tool: Integer - count of remaining calls to same tool (for connector choice)
- expanded_content: Optional array of additional lines to display below the action

=cut

sub display_action_detail {
    my ($self, $action_detail, $is_error, $remaining_same_tool, $expanded_content) = @_;
    
    return unless $action_detail;
    
    # Non-interactive mode: emit [DETAILS] line
    if ($self->_is_non_interactive()) {
        if ($is_error) {
            $self->_emit_noninteractive('ERROR', $action_detail);
        } else {
            $self->_emit_noninteractive('DETAILS', $action_detail);
        }
        # Also emit expanded content
        if ($expanded_content && ref($expanded_content) eq 'ARRAY' && @$expanded_content) {
            for my $line (@$expanded_content) {
                $self->_emit_noninteractive('OUTPUT', $line);
            }
        }
        STDOUT->flush() if STDOUT->can('flush');
        $self->{_inline_prefix_width} = 0;
        return;
    }
    
    my $tool_format = $self->get_tool_format();
    
    if ($tool_format eq 'inline') {
        # Inline format: action detail on same line after "∙ Tool -> "
        # Word-wrap at terminal width, indent continuation lines
        my $prefix_width = $self->{_inline_prefix_width} || 24;
        my ($term_cols) = GetTerminalSize();
        $term_cols ||= 80;
        my $max_width = $term_cols - 1;  # 1 column margin
        my $avail = $max_width - $prefix_width;
        $avail = 20 if $avail < 20;  # Minimum usable width
        
        my $color = $is_error ? 'ERROR' : 'DATA';
        my $can_color = ($self->{ui} && $self->{ui}->can('colorize'));
        
        if (length($action_detail) <= $avail) {
            # Fits on one line
            if ($can_color) {
                print $self->{ui}->colorize($action_detail, $color) . "\n";
            } else {
                print "$action_detail\n";
            }
        } else {
            # Word-wrap: split into lines that fit within $avail
            my $indent = ' ' x $prefix_width;
            my @lines;
            my $current = '';
            
            for my $word (split /\s+/, $action_detail) {
                if ($current eq '') {
                    $current = $word;
                } elsif (length($current) + 1 + length($word) > $avail) {
                    push @lines, $current;
                    $current = $word;
                } else {
                    $current .= " $word";
                }
            }
            push @lines, $current if $current ne '';
            
            for my $idx (0 .. $#lines) {
                my $text = $lines[$idx];
                if ($idx > 0) {
                    # Indent continuation lines to align under first line
                    if ($can_color) {
                        print $self->{ui}->colorize($indent, 'DIM') . $self->{ui}->colorize($text, $color) . "\n";
                    } else {
                        print "$indent$text\n";
                    }
                } else {
                    if ($can_color) {
                        print $self->{ui}->colorize($text, $color) . "\n";
                    } else {
                        print "$text\n";
                    }
                }
            }
        }
        
        # Display expanded content indented under the bullet
        if ($expanded_content && ref($expanded_content) eq 'ARRAY' && @$expanded_content) {
            $self->display_hrule();
            for my $line (@$expanded_content) {
                my $wrapped = $self->wrap_text_to_width($line, '    ');
                if ($self->{ui} && $self->{ui}->can('colorize')) {
                    print $self->{ui}->colorize($wrapped, 'DIM') . "\n";
                } else {
                    print "$wrapped\n";
                }
            }
            $self->display_hrule();
        }
        
        STDOUT->flush() if STDOUT->can('flush');
    } else {
        # Box format: use box-drawing continuation
        # Determine connector: ├─ if more actions/content coming, └─ if last
        my $has_expanded = ($expanded_content && ref($expanded_content) eq 'ARRAY' && @$expanded_content);
        my $tr = box_char('tright');
        my $bl = box_char('bottomleft');
        my $hz = box_char('horizontal');
        my $connector = ($remaining_same_tool > 0 || $has_expanded) ? "${tr}${hz} " : "${bl}${hz} ";
        
        if ($self->{ui} && $self->{ui}->can('colorize')) {
            # Format: {dim}├─ {data/error}action_detail{reset} or {dim}└─ {data/error}action_detail{reset}
            my $conn_colored = $self->{ui}->colorize($connector, 'DIM');
            # Use ERROR color for error messages, DATA color for normal messages
            my $color = $is_error ? 'ERROR' : 'DATA';
            my $action_colored = $self->{ui}->colorize($action_detail, $color);
            print "$conn_colored$action_colored\n";
            STDOUT->flush() if STDOUT->can('flush');
        } else {
            print "$connector$action_detail\n";
            STDOUT->flush() if STDOUT->can('flush');
        }
        
        # Display expanded content with continuation lines
        if ($has_expanded) {
            my $vt = box_char('vertical');
            my $pipe = "${vt}  ";
            my $last_conn = ($remaining_same_tool > 0) ? "${tr}${hz} " : "${bl}${hz} ";
            
            for my $idx (0 .. $#$expanded_content) {
                my $line = $expanded_content->[$idx];
                my $is_last_line = ($idx == $#$expanded_content);
                my $line_connector = $is_last_line ? $last_conn : $pipe;
                
                if ($self->{ui} && $self->{ui}->can('colorize')) {
                    my $conn_colored = $self->{ui}->colorize($line_connector, 'DIM');
                    my $line_colored = $self->{ui}->colorize($line, 'DIM');
                    print "$conn_colored$line_colored\n";
                } else {
                    print "$line_connector$line\n";
                }
            }
            STDOUT->flush() if STDOUT->can('flush');
        }
    }
    $| = 1;
}

=head2 display_expanded_content($expanded_content)

Display expanded content lines (e.g., command output) independently from an
action detail line. Used when the action was already displayed before execution.

Arguments:
- expanded_content: Arrayref of lines to display

=cut

sub display_expanded_content {
    my ($self, $expanded_content) = @_;
    return unless $expanded_content && ref($expanded_content) eq 'ARRAY' && @$expanded_content;
    
    # Non-interactive mode: emit [OUTPUT] lines
    if ($self->_is_non_interactive()) {
        for my $line (@$expanded_content) {
            $self->_emit_noninteractive('OUTPUT', $line);
        }
        STDOUT->flush() if STDOUT->can('flush');
        return;
    }
    
    my $tool_format = $self->get_tool_format();
    
    if ($tool_format eq 'inline') {
        $self->display_hrule();
        for my $line (@$expanded_content) {
            my $wrapped = $self->wrap_text_to_width($line, '    ');
            if ($self->{ui} && $self->{ui}->can('colorize')) {
                print $self->{ui}->colorize($wrapped, 'DIM') . "\n";
            } else {
                print "$wrapped\n";
            }
        }
        $self->display_hrule();
    } else {
        # Box format: use continuation lines
        my $vt = box_char('vertical');
        my $bl = box_char('bottomleft');
        my $hz = box_char('horizontal');
        
        for my $idx (0 .. $#$expanded_content) {
            my $line = $expanded_content->[$idx];
            my $is_last = ($idx == $#$expanded_content);
            my $connector = $is_last ? "${bl}${hz} " : "${vt}  ";
            
            if ($self->{ui} && $self->{ui}->can('colorize')) {
                my $conn_colored = $self->{ui}->colorize($connector, 'DIM');
                my $line_colored = $self->{ui}->colorize($line, 'DIM');
                print "$conn_colored$line_colored\n";
            } else {
                print "$connector$line\n";
            }
        }
    }
    STDOUT->flush() if STDOUT->can('flush');
}

=head2 display_hrule()

Display a dim horizontal rule for visual separation of expanded content blocks.
Only applies in inline tool format.

=cut

sub display_hrule {
    my ($self) = @_;

    # Non-interactive mode: emit a simple separator
    if ($self->_is_non_interactive()) {
        print "\n";
        STDOUT->flush() if STDOUT->can('flush');
        return;
    }

    my $tool_format = $self->get_tool_format();
    return unless $tool_format eq 'inline';

    my ($term_cols) = GetTerminalSize();
    $term_cols ||= 80;
    my $indent = $self->_theme_indent();
    my $rule_len = $term_cols - length($indent) - 1;

    # Honor the theme's separator_repeat preference when set; otherwise
    # fit to terminal width with a sane minimum so thin terminals don't
    # produce one-character rules.
    my $theme_repeat = $self->_theme_separator_repeat();
    if ($theme_repeat && $theme_repeat > 0) {
        $rule_len = $theme_repeat;
    }
    $rule_len = 20 if $rule_len < 20;

    my $hz = box_char('horizontal');
    my $rule = $hz x $rule_len;

    if ($self->{ui} && $self->{ui}->can('colorize')) {
        print $self->{ui}->colorize("$indent$rule", 'DIM') . "\n";
    } else {
        print "$indent$rule\n";
    }
    STDOUT->flush() if STDOUT->can('flush');
}

# Pull theme-controlled indent width. Defaults to 4 (existing behavior).
sub _theme_indent {
    my ($self) = @_;
    my $ui = $self->{ui};
    if ($ui && $ui->{theme_mgr} && $ui->{theme_mgr}->can('get_template')) {
        my $val = $ui->{theme_mgr}->get_template('indent_width');
        if (defined $val && $val =~ /^\d+$/ && $val >= 0 && $val <= 16) {
            return ' ' x $val;
        }
    }
    return ' ' x 4;
}

# Pull theme-controlled separator repeat. undef = fit-to-terminal.
sub _theme_separator_repeat {
    my ($self) = @_;
    my $ui = $self->{ui};
    if ($ui && $ui->{theme_mgr} && $ui->{theme_mgr}->can('get_template')) {
        my $val = $ui->{theme_mgr}->get_template('separator_repeat');
        if (defined $val && $val =~ /^\d+$/ && $val > 0) {
            return $val;
        }
    }
    return undef;
}

=head2 wrap_text_to_width($text, $indent, $max_width)

Word-wrap text to fit within a terminal width, preserving existing line breaks.
Each line is broken at the last space before the width limit. Continuation lines
use the same indent as the first line.

Arguments:
- text: The text to wrap (may contain newlines)
- indent: String prefix for each line (e.g., '    ' for 4-space indent)
- max_width: Terminal width to wrap at (default: auto-detect)

Returns: Wrapped text string with indent applied to all lines

=cut

sub wrap_text_to_width {
    my ($self, $text, $indent, $max_width) = @_;
    
    return '' unless defined $text && length($text);
    
    $indent //= '    ';
    if (!$max_width) {
        my ($term_cols) = GetTerminalSize();
        $max_width = ($term_cols || 80) - 1;  # 1 column margin
    }
    
    my $avail = $max_width - length($indent);
    $avail = 20 if $avail < 20;
    
    my @input_lines = split /\n/, $text, -1;
    my @output_lines;
    
    for my $line (@input_lines) {
        if (length($line) <= $avail) {
            push @output_lines, "$indent$line";
        } else {
            my $current = '';
            for my $word (split /(\s+)/, $line) {
                if ($current eq '' && $word =~ /^\s+$/) {
                    next;  # skip leading whitespace on wrapped line
                }
                if ($current eq '') {
                    $current = $word;
                } elsif (length($current) + length($word) > $avail) {
                    # Current line is full - emit it
                    $current =~ s/\s+$//;  # trim trailing space
                    push @output_lines, "$indent$current";
                    if ($word =~ /^\s+$/) {
                        $current = '';  # don't start next line with whitespace
                    } else {
                        $current = $word;
                    }
                } else {
                    $current .= $word;
                }
            }
            if ($current ne '') {
                $current =~ s/\s+$//;
                push @output_lines, "$indent$current";
            }
        }
    }
    
    return join("\n", @output_lines);
}

=head2 format_error($error_message)

Format an error message for display (shortens long messages).

Arguments:
- error_message: The error message text

Returns: Shortened error message suitable for display

=cut

sub format_error {
    my ($self, $error_message) = @_;
    
    return "Unknown error" unless $error_message;
    
    # Simplify common error messages for better UX
    if ($error_message =~ /Tool returned invalid result/) {
        return "Invalid tool result.";
    } elsif ($error_message =~ /Failed to parse tool arguments/) {
        return "Invalid arguments.";
    } else {
        # For multi-line messages, show the first line (the key message)
        # For single-line messages, truncate if very long
        if ($error_message =~ /\n/) {
            my ($first_line) = $error_message =~ /^([^\n]+)/;
            return "Error: $first_line";
        } else {
            my $short_error = substr($error_message, 0, 80);
            $short_error .= '...' if length($error_message) > 80;
            return "Error: $short_error";
        }
    }
}

=head2 display_diff($old, $new, $filename)

Display a colorized unified diff for a file change using DiffRenderer.

=cut

sub display_diff {
    my ($self, $old, $new, $filename) = @_;

    # Non-interactive mode: emit plain unified diff without colors
    if ($self->_is_non_interactive()) {
        eval { require CLIO::UI::DiffRenderer; };
        if ($@) {
            # Fallback: simple diff output
            $self->_emit_noninteractive('DIFF', $filename);
            return;
        }
        my $renderer = CLIO::UI::DiffRenderer->new(
            theme_mgr => ($self->{ui} && $self->{ui}->{theme_mgr}) ? $self->{ui}->{theme_mgr} : undef,
            ansi      => undef,  # Disable colors
            max_lines => 20,
            context   => 3,
        );
        $renderer->display_diff($old, $new, $filename);
        return;
    }

    eval { require CLIO::UI::DiffRenderer; };
    return if $@;
    
    my $renderer = CLIO::UI::DiffRenderer->new(
        theme_mgr => ($self->{ui} && $self->{ui}->{theme_mgr}) ? $self->{ui}->{theme_mgr} : undef,
        ansi      => ($self->{ui} && $self->{ui}->{ansi}) ? $self->{ui}->{ansi} : undef,
        max_lines => 20,
        context   => 3,
    );
    
    $renderer->display_diff($old, $new, $filename);
}

1;
