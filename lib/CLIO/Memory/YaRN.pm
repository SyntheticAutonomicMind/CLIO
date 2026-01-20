package CLIO::Memory::YaRN;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use JSON::PP;

if ($ENV{CLIO_DEBUG}) {
    print STDERR "[TRACE] CLIO::Memory::YaRN loaded\n";
}

sub new {
    my ($class, %args) = @_;
    my $self = {
        threads => $args{threads} // {},
        debug => $args{debug} // 0,
    };
    bless $self, $class;
    return $self;
}

sub create_thread {
    my ($self, $thread_id) = @_;
    print STDERR "[YaRN] create_thread: self=$self, thread_id=$thread_id\n" if $ENV{CLIO_DEBUG} || $self->{debug};
    $self->{threads}{$thread_id} = [];
    print STDERR "[YaRN] threads after create: " . join(',', keys %{$self->{threads}}) . "\n" if $ENV{CLIO_DEBUG} || $self->{debug};
}

sub add_to_thread {
    my ($self, $thread_id, $msg) = @_;
    print STDERR "[YaRN] add_to_thread: self=$self, thread_id=$thread_id, msg=$msg\n" if $ENV{CLIO_DEBUG} || $self->{debug};
    $self->{threads}{$thread_id} ||= [];
    # If $msg is a JSON string, decode it; otherwise, assume it's a hashref
    if (defined $msg && !ref $msg && $msg =~ /^\s*\{.*\}\s*$/) {
        eval { $msg = JSON::PP::decode_json($msg); };
    }
    push @{$self->{threads}{$thread_id}}, $msg;
    print STDERR "[YaRN] threads after add: " . join(',', keys %{$self->{threads}}) . "; thread content: " . join(',', map { ref $_ ? $_->{content} : $_ } @{$self->{threads}{$thread_id}}) . "\n" if $ENV{CLIO_DEBUG} || $self->{debug};
    use Data::Dumper;
    print STDERR "[YaRN][DEBUG] threads structure after add: " . Dumper($self->{threads}) . "\n" if $ENV{CLIO_DEBUG} || $self->{debug};
}

sub get_thread {
    my ($self, $thread_id) = @_;
    print STDERR "[YaRN] get_thread: self=$self, thread_id=$thread_id\n" if $ENV{CLIO_DEBUG} || $self->{debug};
    print STDERR "[YaRN] get_thread: $thread_id => " . join(',', @{$self->{threads}{$thread_id} // []}) . "\n" if $ENV{CLIO_DEBUG} || $self->{debug};
    my $thread = $self->{threads}{$thread_id};
    $thread = [] unless defined $thread;
    use Data::Dumper;
    print STDERR "[YaRN][DEBUG] get_thread returning: " . Dumper($thread) . "\n" if $ENV{CLIO_DEBUG} || $self->{debug};
    return $thread;
}

sub list_threads {
    my ($self) = @_;
    my @keys = sort keys %{$self->{threads}};
    print STDERR "[YaRN] list_threads: @keys, debug: $self->{debug}\n" if $ENV{CLIO_DEBUG} || $self->{debug};
    return \@keys;
}

sub summarize_thread {
    my ($self, $thread_id) = @_;
    my $thread = $self->get_thread($thread_id);
    return {
        thread_id => $thread_id,
        message_count => scalar(@$thread),
        latest_message => $thread->[-1],
    };
}

sub save {
    my ($self, $file) = @_;
    open my $fh, '>', $file or die "Cannot save YaRN: $!";
    print $fh encode_json($self->{threads});
    close $fh;
}

sub load {
    my ($class, $file, %args) = @_;
    return unless -e $file;
    open my $fh, '<', $file or return;
    local $/; my $json = <$fh>; close $fh;
    my $threads = eval { decode_json($json) };
    return $class->new(threads => $threads, %args);
}

1;
