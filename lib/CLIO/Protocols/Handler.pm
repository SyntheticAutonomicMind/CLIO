package CLIO::Protocols::Handler;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use Time::HiRes qw(time);

sub new {
    my ($class, %args) = @_;
    print STDERR "[PROTO][DEBUG] Handler::new called for class $class\n" if should_log('DEBUG') || $args{debug};
    my $self = { debug => $args{debug} // 0 };
    bless $self, $class;
    print STDERR "[PROTO][DEBUG] Handler::new returning object of class " . ref($self) . "\n" if should_log('DEBUG') || $args{debug};
    return $self;
}

sub validate_input {
    my ($self, $input) = @_;
    # Must be a hashref
    return 0 unless ref($input) eq 'HASH';
    # Must have protocol and uuid
    return 0 unless $input->{protocol} && $input->{uuid};
    # All fields must be base64 if required
    for my $key (keys %$input) {
        next if $key eq 'protocol' || $key eq 'uuid';
        if ($key =~ /^(data|query|file|operation)$/) {
            return 0 unless $input->{$key} =~ /^[A-Za-z0-9+\/=]+$/;
        }
    }
    # No partial or malformed blocks
    for my $field (qw(protocol uuid)) {
        return 0 unless defined $input->{$field} && $input->{$field} ne '';
    }
    return 1;
}

sub process_request {
    my ($self, $input) = @_;
    print STDERR "[PROTO][DEBUG] Base Handler::process_request called for class " . ref($self) . "\n" if should_log('DEBUG') || $self->{debug};
    return { success => 1, data => undef };
}

sub format_response {
    my ($self, $result) = @_;
    my $meta = { timestamp => time, duration => 0 };
    my %out = (%$result, meta => $meta);
    return \%out;
}

sub handle_errors {
    my ($self, $error) = @_;
    return { success => 0, error => $error };
}

1;
