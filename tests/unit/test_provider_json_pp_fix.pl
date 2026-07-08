#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Regression: three provider modules had broken JSON::PP usage:
# - Anthropic.pm: 'use JSON::PP' collided with CLIO::Util::JSON's
#   encode_json/decode_json, causing a prototype mismatch warning.
# - NVIDIA.pm and Google.pm: referenced JSON::PP::true without ever
#   loading JSON::PP, causing 'Bareword "JSON::PP::true" not allowed'
#   compile errors.
#
# This test loads each provider, calls encode_json with a stream=>true
# field, and asserts the output is JSON `true` (not `1`).

use Test::More;

use JSON::PP ();

# Loading must succeed (no compile errors, no prototype warnings)
my @providers = qw(
    CLIO::Providers::Anthropic
    CLIO::Providers::Google
    CLIO::Providers::NVIDIA
);

for my $prov (@providers) {
    my $loaded = eval "require $prov; 1" ? 1 : 0;
    ok($loaded, "$prov compiles and loads");
    diag($@) if !$loaded && $@;
}

# Verify the encode_json output is JSON `true` for stream fields
use CLIO::Util::JSON qw(encode_json);

my $json = encode_json({ stream => JSON::PP::true, model => 'test' });
like($json, qr/"stream":true/, 'stream => JSON::PP::true encodes as JSON true (not 1)');

# And that a plain 1 is NOT treated as JSON true (this is why we need the constant)
my $json_int = encode_json({ stream => 1, model => 'test' });
like($json_int, qr/"stream":1/, 'plain 1 encodes as JSON 1 (not true) - confirms we need the constant');

done_testing();
