#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: ToolExecutor's ToolLogger integration must redact secrets from
# logged parameters before writing them to disk. The old code logged raw
# parameters (which can contain API keys, file contents, connection strings)
# in plaintext, creating a side-channel leak via .clio/logs/ files.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $repo_root;
BEGIN {
    $repo_root = abs_path(dirname(dirname(dirname($0))));
    $repo_root = abs_path('.') unless -d "$repo_root/lib";
    unshift @INC, "$repo_root/lib";
}

use File::Temp qw(tempdir);
use CLIO::Core::ToolExecutor;
use CLIO::Logging::ToolLogger;
use CLIO::Security::SecretRedactor qw(get_redactor);

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $label) = @_;
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

# Create a temp directory to serve as the session working dir
my $tmp = tempdir(CLEANUP => 1);

# Create a mock session
my $mock_session = {
    session_id => 'test-session-123',
    state => sub {
        return {
            session_id => 'test-session-123',
            working_directory => $tmp,
        };
    },
};

# Build a ToolLogger pointed at a temp log dir
my $tool_logger = CLIO::Logging::ToolLogger->new(
    session_id => 'test-session-123',
    debug => 0,
    log_dir => "$tmp/.clio/logs",
);

my $executor = CLIO::Core::ToolExecutor->new(
    session => $mock_session,
    debug => 0,
    # Provide a mock config that returns 'strict' redact_level so all
    # secret types (API keys, tokens, PII, crypto) are redacted in logs.
    config => do {
        package MockConfigForTest;
        sub get {
            my ($self, $key) = @_;
            return $key eq 'redact_level' ? 'strict' : undef;
        }
        bless {}, 'MockConfigForTest';
    },
);
$executor->{tool_logger} = $tool_logger;

# ── Test 1: Parameters with API keys are redacted in logs ──
my $api_key_value = 'sk-proj-' . ('a' x 48);
my $tool_args = {
    operation => 'execute',
    command => "curl -H 'Authorization: Bearer $api_key_value' https://api.example.com",
};

$executor->_log_tool_operation({
    tool_call_id => 'test-call-1',
    tool_name => 'terminal_operations',
    operation => 'execute',
    parameters => $tool_args,
    output => { text => "HTTP/1.1 200 OK", exit_code => 0 },
    action_description => "Executing: curl command",
    sent_to_ai => "HTTP/1.1 200 OK",
    success => 1,
    execution_time_ms => 42,
});

# Read the log file and check for redaction
my $log_file = $tool_logger->_get_log_file();
my $log_content = '';
if (-f $log_file) {
    open my $lfh, '<', $log_file or die "Cannot read log: $!";
    local $/;
    $log_content = <$lfh>;
    close $lfh;
}

ok(index($log_content, $api_key_value) == -1, "API key NOT in plaintext in log file");
ok(index($log_content, '[REDACTED]') >= 0, "Redaction marker present in log file");

# ── Test 2: Non-secret parameters are preserved ──
$tool_args = {
    operation => 'read',
    path => '/etc/hostname',
};

$executor->_log_tool_operation({
    tool_call_id => 'test-call-2',
    tool_name => 'file_operations',
    operation => 'read',
    parameters => $tool_args,
    output => "localhost\n",
    action_description => "reading /etc/hostname",
    sent_to_ai => "localhost",
    success => 1,
    execution_time_ms => 5,
});

$log_content = '';
{
    open my $lfh, '<', $log_file or die "Cannot read log: $!";
    local $/;
    $log_content = <$lfh>;
    close $lfh;
}

ok(index($log_content, '/etc/hostname') >= 0, "Non-secret path preserved in log");
ok($log_content =~ /"operation"/, "Operation name preserved in log");

# ── Test 3: Database password in parameters is redacted ──
# Use single quotes to avoid Perl @-interpolation issues
my $db_command = q{psql "postgresql://user:s3cr3tPass123\@mydb\@db.example.com:5432/mydb" -c 'SELECT 1'};
$tool_args = {
    operation => 'execute',
    command => $db_command,
};

$executor->_log_tool_operation({
    tool_call_id => 'test-call-3',
    tool_name => 'terminal_operations',
    operation => 'execute',
    parameters => $tool_args,
    output => '',
    action_description => "Executing: psql",
    sent_to_ai => '',
    success => 0,
    error => "Connection failed",
    execution_time_ms => 100,
});

$log_content = '';
{
    open my $lfh, '<', $log_file or die "Cannot read log: $!";
    local $/;
    $log_content = <$lfh>;
    close $lfh;
}

ok($log_content !~ /s3cr3tPass123/, "Database password not in plaintext in log");

# ── Test 4: Nested hash parameters are recursively redacted ──
my $secret_value = 'ghp_' . ('x' x 36);
$tool_args = {
    operation => 'write',
    content_json => {
        lines => [
            "api_key = $secret_value",
            "config = { debug: true }",
        ],
        metadata => {
            token => $secret_value,
        },
    },
};

$executor->_log_tool_operation({
    tool_call_id => 'test-call-4',
    tool_name => 'file_operations',
    operation => 'write',
    parameters => $tool_args,
    output => '',
    action_description => "writing file",
    sent_to_ai => '',
    success => 1,
    execution_time_ms => 10,
});

$log_content = '';
{
    open my $lfh, '<', $log_file or die "Cannot read log: $!";
    local $/;
    $log_content = <$lfh>;
    close $lfh;
}

ok(index($log_content, $secret_value) == -1, "Secret in nested hash parameter is redacted in log");

print "\n----------------------------------------\n";
print "PASS: $pass  FAIL: $fail\n";
if ($fail > 0) {
    print "SOME TESTS FAILED!\n";
    exit 1;
}
print "ALL TESTS PASSED\n";
exit 0;
