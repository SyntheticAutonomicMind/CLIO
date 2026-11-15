# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Code::Extractor;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(extract_symbols classify_reference kind_weights);

our $VERSION = '0.01';

=head1 NAME

CLIO::Code::Extractor - Typed symbol extraction and reference classification

=head1 SYNOPSIS

    use CLIO::Code::Extractor qw(extract_symbols classify_reference);
    use CLIO::Code::Scanner qw(scan language_for);

    my $clean = scan($source, 'perl');
    my @syms  = extract_symbols($clean, 'perl', $path);
    # ({ kind => 'function', name => 'read_file', line => 812,
    #    package => 'CLIO::Tools::FileOperations', signature => 'read_file($params, $ctx)' })

    my $kind = classify_reference($clean_line, 'read_file');   # 'call'

=head1 DESCRIPTION

Turns scanned source into typed symbols and labels each reference with the role
it plays. This is what L<CLIO::Tools::CodeIntelligence> was missing: a text
search returns a definition, a call site, an import and a mention in a comment
as an undifferentiated list, so the model has to read every hit to work out
which one it wanted.

Extraction runs over L<CLIO::Code::Scanner> output, so comments and string
literals cannot produce symbols. Patterns are lexical rather than syntactic:
they are strong on the languages CLIO targets and deliberately report a
confidence instead of pretending to parse.

=head1 METHODS

=cut

# Definition patterns per language family. Each entry is
#   [ regex, kind, name_capture_index ]
# ordered most-specific first. Patterns are anchored to the start of a scanned
# line, which the scanner guarantees is real code.
my %DEF_PATTERNS = (
    perl => [
        [ qr/^package\s+([\w:]+)/,                     'package',  1 ],
        [ qr/^sub\s+(\w+)/,                            'function', 1 ],
        [ qr/^use\s+(?:base|parent)\s+([\w:]+)/,       'base',     1 ],
        [ qr/^use\s+([\w:]+)/,                         'import',   1 ],
        [ qr/^\s*(?:our|my)\s+([%\@\$\*]\w+)\s*=/,     'variable', 1 ],
        [ qr/^\s*use\s+constant\s+([A-Z][A-Z0-9_]*)/,  'constant', 1 ],
    ],
    c => [
        [ qr/^(?:public|private|protected|internal|static|final|abstract|\s)*\s*(?:class|interface|enum|struct|trait|record)\s+(\w+)/, 'class', 1 ],
        [ qr/^(?:package|namespace)\s+([\w.]+)/,                          'package', 1 ],
        [ qr/^(?:pub\s+)?fn\s+(\w+)/,                                     'function', 1 ],
        # Functions with or without a return type. Control-flow and other
        # statement keywords are excluded so 'if (x) {' is not reported as a
        # function named 'if'.
        [ qr/^(?!\s*(?:if|for|while|switch|catch|return|do|else|try|sizeof|new|delete)\b)(?:[A-Za-z_][\w:<>,*&\[\]\s]*[\s*&])?([A-Za-z_]\w*)\s*\([^()]*\)\s*(?:const\b\s*)?(?:\{|:|->|throws\b|$)/, 'function', 1 ],
        [ qr/^(?:const|let|var)\s+(\w+)/,                                 'variable', 1 ],
        [ qr{^(?:import|use|#include)\s+([\w./{}*]+)},                    'import',  1 ],
        [ qr/^export\s+(?:default\s+)?(?:const|let|var|function|class)\s+(\w+)/, 'function', 1 ],
    ],
    python => [
        [ qr/^class\s+(\w+)/,            'class',    1 ],
        [ qr/^def\s+(\w+)/,              'function', 1 ],
        [ qr/^async\s+def\s+(\w+)/,      'function', 1 ],
        [ qr/^(?:from\s+([\w.]+)\s+import|import\s+([\w.]+))/, 'import', 1 ],
        [ qr/^([A-Za-z_]\w*)\s*=/,       'variable', 1 ],
    ],
    ruby => [
        [ qr/^module\s+([\w:]+)/,   'package',  1 ],
        [ qr/^class\s+([\w:]+)/,    'class',    1 ],
        [ qr/^def\s+(?:self\.)?(\w+)/, 'function', 1 ],
        [ qr{^require(?:_relative)?\s+['"]([\w./]+)['"]}, 'import', 1 ],
    ],
    sh => [
        [ qr/^(\w+)\s*\(\)\s*\{/,      'function', 1 ],
        [ qr{^(?:source|\.)\s+([\w./-]+)}, 'import', 1 ],
    ],
);

# How much a symbol kind is worth when ranking search results. Definitions are
# what a caller usually wants; mentions are what a grep returns by accident.
my %KIND_WEIGHT = (
    package  => 10, class    => 10, base     => 8,
    function => 9,  method   => 8,  constant => 7,
    variable => 5,  import   => 4,
    definition => 10, declaration => 8,
    qualified_call => 6, method_call => 6, call => 6,
    assignment => 3, reference => 2, mention => 1,
);

=head2 kind_weights

Returns: Hashref mapping a kind or reference role to its ranking weight.

=cut

sub kind_weights { return \%KIND_WEIGHT }

=head2 extract_symbols

Arguments:
  $clean   (required) - scanned source, see L<CLIO::Code::Scanner/scan>
  $language (required) - language key
  $path   (optional)  - recorded on each symbol
Returns: List of symbol hashrefs in source order.

=cut

sub extract_symbols {
    my ($clean, $language, $path) = @_;
    return () unless defined $clean && length $clean;
    my $patterns = $DEF_PATTERNS{$language} or return ();

    my @syms;
    my $line_no = 0;
    my $package = '';

    for my $line (split /\n/, $clean, -1) {
        $line_no++;
        next unless $line =~ /\S/;
        # Indented definitions are still definitions; strip leading whitespace
        # but keep the line otherwise intact for signature capture.
        (my $t = $line) =~ s/^\s+//;

        for my $p (@$patterns) {
            my ($re, $kind, $idx) = @$p;
            next unless $t =~ $re;
            # Prefer the declared capture index. Patterns using an alternation
            # only populate one branch, so fall back to the first group that
            # actually matched ('import x' vs 'from x import y').
            my @caps = ($1, $2, $3);
            my $name = defined $idx ? $caps[ $idx - 1 ] : undef;
            $name = (grep { defined } @caps)[0]
                unless defined $name && length $name;
            next unless defined $name && length $name;

            $package = $name if $kind eq 'package';

            my %sym = (
                kind   => $kind,
                name   => $name,
                line   => $line_no,
                column => (length($line) - length($t) + 1),
            );
            $sym{package}  = $package  if length $package;
            $sym{path}     = $path     if defined $path;
            $sym{signature} = _signature($t, $name);
            push @syms, \%sym;
            last;   # most specific pattern wins
        }
    }
    return @syms;
}

# Trim a definition line down to something useful as a signature, dropping the
# trailing body brace and any runaway length.
sub _signature {
    my ($line, $name) = @_;
    my $sig = $line;
    $sig =~ s/\s*\{.*$//;
    $sig =~ s/\s+$//;
    return $sig if length($sig) <= 120;
    return substr($sig, 0, 117) . '...';
}

=head2 classify_reference

Arguments: $line (scanned, code only), $symbol
Returns: One of definition, declaration, method_call, qualified_call, call,
         assignment, reference.

Order matters: a line can match several shapes, and the most specific reading
is the useful one.

=cut

sub classify_reference {
    my ($line, $symbol) = @_;
    return 'reference' unless defined $line && defined $symbol && length $symbol;

    my $q = quotemeta($symbol);
    (my $t = $line) =~ s/^\s+//;

    return 'definition' if $t =~ /^(?:sub|def|func|fn|function|class|interface|enum|struct|trait|module|package|namespace)\s+$q\b/;
    return 'definition' if $t =~ /^(?:export\s+)?(?:const|let|var)\s+$q\b.*=>\s*(?:async\s*)?\(/;
    return 'declaration' if $t =~ /^(?:our|my|local|extern|declare|type)\b.*\b$q\b/;
    return 'method_call' if $line =~ /->\s*$q\s*[(\{;]/ || $line =~ /\.\s*$q\s*\(/;
    return 'qualified_call' if $line =~ /::\s*$q\s*[(\{;]/ || $line =~ /\.\s*$q\s*\.\s*\w/;
    return 'call' if $line =~ /(?<![\w:.\$])$q\s*\(/;
    return 'assignment' if $line =~ /\b$q\b\s*(?:=|\+=|-=|\|=)(?!=)/;
    return 'reference';
}

=head1 LIMITATIONS

Lexical extraction cannot resolve dynamic dispatch, metaprogramming, or
decorator-generated methods, and multi-line definitions are attributed to their
first line. Where a language is not in %DEF_PATTERNS, extraction returns nothing
rather than guessing.

=head1 SEE ALSO

L<CLIO::Code::Scanner>, L<CLIO::Tools::CodeIntelligence>

=cut

1;

__END__

=head1 LICENSE

GPL-3.0-only

=cut
