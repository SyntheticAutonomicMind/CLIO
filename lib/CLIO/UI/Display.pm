package CLIO::UI::Display;

use strict;
use warnings;
use Carp qw(croak confess);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::Display - Message display and formatting for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Display;
  
  my $display = CLIO::UI::Display->new(
      theme_mgr => $theme_mgr,
      markdown_renderer => $markdown_renderer,
      ansi => $ansi,
      terminal_width => 80,
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

Uses theme manager for colors and markdown renderer for rich text.

=head1 METHODS

=head2 new(%args)

Create a new Display instance.

Arguments:
- theme_mgr: Theme manager instance
- markdown_renderer: Markdown renderer instance
- ansi: ANSI color handler
- terminal_width: Terminal width in columns
- debug: Enable debug logging

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        theme_mgr => $args{theme_mgr} || croak "theme_mgr required",
        markdown_renderer => $args{markdown_renderer} || croak "markdown_renderer required",
        ansi => $args{ansi} || croak "ansi required",
        terminal_width => $args{terminal_width} || 80,
        debug => $args{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}

=head2 display_user_message($message)

Display a user message with appropriate styling.

=head2 display_assistant_message($message)

Display an assistant message with appropriate styling.

=head2 display_system_message($message)

Display a system message.

=head2 display_error_message($message)

Display an error message.

=head2 display_success_message($message)

Display a success message.

=head2 display_warning_message($message)

Display a warning message.

=head2 display_info_message($message)

Display an informational message.

=head2 display_header($text)

Display a section header.

=head2 display_command_header($command)

Display a command header.

=head2 display_section_header($title)

Display a section header with formatting.

=head2 display_key_value($key, $value)

Display a key-value pair.

=head2 display_list_item($item)

Display a list item.

=head2 display_usage_summary($summary)

Display API usage summary.

=head2 show_thinking()

Show thinking indicator.

=head2 clear_thinking()

Clear thinking indicator.

=cut

# Methods will be extracted from Chat.pm during refactoring

1;
