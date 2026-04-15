#!/usr/bin/env perl
# test_interact_rename.pl - Verify user_collaboration -> interact rename is complete

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Find;
use Test::More tests => 6;

my $lib_dir = "$RealBin/../../lib";

# Test 1: Interact.pm can be loaded
use_ok('CLIO::Tools::Interact');

# Test 2: Tool instantiation
my $tool = CLIO::Tools::Interact->new(debug => 0);
ok(defined $tool, 'CLIO::Tools::Interact->new() returns an object');

# Test 3: Tool name is 'interact'
is($tool->{name}, 'interact', 'Tool name is "interact"');

# Test 4: Supported operations include request_input
my $ops = $tool->{supported_operations};
ok(
    (ref($ops) eq 'ARRAY' && grep { $_ eq 'request_input' } @$ops),
    'supported_operations includes request_input'
);

# Test 5: Old file does NOT exist
ok(! -e "$lib_dir/CLIO/Tools/UserCollaboration.pm", 'Old UserCollaboration.pm does not exist');

# Test 6: No remaining 'user_collaboration' string references in lib/*.pm
# Exceptions: Registry.pm backward-compat alias, PromptBuilder.pm migration note
my @violations;
find(sub {
    return unless /\.pm$/;
    return if $File::Find::name =~ /\.git/;
    return if $File::Find::name =~ /UserCollaboration\.pm$/;
    
    open my $fh, '<', $_ or return;
    my $line_num = 0;
    while (my $line = <$fh>) {
        $line_num++;
        if ($line =~ /user_collaboration|UserCollaboration/) {
            # Allow backward-compat alias in Registry
            next if $File::Find::name =~ /Registry\.pm$/ && $line =~ /=> \{ tool => 'interact'/;
            # Allow migration note in PromptBuilder
            next if $File::Find::name =~ /PromptBuilder\.pm$/ && $line =~ /replaces the former/;
            push @violations, "$File::Find::name:$line_num: $line";
        }
    }
    close $fh;
}, $lib_dir);

is(scalar @violations, 0, 'No remaining user_collaboration/UserCollaboration references in lib/')
    or diag("Found violations:\n" . join("", @violations));

done_testing();
