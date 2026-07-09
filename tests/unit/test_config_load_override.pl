#!/usr/bin/env perl
# Regression test for the silent override bug.
#
# Bug: On every load(), Config.pm unconditionally copied values from
# model_configs->{$current_model} into $self->{config}, even when those
# values equaled DEFAULT_CONFIG. Combined with stale model_configs entries
# (created on prior sessions before the user changed global settings),
# this caused `/api set thinking on` and `/api set context_window N` to
# appear to silently reset on every new session.
#
# Example before the fix (user's actual config):
#   Top-level:           show_thinking=1, cap_context_window=64000  (user's intent)
#   model_configs:       show_thinking=0, cap_context_window=0       (stale defaults)
#   After load():        show_thinking=0, cap_context_window=0       (clobbered!)
#
# Fix: load()'s Restore block only applies model_configs values that
# DIFFER from DEFAULT_CONFIG. Stale default-value entries are ignored.

use strict;
use warnings;
use lib './lib';
use Test::More;
use File::Temp qw(tempdir);

use CLIO::Core::Config;

# Helper: write a crafted config.json into a temp dir, load it, return the result.
sub load_with_disk {
    my (%disk) = @_;
    my $tmpdir = tempdir(CLEANUP => 1);
    require CLIO::Util::JSON;
    my $json = CLIO::Util::JSON::encode_json(\%disk);
    open my $fh, '>', "$tmpdir/config.json" or die "Cannot write: $!";
    print $fh $json;
    close $fh;
    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
    return ($config, $tmpdir);
}

subtest 'Global /api set thinking on survives new session (stale model_configs entries ignored)' => sub {
    # Simulate the exact bug: top-level says thinking on, model_configs
    # entry for current model still has the stale default 0.
    my %disk = (
        api_bases   => {},
        api_keys    => {},
        model       => 'minimax/MiniMax-M3',
        provider    => 'minimax',
        show_thinking   => 1,
        thinking_effort => 'high',
        thinking_mode   => 'auto',
        model_configs   => {
            'minimax/MiniMax-M3' => {
                show_thinking   => 0,           # stale default - should NOT override top-level
                thinking_effort => 'medium',    # stale default - should NOT override top-level
                thinking_mode   => 'auto',
                cap_context_window => 0,        # stale default - should NOT override top-level
                cap_max_output     => 0,
                cap_max_prompt     => 0,
                force_reasoning    => '',
                force_tools        => '',
                force_vision       => '',
                sampling_temperature => '',
                sampling_top_p => '',
                sampling_top_k => '',
            },
        },
    );
    my ($config) = load_with_disk(%disk);

    is($config->{config}{show_thinking}, 1, 'thinking on preserved (model_configs stale 0 ignored)');
    is($config->{config}{thinking_effort}, 'high', 'thinking effort preserved (model_configs stale medium ignored)');
};

subtest 'Global /api set context_window 64000 survives new session' => sub {
    my %disk = (
        api_bases => {},
        api_keys  => {},
        model     => 'minimax/MiniMax-M3',
        provider  => 'minimax',
        cap_context_window => 64000,
        model_configs => {
            'minimax/MiniMax-M3' => {
                show_thinking   => 0,
                thinking_effort => 'medium',
                thinking_mode   => 'auto',
                cap_context_window => 0,         # stale default - should NOT override top-level
                cap_max_output     => 0,
                cap_max_prompt     => 0,
                force_reasoning    => '',
                force_tools        => '',
                force_vision       => '',
                sampling_temperature => '',
                sampling_top_p => '',
                sampling_top_k => '',
            },
        },
    );
    my ($config) = load_with_disk(%disk);

    is($config->{config}{cap_context_window}, 64000, 'cap_context_window=64000 preserved');
};

subtest 'Explicit per-model overrides still apply (regression for the fix)' => sub {
    # If the model_configs entry has a NON-default value (an explicit
    # per-model override), it should still take precedence over top-level.
    my %disk = (
        api_bases => {},
        api_keys  => {},
        model     => 'minimax/MiniMax-M3',
        provider  => 'minimax',
        show_thinking   => 0,   # global default
        thinking_effort => 'medium',
        thinking_mode   => 'auto',
        model_configs => {
            'minimax/MiniMax-M3' => {
                show_thinking   => 1,             # explicit per-model override ON
                thinking_effort => 'medium',
                thinking_mode   => 'auto',
                cap_context_window => 0,
                cap_max_output     => 0,
                cap_max_prompt     => 0,
                force_reasoning    => '',
                force_tools        => '',
                force_vision       => '',
                sampling_temperature => '',
                sampling_top_p => '',
                sampling_top_k => '',
            },
        },
    );
    my ($config) = load_with_disk(%disk);

    is($config->{config}{show_thinking}, 1, 'explicit per-model override=1 is applied');
};

subtest 'Explicit per-model cap_context_window override applies' => sub {
    my %disk = (
        api_bases => {},
        api_keys  => {},
        model     => 'minimax/MiniMax-M3',
        provider  => 'minimax',
        cap_context_window => 0,             # global default
        model_configs => {
            'minimax/MiniMax-M3' => {
                show_thinking   => 0,
                thinking_effort => 'medium',
                thinking_mode   => 'auto',
                cap_context_window => 128000,  # explicit per-model override
                cap_max_output     => 0,
                cap_max_prompt     => 0,
                force_reasoning    => '',
                force_tools        => '',
                force_vision       => '',
                sampling_temperature => '',
                sampling_top_p => '',
                sampling_top_k => '',
            },
        },
    );
    my ($config) = load_with_disk(%disk);

    is($config->{config}{cap_context_window}, 128000, 'explicit per-model cap=128000 is applied');
};

subtest 'Top-level set then save: round-trip preserves values' => sub {
    # Baseline sanity: normal save/load flow without any model_configs shenanigans.
    my $tmpdir = tempdir(CLEANUP => 1);
    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
    $config->set('show_thinking', 1);
    $config->set('cap_context_window', 64000);
    $config->save();

    my $config2 = CLIO::Core::Config->new(config_dir => $tmpdir);
    is($config2->{config}{show_thinking}, 1, 'show_thinking round-trips through save/load');
    is($config2->{config}{cap_context_window}, 64000, 'cap_context_window round-trips through save/load');
};

done_testing();