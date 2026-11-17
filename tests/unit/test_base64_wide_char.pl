#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# MIME::Base64 is byte-oriented XS and mishandles UTF-8-flagged strings.
#
# Given a flagged string it either encodes the codepoint's low byte
# (silent corruption below U+0100) or dies with "Wide character in
# subroutine entry". Both shipped text call sites encoded model- or
# user-supplied text without encoding it to bytes first:
#
#   RemoteExecution: commands piped to the remote `base64 -d`
#   ImageDisplay:    the iTerm inline-image filename
#
# Raw image byte paths are deliberately NOT encoded - they are already
# bytes, and encoding them would corrupt the payload.
#
# Run: perl -I./lib tests/unit/test_base64_wide_char.pl

use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(decode encode_utf8);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use MIME::Base64 qw(decode_base64);

use CLIO::Tools::RemoteExecution;
use CLIO::Util::ImageDisplay;

# Genuinely decoded strings. A "\x{e9}" literal is stored without the UTF-8
# flag and does not reproduce the bug, so build these from UTF-8 bytes.
my $e_acute  = decode('UTF-8', "echo \"caf\xC3\xA9\"");          # U+00E9
my $gear     = decode('UTF-8', "echo \"\xE2\x9A\x99\"");          # U+2699
my $emoji    = decode('UTF-8', "echo \"\xF0\x9F\x98\x80\"");      # U+1F600
my $multiline = "echo one\necho two";

# --- RemoteExecution: command -> base64 -> base64 -d -> original bytes ---
my $re = CLIO::Tools::RemoteExecution->new;

# Resolve the helper at runtime. Without it, fall back to the ungarded encode
# so the round-trip assertions report the regression instead of aborting
# this file at compile time.
my $encode_command = CLIO::Tools::RemoteExecution->can('_base64_command_payload')
    || sub {
        my ($self, $command) = @_;
        require MIME::Base64;
        return MIME::Base64::encode_base64($command, '');
    };

for my $case (
    [ 'ascii',            'echo hi',  0 ],
    [ 'U+00E9',           $e_acute,   1 ],
    [ 'U+2699',           $gear,      1 ],
    [ 'U+1F600 emoji',    $emoji,     1 ],
    [ 'multiline ascii',  $multiline, 0 ],
) {
    my ($label, $command, $flagged) = @$case;

    is(utf8::is_utf8($command) ? 1 : 0, $flagged,
        "$label: input string has the expected UTF-8 flag state");

    my $encoded = eval { $encode_command->($re, $command) };
    if (my $err = $@) {
        fail("$label: encoding died - $err");
        next;
    }
    ok(defined $encoded && length($encoded), "$label: encoded to base64");
    unlike($encoded, qr/\n/, "$label: no line breaks in payload");

    # This is what the remote `base64 -d | bash` pipe yields.
    my $decoded = decode_base64($encoded);
    is($decoded, encode_utf8($command),
        "$label: base64 -d reproduces the command's UTF-8 bytes");
}

# ASCII must stay byte-identical to the previous behavior, so command
# payloads on existing remote installs do not change.
is($encode_command->($re, $multiline),
   MIME::Base64::encode_base64($multiline, ''),
   'ascii command payload is byte-identical to the ungarded encode');

# The pre-fix call is the regression: prove it actually misbehaved.
{
    my $prefix_died = !eval { MIME::Base64::encode_base64($gear, ''); 1 };
    ok($prefix_died, 'ungarded encode of U+2699 dies (bug still reproducible)');

    my $prefix_corrupt = eval { decode_base64(MIME::Base64::encode_base64($e_acute, '')) };
    isnt($prefix_corrupt, encode_utf8($e_acute),
        'ungarded encode of U+00E9 produces corrupted bytes');
}

# --- ImageDisplay: iTerm filename is text, image data is not ---
sub _capture_stdout {
    my ($cb) = @_;
    my $captured = '';
    open my $fh, '>:encoding(UTF-8)', \$captured or die "open in-memory fh: $!";
    my $old = select $fh;
    local $| = 1;
    $cb->();
    select $old;
    close $fh;
    return $captured;
}

my $id = CLIO::Util::ImageDisplay->new;
my $png = "\x89PNG\r\n\x1a\n" . ('raw-image-bytes' x 4);

for my $case (
    [ 'ascii filename',   'image.png',                                      0 ],
    [ 'U+00E9 filename',  decode('UTF-8', "caf\xC3\xA9.png"),               1 ],
    [ 'U+2699 filename',  $gear . '.png',                                   1 ],
    [ 'U+1F600 filename', $emoji . '.png',                                  1 ],
) {
    my ($label, $filename, $flagged) = @$case;
    next unless utf8::is_utf8($filename) == ($flagged ? 1 : 0);

    my $out = eval {
        _capture_stdout(sub {
            $id->_display_iterm($png, 'image/png', filename => $filename);
        });
    };
    if (my $err = $@) {
        fail("$label: display died - $err");
        next;
    }

    my ($name_b64) = ($out =~ /name=([^;]+);/);
    ok(defined $name_b64, "$label: name field emitted");
    my $decoded_name = decode_base64($name_b64);
    is($decoded_name, encode_utf8($filename),
        "$label: iTerm name field carries the filename's UTF-8 bytes");

    my ($data_b64) = ($out =~ /inline=1:([^\x07]+)\x07/s);
    ok(defined $data_b64, "$label: image payload emitted");
    is(decode_base64($data_b64), $png,
        "$label: image bytes passed through unmodified");
    is(length(decode_base64($data_b64)), length($png),
        "$label: image length unchanged");
}

done_testing();
