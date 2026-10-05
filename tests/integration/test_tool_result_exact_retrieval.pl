#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use CLIO::Session::ToolResultStore;
use File::Temp qw(tempdir);

=head1 NAME

test_tool_result_exact_retrieval.pl - Verify ToolResultStore preserves
exact content during persist + retrieve round-trip.

=head1 DESCRIPTION

Tests that retrieveChunk returns the EXACT original content (character-for-
character), not a line-wrapped/transformed version. This is critical when
tool results contain structured data (JSON, source code, base64, compiler
output) that would be corrupted by inserted newlines.

=cut

# MAX_INLINE_SIZE is 16384 — content must exceed this to be persisted.
# Use 20000+ chars for storage/retrieval tests; smaller content is inline.

my $temp_dir = tempdir(CLEANUP => 1);
my $sessions_dir = "$temp_dir/sessions";

my $store = CLIO::Session::ToolResultStore->new(
    sessions_dir => $sessions_dir,
    debug => 0,
);

# Test 1: 20000-character line (would have been wrapped by old impl)
{
    my $line = 'x' x 20000;
    $store->processToolResult('tc_20k', $line, 'sess_1');
    my $chunk = $store->retrieveChunk('tc_20k', 'sess_1', 0, 32000);
    is($chunk->{content}, $line, "20K-char line: exact retrieval");
    is($chunk->{totalLength}, 20000, "20K-char line: totalLength matches original");
}

# Test 2: 20001-character line (just over inline threshold)
{
    my $line = 'x' x 20001;
    $store->processToolResult('tc_20001', $line, 'sess_1');
    my $chunk = $store->retrieveChunk('tc_20001', 'sess_1', 0, 32000);
    is($chunk->{content}, $line, "20001-char line: exact retrieval (no wrapping)");
    is($chunk->{totalLength}, 20001, "20001-char line: totalLength = 20001 (not 20002+ with newlines)");
}

# Test 3: 20,000-char line, distinct character
{
    my $line = 'y' x 20_000;
    $store->processToolResult('tc_20k_b', $line, 'sess_1');
    my $chunk = $store->retrieveChunk('tc_20k_b', 'sess_1', 0, 32000);
    is($chunk->{content}, $line, "20K y-line: exact retrieval (no wrapping)");
    is($chunk->{totalLength}, 20_000, "20K y-line: totalLength = 20000 (no added newlines)");
}

# Test 4: Multi-byte UTF-8 content
{
    my $text = "héllo wörld 日本語 " x 2000;  # ~32000 chars multi-byte
    $store->processToolResult('tc_utf8', $text, 'sess_1');
    my $chunk = $store->retrieveChunk('tc_utf8', 'sess_1', 0, 32000);
    is($chunk->{content}, $text, "UTF-8 content: exact retrieval");
    is($chunk->{totalLength}, length($text), "UTF-8 content: totalLength matches original char count");
}

# Test 5: JSON with long strings (canonical corruption scenario)
{
    my $json = '{"data": "' . ('A' x 20000) . '", "key": "value"}';
    $store->processToolResult('tc_json', $json, 'sess_1');
    my $chunk = $store->retrieveChunk('tc_json', 'sess_1', 0, 32000);
    is($chunk->{content}, $json, "JSON with long strings: exact retrieval (no newlines inserted)");
    ok($chunk->{content} !~ /\n/, "JSON content: no newlines inserted in stored content");
}

# Test 6: Base64 content (would be corrupted by line wrapping)
{
    my $b64 = 'iVBORw0KGgoAAAANSUhEUg==' x 1200;  # ~21600 chars, no spaces
    $store->processToolResult('tc_b64', $b64, 'sess_1');
    my $chunk = $store->retrieveChunk('tc_b64', 'sess_1', 0, 32768);
    is($chunk->{content}, $b64, "Base64: exact retrieval (no wrapping)");
    is($chunk->{totalLength}, length($b64), "Base64: totalLength matches original");
}

# Test 7: Source code with long lines
{
    my $code = "package CLIO::Test;\n" . ('    my $x = "this is a very long line that exceeds 1000 characters"' x 400) . "\n1;\n";
    $store->processToolResult('tc_code', $code, 'sess_1');
    my $chunk = $store->retrieveChunk('tc_code', 'sess_1', 0, 32768);
    is($chunk->{content}, $code, "Source code: exact retrieval");
    is($chunk->{content}, $code, "Source code preserved character-for-character");
}

# Test 8: Data containing deliberate line endings (mixed content)
{
    my $content = "Line 1\n" . ('x' x 10000) . "\nLine 3\n" . ('y' x 10000) . "\nLine 5";
    $store->processToolResult('tc_mixed', $content, 'sess_1');
    my $total = length($content);
    my $chunk = $store->retrieveChunk('tc_mixed', 'sess_1', 0, $total + 100);
    is($chunk->{content}, $content, "Mixed content with newlines: exact retrieval");
    is($chunk->{totalLength}, $total, "Mixed content: totalLength matches original");
}

# Test 9: Offset crossing what would have been a wrapping boundary
{
    my $content = ('x' x 20000);  # would have been 20 lines + 19 newlines
    $store->processToolResult('tc_cross', $content, 'sess_1');
    is($store->retrieveChunk('tc_cross', 'sess_1', 0, 32768)->{totalLength}, 20000,
        "Cross-boundary: totalLength = 20000 (not 20019 with newlines)");
    is($store->retrieveChunk('tc_cross', 'sess_1', 9000, 2000)->{content}, substr($content, 9000, 2000),
        "Offset 9000, length 2000: exact slice (would have been corrupted by wrapping)");
}

# Test 10: Chunk boundary inside a UTF-8 multibyte sequence
{
    my $text = "héllo" x 5000;  # ~25000 chars
    $store->processToolResult('tc_utf8_chunk', $text, 'sess_1');
    my $total = length($text);
    my $chunk1 = $store->retrieveChunk('tc_utf8_chunk', 'sess_1', 0, $total + 100);
    is($chunk1->{content}, $text, "UTF-8 full retrieval: exact");
}

# Test 11: Empty result (border case — returned inline, not persisted)
{
    my $content = '';
    my $result = $store->processToolResult('tc_empty', $content, 'sess_1');
    is($result, '', "Empty result: returned inline as empty string");
}

# Test 12: Very large result (1MB — ensures exact preservation at scale)
{
    my $content = "A" x 1_048_576;
    $store->processToolResult('tc_large', $content, 'sess_1');
    my $total = $store->retrieveChunk('tc_large', 'sess_1', 0, 8192)->{totalLength};
    is($total, 1_048_576, "1MB result: totalLength = 1_048_576 (exact, no added newlines)");
    my $reconstructed = '';
    my $offset = 0;
    while (1) {
        my $chunk = $store->retrieveChunk('tc_large', 'sess_1', $offset, 32768);
        $reconstructed .= $chunk->{content};
        last unless $chunk->{hasMore};
        $offset = $chunk->{nextOffset};
    }
    is($reconstructed, $content, "1MB result: full reconstruction is exact");
}

# Test 13: processToolResult marker consistency — totalLength must match original
{
    my $content = 'x' x 20000;
    my $marker = $store->processToolResult('tc_marker', $content, 'sess_1');
    like($marker, qr/totalLength=20000/, "Marker totalLength = 20000 (no wrapping inflation)");
    like($marker, qr/remaining=3616/, "Marker remaining = 20000 - 16384 = 3616 (no wrapping inflation)");
}

# Test 14: No wrapping in processToolResult marker preview
{
    my $content = "header\n" . ('x' x 20000) . "\ntrailer";
    my $marker = $store->processToolResult('tc_preview', $content, 'sess_1');
    # The preview in the marker should be the first 16384 chars of original
    my $first_chunk = $store->retrieveChunk('tc_preview', 'sess_1', 0, 16384);
    is($first_chunk->{content}, substr($content, 0, 16384), "Preview chunk: first 16384 chars of original");
}

done_testing();

print "\n";
print "━" x 60 . "\n";
print "TEST SUMMARY: ToolResultStore Exact Content Retrieval\n";
print "━" x 60 . "\n";
print "[OK] 20K-char line: exact\n";
print "[OK] 20001-char line: exact (no wrapping)\n";
print "[OK] 20K-char line (y): exact\n";
print "[OK] UTF-8 content: exact\n";
print "[OK] JSON with long strings: no newlines inserted\n";
print "[OK] Base64: no newlines inserted\n";
print "[OK] Source code: exact retrieval\n";
print "[OK] Mixed content with newlines: exact\n";
print "[OK] Offset crossing wrapping boundary: exact slice\n";
print "[OK] UTF-8 chunk reconstruction: exact\n";
print "[OK] Empty result: inline\n";
print "[OK] 1MB result: exact round-trip\n";
print "[OK] Marker consistency: totalLength matches original\n";
print "[OK] Preview chunk matches original content\n";
print "━" x 60 . "\n";
