package CLIO::UI::StreamingHandler;

use strict;
use warnings;
use Carp qw(croak confess);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::StreamingHandler - Streaming output management for CLIO

=head1 SYNOPSIS

  use CLIO::UI::StreamingHandler;
  
  my $handler = CLIO::UI::StreamingHandler->new(
      markdown_renderer => $markdown_renderer,
      ansi => $ansi,
      debug => 0
  );
  
  # Initialize streaming
  $handler->reset_streaming_state();
  
  # Add content to buffer
  $handler->add_to_buffer($chunk);
  
  # Flush buffer
  $handler->flush_output_buffer();
  
  # Render and write
  $handler->writeline($text);

=head1 DESCRIPTION

StreamingHandler manages streaming output from AI responses. Extracted from
Chat.pm to isolate streaming logic and buffer management.

Responsibilities:
- Streaming state management
- Output buffer management
- Markdown rendering for streaming content
- Line-by-line output with proper flushing

Handles the complexity of streaming AI responses with markdown rendering,
color codes, and proper terminal output buffering.

=head1 METHODS

=head2 new(%args)

Create a new StreamingHandler instance.

Arguments:
- markdown_renderer: Markdown renderer instance
- ansi: ANSI color handler
- debug: Enable debug logging

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        markdown_renderer => $args{markdown_renderer} || croak "markdown_renderer required",
        ansi => $args{ansi} || croak "ansi required",
        debug => $args{debug} // 0,
        
        # Streaming state
        screen_buffer => [],
        line_count => 0,
        _streaming_markdown_buffer => '',
        _streaming_line_buffer => '',
        _first_chunk_received => 0,
    };
    
    bless $self, $class;
    return $self;
}

=head2 reset_streaming_state()

Reset all streaming state variables for a new response.

=head2 flush_output_buffer()

Flush the output buffer to STDOUT.

Returns: 1 on success

=head2 add_to_buffer($content)

Add content to the screen buffer for later display.

=head2 writeline($text)

Write a line of text to STDOUT with proper formatting.

=head2 render_markdown($text)

Render markdown and return formatted output.

=head2 colorize($text, $style)

Apply color/style to text using theme manager.

=cut

# Methods will be extracted from Chat.pm during refactoring

1;
