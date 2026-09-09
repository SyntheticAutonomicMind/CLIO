#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: repair_malformed_json idempotency — running repair on already-valid
# JSON must not corrupt string values. The decimal-fix regex
# s/:(\s*)\.(\d)/:${1}0.$2/g matches ANY colon-dot-digit sequence,
# including inside string values like "error: .500 status".
#
# Before the Phase 3 fix, aliased tool calls had their JSON repaired twice:
# once in Phase 1 (repair_tool_call_json) and again in Phase 3 (repair_malformed_json).
# The second pass corrupted valid string values. This test verifies that
# repair_malformed_json leaves valid JSON untouched.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Util::JSONRepair qw(repair_malformed_json);

# Valid JSON with colon-dot-digit patterns inside string values
my @valid_cases = (
    # String values with "x: .5y" pattern
    '{"operation":"grep_search","query":"error: .500 status"}',
    # String values with "x:.5y" (no space)
    '{"operation":"read_file","path":"/project/config/.config"}' => 0,
    # String values with "x: .05y"
    '{"operation":"write_file","content":"progress: .75 done"}',
    # Empty string
    '{}',
    # No dangerous patterns
    '{"operation":"list_dir","path":"/tmp"}',
);

for my $case (@valid_cases) {
    my $json = ref($case) ? $case : $case;
    my $repaired = repair_malformed_json($json, 0);

    # The repaired JSON must be identical to the input (no corruption)
    is($repaired, $json, "Valid JSON unchanged: " . substr($json, 0, 50));

    # The repaired JSON must still parse as valid JSON
    eval {
        require JSON::PP;
        JSON::PP::decode_json($repaired);
    };
    ok(!$@, "Repaired JSON is still valid: " . substr($json, 0, 50));
}

# Test the corruption case: a : .5 regex pattern must survive repair.
{
    my $valid_json = '{"operation":"grep_search","query":"error: .500 status"}';
    my $repaired_once = repair_malformed_json($valid_json, 0);
    my $repaired_twice = repair_malformed_json($repaired_once, 0);

    is($repaired_once, $valid_json, "Single repair does not corrupt : .5 pattern");
    is($repaired_twice, $valid_json, "Double repair does not corrupt : .5 pattern");
}

# Also verify that genuinely malformed JSON IS still repaired correctly
{
    my $broken = '{"operation":"read", "path":"/tmp",}';
    my $repaired = repair_malformed_json($broken, 0);
    eval { require JSON::PP; JSON::PP::decode_json($repaired); };
    ok(!$@, "Trailing comma still repaired");
}

{
    my $broken = '{"operation":"read","path":,"length":8192}';
    my $repaired = repair_malformed_json($broken, 0);
    eval { require JSON::PP; JSON::PP::decode_json($repaired); };
    ok(!$@, "Missing value still repaired");
}

done_testing();
