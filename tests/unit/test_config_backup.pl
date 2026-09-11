#!/usr/bin/perl
# Test: Config::save() backs up the existing config before overwriting it.
#
# Covers the date-stamped backup-on-save change. Each subtest gets its own
# private tempdir so backups don't leak across cases.
#
# Isolation: explicit tempdir config_dir -> never touches real ~/.clio.

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use CLIO::Util::JSON qw(encode_json);

use CLIO::Core::Config;

# Each subtest makes its own tempdir so the backup dir never accumulates
# files from a previous case.
sub make_fixture {
    my $td = tempdir(CLEANUP => 1);
    my $cfg_file = File::Spec->catfile($td, 'config.json');
    my $backup_dir = File::Spec->catfile($td, 'config_backups');
    my $config = CLIO::Core::Config->new(config_dir => $td);
    $config->{config} = {};
    $config->{user_set} = {};
    return ($td, $cfg_file, $backup_dir, $config);
}

sub seed_config {
    my ($cfg_file, $provider, $model) = @_;
    open my $fh, '>', $cfg_file or die "seed write: $!";
    print $fh encode_json({ provider => $provider, model => $model });
    close $fh;
}

sub backup_count {
    my ($backup_dir) = @_;
    return 0 unless -d $backup_dir;
    return scalar(glob(File::Spec->catfile($backup_dir, '*.json')));
}

sub live_model {
    my ($cfg_file) = @_;
    open my $fh, '<', $cfg_file or die "live read: $!";
    my $c = do { local $/; <$fh> }; close $fh;
    return $c;
}

# -----------------------------------------------------------------------------
# No backup when there's no pre-existing config (initial write)
# -----------------------------------------------------------------------------
subtest 'no backup created when config file does not exist yet' => sub {
    my ($td, $cfg_file, $backup_dir, $config) = make_fixture();
    $config->{config} = { provider => 'openai', model => 'openai/gpt-4.1' };
    $config->{user_set} = { provider => 1, model => 1 };
    ok($config->save(), 'initial save succeeds');
    is(backup_count($backup_dir), 0, 'no backup dir / files created on initial write');
    like(live_model($cfg_file), qr/openai\/gpt-4\.1/, 'live config written on initial save');
};

# -----------------------------------------------------------------------------
# Backup created with date-stamped filename and 0600 perms on first overwrite
# -----------------------------------------------------------------------------
subtest 'backup created with date-stamped name and secure perms on overwrite' => sub {
    my ($td, $cfg_file, $backup_dir, $config) = make_fixture();
    seed_config($cfg_file, 'anthropic', 'anthropic/claude-3-opus');

    $config->{config} = { provider => 'openai', model => 'openai/gpt-4.1' };
    $config->{user_set} = { provider => 1, model => 1 };
    ok($config->save(), 'overwrite save succeeds');

    my @backups = glob(File::Spec->catfile($backup_dir, '*.json'));
    is(scalar(@backups), 1, 'exactly one backup created');
    my $name = (split(m!/!, $backups[0]))[-1];
    like($name, qr/^\d{8}_\d{6}\.json$/, "backup filename is date-stamped (got '$name')");
    my $mode = (stat($backups[0]))[2] & 0777;
    is($mode, 0600, 'backup has 0600 perms (contains API keys)');

    open my $fh, '<', $backups[0] or die "backup read: $!";
    my $content = do { local $/; <$fh> }; close $fh;
    like($content, qr/anthropic\/claude-3-opus/, 'backup preserves old content');
    like($content, qr/"provider":"anthropic"/, 'backup preserves old provider');

    like(live_model($cfg_file), qr/openai\/gpt-4\.1/, 'live config has new model');
};

# -----------------------------------------------------------------------------
# Same-second collision: second save disambiguates with _1 suffix
# -----------------------------------------------------------------------------
subtest 'same-second collision produces _1 suffix, no overwrite' => sub {
    my ($td, $cfg_file, $backup_dir, $config) = make_fixture();
    seed_config($cfg_file, 'anthropic', 'anthropic/claude-3-opus');

    # First overwrite -> backup #1 (base timestamp).
    $config->{config} = { provider => 'openai', model => 'openai/gpt-4.1' };
    $config->{user_set} = { provider => 1, model => 1 };
    $config->save();

    # Second overwrite in the same second -> must not clobber backup #1.
    $config->{config} = { provider => 'deepseek', model => 'deepseek/deepseek-v4-flash' };
    $config->save();

    my @backups = glob(File::Spec->catfile($backup_dir, '*.json'));
    is(scalar(@backups), 2, 'two backups exist, neither clobbered');

    my %names = map { (split(m!/!, $_))[-1] => $_ } @backups;
    my @sorted = sort keys %names;
    like($sorted[0], qr/^\d{8}_\d{6}\.json$/, 'first backup uses base stamp');
    like($sorted[1], qr/^\d{8}_\d{6}_1\.json$/, 'second backup uses _1 suffix');

    open my $fh, '<', $names{$sorted[0]} or die $!;
    my $first = do { local $/; <$fh> }; close $fh;
    like($first, qr/anthropic\/claude-3-opus/, 'first backup preserves original seed');
};

done_testing();
