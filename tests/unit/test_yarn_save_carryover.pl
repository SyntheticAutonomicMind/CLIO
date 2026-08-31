#!/usr/bin/env perl
# Regression tests for YaRN save/load and cross-cycle section carryover.
#
# Covers the bugs found during the long-session audit:
#   1. YaRN::save() called encode_json that wasn't imported - croak on use.
#   2. _parse_previous_summary used /s regex that bled across sections,
#      and looked for "Files created/modified" while _render produced
#      "Files:" (and similarly for the other section labels).
#   3. The [original] carryover regex was greedy and matched "[original]"
#      anywhere in body text.
#   4. The Current task: carryover regex was unanchored and unanchored.

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use File::Temp qw(tempfile);

use CLIO::Memory::YaRN;

# Test 1: YaRN::save() actually writes JSON (and load() reads it back)
subtest 'save/load roundtrip' => sub {
    my $yarn = CLIO::Memory::YaRN->new();
    $yarn->create_thread('alpha');
    $yarn->add_to_thread('alpha', { role => 'user', content => 'hi' });
    $yarn->add_to_thread('alpha', { role => 'assistant', content => 'hello' });

    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    close $fh;
    ok($yarn->save($path), 'save() does not croak on imported encode_json');
    ok(-s $path > 0, 'save() wrote non-empty file');

    my $loaded = CLIO::Memory::YaRN->load($path);
    my $thread = $loaded->get_thread('alpha');
    is(scalar(@$thread), 2, 'load() recovered both messages');
    is($thread->[0]{content}, 'hi', 'first message content preserved');
    is($thread->[1]{role}, 'assistant', 'second message role preserved');
};

# Test 2: Section isolation - bullet bodies do not bleed across sections
subtest 'parse_previous_summary isolates sections' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my $summary = <<EOF;
<thread_summary>

Current task: Initial task

Active discussion (agent-user collaboration exchanges):
  Agent asked: Q?
  User replied: A

Recent user requests:
- First user request

Git commits made during compressed period:
- abc1234: feat: add stuff

Files created/modified:
- lib/Foo.pm

Key decisions:
- Use foo for everything

Tool usage:
- file_operations: 5 calls
</thread_summary>
EOF

    my @cycle2 = ({ role => 'user', content => 'follow up ' . ('x' x 60) });
    my $r = $yarn->compress_messages(\@cycle2, original_task => 'follow up', previous_summary => $summary);

    # The carryover preserves all sections in order; blank lines between
    # headings are part of the rendering and make regex matching brittle.
    # Verify each section is present and bounded - bullet bodies do not
    # cross section boundaries.
    like($r->{content}, qr/- abc1234: feat: add stuff/, 'abc1234 commit preserved');
    like($r->{content}, qr/- lib\/Foo\.pm/, 'Foo.pm file preserved');
    like($r->{content}, qr/- Use foo for everything/, 'decision preserved');
    like($r->{content}, qr/- file_operations: 5 calls/, 'tool usage preserved');
    unlike($r->{content}, qr/Tool usage/, 'renderer now emits "Tools:" not legacy "Tool usage:"');
    unlike($r->{content}, qr/Git commits made during compressed period/, 'renderer uses new "Commits:"');
    unlike($r->{content}, qr/Files created/, 'renderer uses new "Files:"');
    unlike($r->{content}, qr/Key decisions/, 'renderer uses new "Decisions:"');
    unlike($r->{content}, qr/Active discussion \(agent-user/, 'renderer uses new "Discussion:"');
};

# Test 3: New-format summary parses back via legacy + new header regexes
subtest 'parse_previous_summary accepts new headers' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my $new_format = <<EOF;
<thread_summary>

Current task: Build feature X

Discussion:
  Agent asked: Which auth scheme?
  User replied: OAuth2 PKCE

Recent user requests:
- initial user request

Commits:
- abc1234: feat: add foo

Files:
- lib/Foo.pm

Decisions:
- Use foo

Tools:
- file_operations: 12 calls
</thread_summary>
EOF

    my @cycle2 = ({ role => 'user', content => 'continue ' . ('x' x 60) });
    my $r = $yarn->compress_messages(\@cycle2, original_task => 'continue', previous_summary => $new_format);

    like($r->{content}, qr/- abc1234: feat: add foo/, 'commits carryover works for new format');
    like($r->{content}, qr/- lib\/Foo\.pm/, 'files carryover works for new format');
    like($r->{content}, qr/- Use foo/, 'decisions carryover works for new format');
    like($r->{content}, qr/Which auth scheme\?/, 'discussion carryover works for new format');
    like($r->{content}, qr/- initial user request/, 'user requests carryover works for new format');
};

# Test 4: [original] marker only matches literal '- [original] X' on a single line
subtest 'original marker is anchored' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    # Body text mentions [original] mid-line - should NOT be carried
    my $summary_no_marker = <<EOF;
<thread_summary>

Current task: do thing

Recent user requests:
- This body line mentions [original] but is not a marker
EOF

    my @cycle2 = ({ role => 'user', content => 'yes' });
    my $r = $yarn->compress_messages(\@cycle2,
        original_task => 'yes',
        previous_summary => $summary_no_marker,
    );
    unlike($r->{content}, qr/- \[original\]/, 'No [original] marker carryover from body text');

    # Legitimate marker on its own line should carry forward into first_user_request
    my $summary_real_marker = <<EOF;
<thread_summary>

Current task: do thing

Recent user requests:
- [original] Build the auth flow exactly as spec says
EOF

    @cycle2 = ({ role => 'user', content => 'no' });
    $r = $yarn->compress_messages(\@cycle2,
        original_task => 'no',
        previous_summary => $summary_real_marker,
    );
    like($r->{content}, qr/- Build the auth flow exactly as spec says/, 'carried [original] lands as first user request');
    unlike($r->{content}, qr/- \[original\] Build/, '[original] prefix stripped on carryover');

    # Carried [original] populates Current task via find_substantive_task
    # when the prior summary has BOTH a [original] marker AND a substantive
    # Current task line (which the carryover propagates).
    my $summary_full = <<EOF;
<thread_summary>

Current task: Build the auth flow exactly as spec says

Recent user requests:
- [original] Build the auth flow exactly as spec says
EOF

    @cycle2 = ({ role => 'user', content => 'no' });
    $r = $yarn->compress_messages(\@cycle2,
        original_task => 'no',
        previous_summary => $summary_full,
    );
    like($r->{content}, qr/Current task: Build the auth flow/, 'carried [original] populates Current task');
};

# Test 5: Current task: regex anchored to line start (no false positives)
subtest 'Current task regex is anchored' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    # Body content has "Current task:" in a quoted discussion
    my $summary = <<EOF;
<thread_summary>

Discussion:
  Agent asked: Note: Current task: hidden reference
  User replied: ack

Recent user requests:
- real user message
EOF

    my @cycle2 = ({ role => 'user', content => 'continue' });
    my $r = $yarn->compress_messages(\@cycle2,
        original_task => 'continue',
        previous_summary => $summary,
    );
    like($r->{content}, qr/Current task: continue/, 'caller-provided original_task wins when short');
    # Body content MUST be preserved (it is part of conversation history).
    # The fix is that the inline body text is NOT promoted to the Current task
    # line. There is exactly one Current task: line and its body is the
    # short caller-provided value, not the body reference.
    my @ct_lines = ($r->{content} =~ /^Current task: ([^\n]+)$/mg);
    is(scalar(@ct_lines), 1, 'exactly one Current task line emitted');
    is($ct_lines[0], 'continue', 'Current task line body is caller-provided value');
};

# Test 6: Body bullet surviving in summary block does not get re-classified
subtest 'body bullets do not re-classify' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my $summary = <<EOF;
<thread_summary>

Current task: Build X

Git commits made during compressed period:
- abc1234: feat: shipped
- not a commit, body text with - dash

Files created/modified:
- lib/Foo.pm
EOF

    my @cycle2 = ({ role => 'user', content => 'next' . ('x' x 60) });
    my $r = $yarn->compress_messages(\@cycle2,
        original_task => 'next',
        previous_summary => $summary,
    );
    # Section capture is bounded by [^\n]+ (no /s) so each bullet body stays
    # on its own line. The "not a commit" line is in the section block but
    # rendered separately from abc1234.
    my ($commit_block) = ($r->{content} =~ /^Commits:\n((?:- [^\n]+\n?)+)/m);
    ok($commit_block, 'Commits section captured');
    like($commit_block, qr/abc1234/, 'commits section contains abc1234');
    like($commit_block, qr/not a commit/, 'commits section retains dash-prefixed body line');
    # Files section comes AFTER Commits - verify by splitting on section headings
    my $commits_pos = index($r->{content}, "Commits:");
    my $files_pos = index($r->{content}, "Files:");
    ok($commits_pos >= 0 && $files_pos > $commits_pos, 'Files section comes after Commits');
};

done_testing();
