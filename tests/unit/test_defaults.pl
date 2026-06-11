#!/usr/bin/env perl
use strict;
use warnings;
use lib './lib';
use Test::More tests => 8;

use CLIO::Core::Defaults qw(
    DEFAULT_CONTEXT_WINDOW
    DEFAULT_LOCAL_CONTEXT_WINDOW
    DEFAULT_MAX_OUTPUT_TOKENS
    DEFAULT_MAX_RESPONSE_TOKENS
    DEFAULT_BINARY_SAMPLE_SIZE
    DEFAULT_POST_TRIM_FLOOR
    TOOL_RESULT_MAX_CHUNK
    default_chunk_size
);

# Constants exist and have sensible values
ok(DEFAULT_CONTEXT_WINDOW > 0, "DEFAULT_CONTEXT_WINDOW is positive");
ok(DEFAULT_LOCAL_CONTEXT_WINDOW > 0, "DEFAULT_LOCAL_CONTEXT_WINDOW is positive");
ok(DEFAULT_LOCAL_CONTEXT_WINDOW < DEFAULT_CONTEXT_WINDOW, "local < cloud context");
ok(DEFAULT_MAX_OUTPUT_TOKENS > 0, "DEFAULT_MAX_OUTPUT_TOKENS is positive");

# Dynamic chunk sizing
is(default_chunk_size(32000), 16384, "32k context -> 16384 chunk (floor)");
my $mid = default_chunk_size(128000);
ok($mid > 8192 && $mid <= TOOL_RESULT_MAX_CHUNK, "128k context -> chunk between 8192 and max ($mid)");
is(default_chunk_size(500000), TOOL_RESULT_MAX_CHUNK, "500k context -> clamped to max");
is(default_chunk_size(), $mid, "default (no arg) uses DEFAULT_CONTEXT_WINDOW");

print "\n All Defaults tests passed!\n";
