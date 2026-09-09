#!/usr/bin/env perl
# Regression tests for YaRN save/load and cross-cycle section carryover.
# Adapted for the slimmed YaRN format (only original task + recent user
# requests — no commits, files, decisions, or tool counts).

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

# Test 2: Slim format — no commits, files, decisions, tool counts
subtest 'slim format has no statistical noise' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my $summary = <<'EOF';
<thread_summary>

Current task: The initial widget construction task

Recent user requests:
- [original] The initial widget construction task
- Follow up request
</thread_summary>
EOF

    my @cycle2 = ({ role => 'user', content => 'next step ' . ('x' x 60) });
    my $r = $yarn->compress_messages(\@cycle2,
        original_task => 'next step',
        previous_summary => $summary,
    );

    like($r->{content}, qr/Current task:/, 'Current task section present');
    like($r->{content}, qr/- The initial widget construction task/, 'previous original request carried forward');
    like($r->{content}, qr/- Follow up request/, 'previous user request carried forward');
    like($r->{content}, qr/next step/, 'new user request included');

    unlike($r->{content}, qr/Commits:|Files:|Decisions:|Tools:|Git commits|Files created|Tool usage/,
        'no statistical noise sections in slim output');
    unlike($r->{content}, qr/abc1234|def5678|file_operations: \d+ calls/,
        'no commit hashes or tool counts in slim output');
};

# Test 3: [original] marker is scoped to its bullet line
subtest 'original marker is scoped' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    # Body text mentions [original] mid-line - should NOT be carried
    my $summary_no_marker = <<'EOF';
<thread_summary>

Current task: do thing

Recent user requests:
- This body line mentions [original] but is not a marker
</thread_summary>
EOF

    my @cycle2 = ({ role => 'user', content => 'yes' });
    my $r = $yarn->compress_messages(\@cycle2,
        original_task => 'yes',
        previous_summary => $summary_no_marker,
    );
    unlike($r->{content}, qr/- \[original\]/, 'No [original] marker carryover from body text');

    # Legitimate [original] marker on its own bullet — the original task
    # is carried into the "Recent user requests:" section.
    my $summary_real_marker = <<'EOF';
<thread_summary>

Current task: a short placeholder

Recent user requests:
- [original] The initial widget construction task that we started with
</thread_summary>
EOF

    @cycle2 = ({ role => 'user', content => 'no' });
    $r = $yarn->compress_messages(\@cycle2,
        original_task => 'no',
        previous_summary => $summary_real_marker,
    );
    like($r->{content}, qr/The initial widget construction task/, 'carried [original] appears in output');

    # Carried [original] (>= 50 chars) populates Current task when caller
    # original_task is short.
    my $summary_full = <<'EOF';
<thread_summary>

Current task: The initial widget construction task that we started with

Recent user requests:
- [original] The initial widget construction task that we started with
</thread_summary>
EOF

    @cycle2 = ({ role => 'user', content => 'no' });
    $r = $yarn->compress_messages(\@cycle2,
        original_task => 'no',
        previous_summary => $summary_full,
    );
    like($r->{content}, qr/Current task: The initial widget construction task/,
        'carried [original] (>=50 chars) populates Current task');
};

# Test 4: Current task: regex is anchored to line start (no false positives
# from prose that mentions "Current task:" mid-line).
subtest 'Current task regex is anchored' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my $summary = <<'EOF';
<thread_summary>

Current task: The initial widget construction task

Recent user requests:
- First user request that is quite long indeed
</thread_summary>
EOF

    my @cycle2 = ({ role => 'user', content => 'continue doing the thing please' });
    my $r = $yarn->compress_messages(\@cycle2,
        original_task => 'continue doing the thing please',
        previous_summary => $summary,
    );
    like($r->{content}, qr/Current task: The initial widget construction task/,
        'carried task used when caller original_task is short');

    my @ct_lines = ($r->{content} =~ /^Current task: ([^\n]+)$/mg);
    is(scalar(@ct_lines), 1, 'exactly one Current task line emitted');
    is($ct_lines[0], 'The initial widget construction task', 'Current task body is carried task value');
};

# Test 5: User request bullet lines are line-bounded (no cross-line bleed)
subtest 'user request bullets are line-bounded' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @messages = (
        { role => 'user', content => 'First request' },
        { role => 'assistant', content => 'Working' },
        { role => 'user', content => 'Second request' },
    );
    my $r = $yarn->compress_for_context_recovery(\@messages,
        original_task => 'First request'
    );

    my ($req_block) = ($r->{content} =~ /^Recent user requests:\n((?:- [^\n]+\n?)+)/m);
    ok($req_block, 'Recent user requests section captured');
    like($req_block, qr/First request/, 'first request in section');
    like($req_block, qr/Second request/, 'second request in section');
};

done_testing();