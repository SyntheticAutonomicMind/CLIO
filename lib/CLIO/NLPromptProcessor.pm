package CLIO::NLPromptProcessor;
use strict;
use warnings;
use CLIO::Utils;

# Inject debug_log into this namespace
*debug_log = \&CLIO::Utils::debug_log;

# Import reference implementation
BEGIN {
    my $ref_file = '/Users/andrew/repositories/fewtarius/clio/reference/clio/modules/CA/NLPromptProcessor.pm';
    if (-e $ref_file) {
        do $ref_file or die $@;
    } else {
        die "Reference NLPromptProcessor not found: $ref_file";
    }
}

1;
