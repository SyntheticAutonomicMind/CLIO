#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: /api set base URL normalization for local inference providers
# (llama.cpp, lmstudio, sam). The user reported a fresh llama.cpp install
# with a bare host URL like http://nimo:9090 producing a useless "File Not
# Found" error because the request hit the server root instead of
# /v1/chat/completions. CLIO now auto-appends the conventional path for
# local inference providers and prints a one-line note about the change.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $repo_root = abs_path(dirname(dirname(dirname($0))));
$repo_root = abs_path('.') unless -d "$repo_root/lib";
unshift @INC, "$repo_root/lib";

BEGIN {
    no warnings 'redefine';
    eval { require CLIO::Compat::Terminal; };
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (80, 24); };
    *CLIO::Compat::Terminal::ReadMode     = sub { };
    *CLIO::Compat::Terminal::ReadKey      = sub { undef };
}

BEGIN {
    $ENV{CLIO_NO_CONFIG_LOAD} = 1;
}

use CLIO::UI::Commands::API::Config;

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $label) = @_;
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

# Build a minimal stub config + chat so the API::Config command object
# can be instantiated without dragging in a real session/agent.
package FakeConfig;
sub new { return bless { config => { provider => $_[1] }, user_set => {} }, $_[0] }
sub get { my ($s, $k) = @_; return $s->{config}{$k}; }
sub set { my ($s, $k, $v) = @_; $s->{config}{$k} = $v; $s->{user_set}{$k} = 1; }
sub get_provider_base { return undef; }
sub set_provider_base { return 1; }
sub save { return 1; }
package FakeChat;
sub new { return bless {}, $_[0] }
package main;

my $cfg_stub = FakeConfig->new('llama.cpp');
my $cmd = CLIO::UI::Commands::API::Config->new(
    chat   => FakeChat->new(),
    config => $cfg_stub,
    session => undef,
    ai_agent => undef,
    debug => 0,
);

# --- llama.cpp cases ---

my @cases = (
    # input,                            expected normalized URL,         expected note contains
    ['llama.cpp', 'http://nimo:9090',   'http://nimo:9090/v1/chat/completions', 'appended /v1/chat/completions'],
    ['llama.cpp', 'http://nimo:9090/',  'http://nimo:9090/v1/chat/completions', 'appended /v1/chat/completions'],
    ['llama.cpp', 'http://localhost:8080', 'http://localhost:8080/v1/chat/completions', 'appended /v1/chat/completions'],
    ['llama.cpp', 'http://nimo:9090/v1',     'http://nimo:9090/chat/completions',  'appended /chat/completions to existing /v1'],
    ['llama.cpp', 'http://nimo:9090/v1/',    'http://nimo:9090/chat/completions',  'appended /chat/completions to existing /v1'],
    ['llama.cpp', 'http://nimo:9090/v1/chat/completions', 'http://nimo:9090/v1/chat/completions', undef],
    ['llama.cpp', 'http://nimo:9090/v1/chat/completions/', 'http://nimo:9090/v1/chat/completions/', undef],

    # lmstudio and sam are also local inference - same rules apply
    ['lmstudio', 'http://localhost:1234', 'http://localhost:1234/v1/chat/completions', 'appended /v1/chat/completions'],
    ['sam',      'http://localhost:8080', 'http://localhost:8080/v1/chat/completions', 'appended /v1/chat/completions'],

    # Non-local providers (e.g. openai, github_copilot, google) - leave alone
    # even when bare host. They use different URL conventions.
    ['openai',      'https://api.openai.com',           'https://api.openai.com',           undef],
    ['github_copilot', 'https://api.githubcopilot.com', 'https://api.githubcopilot.com',    undef],
    ['deepseek',    'https://api.deepseek.com/v1',      'https://api.deepseek.com/v1',      undef],
);

for my $case (@cases) {
    my ($provider, $input, $expected_url, $expected_note_contains) = @$case;

    $cfg_stub->{config}{provider} = $provider;
    my ($got_url, $got_note) = $cmd->_normalize_local_inference_url($input, $provider);

    ok($got_url eq $expected_url,
        sprintf("[%s] %-50s -> %s",
            $provider, $input, $got_url));

    if (defined $expected_note_contains) {
        ok(defined $got_note && index($got_note, $expected_note_contains) >= 0,
            sprintf("[%s] note mentions normalization (got: %s)",
                $provider, $got_note // '(none)'));
    } else {
        ok(!defined $got_note,
            sprintf("[%s] no normalization needed -> no note", $provider));
    }
}

# --- Unknown provider: leave alone ---
{
    my ($got_url, $got_note) = $cmd->_normalize_local_inference_url('http://example.com', 'unknown_provider');
    ok($got_url eq 'http://example.com' && !defined $got_note,
        'Unknown provider: URL unchanged, no note');
}

# --- HTTPS variant ---
{
    my ($got_url, $got_note) = $cmd->_normalize_local_inference_url('https://gpu-server.local:9090', 'llama.cpp');
    ok($got_url eq 'https://gpu-server.local:9090/v1/chat/completions',
        'HTTPS bare host normalized');
    ok(defined $got_note, 'HTTPS normalization produces a note');
}

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);