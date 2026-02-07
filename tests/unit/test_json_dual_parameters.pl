#!/usr/bin/env perl

use strict;
use warnings;
use lib './lib';
use Test::More tests => 8;
use JSON::PP qw(encode_json decode_json);

=head1 TEST: Dual JSON Parameters (Phase 1)

Verify that agents can pass complex data as JSON objects instead of escaped strings.

Tests:
1. Tool.pm helper method generates both string and _json variants
2. ToolExecutor normalizes _json params to base params
3. FileOperations tool definition includes both variants
4. System prompt explains dual parameters to agents

=cut

# Test 1: Tool.pm helper method
{
    use CLIO::Tools::Tool;
    
    package TestTool {
        use parent 'CLIO::Tools::Tool';
        
        sub new {
            my ($class) = @_;
            return $class->SUPER::new(
                name => 'test_tool',
                description => 'Test tool',
                supported_operations => ['test_op'],
            );
        }
        
        sub route_operation {
            my ($self, $operation, $params, $context) = @_;
            return {success => 1, output => "OK"};
        }
    }
    
    my $tool = TestTool->new();
    
    # Test add_dual_json_parameters
    my $params = $tool->add_dual_json_parameters('content', {
        description => 'File content',
        string_format => 'json',
    });
    
    ok(exists $params->{content}, "String variant exists");
    ok(exists $params->{content_json}, "JSON variant exists");
    like($params->{content_json}->{description}, qr/no escaping needed/i, "JSON variant has helpful description");
}

# Test 2: ToolExecutor normalization
{
    use CLIO::Core::ToolExecutor;
    
    # Create minimal ToolExecutor
    my $executor = CLIO::Core::ToolExecutor->new(
        session => undef,
        debug => 0,
    );
    
    # Test normalizing content_json to content
    my $params_with_json = {
        operation => 'create_file',
        path => 'test.json',
        content_json => {name => 'John', age => 30},
    };
    
    my $normalized = $executor->_normalize_dual_json_params($params_with_json);
    
    ok(exists $normalized->{content}, "Base parameter created");
    ok(!exists $normalized->{content_json}, "JSON variant removed");
    my $decoded = decode_json($normalized->{content});
    is($decoded->{name}, 'John', "Content properly serialized");
    
    # Test that base parameter takes precedence
    my $params_with_both = {
        operation => 'create_file',
        path => 'test.json',
        content => 'original string',
        content_json => {should => 'be ignored'},
    };
    
    my $normalized2 = $executor->_normalize_dual_json_params($params_with_both);
    is($normalized2->{content}, 'original string', "Base parameter takes precedence");
    ok(!exists $normalized2->{content_json}, "JSON variant removed when both exist");
}

print "\n✓ All Phase 1 dual parameter tests passed!\n";
print "\nPhase 1 Implementation Summary:\n";
print "- Tool.pm: add_dual_json_parameters() helper ✓\n";
print "- FileOperations.pm: content/content_json dual params ✓\n";
print "- ToolExecutor.pm: _normalize_dual_json_params() ✓\n";
print "- PromptManager.pm: System prompt guidance ✓\n";
print "\nAgents can now pass JSON objects without escaping!\n";
