#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use File::Temp qw(tempdir);
use File::Spec;
use Test::More tests => 13;

# Test model aliases in Config

use_ok('CLIO::Core::Config');

# Create a temp config dir
my $tmpdir = tempdir(CLEANUP => 1);

# Create a config instance with temp dir
my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
ok($config, 'Config created with temp dir');

# Test: no aliases initially
my %aliases = $config->list_model_aliases();
is(scalar keys %aliases, 0, 'No aliases initially');

# Test: get non-existent alias
is($config->get_model_alias('fast'), undef, 'Non-existent alias returns undef');

# Test: set alias
ok($config->set_model_alias('fast', 'gpt-5-mini'), 'set_model_alias returns true');

# Test: get alias
is($config->get_model_alias('fast'), 'gpt-5-mini', 'get_model_alias returns correct value');

# Test: case insensitive
is($config->get_model_alias('FAST'), 'gpt-5-mini', 'Alias lookup is case-insensitive');

# Test: set multiple
$config->set_model_alias('thinking', 'openrouter/deepseek/deepseek-r1');
$config->set_model_alias('sonnet', 'github_copilot/claude-sonnet-4');

%aliases = $config->list_model_aliases();
is(scalar keys %aliases, 3, 'Three aliases exist');

# Test: save and reload
ok($config->save(), 'Config saves');

my $config2 = CLIO::Core::Config->new(config_dir => $tmpdir);
is($config2->get_model_alias('fast'), 'gpt-5-mini', 'Alias persists after reload');
is($config2->get_model_alias('thinking'), 'openrouter/deepseek/deepseek-r1', 'Multi-segment alias persists');

# Test: delete alias
ok($config->delete_model_alias('fast'), 'delete_model_alias returns true');
is($config->get_model_alias('fast'), undef, 'Deleted alias returns undef');

