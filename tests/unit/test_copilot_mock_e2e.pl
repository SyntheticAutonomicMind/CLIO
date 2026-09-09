#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# End-to-end test for GitHub Copilot provider using a mock API server.
#
# This test starts tests/manual/mock_copilot_server.pl on a local port,
# then exercises the Copilot auth/token exchange and chat flow against it.
# No real GitHub account or API key is required.
#
# Usage: perl -I./lib tests/unit/test_copilot_mock_e2e.pl

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use IO::Socket::INET;

# Start the mock server
my $port = 18443 + int(rand(1000));
my $mock_script = "$FindBin::Bin/../manual/mock_copilot_server.pl";

my $pid = fork();
if ($pid == 0) {
    # Child: start mock server
    close(STDIN);
    open(STDIN, '<', '/dev/null');
    exec("perl", "-I./lib", $mock_script, $port);
    exit(1);
}

# Wait for the server to start
sleep(1);

# Verify server is up
use IO::Socket::INET;
my $sock = IO::Socket::INET->new(
    PeerAddr => '127.0.0.1',
    PeerPort => $port,
    Proto    => 'tcp',
    Timeout  => 2,
);

if ($sock) {
    close($sock);
    ok(1, "Mock Copilot server started on port $port");
} else {
    fail("Mock Copilot server failed to start on port $port");
    kill(9, $pid) if $pid;
    done_testing();
    exit(1);
}

# Test 1: Token exchange via GitHubAuth
{
    require CLIO::Core::GitHubAuth;
    my $auth = CLIO::Core::GitHubAuth->new(
        api_base => "http://127.0.0.1:$port",
    );

    my $token_data = $auth->exchange_for_copilot_token('mock-github-token');
    if ($token_data) {
        ok($token_data->{token}, 'Token exchange returns a token');
        ok($token_data->{token} =~ /^mock-copilot-token/, 'Token is a mock token');
        note "Token: $token_data->{token}";
    } else {
        fail('Token exchange failed');
    }
}

# Test 2: Token exchange does not crash with invalid-format token
{
    require CLIO::Core::GitHubAuth;
    my $auth = CLIO::Core::GitHubAuth->new(
        api_base => "http://127.0.0.1:$port",
    );

    my $token_data = eval { $auth->exchange_for_copilot_token('invalid-token') };
    ok(1, 'Token exchange with invalid-format token does not crash');
}

# Test 3: User API fetch
{
    require CLIO::Core::CopilotUserAPI;
    my $user_api = CLIO::Core::CopilotUserAPI->new(
        api_base_url => "http://127.0.0.1:$port",
        api_key => 'mock-copilot-token-' . time(),
    );

    my $user_data = $user_api->fetch_user('mock-github-token');
    if ($user_data) {
        ok($user_data->{login}, 'User API returns login');
        is($user_data->{login}, 'mock-user', 'User API returns correct login');
        note "User: $user_data->{login}";
    } else {
        fail('User API fetch failed');
    }
}

# Test 4: Header/version assertions (source-level)
{
    my $auth_src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/GitHubAuth.pm' or die; my $c = <$fh>; $c };

    like($auth_src, qr/use CLIO::Core::Defaults/,
        'GitHubAuth imports Defaults module');

    my $defaults_src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/Defaults.pm' or die; my $c = <$fh>; $c };
    like($defaults_src, qr/COPILOT_USER_API_VERSION.*2025-04-01/,
        'Defaults.pm defines COPILOT_USER_API_VERSION as 2025-04-01');
    like($defaults_src, qr/COPILOT_API_VERSION.*2026-01-09/,
        'Defaults.pm defines COPILOT_API_VERSION as 2026-01-09');

    like($auth_src, qr/COPILOT_USER_API_VERSION/,
        'GitHubAuth uses COPILOT_USER_API_VERSION for token exchange');

    my $user_api_src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/CopilotUserAPI.pm' or die; my $c = <$fh>; $c };
    like($user_api_src, qr/COPILOT_USER_API_VERSION/,
        'CopilotUserAPI uses COPILOT_USER_API_VERSION for user endpoint');
    unlike($user_api_src, qr/X-GitHub-Api-Version.*COPILOT_API_VERSION/,
        'CopilotUserAPI does not use COPILOT_API_VERSION for user endpoint');
}

# Test 5: Chat completions headers in APIManager
{
    my $api_src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/APIManager.pm' or die; my $c = <$fh>; $c };

    # APIManager should use COPILOT_API_VERSION for CAPI endpoints
    like($api_src, qr/COPILOT_API_VERSION/,
        'APIManager uses COPILOT_API_VERSION for CAPI headers');

    # APIManager should also use COPILOT_USER_API_VERSION where needed
    like($api_src, qr/COPILOT_EDITOR_VERSION.*COPILOT_PLUGIN_VERSION.*COPILOT_LS_VERSION/ms,
        'APIManager sends all Copilot editor identification headers');
}

# Test 6: Custom provider integration with Copilot
{
    require CLIO::Core::Config;
    my $config = CLIO::Core::Config->new(isolated => 1);

    # Add a custom provider pointing to our mock server
    $config->add_custom_provider('copilot_mock', 'github_copilot', 'mock-token', "http://127.0.0.1:$port");

    ok($config->is_custom_provider('copilot_mock'),
        'Custom Copilot provider registered');
    is($config->resolve_custom_provider('copilot_mock'), 'github_copilot',
        'Custom provider resolves to github_copilot base type');
    is($config->get_provider_base('copilot_mock'), "http://127.0.0.1:$port",
        'Custom provider stores mock server base URL');

    # Verify build_endpoint_config resolves custom provider
    require CLIO::Providers;
    my $ep = CLIO::Providers::build_endpoint_config('copilot_mock', 'mock-token', $config);
    ok($ep->{requires_copilot_headers},
        'build_endpoint_config resolves custom Copilot provider');

    # Cleanup
    $config->remove_custom_provider('copilot_mock');
}

# Cleanup
kill(9, $pid);
waitpid($pid, 0);

done_testing();
