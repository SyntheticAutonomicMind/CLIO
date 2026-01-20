if ($ENV{CLIO_DEBUG}) {
    print STDERR "[TRACE] CLIO::Memory::ShortTerm loaded\n";
}
package CLIO::Memory::ShortTerm;

use strict;
use warnings;
use JSON::PP;

sub new {
    my ($class, %args) = @_;
    my $self = {
        history => $args{history} // [],
        max_size => $args{max_size} // 20,
        debug => $args{debug} // 0,
    };
    bless $self, $class;
    return $self;
}

# Strip out conversation markup
sub strip_conversation_tags {
    my ($text) = @_;
    return $text unless defined $text;
    $text =~ s/\[conversation\](.*?)\[\/conversation\]/$1/gs;
    return $text;
}

sub add_message {
    my ($self, $role, $content) = @_;
    $content = strip_conversation_tags($content);
    push @{$self->{history}}, { role => $role, content => $content };
    $self->_prune();
}

sub get_context {
    my ($self) = @_;
    return $self->{history};
}

# Natural language context search for recall queries
sub search_context {
    my ($self, $query) = @_;
    return undef unless defined $query;
    
    if ($ENV{CLIO_DEBUG} || $self->{debug}) {
        print STDERR "[STM] search_context: query='$query'\n";
    }
    
    # Handle contextual "repeat it" - check if previous query was about a position
    if ($query =~ /\b(repeat\s+it|repeat\s+that)\b/i) {
        # Look for the most recent query that asked about a specific position
        my @user_messages = grep { $_->{role} eq 'user' } @{$self->{history}};
        for my $i (reverse 0 .. $#{user_messages}) {
            my $msg = $user_messages[$i];
            if ($msg->{content} =~ /\b(first|second|third|fourth|1st|2nd|3rd|4th)\s+thing/i ||
                $msg->{content} =~ /what\s+(did|was)\s+(?:the\s+)?(first|second|third|fourth|1st|2nd|3rd|4th|last|final)\s+(?:thing\s+)?(?:that\s+)?I\s+(?:said|say)/i) {
                # Found a positional query, extract the position and apply it
                return $self->search_context($msg->{content});
            }
        }
        # If no previous positional query found, default to last message
        return $self->_get_user_message_by_position(-1);
    }
    
    # Handle keyword-based searches (what did I say about X)
    if ($query =~ /what\s+(?:did|was)\s+.*I\s+(?:said|say)\s+about\s+(.+)/i) {
        my $keyword = lc($1);
        $keyword =~ s/\?.*$//;  # Remove trailing question marks
        $keyword =~ s/^\s+|\s+$//g;  # Trim whitespace
        
        if ($ENV{CLIO_DEBUG} || $self->{debug}) {
            print STDERR "[STM] Searching for keyword: '$keyword'\n";
        }
        
        my @user_messages = grep { $_->{role} eq 'user' } @{$self->{history}};
        for my $msg (@user_messages) {
            if (lc($msg->{content}) =~ /\Q$keyword\E/) {
                if ($ENV{CLIO_DEBUG} || $self->{debug}) {
                    print STDERR "[STM] Found matching message: $msg->{content}\n";
                }
                return $msg;
            }
        }
        return undef;
    }
    
    # Handle positional references (first, second, last, etc.)
    if ($query =~ /\b(first|1st)\s+thing/i) {
        return $self->_get_user_message_by_position(1);
    }
    elsif ($query =~ /\b(second|2nd)\s+thing/i) {
        return $self->_get_user_message_by_position(2);
    }
    elsif ($query =~ /\b(third|3rd)\s+thing/i) {
        return $self->_get_user_message_by_position(3);
    }
    elsif ($query =~ /\b(fourth|4th)\s+thing/i) {
        return $self->_get_user_message_by_position(4);
    }
    elsif ($query =~ /\b(last|final)\s+thing/i) {
        return $self->_get_user_message_by_position(-1);
    }
    elsif ($query =~ /\bprevious\s+thing/i) {
        return $self->_get_user_message_by_position(-1);
    }
    
    # Handle "what did I say" patterns with positions
    if ($query =~ /what\s+(did|was)\s+(?:the\s+)?(.*?)\s+(?:thing\s+)?(?:that\s+)?I\s+(?:said|say)/i) {
        my $position_desc = $2;
        if ($position_desc =~ /first|1st/i) {
            return $self->_get_user_message_by_position(1);
        }
        elsif ($position_desc =~ /second|2nd/i) {
            return $self->_get_user_message_by_position(2);
        }
        elsif ($position_desc =~ /third|3rd/i) {
            return $self->_get_user_message_by_position(3);
        }
        elsif ($position_desc =~ /fourth|4th/i) {
            return $self->_get_user_message_by_position(4);
        }
        elsif ($position_desc =~ /last|final/i) {
            return $self->_get_user_message_by_position(-1);
        }
    }
    
    # Handle "repeat" patterns
    if ($query =~ /repeat\s+(?:the\s+)?(.*?)(?:\s+thing)?/i) {
        my $what = $1;
        if ($what =~ /first|1st/i) {
            return $self->_get_user_message_by_position(1);
        }
        elsif ($what =~ /second|2nd/i) {
            return $self->_get_user_message_by_position(2);
        }
        elsif ($what =~ /third|3rd/i) {
            return $self->_get_user_message_by_position(3);
        }
        elsif ($what =~ /fourth|4th/i) {
            return $self->_get_user_message_by_position(4);
        }
        elsif ($what =~ /last|final|that/i) {
            return $self->_get_user_message_by_position(-1);
        }
    }
    
    # Default fallback - return last user message for simple "repeat" requests
    if ($query =~ /\b(repeat|what.*said)\b/i) {
        return $self->_get_user_message_by_position(-1);
    }
    
    return undef;
}

# Get user message by position (1-indexed for positive, -1 for last)
sub _get_user_message_by_position {
    my ($self, $position) = @_;
    
    # Get all user messages
    my @user_messages = grep { $_->{role} eq 'user' } @{$self->{history}};
    
    if ($ENV{CLIO_DEBUG} || $self->{debug}) {
        print STDERR "[STM] _get_user_message_by_position: position=$position, total_user_messages=" . scalar(@user_messages) . "\n";
    }
    
    return undef unless @user_messages;
    
    if ($position > 0) {
        # Positive index (1-based)
        return $user_messages[$position - 1] if $position <= @user_messages;
    } else {
        # Negative index (-1 for last)
        return $user_messages[$position];
    }
    
    return undef;
}

sub _prune {
    my ($self) = @_;
    my $max = $self->{max_size};
    if (@{$self->{history}} > $max) {
        splice @{$self->{history}}, 0, @{$self->{history}} - $max;
    }
}

sub save {
    my ($self, $file) = @_;
    open my $fh, '>', $file or die "Cannot save STM: $!";
    print $fh encode_json($self->{history});
    close $fh;
}

sub load {
    my ($class, $file, %args) = @_;
    return unless -e $file;
    open my $fh, '<', $file or return;
    local $/; my $json = <$fh>; close $fh;
    my $history = eval { decode_json($json) };
    return $class->new(history => $history, %args);
}

1;
