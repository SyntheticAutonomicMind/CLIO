package CLIO::Util::AnthropicXMLParser;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use Exporter 'import';
our @EXPORT_OK = qw(is_anthropic_xml_format parse_anthropic_xml_to_json);
use CLIO::Util::JSON qw(encode_json decode_json);

=head1 NAME

CLIO::Util::AnthropicXMLParser - Parse Anthropic's native XML tool call format

=head1 DESCRIPTION

Claude sometimes uses its native XML parameter format instead of JSON:

  <parameter name="key">value

Or mixed formats where it starts JSON but switches to XML mid-call:

  {"end_line":1050
  <parameter name="operation": "read_file", ...}

This module detects and converts these formats to standard JSON.

=head1 SYNOPSIS

    use CLIO::Util::AnthropicXMLParser;
    
    my $mixed = '{"key":123<parameter name="other">value}';
    
    if (is_anthropic_xml_format($mixed)) {
        my $json = parse_anthropic_xml_to_json($mixed);
        # Returns: {"key":123,"other":"value"}
    }

=cut

=head2 is_anthropic_xml_format

Detect if a string is Anthropic XML format (pure or mixed with JSON).

Safe detection that avoids false positives from XML in string values.

Arguments:
- $text: String to check

Returns: Boolean (1 if Anthropic XML, 0 if not)

=cut

sub is_anthropic_xml_format {
    my ($text) = @_;
    
    return 0 unless defined $text;
    
    # Must contain parameter tags to be Anthropic format
    return 0 unless ($text =~ /<parameter|<\/parameter>/);
    
    # Quick check: if it's valid JSON without parameter tags in strings, NOT Anthropic
    # Try to parse as JSON first
    my $is_valid_json = 0;
    eval {
        my $parsed = decode_json($text);
        $is_valid_json = 1;
    };
    
    # If JSON parses cleanly, it's NOT Anthropic XML (parameter tags are in string values)
    return 0 if $is_valid_json;
    
    # Has parameter tags AND JSON failed = likely Anthropic format
    # Additional validation: check for Anthropic XML patterns
    return 1 if ($text =~ /<parameter\s+name="/);  # Opening tag with name attribute
    return 1 if ($text =~ /<\/parameter>/);        # Closing tag
    
    return 0;
}

=head2 parse_anthropic_xml_to_json

Convert Anthropic XML parameter format to JSON.

Handles:
1. Pure XML: <parameter name="key">value
2. Mixed JSON/XML: {"key":val<parameter name="other">val2}
3. Malformed transitions between formats

Arguments:
- $text: XML or mixed-format text
- $debug: Optional debug flag

Returns: JSON string

=cut

sub parse_anthropic_xml_to_json {
    my ($text, $debug) = @_;
    
    $debug //= 0;
    my %params;
    
    print STDERR "[DEBUG][AnthropicXMLParser] Parsing Anthropic XML format\n" if $debug;
    print STDERR "[DEBUG][AnthropicXMLParser] Input: " . substr($text, 0, 200) . "...\n" if $debug;
    
    # Strategy 1: Extract any existing JSON portions first
    # Pattern: Find {..."key":value...} before XML tags interfere
    if ($text =~ /^\s*\{([^<]+)/) {
        my $json_fragment = "{" . $1;
        # Try to extract key:value pairs from partial JSON
        while ($json_fragment =~ /"(\w+)"\s*:\s*(\d+|"[^"]*"|true|false|null)/g) {
            my ($key, $value) = ($1, $2);
            # Remove quotes from string values for re-encoding
            $value =~ s/^"(.*)"$/$1/ if ($value =~ /^"/);
            $params{$key} = $value;
            print STDERR "[DEBUG][AnthropicXMLParser] Extracted from JSON fragment: $key => $value\n" if $debug;
        }
    }
    
    # Strategy 2: Extract XML parameter tags
    # Pattern: <parameter name="key">value
    while ($text =~ /<parameter\s+name="([^"]+)"[^>]*>([^<]*)<\/parameter>/gs) {
        my ($name, $value) = ($1, $2);
        $value =~ s/^\s+|\s+$//g;  # Trim whitespace
        
        # Type detection
        if ($value =~ /^-?\d+$/) {
            $params{$name} = $value + 0;  # Integer
        } elsif ($value =~ /^-?\d+\.\d+$/) {
            $params{$name} = $value + 0;  # Float
        } elsif (lc($value) eq 'true') {
            $params{$name} = \1;  # JSON true
        } elsif (lc($value) eq 'false') {
            $params{$name} = \0;  # JSON false
        } elsif ($value eq 'null' || $value eq '') {
            $params{$name} = undef;  # JSON null
        } else {
            $params{$name} = $value;  # String
        }
        
        print STDERR "[DEBUG][AnthropicXMLParser] Extracted from XML: $name => $value\n" if $debug;
    }
    
    # Strategy 3: Handle mixed format with parameter tags as properties
    # Pattern: <parameter name="key": value>  (note the colon - malformed XML/JSON hybrid)
    while ($text =~ /<parameter\s+name="([^"]+)"\s*:\s*([^}>]+)/gs) {
        my ($name, $value) = ($1, $2);
        $value =~ s/^\s+|\s+$//g;
        $value =~ s/^"(.*)"$/$1/;  # Remove surrounding quotes if present
        $params{$name} = $value unless exists $params{$name};
        print STDERR "[DEBUG][AnthropicXMLParser] Extracted from hybrid format: $name => $value\n" if $debug;
    }
    
    if (%params) {
        my $json = encode_json(\%params);
        print STDERR "[DEBUG][AnthropicXMLParser] Result JSON: $json\n" if $debug;
        return $json;
    }
    
    # Fallback: return empty JSON object
    print STDERR "[WARN][AnthropicXMLParser] No parameters extracted, returning empty object\n" if $debug;
    return '{}';
}

1;

=head1 DEBUGGING

Enable debug output:

    my $json = parse_anthropic_xml_to_json($xml, 1);

=head1 SEE ALSO

L<CLIO::Util::JSONRepair> - Complementary JSON repair utilities

=cut
