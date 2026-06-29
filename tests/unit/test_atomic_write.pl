#!/usr/bin/env perl

# Test CLIO::Util::AtomicWrite
# Validates atomic write behavior: basic writes, encoding, permissions, error handling

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More tests => 18;
use File::Temp qw(tempdir);
use File::Spec;

use_ok('CLIO::Util::AtomicWrite', 'atomic_write');

my $tmpdir = tempdir(CLEANUP => 1);

# Test 1: Basic raw write
{
    my $file = File::Spec->catfile($tmpdir, 'basic.txt');
    ok(atomic_write($file, "hello world"), 'atomic_write returns true');
    ok(-e $file, 'file exists after write');
    open my $fh, '<:raw', $file;
    my $content = do { local $/; <$fh> };
    close $fh;
    is($content, "hello world", 'content matches');
}

# Test 2: UTF-8 encoding mode
{
    my $file = File::Spec->catfile($tmpdir, 'utf8.txt');
    atomic_write($file, "café naïve 日本語", encoding => 'UTF-8');
    open my $fh, '<:encoding(UTF-8)', $file;
    my $content = do { local $/; <$fh> };
    close $fh;
    is($content, "café naïve 日本語", 'UTF-8 content round-trips');
}

# Test 3: File permissions
{
    my $file = File::Spec->catfile($tmpdir, 'secure.txt');
    atomic_write($file, "secret", mode => 0600);
    my $perms = (stat($file))[2] & 07777;
    is($perms, 0600, 'file has restricted permissions');
}

# Test 4: Overwrite existing file atomically
{
    my $file = File::Spec->catfile($tmpdir, 'overwrite.txt');
    atomic_write($file, "version 1");
    atomic_write($file, "version 2");
    open my $fh, '<:raw', $file;
    my $content = do { local $/; <$fh> };
    close $fh;
    is($content, "version 2", 'overwrite replaces content');
}

# Test 5: No temp file left behind
{
    my $file = File::Spec->catfile($tmpdir, 'clean.txt');
    atomic_write($file, "data");
    my @temps = glob("$file.tmp.*");
    is(scalar @temps, 0, 'no temp files left behind');
}

# Test 6: Write to nonexistent directory fails gracefully
{
    my $bad_file = File::Spec->catfile($tmpdir, 'nonexistent', 'sub', 'file.txt');
    eval { atomic_write($bad_file, "data") };
    ok($@, 'write to nonexistent dir throws error');
    like($@, qr/Cannot create temp file/, 'error message mentions temp file');
}

# Test 7: undef content is rejected (defensive check)
{
    my $file = File::Spec->catfile($tmpdir, 'undef.txt');
    eval { atomic_write($file, undef) };
    ok($@, 'undef content throws error');
    like($@, qr/undef content/, 'error mentions undef content');
    ok(!-e $file, 'no file created for undef content');
}

# Test 8: hash ref content is rejected (defensive check)
{
    my $file = File::Spec->catfile($tmpdir, 'hashref.txt');
    my $bad = { type => '__TIMEOUT__' };
    eval { atomic_write($file, $bad) };
    ok($@, 'hashref content throws error');
    like($@, qr/ref\(HASH\)/, 'error mentions ref type');
    ok(!-e $file, 'no file created for hashref content');
}

# Test 9: empty string is allowed (legitimate use case: clearing a file)
{
    my $file = File::Spec->catfile($tmpdir, 'cleared.txt');
    atomic_write($file, "initial content");
    atomic_write($file, "");
    ok(-e $file, 'empty write still creates file');
    open my $fh, '<:raw', $file;
    my $content = do { local $/; <$fh> };
    close $fh;
    is($content, "", 'empty content empties file');
}

print "\n All AtomicWrite tests passed!\n";
