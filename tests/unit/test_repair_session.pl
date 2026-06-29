#!/usr/bin/env perl
# Test: scripts/repair_session.pl handles all known corruption patterns.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use Test::More;
use File::Path qw(make_path rmtree);
use File::Copy qw(copy);
use POSIX qw(strftime);

# Test fixtures live under tmp/ (gitignored)
my $tmp_root = "$RealBin/../tmp/test_sessions_$$";
rmtree($tmp_root);
make_path($tmp_root);

# Clean up on exit
END { rmtree($tmp_root) if -d $tmp_root; }

# Build corrupt fixtures
sub write_fixture {
    my ($name, $content_or_undef) = @_;
    my $path = "$tmp_root/$name";
    if (defined $content_or_undef && length $content_or_undef) {
        open my $fh, '>:raw', $path or die "Cannot write $path: $!";
        print $fh $content_or_undef;
        close $fh;
    } else {
        # Empty file
        open my $fh, '>:raw', $path or die;
        close $fh;
    }
    return $path;
}

# Fixture 1: 0-byte file (pre-atomic_write era corruption)
my $empty_path = write_fixture('empty.json', '');

# Fixture 2: ReadLine __TIMEOUT__ leak
my $timeout_path = write_fixture('timeout.json',
    qq({"history":[{"role":"user","content":"Hi"},{"role":"user","content":{"type":"__TIMEOUT__"}}]}));

# Fixture 3: ReadLine __AGENT_EVENT__ leak (different signal)
my $event_path = write_fixture('event.json',
    qq({"messages":[{"role":"user","content":"ping"},{"role":"user","content":{"type":"__AGENT_EVENT__","payload":"x"}}]}));

# Fixture 4: Truncated JSON
my $truncated_path = write_fixture('truncated.json', '{"history":[{"role":"user","content":"cut');

# Fixture 5: Wrong shape (valid JSON, no session keys)
my $wrong_shape_path = write_fixture('wrong-shape.json', '{"unrelated": "data"}');

# Fixture 6: Healthy session (must not be touched)
my $healthy_path = write_fixture('healthy.json',
    qq({"history":[{"role":"user","content":"Hi"},{"role":"assistant","content":"Hello"}]}));

# Fixture 7: JSON-repairable missing-value syntax
my $jsonrepair_path = write_fixture('repairable.json',
    q({"history":[{"role":"user","content":"hi","priority": ,}]}));

# Helper: run repair with given env
sub run_repair {
    my (@args) = @_;
    my $cmd = qq{perl -I$RealBin/../../lib $RealBin/../../scripts/repair_session.pl @args};
    my $output = `$cmd 2>&1`;
    my $rc = $? >> 8;
    return ($output, $rc);
}

# 1. Scan reports issues
{
    local $ENV{CLIO_SESSIONS_DIR} = $tmp_root;
    my ($out, $rc) = run_repair('--scan');
    isnt($rc, 0, 'scan returns nonzero when issues found');
    like($out, qr/empty\.json/, 'scan flags empty file');
    like($out, qr/timeout\.json/, 'scan flags timeout leak');
    like($out, qr/event\.json/, 'scan flags agent_event leak');
    like($out, qr/truncated\.json/, 'scan flags truncated JSON');
    like($out, qr/wrong-shape\.json/, 'scan flags wrong-shape');
    unlike($out, qr/healthy\.json/, 'scan does not flag healthy file');
    unlike($out, qr/repairable\.json/, 'scan does not flag JSONRepair-recoverable file');
}

# 2. --auto leaves empty file in place without --cleanup or --delete-empty
{
    local $ENV{CLIO_SESSIONS_DIR} = $tmp_root;
    run_repair('--auto');
    ok(-f $empty_path, 'empty file preserved without --cleanup');
    ok(-f $timeout_path, 'timeout file exists before cleanup (modified in place)');

    # Re-build for next phase (since in-place edits happened above)
}

# 3. After --auto with --cleanup, empty file gets quarantined
{
    # Rebuild fixtures to test full pipeline
    write_fixture('empty.json', '');
    write_fixture('timeout.json',
        qq({"history":[{"role":"user","content":"Hi"},{"role":"user","content":{"type":"__TIMEOUT__"}}]}));
    write_fixture('truncated.json', '{"history":[{"role":"user","content":"cut');

    local $ENV{CLIO_SESSIONS_DIR} = $tmp_root;
    my ($out, $rc) = run_repair('--auto', '--cleanup');
    is($rc, 0, 'auto+cleanup exits cleanly');

    unlike($out, qr/LEFT IN PLACE/, 'no files left in place with --cleanup');

    ok(!-f $empty_path, 'empty file removed');
    my @quarantined = glob "$empty_path.corrupted.*.bak";
    ok(@quarantined, 'empty file quarantined to .bak');

    # Verify repaired files in place
    open my $fh, '<:raw', $timeout_path or die;
    my $contents = do { local $/; <$fh> };
    close $fh;
    # Default repair replaces hash-ref content with a [CORRUPTED INPUT: ...] marker
    # instead of dropping the message. This preserves conversation flow and
    # tool_call/tool_result pairing for strict-schema API providers like
    # NVIDIA NIM, which require string content.
    unlike($contents, qr/\{"type":"__TIMEOUT__"\}/,
        'hash ref TIMEOUT object removed from timeout.json (replaced with marker)');
    like($contents, qr/\[CORRUPTED INPUT: HASH type='__TIMEOUT__' - repaired by repair_session\.pl\]/,
        'replaced with [CORRUPTED INPUT: ...] marker');
    like($contents, qr/"Hi"/, 'real messages preserved');
    like($contents, qr/"user"/, 'message count preserved (not dropped)');
}

# 3b. --drop-messages opt-in restores legacy behavior
{
    write_fixture('timeout2.json',
        qq({"history":[{"role":"user","content":"Hi"},{"role":"user","content":{"type":"__TIMEOUT__"}},{"role":"assistant","content":"Hello"}]}));

    local $ENV{CLIO_SESSIONS_DIR} = $tmp_root;
    my ($out, $rc) = run_repair('--auto', '--drop-messages');
    is($rc, 0, 'auto+drop-messages exits cleanly');

    open my $fh2, '<:raw', "$tmp_root/timeout2.json" or die;
    my $contents2 = do { local $/; <$fh2> };
    close $fh2;
    unlike($contents2, qr/__TIMEOUT__/, 'hash ref message dropped from timeout2.json');
    like($contents2, qr/"Hi"/, 'first real message preserved');
    like($contents2, qr/"Hello"/, 'second real message preserved');
    unlike($contents2, qr/\[CORRUPTED INPUT/, 'no CORRUPTED marker when drop-messages is set');
}

# 4. --auto --delete-empty deletes zero-byte files entirely
{
    write_fixture('empty2.json', '');
    local $ENV{CLIO_SESSIONS_DIR} = $tmp_root;
    my ($out, $rc) = run_repair('--auto', '--delete-empty');
    is($rc, 0, 'auto+delete-empty exits cleanly');
    ok(!-f "$tmp_root/empty2.json", '0-byte file deleted');
    my @baks = glob "$tmp_root/empty2.json*";
    ok(!@baks, 'no backup created for deleted empty file');
}

# 5. --dry-run makes no changes
{
    my $marker_path = write_fixture('marker.json',
        qq({"history":[{"role":"user","content":"x"},{"role":"user","content":{"type":"__TIMEOUT__"}}]}));
    my $before = _slurp($marker_path);

    local $ENV{CLIO_SESSIONS_DIR} = $tmp_root;
    run_repair('--auto', '--dry-run');

    my $after = _slurp($marker_path);
    is($before, $after, 'dry-run does not modify files');
}

# 6. --session ID repairs one specific session
{
    write_fixture('specific.json',
        qq({"history":[{"role":"user","content":"y"},{"role":"user","content":{"type":"__TIMEOUT__"}}]}));

    local $ENV{CLIO_SESSIONS_DIR} = $tmp_root;
    my ($out, $rc) = run_repair('--session', 'specific');

    open my $fh, '<:raw', "$tmp_root/specific.json" or die;
    my $contents = do { local $/; <$fh> };
    close $fh;
    # Default replace mode keeps the message, just fixes content
    unlike($contents, qr/\{"type":"__TIMEOUT__"\}/,
        '--session replaced TIMEOUT object in specific file');
    like($contents, qr/\[CORRUPTED INPUT: HASH type='__TIMEOUT__' - repaired by repair_session\.pl\]/,
        '--session inserted [CORRUPTED INPUT: ...] marker');
}

sub _slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    my $c = do { local $/; <$fh> };
    close $fh;
    return $c;
}

done_testing();
