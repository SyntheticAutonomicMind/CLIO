# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Util::JSON;

use strict;
use warnings;
use utf8;

=head1 NAME

CLIO::Util::JSON - Opportunistic fast JSON with automatic fallback

=head1 DESCRIPTION

Provides encode_json and decode_json functions that automatically use the
fastest available JSON implementation:

  1. JSON::XS (C-based, ~50x faster) - if installed
  2. Cpanel::JSON::XS (C-based fork) - if installed
  3. JSON::PP (pure Perl, always available) - fallback

No CPAN installation required. Simply uses whatever is already on the system.

=head1 SYNOPSIS

    use CLIO::Util::JSON qw(encode_json decode_json);
    
    my $json = encode_json({ key => 'value' });
    my $data = decode_json('{"key":"value"}');

=cut

use Exporter 'import';
our @EXPORT_OK = qw(encode_json decode_json encode_json_pretty encode_json_canonical JSON_BACKEND
    safe_decode_json safe_encode_json is_hashref is_arrayref
);

# Detect the best available JSON backend at compile time
my $_backend;
my $_encode;
my $_decode;
my $_backend_obj;

BEGIN {
    # Try JSON::XS first (fastest, C-based)
    if (eval { require JSON::XS; 1 }) {
        $_backend = 'JSON::XS';
        $_encode = \&JSON::XS::encode_json;
        $_decode = \&JSON::XS::decode_json;
        $_backend_obj = JSON::XS->new->utf8;
    }
    # Try Cpanel::JSON::XS (fast C-based fork)
    elsif (eval { require Cpanel::JSON::XS; 1 }) {
        $_backend = 'Cpanel::JSON::XS';
        $_encode = \&Cpanel::JSON::XS::encode_json;
        $_decode = \&Cpanel::JSON::XS::decode_json;
        $_backend_obj = Cpanel::JSON::XS->new->utf8;
    }
    # Fall back to JSON::PP (always available in Perl 5.14+)
    else {
        require JSON::PP;
        $_backend = 'JSON::PP';
        $_encode = \&JSON::PP::encode_json;
        $_decode = \&JSON::PP::decode_json;
        $_backend_obj = JSON::PP->new->utf8;
    }
}

=head2 encode_json

Encode a Perl data structure to a JSON string.

    my $json = encode_json($hashref);

=cut

sub encode_json {
    my ($data) = @_;
    # Use canonical mode for deterministic output (critical for KV cache efficiency)
    # This ensures consistent key ordering across requests, maximizing cache hits
    # when the semantic content is identical
    return $_backend_obj->canonical->encode($data);
}

=head2 decode_json

Decode a JSON string to a Perl data structure.

    my $data = decode_json($json_string);

=cut

sub decode_json {
    goto &$_decode;
}


=head2 encode_json_pretty

Encode a Perl data structure to a pretty-printed, canonical JSON string.

    my $json = encode_json_pretty($hashref);

=cut

sub encode_json_pretty {
    my ($data) = @_;
    # All backends support OO interface for pretty/canonical
    if ($_backend eq 'JSON::XS') {
        return JSON::XS->new->utf8->pretty->canonical->encode($data);
    } elsif ($_backend eq 'Cpanel::JSON::XS') {
        return Cpanel::JSON::XS->new->utf8->pretty->canonical->encode($data);
    } else {
        return JSON::PP->new->utf8->pretty->canonical->encode($data);
    }
}

=head2 encode_json_canonical

Encode a Perl data structure to a JSON string with canonical (sorted) key ordering.

This ensures deterministic JSON output regardless of hash key insertion order,
which is critical for KV cache efficiency when sending tool definitions to
language models. Non-deterministic ordering causes cache misses even when
the semantic content is identical.

    my $json = encode_json_canonical($hashref);

Uses the backend's canonical (sort_keys) mode for consistent key ordering.

=cut

sub encode_json_canonical {
    my ($data) = @_;
    # All backends support canonical mode for deterministic output
    return $_backend_obj->canonical->encode($data);
}

=head2 safe_decode_json

Decode a JSON string to a Perl data structure, returning a default value on failure.

    my $data = safe_decode_json($json_string);
    my $data = safe_decode_json($json_string, {});   # Default on failure
    my $data = safe_decode_json($json_string, 'fallback');

Arguments:
    $json_str - JSON string to decode (required)
    $default  - Value to return on parse failure (optional, default: undef)

Returns: Decoded data structure, or C<$default> if parsing fails

=cut

sub safe_decode_json {
    my ($json_str, $default) = @_;
    my $result = eval { decode_json($json_str) };
    return defined $result ? $result : $default;
}

=head2 safe_encode_json

Encode a Perl data structure to a JSON string, returning a default value on failure.

    my $json = safe_encode_json($data);
    my $json = safe_encode_json($data, '');    # Empty string on failure
    my $json = safe_encode_json($data, '{}');  # Valid JSON on failure

Arguments:
    $data    - Data structure to encode (required)
    $default - Value to return on encode failure (optional, default: undef)

Returns: JSON string, or C<$default> if encoding fails

=cut

sub safe_encode_json {
    my ($data, $default) = @_;
    my $result = eval { encode_json($data) };
    return defined $result ? $result : $default;
}

=head2 JSON_BACKEND

Returns the name of the JSON backend in use.

    print "Using: " . JSON_BACKEND() . "\n";

=cut

sub JSON_BACKEND {
    return $_backend;
}

=head2 is_hashref / is_arrayref

Test whether a value is a hashref or arrayref, INCLUDING blessed variants.

Background: Perl's built-in ref() returns the class name for blessed
references ("Foo::Bar"), NOT "HASH" / "ARRAY". The common idiom
`ref($x) eq 'HASH'` is therefore FALSE for blessed hashes, which causes
silent data leakage in guards. These helpers accept both plain and
blessed refs.

    is_hashref({})                           # 1
    is_hashref(bless {}, 'Foo')              # 1
    is_hashref([])                           # 0
    is_hashref(undef)                        # 0
    is_hashref("string")                     # 0

    is_arrayref([])                          # 1
    is_arrayref(bless [], 'Foo')             # 1
    is_arrayref({})                          # 0

Replace `ref($x) eq 'HASH'` with `is_hashref($x)` and similarly for arrays
to avoid the silent-failure bug fixed in commit b5d93d3d.

=cut

sub is_hashref {
    my ($x) = @_;
    return 0 unless ref $x;
    return 1 if ref($x) eq 'HASH';
    return 1 if eval { $x->isa('HASH') };
    return 0;
}

sub is_arrayref {
    my ($x) = @_;
    return 0 unless ref $x;
    return 1 if ref($x) eq 'ARRAY';
    return 1 if eval { $x->isa('ARRAY') };
    return 0;
}

1;

__END__

=head1 PERFORMANCE

Approximate benchmarks for a typical JSON operation:

  JSON::XS:        ~50x faster than JSON::PP
  Cpanel::JSON::XS: ~50x faster than JSON::PP
  JSON::PP:         Baseline (pure Perl)

For CLIO's typical JSON operations (tool arguments, session state, API payloads),
the difference can be significant on low-end hardware:

  JSON::PP:  ~1-5ms per encode/decode
  JSON::XS:  ~0.02-0.1ms per encode/decode

=head1 NOTES

This module does NOT require any CPAN installation. It simply detects what
is already available on the system. JSON::PP is always available as it ships
with Perl 5.14+.

=cut

1;
