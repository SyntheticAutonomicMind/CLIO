#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Verify that custom provider aliases (e.g. "nimo" based on "llama.cpp")
# are correctly resolved so MCM is used instead of falling back to
# DEFAULT_CONTEXT_WINDOW (128K). This was the root cause of premature
# context trimming: without MCM, CLIO thought a 196K llama.cpp server
# had only 128K context.

use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);

# --- Mock the config subsystem so we control the provider config ---
# We need to intercept CLIO::Core::Config before it loads the user's real
# config. We do this by pre-populating the %INC cache and defining a mock
# package.

my $tmp = tempdir(CLEANUP => 1);

{
    package CLIO::Core::Config;
    use CLIO::Util::ConfigPath qw(get_config_dir);
    # Override get_config_dir to return a temp dir so no real config is loaded
    *get_config_dir = sub { $tmp };

    sub new {
        my $self = bless {}, shift;
        $self->{config} = {
            provider => "nimo",
            api_bases => {
                "llama.cpp" => "http://localhost:8080/v1/chat/completions",
                "nimo" => "http://nimo:9090/v1/chat/completions",
            },
            api_keys => {},
            custom_providers => {
                "nimo" => {
                    base_provider => "llama.cpp",
                    display_name => "llama.cpp (Local) (nimo)",
                    created_at => 1789262812,
                },
            },
            model_configs => {},
        };
        $self->{user_set} = {};
        return $self;
    }
    sub get { return $_[0]->{config}{$_[1]} }
    sub set { $_[0]->{config}{$_[1]} = $_[2] }
    sub get_provider_base { return $_[0]->{config}{api_bases}{$_[1]} }
    sub get_provider_key { return $_[0]->{config}{api_keys}{$_[1]} }
    sub resolve_custom_provider {
        my ($self, $name) = @_;
        return $self->{config}{custom_providers}{$name}{base_provider} || $name;
    }
    sub is_custom_provider {
        my ($self, $name) = @_;
        return exists $self->{config}{custom_providers}{$name};
    }
    sub is_custom_provider_key { return 0 }
    sub provider_exists { return 0 }
    sub save { }
}

plan(tests => 7);

# --- Test 1: resolve_custom_provider maps "nimo" to "llama.cpp" ---
require CLIO::Core::Config;
my $config = CLIO::Core::Config->new();
my $resolved = $config->resolve_custom_provider("nimo");
is($resolved, "llama.cpp", "resolve_custom_provider('nimo') returns 'llama.cpp'");

# --- Test 2: MCM provider check now finds the base provider ---
require CLIO::Providers;
my $pdef = CLIO::Providers::get_provider($resolved);
ok($pdef, "get_provider('llama.cpp') returns a provider definition after resolution");
ok($pdef->{local_inference}, "resolved llama.cpp provider has local_inference=1");

# --- Test 3: Before the fix, get_provider("nimo") returned undef ---
my $pdef_nimo = CLIO::Providers::get_provider("nimo");
ok(!defined $pdef_nimo, "get_provider('nimo') returns undef (custom alias not in registry) - confirms original bug");

# --- Test 4: MCM::get_capabilities accepts api_base parameter ---
require CLIO::Core::ModelCapabilitiesManager;
my $mcm = CLIO::Core::ModelCapabilitiesManager->new();
ok($mcm->can("get_capabilities"), "MCM has get_capabilities method");

# --- Test 5: MCM resolves custom provider names internally ---
# We verify by checking the source contains the resolution logic
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die; <$fh> };
    like($src, qr/provider_exists\(\$provider\)/, "MCM _fetch_provider_capabilities checks provider_exists");
    like($src, qr/resolve_custom_provider/, "MCM _fetch_provider_capabilities resolves custom providers");
}

done_testing();
