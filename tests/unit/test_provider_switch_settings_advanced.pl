#!/usr/bin/env perl
# More aggressive round-trip tests for per-provider/model settings.
#
# Scenarios:
#   A. Setting show_thinking AFTER first provider switch
#   B. /api set model with explicit model name (not provider switch)
#   C. Multiple provider switches in sequence (3-way)
#   D. Setting thinking_effort alongside show_thinking
#   E. User explicitly sets show_thinking=0 on each provider

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
# A. Set thinking after first provider switch
# ============================================================================

subtest 'A: setting after first provider switch (no save in between)' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    $config->set_provider('minimax');
    $config->set('show_thinking', 1, 1);

    # Switch away and back
    $config->set_provider('nvidia');
    $config->save();
    $config->set_provider('minimax');
    $config->save();

    is($config->{config}{show_thinking}, 1,
        'A: show_thinking preserved through round-trip');
};

# ============================================================================
# B. /api set model with explicit model name
# ============================================================================

subtest 'B: /api set model moves settings between models' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    $config->set_provider('minimax');
    $config->set('show_thinking', 1, 1);
    $config->save();

    # Explicitly switch model (still on minimax)
    $config->set('model', 'minimax/MiniMax-Reasoning', 1);
    is($config->{config}{show_thinking}, 1,
        'B: explicit /api set model on same provider keeps settings');

    # Switch to a different model via set() with mark_user_set=1
    $config->set('model', 'nvidia/nemotron-3-ultra-550b-a55b', 1);
    # On a different provider (no entry), the global value is preserved
    # rather than reset to default. This is the documented behavior
    # (commit 28f3ffb6): global user-set values should persist across
    # model switches. The new-model entry is not auto-seeded because
    # cross-provider switches are an explicit "fresh start" signal at
    # the model level, but the user's global preference is still honored.
    is($config->{config}{show_thinking}, 1,
        'B: show_thinking global value preserved on different model (no entry)');

    # Switch BACK to minimax
    $config->set('model', 'minimax/MiniMax-M3', 1);
    is($config->{config}{show_thinking}, 1,
        'B: show_thinking restored when returning to saved model');

    $config->save();
    my $disk = read_disk("$tmpdir/config.json");
    is($disk->{model_configs}{'minimax/MiniMax-M3'}{show_thinking}, 1,
        'B: minimax entry on disk still has show_thinking=1');
    is($disk->{model_configs}{'minimax/MiniMax-Reasoning'}{show_thinking}, 1,
        'B: minimax entry on disk has show_thinking=1 for the second model too');
};

# ============================================================================
# C. Multiple provider switches in a sequence
# ============================================================================

subtest 'C: 3-way provider switch round-trip' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    $config->set_provider('minimax');
    $config->set('show_thinking', 1, 1);
    $config->save();

    # minimax -> nvidia -> deepseek -> minimax
    $config->set_provider('nvidia');
    $config->save();
    $config->set_provider('deepseek');
    $config->save();
    $config->set_provider('minimax');
    $config->save();

    is($config->{config}{show_thinking}, 1,
        'C: show_thinking survives 3-way round-trip');
    is($config->{config}{model_configs}{'minimax/MiniMax-M3'}{show_thinking}, 1,
        'C: model_configs retains minimax settings');
};

# ============================================================================
# D. Multiple scoped settings together
# ============================================================================

subtest 'D: multiple scoped settings preserved' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    $config->set_provider('minimax');
    $config->set('show_thinking', 1, 1);
    $config->set('thinking_effort', 'xhigh', 1);
    $config->set('sampling_temperature', 0.7, 1);
    $config->save();

    $config->set_provider('nvidia');
    $config->save();
    $config->set_provider('minimax');
    $config->save();

    is($config->{config}{show_thinking}, 1, 'D: show_thinking=1');
    is($config->{config}{thinking_effort}, 'xhigh', 'D: thinking_effort=xhigh');
    is($config->{config}{sampling_temperature}, 0.7, 'D: sampling_temperature=0.7');
};

# ============================================================================
# E. Reload from disk at each switch
# ============================================================================

subtest 'E: fresh reload between switches' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    # Initial setup
    {
        my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
        $config->set_provider('minimax');
        $config->set('show_thinking', 1, 1);
        $config->save();
    }

    # First switch (simulates end of session)
    {
        my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
        $config->set_provider('nvidia');
        $config->save();

        my $disk = read_disk("$tmpdir/config.json");
        is($disk->{model_configs}{'minimax/MiniMax-M3'}{show_thinking}, 1,
            'E: after switch+save, minimax entry on disk has show_thinking=1');
        isnt($disk->{model_configs}{'minimax/MiniMax-M3'}, undef,
            'E: minimax entry exists on disk after switch to nvidia');
    }

    # Second switch (simulates another session)
    {
        my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
        $config->set_provider('minimax');
        $config->save();

        is($config->{config}{show_thinking}, 1,
            'E: show_thinking=1 on switch back from fresh load');

        my $disk = read_disk("$tmpdir/config.json");
        is($disk->{model_configs}{'minimax/MiniMax-M3'}{show_thinking}, 1,
            'E: after switch back, minimax entry on disk STILL has show_thinking=1');
    }
};

done_testing();
