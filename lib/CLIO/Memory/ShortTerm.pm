=head1 NAME

CLIO::Memory::ShortTerm - Short-term conversation memory (sliding window)

=head1 DESCRIPTION

Maintains a sliding window of recent conversation history for context.
This is the working memory used during a session.

The full conversation is always available in session history.
ShortTerm provides access to recent context for quick lookups.

=head1 SYNOPSIS

    my $stm = CLIO::Memory::ShortTerm->new(max_size => 20);
    $stm->add_message('user', 'Hello');
    $stm->add_message('assistant', 'Hi there!');
    
    my $context = $stm->get_context();  # Returns array of recent messages

=cut

package CLIO::Memory::ShortTerm;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use Carp qw(croak);
use CLIO::Core::Logger qw(should_log log_debug);
use CLIO::Util::JSON qw(encode_json decode_json);

log_debug('ShortTerm', "CLIO::Memory::ShortTerm loaded");

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
    
    # DEFENSIVE: Handle malformed input where entire message hash was passed as role
    # This fixes corruption from old sessions where role was {role => "user", content => "text"}
    if (ref($role) eq 'HASH') {
        # Extract actual role and content from the hash
        $content = $role->{content} if defined $role->{content};
        $role = $role->{role} if defined $role->{role};
    }
    
    # Normalize role to string
    $role = 'unknown' unless defined $role && !ref($role);
    $content = '' unless defined $content;
    
    $content = strip_conversation_tags($content);
    push @{$self->{history}}, { role => $role, content => $content };
    $self->_prune();
}

sub get_context {
    my ($self) = @_;
    return $self->{history};
}

=head2 get_recent_user_messages

Get N most recent user messages

    my $recent = $stm->get_recent_user_messages(5);  # Last 5 user messages

=cut

sub get_recent_user_messages {
    my ($self, $count) = @_;
    $count //= 10;
    
    my @user_messages = grep { $_->{role} eq 'user' } @{$self->{history}};
    
    # Return last N messages
    my $start = @user_messages > $count ? @user_messages - $count : 0;
    return [@user_messages[$start .. $#user_messages]];
}

=head2 search_messages

Simple text search across message history

    my $matches = $stm->search_messages('keyword');

=cut

sub search_messages {
    my ($self, $query) = @_;
    return [] unless defined $query && length($query);
    
    my @matches;
    for my $msg (@{$self->{history}}) {
        next unless $msg->{content};
        if ($msg->{content} =~ /\Q$query\E/i) {
            push @matches, $msg;
        }
    }
    
    return \@matches;
}

=head2 get_last_user_message

Get the most recent user message

    my $last = $stm->get_last_user_message();

=cut

sub get_last_user_message {
    my ($self) = @_;
    
    my @user_messages = grep { $_->{role} eq 'user' } @{$self->{history}};
    return undef unless @user_messages;
    
    return $user_messages[-1];
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
    open my $fh, '>', $file or croak "Cannot save STM: $!";
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

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same terms as Perl itself.

=cut

1;
