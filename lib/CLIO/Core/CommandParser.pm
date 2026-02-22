package CLIO::Core::CommandParser;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(should_log log_debug);

=head1 NAME

CLIO::Core::CommandParser - Parse and analyze user commands for CLIO

=head1 SYNOPSIS

  use CLIO::Core::CommandParser;
  
  my $parser = CLIO::Core::CommandParser->new(debug => 0);
  
  # Parse stacked commands separated by semicolons
  my $commands = $parser->parse_commands('read file.txt; list dir');
  # Returns: ['read file.txt', 'list dir']
  
  # Check if command is a recall query
  if ($parser->is_recall_query('what did I say last?')) {
      # Handle recall logic
  }

=head1 DESCRIPTION

CommandParser provides utility functions for parsing and analyzing user input
in CLIO. It handles:

- Stacked commands (semicolon-separated)
- Quoted strings with escape sequences
- Recall query detection (what did I say, repeat that, etc.)
- Command trimming and normalization

This module is used by the main Chat UI to preprocess user input before
passing it to the AI workflow orchestrator.

=head1 METHODS

=head2 new(%args)

Create a new CommandParser instance.

Arguments:
- debug: Enable debug logging (default: 0)

=head2 parse_commands($input)

Parse input string into array of individual commands separated by semicolons.
Respects quoted strings and escape sequences.

Returns: ArrayRef of command strings

=head2 is_recall_query($command)

Check if a command is asking to recall previous conversation context.
Detects patterns like "what did I say", "repeat that", "the last thing", etc.

Returns: Boolean

=head2 extract_recall_context($command, $memory)

DEPRECATED: Extract recall context from command using memory system.
Use Memory::ShortTerm methods directly instead.

Returns: Previous message content or undef

=cut

log_debug('CommandParser', "CLIO::Core::CommandParser loaded");

sub new {
    my ($class, %args) = @_;
    my $self = {
        debug => $args{debug} // 0,
    };
    bless $self, $class;
    return $self;
}

# Parse stacked commands separated by semicolons
# Handles quoted strings and escaped characters
sub parse_commands {
    my ($self, $input) = @_;
    return [] unless defined $input && length($input) > 0;
    
    my @commands = ();
    my $current_command = '';
    my $in_quotes = 0;
    my $quote_char = '';
    my $escaped = 0;
    
    if (should_log('DEBUG')) {
        log_debug('CommandParser', "parse_commands: input='$input'");
    }
    
    for my $i (0 .. length($input) - 1) {
        my $char = substr($input, $i, 1);
        
        if ($escaped) {
            $current_command .= $char;
            $escaped = 0;
            next;
        }
        
        if ($char eq '\\') {
            $escaped = 1;
            $current_command .= $char;
            next;
        }
        
        if (!$in_quotes && ($char eq '"' || $char eq "'")) {
            $in_quotes = 1;
            $quote_char = $char;
            $current_command .= $char;
            next;
        }
        
        if ($in_quotes && $char eq $quote_char) {
            $in_quotes = 0;
            $quote_char = '';
            $current_command .= $char;
            next;
        }
        
        if (!$in_quotes && $char eq ';') {
            # End of command
            my $trimmed = $self->_trim($current_command);
            push @commands, $trimmed if length($trimmed) > 0;
            $current_command = '';
            next;
        }
        
        $current_command .= $char;
    }
    
    # Add the last command if there's content
    my $trimmed = $self->_trim($current_command);
    push @commands, $trimmed if length($trimmed) > 0;
    
    if (should_log('DEBUG')) {
        log_debug('CommandParser', "parsed commands: " . join(' | ', @commands) . "");
    }
    
    return \@commands;
}

# Check if a command is a recall/memory query
sub is_recall_query {
    my ($self, $command) = @_;
    return 0 unless defined $command;
    
    # Pattern matching for recall queries
    return 1 if $command =~ /\b(repeat|what.*said|what.*thing|recall)\b/i;
    return 1 if $command =~ /\b(first|second|third|fourth|last|previous)\s+thing/i;
    return 1 if $command =~ /what\s+(did|was)\s+.*I\s+(said|say)/i;
    return 1 if $command =~ /\b(repeat\s+it|repeat\s+that)\b/i;
    
    return 0;
}

# Extract recall context from a command using memory system
# DEPRECATED: Use STM->get_last_user_message() or search_messages() directly instead
# This method is kept for backward compatibility only
sub extract_recall_context {
    my ($self, $command, $memory) = @_;
    return undef unless $memory && $memory->can('get_last_user_message');
    
    if (should_log('DEBUG')) {
        log_debug('CommandParser', "extract_recall_context (DEPRECATED): command='$command'");
    }
    
    # For backward compatibility, just return the last user message
    # The AI can handle recall queries better than pattern matching
    my $result = $memory->get_last_user_message();
    
    if (should_log('DEBUG')) {
        if ($result) {
            log_debug('CommandParser', "Returning last user message for recall");
        } else {
            log_debug('CommandParser', "No recall context found");
        }
    }
    
    return $result;
}

# Trim whitespace from string
sub _trim {
    my ($self, $str) = @_;
    return '' unless defined $str;
    $str =~ s/^\s+|\s+$//g;
    return $str;
}

1;
