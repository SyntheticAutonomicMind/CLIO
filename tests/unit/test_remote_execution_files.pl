#!/usr/bin/env perl

# transfer_files and retrieve_files take an array of {local_path,
# remote_path} objects. The published schema used to declare an array of
# plain strings, so a model following the schema hit
#   Can't use string ("...") as a HASH ref while "strict refs" in use
# These tests pin the schema to the handler and check that a wrong shape
# produces an actionable error instead of a strict-refs crash.

use strict;
use warnings;
use utf8;
use lib 'lib';

use Test::More;
use CLIO::Tools::RemoteExecution;

my $rx = CLIO::Tools::RemoteExecution->new(debug => 0);
ok($rx, 'tool constructed');

# ── Published schema ─────────────────────────────────────────────────

my $defs = $rx->get_operation_tool_definitions();
ok($defs && %$defs, 'per-operation definitions available');

for my $op (qw(transfer_files retrieve_files)) {
    my $params = $defs->{$op}{properties} || {};
    my $files  = $params->{files};

    is($files->{type}, 'array', "$op: files is an array");
    is($files->{items}{type}, 'object', "$op: files items are objects");

    my $item_required = $files->{items}{required} || [];
    is_deeply([sort @$item_required], [qw(local_path remote_path)],
        "$op: files items require local_path and remote_path");

    ok($files->{items}{properties}{local_path}, "$op: local_path documented");
    ok($files->{items}{properties}{remote_path}, "$op: remote_path documented");

    ok($params->{working_dir}, "$op: working_dir published");
}

# ── Wrong shapes are rejected cleanly ────────────────────────────────

sub transfer_error {
    my (%params) = @_;
    my $result = $rx->execute({
        operation => 'transfer_files',
        host => 'somehost',
        %params,
    }, {});
    return $result;
}

my $r = transfer_error(files => ['/tmp/test_file.txt']);
ok(!$r->{success}, 'bare string rejected');
unlike($r->{error}, qr/strict refs/, 'no strict-refs leak');
unlike($r->{error}, qr/ as a HASH ref/, 'no hash-ref type error');
unlike($r->{error}, qr/ at \S+ line \d+/, 'no caller-location leak');
like($r->{error}, qr/files\[0\]/, 'error names the offending index');
like($r->{error}, qr/local_path and remote_path/, 'error states the expected shape');
like($r->{error}, qr{/tmp/test_file\.txt}, 'error quotes the offending value');

# A bad entry later in the array is caught before anything is copied.
my $mixed = {
    operation => 'transfer_files',
    host => 'somehost',
    files => [
        { local_path => 'a.txt', remote_path => 'a.txt' },
        '/tmp/second.txt',
    ],
};
$r = $rx->execute($mixed, {});
ok(!$r->{success}, 'mixed array rejected');
like($r->{error}, qr/files\[1\]/, 'mixed array names the bad index');
unlike($r->{error}, qr/strict refs/, 'mixed array: no strict-refs leak');

# Missing keys inside an object.
$r = transfer_error(files => [{ local_path => 'a.txt' }]);
ok(!$r->{success}, 'object without remote_path rejected');
like($r->{error}, qr/files\[0\] is missing remote_path/, 'missing key named');

$r = transfer_error(files => [{ remote_path => 'a.txt' }]);
ok(!$r->{success}, 'object without local_path rejected');
like($r->{error}, qr/files\[0\] is missing local_path/, 'missing key named');

# retrieve_files validates the same way.
my $ret = $rx->execute({
    operation => 'retrieve_files',
    host => 'somehost',
    files => ['/tmp/remote.txt'],
}, {});
ok(!$ret->{success}, 'retrieve_files rejects bare string');
like($ret->{error}, qr/files\[0\]/, 'retrieve_files names the offending index');
unlike($ret->{error}, qr/strict refs/, 'retrieve_files: no strict-refs leak');

# ── remote_path resolution ───────────────────────────────────────────

my $spec = $rx->_file_spec_paths({ local_path => 'a.txt', remote_path => 'a.txt' }, 0, undef);
is($spec->{remote_path}, '/tmp/a.txt', 'relative remote_path defaults under /tmp');
is($spec->{local_path}, 'a.txt', 'local_path is left alone');

$spec = $rx->_file_spec_paths({ local_path => 'a.txt', remote_path => 'sub/a.txt' }, 0, '/srv/work/');
is($spec->{remote_path}, '/srv/work/sub/a.txt', 'relative remote_path resolves under working_dir');

$spec = $rx->_file_spec_paths({ local_path => 'a.txt', remote_path => '/abs/a.txt' }, 0, '/srv/work');
is($spec->{remote_path}, '/abs/a.txt', 'absolute remote_path ignores working_dir');

done_testing();
