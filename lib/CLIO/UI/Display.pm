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
    
    # Add to session history for AI context (original, not rendered)
    if ($chat->{session}) {
        print STDERR "[DEBUG][Chat] Adding user message to session history\n" if should_log('DEBUG');
        $chat->{session}->add_message('user', $message);
    } else {
        print STDERR "[ERROR][Chat] No session object - cannot store message!\n" if should_log('ERROR');
    }
    
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

Display a system message.

=cut

sub display_system_message {
    my ($self, $message) = @_;
    
    my $chat = $self->{chat};
    
    # Add to screen buffer
    $chat->add_to_buffer('system', $message);
    
    my $line = $chat->colorize("SYSTEM: ", 'SYSTEM') . $message;
    $chat->writeline($line, markdown => 0);
}

=head2 display_error_message($message)

Display an error message.

=cut

sub display_error_message {
    my ($self, $message) = @_;
    
    my $chat = $self->{chat};
    
    # Add to screen buffer
    $chat->add_to_buffer('error', $message);
    
    my $line = $chat->colorize("ERROR: ", 'ERROR') . $message;
    $chat->writeline($line, markdown => 0);
}

=head2 display_success_message($message)

Display a success message.

=cut

sub display_success_message {
    my ($self, $message) = @_;
    
    my $chat = $self->{chat};
    
    # Add to screen buffer
    $chat->add_to_buffer('success', $message);
    
    my $line = $chat->colorize("", 'success_message') . $message;
    $chat->writeline($line, markdown => 0);
}

=head2 display_warning_message($message)

Display a warning message.

=cut

sub display_warning_message {
    my ($self, $message) = @_;
    
    my $chat = $self->{chat};
    
    # Add to screen buffer
    $chat->add_to_buffer('warning', $message);
    
    my $line = $chat->colorize("[WARN] ", 'warning_message') . $message;
    $chat->writeline($line, markdown => 0);
}

=head2 display_info_message($message)

Display an informational message.

=cut

sub display_info_message {
    my ($self, $message) = @_;
    
    my $chat = $self->{chat};
    
    # Add to screen buffer
    $chat->add_to_buffer('info', $message);
    
    my $line = $chat->colorize("[INFO] ", 'info_message') . $message;
    $chat->writeline($line, markdown => 0);
}

=head2 display_command_header($text, $width)

Display a command header with formatting.

=cut

sub display_command_header {
    my ($self, $text, $width) = @_;
    $width ||= 70;
    
    my $chat = $self->{chat};
    
    $chat->writeline('', markdown => 0);
    $chat->writeline($chat->colorize($text, 'command_header'), markdown => 0);
    $chat->writeline('', markdown => 0);
}

=head2 display_section_header($text, $width)

Display a section header with formatting.

=cut

sub display_section_header {
    my ($self, $text, $width) = @_;
    $width ||= 70;
    
    my $chat = $self->{chat};
    
    $chat->writeline($chat->colorize($text, 'command_subheader'), markdown => 0);
}

=head2 display_key_value($key, $value, $key_width)

Display a key-value pair.

=cut

sub display_key_value {
    my ($self, $key, $value, $key_width) = @_;
    $key_width ||= 20;
    
    my $chat = $self->{chat};
    
    my $line = sprintf("%-${key_width}s %s",
        $chat->colorize($key . ":", 'command_label'),
        $chat->colorize($value, 'command_value'));
    $chat->writeline($line, markdown => 0);
}

=head2 display_list_item($item, $num)

Display a list item.

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
    
    print $chat->colorize("━ SERVER ━ ", 'SYSTEM');
    print $cost_str;
    print $quota_info;
    print " " . $chat->colorize("━", 'SYSTEM');
    print "\n";
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

