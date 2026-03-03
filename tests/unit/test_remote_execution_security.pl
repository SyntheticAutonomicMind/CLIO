#!/usr/bin/env perl

# Test shell injection hardening in RemoteExecution.pm

use strict;
use warnings;
use utf8;
use lib '../../lib';
use Test::More;

# We test the validation and quoting helpers directly
# without needing actual SSH connectivity

use_ok('CLIO::Tools::RemoteExecution');

# Create a mock instance
my $re = bless {}, 'CLIO::Tools::RemoteExecution';

# ============================================================================
# _shell_quote tests
# ============================================================================

subtest '_shell_quote' => sub {
    is($re->_shell_quote('simple'), "'simple'", 'simple string');
    is($re->_shell_quote('hello world'), "'hello world'", 'string with space');
    is($re->_shell_quote("it's"), "'it'\\''s'", 'string with single quote');
    is($re->_shell_quote('$(whoami)'), "'\$(whoami)'", 'command substitution wrapped in single quotes');
    is($re->_shell_quote('`id`'), "'`id`'", 'backtick wrapped in single quotes');
    is($re->_shell_quote('a;b'), "'a;b'", 'semicolon preserved literally');
    is($re->_shell_quote('a|b'), "'a|b'", 'pipe preserved literally');
    is($re->_shell_quote('/tmp/path'), "'/tmp/path'", 'normal path');
    is($re->_shell_quote(''), "''", 'empty string');
};

# ============================================================================
# _validate_host tests
# ============================================================================

subtest '_validate_host - valid hosts' => sub {
    ok($re->_validate_host('user@host'), 'user@host');
    ok($re->_validate_host('user@host.example.com'), 'FQDN');
    ok($re->_validate_host('192.168.1.1'), 'IPv4');
    ok($re->_validate_host('user@192.168.1.1'), 'user@IPv4');
    ok($re->_validate_host('host-name'), 'hyphenated host');
    ok($re->_validate_host('host_name'), 'underscored host');
    ok($re->_validate_host('[::1]'), 'IPv6 in brackets');
    ok($re->_validate_host('user@[::1]'), 'user@IPv6');
};

subtest '_validate_host - invalid hosts' => sub {
    ok(!$re->_validate_host(undef), 'undef');
    ok(!$re->_validate_host(''), 'empty');
    ok(!$re->_validate_host('host; rm -rf /'), 'semicolon injection');
    ok(!$re->_validate_host('host$(whoami)'), 'command substitution');
    ok(!$re->_validate_host('host`id`'), 'backtick injection');
    ok(!$re->_validate_host('host name'), 'space in host');
    ok(!$re->_validate_host("host\nid"), 'newline in host');
    ok(!$re->_validate_host('host|cat /etc/passwd'), 'pipe injection');
    ok(!$re->_validate_host('host&bg'), 'ampersand injection');
    ok(!$re->_validate_host('host>file'), 'redirect injection');
    ok(!$re->_validate_host('host<file'), 'input redirect injection');
    ok(!$re->_validate_host("host'quote"), 'single quote in host');
    ok(!$re->_validate_host('host"quote'), 'double quote in host');
};

# ============================================================================
# _validate_port tests
# ============================================================================

subtest '_validate_port - valid ports' => sub {
    ok($re->_validate_port(22), 'port 22');
    ok($re->_validate_port(443), 'port 443');
    ok($re->_validate_port(1), 'port 1');
    ok($re->_validate_port(65535), 'port 65535');
    ok($re->_validate_port('2222'), 'port as string');
};

subtest '_validate_port - invalid ports' => sub {
    ok(!$re->_validate_port(undef), 'undef');
    ok(!$re->_validate_port(0), 'port 0');
    ok(!$re->_validate_port(65536), 'port > 65535');
    ok(!$re->_validate_port('abc'), 'non-numeric');
    ok(!$re->_validate_port('22; rm -rf /'), 'injection in port');
    ok(!$re->_validate_port(''), 'empty string');
};

# ============================================================================
# _validate_path tests
# ============================================================================

subtest '_validate_path - valid paths' => sub {
    ok($re->_validate_path('/tmp/test'), 'absolute path');
    ok($re->_validate_path('relative/path'), 'relative path');
    ok($re->_validate_path('/path/with spaces/file'), 'path with spaces');
    ok($re->_validate_path('/tmp/file.txt'), 'path with extension');
    ok($re->_validate_path('~/.ssh/id_rsa'), 'home dir path');
};

subtest '_validate_path - invalid paths' => sub {
    ok(!$re->_validate_path(undef), 'undef');
    ok(!$re->_validate_path(''), 'empty');
    ok(!$re->_validate_path("/path/with\0null"), 'null byte in path');
};

# ============================================================================
# _ssh_exec validation integration tests
# ============================================================================

subtest '_ssh_exec rejects bad host' => sub {
    my $result = $re->_ssh_exec(
        host => 'host; rm -rf /',
        command => 'echo hello',
    );
    ok(!$result->{success}, 'rejected');
    like($result->{error}, qr/Invalid host/, 'error mentions host');
};

subtest '_ssh_exec rejects bad port' => sub {
    my $result = $re->_ssh_exec(
        host => 'user@host',
        ssh_port => 'abc',
        command => 'echo hello',
    );
    ok(!$result->{success}, 'rejected');
    like($result->{error}, qr/Invalid SSH port/, 'error mentions port');
};

subtest '_ssh_exec rejects bad ssh_key path' => sub {
    my $result = $re->_ssh_exec(
        host => 'user@host',
        ssh_key => "/path/with\0null",
        command => 'echo hello',
    );
    ok(!$result->{success}, 'rejected');
    like($result->{error}, qr/Invalid SSH key/, 'error mentions key');
};

# ============================================================================
# _scp_to_remote validation integration tests
# ============================================================================

subtest '_scp_to_remote rejects bad host' => sub {
    my $result = $re->_scp_to_remote(
        host => '$(whoami)@evil',
        local_path => '/tmp/file',
        remote_path => '/tmp/dest',
    );
    ok(!$result->{success}, 'rejected');
    like($result->{error}, qr/Invalid host/, 'error mentions host');
};

subtest '_scp_to_remote rejects null byte path' => sub {
    my $result = $re->_scp_to_remote(
        host => 'user@host',
        local_path => "/tmp/file\0evil",
        remote_path => '/tmp/dest',
    );
    ok(!$result->{success}, 'rejected');
    like($result->{error}, qr/Invalid file path/, 'error mentions path');
};

# ============================================================================
# _scp_from_remote validation integration tests
# ============================================================================

subtest '_scp_from_remote rejects bad host' => sub {
    my $result = $re->_scp_from_remote(
        host => 'host`id`',
        remote_path => '/tmp/file',
        local_path => '/tmp/dest',
    );
    ok(!$result->{success}, 'rejected');
    like($result->{error}, qr/Invalid host/, 'error mentions host');
};

# ============================================================================
# _copy_local_clio_to_remote validation tests
# ============================================================================

subtest '_copy_local_clio_to_remote rejects bad host' => sub {
    my $result = $re->_copy_local_clio_to_remote(
        host => 'host; evil',
        remote_dir => '/tmp/clio',
    );
    ok(!$result->{success}, 'rejected');
    like($result->{error}, qr/Invalid host/, 'error mentions host');
};

subtest '_copy_local_clio_to_remote rejects bad port' => sub {
    my $result = $re->_copy_local_clio_to_remote(
        host => 'user@host',
        ssh_port => '22; evil',
        remote_dir => '/tmp/clio',
    );
    ok(!$result->{success}, 'rejected');
    like($result->{error}, qr/Invalid SSH port/, 'error mentions port');
};

done_testing();
