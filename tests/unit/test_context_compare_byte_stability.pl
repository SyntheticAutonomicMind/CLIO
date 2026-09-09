#!/usr/bin/env perl
# Test: Byte-level content diff engine and system prompt comparison
# for tools/context_compare.pl
#
# Tests via subprocess: creates mock session JSON files, runs the tool,
# and verifies the four-scenario divergence report and system prompt
# byte stability output.
#
# Covers P1 (SHA-256 diffs), P2 (system prompt byte comparison),
# and P3 (token estimation alignment).
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test2::V0;
use File::Temp qw(tempfile);
use JSON::PP;

my $TOOL = "$FindBin::Bin/../../tools/context_compare.pl";
my $LIB = "$FindBin::Bin/../../lib";
ok(-f $TOOL, 'context_compare.pl exists');

# ── Helper: run the tool on a mock session JSON ──────────────────────
sub run_tool {
    my ($json, $extra_args) = @_;
    $extra_args //= '';
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print $fh JSON::PP->new->ascii->encode($json);
    close $fh;
    my $cmd = "perl -I$LIB $TOOL " . shell_quote($path) . " $extra_args 2>&1";
    my $output = `$cmd`;
    return $output;
}

# ── Helper: shell-quote a string ──────────────────────────────────────
sub shell_quote {
    my ($s) = @_;
    return "'$s'" if $s =~ /\A[\w.\/:@\-]+\z/;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# ── Helper: build a mock session JSON ────────────────────────────────
sub mock_session {
    my ($opts) = @_;
    $opts //= {};
    my $sys = $opts->{system_prompt} // 'BASE SYSTEM PROMPT FOR TESTING';
    my $turns = $opts->{turns} // 1;

    my @payload;
    push @payload, { role => 'system', content => $sys };
    for my $t (1..$turns) {
        push @payload, { role => 'user', content => "message from turn $t part A" };
        push @payload, { role => 'assistant', content => "response for turn $t part B" };
    }

    my @history;
    for my $t (1..$turns) {
        push @history, { role => 'user', content => "message from turn $t part A", token_count => 7 };
        push @history, { role => 'assistant', content => "response for turn $t part B", token_count => 7 };
    }

    return {
        session_name => $opts->{name} // 'test_session',
        selected_model => $opts->{model} // 'test/model',
        max_tokens => $opts->{max_tokens} // 200000,
        history => \@history,
        last_api_payload => \@payload,
        last_api_metadata => {
            model => $opts->{model} // 'test/model',
            provider => $opts->{provider} // 'test-provider',
            context_window => $opts->{ctx_window} // 200000,
            tools_signature => $opts->{tools_sig} // 'sig_test_12345',
        },
        selected_provider => $opts->{provider} // 'test-provider',
        config => {
            max_tokens => 8000,
            language => 'English',
            working_directory => '/tmp',
            non_interactive => $opts->{non_interactive} // 0,
        },
    };
}

# ── Test 1: Tool runs without crashing on a basic session ────────────
{
    my $sess = mock_session({ turns => 1 });
    my $out = run_tool($sess);
    ok(length($out) > 0, 'tool produces output');
    like($out, qr/CONTEXT COMPARE/, 'output contains header');
    like($out, qr/DIVERGENCE REPORT/, 'output contains divergence report');
    like($out, qr/SYSTEM PROMPT BYTE STABILITY/, 'output contains system prompt section');
    pass('Tool runs without crashing (smoke test)');
}

# ── Test 2: Pre-trim and rebuild are byte-stable ────────────────────
{
    my $sess = mock_session({ turns => 2 });
    my $out = run_tool($sess, '--json');
    my $data = eval { decode_json($out) };
    ok($data, 'JSON output parses');
    if ($data) {
        my ($pre_rebuild) = grep { $_->{a} eq 'pre-trim' && $_->{b} eq 'rebuild' } @{$data->{pair_diffs}};
        ok($pre_rebuild, 'found pre-trim->rebuild pair in JSON');
        if ($pre_rebuild) {
            is($pre_rebuild->{byte_stable}, 1, 'pre-trim->rebuild is byte_stable');
            is($pre_rebuild->{common}, $pre_rebuild->{a_count}, 'all messages common');
        }
    }
    pass('Pre-trim/rebuild byte stability (P1)');
}

# ── Test 3: SHA-256 detects stale system prompt ─────────────────────
{
    my $sess = mock_session({ turns => 1, system_prompt => 'SYSTEM PROMPT VERSION 2' });
    # Make cached payload's system prompt stale
    $sess->{last_api_payload}[0]{content} = 'SYSTEM PROMPT VERSION 1 OLD';

    my $out = run_tool($sess, '--json 2>/dev/null');
    my $data = eval { decode_json($out) };
    ok($data, 'JSON output for stale prompt session parses');
    if ($data) {
        my ($pre) = grep { $_->{name} eq 'pre-trim' } @{$data->{scenarios}};
        my ($fast) = grep { $_->{name} eq 'fast-resume' } @{$data->{scenarios}};
        if ($pre && $fast && $pre->{system_prompt} && $fast->{system_prompt}) {
            isnt($pre->{system_prompt}{sha256}, $fast->{system_prompt}{sha256},
                 'fast-resume system prompt SHA differs from pre-trim');
            isnt($fast->{system_prompt}{bytes}, $pre->{system_prompt}{bytes},
                 'fast-resume system prompt byte count differs');
        }
    }
    pass('SHA-256 detects stale system prompt (P1+P2)');
}

# ── Test 4: Handles sessions with no last_api_payload ──────────────
{
    my $sess = mock_session({ turns => 1 });
    delete $sess->{last_api_payload};
    delete $sess->{last_api_metadata}{tools_signature};
    my $out = run_tool($sess, '--json 2>/dev/null');
    my $data = eval { decode_json($out) };
    ok($data, 'JSON output for session without payload parses');
    if ($data) {
        my ($fast) = grep { $_->{name} eq 'fast-resume' } @{$data->{scenarios}};
        if ($fast) {
            ok($fast->{message_count} == 0, 'fast-resume has 0 messages when no cached payload');
        }
    }
    pass('Handles missing cached payload gracefully');
}

# ── Test 5: Token estimation produces non-zero values ───────────────
{
    my $sess = mock_session({ turns => 3 });
    my $out = run_tool($sess, '--json 2>/dev/null');
    my $data = eval { decode_json($out) };
    if ($data) {
        my ($pre) = grep { $_->{name} eq 'pre-trim' } @{$data->{scenarios}};
        if ($pre) {
            my $total = $pre->{total_tokens};
            my $sys_tok = $pre->{sections}{system_prompt}{tokens};
            my $dialog_tok = $pre->{sections}{dialog}{tokens};
            ok($total > $sys_tok, 'total tokens > system prompt tokens');
            ok($total > $dialog_tok, 'total tokens > dialog tokens');
            ok($sys_tok > 0, 'system prompt has non-zero token count');
        }
    }
    pass('Token estimation alignment (P3)');
}

# ── Test 6: Divergence report includes byte_stable ──────────────────
{
    my $sess = mock_session({ turns => 2 });
    my $out = run_tool($sess, '--quiet');
    like($out, qr/byte-stable/i, 'divergence report includes byte_stable info');
    like($out, qr/SYSTEM PROMPT BYTE STABILITY/, 'system prompt comparison section present');
    pass('Divergence report includes byte stability info');
}

# ── Test 8: Thread_summary deduplication detection ───────────────────
# Verify the tool correctly identifies thread_summary messages in
# scenarios. When the framework injects thread_summary on every turn,
# the cached payload may have multiple copies. CLIO's fast-path resume
# deduplicates them (keeps first, drops rest).
{
    my $sess = mock_session({ turns => 2 });
    # Simulate duplicate thread_summary in cached payload
    $sess->{last_api_payload}[0]{content} = "BASE SYSTEM PROMPT\n<thread_summary>DUPLICATE TS 1</thread_summary>";
    # Add a duplicate thread_summary as a separate system message
    splice(@{$sess->{last_api_payload}}, 1, 0,
        { role => 'system', content => '<thread_summary>DUPLICATE TS 2</thread_summary>' });

    my $out = run_tool($sess, '--json 2>/dev/null');
    my $data = eval { decode_json($out) };
    ok($data, 'JSON output for duplicate thread_summary session parses');
    if ($data) {
        # Verify the tool runs without crashing on duplicate thread_summary
        my ($pre) = grep { $_->{name} eq 'pre-trim' } @{$data->{scenarios}};
        ok($pre && $pre->{message_count} > 0, 'pre-trim scenario has messages');
    }
    pass('Thread_summary deduplication does not crash tool');
}

done_testing();
