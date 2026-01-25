package CLIO::Core::CommandParser;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);

print STDERR "[TRACE] CLIO::Core::CommandParser loaded\n" if should_log('DEBUG');

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
        print STDERR "[CommandParser] parse_commands: input='$input'\n";
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
        print STDERR "[CommandParser] parsed commands: " . join(' | ', @commands) . "\n";
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
        print STDERR "[CommandParser] extract_recall_context (DEPRECATED): command='$command'\n";
    }
    
    # For backward compatibility, just return the last user message
    # The AI can handle recall queries better than pattern matching
    my $result = $memory->get_last_user_message();
    
    if (should_log('DEBUG')) {
        if ($result) {
            print STDERR "[CommandParser] Returning last user message for recall\n";
        } else {
            print STDERR "[CommandParser] No recall context found\n";
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
