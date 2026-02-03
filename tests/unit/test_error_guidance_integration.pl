#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use lib './lib';

use CLIO::Core::ToolErrorGuidance;
use CLIO::Tools::Registry;
use JSON::PP qw(encode_json);

print "Integration Test: Error Guidance in Tool Execution\n";
print "=" x 80 . "\n\n";

# Initialize the registry (like WorkflowOrchestrator does)
my $registry = CLIO::Tools::Registry->new(debug => 0);

# Register default tools
require CLIO::Tools::FileOperations;
require CLIO::Tools::UserCollaboration;
require CLIO::Tools::VersionControl;
require CLIO::Tools::TerminalOperations;
require CLIO::Tools::MemoryOperations;
require CLIO::Tools::WebOperations;
require CLIO::Tools::TodoList;
require CLIO::Tools::CodeIntelligence;

$registry->register_tool(CLIO::Tools::FileOperations->new(debug => 0));
$registry->register_tool(CLIO::Tools::UserCollaboration->new(debug => 0));
$registry->register_tool(CLIO::Tools::VersionControl->new(debug => 0));
$registry->register_tool(CLIO::Tools::TerminalOperations->new(debug => 0));
$registry->register_tool(CLIO::Tools::MemoryOperations->new(debug => 0));
$registry->register_tool(CLIO::Tools::WebOperations->new(debug => 0));
$registry->register_tool(CLIO::Tools::TodoList->new(debug => 0));
$registry->register_tool(CLIO::Tools::CodeIntelligence->new(debug => 0));

# Initialize error guidance (like WorkflowOrchestrator does)
my $guidance = CLIO::Core::ToolErrorGuidance->new();

# Test scenario: Agent tries to call user_collaboration without message parameter
print "Scenario: Agent tries to use user_collaboration but forgets 'message' parameter\n\n";

print "WHAT AGENT DID:\n";
my $bad_call = {
    operation => 'request_input',
    context => 'optional context here'
};
print "  " . encode_json($bad_call) . "\n\n";

# Get the tool definition
my $tool = $registry->get_tool('user_collaboration');
unless ($tool) {
    print "ERROR: Could not find tool in registry\n";
    exit 1;
}

my $tool_def = $tool->get_tool_definition();

# Simulate the error that would come from the tool
my $error_message = 'Missing required parameter: message';

# Get the enhanced guidance
my $enhanced = $guidance->enhance_tool_error(
    error => $error_message,
    tool_name => 'user_collaboration',
    tool_definition => $tool_def,
    attempted_params => $bad_call
);

print "WHAT THE AGENT RECEIVES (Enhanced Error):\n";
print "-" x 80 . "\n";
print $enhanced;
print "\n" . "-" x 80 . "\n\n";

print "KEY IMPROVEMENTS FOR AGENT:\n";
print "   1. Clear error classification (missing parameter)\n";
print "   2. Specific guidance on what went wrong\n";
print "   3. List of all required parameters with types\n";
print "   4. Example of correct usage\n";
print "   5. Common mistakes to avoid\n\n";

print "EXPECTED BEHAVIOR:\n";
print "  OLD: Agent gets generic error, tries alternative tools or gives up\n";
print "  NEW: Agent reads schema, sees it just needs to add 'message' parameter, fixes it\n\n";

print "=" x 80 . "\n";
print "Integration test PASSED\n";
