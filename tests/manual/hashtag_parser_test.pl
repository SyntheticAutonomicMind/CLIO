#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';

use CLIO::Core::HashtagParser;
use Data::Dumper;

print "Testing HashtagParser\n";
print "=" x 50 . "\n\n";

# Create parser
my $parser = CLIO::Core::HashtagParser->new(
    debug => 1,
    session => {
        working_directory => '.',
        selection => 'This is selected text',
        terminal_last_command => 'ls -la',
        terminal_last_output => "total 100\ndrwxr-xr-x  1 user  staff  512 Jan 17 10:00 ."
    }
);

# Test 1: Parse various hashtags
print "Test 1: Parsing hashtags\n";
print "-" x 50 . "\n";

my $input = "Explain #file:lib/CLIO/Core/HashtagParser.pm and also #folder:lib/CLIO/UI with #selection";
print "Input: $input\n\n";

my $tags = $parser->parse($input);
print "Found " . scalar(@$tags) . " hashtags:\n";
for my $tag (@$tags) {
    print "  - Type: $tag->{type}, Value: " . ($tag->{value} || 'none') . ", Raw: $tag->{raw}\n";
}
print "\n";

# Test 2: Resolve #file
print "Test 2: Resolving #file\n";
print "-" x 50 . "\n";

my $file_tag = [{
    type => 'file',
    value => 'lib/CLIO/Core/HashtagParser.pm',
    raw => '#file:lib/CLIO/Core/HashtagParser.pm'
}];

my $context = $parser->resolve($file_tag);
if (@$context) {
    my $item = $context->[0];
    print "File: $item->{path}\n";
    print "Size: $item->{size} bytes\n";
    print "Lines: $item->{line_count}\n";
    print "Content preview: " . substr($item->{content}, 0, 100) . "...\n";
}
print "\n";

# Test 3: Resolve #folder
print "Test 3: Resolving #folder\n";
print "-" x 50 . "\n";

my $folder_tag = [{
    type => 'folder',
    value => 'lib/CLIO/Core',
    raw => '#folder:lib/CLIO/Core'
}];

$context = $parser->resolve($folder_tag);
if (@$context) {
    my $item = $context->[0];
    print $item->{content};
}
print "\n";

# Test 4: Resolve #selection
print "Test 4: Resolving #selection\n";
print "-" x 50 . "\n";

my $selection_tag = [{
    type => 'selection',
    raw => '#selection'
}];

$context = $parser->resolve($selection_tag);
if (@$context) {
    my $item = $context->[0];
    print "Selection: $item->{content}\n";
}
print "\n";

# Test 5: Format context
print "Test 5: Formatting context for AI prompt\n";
print "-" x 50 . "\n";

my $all_tags = $parser->parse("Explain #file:clio with #selection");
my $all_context = $parser->resolve($all_tags);
my $formatted = $parser->format_context($all_context);

print substr($formatted, 0, 500) . "...\n\n";

print "All tests completed!\n";
