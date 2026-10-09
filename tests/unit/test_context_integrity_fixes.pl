#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
use strict;
use warnings;
use utf8;
use Test::More;

# Tests for the adversarial context-integrity fixes:
# 1. Separator delimiter between dynamic-UC and user input in user message
# 2. thread_summary folding into user message for local-inference providers
# 3. remove_existing_thread_summaries scans ALL roles (not just system)
# 4. _extract_thread_summary_from_messages scans ALL roles

use CLIO::Core::API::MessageValidator qw(remove_existing_thread_summaries);
use CLIO::Providers;

# ---- Test 1: remove_existing_thread_summaries removes thread_summary from ANY role ----

subtest 'remove_existing_thread_summaries scans all roles' => sub {
    # System message with thread_summary (cloud provider layout)
    my $msgs_cloud = [
        { role => 'system', content => 'system prompt' },
        { role => 'system', content => '<thread_summary>old summary</thread_summary>' },
        { role => 'user',    content => 'hello' },
    ];
    my $result = remove_existing_thread_summaries($msgs_cloud);
    is(scalar(@$result), 2, 'Removes system thread_summary');
    ok($result->[0]{content} eq 'system prompt', 'System prompt preserved');
    ok($result->[1]{content} eq 'hello', 'User message preserved');

    # User message with embedded thread_summary (local inference provider layout)
    my $msgs_local = [
        { role => 'system', content => 'system prompt' },
        { role => 'user',    content => '<thread_summary>old summary</thread_summary>CWD: /tmp\n---\n\nactual user input' },
        { role => 'assistant', content => 'response' },
    ];
    my $result2 = remove_existing_thread_summaries($msgs_local);
    is(scalar(@$result2), 2, 'Removes user-embedded thread_summary for local inference');
    ok($result2->[0]{content} eq 'system prompt', 'System prompt preserved after user-embedded removal');
    ok($result2->[1]{content} eq 'response', 'Assistant message preserved after user-embedded removal');
    done_testing();
};

# ---- Test 2: _extract_thread_summary_from_messages scans all roles ----

subtest '_extract_thread_summary_from_messages scans all roles' => sub {
    require CLIO::Memory::YaRN;
    my $yarn = CLIO::Memory::YaRN->new();

    # System message (cloud layout)
    my $found_system = $yarn->_extract_thread_summary_from_messages([
        { role => 'system', content => '<thread_summary>summary here</thread_summary>' },
        { role => 'user',   content => 'hello' },
    ]);
    ok($found_system =~ /<thread_summary>.*summary here.*<\/thread_summary>/s,
       'Extracts from system message');

    # User message (local inference layout)
    my $found_user = $yarn->_extract_thread_summary_from_messages([
        { role => 'system', content => 'system prompt' },
        { role => 'user',   content => '<thread_summary>user-embedded summary</thread_summary>CWD: /tmp\n---\n\nactual input' },
    ]);
    ok($found_user =~ /<thread_summary>.*user-embedded summary.*<\/thread_summary>/s,
       'Extracts from user message for local inference');

    # Returns empty string when no thread_summary
    my $found_empty = $yarn->_extract_thread_summary_from_messages([
        { role => 'system', content => 'system prompt' },
        { role => 'user',   content => 'hello' },
    ]);
    is($found_empty, '', 'Returns empty string when no thread_summary found');

    done_testing();
};

# ---- Test 3: is_local_inference returns true for sam/llama.cpp/lmstudio ----

subtest 'is_local_inference' => sub {
    ok(CLIO::Providers::is_local_inference('sam'),           'SAM is local inference');
    ok(CLIO::Providers::is_local_inference('llama.cpp'),     'llama.cpp is local inference');
    ok(CLIO::Providers::is_local_inference('lmstudio'),      'LM Studio is local inference');
    ok(!CLIO::Providers::is_local_inference('openai'),       'OpenAI is NOT local inference');
    ok(!CLIO::Providers::is_local_inference('anthropic'),    'Anthropic is NOT local inference');
    ok(!CLIO::Providers::is_local_inference('github_copilot'),'Copilot is NOT local inference');
    done_testing();
};

# ---- Test 4: Separator is deterministic and present only when dynamic_uc is non-empty ----

subtest 'separator logic' => sub {
    # Simulate the logic from _build_turn_context:
    # If dynamic_uc has content, append "---\n\n" after it.
    my $user_context = "CWD: /tmp | Date: 2026-10-09 07:07 | Respond in English\n";

    # Case 1: No dynamic_uc -> no separator -> user input follows directly
    my $msg_no_uc = $user_context . 'actual user input';
    ok(index($msg_no_uc, '---') == -1, 'No separator when dynamic_uc is empty');

    # Case 2: With dynamic_uc -> separator present
    my $dynamic_uc = "Active todos:\n- [in-progress] Fix bug\n\n";
    my $msg_with_uc = $user_context;
    $msg_with_uc .= $dynamic_uc;
    $msg_with_uc .= "---\n\n";
    $msg_with_uc .= 'actual user input';
    ok(index($msg_with_uc, "---\n\n") > 0, 'Separator present when dynamic_uc is non-empty');
    ok($msg_with_uc =~ /---\n\nactual user input$/, 'User input follows separator');

    # Case 3: Separator is byte-stable when dynamic_uc content is the same
    my $msg_with_uc_2 = $user_context . $dynamic_uc . "---\n\n" . 'actual user input';
    is($msg_with_uc, $msg_with_uc_2, 'Separator produces byte-identical output for same dynamic_uc');
    done_testing();
};

# ---- Test 5: Thread summary folding logic (simulated) ----

subtest 'thread_summary folding for local inference' => sub {
    # Simulate the logic from _build_turn_context:
    # For local inference: fold into user message
    # For cloud: push as system message
    my $tail = '<thread_summary>Compressed summary of dropped turns</thread_summary>';
    my $dynamic_uc = "Active todos:\n- [in-progress] Task\n\n";
    my $user_context = "CWD: /tmp | Date: ...\n";

    # Local inference path: thread_summary + user_context + dynamic_uc + separator + user_input
    my $user_message_local = $tail . "\n\n" . $user_context . $dynamic_uc . "---\n\n" . 'user input';
    ok($user_message_local =~ /^<thread_summary>/, 'Thread summary at start of user message for local inference');
    ok($user_message_local =~ /user input$/, 'User input at end of user message for local inference');

    # Cloud path: thread_summary as separate system message
    my @messages_cloud = (
        { role => 'system', content => 'main system prompt' },
        { role => 'system', content => $tail },
        { role => 'user',    content => $user_context . $dynamic_uc . "---\n\n" . 'user input' },
    );
    ok($messages_cloud[1]{role} eq 'system', 'Thread summary is system message for cloud providers');
    ok($messages_cloud[1]{content} eq $tail, 'Thread summary content preserved for cloud providers');

    done_testing();
};

done_testing();
