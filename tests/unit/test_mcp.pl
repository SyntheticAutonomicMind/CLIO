#!/usr/bin/env perl
# Unit tests for CLIO::MCP::Client and CLIO::MCP::Manager

use strict;
use warnings;
use utf8;
use lib './lib';

my $tests_run = 0;
my $tests_passed = 0;

sub ok {
    my ($condition, $name) = @_;
    $tests_run++;
    if ($condition) {
        $tests_passed++;
        print "ok $tests_run - $name\n";
    } else {
        print "not ok $tests_run - $name\n";
    }
}

sub is {
    my ($got, $expected, $name) = @_;
    $tests_run++;
    if ((!defined $got && !defined $expected) || (defined $got && defined $expected && $got eq $expected)) {
        $tests_passed++;
        print "ok $tests_run - $name\n";
    } else {
        print "not ok $tests_run - $name [got: " . ($got // 'undef') . ", expected: " . ($expected // 'undef') . "]\n";
    }
}

print "# Testing CLIO::MCP modules\n";

# ===== Test MCP::Client module loads =====
eval { require CLIO::MCP::Client; };
ok(!$@, "CLIO::MCP::Client loads without error");

# ===== Test Client constructor =====
{
    my $client = CLIO::MCP::Client->new(
        name    => 'test-server',
        command => ['echo', 'hello'],
        timeout => 5,
    );
    ok(defined $client, "Client constructor returns object");
    is($client->name(), 'test-server', "Client name accessor works");
    ok(!$client->is_connected(), "New client is not connected");
    is(ref($client->list_tools()), 'ARRAY', "list_tools returns arrayref");
    is(scalar @{$client->list_tools()}, 0, "list_tools returns empty array for unconnected client");
}

# ===== Test Client with empty command =====
{
    my $client = CLIO::MCP::Client->new(
        name    => 'empty',
        command => [],
    );
    my $result = $client->connect();
    ok(!$result, "Client connect fails with empty command");
}

# ===== Test Client call_tool when not connected =====
{
    my $client = CLIO::MCP::Client->new(
        name    => 'offline',
        command => ['true'],
    );
    my $result = $client->call_tool('some_tool', { arg => 'value' });
    ok(defined $result, "call_tool returns result when not connected");
    ok($result->{error}, "call_tool returns error when not connected");
}

# ===== Test MCP::Manager module loads =====
eval { require CLIO::MCP::Manager; };
ok(!$@, "CLIO::MCP::Manager loads without error");

# ===== Test Manager constructor =====
{
    my $mgr = CLIO::MCP::Manager->new(
        config => { mcp => {} },
        debug  => 0,
    );
    ok(defined $mgr, "Manager constructor returns object");
    ok(defined CLIO::MCP::Manager->instance(), "Manager singleton is set");
}

# ===== Test Manager is_available =====
{
    my $mgr = CLIO::MCP::Manager->new(
        config => {},
        debug  => 0,
    );
    # This will return 1 or 0 depending on the system
    my $available = $mgr->is_available();
    ok(defined $available, "is_available returns defined value");
    ok($available == 0 || $available == 1, "is_available returns 0 or 1");
}

# ===== Test Manager _which helper =====
{
    # Test finding 'perl' which should always exist
    my $perl_path = CLIO::MCP::Manager::_which('perl');
    ok(defined $perl_path, "_which finds 'perl' in PATH");
    ok(-x $perl_path, "_which returns executable path") if $perl_path;
    
    # Test not finding nonsense
    my $fake = CLIO::MCP::Manager::_which('this_command_definitely_does_not_exist_xyz');
    ok(!defined $fake, "_which returns undef for nonexistent command");
}

# ===== Test Manager start with no config =====
{
    my $mgr = CLIO::MCP::Manager->new(
        config => {},
        debug  => 0,
    );
    my $count = $mgr->start();
    is($count, 0, "start() returns 0 with no MCP config");
}

# ===== Test Manager start with empty MCP config =====
{
    my $mgr = CLIO::MCP::Manager->new(
        config => { mcp => {} },
        debug  => 0,
    );
    my $count = $mgr->start();
    is($count, 0, "start() returns 0 with empty MCP config");
}

# ===== Test Manager all_tools with no clients =====
{
    my $mgr = CLIO::MCP::Manager->new(
        config => {},
        debug  => 0,
    );
    my $tools = $mgr->all_tools();
    ok(ref($tools) eq 'ARRAY', "all_tools returns arrayref");
    is(scalar @$tools, 0, "all_tools returns empty array with no clients");
}

# ===== Test Manager call_tool with no clients =====
{
    my $mgr = CLIO::MCP::Manager->new(
        config => {},
        debug  => 0,
    );
    my $result = $mgr->call_tool('filesystem_read_file', { path => '/tmp/test' });
    ok($result->{error}, "call_tool returns error with no matching server");
}

# ===== Test Manager server_status =====
{
    my $mgr = CLIO::MCP::Manager->new(
        config => {},
        debug  => 0,
    );
    my $status = $mgr->server_status();
    ok(ref($status) eq 'HASH', "server_status returns hashref");
}

# ===== Test Manager tool name qualification =====
{
    my $mgr = CLIO::MCP::Manager->new(config => {}, debug => 0);
    my $name = $mgr->_qualify_tool_name('my-server', 'read_file');
    is($name, 'my-server_read_file', "qualify_tool_name namespaces correctly");
    
    # Test with special characters
    my $name2 = $mgr->_qualify_tool_name('server.with.dots', 'tool name');
    is($name2, 'server_with_dots_tool_name', "qualify_tool_name sanitizes special chars");
}

# ===== Test Manager add/remove server (will fail to connect but tests flow) =====
{
    my $mgr = CLIO::MCP::Manager->new(config => {}, debug => 0);
    
    # Remove should always succeed even for non-existent server
    my $rm = $mgr->remove_server('nonexistent');
    ok($rm->{success}, "remove_server succeeds for nonexistent server");
    
    # Skip add_server test - requires a real MCP server and would hang on timeout
    ok(1, "SKIP: add_server (requires real MCP server)");
}

# ===== Test Manager disabled server config =====
{
    my $mgr = CLIO::MCP::Manager->new(
        config => {
            mcp => {
                disabled_server => {
                    command => ['node', 'some-server.js'],
                    enabled => 0,
                },
            },
        },
        debug => 0,
    );
    my $count = $mgr->start();
    is($count, 0, "Disabled servers are not connected");
    my $status = $mgr->server_status();
    is($status->{disabled_server}{status}, 'disabled', "Disabled server shows disabled status");
}

# ===== Test MCPBridge module loads =====
eval { require CLIO::Tools::MCPBridge; };
ok(!$@, "CLIO::Tools::MCPBridge loads without error");

# ===== Test MCPBridge is_mcp_tool =====
{
    ok(CLIO::Tools::MCPBridge->is_mcp_tool('mcp_filesystem_read_file'), "is_mcp_tool detects MCP tool name");
    ok(!CLIO::Tools::MCPBridge->is_mcp_tool('file_operations'), "is_mcp_tool rejects non-MCP tool name");
    ok(!CLIO::Tools::MCPBridge->is_mcp_tool(undef), "is_mcp_tool handles undef");
    ok(!CLIO::Tools::MCPBridge->is_mcp_tool(''), "is_mcp_tool handles empty string");
}

# ===== Test MCPBridge generate_tool_definitions with no manager =====
{
    my $defs = CLIO::Tools::MCPBridge->generate_tool_definitions(undef);
    ok(ref($defs) eq 'ARRAY', "generate_tool_definitions returns arrayref with undef manager");
    is(scalar @$defs, 0, "generate_tool_definitions returns empty array with undef manager");
}

# ===== Test MCPBridge execute_tool with no manager =====
{
    my $result = CLIO::Tools::MCPBridge->execute_tool(undef, 'mcp_test_tool', {});
    ok(!$result->{success}, "execute_tool fails with no manager");
    ok($result->{error}, "execute_tool returns error with no manager");
}

# Summary
print "\n# Test summary: $tests_passed/$tests_run passed\n";
exit($tests_passed == $tests_run ? 0 : 1);
