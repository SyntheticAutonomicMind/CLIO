package CLIO::Util::TextSanitizer;

use strict;
use warnings;
use utf8;  # Source code contains UTF-8
use Encode qw(decode encode);  # For proper UTF-8 handling

=head1 NAME

CLIO::Util::TextSanitizer - Universal text sanitization for API compatibility

=head1 DESCRIPTION

Provides text sanitization to prevent JSON encoding issues when sending
content to AI APIs. Handles UTF-8 emojis and other problematic characters.

=head1 SYNOPSIS

    use CLIO::Util::TextSanitizer qw(sanitize_text);
    
    my $clean = sanitize_text($text_with_emojis);

=cut

use Exporter 'import';
our @EXPORT_OK = qw(sanitize_text);

=head2 sanitize_text

Remove or replace UTF-8 emojis and problematic characters to prevent JSON encoding issues.

This prevents 400 Bad Request errors when emojis or other special UTF-8 characters
cause JSON encoding problems with APIs.

Arguments:
- $text: Text potentially containing emojis or special characters

Returns: Sanitized text with problematic characters removed/replaced

=cut

sub sanitize_text {
    my ($text) = @_;
    
    return $text unless defined $text;
    
    # Don't sanitize numbers - return them as-is to preserve numeric type
    # This prevents 0.2 from becoming "0.2" when JSON-encoded
    if ($text =~ /^-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/) {
        return $text;
    }
    
    # Ensure text is decoded as UTF-8 (convert bytes to characters)
    # Use eval to handle text that's already decoded
    eval { $text = decode('UTF-8', $text, Encode::FB_CROAK); };
    # If decode fails, text was already in character form, continue
    
    # Map common emojis/unicode to text equivalents using proper Unicode code points
    # Use \x{XXXX} format for all Unicode characters
    my %emoji_map = (
        "\x{2705}" => '[OK]',      # ✓ Check mark (heavy check mark)
        "\x{274C}" => '[FAIL]',    # ✗ Cross mark
        "\x{26A0}" => '[WARN]',    # ⚠️ Warning sign
        "\x{2139}" => '[INFO]',    # ℹ️ Information
        "\x{1F4DD}" => '[NOTE]',   # 📝 Memo
        "\x{1F3AF}" => '[TARGET]', # 🎯 Target
        "\x{1F4E6}" => '[DONE]',   # 📦 Package
        "\x{1F4DA}" => '[DOC]',    # 📚 Books
        "\x{1F41B}" => '[BUG]',    # 🐛 Bug
        "\x{1F6A7}" => '[WIP]',    # 🚧 Construction
        "\x{1F525}" => '[FIRE]',   # 🔥 Fire
        "\x{1F6D1}" => '[STOP]',   # 🛑 Stop sign
        "\x{1F680}" => '[ROCKET]', # 🚀 Rocket
        "\x{1F4A1}" => '[IDEA]',   # 💡 Light bulb
        "\x{1F514}" => '[ALERT]',  # 🔔 Bell
        "\x{2B50}" => '[STAR]',    # ⭐ Star
        "\x{2620}" => '[DANGER]',  # ☠️ Skull
        "\x{26A1}" => '[FAST]',    # ⚡ Lightning
        "\x{1F50D}" => '[SEARCH]', # 🔍 Magnifying glass
        "\x{1F512}" => '[LOCK]',   # 🔒 Lock
        "\x{1F511}" => '[KEY]',    # 🔑 Key
        "\x{1F9F0}" => '[TOOLS]',  # 🧰 Toolbox
        "\x{1F4BB}" => '[CODE]',   # 💻 Laptop
        "\x{1F4CB}" => '[FILES]',  # 📋 Clipboard
        "\x{1F333}" => '[GIT]',    # 🌳 Tree
        "\x{1F9E0}" => '[BRAIN]',  # 🧠 Brain
        "\x{1F517}" => '[LINK]',   # 🔗 Link
        "\x{2699}" => '[CONFIG]',  # ⚙️ Gear
        "\x{2192}" => '->',        # → Right arrow
        "\x{2190}" => '<-',        # ← Left arrow
        "\x{2191}" => '^',         # ↑ Up arrow
        "\x{2193}" => 'v',         # ↓ Down arrow
    );
    
    # Replace known emojis with text equivalents
    for my $emoji (keys %emoji_map) {
        my $replacement = $emoji_map{$emoji};
        $text =~ s/\Q$emoji\E/$replacement/g;
    }
    
    # Remove any remaining emoji characters (Unicode ranges for emojis)
    # This is a broad pattern - matches most emoji ranges
    $text =~ s/[\x{1F300}-\x{1F9FF}]//g;  # Miscellaneous Symbols and Pictographs
    $text =~ s/[\x{2600}-\x{26FF}]//g;    # Miscellaneous Symbols
    $text =~ s/[\x{2700}-\x{27BF}]//g;    # Dingbats
    $text =~ s/[\x{1F600}-\x{1F64F}]//g;  # Emoticons
    $text =~ s/[\x{1F680}-\x{1F6FF}]//g;  # Transport and Map Symbols
    $text =~ s/[\x{1F900}-\x{1F9FF}]//g;  # Supplemental Symbols and Pictographs
    $text =~ s/[\x{2300}-\x{23FF}]//g;    # Miscellaneous Technical
    $text =~ s/[\x{2B50}-\x{2BFF}]//g;    # Additional symbols
    
    # Return as character string (JSON::PP will handle UTF-8 encoding)
    return $text;
}

1;

__END__

=head1 WHY THIS EXISTS

AI APIs (particularly when sending JSON payloads) can reject requests containing
certain UTF-8 characters, especially emojis. This causes "400 Bad Request" errors.

Common sources of problematic characters:
- Custom instructions files (.clio/instructions.md)
- AI-generated responses (agents like to use emojis)
- Tool results (reading files with emojis)
- User input

This module provides a centralized sanitization function to prevent these issues.

=head1 USAGE LOCATIONS

- PromptManager: Sanitize custom instructions before including in system prompt
- WorkflowOrchestrator: Sanitize tool results before adding to messages
- Any code sending text to AI APIs

=head1 DESIGN DECISIONS

1. **Map before remove**: Common emojis mapped to readable text ([OK], [INFO])
   so meaning is preserved when possible

2. **Broad Unicode ranges**: Remove all emoji ranges to catch everything,
   even newly-added emojis

3. **Exportable function**: Not a class - simple function export for ease of use

4. **No dependencies**: Uses only Perl core features

=cut

1;
