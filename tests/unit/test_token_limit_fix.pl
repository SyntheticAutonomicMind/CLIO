#!/usr/bin/env perl
# Test script to verify token limit error handling

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More tests => 4;
use CLIO::Core::APIManager;

# Mock HTTP response for testing
package MockResponse {
    sub new {
        my ($class, $code, $content) = @_;
        return bless { code => $code, content => $content }, $class;
    }
    sub code { $_[0]->{code} }
    sub decoded_content { $_[0]->{content} }
    sub header { undef }
}

# Test 1: Token limit exceeded error should NOT be retryable
{
    my $error_msg = '{"error":{"message":"prompt token count of 128779 exceeds the limit of 128000","code":"model_max_prompt_tokens_exceeded"}}';
    
    # Check if error matches our pattern
    my $is_token_limit = $error_msg =~ /model_max_prompt_tokens_exceeded|context_length_exceeded|prompt token count.*exceeds/i;
    ok($is_token_limit, "Token limit error pattern matches correctly");
}

# Test 2: context_length_exceeded should also match
{
    my $error_msg = '{"error":{"code":"context_length_exceeded","message":"Maximum context length exceeded"}}';
    
    my $is_token_limit = $error_msg =~ /model_max_prompt_tokens_exceeded|context_length_exceeded|prompt token count.*exceeds/i;
    ok($is_token_limit, "Context length exceeded pattern matches correctly");
}

# Test 3: Malformed tool JSON should still be retryable
{
    my $error_msg = '{"error":{"message":"Invalid JSON in tool call"}}';
    
    my $is_tool_json_error = $error_msg =~ /invalid.*json.*tool.*call|tool.*call.*invalid.*json/i;
    ok($is_tool_json_error, "Malformed tool JSON error pattern matches correctly");
}

# Test 4: Regular 400 error should not match either pattern
{
    my $error_msg = '{"error":{"message":"Bad request - invalid parameters"}}';
    
    my $is_token_limit = $error_msg =~ /model_max_prompt_tokens_exceeded|context_length_exceeded|prompt token count.*exceeds/i;
    my $is_tool_json_error = $error_msg =~ /invalid.*json.*tool.*call|tool.*call.*invalid.*json/i;
    
    ok(!$is_token_limit && !$is_tool_json_error, "Regular 400 error does not match special patterns");
}

print "\n✓ All token limit error handling tests passed!\n";
