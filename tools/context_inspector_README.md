#!/usr/bin/env perl
# Quick syntax/sanity check for the context_inspector tool
use strict;
use warnings;
use utf8;
binmode(STDOUT, ":encoding(UTF-8)");

print "Context Inspector tool: tools/context_inspector.pl\n";
print "Status: standalone script (no module load needed)\n";
print "\n";
print "Usage:\n";
print "  perl tools/context_inspector.pl <session.json> [--messages=START-END]\n";
print "\n";
print "Example:\n";
print "  perl tools/context_inspector.pl .clio/sessions/<sid>.json\n";
print "  perl tools/context_inspector.pl session.json --messages=0-50\n";
print "\n";
print "For now, here's a checklist of what to look at:\n";
print "  1. Total messages and token breakdown\n";
print "  2. Role distribution (system/user/assistant/tool)\n";
print "  3. user_context anchor position (should be at trailing position)\n";
print "  4. Tool errors in the conversation (look for repeats)\n";
print "  5. Empty content messages (model not generating content)\n";
print "  6. Last API payload size and content (resume correctness)\n";
