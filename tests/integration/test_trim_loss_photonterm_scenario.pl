#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Test: Round-trip the original PhotonTERM session shape through
# validate_and_truncate + YaRN compress, verifying the post-trim
# summary contains everything the model needs to continue work
# without losing state.
#
# This replays the exact scenario that triggered the bug report:
#   1. User asked for code review (1 message)
#   2. Model did 8 file reads (8 messages)
#   3. User approved with "proceed with all 8 items" (1 message)
#   4. Model started implementing (5 tool calls + 1 assistant marker)
#   5. Mid-implementation trim fires
#
# After trim, the summary must contain:
#   (a) The user's approval message (Layer 3)
#   (b) The "Done with item 1, moving to item 2" marker (Layer 2)
#   (c) At least one persisted chunk pointer for the file reads (Layer 1)

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Memory::YaRN;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);
use CLIO::Core::API::MessageValidator;

my $passed = 0;
my $failed = 0;
my $total = 0;

sub ok_test {
    my ($cond, $desc) = @_;
    $desc //= '';
    chomp $desc;
    $desc =~ s/^\s+|\s+$//g;
    $total++;
    if ($cond) { $passed++; print "ok $total - $desc\n"; }
    else       { $failed++; print "not ok $total - $desc [desc empty]\n"; }
}

# Build the PhotonTERM session replay
sub build_photonterm_session {
    my @messages;
    push @messages, { role => 'system', content => 'You are CLIO, an AI coding assistant.' };

    # Step 1: User's original request
    push @messages, {
        role => 'user',
        content => 'I would like you to do a full code review of PhotonTERM - I want to start using it soon but we need to make sure that it follows correct UI/UX patterns, and it is free of smells and inconsistencies. Analyze and report first, well discuss the plan and then begin implementing any changes needed.'
    };

    # Step 2: 8 file reads (review phase)
    for my $i (1..8) {
        push @messages, {
            role => 'assistant',
            content => "Reading module $i",
            tool_calls => [{
                id => "r$i",
                type => 'function',
                function => {
                    name => 'file_operations',
                    arguments => qq({"operation":"read_file","path":"src/photon_module$i.c"})
                }
            }],
        };
        push @messages, {
            role => 'tool',
            tool_call_id => "r$i",
            # Simulate persisted chunks: each file is >16KB so the tool
            # result gets the [TOOL_RESULT_STORED] marker.
            content => "[TOOL_RESULT_PREVIEW: First 16384 bytes shown]\n\n/* preview content */\n\n[TOOL_RESULT_STORED: toolCallId=r$i, totalLength=50000, remaining=33616 bytes]\n\nTo read the full result, use:\nfile_operations(operation: \"read_tool_result\", toolCallId: \"r$i\", offset: 0, length: 8192)\n",
            _metadata => { persisted_chunks => [{
                tool_call_id => "r$i",
                source_path => "src/photon_module$i.c",
                source_tool => 'file_operations',
                total_length => 50000,
                remaining => 33616,
            }] },
        };
    }

    # Step 3: User's approval
    push @messages, {
        role => 'user',
        content => 'I agree with your approach, please proceed with all 8 items.'
    };

    # Step 4: Implementation phase (5 tool calls + progress marker)
    for my $i (1..5) {
        push @messages, {
            role => 'assistant',
            content => "Implementing item $i",
            tool_calls => [{
                id => "i$i",
                type => 'function',
                function => {
                    name => 'file_operations',
                    arguments => qq({"operation":"replace_string","path":"src/photon_vte.c"})
                }
            }],
        };
        push @messages, {
            role => 'tool',
            tool_call_id => "i$i",
            content => "Edit applied successfully."
        };
    }

    # Step 5: Progress marker (regex fallback captures this)
    push @messages, {
        role => 'assistant',
        content => 'Done with item 1 (VTE insert mode fix). Moving to item 2 (DECCKM cursor key fix). The plan is to continue through all 8 items in order.'
    };

    return @messages;
}

# Test 1: Summary contains the user's approval (Layer 3)
{
    my @messages = build_photonterm_session();

    # Force aggressive trim to simulate the bug
    my $trimmed = validate_and_truncate(
        messages => \@messages,
        model_capabilities => { max_prompt_tokens => 8000, max_output_tokens => 1000 },
        tools => [],
        token_ratio => 2.5,
        model => 'test',
    );

    # Reconstruct summary from dropped units using YaRN
    # (validate_and_truncate already does this internally; we extract)
    my @dropped;
    my $kept_count = scalar(@$trimmed);
    my $total_messages = scalar(@messages);
    if ($kept_count < $total_messages) {
        @dropped = @messages[$kept_count .. $#messages];
    } else {
        @dropped = ();
    }

    my $yarn = CLIO::Memory::YaRN->new();
    my $compressed = $yarn->compress_messages(\@dropped,
        original_task => 'Code review PhotonTERM and fix all 8 issues',
        target_tokens => 2000,
    );

    my $summary = $compressed->{content} // '';

    ok_test($summary =~ /proceed with all 8 items/i,
        'PhotonTERM scenario L3: user approval preserved in summary');
}

# Test 2: Summary contains the progress marker (Layer 2)
{
    my @messages = build_photonterm_session();

    my $trimmed = validate_and_truncate(
        messages => \@messages,
        model_capabilities => { max_prompt_tokens => 8000, max_output_tokens => 1000 },
        tools => [],
        token_ratio => 2.5,
        model => 'test',
    );

    my @dropped;
    my $kept_count = scalar(@$trimmed);
    my $total_messages = scalar(@messages);
    if ($kept_count < $total_messages) {
        @dropped = @messages[$kept_count .. $#messages];
    } else {
        @dropped = ();
    }

    my $yarn = CLIO::Memory::YaRN->new();
    my $compressed = $yarn->compress_messages(\@dropped,
        original_task => 'Code review PhotonTERM and fix all 8 issues',
        target_tokens => 2000,
    );

    my $summary = $compressed->{content} // '';

    ok_test($summary =~ /Done with item 1/i,
        'PhotonTERM scenario L2: progress marker captured in summary');
    ok_test($summary =~ /Moving to item 2/i,
        'PhotonTERM scenario L2: "moving to" marker captured');
    ok_test($summary =~ /Key decisions/i,
        'PhotonTERM scenario L2: Decisions section rendered');
}

# Test 3: Summary contains at least one persisted chunk pointer (Layer 1)
{
    my @messages = build_photonterm_session();

    my $trimmed = validate_and_truncate(
        messages => \@messages,
        model_capabilities => { max_prompt_tokens => 8000, max_output_tokens => 1000 },
        tools => [],
        token_ratio => 2.5,
        model => 'test',
    );

    my @dropped;
    my $kept_count = scalar(@$trimmed);
    my $total_messages = scalar(@messages);
    if ($kept_count < $total_messages) {
        @dropped = @messages[$kept_count .. $#messages];
    } else {
        @dropped = ();
    }

    my $yarn = CLIO::Memory::YaRN->new();
    my $compressed = $yarn->compress_messages(\@dropped,
        original_task => 'Code review PhotonTERM and fix all 8 issues',
        target_tokens => 3000,  # bigger budget to fit chunks
    );

    my $summary = $compressed->{content} // '';

    ok_test($summary =~ /Persisted chunks/,
        'PhotonTERM scenario L1: Persisted chunks section rendered');
    ok_test($summary =~ /r[1-8]/,
        'PhotonTERM scenario L1: at least one toolCallId present in chunks');
    ok_test($summary =~ /photon_module[1-8]\.c/,
        'PhotonTERM scenario L1: source path preserved in chunks');
}

# Test 4: Combined - all three layers in one summary
{
    my @messages = build_photonterm_session();

    my $trimmed = validate_and_truncate(
        messages => \@messages,
        model_capabilities => { max_prompt_tokens => 8000, max_output_tokens => 1000 },
        tools => [],
        token_ratio => 2.5,
        model => 'test',
    );

    my @dropped;
    my $kept_count = scalar(@$trimmed);
    my $total_messages = scalar(@messages);
    if ($kept_count < $total_messages) {
        @dropped = @messages[$kept_count .. $#messages];
    } else {
        @dropped = ();
    }

    my $yarn = CLIO::Memory::YaRN->new();
    my $compressed = $yarn->compress_messages(\@dropped,
        original_task => 'Code review PhotonTERM and fix all 8 issues',
        target_tokens => 4000,  # bigger budget for all 3 layers
    );

    my $summary = $compressed->{content} // '';

    # Layer 1: persisted chunks
    ok_test($summary =~ /Persisted chunks/, 'combined L1: chunks present');
    # Layer 2: progress marker
    ok_test($summary =~ /Done with item 1/, 'combined L2: progress marker present');
    # Layer 3: user message (preserved either via budget walk or injection)
    my @user_msgs = grep { $_->{role} eq 'user' } @$trimmed;
    ok_test(scalar(@user_msgs) > 0 || $summary =~ /proceed with all 8 items/i,
        'combined L3: user message preserved (budget walk or summary)');
}

print "\n$passed passed, $failed failed\n";
exit($failed > 0 ? 1 : 0);
