#!/usr/bin/env perl
# Test CLIO::Core::Config - --model override preserves configured provider
#
# Regression test for the bug where running `clio --model X/Y` (with a
# provider prefix different from the configured provider) overwrote the
# user's configured provider in config.json.
#
# Root cause: Config.pm set() called save() internally when the old model
# had a "/". save() iterates user_set and writes the CURRENT config hash
# values, which by then had the runtime override. The fix: set() should
# not auto-save when called with mark_user_set=0, because mark_user_set=0
# semantically means "don't persist".

use strict;
use warnings;
use lib './lib';
use Test::More;
use File::Temp qw(tempdir);

use CLIO::Core::Config;
use CLIO::Util::JSON qw(decode_json);

sub read_disk {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read $path: $!";
    my $raw = do { local $/; <$fh> };
    close $fh;
    return decode_json($raw);
}

# ==========================================================================
# Test 1: Different-provider --model preserves the user's config.json
# ==========================================================================

subtest 'different-provider --model: disk config unchanged' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    # User configures deepseek via /api set provider + model
    $config->set_provider('deepseek');
    $config->set('model', 'deepseek/deepseek-v4-pro', 1);
    $config->save();

    # Simulate startup prefix-add (in-memory only, mark=0):
    # already prefixed, no change here. Skip if already a / model.

    # Simulate `clio --model nvidia/some-model` code path. clio's --model
    # handler:
    #   1. Directly mutates config hash with the target provider's values
    #   2. Calls $config->set('model', "$provider/$model", 0)
    # With the fix, step 2's internal save() is skipped, so the disk state
    # stays as the user-configured values.
    require CLIO::Providers;
    my $pcfg = CLIO::Providers::get_provider('nvidia');
    $config->{config}->{provider} = 'nvidia';
    $config->{config}->{api_base} = $pcfg->{api_base};
    $config->set('model', 'nvidia/deepseek-ai/deepseek-v4-flash', 0);

    # In-memory state has the override (correct, for this session)
    is($config->{config}->{provider}, 'nvidia', 'in-memory provider is the override');
    is($config->{config}->{model},    'nvidia/deepseek-ai/deepseek-v4-flash',
        'in-memory model is the override');

    # Disk state preserves what the user actually configured
    my $saved = read_disk("$tmpdir/config.json");
    is($saved->{provider}, 'deepseek',
        'on-disk provider preserved (not leaked to nvidia)');
    is($saved->{model}, 'deepseek/deepseek-v4-pro',
        'on-disk model preserved (not leaked to override)');
};

# ==========================================================================
# Test 2: Same-provider --model preserves the user's model
# ==========================================================================

subtest 'same-provider --model: on-disk model unchanged' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    $config->set_provider('deepseek');
    $config->set('model', 'deepseek/deepseek-v4-pro', 1);
    $config->save();

    # Simulate `clio --model deepseek/different-model` - same provider
    $config->set('model', 'deepseek/different-model', 0);

    my $saved = read_disk("$tmpdir/config.json");

    is($saved->{provider}, 'deepseek', 'provider unchanged on disk');
    is($saved->{model}, 'deepseek/deepseek-v4-pro',
        'on-disk model preserved (not leaked to override)');
};

# ==========================================================================
# Test 3: /api set model still persists (mark_user_set=1 path)
# Confirms the fix doesn't regress the persistence semantics for /api calls.
# ==========================================================================

subtest 'mark_user_set=1 still triggers save()' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    $config->set_provider('deepseek');
    $config->set('model', 'deepseek/deepseek-v4-pro', 1);
    $config->save();

    # User changes model via /api - this MUST persist
    $config->set('model', 'deepseek/deepseek-v4-flash', 1);

    my $saved = read_disk("$tmpdir/config.json");

    is($saved->{model}, 'deepseek/deepseek-v4-flash',
        'mark_user_set=1 persists new model to disk');
    is($saved->{provider}, 'deepseek', 'provider preserved across mark=1 changes');
};

done_testing();
