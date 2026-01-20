package CLIO::Protocols::Manager;

use strict;
use warnings;

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
