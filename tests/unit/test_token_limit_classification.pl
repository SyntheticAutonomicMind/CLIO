#!/usr/bin/env perl
# Regression test for the CachyLLama bug (2026-08-20):
#   - llama.cpp returned 400 "request (163014 tokens) exceeds the available
#     context size (131072 tokens)" with error_obj.n_ctx=131072 and
#     error_obj.n_prompt_tokens=163014.
#   - The previous regex (model_max_prompt_tokens_exceeded|context_length_exceeded|prompt token count.*exceeds)
#     did NOT match llama.cpp's wording, so the response fell through to the
#     generic "bad_request" handler. trim_for_token_limit was never called,
#     the retry loop spun 3x, then bailed.
#
# This test verifies:
#   1. ResponseHandler classifies llama.cpp's wording as token_limit_exceeded.
#   2. ResponseHandler extracts n_ctx and n_prompt_tokens from error_obj and
#      forwards them on the result.
#   3. ResponseHandler keeps recognizing the older OpenAI/Anthropic patterns.

use strict;
use warnings;
use lib './lib';
use Test::More;

# Mock HTTP::Response object (matches the pattern in test_response_handler.pl)
package MockResponse;
sub new {
    my ($class, %opts) = @_;
    return bless {
        code        => $opts{code}        // 200,
        status_line => $opts{status_line} // "$opts{code} Error",
        content     => defined $opts{content} ? $opts{content} : '{}',
        message     => $opts{message}     // '',
    }, $class;
}
sub code { $_[0]->{code} }
sub status_line { $_[0]->{status_line} }
sub decoded_content { $_[0]->{content} }
sub is_success { $_[0]->{code} >= 200 && $_[0]->{code} < 300 }
sub header { return undef }
sub headers { return $_[0]->{headers} //= bless {}, 'MockHeaders' }
sub message { $_[0]->{message} }

package main;

use CLIO::Core::API::ResponseHandler;

subtest 'llama.cpp exceeds_context_size is classified as token_limit_exceeded' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"code":400,"message":"request (163014 tokens) exceeds the available context size (131072 tokens), try increasing it","type":"exceed_context_size_error","n_prompt_tokens":163014,"n_ctx":131072}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);

    ok($result->{retryable}, 'Token limit is retryable');
    is($result->{error_type}, 'token_limit_exceeded', 'Classified as token_limit_exceeded');
    is($result->{n_ctx}, 131072, 'n_ctx extracted from error_obj');
    is($result->{n_prompt_tokens}, 163014, 'n_prompt_tokens extracted from error_obj');
    like($result->{error}, qr/163014.*131072|131072.*163014/i,
        'User-facing error includes server-reported token counts');
};

subtest 'llama.cpp alt wording (context window full) is classified' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"context window is full","n_ctx":8192,"n_prompt_tokens":9123}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);

    is($result->{error_type}, 'token_limit_exceeded', 'context window is full -> token_limit_exceeded');
    is($result->{n_ctx}, 8192, 'n_ctx extracted');
    is($result->{n_prompt_tokens}, 9123, 'n_prompt_tokens extracted');
};

subtest 'OpenAI model_max_prompt_tokens_exceeded still recognized' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"model_max_prompt_tokens_exceeded","code":400}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);

    is($result->{error_type}, 'token_limit_exceeded', 'model_max_prompt_tokens_exceeded -> token_limit_exceeded');
    ok($result->{retryable}, 'still retryable');
};

subtest 'OpenAI Responses API context_length_exceeded still recognized' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"context_length_exceeded","code":400}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);

    is($result->{error_type}, 'token_limit_exceeded', 'context_length_exceeded -> token_limit_exceeded');
};

subtest 'OpenAI "prompt token count exceeds ..." still recognized' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"Prompt token count exceeds the limit"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);

    is($result->{error_type}, 'token_limit_exceeded', 'prompt token count exceeds -> token_limit_exceeded');
};

subtest 'Anthropic "prompt is too long" still recognized' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"prompt is too long"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);

    is($result->{error_type}, 'token_limit_exceeded', 'prompt is too long -> token_limit_exceeded');
};

subtest 'malformed JSON tool call NOT misclassified as token limit' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"Invalid JSON in tool call arguments"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);

    isnt($result->{error_type}, 'token_limit_exceeded', 'malformed JSON is NOT token_limit_exceeded');
    is($result->{error_type}, 'malformed_tool_json', 'Classified as malformed_tool_json');
};

subtest 'generic 400 (no recognizable pattern) is bad_request, not token_limit' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"Some unrecognized validation error"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);

    isnt($result->{error_type}, 'token_limit_exceeded', 'generic 400 is NOT token_limit_exceeded');
    is($result->{error_type}, 'bad_request', 'Falls through to bad_request');
};

subtest 'alt key names (context_size, input_tokens) recognized' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"request exceeds the available context size","context_size":65536,"input_tokens":70000}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);

    is($result->{error_type}, 'token_limit_exceeded', 'classified');
    is($result->{n_ctx}, 65536, 'context_size accepted as n_ctx');
    is($result->{n_prompt_tokens}, 70000, 'input_tokens accepted as n_prompt_tokens');
};

subtest 'no token counts in error_obj still classifies but without n_ctx' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"request exceeds the available context size"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);

    is($result->{error_type}, 'token_limit_exceeded', 'still classified');
    ok(!defined $result->{n_ctx}, 'n_ctx undefined (not in error_obj)');
    ok(!defined $result->{n_prompt_tokens}, 'n_prompt_tokens undefined');
};

done_testing();
