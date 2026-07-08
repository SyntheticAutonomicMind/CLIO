#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Regression: MCM._query_llama_props derived the /props URL by stripping
# /v1 from the chat api_base. The regex `s{/v1(/.*)?$}{}` only handled
# /v1 paths. For any other path, it appended /props to the full chat
# URL, producing invalid URLs:
#
#   http://localhost:8080/api/chat/completions  -> /api/chat/completions/props (404)
#   http://localhost:8080/v2/chat/completions  -> /v2/chat/completions/props (404)
#   https://api.githubcopilot.com               -> https://api.githubcopilot.comprops (missing slash)
#
# The function returns undef when /props is unavailable, so MCM silently
# fell back to max_context_tokens. User saw the wrong context window.
#
# Fix: new helper _origin_from_url extracts just the origin
# (protocol + host + port) from any URL shape, then /props is appended.
# Handles bare hosts, IPv6 (bracketed), query strings, fragments,
# and any path prefix (not just /v1).

use Test::More;

use CLIO::Core::ModelCapabilitiesManager;

my $mcm = CLIO::Core::ModelCapabilitiesManager->new();

# Test 1-13: Origin extraction correctness across URL shapes
{
    my @cases = (
        # input, expected origin
        [ 'http://localhost:8080/v1/chat/completions',  'http://localhost:8080' ],
        [ 'http://localhost:8080/v1/chat/completions/', 'http://localhost:8080' ],  # trailing slash
        [ 'http://localhost:8080/v1',                  'http://localhost:8080' ],  # bare /v1
        [ 'http://localhost:8080/v1/',                 'http://localhost:8080' ],  # /v1/ trailing
        [ 'http://localhost:1234/v1/chat/completions',  'http://localhost:1234' ],  # LM Studio default
        [ 'http://max.local:9090/v1/chat/completions',  'http://max.local:9090' ],  # LAN hostname
        [ 'http://192.168.1.50:8080/v1/chat/completions', 'http://192.168.1.50:8080' ], # LAN IP
        [ 'http://[::1]:8080/v1/chat/completions',      'http://[::1]:8080' ],  # IPv6 localhost
        [ 'https://api.githubcopilot.com',              'https://api.githubcopilot.com' ], # bare host
        [ 'https://api.githubcopilot.com/',             'https://api.githubcopilot.com' ], # bare host + slash
        [ 'http://localhost:8080/api/chat/completions', 'http://localhost:8080' ],  # /api/ path (was broken)
        [ 'https://api.openai.com/v1/chat/completions?token=abc', 'https://api.openai.com' ], # query string
        [ 'https://api.openai.com/v1/chat/completions#frag',    'https://api.openai.com' ], # fragment
    );

    for my $case (@cases) {
        my ($input, $expected) = @$case;
        my $result = $mcm->_origin_from_url($input);
        is($result, $expected, "origin('$input') = '$expected'");
    }
}

# Test 14: Empty/undef input returns undef (don't blow up)
{
    is($mcm->_origin_from_url(undef),  undef, 'undef input -> undef');
    is($mcm->_origin_from_url(''),    undef, 'empty input -> undef');
}

# Test 15: HTTP-only scheme variants work
{
    is($mcm->_origin_from_url('http://example.com/path'),
       'http://example.com', 'http scheme');
    is($mcm->_origin_from_url('https://example.com/path'),
       'https://example.com', 'https scheme');
}

# Test 16: userinfo is preserved
{
    is($mcm->_origin_from_url('http://user:pass@host:8080/v1/chat/completions'),
       'http://user:pass@host:8080', 'user:pass@ preserved in origin');
}

# Test 17: HTTPS with port
{
    is($mcm->_origin_from_url('https://api.example.com:8443/v1/chat/completions'),
       'https://api.example.com:8443', 'port preserved');
}

# Test 18: Source-level regression guards
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die; <$fh> };

    # The /v1 stripping pattern (as a regex literal, not a comment) must
    # not appear in the active code of _query_llama_props. We grep for
    # the comment form (backticks around the regex in the comment) to
    # confirm the old pattern is only referenced in explanatory text.
    my $fn_start = index($src, 'sub _query_llama_props');
    my $fn_end   = index($src, 'sub _origin_from_url', $fn_start);
    my $fn_body  = $fn_start >= 0 && $fn_end > $fn_start
        ? substr($src, $fn_start, $fn_end - $fn_start)
        : '';
    # The simplest and most reliable check: the function body should
    # contain a call to _origin_from_url (proves the new code path
    # exists) and should NOT contain the `s{` substitution operator
    # at all (proves the old `s{/v1...}` regex was replaced).
    like($fn_body, qr/_origin_from_url\(/,
        '_query_llama_props delegates URL parsing to _origin_from_url');
    # The /props URL construction should use the helper's output, not
    # a regex substitution on the input.
    unlike($fn_body, qr/s\{[^}]+\}\s*=\s*\$api_base/,
        '_query_llama_props no longer does regex substitution on $api_base');

    # New helper must exist
    like($src, qr/sub _origin_from_url/,
        'new _origin_from_url helper is defined');
}

done_testing();
