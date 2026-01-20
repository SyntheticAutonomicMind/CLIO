if ($ENV{CLIO_DEBUG}) {
    print STDERR "[TRACE] CLIO::Memory::LongTerm loaded\n";
}
package CLIO::Memory::LongTerm;

use strict;
use warnings;
use JSON::PP;

sub new {
    my ($class, %args) = @_;
    my $self = { %args };
    $self->{store} //= {};
    $self->{debug} //= 0;
    bless $self, $class;
    return $self;
}

sub store_pattern {
    my ($self, $key, $value) = @_;
    warn "[LTM][DEBUG] store_pattern: key='$key', value='$value', self=$self\n" if $ENV{CLIO_DEBUG} || $self->{debug};
    $self->{store}{$key} = $value;
}

sub retrieve_pattern {
    my ($self, $key) = @_;
    my $val = $self->{store}{$key};
    warn "[LTM][DEBUG] retrieve_pattern: key='$key', val='" . (defined $val ? $val : '[undef]') . "', self=$self\n" if $ENV{CLIO_DEBUG} || $self->{debug};
    return $val;
}

sub list_patterns {
    my ($self) = @_;
    my @keys = keys %{$self->{store}};
    return [@keys];
}

sub save {
    my ($self, $file) = @_;
    open my $fh, '>', $file or die "Cannot save LTM: $!";
    print $fh encode_json($self->{store});
    close $fh;
}

sub load {
    my ($class, $file, %args) = @_;
    return unless -e $file;
    open my $fh, '<', $file or return;
    local $/; my $json = <$fh>; close $fh;
    my $store = eval { decode_json($json) };
    return $class->new(store => $store, %args);
}

1;
