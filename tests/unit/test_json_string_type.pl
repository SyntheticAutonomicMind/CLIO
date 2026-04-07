#!/usr/bin/env perl

use strict;
use warnings;
use lib './lib';
use Test::More tests => 7;
use JSON::PP qw(encode_json decode_json);

=head1 TEST: OneOf Type Parameters (ToolExecutor normalization)

Verify that _normalize_oneof_params correctly converts object values
to JSON strings when a tool schema declares oneOf [{type: string}, {type: object}].

Tests:
1. Object param exists after normalization
2. Object value converted to JSON string
3. Serialized JSON preserves structure
4. Nested data preserved
5. JSON string passthrough
6. Plain text passthrough
7. Params without oneOf schema are untouched

=cut

# Create a mock tool with oneOf schema for testing
{
    package MockOneOfTool;
    use parent 'CLIO::Tools::Tool';

    sub new {
        my ($class, %opts) = @_;
        my $self = $class->SUPER::new(
            name => 'mock_oneof_tool',
            description => 'Mock tool with oneOf parameters',
            supported_operations => ['test_op'],
            %opts,
        );
        return $self;
    }

    sub get_tool_definition {
        return {
            name => 'mock_oneof_tool',
            description => 'Mock tool with oneOf parameters',
            parameters => {
                type => 'object',
                required => ['operation'],
                properties => {
                    operation => { type => 'string' },
                    data => {
                        oneOf => [
                            { type => 'string' },
                            { type => 'object' },
                        ],
                        description => 'Accepts string or object',
                    },
                },
            },
        };
    }

    sub route_operation { return { success => 1 } }
}

use CLIO::Core::ToolExecutor;
use CLIO::Tools::Registry;

# Create tool registry with mock tool
my $registry = CLIO::Tools::Registry->new(debug => 0);
$registry->register_tool(MockOneOfTool->new(debug => 0));

# Create ToolExecutor
my $executor = CLIO::Core::ToolExecutor->new(
    session => undef,
    tool_registry => $registry,
    debug => 0,
);

# Test 1-4: oneOf param with object value -> serialized to JSON string
{
    my $params = {
        operation => 'test_op',
        data => {key => 'value', nested => {num => 123}},
    };

    my $normalized = $executor->_normalize_oneof_params($params, 'mock_oneof_tool');

    ok(exists $normalized->{data}, "data parameter exists after normalization");
    ok(!ref($normalized->{data}), "object converted to string");

    my $decoded = decode_json($normalized->{data});
    is($decoded->{key}, 'value', "JSON object correctly serialized");
    is($decoded->{nested}{num}, 123, "Nested data preserved");
}

# Test 5: JSON string passthrough
{
    my $params = {
        operation => 'test_op',
        data => '{"already": "json"}',
    };

    my $normalized = $executor->_normalize_oneof_params($params, 'mock_oneof_tool');
    is($normalized->{data}, '{"already": "json"}', "JSON string passes through");
}

# Test 6: Plain text passthrough
{
    my $params = {
        operation => 'test_op',
        data => 'Just plain text',
    };

    my $normalized = $executor->_normalize_oneof_params($params, 'mock_oneof_tool');
    is($normalized->{data}, 'Just plain text', "Plain text passes through");
}

# Test 7: Params without oneOf schema are untouched
{
    use CLIO::Tools::FileOperations;
    $registry->register_tool(CLIO::Tools::FileOperations->new(debug => 0));

    my $params = {
        operation => 'read_file',
        path => '/tmp/test.txt',
    };

    my $normalized = $executor->_normalize_oneof_params($params, 'file_operations');
    is($normalized->{path}, '/tmp/test.txt', "Non-oneOf params pass through unchanged");
}
