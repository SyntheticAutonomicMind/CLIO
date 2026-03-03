#!/usr/bin/env perl

# Test error classification and formatting

use strict;
use warnings;
use utf8;
use lib '../../lib';
use Test::More;

use_ok('CLIO::Core::ErrorContext', qw(classify_error format_error));

# ============================================================================
# classify_error tests
# ============================================================================

subtest 'classify transport errors' => sub {
    is(classify_error('Connection refused'), 'transport', 'connection refused');
    is(classify_error('Connection timed out'), 'transport', 'connection timed out');
    is(classify_error('Connection reset by peer'), 'transport', 'connection reset');
    is(classify_error('SSL handshake error'), 'transport', 'SSL error');
    is(classify_error('read timeout at line 5'), 'transport', 'read timeout');
    is(classify_error('ETIMEDOUT'), 'transport', 'ETIMEDOUT');
    is(classify_error('socket error'), 'transport', 'socket');
};

subtest 'classify auth errors' => sub {
    is(classify_error('HTTP 401 Unauthorized'), 'auth', '401');
    is(classify_error('HTTP 403 Forbidden'), 'auth', '403');
    is(classify_error('Authentication failed for user'), 'auth', 'auth failed');
    is(classify_error('Invalid API token'), 'auth', 'invalid token');
    is(classify_error('Token has expired'), 'auth', 'token expired');
    is(classify_error('Access denied'), 'auth', 'access denied');
};

subtest 'classify validation errors' => sub {
    is(classify_error('HTTP 400 Bad Request'), 'validation', '400');
    is(classify_error('HTTP 422 Unprocessable'), 'validation', '422');
    is(classify_error('Invalid JSON in response'), 'validation', 'invalid JSON');
    is(classify_error('Missing required parameter: host'), 'validation', 'missing param');
    is(classify_error('Malformed request body'), 'validation', 'malformed');
    is(classify_error("decode_json failed: not a valid JSON"), 'validation', 'decode_json');
};

subtest 'classify IO errors' => sub {
    is(classify_error('No such file or directory'), 'io', 'no such file');
    is(classify_error('Is a directory'), 'io', 'is a directory');
    is(classify_error('No space left on device'), 'io', 'no space');
    is(classify_error('Failed to open /tmp/foo: No such file or directory'), 'io', 'failed to open');
    is(classify_error('Failed to write config'), 'io', 'failed to write');
};

subtest 'classify unexpected errors' => sub {
    is(classify_error('something weird happened'), 'unexpected', 'unknown error');
    is(classify_error(undef), 'unexpected', 'undef error');
    is(classify_error(''), 'unexpected', 'empty error');
    is(classify_error('Bizarre copy of HASH'), 'unexpected', 'perl internal');
};

# Auth should take priority over IO for "Permission denied"
subtest 'auth beats IO for Permission denied' => sub {
    is(classify_error('Permission denied'), 'auth', 'Permission denied -> auth');
};

# ============================================================================
# format_error tests
# ============================================================================

subtest 'format_error basic' => sub {
    my $msg = format_error('Connection refused', 'API request');
    like($msg, qr/^API request failed \(transport\): Connection refused$/, 'formatted transport error');
};

subtest 'format_error strips Perl location' => sub {
    my $msg = format_error('Something broke at /foo/bar.pm line 42.', 'parsing');
    like($msg, qr/^parsing failed \(unexpected\): Something broke$/, 'stripped location');
};

subtest 'format_error with undef' => sub {
    my $msg = format_error(undef, 'test');
    like($msg, qr/^test failed \(unexpected\): unknown error$/, 'undef handled');
};

subtest 'format_error with no context' => sub {
    my $msg = format_error('Connection refused');
    like($msg, qr/^operation failed \(transport\): Connection refused$/, 'default context');
};

done_testing();
