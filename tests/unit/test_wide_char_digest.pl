#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test for wide-character handling in diagnostic digests.
#
# Digest::SHA is byte-oriented XS. Handing it a string that carries the
# UTF-8 flag dies with "Wide character in subroutine entry". Three places
# fed it model- or user-supplied text:
#
#   1. WorkflowOrchestrator::_tool_arguments_digest - the raw arguments of a
#      tool call. A patch body containing box-drawing (U+2500 is what the
#      apply_patch divider uses), accented text, or emoji sets the flag.
#      Because the digest is only computed on the tool-ERROR path, a failing
#      apply_patch turned a recoverable tool error into a fatal exception
#      that SimpleAIAgent reported as "API exception" and the turn was lost.
#   2. APIManager::_cache_diagnostics - system prompt, first non-system
#      message, and serialized tools. Gated on debug, so a debug session
#      died on every request once prompt content held non-ASCII.
#   3. Security::Auth::_generate_token - user id and secret key, so a
#      non-ASCII user name aborted login.
#
# Each site now encodes before hashing. ASCII-only input is unaffected, so
# digests and cache fingerprints computed before the fix still match; that
# stability is asserted here, because a silent change to the cache-prefix
# fingerprint would look like a provider caching regression.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);

use CLIO::Core::Config;
use CLIO::Core::WorkflowOrchestrator;
use CLIO::Core::APIManager;
use CLIO::Security::Auth;

my $BOX   = "\x{2500}";    # box drawings light horizontal
my $ACUTE = "\x{e9}";      # e-acute
my $EMOJI = "\x{1f600}";   # grinning face, needs a surrogate pair in UTF-8

sub build_orchestrator {
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$dir/config.json" or die $!;
    print $fh q({"provider":"github_copilot","api_key":"sk-test-key"});
    close $fh;
    return CLIO::Core::WorkflowOrchestrator->new(
        config  => CLIO::Core::Config->new(config_dir => $dir),
        debug   => 0,
        session => undef,
    );
}

sub build_apimanager {
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$dir/config.json" or die $!;
    print $fh q({"provider":"github_copilot","api_key":"sk-test-key"});
    close $fh;
    my $am = CLIO::Core::APIManager->new(
        config => CLIO::Core::Config->new(config_dir => $dir),
    );
    $am->{debug}       = 1;   # _cache_diagnostics only runs when debugging
    $am->{_request_seq} = 1;
    return $am;
}

# ---------------------------------------------------------------------------
# 1. Tool arguments digest: the reported crash
# ---------------------------------------------------------------------------

my $wo = build_orchestrator();

# Eval-wrapped so a regression reports every site instead of the first die
# aborting the run and hiding the rest.
sub digest_of {
    my ($call) = @_;
    my $d = eval { $wo->_tool_arguments_digest($call) };
    return $@ ? "DIED: $@" : $d;
}

# The shape that broke: a patch body carrying the apply_patch divider.
my $patch_args = '{"path":"/x/app.js","patch":"*** Update File: app.js' . "\\n"
               . $BOX x 35 . "\\nError: no match\\n\"}";
ok(utf8::is_utf8($patch_args), 'fixture really carries the UTF-8 flag');

my $digest = digest_of({ function => { arguments => $patch_args } });
ok($digest !~ /^DIED/, 'wide-character arguments no longer die in the digest')
    or diag($digest);
like($digest // '', qr/^[0-9a-f]{64}$/, 'digest is 64 hex chars');

is(digest_of({ function => { arguments => $patch_args } }),
   $digest, 'same arguments digest the same twice (repeat detection intact)');

isnt(digest_of({ function => { arguments => '{"path":"/other"}' } }),
     $digest, 'different arguments digest differently');

# Encoding must be deterministic and content-preserving: the digest of the
# decoded string equals the digest of its UTF-8 bytes.
is($digest, sha256_hex(encode_utf8($patch_args)),
   'digest matches sha256 of the UTF-8 bytes');

# ---------------------------------------------------------------------------
# 2. Tool arguments digest: fallback path and guards
# ---------------------------------------------------------------------------

my $parsed = digest_of({ _parsed_args => { patch => $BOX . ' divider ' . $EMOJI } });
ok($parsed !~ /^DIED/ && length($parsed // ''),
   'wide characters survive the parsed-arguments fallback')
    or diag($parsed);

is(digest_of({ function => { arguments => '' } }), '',
   'empty arguments digest to empty string');
is(digest_of(undef), '', 'undef tool call digests to empty string');
is(digest_of({ function => { arguments => undef } }), '',
   'undef arguments digest to empty string');
is(digest_of('not a hashref'), '',
   'non-hashref tool call digests to empty string');

# ---------------------------------------------------------------------------
# 3. ASCII digests unchanged by the fix
# ---------------------------------------------------------------------------

for my $ascii ('{"path":"/x/y.js"}', '{"operation":"exec","command":"ls -la"}', 'plain') {
    ok(!utf8::is_utf8($ascii), "ascii fixture '$ascii' is byte-flagged off");
    is(digest_of({ function => { arguments => $ascii } }),
       sha256_hex($ascii),
       "ascii digest byte-identical to plain sha256_hex: $ascii");
}

# ---------------------------------------------------------------------------
# 4. Loop tracker still works when the digest came from wide text
# ---------------------------------------------------------------------------

# The point of the digest is identical-repeat detection, so the fix has to
# preserve it end to end through track_tool_error_loop.
my $d1 = digest_of({ function => { arguments => $patch_args } });
my $v1 = $wo->track_tool_error_loop(
    tool => 'apply_patch', operation => '', category => 'unknown',
    args_digest => $d1, iteration => 1);
my $v2 = $wo->track_tool_error_loop(
    tool => 'apply_patch', operation => '', category => 'unknown',
    args_digest => $d1, iteration => 2);
is($v1->{identical}, 1, 'first wide-argument failure counted once');
is($v2->{identical}, 2, 'repeated wide-argument failure detected as identical');
ok(defined $v2->{guidance}, 'identical repeat still produces guidance');

# An undigestable call degrades to '' and must not collide into a false
# "identical" verdict on its own.
$wo->reset_tool_error_loop();
my $e1 = $wo->track_tool_error_loop(
    tool => 'apply_patch', operation => '', category => 'unknown',
    args_digest => '', iteration => 1);
is($e1->{identical}, 1, 'empty digest counts as a first attempt');

# ---------------------------------------------------------------------------
# 5. Cache diagnostics: the debug-mode instance
# ---------------------------------------------------------------------------

my $am = build_apimanager();
my $wide_payload = {
    messages => [
        { role => 'system', content => "system $BOX prompt $ACUTE" },
        { role => 'user',   content => "user $EMOJI message" },
    ],
    tools => [{ type => 'function', function => { name => "tool$ACUTE", description => "$BOX" } }],
};
my $diag_ok = eval { $am->_cache_diagnostics({}, $wide_payload, 'test-model', { name => 'test' }); 1 };
ok($diag_ok, 'wide prompt content no longer dies in cache diagnostics')
    or diag("died: $@");

my $diag = $am->{_pending_cache_diag};
ok($diag, 'diagnostics recorded');
for my $field (qw(system_prompt_hash first_nonsys_hash tools_hash request_prefix_hash)) {
    like($diag->{$field} // '', qr/^[0-9a-f]{16}$/, "$field is 16 hex chars");
}

# Array-form message content (multimodal) takes the same join path.
my $array_ok = eval {
    $am->_cache_diagnostics({}, {
        messages => [
            { role => 'system', content => [{ type => 'text', text => "sys$BOX" }] },
            { role => 'user',   content => [{ type => 'text', text => "hi $ACUTE" }] },
        ],
        tools => [],
    }, 'test-model', { name => 'test' }); 1;
};
ok($array_ok, 'wide content in array-form messages is handled') or diag("died: $@");

# ---------------------------------------------------------------------------
# 6. ASCII fingerprints unchanged, so cache-prefix history still lines up
# ---------------------------------------------------------------------------

$am->{_pending_cache_diag} = undef;
$am->_cache_diagnostics({}, {
    messages => [
        { role => 'system', content => 'plain system prompt' },
        { role => 'user',   content => 'plain user message' },
    ],
    tools => [],
}, 'test-model', { name => 'test' });
my $ascii_diag = $am->{_pending_cache_diag};
is($ascii_diag->{system_prompt_hash}, substr(sha256_hex('plain system prompt'), 0, 16),
   'ascii system fingerprint matches plain sha256_hex');
is($ascii_diag->{first_nonsys_hash}, substr(sha256_hex('plain user message'), 0, 16),
   'ascii first non-system fingerprint matches plain sha256_hex');
is($ascii_diag->{request_prefix_hash},
   substr(sha256_hex(substr(sha256_hex('plain system prompt'), 0, 16)
                   . substr(sha256_hex('plain user message'), 0, 16)
                   . substr(sha256_hex('[]'), 0, 16)), 0, 16),
   'ascii prefix fingerprint matches plain sha256_hex');

# ---------------------------------------------------------------------------
# 7. Auth token generation
# ---------------------------------------------------------------------------

my $auth = CLIO::Security::Auth->new(secret_key => "sec$ACUTE ret");
my $token;
my $auth_ok = eval { $token = $auth->_generate_token("caf$ACUTE.user$BOX"); 1 };
ok($auth_ok, 'wide user id and secret no longer die in token generation')
    or diag("died: $@");
like($token // '', qr/^[0-9a-f]{64}$/, 'token is 64 hex chars');

my $ascii_auth = CLIO::Security::Auth->new(secret_key => 'plainsecret');
like($ascii_auth->_generate_token('plain.user'), qr/^[0-9a-f]{64}$/,
     'ascii login path still produces a token');

done_testing();
