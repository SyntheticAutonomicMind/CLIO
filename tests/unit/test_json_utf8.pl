#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More tests => 10;
use CLIO::Util::JSON qw(encode_json decode_json encode_json_pretty safe_decode_json);
use CLIO::Memory::LongTerm;

# Regression test for two related bugs:
# 1. "Wide character in goto" in JSON.pm's decode_json (caused by
#    `goto &$_decode` forwarding wide-char args on some Perl versions).
#    Fix: replaced with $_decode->(@_).
# 2. Double-encoding of UTF-8 characters in LongTerm.pm save/load
#    (and 8 other modules): save() used encoding => 'UTF-8' with
#    atomic_write but encode_json_pretty already produces UTF-8 bytes,
#    causing double-encoding. load() used <:encoding(UTF-8> which
#    decodes to Perl characters, then passed those to decode_json
#    which expects raw UTF-8 bytes. Fix: save without encoding layer,
#    load with <:raw>.

# --- Test 1: decode_json works with raw UTF-8 bytes (normal path) ---
my $data = { key => "café résumé naïve" };
my $json = encode_json($data);
my $decoded = eval { decode_json($json) };
ok($decoded && $decoded->{key} eq "café résumé naïve",
   "decode_json handles UTF-8 bytes correctly");

# --- Test 2: decode_json does NOT crash with wide-char string (goto fix) ---
my $wide = $json;
utf8::decode($wide);  # Set UTF-8 flag ON
# Before the fix, this crashed with "Wide character in goto" on macOS.
# After the fix, it should not crash with goto — it will error with
# "malformed UTF-8" from JSON::PP (expected: wide chars are not valid
# JSON bytes), but the key is that goto itself doesn't crash.
my $wide_result = eval { decode_json($wide) };
my $wide_error = $@;
# On Perl versions where goto &sub crashes with wide chars, the error
# message contains "Wide character in goto". After our fix, that
# specific error should NOT appear.
ok($wide_error !~ /Wide character in goto/,
   "decode_json does not produce 'Wide character in goto' error");

# --- Test 3: safe_decode_json returns undef on wide-char input (not crash) ---
my $safe_result = safe_decode_json($wide);
ok(!defined($safe_result),
   "safe_decode_json returns undef (not crash) for wide-char input");

# --- Test 4: LTM save/load round-trips wide characters ---
my $ltm = CLIO::Memory::LongTerm->new();
$ltm->add_discovery("Wide char round-trip: café — naïve", 1.0);
my $test_file = "/tmp/test_ltm_utf8_roundtrip.json";
$ltm->save($test_file);

# Verify no double-encoding in the file
open my $bfh, "<:raw", $test_file or die;
local $/; my $file_raw = <$bfh>; close $bfh;
ok($file_raw !~ /\xc3\x83/,
   "LTM file has no double-encoding markers (Ã)");
ok(utf8::decode($file_raw) && $file_raw =~ /café/,
   "LTM file decodes as valid UTF-8 and contains wide chars");

# Load it back
my $loaded = CLIO::Memory::LongTerm->load($test_file);
my $facts = $loaded->{patterns}{discoveries};
ok($facts && @$facts, "LTM loaded has discoveries");
ok($facts->[0]{fact} eq "Wide char round-trip: café — naïve",
   "LTM round-trip preserves wide characters exactly");

# --- Test 5: LongTemp save/load cycle with em-dash ---
my $ltm2 = CLIO::Memory::LongTerm->new();
$ltm2->add_discovery("Test with em-dash \x{2014} and accented chars ñ ü é", 0.8);
my $test_file2 = "/tmp/test_ltm_utf8_roundtrip2.json";
$ltm2->save($test_file2);
my $loaded2 = CLIO::Memory::LongTerm->load($test_file2);
my $fact2 = $loaded2->{patterns}{discoveries}[0]{fact};
is($fact2, "Test with em-dash \x{2014} and accented chars ñ ü é",
   "LTM round-trip with em-dash and multiple accents");

# --- Test 6: encode_json_pretty produces valid UTF-8 bytes ---
my $pretty = encode_json_pretty({ desc => "héllo wörld" });
my $pretty_copy = $pretty;
ok(utf8::decode($pretty_copy), "encode_json_pretty output is valid UTF-8");
ok($pretty_copy =~ /héllo wörld/, "encode_json_pretty preserves wide chars after decode");

