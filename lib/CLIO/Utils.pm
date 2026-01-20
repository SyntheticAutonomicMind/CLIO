package CLIO::Utils;
use strict;
use warnings;

sub debug_log {
    my ($msg, $debug) = @_;
    print STDERR "$msg\n" if $debug;
}

sub init_colors {
    return {};
}

1;
