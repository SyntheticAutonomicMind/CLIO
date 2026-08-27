#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Regression test for tool result truncation.
#
# ToolResultStore.processToolResult persists results larger than
# MAX_INLINE_SIZE (16KB) and returns a marker with preview. Results
# <= 16KB are returned inline (the marker would be a regression).
#
# The truncation must produce a marker that:
#   1. Contains a [TOOL_RESULT_STORED: ...] marker with toolCallId
#   2. Includes a preview of the FIRST $PREVIEW_SIZE bytes
#   3. Tells the model how to read the rest with read_tool_result
#   4. Does NOT include the full content inline
#
# Fallback path: when persistence fails (e.g. disk full), the result
# is truncated to MAX_INLINE_SIZE inline with a [TRUNCATED: ...] marker.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use File::Temp;
use CLIO::Session::ToolResultStore;

my $tmpdir = File::Temp::tempdir(CLEANUP => 1);
my $session_id = 'test-session-123';

subtest 'small results (<= MAX_INLINE_SIZE) returned inline without marker' => sub {
    my $store = CLIO::Session::ToolResultStore->new(
        sessions_dir => $tmpdir,
        debug => 0,
    );
    my $content = 'x' x 1024;  # 1KB, well under MAX_INLINE_SIZE (16KB)
    my $result = $store->processToolResult('tc_small', $content, $session_id);
    ok($result, 'result returned');
    ok(!$result->{persisted}, 'small result NOT persisted');
    is($result->{content}, $content, 'small result returned inline verbatim');
    unlike($result->{content}, qr/TOOL_RESULT_STORED/,
        'inline content does NOT contain TOOL_RESULT_STORED marker');
};

subtest 'large results (> MAX_INLINE_SIZE) persisted with preview marker' => sub {
    my $store = CLIO::Session::ToolResultStore->new(
        sessions_dir => $tmpdir,
        debug => 0,
    );
    my $content = 'y' x 50000;  # 50KB, well over MAX_INLINE_SIZE (16KB)
    my $result = $store->processToolResult('tc_large', $content, $session_id);
    ok($result, 'result returned');
    ok($result->{persisted}, 'large result persisted');
    like($result->{content}, qr/TOOL_RESULT_STORED/,
        'persisted content contains TOOL_RESULT_STORED marker');
    like($result->{content}, qr/toolCallId=tc_large/,
        'marker includes toolCallId');
    like($result->{content}, qr/read_tool_result/,
        'marker tells model how to read the rest');
    # Preview is the first 16KB. The original content was 'y' * 50000.
    # The preview shown should be 16384 'y' chars.
    like($result->{content}, qr/y{1000}/,
        'preview contains the original content (first chunk visible)');
    # The full content is NOT inline.
    unlike($result->{content}, qr/y{30000}/,
        'full content NOT inline (only preview)');

    # metadata captured
    ok($result->{meta}, 'meta captured');
    is($result->{meta}{tool_call_id}, 'tc_large', 'meta has tool_call_id');
    is($result->{meta}{total_length}, 50049, 'meta has total_length (includes wrapping)');
};

subtest 'persisted result retrievable via retrieveChunk' => sub {
    my $store = CLIO::Session::ToolResultStore->new(
        sessions_dir => $tmpdir,
        debug => 0,
    );
    my $content = 'z' x 30000;
    my $result = $store->processToolResult('tc_retrieve', $content, $session_id);
    ok($result->{persisted}, 'persisted');

    # Retrieve first chunk
    my $chunk = $store->retrieveChunk('tc_retrieve', $session_id, 0, 8192);
    # retrieveChunk returns a hashref with content/metadata; older API
    # returned the content string. The metadata includes the actual
    # chunk size; just verify retrieval succeeded.
    ok(defined $chunk, 'chunk retrieved');
    my $content_field = ref($chunk) eq 'HASH' ? $chunk->{content} : $chunk;
    ok(defined $content_field && length($content_field) > 0,
        'retrieved chunk has content');
    like($content_field, qr/^z+/, 'chunk starts with original z content');
};

subtest 'persisted result with markers and line-wrapping preserved' => sub {
    my $store = CLIO::Session::ToolResultStore->new(
        sessions_dir => $tmpdir,
        debug => 0,
    );
    # Build content with > 2000 char lines (triggers the long-line split)
    my $long_line = 'a' x 3000;
    my $content = "$long_line\nshort line\n";
    # Bump above MAX_INLINE_SIZE so it's persisted
    $content .= 'b' x 20000;

    my $result = $store->processToolResult('tc_lines', $content, $session_id);
    ok($result->{persisted}, 'persisted with long lines');

    # The preview should show the long line as content but the
    # persisted file on disk should have the line broken. We don't
    # inspect the on-disk layout here - that's covered in the existing
    # ToolResultStore tests. Just verify the marker is correct.
    like($result->{content}, qr/TOOL_RESULT_STORED/, 'marker present');
};

done_testing();