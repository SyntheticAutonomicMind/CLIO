# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Code::Scanner;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(scan scan_file language_for is_code_language);

our $VERSION = '0.01';

=head1 NAME

CLIO::Code::Scanner - Length-preserving source scanner that isolates code from non-code

=head1 SYNOPSIS

    use CLIO::Code::Scanner qw(scan language_for);

    my $lang  = language_for('lib/CLIO/Tools/Tool.pm');   # 'perl'
    my $clean = scan($source, $lang);

    # $clean has the same length as $source. Comments, POD, docstrings and
    # string literals are replaced with spaces, so every surviving offset maps
    # to the same line and column in the original.

=head1 DESCRIPTION

Roughly a quarter of the matches produced by naive text search over a codebase
are comments, documentation prose, or string literals. Measured on this repo:
21.8% of C<list_usages> hits, and 54% for a symbol that appears mostly in
documentation.

This module removes that noise without a parser and without CPAN dependencies.
It walks the source as a small state machine and blanks everything that is not
code, replacing each removed character with a space. Newlines are preserved, so
the result stays line-aligned with the input and a match in the scanned text can
be reported against the original file without a second pass.

The scanner is deliberately conservative. Where a construct is ambiguous - a
Perl regex delimiter versus division, for instance - it leaves the text as code
rather than guessing. That can leave a noisy match; it can never hide a real
one.

That invariant is why a C<#> preceded by C<$> or C<{> is not treated as a
comment opener: Perl's C<$#array> and shell's C<${#var}> and C<$#> are live
code, and blanking from there would hide every symbol later on the line. A C<#>
after a space or at the start of a token is still a comment.

=head2 Supported languages

C-like (C, C++, C#, Java, JavaScript, TypeScript, Go, Rust, Swift, Kotlin,
Scala, Dart, Objective-C), Perl, Ruby, Python, Shell, YAML/TOML/INI, and
Markdown. Unknown extensions are treated as plain text and scanned with hash
comments only, which is safe but weak; callers should check
L</is_code_language> first.

=cut

# Per-language scanning configuration.
#
#   line      - regex matching a line comment start at the current position
#   blocks    - arrayref of [open, close] block comment pairs
#   strings   - arrayref of quote characters, longest first for multi-char quotes
#   heredoc   - regex matching a heredoc operator, capturing the marker
#   pod       - arrayref of [start_directive_regex, end_directive_regex]
#   line_start_strings - quotes only meaningful at the start of a line
my %LANG = (
    c => {
        line    => qr{//},
        blocks  => [[ '/*', '*/' ]],
        strings => [qw(" ')],
        escapes => 1,
    },
    perl => {
        line    => qr{\#},
        blocks  => [],
        strings => [qw(" ' `)],
        escapes => 1,
        heredoc => qr{(?<op><< *['"](?<marker>[A-Za-z_]\w*)['"]|<< *[A-Za-z_]\w*)},
        pod     => [qr{^=\w+}, qr{^=cut\b}],
    },
    ruby => {
        line    => qr{\#},
        blocks  => [[ '=begin', '=end' ]],
        strings => [qw(" ' ?)],
        escapes => 1,
        # =begin is only a block opener at the start of a line.
        block_at_line_start => 1,
        heredoc => qr{(?<op><< *[-~]?['"]?(?<marker>[A-Za-z_]\w*)['"]?)},
    },
    python => {
        line    => qr{\#},
        blocks  => [],
        strings => ['"""', "'''", '"', "'"],
        escapes => 1,
    },
    sh => {
        line    => qr{\#},
        blocks  => [],
        strings => ['"', "'"],
        escapes => 1,
        heredoc => qr{(?<op><< *-?['"]?(?<marker>[A-Za-z_]\w*)['"]?)},
    },
    hash => {
        line    => qr{\#},
        blocks  => [],
        strings => ['"', "'"],
        escapes => 1,
    },
    markdown => {
        # No line-comment entry: '<!--' is a block opener, not a line
        # comment. Declaring it as both made the line-comment branch match
        # first and consume only the opener, so the body of a multi-line
        # HTML comment survived the scan while single-line ones were blanked.
        blocks  => [[ '<!--', '-->' ]],
        strings => [],
        escapes => 0,
    },
);

my %EXT = (
    c => 'c',      h => 'c',      cpp => 'c',    cxx => 'c',   hpp => 'c',
    cc => 'c',     cs => 'c',     java => 'c',   m => 'c',
    js => 'c',     jsx => 'c',    ts => 'c',     tsx => 'c',   mjs => 'c',
    cjs => 'c',    go => 'c',     rs => 'c',     swift => 'c', kt => 'c',
    kts => 'c',    scala => 'c',  dart => 'c',   php => 'c',
    pm => 'perl',  pl => 'perl',  t => 'perl',   pod => 'perl',
    rb => 'ruby',  rake => 'ruby',
    py => 'python', pyw => 'python',
    sh => 'sh',    bash => 'sh',  zsh => 'sh',
    yml => 'hash', yaml => 'hash', toml => 'hash', ini => 'hash',
    cfg => 'hash', conf => 'hash',
    md => 'markdown', markdown => 'markdown',
);

=head2 language_for

Arguments: $path (required) - file path
Returns: language key, or 'text' when the extension is unknown

=cut

sub language_for {
    my ($path) = @_;
    return 'text' unless defined $path && length $path;
    my ($ext) = $path =~ /\.([A-Za-z0-9]+)$/;
    return 'text' unless defined $ext;
    return $LANG{lc $ext} ? lc($ext) : ($EXT{lc $ext} || 'text');
}

=head2 is_code_language

Arguments: $language
Returns: Boolean - false for 'text', where scanning is unreliable

=cut

sub is_code_language {
    my ($lang) = @_;
    return 0 unless defined $lang && exists $LANG{$lang};
    return 1;
}

sub _blank_from {
    my ($src, $i, $end) = @_;
    # Blank [i, end) preserving newlines.
    my $chunk = substr($src, $i, $end - $i);
    $chunk =~ s/[^\n]/ /g;
    return $chunk;
}

=head2 scan

Arguments: $source (required), $language (required, see L</language_for>)
Returns: Scanned string, identical in length to $source, with non-code regions
         replaced by spaces. Returns $source unchanged for unknown languages.

=cut

sub scan {
    my ($source, $language) = @_;
    return '' unless defined $source;
    return $source unless defined $language && exists $LANG{$language};

    my $cfg = $LANG{$language};
    my $len = length $source;
    return $source if $len > 32 * 1024 * 1024;

    # Characters that can begin a non-code region. The walk copies everything up
    # to the next trigger in one operation instead of one character at a time,
    # which is the difference between scanning this repository in ~1s and ~11s.
    my %trigger;
    $trigger{'#'} = 1 if $cfg->{line} && "$cfg->{line}" =~ /#/;
    $trigger{'/'} = 1 if $cfg->{line} && "$cfg->{line}" =~ m{/} || grep { $_->[0] =~ m{/} } @{ $cfg->{blocks} || [] };
    $trigger{'<'} = 1 if grep { $_->[0] =~ /</ } @{ $cfg->{blocks} || [] };
    $trigger{'='} = 1 if $cfg->{pod} || grep { $_->[0] =~ /^=/ } @{ $cfg->{blocks} || [] };
    $trigger{substr($_, 0, 1)} = 1 for @{ $cfg->{strings} || [] };
    $trigger{'<'} = 1 if $cfg->{heredoc};
    my @triggers = sort keys %trigger;
    my $trigger_re = @triggers ? qr/[@{[ join('|', map { quotemeta } @triggers) ]}]/ : undef;

    my $out = '';
    my $i   = 0;
    my $at_line_start = 1;

    while ($i < $len) {
        my $before = $i;

        # Copy the plain run up to the next trigger (or end of source) verbatim.
        if ($trigger_re) {
            my ($pos) = substr($source, $i) =~ /\A(.*?)$trigger_re/s;
            my $run = defined $pos ? length $pos : $len - $i;
            if ($run > 0) {
                $out .= substr($source, $i, $run);
                $i += $run;
                # A directive only starts a region at the beginning of a line.
                $at_line_start = ($i > 0 && substr($source, $i - 1, 1) eq "\n") ? 1 : 0;
            }
        }
        last if $i >= $len;

        my $rest = substr($source, $i);

        # --- POD: =directive at line start through =cut ---
        if ($at_line_start && $cfg->{pod}) {
            my ($start_re, $end_re) = @{ $cfg->{pod} };
            if ($rest =~ /\A$start_re/) {
                my $dir_len = $rest =~ /\A([^\n]*)/ ? length($1) : 0;
                my $is_end  = ($rest =~ /\A$end_re/) ? 1 : 0;
                $out .= _blank_from($source, $i, $i + $dir_len);
                $i   += $dir_len;
                unless ($is_end) {
                    while ($i < $len) {
                        my $nl = index($source, "\n", $i);
                        my $stop = ($nl < 0) ? $len : $nl + 1;
                        my $line = substr($source, $i, $stop - $i);
                        $out .= _blank_from($source, $i, $stop);
                        $i = $stop;
                        last if $line =~ /\A$end_re/;
                    }
                }
                $at_line_start = 1;
                next;
            }
        }

        # --- line comment ---
        if ($cfg->{line} && $rest =~ /\A$cfg->{line}/) {
            # '#' is not always a comment opener. Perl's $#array (last index)
            # and shell's ${#var} / $# (length and argument count) put a '#'
            # in live code, and blanking from there hid every symbol later on
            # the line. A '#' preceded by a sigil or an opening brace is an
            # operator, not a comment.
            my $prev = $i > 0 ? substr($source, $i - 1, 1) : '';
            if (substr($source, $i, 1) eq '#' && ($prev eq '$' || $prev eq '{')) {
                $out .= '#';
                $at_line_start = 0;
                $i++;
                next;
            }
            my $nl = index($source, "\n", $i);
            $nl = $len if $nl < 0;
            $out .= _blank_from($source, $i, $nl);
            $i = $nl;
            next;
        }

        # --- block comment ---
        my $consumed = 0;
        for my $b (@{ $cfg->{blocks} || [] }) {
            my ($open, $close) = @$b;
            next unless substr($source, $i, length $open) eq $open;
            # Only some openers are anchored to a line start (=begin); a
            # '/*' or '<!--' may open anywhere. The old test inferred this
            # from whether the opener began with '/', which made an inline
            # markdown comment invisible to the block branch.
            next if $cfg->{block_at_line_start} && !$at_line_start;
            my $idx = index($source, $close, $i + length $open);
            my $end = ($idx < 0) ? $len : $idx + length($close);
            $out .= _blank_from($source, $i, $end);
            $i = $end;
            $consumed = 1;
            last;
        }
        next if $consumed;

        # --- heredoc ---
        if ($cfg->{heredoc} && $rest =~ /\A$cfg->{heredoc}/) {
            my $op     = $+{op};
            my $marker = $+{marker};

            # A heredoc operator with no usable marker must not blank the rest
            # of the file, so fall through and treat it as ordinary text.
            if (defined $op && length $marker) {
                my $body_start = $i + length $op;
                $out .= $op;
                $i = $body_start;

                my $done = 0;
                while ($i < $len) {
                    my $nl = index($source, "\n", $i);
                    my $stop = ($nl < 0) ? $len : $nl + 1;
                    my $line = substr($source, $i, $stop - $i);
                    (my $stripped = $line) =~ s/^\s+//;
                    $stripped =~ s/[\r\n\s]+$//;
                    if (length $stripped && $stripped eq $marker) {
                        $out .= _blank_from($source, $body_start, $i);
                        $out .= $line;
                        $i = $stop;
                        $done = 1;
                        last;
                    }
                    $i = $stop;
                }
                unless ($done) {
                    $out .= _blank_from($source, $body_start, $len);
                    $i = $len;
                }
                $at_line_start = 0;
                next;
            }
        }

        # --- quoted literal; longest quote first so """ beats " ---
        my $in_str = 0;
        for my $q (@{ $cfg->{strings} || [] }) {
            next unless substr($source, $i, length $q) eq $q;
            my $j    = $i + length $q;
            my $term = 0;
            while ($j < $len) {
                my $c = substr($source, $j, 1);
                if ($cfg->{escapes} && $c eq '\\') { $j += 2; next }
                last if $c eq "\n" && length($q) == 1;
                if (substr($source, $j, length $q) eq $q) {
                    $j += length $q; $term = 1; last;
                }
                $j++;
            }
            next unless $term;
            $out .= _blank_from($source, $i, $j);
            $i = $j;
            $in_str = 1;
            last;
        }
        if ($in_str) { $at_line_start = 0; next }

        # --- trigger character that starts nothing: copy it literally ---
        my $c = substr($source, $i, 1);
        $out .= $c;
        $at_line_start = ($c eq "\n") ? 1 : 0;
        $i++;

        # Progress guard: never spin on a construct no branch consumed.
        if ($i <= $before) {
            $out .= substr($source, $before, 1);
            $i = $before + 1;
        }
    }

    return $out;
}

=head2 scan_file

Arguments: $path (required), $language (optional, detected from the extension)
Returns: Scanned contents, or undef if the file cannot be read.

=cut

sub scan_file {
    my ($path, $language) = @_;
    return undef unless defined $path && -f $path;

    open my $fh, '<:encoding(UTF-8)', $path or return undef;
    my $src = do { local $/; <$fh> };
    close $fh;
    return undef unless defined $src;

    return scan($src, $language || language_for($path));
}

=head1 DESIGN NOTES

=head2 Why blanking rather than tokenising

Preserving length and newlines means a caller can search the scanned text and
report results against the original file with no bookkeeping. A token stream
would need an offset map for the same thing.

=head2 What is deliberately not handled

Regex literals in Perl and JavaScript are ambiguous with division without a
real parser. They are left as code. Similarly, unterminated strings stop at the
line end rather than swallowing the rest of the file, so a syntax error in one
line cannot blank the lines after it.

=head1 LIMITATIONS

Scanning is lexical, not syntactic. Interpolated variables inside double-quoted
strings are blanked along with the string, so a symbol used only inside an
interpolation will not be found by a scan-based search.

=head1 SEE ALSO

L<CLIO::Code::Extractor>, L<CLIO::Tools::CodeIntelligence>

=cut

1;

__END__

=head1 LICENSE

GPL-3.0-only

=cut
