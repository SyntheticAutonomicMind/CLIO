package CLIO::UI::ToolOutputFormatter;

use strict;
use warnings;
use utf8;
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

=head2 display_tool_header($tool_name, $tool_display_name, $is_first_tool)

Display the tool header (box-drawing or inline prefix).

Arguments:
- tool_name: Internal tool name (for tracking)
- tool_display_name: Display name for the tool
- is_first_tool: Boolean - whether this is the first tool output (affects spacing)

=cut

sub display_tool_header {
    my ($self, $tool_name, $tool_display_name, $is_first_tool) = @_;
    
    my $tool_format = $self->get_tool_format();
    
    if ($tool_format eq 'inline') {
        # Inline format: "TOOL NAME: " prefix (no box-drawing)
        # The action will appear on the same line after the colon
        if ($self->{ui} && $self->{ui}->can('colorize')) {
            my $prefix = $self->{ui}->colorize("$tool_display_name: ", 'ASSISTANT');
            print "$prefix";
        } else {
            print "$tool_display_name: ";
        }
        STDOUT->flush() if STDOUT->can('flush');
    } else {
        # Box format (default): box-drawing header for this tool
        if ($self->{ui} && $self->{ui}->can('colorize')) {
            # Only add spacing if this isn't the first tool output
            if (!$is_first_tool) {
                print "\n";
                STDOUT->flush() if STDOUT->can('flush');
            }
            
            # Build header with three-color format:
            # {dim}┌──┤ {agent_label}TOOL NAME{reset}
            my $connector = $self->{ui}->colorize("\x{250C}\x{2500}\x{2500}\x{2524} ", 'DIM');
            my $name = $self->{ui}->colorize($tool_display_name, 'ASSISTANT');
            print "$connector$name\n";
        } else {
            # Fallback without colors
            if (!$is_first_tool) {
                print "\n";
                STDOUT->flush() if STDOUT->can('flush');
            }
            print "\x{250C}\x{2500}\x{2500}\x{2524} $tool_display_name\n";
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
        # Inline format: just print the action detail on the same line, then newline
        if ($self->{ui} && $self->{ui}->can('colorize')) {
            my $color = $is_error ? 'ERROR' : 'DATA';
            my $action_colored = $self->{ui}->colorize($action_detail, $color);
            print "$action_colored\n";
        } else {
            print "$action_detail\n";
        }
        
        # Display expanded content if present
        if ($expanded_content && ref($expanded_content) eq 'ARRAY' && @$expanded_content) {
            for my $line (@$expanded_content) {
                if ($self->{ui} && $self->{ui}->can('colorize')) {
                    my $line_colored = $self->{ui}->colorize("  $line", 'DIM');
                    print "$line_colored\n";
                } else {
                    print "  $line\n";
                }
            }
        }
        
        STDOUT->flush() if STDOUT->can('flush');
    } else {
        # Box format: use box-drawing continuation
        # Determine connector: ├─ if more actions/content coming, └─ if last
        my $has_expanded = ($expanded_content && ref($expanded_content) eq 'ARRAY' && @$expanded_content);
        my $connector = ($remaining_same_tool > 0 || $has_expanded) ? "\x{251C}\x{2500} " : "\x{2514}\x{2500} ";
        
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
            my $pipe = "\x{2502}  ";  # │  (vertical bar with indent)
            my $last_conn = ($remaining_same_tool > 0) ? "\x{251C}\x{2500} " : "\x{2514}\x{2500} ";
            
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

1;
