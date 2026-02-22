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
our @EXPORT_OK = qw(encode_json decode_json JSON_BACKEND);

# Detect the best available JSON backend at compile time
my $_backend;
my $_encode;
my $_decode;

BEGIN {
    # Try JSON::XS first (fastest, C-based)
    if (eval { require JSON::XS; 1 }) {
        $_backend = 'JSON::XS';
        $_encode = \&JSON::XS::encode_json;
        $_decode = \&JSON::XS::decode_json;
    }
    # Try Cpanel::JSON::XS (fast C-based fork)
    elsif (eval { require Cpanel::JSON::XS; 1 }) {
        $_backend = 'Cpanel::JSON::XS';
        $_encode = \&Cpanel::JSON::XS::encode_json;
        $_decode = \&Cpanel::JSON::XS::decode_json;
    }
    # Fall back to JSON::PP (always available in Perl 5.14+)
    else {
        require JSON::PP;
        $_backend = 'JSON::PP';
        $_encode = \&JSON::PP::encode_json;
        $_decode = \&JSON::PP::decode_json;
    }
}

=head2 encode_json

Encode a Perl data structure to a JSON string.

    my $json = encode_json($hashref);

=cut

sub encode_json {
    goto &$_encode;
}

=head2 decode_json

Decode a JSON string to a Perl data structure.

    my $data = decode_json($json_string);

=cut

sub decode_json {
    goto &$_decode;
}

=head2 JSON_BACKEND

Returns the name of the JSON backend in use.

    print "Using: " . JSON_BACKEND() . "\n";

=cut

sub JSON_BACKEND {
    return $_backend;
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
