#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Test: Persisted chunk pointers in thread_summary
#
# When a tool result exceeds the inline size limit and is persisted to
# disk by ToolResultStore, the summary pipeline (YaRN) must preserve
# the toolCallId so the model can re-read the chunk via read_tool_result
# after the original tool result is dropped by a trim cycle.
#
# Covers three code paths:
#   1. Structured _metadata.persisted_chunks (new, authoritative)
#   2. Legacy regex fallback over [TOOL_RESULT_STORED: toolCallId=X]
#      marker in content (for sessions persisted before the plumbing)
#   3. Round-trip: render a summary with chunks, re-parse as previous,
#      confirm chunks survive into the next summary.

use strict;
use warnings;
use utf8;
use lib './lib';
use CLIO::Memory::YaRN;

# Manual ok_test framework to avoid Test::More's "No tests run!" false
# positive when the test produces output but no plan is declared.

my $passed = 0;
my $failed = 0;
my $total = 0;

sub ok_test {
    my ($cond, $desc) = @_;
    $desc //= '';
    $total++;
    if ($cond) { $passed++; print "ok $total - $desc\n"; }
    else       { $failed++; print "not ok $total - $desc\n"; }
}

# Test 1: structured _metadata.persisted_chunks survives compression
{
    my $yarn = CLIO::Memory::YaRN->new();
    my @messages = (
        { role => 'user', content => 'Read big.pm' },
        { role => 'assistant', content => 'Reading.', tool_calls => [
            { id => 'call_abc', function => { name => 'file_operations', arguments => '{"operation":"read_file","path":"big.pm"}' } }
        ] },
        { role => 'tool', tool_call_id => 'call_abc',
          content => "[TOOL_RESULT_PREVIEW: ...]\n[content]\n[TOOL_RESULT_STORED: toolCallId=call_abc, totalLength=50000, remaining=33616 bytes]",
          _metadata => { persisted_chunks => [{
              tool_call_id => 'call_abc',
              source_path  => 'big.pm',
              source_tool  => 'file_operations',
              total_length => 50000,
              remaining    => 33616,
          }] } },
    );

    my $result = $yarn->compress_messages(\@messages, original_task => 'Read big.pm');
    my $content = $result->{content} || '';

    ok_test($content =~ /Persisted chunks/, 'Persisted chunks section present');
    ok_test($content =~ /call_abc/, 'toolCallId call_abc preserved');
    ok_test($content =~ /file_operations/, 'source tool name preserved');
    ok_test($content =~ /big\.pm/, 'source path preserved');
    ok_test($content =~ /50000/, 'total length preserved');
    ok_test($content =~ /33616/, 'remaining bytes preserved');
}

# Test 2: legacy regex fallback (no _metadata, only content marker)
{
    my $yarn = CLIO::Memory::YaRN->new();
    my @messages = (
        { role => 'user', content => 'Read legacy.pm' },
        { role => 'assistant', content => 'Reading.', tool_calls => [
            { id => 'call_legacy', function => { name => 'file_operations', arguments => '{"operation":"read_file","path":"legacy.pm"}' } }
        ] },
        { role => 'tool', tool_call_id => 'call_legacy',
          content => "[TOOL_RESULT_PREVIEW: ...]\n[content]\n[TOOL_RESULT_STORED: toolCallId=call_legacy, totalLength=40000, remaining=24000 bytes]" },
    );

    my $result = $yarn->compress_messages(\@messages, original_task => 'Read legacy.pm');
    my $content = $result->{content} || '';

    ok_test($content =~ /Persisted chunks/, 'Legacy: Persisted chunks section present');
    ok_test($content =~ /call_legacy/, 'Legacy: toolCallId call_legacy preserved');
    ok_test($content =~ /\[legacy:/, 'Legacy marker indicates regex detection');
}

# Test 3: persisted chunks survive round-trip via previous_summary
{
    my $yarn = CLIO::Memory::YaRN->new();

    # First compression produces a summary with persisted chunks
    my @first_messages = (
        { role => 'user', content => 'Read big.pm' },
        { role => 'assistant', content => 'Reading.', tool_calls => [
            { id => 'call_abc', function => { name => 'file_operations', arguments => '{"operation":"read_file","path":"big.pm"}' } }
        ] },
        { role => 'tool', tool_call_id => 'call_abc', content => 'preview',
          _metadata => { persisted_chunks => [{
              tool_call_id => 'call_abc', source_path => 'big.pm',
              source_tool => 'file_operations', total_length => 50000,
              remaining => 33616,
          }] } },
    );

    my $first = $yarn->compress_messages(\@first_messages, original_task => 'Read big.pm');
    ok_test($first->{content} =~ /call_abc/, 'First render: toolCallId present');

    # Second compression with the first as previous_summary
    my @second_messages = (
        { role => 'user', content => 'Now read small.pm too' },
    );

    my $second = $yarn->compress_messages(\@second_messages,
        original_task => 'Now read small.pm too',
        previous_summary => $first->{content});

    ok_test($second->{content} =~ /call_abc/, 'Round-trip: toolCallId preserved across compress');
    ok_test($second->{content} =~ /big\.pm/, 'Round-trip: source path preserved across compress');
    ok_test($second->{content} =~ /Persisted chunks/, 'Round-trip: Persisted chunks section in second render');
}

# Test 4: Current task line not corrupted by leaked chunk pointer
{
    my $yarn = CLIO::Memory::YaRN->new();

    # Render a summary first
    my @first_messages = (
        { role => 'user', content => 'Read big.pm' },
        { role => 'assistant', content => 'Reading.', tool_calls => [
            { id => 'call_abc', function => { name => 'file_operations', arguments => '{"operation":"read_file","path":"big.pm"}' } }
        ] },
        { role => 'tool', tool_call_id => 'call_abc', content => 'preview',
          _metadata => { persisted_chunks => [{
              tool_call_id => 'call_abc', source_path => 'big.pm',
              source_tool => 'file_operations', total_length => 50000,
              remaining => 33616,
          }] } },
    );
    my $first = $yarn->compress_messages(\@first_messages, original_task => 'Read big.pm');

    # Next compress uses a SHORT original_task. The carried-task would
    # normally be picked up from "Current task: ..." but if that line
    # became "Current task: call_abc (file_operations: big.pm) (50000
    # bytes, ...)" due to a leaked pointer, find_substantive_task must
    # detect the corruption and fall through to the messages scan.
    my @second_messages = (
        { role => 'user', content => 'Investigate the trim loss bug we just discovered' },
    );
    my $second = $yarn->compress_messages(\@second_messages,
        original_task => 'short',
        previous_summary => $first->{content});

    # The original_task "Read big.pm" is short (< 50 chars) so
    # find_substantive_task falls through to the messages scan. The
    # last user message is the substantive one ("Investigate the trim
    # loss bug..."), but the carried-task logic in compress_messages
    # currently captures "Read big.pm" as the carried_task from the
    # previous_summary's Current task line. Verify the carried chunk
    # pointer does NOT leak into the new Current task line (it should
    # be the substantive message, not the chunk pointer format).
    ok_test($second->{content} !~ /Current task: call_abc/,
        'Carried chunk pointer does not leak into Current task line (Test 4)');
}

# Test 5: persist_failed chunks are NOT rendered (no file on disk to read)
{
    my $yarn = CLIO::Memory::YaRN->new();
    my @messages = (
        { role => 'user', content => 'Read big.pm' },
        { role => 'tool', tool_call_id => 'call_failed',
          content => '[WARNING: persistence failed]',
          _metadata => { persisted_chunks => [{
              tool_call_id => 'call_failed',
              persist_failed => 1,
          }] } },
    );

    my $result = $yarn->compress_messages(\@messages, original_task => 'Read big.pm');
    ok_test($result->{content} !~ /call_failed/, 'persist_failed chunks not rendered');
}

# Test 6: multiple chunks in one tool result all render
{
    my $yarn = CLIO::Memory::YaRN->new();
    my @messages = (
        { role => 'user', content => 'Read both files' },
        { role => 'tool', tool_call_id => 'call_multi',
          content => 'preview',
          _metadata => { persisted_chunks => [
              { tool_call_id => 'call_a', source_path => 'a.pm', source_tool => 'file_operations', total_length => 30000, remaining => 14000 },
              { tool_call_id => 'call_b', source_path => 'b.pm', source_tool => 'file_operations', total_length => 40000, remaining => 24000 },
          ] } },
    );

    my $result = $yarn->compress_messages(\@messages, original_task => 'Read both');
    ok_test($result->{content} =~ /call_a/, 'Multiple chunks: call_a present');
    ok_test($result->{content} =~ /call_b/, 'Multiple chunks: call_b present');
    ok_test($result->{content} =~ /a\.pm/, 'Multiple chunks: a.pm path present');
    ok_test($result->{content} =~ /b\.pm/, 'Multiple chunks: b.pm path present');
}

print "\n$passed passed, $failed failed\n";
exit($failed > 0 ? 1 : 0);