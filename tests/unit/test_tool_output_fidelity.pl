#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tool output must reach the model byte-identical to what the tool returned.
#
# The display sanitizer maps emoji to ASCII tags and deletes whole Unicode
# ranges. Applied to tool output, that makes the model quote text that does
# not exist on disk: an apply_patch built from a read_file result cannot
# match, fails with "cannot find match position", and the retry sends the
# same altered text again.
#
# Covered here:
#   1. sanitize_tool_output leaves printable content untouched
#   2. sanitize_tool_output still filters invisible characters (security)
#   3. PayloadSanitizer preserves role=tool messages
#   4. PayloadSanitizer preserves Responses API function_call_output items
#   5. PayloadSanitizer still sanitizes user and assistant text
#   6. Round trip: read_file -> apply_patch on a file with non-ASCII content
#
# Run: perl -I./lib tests/unit/test_tool_output_fidelity.pl

use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use File::Temp qw(tempdir);

use CLIO::Util::TextSanitizer qw(sanitize_text);
use CLIO::Core::API::PayloadSanitizer qw(sanitize_payload);
use CLIO::Tools::FileOperations;
use CLIO::Tools::ApplyPatch;

# Resolve sanitize_tool_output at runtime. Without it, fall back to the
# display sanitizer so the behavioural assertions report the regression
# instead of aborting this file at compile time.
my $sanitize_tool_output = CLIO::Util::TextSanitizer->can('sanitize_tool_output')
    || \&CLIO::Util::TextSanitizer::sanitize_text;

my $dir = tempdir(CLEANUP => 1);

# Content with characters the display sanitizer rewrites or deletes:
#   U+2699 -> "[CONFIG]"     (emoji map)
#   U+23F8 -> deleted        (Miscellaneous Technical range)
#   U+00B7 -> untouched      (below U+2300)
my $source = "const a = 1;\n"
    . "const btn = { text: \"\x{2699}\", pause: \"\x{23F8}\", dot: \"\x{00B7}\" };\n"
    . "const b = 2;\n";

my $path = "$dir/fixture.js";
{
    open my $fh, '>:encoding(UTF-8)', $path or die "write fixture: $!";
    print $fh $source;
    close $fh;
}

# --- 1. Tool output is not rewritten ---
is($sanitize_tool_output->($source), $source,
    'sanitize_tool_output leaves printable content byte-identical');

is($sanitize_tool_output->("plain ascii\n"), "plain ascii\n",
    'sanitize_tool_output passes ascii through unchanged');

is($sanitize_tool_output->(undef), undef,
    'sanitize_tool_output(undef) returns undef');

# Confirm the display sanitizer still does rewrite, so the distinction is real
isnt(sanitize_text($source), $source,
    'sanitize_text still rewrites the same content (display path unchanged)');
like(sanitize_text($source), qr/\[CONFIG\]/,
    'display sanitizer maps U+2699 to its ASCII tag');
unlike(sanitize_text($source), qr/\x{23F8}/,
    'display sanitizer deletes U+23F8');

# --- 2. Invisible-character filtering still applies to tool output ---
my $hostile = "safe\x{202E}text\x{200B}here";
my $filtered = $sanitize_tool_output->($hostile);
unlike($filtered, qr/\x{202E}/, 'bidi override stripped from tool output');
unlike($filtered, qr/\x{200B}/, 'zero-width space stripped from tool output');
like($filtered, qr/safe/, 'visible content survives invisible-char filtering');
like($filtered, qr/here/, 'trailing visible content survives');

# --- 3. Payload sanitizer preserves tool messages ---
my $tool_body = $sanitize_tool_output->($source);
is($tool_body, $source, 'tool body delivered to the payload equals the file on disk');
my $payload = {
    model    => 'test-model',
    max_tokens => 1024,
    messages => [
        { role => 'user',      content => "check \x{2699} please" },
        { role => 'tool',      tool_call_id => 'call_1', name => 'read_file',
          content => $tool_body },
        { role => 'assistant', content => "done \x{2699}" },
    ],
};
my $clean = sanitize_payload($payload);

is($clean->{messages}[1]{content}, $source,
    'payload sanitizer preserves role=tool content byte-for-byte');
is($clean->{messages}[1]{role}, 'tool',
    'tool message role unchanged');
is($clean->{messages}[0]{content}, 'check [CONFIG] please',
    'user message still sanitized');
is($clean->{messages}[2]{content}, 'done [CONFIG]',
    'assistant message still sanitized');
is($clean->{max_tokens}, 1024,
    'numeric field survives as a number');

# --- 4. Responses API function_call_output items ---
my $responses = {
    model => 'test-model',
    input => [
        { type => 'function_call_output', call_id => 'call_1', output => $tool_body },
    ],
};
my $rclean = sanitize_payload($responses);
is($rclean->{input}[0]{output}, $source,
    'payload sanitizer preserves function_call_output output (Responses API)');

# --- 5. Round trip through the real tools ---
my $fo = CLIO::Tools::FileOperations->new;
my $read = $fo->read_file({ path => $path }, {});
ok($read->{success}, 'read_file succeeded');
is($read->{output}, $source,
    'read_file reports the file exactly as stored on disk');

# The model builds its patch from what the pipeline delivered to it, not
# from the bytes on disk. That distinction is the whole point of this test:
# if the pipeline rewrote the content, the patch cannot match.
my $model_sees = $clean->{messages}[1]{content};
my ($btn_line) = ($model_sees =~ /^(const btn = .*)$/m);
ok(defined $btn_line, 'tool message contains the btn line the model will quote');

my $patch = join("\n",
    "*** Begin Patch",
    "*** Update File: $path",
    "@@ const btn",
    " $btn_line",
    "-const b = 2;",
    "+const b = 3;",
    "*** End Patch");

my $ap = CLIO::Tools::ApplyPatch->new;
my $applied = $ap->_do_apply({ patch => $patch }, {});
ok($applied->{success},
    'apply_patch built from read_file output matches the file')
    or diag("apply_patch error: " . ($applied->{error} // '(none)'));

my $after = do { local $/; open my $fh, '<:encoding(UTF-8)', $path or die; <$fh> };
like($after, qr/const b = 3;/, 'edit landed');
like($after, qr/\x{2699}/, 'U+2699 preserved on disk after the patch');
like($after, qr/\x{23F8}/, 'U+23F8 preserved on disk after the patch');

done_testing();
