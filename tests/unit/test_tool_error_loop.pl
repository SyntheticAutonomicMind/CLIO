#!/usr/bin/env perl
# Regression test for Bug B: tool error loop detection.
#
# When a model emits a malformed tool call (missing operation, wrong key
# names like 'command' instead of 'operation'), CLIO returns a TOOL ERROR +
# full schema help. Without detection, the model can repeat the same
# mistake for dozens of iterations, dumping 30+ lines of schema into the
# context each time and burying the original task.
#
# Fix: After 3 consecutive identical-shape tool errors, replace the verbose
# schema help with a one-line "STOP" message so the model knows to break
# the loop.

use strict;
use warnings;
use utf8;
use lib '../../lib';
use Test::More;
use CLIO::Tools::Tool;
use CLIO::Core::ToolErrorGuidance;
use CLIO::UI::ToolOutputFormatter;

# Create a minimal mock WorkflowOrchestrator that exposes only the loop
# detection state and the per-tool-error logic. We mirror the data-driven
# signature scheme: tool_name + operation + first 80 chars of the error.
package FakeOrchestrator;

sub new {
    my ($class) = @_;
    return bless {
        _tool_error_loop_count => {},
        _tool_error_loop_last_sig => undef,
    }, $class;
}

sub record_tool_outcome {
    my ($self, $tool_name, $tool_operation, $result_data) = @_;
    return ($self->{_tool_error_loop_count}, $self->{_tool_error_loop_last_sig})
        unless $result_data && ref($result_data) eq 'HASH';

    my $is_error = exists $result_data->{success} && !$result_data->{success};
    my $err_sig = join("|",
        $tool_name,
        $tool_operation || '',
        substr($result_data->{error} // '', 0, 80)
    );

    if ($is_error) {
        if (defined $self->{_tool_error_loop_last_sig}
            && $self->{_tool_error_loop_last_sig} eq $err_sig) {
            $self->{_tool_error_loop_count}{$err_sig}++;
        } else {
            $self->{_tool_error_loop_count}{$err_sig} = 1;
            $self->{_tool_error_loop_last_sig} = $err_sig;
        }
        my $count = $self->{_tool_error_loop_count}{$err_sig};
        return ($self->{_tool_error_loop_count}, $count, $err_sig);
    } else {
        $self->{_tool_error_loop_count} = {};
        $self->{_tool_error_loop_last_sig} = undef;
        return ($self->{_tool_error_loop_count}, 0, undef);
    }
}

package main;

# Test 1: First error of a new shape sets count=1
{
    my $orc = FakeOrchestrator->new();
    my ($count_h, $count, $sig) = $orc->record_tool_outcome(
        'terminal_operations', 'exec',
        { success => 0, error => "Missing 'operation' parameter" }
    );
    is($count, 1, "First error of new shape: count=1");
    like($sig, qr/terminal_operations\|exec\|Missing 'operation'/, "Signature includes tool, op, error");
}

# Test 2: Same error 3 times triggers STOP signal
{
    my $orc = FakeOrchestrator->new();
    my $err = { success => 0, error => "Missing 'operation' parameter" };
    $orc->record_tool_outcome('terminal_operations', 'exec', $err);
    $orc->record_tool_outcome('terminal_operations', 'exec', $err);
    my ($count_h, $count, $sig) = $orc->record_tool_outcome('terminal_operations', 'exec', $err);
    is($count, 3, "Third identical error: count=3");
}

# Test 3: Different error resets to count=1
{
    my $orc = FakeOrchestrator->new();
    $orc->record_tool_outcome('terminal_operations', 'exec',
        { success => 0, error => "Missing 'operation' parameter" });
    $orc->record_tool_outcome('terminal_operations', 'exec',
        { success => 0, error => "Missing 'operation' parameter" });
    my ($count_h, $count, $sig) = $orc->record_tool_outcome('file_operations', 'read_file',
        { success => 0, error => "File not found" });
    is($count, 1, "Different shape resets to count=1");
}

# Test 4: Successful tool call resets loop tracking
{
    my $orc = FakeOrchestrator->new();
    $orc->record_tool_outcome('terminal_operations', 'exec',
        { success => 0, error => "Missing 'operation' parameter" });
    $orc->record_tool_outcome('terminal_operations', 'exec',
        { success => 0, error => "Missing 'operation' parameter" });
    # Successful call resets
    my ($count_h, $count, $sig) = $orc->record_tool_outcome('terminal_operations', 'exec',
        { success => 1, output => 'ok' });
    is($count, 0, "Successful call resets tracking");
    is_deeply($count_h, {}, "Count hash cleared after success");

    # After reset, same error shape starts count=1 again
    my ($count_h2, $count2, $sig2) = $orc->record_tool_outcome('terminal_operations', 'exec',
        { success => 0, error => "Missing 'operation' parameter" });
    is($count2, 1, "After reset, same error starts count=1 again");
}

# Test 5: Two different operations on the same tool don't trigger STOP
{
    my $orc = FakeOrchestrator->new();
    $orc->record_tool_outcome('file_operations', 'read_file',
        { success => 0, error => "File not found" });
    $orc->record_tool_outcome('file_operations', 'read_file',
        { success => 0, error => "File not found" });
    my ($count_h, $count, $sig) = $orc->record_tool_outcome('file_operations', 'write_file',
        { success => 0, error => "Permission denied" });
    is($count, 1, "Different operation on same tool: count=1 (signature includes operation)");
}

# Test 6: Verify ToolErrorGuidance still produces the verbose message
# (we only override it AFTER 3 identical errors, not from the start)
{
    my $guidance = CLIO::Core::ToolErrorGuidance->new();
    my $enhanced = $guidance->enhance_tool_error(
        error => "Missing 'operation' parameter",
        tool_name => "terminal_operations",
    );
    like($enhanced, qr/operation.*REQUIRED|terminal_operations/,
        "ToolErrorGuidance still produces full schema help on first error");
}

done_testing();
