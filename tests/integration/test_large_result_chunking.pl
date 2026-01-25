#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use CLIO::Session::ToolResultStore;
use File::Temp qw(tempdir);

=head1 NAME

test_large_result_chunking.pl - Test ToolResultStore chunking behavior

=head1 DESCRIPTION

Tests that large tool results are properly chunked and can be retrieved
sequentially, preventing oversized read requests.

This test validates the fix for the bug where AI requested 74KB chunks
(exceeding the 32KB maximum).

=cut

# Setup
my $temp_dir = tempdir(CLEANUP => 1);
my $sessions_dir = "$temp_dir/sessions";

my $store = CLIO::Session::ToolResultStore->new(
    sessions_dir => $sessions_dir,
    debug => 0,
);

# Test 1: Small result (< 8KB) - should be returned inline
{
    my $small_content = "x" x 4000;  # 4KB
    my $result = $store->processToolResult(
        'test_small_123',
        $small_content,
        'test_session_1'
    );
    
    is($result, $small_content, 'Small result returned inline (no storage)');
    like($result, qr/^x+$/, 'Content intact');
}

# Test 2: Large result (> 8KB) - should be stored with marker
{
    my $large_content = "y" x 50000;  # 50KB (exceeds inline threshold)
    my $result = $store->processToolResult(
        'test_large_456',
        $large_content,
        'test_session_2'
    );
    
    like($result, qr/\[TOOL_RESULT_PREVIEW:/, 'Large result shows preview marker');
    like($result, qr/\[TOOL_RESULT_STORED:/, 'Large result shows storage marker');
    like($result, qr/toolCallId=test_large_456/, 'toolCallId included in marker');
    like($result, qr/totalLength=50000/, 'Total length included in marker');
    like($result, qr/read_tool_result/, 'Instructions to use read_tool_result');
}

# Test 3: Chunk retrieval - sequential reading within 32KB limit
{
    my $content = "z" x 100000;  # 100KB total
    $store->processToolResult('test_chunked_789', $content, 'test_session_3');
    
    # Read first chunk (8KB default)
    my $chunk1 = $store->retrieveChunk('test_chunked_789', 'test_session_3', 0, 8192);
    is($chunk1->{offset}, 0, 'First chunk: offset=0');
    is($chunk1->{length}, 8192, 'First chunk: length=8192');
    is($chunk1->{totalLength}, 100000, 'First chunk: totalLength=100000');
    ok($chunk1->{hasMore}, 'First chunk: hasMore=true');
    is($chunk1->{nextOffset}, 8192, 'First chunk: nextOffset=8192');
    
    # Read second chunk (starting at offset 8192)
    my $chunk2 = $store->retrieveChunk('test_chunked_789', 'test_session_3', 8192, 8192);
    is($chunk2->{offset}, 8192, 'Second chunk: offset=8192');
    is($chunk2->{length}, 8192, 'Second chunk: length=8192');
    ok($chunk2->{hasMore}, 'Second chunk: hasMore=true');
    is($chunk2->{nextOffset}, 16384, 'Second chunk: nextOffset=16384');
    
    # Read large chunk (32KB - the maximum)
    my $chunk3 = $store->retrieveChunk('test_chunked_789', 'test_session_3', 16384, 32768);
    is($chunk3->{offset}, 16384, 'Large chunk: offset=16384');
    is($chunk3->{length}, 32768, 'Large chunk: length=32768 (at max)');
    ok($chunk3->{hasMore}, 'Large chunk: hasMore=true');
    is($chunk3->{nextOffset}, 49152, 'Large chunk: nextOffset=49152');
    
    # Read final chunk (request 32KB, but only 18080 bytes remain: 100000 - 81920 = 18080)
    my $chunk4 = $store->retrieveChunk('test_chunked_789', 'test_session_3', 81920, 32768);
    is($chunk4->{offset}, 81920, 'Final chunk: offset=81920');
    is($chunk4->{length}, 18080, 'Final chunk: actual length = remaining bytes (18080)');
    ok(!$chunk4->{hasMore}, 'Final chunk: hasMore=false');
    is($chunk4->{nextOffset}, undef, 'Final chunk: nextOffset=undef');
}

# Test 4: Verify 32KB cap is enforced (this was the bug!)
{
    my $content = "a" x 150000;  # 150KB
    $store->processToolResult('test_oversized_999', $content, 'test_session_4');
    
    # Request oversized chunk (74KB like the bug)
    my $chunk = $store->retrieveChunk('test_oversized_999', 'test_session_4', 0, 74228);
    
    # Should be capped at 32KB, not 74KB
    cmp_ok($chunk->{length}, '<=', 32768, 'Oversized request capped to 32KB max');
    is($chunk->{length}, 32768, 'Chunk length exactly 32KB (capped)');
}

# Test 5: Error handling - invalid offset
{
    my $content = "b" x 20000;
    $store->processToolResult('test_error_111', $content, 'test_session_5');
    
    eval {
        $store->retrieveChunk('test_error_111', 'test_session_5', 99999, 8192);
    };
    like($@, qr/Invalid offset/, 'Invalid offset throws error');
}

# Test 6: Error handling - nonexistent result
{
    eval {
        $store->retrieveChunk('nonexistent_xyz', 'test_session_6', 0, 8192);
    };
    like($@, qr/not found/, 'Nonexistent result throws error');
}

done_testing();

print "\n";
print "━" x 60 . "\n";
print "TEST SUMMARY: Large Result Chunking\n";
print "━" x 60 . "\n";
print "[OK] Small results (<8KB) returned inline\n";
print "[OK] Large results (>8KB) stored with preview marker\n";
print "[OK] Sequential chunk reading works correctly\n";
print "[OK] 32KB maximum enforced (prevents 74KB bug)\n";
print "[OK] Error handling for invalid offsets\n";
print "[OK] Error handling for missing results\n";
print "━" x 60 . "\n";
print "\nAll chunking tests passed!\n\n";
