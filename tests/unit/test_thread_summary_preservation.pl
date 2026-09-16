#!/usr/bin/env perl
# Test that thread_summary content is preserved across multiple trim cycles
# Verifies the fix for cumulative memory loss during long sessions

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;

use CLIO::Memory::YaRN;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);
use CLIO::Memory::TokenEstimator qw(estimate_tokens);

# Test 1: YaRN preserves previous_summary content
{
    my $yarn = CLIO::Memory::YaRN->new();
    
    # Simulate a previous summary with accumulated history
    my $old_summary = <<'END';
<thread_summary>
(Compressed 52 messages to free context space)

Original task: Build a widget system

Git commits made during compressed period:
- abc1234: feat: add widget base class
- def5678: feat: add widget rendering

Files created/modified:
- lib/Widget.pm
- lib/WidgetRenderer.pm

Key decisions:
- Use composition over inheritance for widgets

Tool usage:
- file_operations: 25 calls
- terminal_operations: 10 calls
</thread_summary>
END

    # New messages being compressed - different work
    my @new_messages = (
        { role => 'user', content => 'Now add tests for the widget system' },
        { role => 'assistant', content => 'I\'ll create tests', tool_calls => [
            { id => 'tc1', function => { name => 'file_operations', arguments => '{"path":"tests/test_widget.pl"}' } }
        ]},
        { role => 'tool', content => "[1234567] test: add widget tests\n", tool_call_id => 'tc1' },
    );
    
    my $result = $yarn->compress_messages(\@new_messages,
        original_task    => 'Build a widget system',
        previous_summary => $old_summary,
    );
    
    ok($result && $result->{content}, "YaRN compress with previous_summary returns content");
    
    my $content = $result->{content} || '';
    
    # Minimal-summary design (see YaRN::compress_messages): only the current
    # task and recent user requests survive across trim cycles. Per-turn noise
    # (commits, files, tool calls, counts, decisions) is intentionally NOT
    # carried over so the stable prefix stays byte-stable for KV caching.
    like($content, qr/<thread_summary>/, "Summary wrapped in thread_summary tags");
    like($content, qr/Build a widget system/, "Original task preserved as current task");
    like($content, qr/Now add tests for the widget system/, "Recent user request preserved");
    # And the dropped content must stay dropped (negative guards).
    unlike($content, qr/abc1234/, "Commits not carried over across trim cycles");
    unlike($content, qr/Widget\.pm/, "File paths not carried over");
    unlike($content, qr/file_operations:\s*2[56]/, "Tool counts not carried over");
}

# Test 2: YaRN without previous_summary still works
{
    my $yarn = CLIO::Memory::YaRN->new();
    
    my @messages = (
        { role => 'user', content => 'Do something' },
        { role => 'assistant', content => 'OK', tool_calls => [
            { id => 'tc2', function => { name => 'terminal_operations', arguments => '{}' } }
        ]},
        { role => 'tool', content => 'done', tool_call_id => 'tc2' },
    );
    
    my $result = $yarn->compress_messages(\@messages, original_task => 'Test task');
    ok($result && $result->{content}, "Compression without previous_summary works");
    like($result->{content}, qr/Do something/, "Recent user request preserved without previous_summary");
}

# Test 3: _parse_previous_summary handles empty/missing content
{
    my $yarn = CLIO::Memory::YaRN->new();
    
    my @messages = (
        { role => 'user', content => 'Hello' },
    );
    
    # Empty previous_summary
    my $result = $yarn->compress_messages(\@messages,
        original_task    => 'Test',
        previous_summary => '',
    );
    ok($result && $result->{content}, "Empty previous_summary handled gracefully");
    
    # undef previous_summary
    $result = $yarn->compress_messages(\@messages,
        original_task    => 'Test',
        previous_summary => undef,
    );
    ok($result && $result->{content}, "undef previous_summary handled gracefully");
}

# Test 4: validate_and_truncate preserves thread_summary (legacy no-op path)
{
    # Simulate a message array with an old thread_summary
    my @messages = (
        { role => 'system', content => 'System prompt goes here' },
        { role => 'system', content => '<thread_summary>Old accumulated summary content</thread_summary>' },
        { role => 'user', content => 'First user message' },
        { role => 'assistant', content => 'Response 1' },
        { role => 'user', content => 'Second message' },
        { role => 'assistant', content => 'Response 2' },
    );
    
    # Call validate_and_truncate with a small limit to trigger trimming
    my $result = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 1000 },  # Very small to force trim
        tools              => [],
        debug              => 0,
        model              => 'test-model',
    );
    
    # The result should exist and have a thread_summary
    ok($result && ref($result) eq 'ARRAY', "validate_and_truncate returns array");
    
    if ($result && @$result) {
        # Check that the result has a thread_summary message
        my $has_summary = 0;
        for my $msg (@$result) {
            if ($msg->{content} && $msg->{content} =~ /<thread_summary>/) {
                $has_summary = 1;
                last;
            }
        }
        ok($has_summary, "Result contains a thread_summary after trimming");
    }
}

# Test 5: Summary preserved when budget is sufficient (no drops needed)
{
    my @messages = (
        { role => 'system', content => 'System prompt' },
        { role => 'system', content => '<thread_summary>Preserved old summary with commits and files</thread_summary>' },
        { role => 'user', content => 'First user message' },
        { role => 'assistant', content => 'Short response' },
    );
    
    # Large budget - nothing should be dropped
    my $result = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 500000 },
        tools              => [],
        debug              => 0,
        model              => 'test-model',
    );
    
    ok($result && ref($result) eq 'ARRAY', "No-drop scenario returns array");
    
    if ($result && @$result) {
        # The summary should pass through unchanged (no trimming needed)
        my $found_summary = 0;
        for my $msg (@$result) {
            if ($msg->{content} && $msg->{content} =~ /Preserved old summary/) {
                $found_summary = 1;
                last;
            }
        }
        ok($found_summary, "Summary preserved unchanged when no trimming needed");
    }
}

done_testing();
