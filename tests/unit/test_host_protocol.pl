#!/usr/bin/env perl
# Unit tests for CLIO::UI::HostProtocol
use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempfile);

use lib './lib';

# Test 1: Module loads
use_ok('CLIO::UI::HostProtocol');

# Test 2: Inactive by default (no CLIO_HOST_PROTOCOL env var)
{
    local $ENV{CLIO_HOST_PROTOCOL};
    delete $ENV{CLIO_HOST_PROTOCOL};
    my $proto = CLIO::UI::HostProtocol->new();
    ok(!$proto->active(), 'Protocol is inactive without CLIO_HOST_PROTOCOL');
}

# Test 3: Active when env var is set
{
    local $ENV{CLIO_HOST_PROTOCOL} = '1';
    my $proto = CLIO::UI::HostProtocol->new();
    ok($proto->active(), 'Protocol is active with CLIO_HOST_PROTOCOL=1');
}

# Test 4: emit methods are no-ops when inactive
{
    local $ENV{CLIO_HOST_PROTOCOL};
    delete $ENV{CLIO_HOST_PROTOCOL};
    my $proto = CLIO::UI::HostProtocol->new();

    # Capture STDOUT to verify nothing is emitted
    my $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Cannot redirect STDOUT: $!";
        $proto->emit_status('thinking');
        $proto->emit_tool_start('file_operations', 'read_file');
        $proto->emit_tool_end('file_operations');
        $proto->emit_spinner_start('Working...');
        $proto->emit_spinner_stop();
        $proto->emit_session(id => 'test', name => 'Test');
        $proto->emit_tokens(prompt => 100, completion => 50);
        $proto->emit_todo({id => 1, title => 'test', status => 'done'});
        $proto->emit_title('Test Title');
    }
    is($output, '', 'No output when protocol is inactive');
}

# Test 5: emit_status produces correct OSC sequence
{
    local $ENV{CLIO_HOST_PROTOCOL} = '1';
    my $proto = CLIO::UI::HostProtocol->new();

    my $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Cannot redirect STDOUT: $!";
        $proto->emit_status('thinking');
    }
    like($output, qr/\x1b\]0;clio:status:/, 'Status emits OSC with clio: prefix');
    like($output, qr/"state"\s*:\s*"thinking"/, 'Status contains state field');
    like($output, qr/\x07$/, 'Status ends with BEL');
}

# Test 6: emit_tool_start produces correct format
{
    local $ENV{CLIO_HOST_PROTOCOL} = '1';
    my $proto = CLIO::UI::HostProtocol->new();

    my $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Cannot redirect STDOUT: $!";
        $proto->emit_tool_start('file_operations', 'read_file');
    }
    like($output, qr/\x1b\]0;clio:tool:/, 'Tool start emits with clio:tool: prefix');
    like($output, qr/"action"\s*:\s*"start"/, 'Tool start has action=start');
    like($output, qr/"name"\s*:\s*"file_operations"/, 'Tool start has tool name');
    like($output, qr/"op"\s*:\s*"read_file"/, 'Tool start has operation');
}

# Test 7: emit_tool_end produces correct format
{
    local $ENV{CLIO_HOST_PROTOCOL} = '1';
    my $proto = CLIO::UI::HostProtocol->new();

    my $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Cannot redirect STDOUT: $!";
        $proto->emit_tool_end('file_operations');
    }
    like($output, qr/"action"\s*:\s*"end"/, 'Tool end has action=end');
}

# Test 8: emit_title produces non-prefixed OSC
{
    local $ENV{CLIO_HOST_PROTOCOL} = '1';
    my $proto = CLIO::UI::HostProtocol->new();

    my $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Cannot redirect STDOUT: $!";
        $proto->emit_title('CLIO - My Session');
    }
    like($output, qr/\x1b\]0;CLIO - My Session\x07/, 'Title emits plain OSC without clio: prefix');
    unlike($output, qr/clio:/, 'Title does not contain protocol prefix');
}

# Test 9: emit_spinner produces correct format
{
    local $ENV{CLIO_HOST_PROTOCOL} = '1';
    my $proto = CLIO::UI::HostProtocol->new();

    my $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Cannot redirect STDOUT: $!";
        $proto->emit_spinner_start('Processing...');
    }
    like($output, qr/clio:spinner:/, 'Spinner uses clio:spinner: prefix');
    like($output, qr/"action"\s*:\s*"start"/, 'Spinner start has action=start');
    like($output, qr/"label"\s*:\s*"Processing\.\.\."/, 'Spinner includes label');
}

# Test 10: emit_tokens produces correct format
{
    local $ENV{CLIO_HOST_PROTOCOL} = '1';
    my $proto = CLIO::UI::HostProtocol->new();

    my $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Cannot redirect STDOUT: $!";
        $proto->emit_tokens(prompt => 1000, completion => 500, total => 1500);
    }
    like($output, qr/clio:tokens:/, 'Tokens uses clio:tokens: prefix');
    like($output, qr/"prompt"\s*:\s*1000/, 'Tokens includes prompt count');
    like($output, qr/"total"\s*:\s*1500/, 'Tokens includes total count');
}

# Test 11: emit_session produces correct format
{
    local $ENV{CLIO_HOST_PROTOCOL} = '1';
    my $proto = CLIO::UI::HostProtocol->new();

    my $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Cannot redirect STDOUT: $!";
        $proto->emit_session(id => 'abc123', name => 'My Session', dir => '/tmp');
    }
    like($output, qr/clio:session:/, 'Session uses clio:session: prefix');
    like($output, qr/"id"\s*:\s*"abc123"/, 'Session includes id');
    like($output, qr/"name"\s*:\s*"My Session"/, 'Session includes name');
}

# Test 12: emit_status with extra fields
{
    local $ENV{CLIO_HOST_PROTOCOL} = '1';
    my $proto = CLIO::UI::HostProtocol->new();

    my $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Cannot redirect STDOUT: $!";
        $proto->emit_status('thinking', model => 'gpt-4.1');
    }
    like($output, qr/"state"\s*:\s*"thinking"/, 'Status has state');
    like($output, qr/"model"\s*:\s*"gpt-4.1"/, 'Status includes extra model field');
}

done_testing();
