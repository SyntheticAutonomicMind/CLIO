package CLIO::UI::InputHandler;

use strict;
use warnings;
use Carp qw(croak confess);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::InputHandler - User input processing for CLIO

=head1 SYNOPSIS

  use CLIO::UI::InputHandler;
  
  my $handler = CLIO::UI::InputHandler->new(
      readline => $readline_instance,
      completer => $tab_completer,
      debug => 0
  );
  
  # Get user input
  my $input = $handler->get_input($prompt);
  
  # Pause for user acknowledgment
  $handler->pause($message);

=head1 DESCRIPTION

InputHandler manages all user input processing. Extracted from Chat.pm
to separate input concerns from output and business logic.

Responsibilities:
- Readline integration
- Tab completion setup
- Input sanitization
- Pause/prompt handling

Integrates with ReadLine for command history and tab completion.

=head1 METHODS

=head2 new(%args)

Create a new InputHandler instance.

Arguments:
- readline: ReadLine instance
- completer: TabCompletion instance
- debug: Enable debug logging

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        readline => $args{readline},
        completer => $args{completer},
        debug => $args{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}

=head2 get_input($prompt)

Get user input with the given prompt.

Uses readline for command history and tab completion.

Returns: User input string or undef on EOF

=head2 setup_tab_completion()

Setup tab completion for commands and file paths.

=head2 pause($message)

Pause and wait for user to press Enter.

Optional message to display before pausing.

=cut

# Methods will be extracted from Chat.pm during refactoring

1;
