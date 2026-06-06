# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Markdown;

use strict;
use warnings;
use utf8;

use CLIO::UI::Terminal qw(box_char ui_char);

use open ':std', ':encoding(UTF-8)';

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
        _color_cache => {},  # Cache for theme color lookups
        %opts
    };
    
    return bless $self, $class;
}

=head2 color

Get a color from theme manager (helper method).
Uses per-instance cache to avoid repeated hash lookups.

=cut

sub color {
    my ($self, $key) = @_;
    
    return '' unless $self->{theme_mgr};
    
    # Return cached color if available
    return $self->{_color_cache}{$key} if exists $self->{_color_cache}{$key};
    
    # Fetch and cache
    my $color = $self->{theme_mgr}->get_color($key) || '';
    $self->{_color_cache}{$key} = $color;
    return $color;
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
    my $numbered_list_indent = -1;  # indent level of current numbered list
    
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        
        # Handle code blocks (allow optional leading whitespace)
        if ($line =~ /^\s*```(.*)$/) {
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
        
        # Check for display-level formulas ($$...$$) at the start of line
        if ($line =~ /^\$\$\s*(.+?)\s*\$\$\s*$/) {
            my $formula = $1;
            # Flush any table before the formula
            if ($in_table) {
                push @output, $self->render_table(@table_rows);
                @table_rows = ();
                $in_table = 0;
            }
            push @output, $self->render_formula_block($formula);
            next;
        }
        
        # Track numbered list context for sub-list indentation
        if ($line =~ /^(\s*)(?:\*\*)?(\d+)\.\s/) {
            $numbered_list_indent = length($1);
        } elsif ($line =~ /^(\s*)[-*+]\s/ && $numbered_list_indent >= 0) {
            # Bullet at or after numbered list indent -> indent as sub-item
            my $bullet_indent = length($1);
            if ($bullet_indent >= $numbered_list_indent) {
                $line = '  ' . $line;
            }
        } elsif ($line !~ /^\s*$/) {
            # Non-blank, non-list line resets numbered list tracking
            $numbered_list_indent = -1;
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
        return $self->color('markdown_quote') . box_char('vertical') . " " . '@RESET@' . $quoted;
    }
    
    # Horizontal rules (---, ***, ___, or variants with 3+ characters)
    if ($line =~ /^(?:---|---+|\*\*\*|\*\*\*+|___|___+)\s*$/) {
        # Render as a colored line
        return $self->color('markdown_quote') . box_char('horizontal') x 40 . '@RESET@';
    }
    
    # Lists - convert model whitespace to nesting depth (2 spaces per level)
    if ($line =~ /^(\s*)[-*+]\s+(.+)$/) {
        my $depth = int(length($1) / 2);
        my $indent = '  ' x $depth;
        my $text = $2;
        return $indent . $self->color('markdown_list_bullet') . "• " . '@RESET@' . $self->process_inline_formatting($text);
    }
    
    # Ordered lists
    if ($line =~ /^(\s*)(\d+)\.\s+(.+)$/) {
        my $depth = int(length($1) / 2);
        my $indent = '  ' x $depth;
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
    
    # Links and images are expanded in process_inline_formatting to include
    # " -> URL". We need to account for this in visual length calculation.
    # Process links: [text](url) -> text -> url
    $clean =~ s/\[([^\]]+)\]\(([^\)]+)\)/$1 -> $2/g;
    # Process images: ![alt](url) -> alt -> url
    $clean =~ s/!\[([^\]]*)\]\(([^\)]+)\)/$1 -> $2/g;
    
    # Now strip any ANSI escape codes
    $clean =~ s/\e\[[0-9;]*m//g;
    
    # Strip OSC 8 hyperlink wrappers (keep the visible text)
    $clean =~ s/\e\]8;;[^\e]*\e\\//g;
    
    # Strip @-codes that are OUTSIDE code blocks (these are color markers)
    $clean =~ s/@[A-Z_]+@//g;
    
    # Restore @ symbols that were inside code blocks
    $clean =~ s/\x01/\@/g;
    
    # Count visual width, accounting for common wide characters
    # See: https://www.unicode.org/reports/tr11/ (East Asian Width)
    my $width = 0;
    for my $char (split //, $clean) {
        my $ord = ord($char);
        # Characters that are truly double-width (East Asian Wide/Fullwidth):
        # - CJK Unified Ideographs and extensions
        # - Fullwidth ASCII variants
        # - Certain emoji (specifically those in presentation sequences)
        # 
        # NOT double-width (though sometimes rendered wide):
        # - Dingbats (U+2700-U+27BF) - single width in most fonts
        # - Miscellaneous Symbols (U+2600-U+26FF) - mostly single width
        # - Checkmarks, arrows, etc.
        if ($ord >= 0x1F300 && $ord <= 0x1F9FF ||  # Emoji (pictographs)
            $ord >= 0x1FA00 && $ord <= 0x1FAFF ||  # Extended emoji
            $ord >= 0x3000 && $ord <= 0x9FFF ||    # CJK ideographs
            $ord >= 0xAC00 && $ord <= 0xD7AF ||    # Korean Hangul
            $ord >= 0xF900 && $ord <= 0xFAFF ||    # CJK compatibility ideographs
            $ord >= 0xFE10 && $ord <= 0xFE1F ||    # Vertical forms
            $ord >= 0xFF00 && $ord <= 0xFFEF ||    # Fullwidth forms
            $ord >= 0x20000 && $ord <= 0x2FFFF) {  # CJK Extension B+
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
    
    # Calculate total table width to decide if wrapping is needed
    # Format: | content | content | = 1 (left border) + sum(width + 3 per col)
    # Each cell: " " + content + " " + "|" = width + 3 chars
    my $num_cols = scalar @col_widths;
    
    my $term_width = $self->{terminal_width} || 80;
    
    # If table fits, render normally
    my $table_width = 1;  # Left border
    for my $w (@col_widths) {
        $table_width += $w + 3;  # space + content + space + border
    }
    
    if ($table_width <= $term_width) {
        # Table fits - render without wrapping
        return $self->_render_table_formatted(\@parsed_rows, \@col_widths);
    }
    
    # Table is too wide - need to wrap columns
    # Strategy: reduce column widths to fit, wrapping cell content
    # First, determine how much space we have for content
    # Available = term_width - 1 (left border) - 3 per col (space, space, border)
    my $available_for_content = $term_width - 1 - (3 * $num_cols);
    $available_for_content = $num_cols if $available_for_content < $num_cols;  # At least 1 per col
    
    # Distribute available width proportionally, with minimum widths
    # Minimum width for each column is the length of the header text (or 1)
    my @min_widths;
    for my $i (0 .. $#col_widths) {
        if ($parsed_rows[0] && $parsed_rows[0]{cells}[$i]) {
            $min_widths[$i] = $self->_visual_length($parsed_rows[0]{cells}[$i]);
            $min_widths[$i] = 3 if $min_widths[$i] < 3;  # At least 3 chars
        } else {
            $min_widths[$i] = 3;
        }
    }
    
    # Calculate target widths: proportional to original, but respecting minimums
    my @target_widths;
    my $total_min = 0;
    for my $i (0 .. $#col_widths) {
        $total_min += $min_widths[$i];
    }
    
    if ($total_min <= $available_for_content) {
        # Minimums fit - distribute remaining space proportionally
        my $remaining = $available_for_content - $total_min;
        my $total_original = 0;
        for my $i (0 .. $#col_widths) {
            $total_original += ($col_widths[$i] - $min_widths[$i]);
        }
        
        for my $i (0 .. $#col_widths) {
            if ($total_original > 0) {
                my $proportion = ($col_widths[$i] - $min_widths[$i]) / $total_original;
                $target_widths[$i] = $min_widths[$i] + int($remaining * $proportion);
            } else {
                $target_widths[$i] = $min_widths[$i];
            }
        }
        
        # Distribute rounding remainder
        my $current_total = 0;
        for my $w (@target_widths) { $current_total += $w; }
        my $rounding_remainder = $available_for_content - $current_total;
        for my $i (0 .. $#col_widths) {
            if ($rounding_remainder <= 0) { last; }
            $target_widths[$i]++;
            $rounding_remainder--;
        }

        # Safety: if rounding pushed total above available (e.g. min_widths
        # sum already exceeds available), trim from the largest column down
        # until we fit. This ensures the table width never exceeds the
        # terminal width (5-char discrepancy bug fix).
        $current_total = 0;
        for my $w (@target_widths) { $current_total += $w; }
        if ($current_total > $available_for_content) {
            my $over = $current_total - $available_for_content;
            # Sort column indices by width descending
            my @order = sort { $target_widths[$b] <=> $target_widths[$a] } 0 .. $#target_widths;
            for my $idx (@order) {
                last if $over <= 0;
                while ($target_widths[$idx] > $min_widths[$idx] && $over > 0) {
                    $target_widths[$idx]--;
                    $over--;
                }
            }
        }
    } else {
        # Minimums don't fit (e.g. one column's header is wider than the
        # available terminal). Compress widths proportionally to the
        # available space so the table fits the terminal, with cells
        # wrapping to honor the compressed width. Apply a hard floor
        # of 1 to keep every column at least one cell wide.
        my $scale = $available_for_content / $total_min;
        my @floored;
        my $floor_total = 0;
        for my $i (0 .. $#min_widths) {
            my $scaled = int($min_widths[$i] * $scale);
            $scaled = 1 if $scaled < 1;
            $floored[$i] = $scaled;
            $floor_total += $scaled;
        }
        
        if ($floor_total > $available_for_content) {
            # Rounding pushed us over. Trim from the largest column down
            # until we fit.
            my @order = sort { $floored[$b] <=> $floored[$a] } 0 .. $#floored;
            for my $idx (@order) {
                last if $floor_total <= $available_for_content;
                if ($floored[$idx] > 1) {
                    $floored[$idx]--;
                    $floor_total--;
                }
            }
        }
        
        @target_widths = @floored;
    }
    
    # Now wrap cell content to fit target widths
    my @wrapped_rows;
    for my $row (@parsed_rows) {
        my @cell_wraps;
        for my $i (0 .. $#{$row->{cells}}) {
            my $cell = $row->{cells}[$i];
            my $target = $target_widths[$i];
            my @lines = $self->_wrap_text($cell, $target);
            push @cell_wraps, \@lines;
        }
        
        # Find max number of lines in any cell for this row
        my $max_lines = 1;
        for my $wrap (@cell_wraps) {
            $max_lines = scalar(@$wrap) if scalar(@$wrap) > $max_lines;
        }
        
        # Create wrapped row entries
        for my $line_num (0 .. $max_lines - 1) {
            my @line_cells;
            for my $i (0 .. $#cell_wraps) {
                $line_cells[$i] = $cell_wraps[$i][$line_num] // '';
            }
            push @wrapped_rows, {
                cells => \@line_cells,
                is_header => ($row->{is_header} && $line_num == 0),
                is_continuation => ($line_num > 0),
            };
        }
    }
    
    # Recalculate column widths based on wrapped content
    my @new_col_widths;
    for my $i (0 .. $#target_widths) {
        $new_col_widths[$i] = $target_widths[$i];
    }
    
    return $self->_render_table_formatted(\@wrapped_rows, \@new_col_widths);
}

=head2 _wrap_text

Wrap text to fit within a specified width, breaking at word boundaries.
Returns a list of lines that fit within the width.

=cut

sub _wrap_text {
    my ($self, $text, $width) = @_;
    
    return ('') unless defined $text && length($text);
    return ($text) if $self->_visual_length($text) <= $width;
    
    my @lines;
    my $current_line = '';
    my $current_len = 0;
    
    # Split text into words, preserving spaces
    my @words = split(/(\s+)/, $text);
    
    for my $word (@words) {
        next unless defined $word && length($word) > 0;
        
        my $word_len = $self->_visual_length($word);
        
        # If word itself is wider than the column, we need to break it
        if ($word_len > $width) {
            # If we have content on the current line, push it first
            if ($current_len > 0) {
                push @lines, $current_line;
                $current_line = '';
                $current_len = 0;
            }
            
            # Break the long word character by character
            my $partial = '';
            my $partial_len = 0;
            for my $char (split //, $word) {
                my $char_width = $self->_visual_length($char);
                if ($partial_len + $char_width > $width) {
                    push @lines, $partial;
                    $partial = $char;
                    $partial_len = $char_width;
                } else {
                    $partial .= $char;
                    $partial_len += $char_width;
                }
            }
            if (length($partial) > 0) {
                $current_line = $partial;
                $current_len = $partial_len;
            }
            next;
        }
        
        # Check if adding this word would exceed the width
        my $new_len = $current_len + $word_len;
        # Add a space if we already have content and this isn't whitespace
        my $separator = '';
        if ($current_len > 0 && $word !~ /^\s+$/) {
            $separator = ' ';
            $new_len += 1;
        }
        
        if ($new_len <= $width) {
            $current_line .= $separator . $word;
            $current_len = $new_len;
        } else {
            # Start a new line
            if ($current_len > 0) {
                push @lines, $current_line;
            }
            # Skip whitespace at line start
            if ($word !~ /^\s+$/) {
                $current_line = $word;
                $current_len = $word_len;
            } else {
                $current_line = '';
                $current_len = 0;
            }
        }
    }
    
    # Push remaining content
    if ($current_len > 0) {
        push @lines, $current_line;
    }
    
    # Ensure at least one line
    push @lines, '' unless @lines;
    
    return @lines;
}

=head2 _render_table_formatted

Render a parsed table with the given column widths. Handles both normal
and wrapped (multi-line) rows.

=cut

sub _render_table_formatted {
    my ($self, $parsed_rows, $col_widths) = @_;
    
    my @output;
    
    # Top border
    my $h = box_char('horizontal');
    my $top_border = box_char('topleft') . join(box_char('tdown'), map { $h x ($_ + 2) } @$col_widths) . box_char('topright');
    push @output, $self->color('table_border') . $top_border . '@RESET@';
    
    for my $i (0 .. $#{$parsed_rows}) {
        my $row = $parsed_rows->[$i];
        my $line = box_char('vertical');
        
        for my $j (0 .. $#{$row->{cells}}) {
            my $cell = $row->{cells}[$j];
            my $width = $col_widths->[$j];
            
            # Calculate visual length for padding (before adding ANSI codes)
            my $visual_len = $self->_visual_length($cell);
            
            # Apply formatting (this adds ANSI codes)
            # Process inline formatting for both headers and data cells
            # Headers get additional styling (table_header color) on top
            my $formatted;
            if ($row->{is_header}) {
                # First process inline formatting (bold, italic, code, links)
                my $processed = $self->process_inline_formatting($cell);
                # Then wrap with header color
                $formatted = $self->color('table_header') . $processed . '@RESET@';
            } else {
                $formatted = $self->process_inline_formatting($cell);
            }
            
            # Pad cell based on visual length, not formatted string length
            my $padding = $width - $visual_len;
            $padding = 0 if $padding < 0;  # Safety check
            $line .= " " . $formatted . (" " x $padding) . " " . $self->color('table_border') . box_char('vertical') . '@RESET@';
        }
        
        push @output, $line;
        
        # Add separator between distinct rows only
        # Skip separators between wrapped continuations of the same logical row
        if ($i < $#{$parsed_rows} && !$parsed_rows->[$i + 1]{is_continuation}) {
            my $sep = box_char('tright') . join(box_char('cross'), map { $h x ($_ + 2) } @$col_widths) . box_char('tleft');
            push @output, $self->color('table_border') . $sep . '@RESET@';
        }
    }
    
    # Bottom border
    my $bottom_border = box_char('bottomleft') . join(box_char('tup'), map { $h x ($_ + 2) } @$col_widths) . box_char('bottomright');
    push @output, $self->color('table_border') . $bottom_border . '@RESET@';
    
    return join("\n", @output);
}

=head2 process_inline_formatting

Process inline formatting like bold, italic, code, links

=cut

sub process_inline_formatting {
    my ($self, $text) = @_;
    
    # Pre-fetch all colors once (cached in color() method)
    my $code_color = $self->color('markdown_code');
    my $bold_color = $self->color('markdown_bold');
    my $italic_color = $self->color('markdown_italic');
    my $link_text_color = $self->color('markdown_link_text');
    my $link_url_color = $self->color('markdown_link_url');
    my $formula_color = $self->color('markdown_formula');
    
    # Code blocks inline (backticks)
    # Content inside backticks should be literal - escape @-codes to prevent
    # them from being interpreted as color codes by ANSI.pm
    # We use \x00AT\x00 as a placeholder, which gets restored in Chat.pm after ANSI parsing
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
    $text =~ s/\*\*(.+?)\*\*/${bold_color}$1\@RESET\@/g;
    $text =~ s/__([^_]+)__/${bold_color}$1\@RESET\@/g;
    
    # Italic (*text* or _text_) - must be careful not to match ** or __
    # For underscore italic, require word boundary before to avoid matching filenames
    # This prevents file_name.ext from being interpreted as file + _name_ + .ext
    $text =~ s/(?<!\*)\*([^\*]+)\*(?!\*)/${italic_color}$1\@RESET\@/g;
    # Match _text_ only when preceded by whitespace/start and followed by whitespace/punct/end
    $text =~ s/(^|[\s\(])_([^_]+)_(?=[\s\)\.\,\!\?\:\;]|$)/$1${italic_color}$2\@RESET\@/g;
    
    # Images ![alt](url) - show as alt text with clickable URL
    $text =~ s{!\[([^\]]*)\]\(([^\)]+)\)}{
        my ($alt, $url) = ($1, $2);
        my $linked_url = $self->_make_hyperlink($url, $url);
        "${link_text_color}${alt}\@RESET\@ → ${link_url_color}${linked_url}\@RESET\@"
    }ge;
    
    # Links [text](url) - show text as clickable hyperlink
    $text =~ s{\[([^\]]+)\]\(([^\)]+)\)}{
        my ($link_text, $url) = ($1, $2);
        my $linked_text = $self->_make_hyperlink($url, $link_text);
        "${link_text_color}${linked_text}\@RESET\@ → ${link_url_color}${url}\@RESET\@"
    }ge;
    
    # Formulas - inline math (single $ should NOT match $$)
    # Match $...$ but not $$...$$
    # Process the formula content to convert symbols first, then apply color
    $text =~ s/(?<!\$)\$([^\$]+)\$(?!\$)/{
        my $formula = $1;
        my $rendered = $self->render_formula_content($formula);
        $formula_color . "\$" . $rendered . "\$" . '@RESET@'
    }/ge;
    
    # Restore escaped characters from code blocks
    $text =~ s/\x00STAR\x00/*/g;
    $text =~ s/\x00UNDER\x00/_/g;
    $text =~ s/\x00LBRACK\x00/[/g;
    $text =~ s/\x00RBRACK\x00/]/g;
    
    return $text;
}

=head2 _make_hyperlink

Wrap text in an OSC 8 terminal hyperlink escape sequence.
In terminals that support it (iTerm2, Kitty, WezTerm, GNOME Terminal 3.26+,
Windows Terminal), the text becomes clickable. In others, only the text shows.

Arguments:
- $url: The URL target for the hyperlink
- $text: The visible text to display

Returns: Text wrapped in OSC 8 hyperlink sequences

=cut

sub _make_hyperlink {
    my ($self, $url, $text) = @_;
    
    return $text unless defined $url && length($url);
    
    # OSC 8 hyperlink: ESC ] 8 ; ; URL ST text ESC ] 8 ; ; ST
    # ST (String Terminator) = ESC backslash - more compatible than BEL
    return "\e]8;;${url}\e\\${text}\e]8;;\e\\";
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
    
    # Remove formulas (keep the LaTeX for reference)
    $text =~ s/\$\$([^\$]+)\$\$/$1/g;  # Display formulas
    $text =~ s/(?<!\$)\$([^\$]+)\$(?!\$)/$1/g;  # Inline formulas
    
    # Remove bold/italic
    $text =~ s/\*\*(.+?)\*\*/$1/g;
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

=head2 render_formula_block

Render a display-level (block) formula with special formatting

=cut

sub render_formula_block {
    my ($self, $formula) = @_;
    
    return '' unless defined $formula;
    
    my $formula_color = $self->color('markdown_formula');
    
    # Strip whitespace
    $formula =~ s/^\s+|\s+$//g;
    
    # Render formula content with Unicode conversions
    my $rendered = $self->render_formula_content($formula);
    
    # Render with a box frame
    my $h = box_char('horizontal');
    my $v = box_char('vertical');
    return $formula_color . box_char('topleft') . $h . " Formula " . $h x 19 . box_char('topright') . '@RESET@' . "\n" .
           $formula_color . $v . " " . '@RESET@' . $rendered . " " . $formula_color . $v . '@RESET@' . "\n" .
           $formula_color . box_char('bottomleft') . $h x 28 . box_char('bottomright') . '@RESET@';
}

=head2 render_formula_content

Render formula content with Unicode/ASCII representations for common symbols

=cut

sub render_formula_content {
    my ($self, $formula) = @_;
    
    return '' unless defined $formula;
    
    my $result = $formula;
    
    # Convert common LaTeX symbols to Unicode
    # Greek letters
    $result =~ s/\\alpha/α/g;
    $result =~ s/\\beta/β/g;
    $result =~ s/\\gamma/γ/g;
    $result =~ s/\\delta/δ/g;
    $result =~ s/\\epsilon/ε/g;
    $result =~ s/\\zeta/ζ/g;
    $result =~ s/\\eta/η/g;
    $result =~ s/\\theta/θ/g;
    $result =~ s/\\iota/ι/g;
    $result =~ s/\\kappa/κ/g;
    $result =~ s/\\lambda/λ/g;
    $result =~ s/\\mu/μ/g;
    $result =~ s/\\nu/ν/g;
    $result =~ s/\\xi/ξ/g;
    $result =~ s/\\omicron/ο/g;
    $result =~ s/\\pi/π/g;
    $result =~ s/\\rho/ρ/g;
    $result =~ s/\\sigma/σ/g;
    $result =~ s/\\tau/τ/g;
    $result =~ s/\\upsilon/υ/g;
    $result =~ s/\\phi/φ/g;
    $result =~ s/\\chi/χ/g;
    $result =~ s/\\psi/ψ/g;
    $result =~ s/\\omega/ω/g;
    
    # Capital Greek letters
    $result =~ s/\\Gamma/Γ/g;
    $result =~ s/\\Delta/Δ/g;
    $result =~ s/\\Theta/Θ/g;
    $result =~ s/\\Lambda/Λ/g;
    $result =~ s/\\Xi/Ξ/g;
    $result =~ s/\\Pi/Π/g;
    $result =~ s/\\Sigma/Σ/g;
    $result =~ s/\\Upsilon/Υ/g;
    $result =~ s/\\Phi/Φ/g;
    $result =~ s/\\Psi/Ψ/g;
    $result =~ s/\\Omega/Ω/g;
    
    # Common mathematical operators and symbols (routed through Terminal charset layer)
    my $times_c = ui_char('times');
    my $divide_c = ui_char('divide');
    my $pm_c = ui_char('plus_minus');
    my $approx_c = ui_char('approx');
    my $neq_c = ui_char('not_equal');
    my $leq_c = ui_char('less_equal');
    my $geq_c = ui_char('greater_equal');
    my $sqrt_c = ui_char('sqrt_sym');
    my $sum_c = ui_char('sum_sym');
    my $int_c = ui_char('integral');
    my $partial_c = ui_char('partial');
    my $nabla_c = ui_char('nabla');
    my $inf_c = ui_char('infinity');
    my $dot_c = ui_char('dot');
    my $ellipsis_c = ui_char('ellipsis');
    
    $result =~ s/\\sqrt/$sqrt_c/g;
    $result =~ s/\\cbrt/$sqrt_c/g;
    $result =~ s/\\sum/$sum_c/g;
    $result =~ s/\\prod/PROD/g;
    $result =~ s/\\int/$int_c/g;
    $result =~ s/\\oint/$int_c/g;
    $result =~ s/\\infty/$inf_c/g;
    $result =~ s/\\pm/$pm_c/g;
    $result =~ s/\\mp/-+/g;
    $result =~ s/\\times/$times_c/g;
    $result =~ s/\\div/$divide_c/g;
    $result =~ s/\\leq/$leq_c/g;
    $result =~ s/\\geq/$geq_c/g;
    $result =~ s/\\neq/$neq_c/g;
    $result =~ s/\\approx/$approx_c/g;
    $result =~ s/\\equiv/≡/g;
    $result =~ s/\\propto/∝/g;
    $result =~ s/\\partial/$partial_c/g;
    $result =~ s/\\nabla/$nabla_c/g;
    $result =~ s/\\forall/∀/g;
    $result =~ s/\\exists/∃/g;
    $result =~ s/\\in/∈/g;
    $result =~ s/\\notin/∉/g;
    $result =~ s/\\subset/⊂/g;
    $result =~ s/\\supset/⊃/g;
    $result =~ s/\\subseteq/⊆/g;
    $result =~ s/\\supseteq/⊇/g;
    $result =~ s/\\cup/∪/g;
    $result =~ s/\\cap/∩/g;
    $result =~ s/\\therefore/∴/g;
    $result =~ s/\\because/∵/g;
    $result =~ s/\\cdot/$dot_c/g;
    $result =~ s/\\ldots|\\dots/$ellipsis_c/g;
    
    # Power and subscript notation
    $result =~ s/\^2/²/g;
    $result =~ s/\^3/³/g;
    $result =~ s/\^-1/⁻¹/g;
    $result =~ s/\^n/ⁿ/g;
    
    # Special cases for common formulas
    if ($result =~ /E\s*=\s*mc\s*\^2/) {
        $result = "E = mc²";
    }
    
    return $result;
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

=item * B<Inline Formulas>: $formula$ (LaTeX, rendered with Unicode symbols)

=item * B<Display Formulas>: $$formula$$ (LaTeX block-level, with frame)

=item * B<Links>: [text](url) (text underlined, URL dimmed)

=item * B<Lists>: - item or * item or 1. item

=item * B<Blockquotes>: > quote text

=back

=head2 Formula Support

CLIO now supports both inline and display-level LaTeX formulas with Unicode rendering:

=over 4

=item * B<Inline Math>: Use `$formula$` for inline formulas (e.g., `$E = mc^2$`)

=item * B<Display Math>: Use `$$formula$$` for block-level formulas (on their own line)

=item * B<Symbol Conversion>: Common LaTeX symbols automatically convert to Unicode
  - Greek letters: \alpha -> α, \pi -> π, etc.
  - Math operators: \sqrt -> √, \sum -> ∑, \int -> ∫, etc.
  - Relations: \leq -> ≤, \geq -> ≥, \neq -> ≠, etc.
  - Superscripts: ^2 -> ², ^3 -> ³, etc.

=item * B<Preserved Content>: Original LaTeX is preserved and highlighted, not removed

=back

=head2 Example Formulas

    Inline: Einstein's equation is $E = mc^2$ showing energy-mass equivalence.
    
    Display:
    $$\int_0^{\infty} e^{-x^2} dx = \frac{\sqrt{\pi}}{2}$$
    
    With Greek: The quadratic formula is $x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$

=head2 Theming

Colors and styles can be customized by passing a theme hash:

    my $md = CLIO::UI::Markdown->new(
        theme => {
            header1 => "\e[1;36m",  # Bold cyan
            code    => "\e[93m",     # Bright yellow
            formula => "\e[92m",     # Bright green
            ...
        }
    );

=back
1;
