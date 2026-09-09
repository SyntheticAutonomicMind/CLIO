#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# Mock GitHub Copilot API server for end-to-end testing without an active account.
#
# Simulates: POST /copilot_internal/v2/token  (token exchange)
#            GET  /copilot_internal/user      (user info)
#            GET  /models                     (models list)
#            POST /chat/completions           (chat)
#
# Usage: perl tests/manual/mock_copilot_server.pl [port] [--delay N]
#   port    - Local port (default 18443)
#   --delay - Simulated latency in seconds (default 0.01)
#
# The server listens on http://127.0.0.1:<port> and speaks the GitHub Copilot
# CAPI protocol. Point CLIO's api_base at http://127.0.0.1:<port> to test.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../..";
use CLIO::Util::JSON qw(encode_json decode_json safe_decode_json);
use Time::HiRes qw(sleep);
use Socket qw(SO_REUSEADDR);
use IO::Socket::INET;

my $port = shift @ARGV // 18443;
my $delay = 0.01;
while (@ARGV) {
    my $arg = shift @ARGV;
    if ($arg eq '--delay' && @ARGV) {
        $delay = shift @ARGV;
    }
}

# Pre-built mock data
my $MOCK_TOKEN = 'mock-copilot-token-' . time();
my $MOCK_MODELS = {
    'object' => 'list',
    'data' => [
        {
            'name' => 'claude-sonnet-4.6',
            'id' => 'claude-sonnet-4.6',
            'vendor' => 'Anthropic',
            'family' => 'claude-sonnet',
            'category' => 'versatile',
            'supports_tools' => 1,
            'supports_streaming' => 1,
            'supports_vision' => 1,
            'supports_adaptive_thinking' => 1,
            'supports_enabled_thinking' => 1,
            'max_prompt_tokens' => 200000,
            'max_output_tokens' => 8192,
            'max_context_window_tokens' => 200000,
            'max_thinking_budget' => 8192,
            'min_thinking_budget' => 1024,
            'supported_endpoints' => ['/chat/completions', '/responses'],
        },
        {
            'name' => 'gpt-5.4',
            'id' => 'gpt-5.4',
            'vendor' => 'OpenAI',
            'family' => 'gpt-5',
            'category' => 'versatile',
            'supports_tools' => 1,
            'supports_streaming' => 1,
            'supports_vision' => 1,
            'supports_adaptive_thinking' => 1,
            'max_prompt_tokens' => 128000,
            'max_output_tokens' => 16384,
            'max_context_window_tokens' => 200000,
            'max_thinking_budget' => 10000,
            'supported_endpoints' => ['/chat/completions', '/responses'],
        },
        {
            'name' => 'gpt-4o-mini',
            'id' => 'gpt-4o-mini',
            'vendor' => 'OpenAI',
            'family' => 'gpt-4o',
            'category' => 'lightweight',
            'supports_tools' => 1,
            'supports_streaming' => 1,
            'supports_vision' => 1,
            'max_prompt_tokens' => 128000,
            'max_output_tokens' => 16384,
            'max_context_window_tokens' => 128000,
            'supported_endpoints' => ['/chat/completions'],
        },
    ],
};

my $MOCK_USER = {
    'login' => 'mock-user',
    'id' => 12345,
    'name' => 'Mock User',
    'email' => 'mock@example.com',
    'avatar_url' => 'https://avatars.githubusercontent.com/u/12345',
    'created_at' => '2020-01-01T00:00:00Z',
};

# Build a raw TCP server (no HTTP::Server::Simple dependency)
my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => $port,
    Proto     => 'tcp',
    Listen    => 5,
    ReuseAddr => 1,
) or die "Cannot listen on 127.0.0.1:$port: $!\n";

print STDERR "Mock Copilot API server listening on http://127.0.0.1:$port\n";
print STDERR "Mock token: $MOCK_TOKEN\n";
print STDERR "Delay: ${delay}s\n";

while (my $client = $server->accept()) {
    # Fork to handle each connection
    my $pid = fork();
    if ($pid == 0) {
        # Child process
        $client->autoflush(1);

        # Read the HTTP request
        my $request = '';
        my $header_end = 0;
        while (my $line = <$client>) {
            $request .= $line;
            if ($line =~ /^\r?\n$/) {
                $header_end = 1;
                last;
            }
        }

        # If there's a body, read it (Content-Length)
        if ($request =~ /Content-Length:\s*(\d+)/i) {
            my $content_length = $1;
            my $body = '';
            my $remaining = $content_length;
            while ($remaining > 0) {
                my $buf;
                my $n = sysread($client, $buf, $remaining);
                last unless $n;
                $body .= $buf;
                $remaining -= $n;
            }
            $request .= $body;
        }

        # Simulate latency
        sleep($delay) if $delay > 0;

        # Parse request
        my ($method, $path, $http_version) = $request =~ /^(\S+)\s+(\S+)\s+(HTTP\/\S+)/;
        $path //= '';
        $method //= 'GET';

        # Verify auth header
        my ($auth_header) = $request =~ /^Authorization:\s*(.+)$/im;
        $auth_header //= '';

        # Check for required headers
        my $has_editor_version = $request =~ /^Editor-Version:/im;
        my $has_api_version = $request =~ /^X-GitHub-Api-Version:/im;

        my $response_status = 200;
        my $response_body = '';
        my $content_type = 'application/json';
        my $is_streaming = 0;

        # Route the request
        if ($method eq 'GET' && $path =~ m{/copilot_internal/v2/token$}) {
            # Token exchange endpoint - should accept any PAT
            if ($auth_header =~ /^(?:token|bearer)\s+(.+)/i) {
                my $pat = $1;
                $response_body = encode_json({
                    'token' => $MOCK_TOKEN,
                    'expires_at' => time() + 86400,
                    'refresh_token' => 'mock-refresh-token',
                    'refresh_in' => 3600,
                });
            } else {
                $response_status = 401;
                $response_body = encode_json({ 'message' => 'Bad credentials', 'code' => 'bad_credentials' });
            }
        }
        elsif ($method eq 'GET' && $path =~ m{/copilot_internal/user$}) {
            # User info endpoint
            $response_body = encode_json($MOCK_USER);
        }
        elsif ($method eq 'GET' && $path =~ m{/models$}) {
            # Models endpoint
            $response_body = encode_json($MOCK_MODELS);
        }
        elsif ($method eq 'POST' && $path =~ m{/chat/completions$}) {
            # Chat completions endpoint
            # Parse the request body
            my $body = ($request =~ /\{.*\}/s) ? $& : '';
            my $chat_req = eval { decode_json($body) };
            $chat_req //= {};

            my $stream = $chat_req->{stream} // 0;
            my $is_responses = $path =~ m{/responses$};

            if ($stream) {
                $is_streaming = 1;
                $content_type = 'text/event-stream';
                my $response_text = "Mock response from GitHub Copilot";
                if ($chat_req->{messages}) {
                    $response_text .= " (messages: " . scalar(@{$chat_req->{messages}}) . ")";
                }
                if ($chat_req->{tools}) {
                    $response_text .= " (tools: " . scalar(@{$chat_req->{tools}}) . ")";
                }
                $response_text .= "\n[Mock server reply]";

                # Build SSE stream
                $response_body = '';
                # First chunk: role=dimension
                $response_body .= "data: " . encode_json({
                    'id' => 'chatcmpletion-' . time(),
                    'object' => 'chat.completion.chunk',
                    'created' => time(),
                    'model' => $chat_req->{model} || 'claude-sonnet-4.6',
                    'choices' => [{
                        'index' => 0,
                        'delta' => { 'content' => '', 'role' => 'assistant' },
                    }],
                }) . "\n\n";

                # Content chunks
                for my $i (0..3) {
                    $response_body .= "data: " . encode_json({
                        'id' => 'chatcmpletion-' . time(),
                        'object' => 'chat.completion.chunk',
                        'created' => time(),
                        'model' => $chat_req->{model} || 'claude-sonnet-4.6',
                        'choices' => [{
                            'index' => 0,
                            'delta' => { 'content' => substr($response_text, $i*1, 1) },
                        }],
                    }) . "\n\n";
                }

                # Final chunk with finish_reason
                $response_body .= "data: " . encode_json({
                    'id' => 'chatcmpletion-' . time(),
                    'object' => 'chat.completion.chunk',
                    'created' => time(),
                    'model' => $chat_req->{model} || 'claude-sonnet-4.6',
                    'choices' => [{
                        'index' => 0,
                        'finish_reason' => 'stop',
                        'delta' => {},
                    }],
                }) . "\n\n";
                $response_body .= "data: [DONE]\n\n";
            } else {
                # Non-streaming response
                my $response_text = "Mock response from GitHub Copilot";
                if ($chat_req->{messages}) {
                    $response_text .= " (messages: " . scalar(@{$chat_req->{messages}}) . ")";
                }
                if ($chat_req->{tools}) {
                    $response_text .= " (tools: " . scalar(@{$chat_req->{tools}}) . ")";
                }
                $response_text .= "\n[Mock server reply]";

                $response_body = encode_json({
                    'id' => 'chatcmpletion-' . time(),
                    'object' => 'chat.completion',
                    'created' => time(),
                    'model' => $chat_req->{model} || 'claude-sonnet-4.6',
                    'choices' => [{
                        'index' => 0,
                        'message' => {
                            'role' => 'assistant',
                            'content' => $response_text,
                        },
                        'finish_reason' => 'stop',
                    }],
                    'usage' => {
                        'prompt_tokens' => 10,
                        'completion_tokens' => 10,
                        'total_tokens' => 20,
                    },
                });
            }
        }
        elsif ($method eq 'POST' && $path =~ m{/responses$}) {
            # Responses API endpoint (for newer models)
            my $body = ($request =~ /\{.*\}/s) ? $& : '';
            my $chat_req = eval { decode_json($body) };
            $chat_req //= {};

            my $response_text = "Mock response from GitHub Copilot (Responses API)";

            $response_body = encode_json({
                'id' => 'resp-' . time(),
                'object' => 'response',
                'created' => time(),
                'model' => $chat_req->{model} || 'gpt-5.4',
                'output' => [{
                    'type' => 'message',
                    'role' => 'assistant',
                    'content' => [{
                        'type' => 'output_text',
                        'text' => $response_text,
                    }],
                }],
                'usage' => {
                    'input_tokens' => 10,
                    'output_tokens' => 10,
                    'total_tokens' => 20,
                },
            });
        }
        else {
            $response_status = 404;
            $response_body = encode_json({ 'message' => 'Not Found' });
        }

        # Send the response
        if ($is_streaming) {
            print $client "HTTP/1.1 $response_status OK\r\n";
            print $client "Content-Type: $content_type\r\n";
            print $client "Cache-Control: no-cache\r\n";
            print $client "Connection: keep-alive\r\n";
            print $client "Access-Control-Allow-Origin: *\r\n";
            print $client "\r\n";
            print $client $response_body;
        } else {
            my $cl = length($response_body);
            print $client "HTTP/1.1 $response_status OK\r\n";
            print $client "Content-Type: $content_type\r\n";
            print $client "Content-Length: $cl\r\n";
            print $client "Connection: close\r\n";
            print $client "Access-Control-Allow-Origin: *\r\n";
            print $client "\r\n";
            print $client $response_body;
        }

        close($client);
        exit(0);
    }
    elsif ($pid > 0) {
        # Parent process
        close($client);
        # Reap zombie children
        use POSIX ":sys_wait_h";
        while (waitpid(-1, WNOHANG) > 0) {}
    } else {
        # Fork failed
        close($client);
    }
}

close($server);
