package CLIO::UI::Markdown;

use strict;
use warnings;
use utf8;
use open ':std', ':encoding(UTF-8)';
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::Markdown - Markdown to ANSI converter for terminal output

=head1 DESCRIPTION

Converts common Markdown elements to ANSI escape codes for rich terminal display.
Supports bold, italic, code, headers, links, lists, tables, and code blocks.
Uses theme manager for colors.

=head1 SYNOPSIS

    use CLIO::UI::Markdown;
    
    my $md = CLIO::UI::Markdown->new(theme_mgr => $theme_mgr);
    my $ansi = $md->render("This is **bold** and *italic* text");
    print $ansi, "\n";

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        debug => $opts{debug} || 0,
        theme_mgr => $opts{theme_mgr},  # Theme manager for colors
        %opts
    };
    
    return bless $self, $class;
}

=head2 color

Get a color from theme manager (helper method)

=cut

sub color {
    my ($self, $key) = @_;
    
    return '' unless $self->{theme_mgr};
    return $self->{theme_mgr}->get_color($key);
}

=head2 render

Convert markdown text to ANSI-formatted text

=cut

sub render {
    my ($self, $text) = @_;
    
    return '' unless defined $text;
    
    # Use -1 limit to preserve trailing empty fields (newlines)
    my @lines = split /\n/, $text, -1;
    my @output;
    my $in_code_block = 0;
    my $code_lang = '';
    my $in_table = 0;
    my @table_rows;
    
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        
        # Handle code blocks
        if ($line =~ /^```(.*)$/) {
            # Flush table if we were in one
            if ($in_table) {
                push @output, $self->render_table(@table_rows);
                @table_rows = ();
                $in_table = 0;
            }
            
            if ($in_code_block) {
                # End of code block
                $in_code_block = 0;
                push @output, '';
            } else {
                # Start of code block
                $in_code_block = 1;
                $code_lang = $1 || '';
                my $lang_display = $code_lang ? " ($code_lang)" : '';
                push @output, $self->color('markdown_code_block') . "Code Block$lang_display:" . '@RESET@';
            }
            next;
        }
        
        if ($in_code_block) {
            # Inside code block - just add with code color
            push @output, $self->color('markdown_code_block') . "  " . $line . '@RESET@';
            next;
        }
        
        # Detect table rows (starts with |, contains |, ends with |)
        # Also handle rows that might have trailing whitespace after |
        my $trimmed_line = $line;
        $trimmed_line =~ s/\s+$//;  # Remove trailing whitespace
        
        if ($trimmed_line =~ /^\|.+\|$/) {
            # Check if this looks like a separator row
            if ($trimmed_line =~ /^\|[\s\-:|]+\|$/) {
                # Separator row - mark as table and continue collecting
                $in_table = 1;
                push @table_rows, $trimmed_line;
                next;
            } else {
                # Data row - add to table
                $in_table = 1;
                push @table_rows, $trimmed_line;
                
                # Check if next line is NOT a table row (end of table)
                # Look ahead, skipping blank lines that might be in the middle of the table
                my $next_idx = $i + 1;
                while ($next_idx <= $#lines && $lines[$next_idx] =~ /^\s*$/) {
                    $next_idx++;  # Skip blank lines
                }
                
                my $next_is_table = 0;
                if ($next_idx <= $#lines) {
                    my $next_trimmed = $lines[$next_idx];
                    $next_trimmed =~ s/\s+$//;
                    $next_is_table = ($next_trimmed =~ /^\|.+\|$/);
                }
                
                if (!$next_is_table) {
                    # End of table - render it
                    push @output, $self->render_table(@table_rows);
                    @table_rows = ();
                    $in_table = 0;
                }
                next;
            }
        } else {
            # Not a table row - flush table if we were in one
            # But don't flush for blank lines - the table might continue
            if ($in_table && $line !~ /^\s*$/) {
                push @output, $self->render_table(@table_rows);
                @table_rows = ();
                $in_table = 0;
            } elsif ($line =~ /^\s*$/ && $in_table) {
                # Blank line inside table - skip it but don't end the table
                next;
            }
        }
        
        # Process inline markdown
        $line = $self->render_inline($line);
        
        push @output, $line;
    }
    
    # Flush any remaining table
    if ($in_table && @table_rows) {
        push @output, $self->render_table(@table_rows);
    }
    
    return join("\n", @output);
}

=head2 render_inline

Process inline markdown elements (bold, italic, code, links, etc.)

=cut

sub render_inline {
    my ($self, $line) = @_;
    
    # Headers (must be at start of line)
    if ($line =~ /^(#{1,6})\s+(.+)$/) {
        my $level = length($1);
        my $text = $2;
        my $color = $level == 1 ? $self->color('markdown_header1') :
                   $level == 2 ? $self->color('markdown_header2') :
                   $self->color('markdown_header3');
        return $color . $text . '@RESET@';
    }
    
    # Blockquotes
    if ($line =~ /^>\s+(.+)$/) {
        my $quoted = $self->process_inline_formatting($1);
        return $self->color('markdown_quote') . "│ " . '@RESET@' . $quoted;
    }
    
    # Horizontal rules (---, ***, ___, or variants with 3+ characters)
    if ($line =~ /^(?:---|---+|\*\*\*|\*\*\*+|___|___+)\s*$/) {
        # Render as a colored line
        return $self->color('markdown_quote') . "─" x 40 . '@RESET@';
    }
    
    # Lists
    if ($line =~ /^(\s*)[-*+]\s+(.+)$/) {
        my $indent = $1;
        my $text = $2;
        return $indent . $self->color('markdown_list_bullet') . "• " . '@RESET@' . $self->process_inline_formatting($text);
    }
    
    # Ordered lists
    if ($line =~ /^(\s*)(\d+)\.\s+(.+)$/) {
        my $indent = $1;
        my $num = $2;
        my $text = $3;
        return $indent . $self->color('markdown_list_bullet') . "$num. " . '@RESET@' . $self->process_inline_formatting($text);
    }
    
    # Regular line with inline formatting
    return $self->process_inline_formatting($line);
}

=head2 _visual_length

Calculate the visual length of a string, stripping ANSI codes and accounting
for markdown that will be rendered. Used for table column width calculations.

=cut

sub _visual_length {
    my ($self, $text) = @_;
    
    # First, strip markdown formatting to get the actual text
    my $clean = $text;
    
    # Remove bold markdown (**text** -> text, __text__ -> text)
    $clean =~ s/\*\*([^\*]+)\*\*/$1/g;
    $clean =~ s/__([^_]+)__/$1/g;
    
    # Remove italic markdown (*text* -> text, _text_ -> text)
    $clean =~ s/(?<!\*)\*([^\*]+)\*(?!\*)/$1/g;
    $clean =~ s/(^|[\s\(])_([^_]+)_(?=[\s\)\.\,\!\?\:\;]|$)/$1$2/g;
    
    # Handle inline code specially: remove backticks but preserve @-codes as literal text
    # Replace @-codes inside backticks with a placeholder before general @-code stripping
    $clean =~ s{`([^`]+)`}{
        my $code = $1;
        $code =~ s/\@/\x01/g;  # Temporarily replace @ with \x01
        $code
    }ge;
    
    # Remove links [text](url) -> text
    $clean =~ s/\[([^\]]+)\]\([^\)]+\)/$1/g;
    
    # Remove images ![alt](url) -> alt
    $clean =~ s/!\[([^\]]*)\]\([^\)]+\)/$1/g;
    
    # Now strip any ANSI escape codes
    $clean =~ s/\e\[[0-9;]*m//g;
    
    # Strip @-codes that are OUTSIDE code blocks (these are color markers)
    $clean =~ s/@[A-Z_]+@//g;
    
    # Restore @ symbols that were inside code blocks
    $clean =~ s/\x01/\@/g;
    
    # Count visual width, accounting for common wide characters
    my $width = 0;
    for my $char (split //, $clean) {
        my $ord = ord($char);
        # Most emoji and CJK characters are double-width
        # This is a simplified check - emoji range and CJK
        if ($ord >= 0x1F300 && $ord <= 0x1FAFF ||  # Emoji
            $ord >= 0x2600 && $ord <= 0x27BF ||    # Misc symbols
            $ord >= 0x3000 && $ord <= 0x9FFF ||    # CJK
            $ord >= 0xFF00 && $ord <= 0xFFEF) {    # Fullwidth
            $width += 2;
        } else {
            $width += 1;
        }
    }
    
    return $width;
}

=head2 render_table

Render a markdown table with borders and formatting

=cut

sub render_table {
    my ($self, @rows) = @_;
    
    return '' unless @rows;
    
    # Parse table rows
    my @parsed_rows;
    my $is_header = 1;
    my @col_widths;
    
    for my $row (@rows) {
        # Skip separator rows (contain only |, -, :, and whitespace)
        next if $row =~ /^\|[\s\-:|]+\|$/;
        
        # Split by | and clean up
        my @cells = split /\|/, $row;
        shift @cells if $cells[0] =~ /^\s*$/;  # Remove leading empty
        pop @cells if $cells[-1] =~ /^\s*$/;   # Remove trailing empty
        
        # Trim whitespace from cells
        @cells = map { s/^\s+|\s+$//gr } @cells;
        
        # Track column widths (use visual length to account for markdown)
        for my $i (0 .. $#cells) {
            my $len = $self->_visual_length($cells[$i]);
            $col_widths[$i] = $len if !defined $col_widths[$i] || $len > $col_widths[$i];
        }
        
        push @parsed_rows, {
            cells => \@cells,
            is_header => $is_header
        };
        $is_header = 0;  # Only first row is header
    }
    
    # Build formatted table
    my @output;
    
    # Top border
    my $top_border = "┌" . join("┬", map { "─" x ($_ + 2) } @col_widths) . "┐";
    push @output, $self->color('table_border') . $top_border . '@RESET@';
    
    for my $i (0 .. $#parsed_rows) {
        my $row = $parsed_rows[$i];
        my $line = "│";
        
        for my $j (0 .. $#{$row->{cells}}) {
            my $cell = $row->{cells}[$j];
            my $width = $col_widths[$j];
            
            # Calculate visual length for padding (before adding ANSI codes)
            my $visual_len = $self->_visual_length($cell);
            
            # Apply formatting (this adds ANSI codes)
            my $formatted = $row->{is_header} ? 
                $self->color('table_header') . $cell . '@RESET@' :
                $self->process_inline_formatting($cell);
            
            # Pad cell based on visual length, not formatted string length
            my $padding = $width - $visual_len;
            $padding = 0 if $padding < 0;  # Safety check
            $line .= " " . $formatted . (" " x $padding) . " " . $self->color('table_border') . "│" . '@RESET@';
        }
        
        push @output, $line;
        
        # Add separator after header
        if ($row->{is_header}) {
            my $sep = "├" . join("┼", map { "─" x ($_ + 2) } @col_widths) . "┤";
            push @output, $self->color('table_border') . $sep . '@RESET@';
        }
    }
    
    # Bottom border
    my $bottom_border = "└" . join("┴", map { "─" x ($_ + 2) } @col_widths) . "┘";
    push @output, $self->color('table_border') . $bottom_border . '@RESET@';
    
    return join("\n", @output);
}

=head2 process_inline_formatting

Process inline formatting like bold, italic, code, links

=cut

sub process_inline_formatting {
    my ($self, $text) = @_;
    
    # Code blocks inline (backticks)
    # IMPORTANT: Content inside backticks should be literal - escape @-codes to prevent
    # them from being interpreted as color codes by ANSI.pm
    # We use \x00AT\x00 as a placeholder, which gets restored in Chat.pm after ANSI parsing
    my $code_color = $self->color('markdown_code');
    $text =~ s{`([^`]+)`}{
        my $code_content = $1;
        $code_content =~ s/\@/\x00AT\x00/g;
        $code_content =~ s/\*/\x00STAR\x00/g;
        $code_content =~ s/_/\x00UNDER\x00/g;
        $code_content =~ s/\[/\x00LBRACK\x00/g;
        $code_content =~ s/\]/\x00RBRACK\x00/g;
        "${code_color}${code_content}\@RESET\@"
    }ge;
    
    # Bold (**text** or __text__)
    my $bold_color = $self->color('markdown_bold');
    
    $text =~ s/\*\*([^\*]+)\*\*/${bold_color}$1\@RESET\@/g;
    $text =~ s/__([^_]+)__/${bold_color}$1\@RESET\@/g;
    
    # Italic (*text* or _text_) - must be careful not to match ** or __
    # For underscore italic, require word boundary before to avoid matching filenames
    # This prevents file_name.ext from being interpreted as file + _name_ + .ext
    my $italic_color = $self->color('markdown_italic');
    $text =~ s/(?<!\*)\*([^\*]+)\*(?!\*)/${italic_color}$1\@RESET\@/g;
    # Match _text_ only when preceded by whitespace/start and followed by whitespace/punct/end
    $text =~ s/(^|[\s\(])_([^_]+)_(?=[\s\)\.\,\!\?\:\;]|$)/$1${italic_color}$2\@RESET\@/g;
    
    # Images ![alt](url) - show as alt text with URL (no emoji, proper markdown)
    my $link_text_color = $self->color('markdown_link_text');
    my $link_url_color = $self->color('markdown_link_url');
    $text =~ s/!\[([^\]]*)\]\(([^\)]+)\)/${link_text_color}$1\@RESET\@ → ${link_url_color}$2\@RESET\@/g;
    
    # Links [text](url) - show text with URL more prominently
    $text =~ s/\[([^\]]+)\]\(([^\)]+)\)/${link_text_color}$1\@RESET\@ → ${link_url_color}$2\@RESET\@/g;
    
    # Restore escaped characters from code blocks
    $text =~ s/\x00STAR\x00/*/g;
    $text =~ s/\x00UNDER\x00/_/g;
    $text =~ s/\x00LBRACK\x00/[/g;
    $text =~ s/\x00RBRACK\x00/]/g;
    
    return $text;
}

=head2 strip_markdown

Remove all markdown formatting, returning plain text

=cut

sub strip_markdown {
    my ($self, $text) = @_;
    
    return '' unless defined $text;
    
    # Remove code blocks
    $text =~ s/```[^\n]*\n.*?```\n?//gs;
    
    # Remove inline code
    $text =~ s/`([^`]+)`/$1/g;
    
    # Remove bold/italic
    $text =~ s/\*\*([^\*]+)\*\*/$1/g;
    $text =~ s/__([^_]+)__/$1/g;
    $text =~ s/\*([^\*]+)\*/$1/g;
    $text =~ s/_([^_]+)_/$1/g;
    
    # Remove links, keep text
    $text =~ s/\[([^\]]+)\]\([^\)]+\)/$1/g;
    
    # Remove headers
    $text =~ s/^#{1,6}\s+//gm;
    
    # Remove blockquotes
    $text =~ s/^>\s+//gm;
    
    # Remove list markers
    $text =~ s/^(\s*)[-*+]\s+/$1/gm;
    $text =~ s/^(\s*)\d+\.\s+/$1/gm;
    
    return $text;
}

1;

__END__

=head1 FEATURES

=head2 Supported Markdown Elements

=over 4

=item * B<Headers>: # H1, ## H2, ### H3 (colored and bold)

=item * B<Bold>: **text** or __text__

=item * B<Italic>: *text* or _text_

=item * B<Inline Code>: `code` (highlighted)

=item * B<Code Blocks>: ```language\ncode\n``` (formatted with language hint)

=item * B<Links>: [text](url) (text underlined, URL dimmed)

=item * B<Lists>: - item or * item or 1. item

=item * B<Blockquotes>: > quote text

=back

=head2 Theming

Colors and styles can be customized by passing a theme hash:

    my $md = CLIO::UI::Markdown->new(
        theme => {
            header1 => "\e[1;36m",  # Bold cyan
            code    => "\e[93m",     # Bright yellow
            ...
        }
    );

=head1 AUTHOR

Fewtarius

=cut
