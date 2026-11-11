#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Sanitizer regression test.
#
# This file previously printed "ERROR" or "SUCCESS" and always exited 0, so a
# regression in sanitize_text produced a green suite. It also used `use lib
# 'lib'`, which only resolves when the test is run from the repository root.
#
# The properties under test matter beyond cosmetics: sanitize_text is a
# security boundary (it strips invisible-character injection) and the JSON
# payload it feeds must never carry literal escape sequences to the provider.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use JSON::PP qw(encode_json);
use CLIO::Util::TextSanitizer qw(sanitize_text);
use CLIO::Security::InvisibleCharFilter qw(filter_invisible_chars has_invisible_chars);

# ── JSON payloads do not carry Perl escape sequences ────────────────────────
{
    my $text = "wrong: test right: test arrow";
    my $sanitized = sanitize_text($text);
    my $json = encode_json({ content => $sanitized });

    unlike($json, qr/\\x\{/,
        'the encoded payload contains no \x{...} escape sequences');
    like($json, qr/"content":/, 'the payload still carries the content field');
}

# ── Invisible-character injection is removed ────────────────────────────────
{
    # Bidi override, zero-width space, and a tag character: all ways to hide
    # text from a human reader while the model still sees it.
    my $hostile = "safe" . "\x{202E}" . "hidden" . "\x{200B}" . "\x{E0041}";
    ok(has_invisible_chars($hostile), 'the fixture contains invisible characters');

    my $cleaned = filter_invisible_chars($hostile);
    ok(!has_invisible_chars($cleaned),
        'filter_invisible_chars removes every invisible character');
    like($cleaned, qr/safe/, 'visible content survives filtering');

    my $via_sanitize = sanitize_text($hostile);
    ok(!has_invisible_chars($via_sanitize),
        'sanitize_text also strips invisible characters');
}

# ── Ordinary text is not damaged ────────────────────────────────────────────
{
    my $plain = 'A normal line with punctuation, paths (/tmp/x), and digits 123.';
    is(sanitize_text($plain), $plain, 'ordinary text passes through unchanged');
}

# ── Numbers keep their type so JSON encodes them as numbers ─────────────────
{
    my $json = encode_json({ max_tokens => sanitize_text(32768) });
    like($json, qr/"max_tokens":32768/, 'a numeric value is not stringified');
}

# ── Undefined input does not become an error ────────────────────────────────
{
    my $result = eval { sanitize_text(undef) };
    is($@, '', 'sanitize_text(undef) does not die');
    ok(!defined $result, 'sanitize_text(undef) returns undef');
}

done_testing();
