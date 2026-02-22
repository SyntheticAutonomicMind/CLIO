#!/usr/bin/env perl
# Unit tests for CLIO MCP modules (Client, Manager, Transports, Bridge)

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

# ===== Module loading =====
eval { require CLIO::MCP::Client; };
ok(!$@, "CLIO::MCP::Client loads");

eval { require CLIO::MCP::Manager; };
ok(!$@, "CLIO::MCP::Manager loads");

eval { require CLIO::MCP::Transport::Stdio; };
ok(!$@, "CLIO::MCP::Transport::Stdio loads");

eval { require CLIO::MCP::Transport::HTTP; };
ok(!$@, "CLIO::MCP::Transport::HTTP loads");

eval { require CLIO::Tools::MCPBridge; };
ok(!$@, "CLIO::Tools::MCPBridge loads");

# ===== Transport::Stdio =====
{
    my $t = CLIO::MCP::Transport::Stdio->new(name => 'test', command => ['echo', 'hi'], timeout => 2);
    ok(defined $t, "Stdio transport constructor");
    ok(!$t->is_connected(), "Stdio not connected before connect()");
}

{
    my $t = CLIO::MCP::Transport::Stdio->new(name => 'empty', command => []);
    ok(!$t->connect(), "Stdio connect fails with empty command");
}

# ===== Transport::HTTP =====
{
    my $t = CLIO::MCP::Transport::HTTP->new(url => 'https://example.com/mcp', timeout => 5);
    ok(defined $t, "HTTP transport constructor");
    ok($t->connect(), "HTTP connect (optimistic)");
    ok($t->is_connected(), "HTTP reports connected");
    ok(!defined $t->session_id(), "HTTP no session before init");
    $t->disconnect();
    ok(!$t->is_connected(), "HTTP disconnected");
}

{
    eval { CLIO::MCP::Transport::HTTP->new() };
    ok($@, "HTTP dies without url");
}

# ===== Client =====
{
    my $c = CLIO::MCP::Client->new(name => 'test', command => ['echo', 'hi']);
    ok(defined $c, "Client legacy command mode");
    is($c->name(), 'test', "Client name");
    ok(!$c->is_connected(), "Client not connected");
    is(ref($c->list_tools()), 'ARRAY', "list_tools arrayref");
    is(scalar @{$c->list_tools()}, 0, "list_tools empty");
}

{
    my $transport = CLIO::MCP::Transport::Stdio->new(name => 'x', command => []);
    my $c = CLIO::MCP::Client->new(name => 'explicit', transport => $transport);
    ok(defined $c, "Client with explicit transport");
    is($c->name(), 'explicit', "Client explicit name");
}

{
    my $c = CLIO::MCP::Client->new(name => 'empty');
    ok(!$c->connect(), "Client connect fails no transport");
}

{
    my $c = CLIO::MCP::Client->new(name => 'offline', command => ['true']);
    my $r = $c->call_tool('tool', { arg => 1 });
    ok($r->{error}, "call_tool error when disconnected");
}

# ===== Manager =====
{
    my $m = CLIO::MCP::Manager->new(config => { mcp => {} }, debug => 0);
    ok(defined $m, "Manager constructor");
    ok(defined CLIO::MCP::Manager->instance(), "Manager singleton");
}

{
    my $m = CLIO::MCP::Manager->new(config => {}, debug => 0);
    my $a = $m->is_available();
    ok(defined $a, "is_available defined");
    ok($a == 0 || $a == 1, "is_available boolean");
}

{
    my $p = CLIO::MCP::Manager::_which('perl');
    ok(defined $p, "_which finds perl");
    ok(-x $p, "_which executable") if $p;
    ok(!defined CLIO::MCP::Manager::_which('fake_cmd_xyz'), "_which undef missing");
}

{
    my $m = CLIO::MCP::Manager->new(config => {}, debug => 0);
    is($m->start(), 0, "start() 0 no config");
}

{
    my $m = CLIO::MCP::Manager->new(config => { mcp => {} }, debug => 0);
    is($m->start(), 0, "start() 0 empty config");
}

{
    my $m = CLIO::MCP::Manager->new(config => {}, debug => 0);
    is(ref($m->all_tools()), 'ARRAY', "all_tools arrayref");
    is(scalar @{$m->all_tools()}, 0, "all_tools empty");
}

{
    my $m = CLIO::MCP::Manager->new(config => {}, debug => 0);
    ok($m->call_tool('x_y', {})->{error}, "call_tool error no servers");
}

{
    my $m = CLIO::MCP::Manager->new(config => {}, debug => 0);
    ok(ref($m->server_status()) eq 'HASH', "server_status hashref");
}

{
    my $m = CLIO::MCP::Manager->new(config => {}, debug => 0);
    is($m->_qualify_tool_name('srv', 'tool'), 'srv_tool', "qualify basic");
    is($m->_qualify_tool_name('a.b', 'c d'), 'a_b_c_d', "qualify sanitizes");
}

{
    my $m = CLIO::MCP::Manager->new(config => {}, debug => 0);
    ok($m->remove_server('nope')->{success}, "remove nonexistent ok");
}

{
    my $m = CLIO::MCP::Manager->new(
        config => { mcp => { off => { command => ['node'], enabled => 0 } } },
        debug => 0,
    );
    is($m->start(), 0, "Disabled not connected");
    is($m->server_status()->{off}{status}, 'disabled', "Disabled status");
}

{
    my $m = CLIO::MCP::Manager->new(
        config => { mcp => { rmt => { type => 'remote', url => 'https://mcp.example.com/api', enabled => 1 } } },
        debug => 0,
    );
    is($m->start(), 0, "Remote unreachable no crash");
    ok(defined $m->server_status()->{rmt}, "Remote in status");
    is($m->server_status()->{rmt}{status}, 'failed', "Remote shows failed");
}

{
    my $m = CLIO::MCP::Manager->new(
        config => { mcp => { bad => { command => ['nonexistent_mcp_cmd_xyz'] } } },
        debug => 0,
    );
    is($m->start(), 0, "Missing cmd no crash");
    is($m->server_status()->{bad}{status}, 'failed', "Missing cmd failed");
}

# ===== MCPBridge =====
{
    ok(CLIO::Tools::MCPBridge->is_mcp_tool('mcp_fs_read'), "is_mcp positive");
    ok(!CLIO::Tools::MCPBridge->is_mcp_tool('file_ops'), "is_mcp negative");
    ok(!CLIO::Tools::MCPBridge->is_mcp_tool(undef), "is_mcp undef");
    ok(!CLIO::Tools::MCPBridge->is_mcp_tool(''), "is_mcp empty");
}

{
    my $d = CLIO::Tools::MCPBridge->generate_tool_definitions(undef);
    is(ref($d), 'ARRAY', "gen_defs arrayref");
    is(scalar @$d, 0, "gen_defs empty");
}

{
    my $r = CLIO::Tools::MCPBridge->execute_tool(undef, 'mcp_t', {});
    ok(!$r->{success}, "execute fails no mgr");
    ok($r->{error}, "execute error no mgr");
}

# Summary
print "\n# Test summary: $tests_passed/$tests_run passed\n";
exit($tests_passed == $tests_run ? 0 : 1);
