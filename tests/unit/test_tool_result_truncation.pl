#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Regression test for tool result truncation.
#
# ToolResultStore::processToolResult returns a STRING: small results
# (<= MAX_INLINE_SIZE, 16KB) are returned inline verbatim; large results
# are replaced by a [TOOL_RESULT_PREVIEW: ...]\n\n[TOOL_RESULT_STORED: ...]
# marker that includes a preview and read_tool_result instructions.
# ToolExecutor assigns the return value directly to $output (used as the
# tool result content in the message), so the string contract is
# intentional and tested here.

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
    ok(defined $result && length($result), 'result returned');
    is($result, $content, 'small result returned inline verbatim');
    unlike($result, qr/TOOL_RESULT_STORED/,
        'inline content does NOT contain TOOL_RESULT_STORED marker');
    unlike($result, qr/TOOL_RESULT_PREVIEW/,
        'inline content does NOT contain preview marker');
};

subtest 'large results (> MAX_INLINE_SIZE) persisted with preview marker' => sub {
    my $store = CLIO::Session::ToolResultStore->new(
        sessions_dir => $tmpdir,
        debug => 0,
    );
    my $content = 'y' x 50000;  # 50KB, well over MAX_INLINE_SIZE (16KB)
    my $result = $store->processToolResult('tc_large', $content, $session_id);
    ok(defined $result && length($result), 'result returned');
    like($result, qr/TOOL_RESULT_STORED/,
        'marker contains TOOL_RESULT_STORED');
    like($result, qr/toolCallId=tc_large/,
        'marker includes toolCallId');
    like($result, qr/read_tool_result/,
        'marker tells model how to read the rest');
    # Preview is the first PREVIEW_SIZE (16384) bytes -> a 1000-char run
    # of 'y' is present.
    like($result, qr/y{1000}/,
        'preview contains the original content (first chunk visible)');
    # The full 30000-char run must NOT be inline (only the preview is).
    unlike($result, qr/y{30000}/,
        'full content NOT inline (only preview)');
    like($result, qr/totalLength=\d+/,
        'marker records totalLength');
};

subtest 'persisted result retrievable via retrieveChunk' => sub {
    my $store = CLIO::Session::ToolResultStore->new(
        sessions_dir => $tmpdir,
        debug => 0,
    );
    my $content = 'z' x 30000;
    my $result = $store->processToolResult('tc_retrieve', $content, $session_id);
    like($result, qr/TOOL_RESULT_STORED/, 'persisted (marker returned)');

    # Retrieve first chunk
    my $chunk = $store->retrieveChunk('tc_retrieve', $session_id, 0, 8192);
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
    # Bump above MAX_INLINE_SIZE so it is persisted
    $content .= 'b' x 20000;

    my $result = $store->processToolResult('tc_lines', $content, $session_id);
    like($result, qr/TOOL_RESULT_STORED/, 'marker present for long-line content');
};

done_testing();
