#!/usr/bin/env perl
# Regression test for the bug where switching away from a provider
# (and back) wiped the per-model scoped settings (e.g. show_thinking).
#
# Scenario:
#   1. User on minimax/MiniMax-M3 runs `/api set thinking on`
#      -> show_thinking=1 stored in model_configs->{minimax/MiniMax-M3}
#   2. User runs `/api provider nvidia`
#      -> set_provider resets model to a default nvidia one
#      -> top-level show_thinking gets reset to 0 in memory by
#         _restore_model_config when restoring the new (default-less)
#         nvidia model.
#      -> save() then writes the CURRENT (0) value at top level because
#         user_set->{show_thinking} was set when the user did /api set.
#   3. User runs `/api provider minimax`
#      -> set_provider restores minimax's saved model_configs entry.
#      -> _restore_model_config finds {show_thinking: 1} and restores it.
#
# The above flow should preserve the user's per-model settings. The
# test below simulates it and asserts that show_thinking=1 for minimax
# after the round-trip.

use strict;
use warnings;
use lib './lib';
use Test::More;
use File::Temp qw(tempdir);
use CLIO::Util::JSON qw(decode_json);
require CLIO::Core::Config;  # Force load before instantiation
use CLIO::Core::Config;

sub read_disk {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read $path: $!";
    my $raw = do { local $/; <$fh> };
    close $fh;
    return decode_json($raw);
}

subtest 'round-trip: per-model show_thinking survives provider switch' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    # User configures minimax initially (this matches /api provider minimax)
    ok($config->set_provider('minimax'), 'set_provider(minimax) returned success');
    # Default model is minimax/MiniMax-M3 per Providers.pm
    is($config->{config}{model}, 'minimax/MiniMax-M3',
        'default model for minimax is minimax/MiniMax-M3');

    # User turns thinking on via /api set thinking on
    $config->set('show_thinking', 1, 1);
    $config->save();

    # Verify on-disk state immediately after /api set
    my $disk1 = read_disk("$tmpdir/config.json");
    is($disk1->{show_thinking}, 1, 'show_thinking=1 written at top level');
    is($disk1->{model_configs}{'minimax/MiniMax-M3'}{show_thinking}, 1,
        'show_thinking=1 also stored in model_configs{minimax/MiniMax-M3}');

    # Switch provider to nvidia (mimics /api provider nvidia)
    ok($config->set_provider('nvidia'), 'set_provider(nvidia) returned success');
    $config->save();

    # In-memory state for nvidia
    is($config->{config}{provider}, 'nvidia', 'in-memory provider now nvidia');
    like($config->{config}{model}, qr/^nvidia\//,
        'in-memory model is now an nvidia/* entry');

    # model_configs should still have the minimax entry intact
    my $mc = $config->{config}{model_configs};
    ok(exists $mc->{'minimax/MiniMax-M3'},
        'model_configs preserves the minimax entry after switch to nvidia');
    is($mc->{'minimax/MiniMax-M3'}{show_thinking}, 1,
        'minimax model_configs->{show_thinking} still 1 after switch to nvidia');

    # Now switch BACK to minimax (mimics /api provider minimax)
    ok($config->set_provider('minimax'), 'set_provider(minimax) returned success');
    $config->save();

    # In-memory: minimax's settings should be restored
    is($config->{config}{provider}, 'minimax', 'provider back to minimax');
    is($config->{config}{model}, 'minimax/MiniMax-M3',
        'model back to minimax/MiniMax-M3');
    is($config->{config}{show_thinking}, 1,
        'show_thinking restored to 1 on switch back to minimax');

    # And model_configs should still keep the minimax entry
    is($config->{config}{model_configs}{'minimax/MiniMax-M3'}{show_thinking}, 1,
        'model_configs{minimax/MiniMax-M3}{show_thinking} is still 1');
};

subtest 'round-trip with FULL save/reload cycle: settings survive end-to-end' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    # Session 1: configure and switch providers
    {
        my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
        $config->set_provider('minimax');
        $config->set('show_thinking', 1, 1);
        # Switch to nvidia and save
        $config->set_provider('nvidia');
        $config->save();
        # Switch back to minimax and save
        $config->set_provider('minimax');
        $config->save();

        is($config->{config}{show_thinking}, 1,
            'session1: show_thinking=1 after round-trip');
    }

    # Session 2: load fresh (simulates new CLIO invocation)
    {
        my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
        is($config->{config}{provider}, 'minimax',
            'session2: provider is minimax after fresh load');
        is($config->{config}{show_thinking}, 1,
            'session2: show_thinking=1 (the bug case - was previously wiped)');
    }
};

done_testing();
