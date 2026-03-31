# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::ToolOutputFormatter;

use strict;
use warnings;
use utf8;
use CLIO::UI::Terminal qw(box_char ui_char supports_unicode);
use CLIO::Compat::Terminal qw(GetTerminalSize);
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

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
                if ($self->{ui} && $self->{ui}->can('colorize')) {
                    my $line_colored = $self->{ui}->colorize("    $line", 'DIM');
                    print "$line_colored\n";
                } else {
                    print "    $line\n";
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
    
    my $tool_format = $self->get_tool_format();
    
    if ($tool_format eq 'inline') {
        $self->display_hrule();
        for my $line (@$expanded_content) {
            if ($self->{ui} && $self->{ui}->can('colorize')) {
                my $line_colored = $self->{ui}->colorize("    $line", 'DIM');
                print "$line_colored\n";
            } else {
                print "    $line\n";
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
    
    my $tool_format = $self->get_tool_format();
    return unless $tool_format eq 'inline';
    
    my ($term_cols) = GetTerminalSize();
    $term_cols ||= 80;
    my $indent = '    ';  # 4 spaces to align under expanded content
    my $rule_len = $term_cols - length($indent) - 1;
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
        return "Invalid tool result, adapting.";
    } elsif ($error_message =~ /Failed to parse tool arguments/) {
        return "Invalid arguments, retrying.";
    } else {
        # For other errors, show a short version
        my $short_error = substr($error_message, 0, 80);
        $short_error .= '...' if length($error_message) > 80;
        return "Error: $short_error";
    }
}

=head2 display_diff($old, $new, $filename)

Display a colorized unified diff for a file change using DiffRenderer.

=cut

sub display_diff {
    my ($self, $old, $new, $filename) = @_;
    
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
