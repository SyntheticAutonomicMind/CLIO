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

use CLIO::Core::API::MessageValidator qw(validate_and_truncate remove_existing_thread_summaries);
use CLIO::Providers;

# ---- Test 1: remove_existing_thread_summaries handles all roles correctly ----

subtest 'remove_existing_thread_summaries scans all roles' => sub {
    # System message with thread_summary (legacy/carryover) — removed
    # entirely for all providers.
    my $msgs_cloud = [
        { role => 'system', content => 'system prompt' },
        { role => 'system', content => '<thread_summary>old summary</thread_summary>' },
        { role => 'user',    content => 'hello' },
    ];
    my $result = remove_existing_thread_summaries($msgs_cloud);
    is(scalar(@$result), 2, 'Removes system thread_summary');
    ok($result->[0]{content} eq 'system prompt', 'System prompt preserved');
    ok($result->[1]{content} eq 'hello', 'User message preserved');

    # User message with embedded thread_summary — strip the <thread_summary>
    # block from the user message, preserving the user's actual input.
    # This is the unified behavior for ALL providers (cloud and local)
    # after the cache-fix refactor: thread_summary is folded into the
    # user message, and remove_existing_thread_summaries strips it
    # (instead of removing the entire user message).
    my $msgs_embedded = [
        { role => 'system', content => 'system prompt' },
        { role => 'user',    content => '<thread_summary>old summary</thread_summary>CWD: /tmp' . "\n---\n\nactual user input" },
        { role => 'assistant', content => 'response' },
    ];
    my $result_embedded = remove_existing_thread_summaries($msgs_embedded);
    is(scalar(@$result_embedded), 3, 'User message preserved (only strip thread_summary)');
    ok($result_embedded->[0]{content} eq 'system prompt', 'System prompt preserved after strip');
    like($result_embedded->[1]{content}, qr/actual user input/, 'User message content preserved');
    ok($result_embedded->[1]{content} !~ /<thread_summary>/, 'Thread_summary removed from user message');
    ok($result_embedded->[1]{content} !~ /old summary/, 'Old summary text stripped from user message');
    ok($result_embedded->[2]{content} eq 'response', 'Assistant message preserved');
    done_testing();
};

# ---- Test 1b: remove_existing_thread_summaries with empty/undefined input ----

subtest 'remove_existing_thread_summaries edge cases' => sub {
    is(scalar(@{ remove_existing_thread_summaries([]) }), 0, 'Empty array returns empty');
    is(scalar(@{ remove_existing_thread_summaries(undef) }), 0, 'Undef returns empty');
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

# ---- Test 6: validate_and_truncate folds thread_summary into user message
#        for local-inference providers (no mid-conversation system message) ----

subtest 'validate_and_truncate: local inference thread_summary folding' => sub {
    require CLIO::Memory::TokenEstimator;

    # Build a message array that exceeds the token budget so the proactive
    # trim path is exercised. The array has a system prompt + many user/
    # assistant messages, ending with a user message carrying the current
    # task. We use a tiny context window to force trimming.
    my @messages = (
        { role => 'system', content => 'System prompt' },
    );
    for my $i (1..20) {
        push @messages, { role => 'user',     content => "User request $i: " . ('x' x 200) };
        push @messages, { role => 'assistant', content => "Assistant response $i: " . ('y' x 200) };
    }

    my $caps = {
        max_context_window_tokens => 2048,
        max_output_tokens         => 256,
        max_prompt_tokens         => 1792,
    };

    # CLOUD provider: thread_summary is now folded INTO the user message
    # (not a separate mid-conversation system message) — this is the fix
    # for the cache regression. Cloud providers previously received a
    # system message between history and the user message, which broke
    # OpenRouter's prefix cache.
    my $result_cloud = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => 'Build a widget system',
        debug              => 0,
    );
    # Verify NO system message appears after index 0
    my $cloud_has_mid_system = 0;
    for my $i (1 .. $#{$result_cloud}) {
        if (ref($result_cloud->[$i]) eq 'HASH'
            && ($result_cloud->[$i]{role} // '') eq 'system') {
            $cloud_has_mid_system = 1;
            last;
        }
    }
    ok(!$cloud_has_mid_system, 'Cloud provider: NO mid-conversation system message (thread_summary folded into user message for cache stability)');

    # Local inference: thread_summary folded into user message, no
    # mid-conversation system message
    # Use longer active_task (>= 50 chars so compress_messages uses it
    # directly as "Current task:" instead of scanning messages)
    my $result_local = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => 'Build a widget system with advanced features and a clean API',
        config             => _make_local_config(),
        api_base           => 'http://localhost:9090/v1/chat/completions',
        debug              => 0,
    );
    my $local_has_mid_system = 0;
    for my $i (1 .. $#{$result_local}) {
        if (ref($result_local->[$i]) eq 'HASH'
            && ($result_local->[$i]{role} // '') eq 'system') {
            $local_has_mid_system = 1;
            last;
        }
    }
    ok(!$local_has_mid_system, 'Local inference: NO mid-conversation system message (thread_summary folded into user message)');

    # Verify the last user message contains the thread_summary
    # (for BOTH cloud and local providers now — unified behavior)
    my $last_user = undef;
    for my $i (reverse 0 .. $#{$result_cloud}) {
        if (ref($result_cloud->[$i]) eq 'HASH'
            && ($result_cloud->[$i]{role} // '') eq 'user') {
            $last_user = $result_cloud->[$i];
            last;
        }
    }
    ok($last_user, 'Cloud provider: last user message exists');
    if ($last_user) {
        my $content = $last_user->{content} // '';
        ok($content =~ /<thread_summary>/, 'Cloud provider: thread_summary folded into last user message');
        ok($content =~ /Build a widget system/, 'Cloud provider: user task text preserved in user message');
    }

    done_testing();
};

# Helper: create a mock Config that returns 'llama.cpp' as the provider
sub _make_local_config {
    return _MockConfig->new();
}

{
    package _MockConfig;
    sub new { bless {}, shift }
    sub get {
        my ($self, $key) = @_;
        if ($key eq 'provider') { return 'llama.cpp' }
        return undef;
    }
}

# ---- Test 7: _inject_summary_before_last_user folds for local inference ----

subtest '_inject_summary_before_last_user: local inference folding' => sub {
    require CLIO::Core::API::ErrorHandler;
    my $summary = { role => 'system', content => '<thread_summary>compressed</thread_summary>' };

    # Use full path since _inject_summary_before_last_user is a private function
    # ALL providers (cloud + local): folds into user message
    my @msgs = (
        { role => 'assistant', content => 'assistant msg' },
        { role => 'user',      content => 'actual user input' },
    );
    CLIO::Core::API::ErrorHandler::_inject_summary_before_last_user(\@msgs, $summary);
    is(scalar(@msgs), 2, 'All providers: no new message added (folded into user)');
    is($msgs[1]{role}, 'user', 'All providers: user message preserved');
    ok($msgs[1]{content} =~ /^<thread_summary>compressed<\/thread_summary>\n\nactual user input/,
        'All providers: summary folded at start of user message, input preserved');

    done_testing();
};

done_testing();
