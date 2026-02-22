package CLIO::Protocols::Handler;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(should_log log_debug);
use Time::HiRes qw(time);

=head1 NAME

CLIO::Protocols::Handler - Base class for CLIO protocol handlers

=head1 SYNOPSIS

  package CLIO::Protocols::MyProtocol;
  use base 'CLIO::Protocols::Handler';
  
  sub process_request {
      my ($self, $input) = @_;
      # Protocol-specific implementation
      return { success => 1, data => $result };
  }

=head1 DESCRIPTION

Handler is the abstract base class for all CLIO protocol implementations
(Architect, Editor, Validate, RepoMap, TreeSit, etc.). It provides common
functionality for:

- Input validation (base64 encoding, required fields)
- Request processing workflow
- Response formatting with metadata
- Error handling standardization

All protocol handlers inherit from this class and override process_request()
to implement their specific functionality.

=head1 METHODS

=head2 new(%args)

Create a new protocol handler instance.

Arguments:
- debug: Enable debug logging (default: 0)

=head2 validate_input($input)

Validate protocol input structure and encoding.

Required fields:
- protocol: Protocol name
- uuid: Request UUID
- data/query/file/operation: Base64-encoded parameters

Returns: Boolean (1 if valid, 0 if invalid)

=head2 process_request($input)

Process protocol request. Override this in subclasses.

Returns: HashRef with 'success' and 'data' or 'error' fields

=head2 format_response($result)

Format response with metadata (timestamp, duration).

Returns: HashRef with result + metadata

=head2 handle_errors($error)

Standardize error responses.

Returns: HashRef with success => 0 and error message

=cut


sub new {
    my ($class, %args) = @_;
    log_debug('ProtocolHandler', "Handler::new called for class $class");
    my $self = { debug => $args{debug} // 0 };
    bless $self, $class;
    log_debug('ProtocolHandler', "[PROTO][DEBUG] Handler::new returning object of class " . ref($self) . "");
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
    log_debug('ProtocolHandler', "[PROTO][DEBUG] Base Handler::process_request called for class " . ref($self) . "");
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
