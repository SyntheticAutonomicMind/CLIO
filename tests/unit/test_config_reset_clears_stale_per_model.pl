#!/usr/bin/env perl
# Regression test for the stale-per-model-shadow bug.
#
# Bug: When the user runs `/api set X off` to reset a model-scoped
# config (sampling_*, cap_*, force_*, show_thinking, thinking_effort,
# thinking_mode), the reset only updated the CURRENT model's entry in
# model_configs. If a stale entry for a DIFFERENT model had the same
# key set to a non-default value, that stale value was restored on the
# next load, silently resurrecting the value the user thought they
# had cleared.
#
# User scenario (real report):
#   - User starts with default model `llama.cpp/local-model` (hyphen).
#   - Runs `/api set temperature 1`, etc. Creates entries for hyphen.
#   - Switches to `--model llama.cpp/local_model` (underscore). The
#     hyphen entry keeps the user's value.
#   - User runs `/api set temperature off`. Reset only touched the
#     underscore entry; hyphen entry still had `1`.
#   - Restart. Load reads default model (hyphen), applies stale
#     `sampling_temperature=1` to global. User's reset was gone.
#
# Fix: Config::clear_model_scoped($key) deletes a model-scoped key
# from EVERY model_configs entry. The /api set handlers call this in
# addition to set($key, '') when the user uses a reset trigger word
# (off/reset/default). set($key, default_value) alone still creates a
# per-model override, so users can still pin a specific model to a
# value that happens to match the global default (e.g. show_thinking=0
# for one model while another stays at 1).

use strict;
use warnings;
use lib './lib';
use Test::More;
use File::Temp qw(tempdir);

use CLIO::Core::Config;
use CLIO::Util::JSON qw(encode_json);

sub write_disk {
    my ($dir, $data) = @_;
    open my $fh, '>', "$dir/config.json" or die "Cannot write: $!";
    print $fh encode_json($data);
    close $fh;
}

# ============================================================================
# 1. The exact user-reported scenario: reset clears stale hyphen entry
# ============================================================================

subtest 'reset on current model deletes stale entry from default model' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    # Two model_configs entries, both with stale sampling_temperature=1.
    # Current model has underscore suffix (user picked it via --model).
    write_disk($tmpdir, {
        api_base => 'http://localhost:9090/v1/chat/completions',
        api_key  => '1234',
        model    => 'llama.cpp/local_model',
        provider => 'llama.cpp',
        show_thinking   => 1,
        thinking_effort => 'high',
        thinking_mode   => 'enabled',
        sampling_temperature => '1',
        sampling_top_p       => '0.95',
        sampling_top_k       => '40',
        model_configs => {
            'llama.cpp/local-model' => {
                sampling_temperature => '1',
                sampling_top_p       => '0.95',
                sampling_top_k       => '40',
            },
            'llama.cpp/local_model' => {
                sampling_temperature => '1',
                sampling_top_p       => '0.95',
                sampling_top_k       => '40',
            },
        },
    });

    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    is($config->{config}{sampling_temperature}, '1', 'precondition: global has stale value');

    # Simulate /api set temperature off: set('', 1) + clear_model_scoped + save
    for my $key (qw(sampling_temperature sampling_top_p sampling_top_k)) {
        $config->set($key, '', 1);
        $config->clear_model_scoped($key);
    }
    $config->save();

    is($config->{config}{sampling_temperature}, '', 'global cleared');
    is($config->{config}{sampling_top_p},       '', 'global cleared');
    is($config->{config}{sampling_top_k},       '', 'global cleared');

    # CRITICAL: stale hyphen entry also has its keys removed
    my $mc = $config->{config}{model_configs};
    ok(!exists $mc->{'llama.cpp/local-model'}{sampling_temperature},
        'stale hyphen entry: sampling_temperature deleted');
    ok(!exists $mc->{'llama.cpp/local-model'}{sampling_top_p},
        'stale hyphen entry: sampling_top_p deleted');
    ok(!exists $mc->{'llama.cpp/local-model'}{sampling_top_k},
        'stale hyphen entry: sampling_top_k deleted');

    ok(!exists $mc->{'llama.cpp/local_model'}{sampling_temperature},
        'current underscore entry: sampling_temperature deleted');
    ok(!exists $mc->{'llama.cpp/local_model'}{sampling_top_p},
        'current underscore entry: sampling_top_p deleted');
    ok(!exists $mc->{'llama.cpp/local_model'}{sampling_top_k},
        'current underscore entry: sampling_top_k deleted');

    # Round-trip: reload and verify the bug doesn't come back
    my $config2 = CLIO::Core::Config->new(config_dir => $tmpdir);
    is($config2->{config}{sampling_temperature}, '',
        'reload: global still cleared (stale entry did not resurrect)');
    is($config2->{config}{sampling_top_p},       '',
        'reload: global still cleared');
    is($config2->{config}{sampling_top_k},       '',
        'reload: global still cleared');
};

# ============================================================================
# 2. set() alone (without clear_model_scoped) still creates a per-model override
#    even when the value happens to equal the default. Users can still pin
#    one model to a "default-equivalent" value while another is customized.
# ============================================================================

subtest 'set() to default value still creates per-model override (regression for new fix)' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    write_disk($tmpdir, {
        api_base => 'http://localhost:9090/v1/chat/completions',
        api_key  => '1234',
        model    => 'minimax/MiniMax-M3',
        provider => 'minimax',
        show_thinking => 1,
        model_configs => {
            'minimax/MiniMax-M3' => {
                show_thinking => 1,
            },
        },
        model_configs_explicit => {
            'minimax/MiniMax-M3' => { show_thinking => 1 },
        },
    });

    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    # Switch to a sibling model and explicitly turn thinking OFF for it.
    # show_thinking=0 IS the default, but this is a deliberate per-model
    # override - the user wants MiniMax-Reasoning to have thinking off
    # while MiniMax-M3 has it on.
    $config->set('model', 'minimax/MiniMax-Reasoning', 1);
    $config->set('show_thinking', 0, 1);

    is($config->{config}{model_configs}{'minimax/MiniMax-Reasoning'}{show_thinking}, 0,
        'per-model entry created with value=0 (default value, but still an override)');

    $config->save();
    my $disk = $config->{config}{model_configs};
    is($disk->{'minimax/MiniMax-Reasoning'}{show_thinking}, 0,
        'per-model entry persists on disk');

    # MiniMax-M3's override (show_thinking=1) must still be intact
    is($disk->{'minimax/MiniMax-M3'}{show_thinking}, 1,
        'MiniMax-M3 entry preserved (different model, different intent)');

    # Switching back to MiniMax-M3 should restore the per-model override
    my $config2 = CLIO::Core::Config->new(config_dir => $tmpdir);
    $config2->set('model', 'minimax/MiniMax-M3', 1);
    is($config2->{config}{show_thinking}, 1,
        'switch back: MiniMax-M3 still has thinking on');

    $config2->set('model', 'minimax/MiniMax-Reasoning', 1);
    is($config2->{config}{show_thinking}, 0,
        'switch to MiniMax-Reasoning: thinking off (per-model override honored)');
};

# ============================================================================
# 3. clear_model_scoped also handles cap_* and force_* keys
# ============================================================================

subtest 'clear_model_scoped clears cap_* from all entries, leaves others alone' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    write_disk($tmpdir, {
        api_base => 'http://localhost:9090/v1/chat/completions',
        api_key  => '1234',
        model    => 'deepseek/deepseek-v4-flash',
        provider => 'deepseek',
        cap_context_window => '128000',
        model_configs => {
            'deepseek/deepseek-v4-pro' => {
                cap_context_window => '256000',
                cap_max_output     => '8192',
            },
            'deepseek/deepseek-v4-flash' => {
                cap_context_window => '128000',
            },
        },
    });

    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    # Reset context_window via /api: set(0) + clear_model_scoped
    $config->set('cap_context_window', 0, 1);
    my $cleared = $config->clear_model_scoped('cap_context_window');

    is($cleared, 2, 'cap_context_window cleared from 2 entries');
    ok(!exists $config->{config}{model_configs}{'deepseek/deepseek-v4-pro'}{cap_context_window},
        'cap cleared from deepseek-v4-pro');
    ok(!exists $config->{config}{model_configs}{'deepseek/deepseek-v4-flash'}{cap_context_window},
        'cap cleared from deepseek-v4-flash');

    # cap_max_output on deepseek-v4-pro should NOT be cleared
    is($config->{config}{model_configs}{'deepseek/deepseek-v4-pro'}{cap_max_output}, '8192',
        'cap_max_output on deepseek-v4-pro preserved');
};

# ============================================================================
# 4. clear_model_scoped is a no-op for keys not in any model_configs
# ============================================================================

subtest 'clear_model_scoped returns 0 when no entries have the key' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    write_disk($tmpdir, {
        api_base => 'http://localhost:9090/v1/chat/completions',
        api_key  => '1234',
        model    => 'minimax/MiniMax-M3',
        provider => 'minimax',
        model_configs => {
            'minimax/MiniMax-M3' => {
                show_thinking => 1,
            },
        },
    });

    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    my $cleared = $config->clear_model_scoped('sampling_temperature');
    is($cleared, 0, 'no entries had sampling_temperature');

    # Unrelated entry is untouched
    is($config->{config}{model_configs}{'minimax/MiniMax-M3'}{show_thinking}, 1,
        'unrelated show_thinking entry preserved');
};

# ============================================================================
# 5. clear_model_scoped is a no-op for non-model-scoped keys
# ============================================================================

subtest 'clear_model_scoped ignores non-model-scoped keys' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    write_disk($tmpdir, {
        api_base => 'http://localhost:9090/v1/chat/completions',
        api_key  => '1234',
        model    => 'minimax/MiniMax-M3',
        provider => 'minimax',
        model_configs => {
            'minimax/MiniMax-M3' => {
                show_thinking => 1,
            },
        },
    });

    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    # serrate-key is NOT a model-scoped key. clear_model_scoped should
    # refuse to touch model_configs (no entries should change).
    my $cleared = $config->clear_model_scoped('serpapi_key');
    is($cleared, 0, 'non-model-scoped key: 0 cleared');

    is($config->{config}{model_configs}{'minimax/MiniMax-M3'}{show_thinking}, 1,
        'show_thinking entry still intact');
};

# ============================================================================
# 6. End-to-end: bug scenario, full reload cycle
# ============================================================================

subtest 'end-to-end: stale value cannot resurrect after reset through reload' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    write_disk($tmpdir, {
        api_base => 'http://localhost:9090/v1/chat/completions',
        api_key  => '1234',
        model    => 'llama.cpp/local_model',
        provider => 'llama.cpp',
        sampling_temperature => '1',
        sampling_top_p       => '0.95',
        sampling_top_k       => '40',
        model_configs => {
            'llama.cpp/local-model' => {
                sampling_temperature => '1',
                sampling_top_p       => '0.95',
                sampling_top_k       => '40',
            },
            'llama.cpp/local_model' => {
                sampling_temperature => '1',
                sampling_top_p       => '0.95',
                sampling_top_k       => '40',
            },
        },
    });

    # Session 1: user resets everything via the API handlers
    {
        my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
        for my $key (qw(sampling_temperature sampling_top_p sampling_top_k)) {
            $config->set($key, '', 1);
            $config->clear_model_scoped($key);
        }
        $config->save();
    }

    # Session 2: fresh restart. Old buggy code would resurrect the values
    # from the hyphen entry. With the fix, the stale entries are gone.
    my $config2 = CLIO::Core::Config->new(config_dir => $tmpdir);
    is($config2->{config}{sampling_temperature}, '',
        'session 2: sampling_temperature not resurrected');
    is($config2->{config}{sampling_top_p},       '',
        'session 2: sampling_top_p not resurrected');
    is($config2->{config}{sampling_top_k},       '',
        'session 2: sampling_top_k not resurrected');
};

# ============================================================================
# 7. Thinking handlers (show_thinking, thinking_effort, thinking_mode) call
#    set() then clear_model_scoped($key, $current_model) then re-pin the
#    current model's entry. This clears stale entries from OTHER models
#    while preserving the current model's explicit override.
#
#    Previously, thinking_effort and thinking_mode called clear_model_scoped()
#    WITHOUT $skip_model, wiping the current model's entry that set() had
#    just written. Combined with a second bug in _restore_model_config (which
#    treated initial load as a cross-provider switch), this caused the values
#    to silently revert to defaults on every restart.
# ============================================================================

for my $key (qw(show_thinking thinking_effort thinking_mode)) {
    subtest "thinking handler clear: $key stale entry cleared across models" => sub {
        my $tmpdir = tempdir(CLEANUP => 1);

        my $value_for_key = {
            show_thinking   => 1,
            thinking_effort => 'high',
            thinking_mode   => 'enabled',
        };
        my $global_value = $value_for_key->{$key};

        # Seed: two models, both have the key set.
        write_disk($tmpdir, {
            api_base => 'http://localhost:9090/v1/chat/completions',
            api_key  => '1234',
            model    => 'minimax/MiniMax-M3',
            provider => 'minimax',
            model_configs => {
                'minimax/MiniMax-M3' => { $key => $global_value },
                'anthropic/claude-4-sonnet' => { $key => $global_value },
            },
        });

        # Simulate the API handler: user on minimax toggles thinking OFF.
        # The handler calls set() then clear_model_scoped(current_model)
        # then re-pins the current model's entry with the explicit flag.
        my $reset_value = {
            show_thinking   => 0,
            thinking_effort => 'medium',
            thinking_mode   => 'auto',
        };

        my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
        my $current_model = $config->get('model') || '';
        $config->set($key, $reset_value->{$key}, 1);
        $config->clear_model_scoped($key, $current_model);
        # Re-pin current model's entry (mirrors the fixed handler)
        if ($current_model && $current_model =~ m{/}) {
            $config->{config}->{model_configs}{$current_model}{$key} = $reset_value->{$key};
            $config->{config}->{model_configs_explicit}{$current_model}{$key} = 1;
        }
        $config->save();

        # Current model's entry should be PRESERVED (with the new value).
        is($config->{config}{model_configs}{'minimax/MiniMax-M3'}{$key}, $reset_value->{$key},
            "$key: minimax entry preserved with reset value");
        # Other model's stale entry should be cleared.
        ok(!exists $config->{config}{model_configs}{'anthropic/claude-4-sonnet'}{$key},
            "$key: anthropic stale entry cleared");

        # Global value should be the new value.
        is($config->{config}{$key}, $reset_value->{$key},
            "$key: global value updated to reset value");

        # Restart and verify: global value persists, stale entry doesn't resurrect.
        my $config2 = CLIO::Core::Config->new(config_dir => $tmpdir);
        is($config2->{config}{$key}, $reset_value->{$key},
            "$key: global value persists across reload");
    };
}

# ============================================================================
# 8. Regression: thinking_effort / thinking_mode survive a full save/restart
#    cycle. This reproduces the exact bug reported by the user:
#      /api set thinking_effort high  ->  saved, but reverted to 'medium' on restart
#      /api set thinking_mode enabled ->  saved, but reverted to 'auto'   on restart
#    Root cause was two bugs:
#      (a) handle_set called clear_model_scoped without $skip_model,
#          wiping the current model's model_configs entry before save.
#      (b) _restore_model_config set $cross_provider=1 on initial load
#          (no $old_model), causing missing thinking keys to be reset
#          to DEFAULT_CONFIG instead of keeping user-set globals.
# ============================================================================

subtest 'thinking_effort and thinking_mode survive save/restart cycle' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    # Seed a config with a provider and model already configured.
    write_disk($tmpdir, {
        api_base => 'https://integrate.api.nvidia.com/v1',
        api_key  => 'nvapi-test',
        model    => 'nvidia/nemotron-3-ultra-550b-a55b',
        provider => 'nvidia',
        show_thinking => 1,
    });

    # Session 1: simulate the full handler flow for /api set thinking_effort high
    # and /api set thinking_mode enabled.
    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
    my $current_model = $config->get('model') || '';
    ok($current_model eq 'nvidia/nemotron-3-ultra-550b-a55b',
        'precondition: model is set');

    # /api set thinking_effort high
    $config->set('thinking_effort', 'high', 1);
    $config->clear_model_scoped('thinking_effort', $current_model);
    if ($current_model && $current_model =~ m{/}) {
        $config->{config}->{model_configs}{$current_model}{'thinking_effort'} = 'high';
        $config->{config}->{model_configs_explicit}{$current_model}{'thinking_effort'} = 1;
    }
    $config->save();

    # /api set thinking_mode enabled
    $config->set('thinking_mode', 'enabled', 1);
    $config->clear_model_scoped('thinking_mode', $current_model);
    if ($current_model && $current_model =~ m{/}) {
        $config->{config}->{model_configs}{$current_model}{'thinking_mode'} = 'enabled';
        $config->{config}->{model_configs_explicit}{$current_model}{'thinking_mode'} = 1;
    }
    $config->save();

    # Verify in-memory state
    is($config->{config}{thinking_effort}, 'high',
        'in-memory: thinking_effort is high');
    is($config->{config}{thinking_mode}, 'enabled',
        'in-memory: thinking_mode is enabled');

    # Session 2: fresh restart - the exact bug scenario
    my $config2 = CLIO::Core::Config->new(config_dir => $tmpdir);

    is($config2->{config}{thinking_effort}, 'high',
        'restart: thinking_effort preserved as high (was reverting to medium)');
    is($config2->{config}{thinking_mode}, 'enabled',
        'restart: thinking_mode preserved as enabled (was reverting to auto)');
    is($config2->{config}{show_thinking}, 1,
        'restart: show_thinking still preserved');
};

# ============================================================================
# 9. Regression: thinking values set WITHOUT model_configs entry (e.g. the
#    value was set before model_configs existed) still survive on initial
#    load. This tests the _restore_model_config $cross_provider=0 fix directly:
#    when $old_model is undef (initial load), missing thinking keys must KEEP
#    the user-set global value, not reset to DEFAULT_CONFIG.
# ============================================================================

subtest 'thinking values persist on load when missing from model_configs' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    # Disk has thinking_effort='high' and thinking_mode='enabled' as
    # top-level user_set values, but the model_configs entry does NOT
    # contain those keys (simulating the state after the old clear_model_scoped
    # bug wiped them, or a partially-migrated config from an older version).
    write_disk($tmpdir, {
        api_base => 'https://integrate.api.nvidia.com/v1',
        api_key  => 'nvapi-test',
        model    => 'nvidia/nemotron-3-ultra-550b-a55b',
        provider => 'nvidia',
        show_thinking => 1,
        thinking_effort => 'high',
        thinking_mode   => 'enabled',
        model_configs => {
            'nvidia/nemotron-3-ultra-550b-a55b' => {
                show_thinking => 1,
                # NOTE: thinking_effort and thinking_mode are MISSING
                # from this entry - exactly the state that triggered
                # Bug 2 (reset to default on initial load).
            },
        },
    });

    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    is($config->{config}{thinking_effort}, 'high',
        'load: thinking_effort keeps user-set global (not reset to medium)');
    is($config->{config}{thinking_mode}, 'enabled',
        'load: thinking_mode keeps user-set global (not reset to auto)');
    is($config->{config}{show_thinking}, 1,
        'load: show_thinking still correct');
};

done_testing();
