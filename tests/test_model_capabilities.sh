#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Test script to verify ModelCapabilitiesManager integration
# Run this after implementing the feature to verify it works

echo "=== Testing ModelCapabilitiesManager ==="

cd "$(dirname "$0")/.."

echo "1. Checking module syntax..."
perl -I./lib -c lib/CLIO/Core/ModelCapabilitiesManager.pm
perl -I./lib -c lib/CLIO/UI/Commands/API/Models.pm

echo ""
echo "2. Running unit tests..."
perl -I./lib tests/unit/test_model_capabilities_manager.pl

echo ""
echo "3. Testing capability lookups..."
perl -I./lib -e '
use strict;
use warnings;
use CLIO::Core::ModelCapabilitiesManager;

my $mcm = CLIO::Core::ModelCapabilitiesManager->new(debug => 0);

# Test Z.AI capabilities
my $zai = $mcm->get_capabilities("zai", "glm-5.1");
print "Z.AI glm-5.1: " . ($zai ? "OK (ctx=$zai->{context_window})" : "FAIL") . "\n";

# Test MiniMax capabilities
my $mm = $mcm->get_capabilities("minimax", "MiniMax-M2.7");
print "MiniMax M2.7: " . ($mm ? "OK (ctx=$mm->{context_window})" : "FAIL") . "\n";

# Test feature detection
my $vision = $mcm->supports_feature("zai", "glm-5v-turbo", "vision");
print "glm-5v-turbo vision: " . ($vision ? "yes" : "no") . "\n";

print "\nAll checks complete.\n";
'

echo ""
echo "=== Test script complete ==="