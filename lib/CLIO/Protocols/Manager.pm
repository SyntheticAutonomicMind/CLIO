package CLIO::Protocols::Manager;

use strict;
use warnings;
use utf8;

=head1 NAME

CLIO::Protocols::Manager - Protocol handler registry and dispatcher

=head1 SYNOPSIS

  use CLIO::Protocols::Manager;
  
  # Register a protocol handler
  CLIO::Protocols::Manager->register(
      name => 'ARCHITECT',
      handler => 'CLIO::Protocols::Architect'
  );
  
  # Get registered handler
  my $handler_class = CLIO::Protocols::Manager->get_handler('ARCHITECT');
  
  # Handle protocol request
  my $result = CLIO::Protocols::Manager->handle(
      '[ARCHITECT:uuid=abc123:data=...]',
      $session
  );

=head1 DESCRIPTION

Manager is the protocol registry and dispatcher for CLIO. It maintains
a registry of available protocol handlers and routes protocol requests
to the appropriate handler class.

Responsibilities:
- Register protocol handlers by name
- Route protocol syntax to handler classes
- Load handler modules on demand
- Handle protocol errors gracefully

Protocol syntax: [PROTOCOL_NAME:param1=value1:param2=value2:...]

Supported protocols: ARCHITECT, EDITOR, VALIDATE, REPOMAP, TREESIT,
RECALL, MEMORY, YARN, MODEL, etc.

=head1 METHODS

=head2 register(name => $protocol_name, handler => $handler_class)

Register a protocol handler class.

Arguments:
- name: Protocol name (case-insensitive, stored uppercase)
- handler: Fully qualified handler class name

Example:
  CLIO::Protocols::Manager->register(
      name => 'EDITOR',
      handler => 'CLIO::Protocols::Editor'
  );

=head2 get_handler($protocol_name)

Get registered handler class for a protocol.

Returns: Handler class name or undef if not registered

=head2 handle($protocol_input, $session)

Parse protocol syntax and dispatch to appropriate handler.

Arguments:
- protocol_input: Protocol syntax string [PROTOCOL:...]
- session: Session object (optional, required for some protocols)

Returns: HashRef with handler result

=cut


my %handlers;

sub register {
    my ($class, %args) = @_;
    my $name = uc($args{name});
    $handlers{$name} = $args{handler};
}

sub get_handler {
    my ($class, $name) = @_;
    $name = uc($name);
    return $handlers{$name};
}

sub handle {
    my ($class, $input, $session) = @_;
    if ($input =~ /^\[(\w+):/) {
        my $proto = $1;
        my $handler_class = $class->get_handler($proto);
        if ($handler_class) {
            eval "require $handler_class";
            if ($@) {
                warn "[PROTO][ERROR] Failed to load handler $handler_class: $@\n";
                return { success => 0, error => "Handler load failed: $@" };
            }
            
            my $handler = $handler_class->new();
            
            # Always pass session to handlers that might need it
            if ($proto =~ /^(MEMORY|YARN|GIT|RECALL)$/) {
                return $handler->handle($input, $session);
            } else {
                return $handler->handle($input);
            }
        } else {
            warn "[PROTO][ERROR] No handler for protocol $proto\n";
            return { success => 0, error => "No handler for protocol $proto" };
        }
    } else {
        return { success => 0, error => "Invalid protocol format" };
    }
}

1;
