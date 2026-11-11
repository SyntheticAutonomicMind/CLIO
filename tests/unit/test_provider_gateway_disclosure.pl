#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
#
# Test: every provider is explicitly classified as a third-party gateway or
# not, and the disclosure fires only for gateways.
#
# CLIO is a coding agent: whatever provider a user selects receives their
# prompts and their source code. A gateway forwards that to models authored
# by other labs, so the gateway operator's retention policy applies
# alongside the upstream's. The registry used to carry no notion of this,
# which meant a new provider entry could be added without anyone deciding
# whether users should be told where their data goes.
#
# Every registry entry now declares third_party_gateway as  or 1. This test
# requires the key to be present rather than defaulting it, so an
# unclassified provider fails the suite instead of silently inheriting the
# non-gateway presentation.

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;

use CLIO::Providers qw(get_provider list_providers is_third_party_gateway);

# Providers that route to models authored by other labs. Add to this list
# when a gateway is added, and to neither list for a first-party provider -
# the completeness test below catches a provider missing from all three.
my @GATEWAYS = qw(
    openrouter orca kilo hyper opper vercel
    cheaperinference cheapaimodel standardcompute uberllm synap
);

# Providers that serve models of their own, or run locally on the user's
# machine. github_copilot is excluded from the gateway set deliberately:
# GitHub is the account holder's counterparty under GitHub's own terms,
# not an intermediary the user has separately agreed to.
my @FIRST_PARTY = qw(
    anthropic openai google deepseek nvidia ollama_cloud
    minimax minimax_token zai zai_coding github_copilot
    llama.cpp lmstudio
);

my %gateway_of = map { $_ => 1 } @GATEWAYS;
my %first_of   = map { $_ => 1 } @FIRST_PARTY;

# ============================================================================
# Registry classification
# ============================================================================
my @providers = list_providers();
ok(@providers, 'registry returns providers');

for my $name (@providers) {
    my $def = get_provider($name);
    ok($def, "$name has a registry entry");

    # The key must be declared explicitly, not inferred from absence.
    ok(exists $def->{third_party_gateway},
       "$name declares third_party_gateway explicitly");

    my $flag = is_third_party_gateway($name);
    if ($gateway_of{$name}) {
        is($flag, 1, "$name is classified as a gateway");
    }
    elsif ($first_of{$name}) {
        is($flag, 0, "$name is not classified as a gateway");
    }
    else {
        fail("$name is in neither the gateway nor the first-party list - "
           . "add it to the correct one");
    }
}

# The expectation lists must not drift away from the registry.
for my $name (@GATEWAYS) {
    ok((grep { $_ eq $name } @providers),
       "gateway expectation $name still exists in the registry");
}
for my $name (@FIRST_PARTY) {
    ok((grep { $_ eq $name } @providers),
       "first-party expectation $name still exists in the registry");
}

is(scalar(@GATEWAYS) + scalar(@FIRST_PARTY), scalar(@providers),
   'expectation lists cover the registry exactly');

# ============================================================================
# Unknown and custom providers
# ============================================================================
is(is_third_party_gateway(undef), 0, 'undef provider is not a gateway');
is(is_third_party_gateway('definitely-not-a-provider'), 0,
   'unknown provider is not a gateway');

# An alias wrapping a gateway inherits its classification: the data path is
# the same regardless of what the user called it.
SKIP: {
    my $resolved = eval {
        require CLIO::Core::Config;
        my $cfg = eval { CLIO::Core::Config->new() };
        skip 'Config unavailable', 1 unless $cfg;
        my @custom = $cfg->list_custom_providers();
        skip 'no custom providers configured', 1 unless @custom;
        my ($alias) = grep {
            ($cfg->resolve_custom_provider($_) // '') eq 'openrouter'
        } @custom;
        skip 'no openrouter alias configured', 1 unless $alias;
        $alias;
    };
    skip 'Config unavailable', 1 if $@ || !$resolved;
    is(is_third_party_gateway($resolved), 1,
       "custom alias $resolved inherits the openrouter gateway classification");
}

# ============================================================================
# Disclosure rendering
# ============================================================================
require CLIO::UI::Commands::API::Config;

my @lines;
{
    no warnings 'redefine';
    no warnings 'once';
    *CLIO::UI::Commands::API::Config::writeline = sub {
        my ($self, $line, %opts) = @_;
        push @lines, ($line // '');
        return 1;
    };
    # Strip color so the assertions read against plain text.
    *CLIO::UI::Commands::API::Config::colorize = sub {
        my ($self, $text, $style) = @_;
        return defined $text ? $text : '';
    };
}

my $cmd = bless {}, 'CLIO::UI::Commands::API::Config';

for my $name (@GATEWAYS) {
    @lines = ();
    my $display = (get_provider($name) || {})->{name} || $name;
    $cmd->_gateway_disclosure($name, $display);

    ok(@lines > 0, "$name emits a disclosure");
    my $text = join(' ', @lines);
    like($text, qr/gateway/i,          "$name disclosure names it a gateway");
    like($text, qr/other labs/i,       "$name disclosure says models come from other labs");
    like($text, qr/prompts and any code/i,
         "$name disclosure names the data at risk");
    like($text, qr/retention/i,        "$name disclosure mentions retention policy");
    like($text, qr/\Q$display\E/,      "$name disclosure names the operator");

    # Neutral wording: inform, do not editorialise or imply a verdict.
    unlike($text, qr/scam|unsafe|avoid|shady|untrustworthy/i,
           "$name disclosure stays neutral");
}

for my $name (@FIRST_PARTY) {
    @lines = ();
    $cmd->_gateway_disclosure($name, (get_provider($name) || {})->{name});
    is(scalar(@lines), 0, "$name emits no disclosure");
}

# The inline list tag agrees with the full disclosure.
for my $name (@GATEWAYS) {
    like($cmd->_gateway_tag($name), qr/gateway/, "$name list row carries the tag");
}
for my $name (@FIRST_PARTY) {
    is($cmd->_gateway_tag($name), '', "$name list row carries no tag");
}

done_testing();
