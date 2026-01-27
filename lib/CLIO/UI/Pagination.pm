package CLIO::UI::Pagination;

use strict;
use warnings;
use Carp qw(croak confess);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::Pagination - Page navigation and display for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Pagination;
  
  my $pager = CLIO::UI::Pagination->new(
      display => $display_instance,
      terminal_height => 24,
      debug => 0
  );
  
  # Display paginated list
  $pager->display_paginated_list(\@items, "Title");
  
  # Display paginated content
  $pager->display_paginated_content($text, "Title");
  
  # Redraw current page
  $pager->redraw_page();

=head1 DESCRIPTION

Pagination handles page-based navigation for long content. Extracted from
Chat.pm to separate pagination logic from core display.

Responsibilities:
- Page buffer management
- Arrow key navigation (up/down for prev/next page)
- Page rendering
- Screen repainting

Supports both list-based and text-based pagination with proper terminal
handling and buffer management.

=head1 METHODS

=head2 new(%args)

Create a new Pagination instance.

Arguments:
- display: Display instance for output
- terminal_height: Terminal height in rows
- debug: Enable debug logging

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        display => $args{display} || croak "display instance required",
        terminal_height => $args{terminal_height} || 24,
        debug => $args{debug} // 0,
        
        # Pagination state
        pages => [],
        current_page => [],
        page_index => 0,
        pagination_enabled => 0,
    };
    
    bless $self, $class;
    return $self;
}

=head2 display_paginated_list(\@items, $title)

Display a list of items with pagination.

Supports arrow key navigation through pages.

=head2 display_paginated_content($content, $title)

Display large text content with pagination.

Splits content into pages based on terminal height.

=head2 redraw_page()

Redraw the current page.

=head2 repaint_screen()

Repaint the entire screen with buffered content.

=cut

# Methods will be extracted from Chat.pm during refactoring

1;
