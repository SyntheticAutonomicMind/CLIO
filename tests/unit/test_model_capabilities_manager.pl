#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_model_capabilities_manager.pl - Unit test for ModelCapabilitiesManager

=head1 SYNOPSIS

    perl -I./lib tests/unit/test_model_capabilities_manager.pl

=cut

use strict;
use warnings;
use utf8;
use Test::More;
use CLIO::Core::ModelCapabilitiesManager;

my $mcm = CLIO::Core::ModelCapabilitiesManager->new(debug => 1);

# Test constructor
ok($mcm, 'Constructor returned object');
isa_ok($mcm, 'CLIO::Core::ModelCapabilitiesManager');

# Test get_capabilities returns hashref for github_copilot (may be undef if no auth)
# We test the infrastructure, not the specific provider API
ok($mcm->can('get_capabilities'), 'Method get_capabilities exists');
ok($mcm->can('supports_feature'), 'Method supports_feature exists');
ok($mcm->can('get_model_info'), 'Method get_model_info exists');
ok($mcm->can('refresh_capabilities'), 'Method refresh_capabilities exists');
ok($mcm->can('clear_cache'), 'Method clear_cache exists');

# Test _format_tokens
my $formatted = $mcm->_format_tokens(204800);
is($formatted, '205k', '_format_tokens formats 204800 as 205k (204.8 rounded)');

$formatted = $mcm->_format_tokens(1000000);
is($formatted, '1.0M', '_format_tokens formats 1000000 as 1.0M');

$formatted = $mcm->_format_tokens(128000);
is($formatted, '128k', '_format_tokens formats 128000 as 128k');

$formatted = $mcm->_format_tokens(500);
is($formatted, '500', '_format_tokens formats 500 as 500');

done_testing();
