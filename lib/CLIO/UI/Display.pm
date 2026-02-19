package CLIO::UI::Display;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak confess);
use CLIO::Core::Logger qw(should_log);
use CLIO::Util::TextSanitizer qw(sanitize_text);

=head1 NAME

CLIO::UI::Display - Message display and formatting for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Display;
  
  my $display = CLIO::UI::Display->new(
      chat => $chat_instance,
      debug => 0
  );
  
  # Display messages
  $display->display_user_message("Hello CLIO");
  $display->display_assistant_message("Hello! How can I help?");
  $display->display_error_message("Error occurred");
  
  # Display structured content
  $display->display_header("Section Title");
  $display->display_key_value("Config", "Value");
  $display->display_list_item("Item");

=head1 DESCRIPTION

Display handles all message formatting and output for the CLIO chat interface.
Extracted from Chat.pm to separate presentation concerns from business logic.

Responsibilities:
- Message display (user, assistant, system, error, success, warning, info)
- Section formatting (headers, key-value pairs, list items)
- Special displays (usage summaries, thinking indicators)

Phase 1: Delegates back to Chat for colorize, render_markdown, add_to_buffer.
Future: Will be fully independent with own implementations.

=head1 METHODS

=head2 new(%args)

Create a new Display instance.

Arguments:
- chat: Parent Chat instance (for colorize, render_markdown, etc.)
- debug: Enable debug logging

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}

=head2 display_user_message($message)

Display a user message with appropriate styling.

=cut

sub display_user_message {
    my ($self, $message) = @_;
    
    my $chat = $self->{chat};
    
    # Add to screen buffer (original text for buffer)
    $chat->add_to_buffer('user', $message);
    
    # NOTE: Session history is managed by WorkflowOrchestrator (WorkflowOrchestrator.pm:318)
    # Do NOT add message here - that would create duplicates
    # WorkflowOrchestrator adds the message to session before processing with API
    
    # Render markdown for display only (not for AI)
    my $display_message = $message;
    if ($chat->{enable_markdown}) {
        $display_message = $chat->render_markdown($message);
    }
    
    # Display with role label using writeline (markdown already rendered above)
    my $line = $chat->colorize("YOU: ", 'USER') . $display_message;
    $chat->writeline($line, markdown => 0);
}

=head2 display_assistant_message($message)

Display an assistant message with appropriate styling.

=cut

sub display_assistant_message {
    my ($self, $message) = @_;
    
    my $chat = $self->{chat};
    
    # Add to screen buffer (display with original emojis)
    $chat->add_to_buffer('assistant', $message);
    
    # Add to session history for AI context (sanitized to prevent encoding issues)
    if ($chat->{session}) {
        print STDERR "[DEBUG][Chat] Adding assistant message to session history\n" if should_log('DEBUG');
        my $sanitized = sanitize_text($message);
        $chat->{session}->add_message('assistant', $sanitized);
    } else {
        print STDERR "[ERROR][Chat] No session object - cannot store message!\n" if should_log('ERROR');
    }
    
    # Render markdown if enabled
    my $display_message = $message;
    if ($chat->{enable_markdown}) {
        $display_message = $chat->render_markdown($message);
    }
    
    # Display with role label using writeline (markdown already rendered above)
    my $line = $chat->colorize("CLIO: ", 'ASSISTANT') . $display_message;
    $chat->writeline($line, markdown => 0);
}

=head2 display_system_message($message)

Display a system message using box-drawing format.

Displays a system message with box-drawing format for consistency with tool output:
  ┌──┤ SYSTEM
  └─ System message text here

=cut

sub display_system_message {
    my ($self, $message) = @_;
    
    my $chat = $self->{chat};
    
    # Add to screen buffer
    $chat->add_to_buffer('system', $message);
    
    # Handle multi-line messages by splitting and applying proper connectors
    my @lines = split /\n/, $message, -1;
    pop @lines if @lines && $lines[-1] eq '';  # Remove trailing empty if message ended with \n
    
    # Build header with three-color format:
    # {dim}┌──┤ {assistant}SYSTEM{reset}
    my $header_conn = $chat->colorize("\x{250C}\x{2500}\x{2500}\x{2524} ", 'DIM');
    my $header_name = $chat->colorize("SYSTEM", 'ASSISTANT');
    print "$header_conn$header_name\n";
    
    # Display each line of the message with appropriate connector
    # {dim}└─ {data}message{reset}
    for my $i (0..$#lines) {
        my $is_last = ($i == $#lines);
        my $connector = $is_last ? "\x{2514}\x{2500} " : "\x{251C}\x{2500} ";  # └─ or ├─
        my $conn_colored = $chat->colorize($connector, 'DIM');
        my $msg_colored = $chat->colorize($lines[$i], 'DATA');
        print "$conn_colored$msg_colored\n";
    }
}

=head2 display_error_message($message)

Display an error message with box-drawing format.

Format:
  ┌──┤ ERROR
  └─ message

=cut

sub display_error_message {
    my ($self, $message) = @_;
    
    my $chat = $self->{chat};
    
    # Add to screen buffer
    $chat->add_to_buffer('error', $message);
    
    # Box-drawing format
    my $header_conn = $chat->colorize("\x{250C}\x{2500}\x{2500}\x{2524} ", 'DIM');
    my $header_name = $chat->colorize("ERROR", 'ERROR');
    my $footer_conn = $chat->colorize("\x{2514}\x{2500} ", 'DIM');
    my $footer_msg = $chat->colorize($message, 'DATA');
    
    $chat->writeline("$header_conn$header_name", markdown => 0);
    $chat->writeline("$footer_conn$footer_msg", markdown => 0);
}

=head2 display_success_message($message)

Display a success message with box-drawing format.

Format:
  ┌──┤ SUCCESS
  └─ message

=cut

sub display_success_message {
    my ($self, $message) = @_;
    
    my $chat = $self->{chat};
    
    # Add to screen buffer
    $chat->add_to_buffer('success', $message);
    
    # Box-drawing format
    my $header_conn = $chat->colorize("\x{250C}\x{2500}\x{2500}\x{2524} ", 'DIM');
    my $header_name = $chat->colorize("SUCCESS", 'SUCCESS');
    my $footer_conn = $chat->colorize("\x{2514}\x{2500} ", 'DIM');
    my $footer_msg = $chat->colorize($message, 'DATA');
    
    $chat->writeline("$header_conn$header_name", markdown => 0);
    $chat->writeline("$footer_conn$footer_msg", markdown => 0);
}

=head2 display_warning_message($message)

Display a warning message with box-drawing format.

Format:
  ┌──┤ WARNING
  └─ message

=cut

sub display_warning_message {
    my ($self, $message) = @_;
    
    my $chat = $self->{chat};
    
    # Add to screen buffer
    $chat->add_to_buffer('warning', $message);
    
    # Box-drawing format
    my $header_conn = $chat->colorize("\x{250C}\x{2500}\x{2500}\x{2524} ", 'DIM');
    my $header_name = $chat->colorize("WARNING", 'WARNING');
    my $footer_conn = $chat->colorize("\x{2514}\x{2500} ", 'DIM');
    my $footer_msg = $chat->colorize($message, 'DATA');
    
    $chat->writeline("$header_conn$header_name", markdown => 0);
    $chat->writeline("$footer_conn$footer_msg", markdown => 0);
}

=head2 display_info_message($message)

Display an informational message with box-drawing format.

Format:
  ┌──┤ INFO
  └─ message

=cut

sub display_info_message {
    my ($self, $message) = @_;
    
    my $chat = $self->{chat};
    
    # Add to screen buffer
    $chat->add_to_buffer('info', $message);
    
    # Box-drawing format
    my $header_conn = $chat->colorize("\x{250C}\x{2500}\x{2500}\x{2524} ", 'DIM');
    my $header_name = $chat->colorize("INFO", 'ASSISTANT');  # Use ASSISTANT color for info
    my $footer_conn = $chat->colorize("\x{2514}\x{2500} ", 'DIM');
    my $footer_msg = $chat->colorize($message, 'DATA');
    
    $chat->writeline("$header_conn$header_name", markdown => 0);
    $chat->writeline("$footer_conn$footer_msg", markdown => 0);
}

=head2 display_command_header($text, $width)

Display a command header with double-line border (═══).
This is the main header for any / command output.

Standard format:
  ═══════════════════════════════════════════════════════════════
  COMMAND TITLE
  ═══════════════════════════════════════════════════════════════

=cut

sub display_command_header {
    my ($self, $text, $width) = @_;
    $width ||= 62;
    
    my $chat = $self->{chat};
    
    my $border = "═" x $width;
    
    $chat->writeline('', markdown => 0);
    $chat->writeline($chat->colorize($border, 'command_header'), markdown => 0);
    $chat->writeline($chat->colorize($text, 'command_header'), markdown => 0);
    $chat->writeline($chat->colorize($border, 'command_header'), markdown => 0);
    $chat->writeline('', markdown => 0);
}

=head2 display_section_header($text, $width)

Display a section header with single-line underline (───).
Used for subsections within a command output.

Standard format:
  
  SECTION TITLE
  ─────────────────────────────────────────────────────────────────

(blank line before header for visual separation)

=cut

sub display_section_header {
    my ($self, $text, $width) = @_;
    $width ||= 62;
    
    my $chat = $self->{chat};
    
    my $underline = "─" x $width;
    
    # Blank line before section for visual separation from previous content
    # Use writeline to ensure proper output handling (UTF-8, color codes, etc.)
    $chat->writeline('', markdown => 0);
    $chat->writeline($chat->colorize($text, 'command_subheader'), markdown => 0);
    $chat->writeline($chat->colorize($underline, 'dim'), markdown => 0);
}

=head2 display_key_value($key, $value, $key_width)

Display a key-value pair with consistent formatting.

Standard format:
  Key:                Value
  ^^^^^^^^^^^^^^^^^^^^
  (key_width chars)

=cut

sub display_key_value {
    my ($self, $key, $value, $key_width) = @_;
    $key_width ||= 20;
    
    my $chat = $self->{chat};
    
    # Pad the key before adding color codes (ANSI codes mess up sprintf width)
    my $padded_key = sprintf("%-${key_width}s", $key . ":");
    
    my $line = $chat->colorize($padded_key, 'command_label') . " " .
               $chat->colorize($value, 'command_value');
    $chat->writeline($line, markdown => 0);
}

=head2 display_command_row($command, $description, $cmd_width)

Display a command with its description (for help output).

Standard format:
  /command <args>        Description text here
  ^^^^^^^^^^^^^^^^^^^
  (cmd_width chars)

=cut

sub display_command_row {
    my ($self, $command, $description, $cmd_width) = @_;
    $cmd_width ||= 25;
    
    my $chat = $self->{chat};
    
    # Pad the command before adding color codes (ANSI codes mess up sprintf width)
    my $padded_cmd = sprintf("%-${cmd_width}s", $command);
    
    my $line = "  " . $chat->colorize($padded_cmd, 'help_command') . " " . $description;
    $chat->writeline($line, markdown => 0);
}

=head2 display_list_item($item, $num)

Display a list item (bulleted or numbered).

Standard format:
  • Item text (if no number)
  1. Item text (if number provided)

=cut

sub display_list_item {
    my ($self, $item, $num) = @_;
    
    my $chat = $self->{chat};
    
    my $line;
    if (defined $num) {
        $line = $chat->colorize("  $num. ", 'command_label') . $item;
    } else {
        $line = $chat->colorize("  • ", 'command_label') . $item;
    }
    $chat->writeline($line, markdown => 0);
}

=head2 display_tip($text)

Display a tip/hint line with consistent styling.

Standard format:
  • Tip text here

=cut

sub display_tip {
    my ($self, $text) = @_;
    
    my $chat = $self->{chat};
    
    my $line = "  " . $chat->colorize("•", 'muted') . " " . $chat->colorize($text, 'muted');
    $chat->writeline($line, markdown => 0);
}

=head2 display_usage_summary()

Display API usage summary.

=cut

sub display_usage_summary {
    my ($self) = @_;
    
    my $chat = $self->{chat};
    
    return unless $chat->{session} && $chat->{session}->{state};
    
    my $billing = $chat->{session}->{state}->{billing};
    return unless $billing;
    
    my $model = $billing->{model} || 'unknown';
    my $multiplier = $billing->{multiplier} || 0;
    
    # Only display for premium models (multiplier > 0)
    return if $multiplier == 0;
    
    # Only display if there was an ACTUAL charge in the last request (delta > 0)
    my $delta = $chat->{session}{_last_quota_delta} || 0;
    return if $delta <= 0;
    
    # Format multiplier
    my $cost_str;
    if ($multiplier == int($multiplier)) {
        $cost_str = sprintf("Cost: %dx", $multiplier);
    } else {
        $cost_str = sprintf("Cost: %.2fx", $multiplier);
        $cost_str =~ s/\.?0+x$/x/;
    }
    my $quota_info = '';
    
    # Get quota status if available
    if ($chat->{session}{quota}) {
        my $quota = $chat->{session}{quota};
        my $used = $quota->{used} || 0;
        my $entitlement = $quota->{entitlement} || 0;
        my $percent_remaining = $quota->{percent_remaining} || 0;
        my $percent_used = 100.0 - $percent_remaining;
        
        my $used_fmt = $used;
        $used_fmt =~ s/(\d)(?=(\d{3})+$)/$1,/g;
        
        my $ent_display;
        if ($entitlement == -1) {
            $ent_display = "∞";
        } else {
            $ent_display = $entitlement;
            $ent_display =~ s/(\d)(?=(\d{3})+$)/$1,/g;
        }
        
        $quota_info = sprintf(" Status: %s/%s Used: %.1f%%", $used_fmt, $ent_display, $percent_used);
    }
    
    # Build complete line with all components and display via writeline for consistency
    my $line = $chat->colorize("━ SERVER ━ ", 'SYSTEM') . $cost_str . $quota_info . " " . $chat->colorize("━", 'SYSTEM');
    $chat->writeline($line, markdown => 0);
}

=head2 show_thinking()

Show thinking indicator.

=cut

sub show_thinking {
    my ($self) = @_;
    
    my $chat = $self->{chat};
    
    print $chat->colorize("CLIO: ", 'ASSISTANT');
    print $chat->colorize("(thinking...)", 'DIM');
    $| = 1;
}

=head2 clear_thinking()

Clear thinking indicator.

=cut

sub clear_thinking {
    my ($self) = @_;
    
    my $chat = $self->{chat};
    
    # Clear line and move cursor back
    print "\e[2K\e[" . $chat->{terminal_width} . "D";
}

1;

