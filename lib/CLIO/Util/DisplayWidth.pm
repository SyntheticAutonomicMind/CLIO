# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Util::DisplayWidth;

use strict;
use warnings;
use utf8;

use Exporter 'import';

our @EXPORT_OK = qw(
    display_width
    is_wide
    is_zero_width
    is_regional_indicator
);

=head1 NAME

CLIO::Util::DisplayWidth - Terminal column width of a Unicode string

=head1 SYNOPSIS

    use CLIO::Util::DisplayWidth qw(display_width);

    my $cols = display_width("check \x{2705}");   # 8, not 7

=head1 DESCRIPTION

Single source of truth for "how many terminal columns does this string
occupy". Every layout that pads or centers text needs this answer:
markdown tables, the line editor, progress animations. Three copies of
this arithmetic previously drifted apart, and the copy used by markdown
tables counted East Asian Wide emoji as one column, so a table row
containing U+2705 rendered one column wider than its border.

Width rules:

=over 4

=item * East Asian C<Wide> and C<Fullwidth> codepoints are 2 columns.

=item * Emoji presentation sequences (base + U+FE0F) are 2 columns, even
when the base codepoint is East Asian C<Neutral>.

=item * Regional indicator pairs (flags) are 2 columns.

=item * Combining marks, ZWJ, ZWNJ, word joiner, BOM, variation
selectors and tag characters are zero width. The width of a grapheme
cluster is the width of its first non-zero-width codepoint.

=item * Everything else is 1 column.

=back

Control sequences (ANSI colours, OSC hyperlinks) are I<not> stripped
here. Strip them first: C<CLIO::Core::ReadLine::_strip_ansi>, or the
markdown renderer's own preprocessing.

Uses L<Unicode::GCString> when installed (it is optional, not a CLIO
dependency) for exact grapheme clustering. Otherwise clusters are
walked with C<\X>, which is correct for every case above.

=cut

# Probe once at load time; the eval must not run per call.
my $HAS_GCSTRING = eval { require Unicode::GCString; 1 } ? 1 : 0;

=head2 is_zero_width

Arguments: $cp (codepoint, integer)
Returns: 1 when the codepoint occupies no columns, 0 otherwise

=cut

sub is_zero_width {
    my ($cp) = @_;
    return 0 unless defined $cp;

    my $ch = chr($cp);

    # Nonspacing marks (combining diacritics) and enclosing marks.
    return 1 if $ch =~ /\p{Mn}/;
    return 1 if $ch =~ /\p{Me}/;

    # Explicit zero-width format characters.
    return 1 if $cp == 0x200B;  # Zero Width Space
    return 1 if $cp == 0x200C;  # Zero Width Non-Joiner
    return 1 if $cp == 0x200D;  # Zero Width Joiner
    return 1 if $cp == 0x2060;  # Word Joiner
    return 1 if $cp == 0xFEFF;  # Zero Width No-Break Space / BOM

    # Variation Selectors (VS1-VS16).
    return 1 if $cp >= 0xFE00 && $cp <= 0xFE0F;

    # Tags (language tags, U+E0001..U+E007F).
    return 1 if $cp >= 0xE0001 && $cp <= 0xE007F;

    return 0;
}

=head2 is_regional_indicator

Arguments: $cp (codepoint, integer)
Returns: 1 for regional indicator symbols (U+1F1E6..U+1F1FF)

Regional indicators are East Asian Neutral but terminals give the pairs
that spell flags two columns.

=cut

sub is_regional_indicator {
    my ($cp) = @_;
    return 0 unless defined $cp;
    return $cp >= 0x1F1E6 && $cp <= 0x1F1FF;
}

=head2 is_wide

Arguments: $cp (codepoint, integer)
Returns: 1 when a single codepoint occupies two columns

=cut

sub is_wide {
    my ($cp) = @_;
    return 0 unless defined $cp;

    my $ch = chr($cp);

    # East Asian Wide and Fullwidth: CJK, kana, Hangul, fullwidth forms,
    # and the emoji blocks Unicode classifies as wide.
    return 1 if $ch =~ /\p{EA=Wide}/;
    return 1 if $ch =~ /\p{EA=Fullwidth}/;

    # Flags render two columns per pair.
    return 1 if is_regional_indicator($cp);

    return 0;
}

=head2 display_width

Arguments: $str (string)
Returns: number of terminal columns the string occupies

=cut

sub display_width {
    my ($str) = @_;
    return 0 unless defined $str && length($str);

    # Fast path: printable ASCII is one column per character.
    return length($str) if $str =~ /\A[\x20-\x7E]*\z/;

    if ($HAS_GCSTRING) {
        return Unicode::GCString->new($str)->columns;
    }

    # Fallback: walk grapheme clusters, count the base of each one.
    my $width = 0;
    while ($str =~ /(\X)/g) {
        my $cluster = $1;

        # Emoji presentation: a base carrying VS16 is drawn two columns
        # wide regardless of its East Asian Width class.
        my $emoji_presentation = $cluster =~ /\x{FE0F}/;

        for my $i (0 .. length($cluster) - 1) {
            my $ch = substr($cluster, $i, 1);
            my $cp = ord($ch);

            next if is_zero_width($cp);

            if (is_wide($cp)) {
                $width += 2;
            } elsif ($emoji_presentation && $cp > 0x7F && $ch =~ /\p{Emoji}/) {
                $width += 2;
            } else {
                $width += 1;
            }

            # Only the first non-zero-width codepoint decides the cluster.
            last;
        }
    }

    return $width;
}

1;

__END__

=head1 SEE ALSO

- L<CLIO::Core::ReadLine> (line editor cursor arithmetic)
- L<CLIO::UI::Markdown> (table column widths)
- L<CLIO::UI::ProgressSpinner> (frame erasure widths)
- Unicode Standard Annex #11, East Asian Width

=cut
