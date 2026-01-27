package CLIO::Util::JSONRepair;

use strict;
use warnings;
use utf8;

=head1 NAME

CLIO::Util::JSONRepair - Utility for repairing malformed JSON from AI model outputs

=head1 DESCRIPTION

Handles common JSON parsing errors that occur when AI models generate tool call arguments.
These include missing values, unescaped quotes, trailing commas, and XML-style parameters.

This module centralizes JSON repair logic to avoid code duplication across WorkflowOrchestrator
and ToolExecutor.

=head1 SYNOPSIS

    use CLIO::Util::JSONRepair qw(repair_malformed_json);
    
    my $broken_json = '{"operation": "read", "offset": , "length": 8192}';
    my $fixed_json = repair_malformed_json($broken_json);
    # Returns: {"operation": "read", "offset": null, "length": 8192}

=head1 FUNCTIONS

=cut

use Exporter 'import';
our @EXPORT_OK = qw(repair_malformed_json);

=head2 repair_malformed_json($json_str, $debug)

Repairs common malformed JSON patterns from AI model outputs.

Handles:
- Missing values: "param":, -> "param":null,
- Missing values with whitespace: "param": , -> "param":null,
- Trailing commas: {...} -> {...}
- XML parameter format: <parameter name="key">value</parameter>

Arguments:
    $json_str - Malformed JSON string
    $debug - Optional flag for debug output (default: false)

Returns:
    Fixed JSON string

=cut

sub repair_malformed_json {
    my ($json_str, $debug) = @_;
    $debug //= 0;
    
    my $original = $json_str;
    
    # Check if this is Anthropic/Claude XML parameter format: <parameter name="...">value</parameter>
    # This happens when the model uses XML-style tool calling instead of JSON
    if ($json_str =~ /<parameter|<\/parameter>/) {
        print STDERR "[DEBUG][JSONRepair] Detected XML parameter format, converting to JSON\n"
            if $debug;
        
        # Extract parameters from XML format
        my %params;
        while ($json_str =~ /<parameter\s+name="([^"]+)"[^>]*>([^<]*)<\/parameter>/gs) {
            my ($name, $value) = ($1, $2);
            # Try to detect value type
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
        }
        
        if (%params) {
            require JSON::PP;
            $json_str = JSON::PP::encode_json(\%params);
            print STDERR "[DEBUG][JSONRepair] Converted XML to JSON: $json_str\n"
                if $debug;
            return $json_str;
        }
    }
    
    # Fix pattern: "param":, or "param": , (missing value with optional whitespace)
    # Handles cases where AI omits values for optional parameters
    # Regex explanation:
    #   "(\w+)"  - Quoted parameter name
    #   \s*      - Optional whitespace after opening quote
    #   :        - Colon separator
    #   \s*      - Optional whitespace before comma (THIS WAS THE BUG)
    #   ,        - Comma that indicates missing value
    $json_str =~ s/"(\w+)"\s*:\s*,/"$1":null,/g;
    
    # Fix trailing comma before } or ] (another common AI mistake)
    $json_str =~ s/,\s*}/}/g;
    $json_str =~ s/,\s*\]/]/g;
    
    # Fix unescaped quotes inside string values (but not property names)
    # Pattern: "key": "value with " unescaped quote"
    # This is tricky - we need to escape quotes that are inside string values
    # but not the quotes that delimit the string itself
    # For now, we'll handle the most common case: trailing unescaped quotes
    
    # Fix: "value": "text", "length": number} -> ensure proper structure
    # Remove any stray quotes or commas that break JSON structure
    $json_str =~ s/"\s*,\s*"/","/g;  # Normalize quote-comma-quote spacing
    
    if ($json_str ne $original && $debug) {
        print STDERR "[DEBUG][JSONRepair] Repaired malformed JSON\n";
        my $details = $original ne $json_str ? " (made changes)" : " (no changes)";
        print STDERR "[DEBUG][JSONRepair] Repair result$details\n";
    }
    
    return $json_str;
}

1;

=head1 DEBUGGING

Enable debug output by passing a true second argument:

    my $fixed = repair_malformed_json($broken_json, 1);

This will print debug messages to STDERR showing what repairs were applied.

=head1 HISTORY

This module was created to centralize JSON repair logic that was previously
duplicated in WorkflowOrchestrator.pm and ToolExecutor.pm. The duplication
led to a bug where "param": , (with whitespace) wasn't being fixed properly.

See: Session restoration bug with malformed JSON from resumed sessions.

=cut

1;
