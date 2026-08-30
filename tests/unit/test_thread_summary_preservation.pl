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

my $passed = 0;
my $failed = 0;

sub ok_test {
    my ($cond, $desc) = @_;
    if ($cond) {
        $passed++;
        print "ok - $desc\n";
    } else {
        $failed++;
        print "NOT OK - $desc\n";
    }
}

# Test 1: YaRN preserves previous_summary content
{
    my $yarn = CLIO::Memory::YaRN->new();
    
    # Simulate a previous summary with accumulated history
    my $old_summary = <<'END';
<threadSummary>

- This is informational context only - do not reference or repeat in your responses

Current task: Build a widget system

Commits:
- abc1234: feat: add widget base class
- def5678: feat: add widget rendering

Files:
- lib/Widget.pm
- lib/WidgetRenderer.pm

Decisions:
- Use composition over inheritance for widgets

</threadSummary>
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
    
    ok_test($result && $result->{content}, "YaRN compress with previous_summary returns content");
    
    my $content = $result->{content} || '';
    
    # Commits, files, and decisions from the previous summary are preserved
    ok_test($content =~ /abc1234/, "Previous commit abc1234 preserved in new summary");
    ok_test($content =~ /def5678/, "Previous commit def5678 preserved in new summary");
    ok_test($content =~ /Widget\.pm/, "Previous file Widget.pm preserved");
    ok_test($content =~ /WidgetRenderer\.pm/, "Previous file WidgetRenderer.pm preserved");
    ok_test($content =~ /composition over inheritance/, "Previous decision preserved");

    # New content should also be present
    ok_test($content =~ /test_widget/, "New file from current messages included");
    ok_test($content =~ /1234567/, "New commit from current messages included");

    # Tool counts are NOT rendered — only work product survives
    ok_test($content !~ /Tool usage:/, "No 'Tool usage:' section in summary");
    ok_test($content !~ /file_operations:\s*\d+\s+calls/, "No file_operations call count");
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
    ok_test($result && $result->{content}, "Compression without previous_summary works");
    ok_test($result->{content} =~ /Current task:/, "Current task line present without previous_summary");
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
    ok_test($result && $result->{content}, "Empty previous_summary handled gracefully");
    
    # undef previous_summary
    $result = $yarn->compress_messages(\@messages,
        original_task    => 'Test',
        previous_summary => undef,
    );
    ok_test($result && $result->{content}, "undef previous_summary handled gracefully");
}

# Test 4: MessageValidator _extract_preserved_units returns gap_units
{
    # Simulate a message array with an old thread_summary
    my @messages = (
        { role => 'system', content => 'System prompt goes here' },
        { role => 'system', content => '<threadSummary>Old accumulated summary content</threadSummary>' },
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
    ok_test($result && ref($result) eq 'ARRAY', "validate_and_truncate returns array");
    
    if ($result && @$result) {
        # Check that the result has a thread_summary message
        my $has_summary = 0;
        for my $msg (@$result) {
            if ($msg->{content} && $msg->{content} =~ /<threadSummary>/) {
                $has_summary = 1;
                last;
            }
        }
        ok_test($has_summary, "Result contains a thread_summary after trimming");
    }
}

# Test 5: Summary preserved when budget is sufficient (no drops needed)
{
    my @messages = (
        { role => 'system', content => 'System prompt' },
        { role => 'system', content => '<threadSummary>Preserved old summary with commits and files</threadSummary>' },
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
    
    ok_test($result && ref($result) eq 'ARRAY', "No-drop scenario returns array");
    
    if ($result && @$result) {
        # The summary should pass through unchanged (no trimming needed)
        my $found_summary = 0;
        for my $msg (@$result) {
            if ($msg->{content} && $msg->{content} =~ /Preserved old summary/) {
                $found_summary = 1;
                last;
            }
        }
        ok_test($found_summary, "Summary preserved unchanged when no trimming needed");
    }
}

print "\n$passed passed, $failed failed\n";
exit($failed > 0 ? 1 : 0);
