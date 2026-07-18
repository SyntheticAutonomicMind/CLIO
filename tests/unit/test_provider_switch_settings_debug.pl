#!/usr/bin/env perl
# More specific scenarios to reproduce the per-provider/model setting loss.

use strict;
use warnings;
use lib './lib';
use Test::More;
use File::Temp qw(tempdir);

require CLIO::Core::Config;
use CLIO::Core::Config;
use CLIO::Util::JSON qw(decode_json);

sub read_disk {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read $path: $!";
    my $raw = do { local $/; <$fh> };
    close $fh;
    return decode_json($raw);
}

# ============================================================================
# Scenario 1: --model with explicit provider prefix on minimax
# (Different model within the same provider)
# ============================================================================

subtest '1: --model switches within same provider follows per-provider settings' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    $config->set_provider('minimax');
    $config->set('show_thinking', 1, 1);
    $config->save();

    is($config->{config}{show_thinking}, 1, 'show_thinking=1 on minimax');

    # Simulate clio --model minimax/MiniMax-Reasoning (override, mark=0)
    $config->set('model', 'minimax/MiniMax-Reasoning', 0);

    # With the fix, switching models within the same provider seeds the new
    # model's entry from the old one. show_thinking=1 follows the user
    # across model changes within minimax.
    is($config->{config}{show_thinking}, 1,
        '1: show_thinking follows user across models in same provider');

    # Now save - top-level show_thinking stays 1 (the user's setting for
    # the minimax provider follows across models on that provider).
    $config->save();

    my $disk = read_disk("$tmpdir/config.json");
    is($disk->{show_thinking}, 1,
        '1: top-level show_thinking stays 1 (followed across model switch)');

    # Switch BACK to the original minimax model
    $config->set('model', 'minimax/MiniMax-M3', 0);
    # This should still show_thinking=1
    is($config->{config}{show_thinking}, 1,
        '1: show_thinking=1 after switching back to original model');
};

# ============================================================================
# Scenario 2: load() with stale model_configs entries
# ============================================================================

subtest '2: load() restores correct values' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    # Session 1: configure and save
    {
        my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
        $config->set_provider('minimax');
        $config->set('show_thinking', 1, 1);
        $config->save();
    }

    # Session 2: switch to nvidia and save (but do nothing else)
    {
        my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
        $config->set_provider('nvidia');
        $config->save();
    }

    # Session 3: switch back
    {
        my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
        $config->set_provider('minimax');
        $config->save();
        is($config->{config}{show_thinking}, 1,
            '2: show_thinking=1 after switching back');

        my $disk = read_disk("$tmpdir/config.json");
        is($disk->{model_configs}{'minimax/MiniMax-M3'}{show_thinking}, 1,
            '2: model_configs minimax entry still has show_thinking=1');
    }
};

# ============================================================================
# Scenario 3: What if user changes model (not provider) then switches provider?
# ============================================================================

subtest '3: change model then provider then back' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    $config->set_provider('minimax');
    $config->set('show_thinking', 1, 1);
    $config->save();

    # Change model within same provider - show_thinking follows
    $config->set('model', 'minimax/MiniMax-Reasoning', 1);
    is($config->{config}{show_thinking}, 1,
        '3: show_thinking follows user to new model on same provider');
    $config->save();

    # Switch provider - falls back to defaults for nvidia (no minimax
    # entry to seed from, different provider)
    $config->set_provider('nvidia');
    $config->save();

    # Switch back to minimax
    $config->set_provider('minimax');
    $config->save();

    # The model is back to 'minimax/MiniMax-M3' (the default)
    is($config->{config}{model}, 'minimax/MiniMax-M3',
        '3: model back to default');
    is($config->{config}{show_thinking}, 1,
        '3: show_thinking=1 restored');
};

# ============================================================================
# Scenario 4: Multiple models within same provider, all should preserve
# ============================================================================

subtest '4: per-MODEL settings work, not just per-provider' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    $config->set_provider('minimax');
    $config->set('model', 'minimax/MiniMax-M3', 1);
    $config->set('show_thinking', 1, 1);
    $config->save();

    # Change to another model on same provider
    $config->set('model', 'minimax/MiniMax-Reasoning', 1);
    $config->set('show_thinking', 0, 1);  # explicitly off for this model
    $config->save();

    my $disk = read_disk("$tmpdir/config.json");
    is($disk->{model_configs}{'minimax/MiniMax-M3'}{show_thinking}, 1,
        '4: MiniMax-M3 has show_thinking=1');
    is($disk->{model_configs}{'minimax/MiniMax-Reasoning'}{show_thinking}, 0,
        '4: MiniMax-Reasoning has show_thinking=0');

    # Switch back to original
    $config->set('model', 'minimax/MiniMax-M3', 1);
    is($config->{config}{show_thinking}, 1,
        '4: switch back to MiniMax-M3 -> show_thinking=1');
    is($config->{config}{model_configs}{'minimax/MiniMax-Reasoning'}{show_thinking}, 0,
        '4: MiniMax-Reasoning entry unchanged');
};

done_testing();
