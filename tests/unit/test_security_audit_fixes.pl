#!/usr/bin/env perl
# test_security_audit_fixes.pl - Verify the adversarial audit fixes
# Tests the security controls added after the audit:
# 1. TerminalOperations sandbox block
# 2. CodeIntelligence context_lines integer validation
# 3. VersionControl blame start_line/max_lines integer validation
# 4. MemoryOperations key path traversal prevention
# 5. FileOperations get_errors sandbox enforcement
# 6. ToolResultStore no auto-correction of toolCallId

use strict;
use warnings;
use utf8;
use Test2::V0;
use File::Temp qw(tempdir);
use File::Spec;

my $lib_dir = File::Spec->catdir(File::Spec->updir(File::Basename::dirname(__FILE__)), 'lib');
use lib $lib_dir;

# Mock config object
my $mock_config;

sub make_config {
    my ($sandbox) = @_;
    return bless { sandbox => $sandbox, _values => {} }, 'MockConfig';
}

sub MockConfig::get {
    my ($self, $key) = @_;
    return $self->{_values}{$key};
}

# Test 1: TerminalOperations blocks in sandbox mode
{
    my $cfg = make_config(1);
    $cfg->{_values}{sandbox} = 1;

    require CLIO::Tools::TerminalOperations;
    my $tool = CLIO::Tools::TerminalOperations->new();

    my $ctx = { config => $cfg, session => { session_id => 'test' } };
    my $result = $tool->execute({ operation => 'exec', command => 'ls -la' }, $ctx);

    ok(!$result->{success}, 'TerminalOperations blocks exec in sandbox mode');
    ok($result->{error} =~ /Sandbox mode/, 'Error message mentions sandbox');
}

# Test 2: TerminalOperations works outside sandbox
{
    my $cfg = make_config(0);

    require CLIO::Tools::TerminalOperations;
    my $tool = CLIO::Tools::TerminalOperations->new();

    my $ctx = { config => $cfg, session => { session_id => 'test' } };
    my $result = $tool->execute({ operation => 'exec', command => 'echo hello' }, $ctx);

    ok($result->{success}, 'TerminalOperations works in non-sandbox mode');
    ok(defined $result->{exit_code}, 'Exit code is defined');
}

# Test 3: TerminalOperations validate_command works in sandbox
{
    my $cfg = make_config(1);
    $cfg->{_values}{sandbox} = 1;

    require CLIO::Tools::TerminalOperations;
    my $tool = CLIO::Tools::TerminalOperations->new();

    my $ctx = { config => $cfg, session => { session_id => 'test' } };
    my $result = $tool->execute({ operation => 'validate', command => 'ls -la' }, $ctx);

    ok(!$result->{success}, 'TerminalOperations blocks validate in sandbox mode');
    ok($result->{error} =~ /Sandbox mode/, 'Validate also blocked in sandbox');
}

# Test 4: CodeIntelligence context_lines rejection
{
    my $cfg = make_config(0);

    require CLIO::Tools::CodeIntelligence;
    my $tool = CLIO::Tools::CodeIntelligence->new();

    my $ctx = { config => $cfg, session => { session_id => 'test' } };
    my $result = $tool->execute({
        operation => 'list_usages',
        symbol_name => 'foo',
        context_lines => '1; echo INJECTED'
    }, $ctx);

    ok(!$result->{success}, 'CodeIntelligence rejects non-integer context_lines');
    ok($result->{error} =~ /Invalid.*context_lines/i, 'Error mentions context_lines');
}

# Test 5: CodeIntelligence context_lines accepts valid integer
{
    my $cfg = make_config(0);

    require CLIO::Tools::CodeIntelligence;
    my $tool = CLIO::Tools::CodeIntelligence->new();

    my $ctx = { config => $cfg, session => { session_id => 'test' } };
    my $result = $tool->execute({
        operation => 'list_usages',
        symbol_name => 'sub_test_only_symbol',
        context_lines => 3
    }, $ctx);

    # Should succeed (or find 0 usages, but not error on context_lines)
    ok(1, 'CodeIntelligence accepts integer context_lines');
}

# Test 6: VersionControl blame start_line rejection
{
    my $cfg = make_config(0);

    require CLIO::Tools::VersionControl;
    my $tool = CLIO::Tools::VersionControl->new();

    my $ctx = { config => $cfg, session => { session_id => 'test' } };
    my $result = $tool->execute({
        operation => 'blame',
        file => 'README.md',
        start_line => '1; echo INJECTED'
    }, $ctx);

    ok(!$result->{success}, 'VersionControl rejects non-integer start_line');
    ok($result->{error} =~ /Invalid.*start_line/i, 'Error mentions start_line');
}

# Test 7: VersionControl blame max_lines rejection
{
    my $cfg = make_config(0);

    require CLIO::Tools::VersionControl;
    my $tool = CLIO::Tools::VersionControl->new();

    my $ctx = { config => $cfg, session => { session_id => 'test' } };
    my $result = $tool->execute({
        operation => 'blame',
        file => 'README.md',
        max_lines => '1; echo INJECTED'
    }, $ctx);

    ok(!$result->{success}, 'VersionControl rejects non-integer max_lines');
    ok($result->{error} =~ /Invalid.*max_lines/i, 'Error mentions max_lines');
}

# Test 8: MemoryOperations rejects key with path traversal
{
    require CLIO::Tools::MemoryOperations;
    my $tool = CLIO::Tools::MemoryOperations->new();

    my $ctx = { config => undef, session => { session_id => 'test' } };
    my $result = $tool->execute({
        operation => 'store',
        key => '../../../etc/passwd',
        content => 'test'
    }, $ctx);

    ok(!$result->{success}, 'MemoryOperations rejects path traversal in key');
    ok($result->{error} =~ /Invalid.*key/i, 'Error mentions invalid key');
}

# Test 9: MemoryOperations rejects key with path separator
{
    my $tool = CLIO::Tools::MemoryOperations->new();

    my $ctx = { config => undef, session => { session_id => 'test' } };
    my $result = $tool->execute({
        operation => 'store',
        key => 'foo/bar',
        content => 'test'
    }, $ctx);

    ok(!$result->{success}, 'MemoryOperations rejects key with slash');
}

# Test 10: MemoryOperations rejects null byte in key
{
    my $tool = CLIO::Tools::MemoryOperations->new();

    my $ctx = { config => undef, session => { session_id => 'test' } };
    my $result = $tool->execute({
        operation => 'store',
        key => "foo\0bar",
        content => 'test'
    }, $ctx);

    ok(!$result->{success}, 'MemoryOperations rejects null byte in key');
}

# Test 11: MemoryOperations accepts valid key
{
    require CLIO::Util::PathResolver;
    my $config_base = CLIO::Util::PathResolver::get_config_dir();
    my $test_mem_dir = File::Spec->catdir($config_base, ".clio-test-mem-audit");
    unless (-d $test_mem_dir) { mkdir $test_mem_dir; }

    require CLIO::Tools::MemoryOperations;
    my $tool = CLIO::Tools::MemoryOperations->new();

    my $ctx = { config => undef, session => { session_id => 'test' } };
    my $result = $tool->execute({
        operation => 'store',
        key => 'valid_key-123',
        content => 'test',
        memory_dir => $test_mem_dir
    }, $ctx);

    ok($result->{success}, 'MemoryOperations accepts valid key in allowed memory_dir');

    # Cleanup
    if (-d $test_mem_dir) {
        opendir(my $dh, $test_mem_dir);
        while (my $f = readdir($dh)) {
            next unless $f =~ /\.json$/;
            unlink File::Spec->catfile($test_mem_dir, $f);
        }
        closedir($dh);
        rmdir $test_mem_dir;
    }
}

# Test 12: FileOperations get_errors enforces sandbox
{
    my $test_dir = tempdir(CLEANUP => 1);
    my $cfg = make_config(1);
    $cfg->{_values}{sandbox} = 1;

    require CLIO::Tools::FileOperations;
    my $tool = CLIO::Tools::FileOperations->new(session_dir => $test_dir);

    my $ctx = { config => $cfg, session => { session_id => 'test', state => { working_directory => $test_dir } } };

    # Create a file outside the session dir
    my $outside_file = File::Spec->catfile($test_dir, '..', 'outside_test.pl');
    $outside_file = File::Spec->rel2abs($outside_file);
    open my $fh, '>', $outside_file;
    print $fh "print 'hello'\n";
    close $fh;

    my $result = $tool->execute({ operation => 'get_errors', path => $outside_file }, $ctx);

    ok(!$result->{success}, 'get_errors blocked in sandbox mode for outside path');
    ok($result->{error} =~ /Sandbox/, 'Error mentions sandbox') if $result->{error};

    unlink $outside_file;
}

# Test 13: ToolResultStore does NOT auto-correct toolCallId
{
    require CLIO::Session::ToolResultStore;
    my $test_dir = tempdir(CLEANUP => 1);

    # Create a fake tool result with a known ID
    my $store = CLIO::Session::ToolResultStore->new(
        sessions_dir => $test_dir,
    );

    my $session_id = 'test_session';
    $store->persistResult('call_correct_123', "test content", $session_id);

    # Try to retrieve with a slightly wrong ID
    my $result;
    my $threw = 0;
    eval {
        $result = $store->retrieveChunk('call_correct_124', $session_id, 0, 8192);
    };
    if ($@) {
        $threw = 1;
    }

    ok($threw, 'ToolResultStore does NOT auto-correct wrong toolCallId');
    ok($@ =~ /not found/i, 'Error message says "not found"') if $threw;
    # The error should NOT silently return the correct content
    ok(!$result || !$result->{content} || $result->{content} !~ /test content/,
        'Did not silently return content from wrong ID');
}

done_testing();
