#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: grep_search handles literal { and } in user-provided regex without
# emitting the Perl "Unescaped left brace in regex is passed through" warning,
# while preserving the semantics of valid quantifiers ({n}, {n,}, {n,m}).
#
# Background: agents pass Perl hash-dereference patterns like
# q{$skill->{type}} as regex queries. Perl's qr// compile-time warns about
# any { that isn't part of a quantifier, and the warning bleeds to STDERR
# even when qr is wrapped in eval (eval catches die, not warnings). The
# helper _escape_unescaped_braces escapes literal { and } so the warning
# does not fire, while leaving valid quantifier syntax intact.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use File::Basename qw(dirname);
use Cwd qw(abs_path);
use File::Temp qw(tempdir);

my $repo_root = abs_path(dirname(dirname(dirname($0))));
$repo_root = abs_path('.') unless -d "$repo_root/lib";
unshift @INC, "$repo_root/lib";

require CLIO::Tools::FileOperations;

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $label) = @_;
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

# ---- _escape_unescaped_braces unit tests ----

my $tool = CLIO::Tools::FileOperations->new(debug => 0, session_dir => '/tmp');

# Valid quantifiers are preserved as-is
ok($tool->_escape_unescaped_braces('a{3}b')       eq 'a{3}b',       'preserves {n} quantifier');
ok($tool->_escape_unescaped_braces('a{3,5}b')     eq 'a{3,5}b',     'preserves {n,m} quantifier');
ok($tool->_escape_unescaped_braces('a{3,}b')      eq 'a{3,}b',      'preserves {n,} quantifier');

# Non-quantifier braces are escaped to literal
ok($tool->_escape_unescaped_braces('{type}')      eq '\{type\}',    'escapes literal {text}');
ok($tool->_escape_unescaped_braces('a{b}c')       eq 'a\{b\}c',     'escapes {non-digit}');
ok($tool->_escape_unescaped_braces('a{}b')        eq 'a\{\}b',      'escapes empty {}');
ok($tool->_escape_unescaped_braces('a}b')         eq 'a\}b',        'escapes stray closing brace');

# Plain text is unchanged
ok($tool->_escape_unescaped_braces('abc')         eq 'abc',         'plain text unchanged');
ok($tool->_escape_unescaped_braces('')            eq '',            'empty string unchanged');

# Original bug-report pattern (Perl hash dereference in regex).
# Note: q{} strips backslashes inside its delimiters, so we build the
# expected escaped string with explicit concatenation to get \{ and \}.
my $bug_query = q{freeform.*type|type.*freeform|$skill->{type}.*=};
my $escaped   = $tool->_escape_unescaped_braces($bug_query);
my $expected  = 'freeform.*type|type.*freeform|$skill->' . '\{type\}' . '.*=';
ok($escaped eq $expected,
   'escapes original bug-report pattern (literal braces become \{ and \})');

# ---- grep_search integration: warning suppression ----

# Create a tmp directory with a sample file that matches the bug-report pattern.
my $tmp = tempdir(CLEANUP => 1);
my $sample_path = "$tmp/sample.pm";
open my $fh, '>:encoding(UTF-8)', $sample_path or die "Cannot create $sample_path: $!";
print $fh <<'END';
package Test::Sample;
sub foo {
    my $skill = { type => 'freeform' };
    my $x = $skill->{type} eq 'freeform';
    my $pattern = q{freeform.*type|type.*freeform|$skill->{type}.*=};
    return 1;
}
1;
END
close $fh;

# Capture warnings emitted during grep_search. The bug fires at compile time
# of qr//, which bypasses eval - so we have to hook $SIG{__WARN__} externally
# and run grep_search, then assert the hook was not called for the offending
# warning. (Belt-and-suspenders: the helper also escapes the brace so the
# regex doesn't trigger the warning at all.)
my $warning_captured = '';
my $result;
{
    local $SIG{__WARN__} = sub { $warning_captured .= $_[0] };
    $result = $tool->grep_search({
        query     => $bug_query,
        directory => $tmp,
        is_regex  => 1,
    });
    ok($result->{success}, 'grep_search with hash-deref query returns success');
    ok(scalar(@{$result->{output}}) >= 3,
       'grep_search finds matches for hash-deref query (got ' . scalar(@{$result->{output}}) . ')');
}
ok(index($warning_captured, 'Unescaped left brace') == -1,
   'no "Unescaped left brace" warning emitted for hash-deref query');

# ---- grep_search integration: quantifier semantics preserved ----

# Valid quantifier {3} must still match 3+ a's, not literal "{3}"
my $quant_path = "$tmp/quant.txt";
open $fh, '>:encoding(UTF-8)', $quant_path or die;
print $fh "aaa\naaaa\naaaaa\nabc\n";
close $fh;

$result = $tool->grep_search({
    query     => 'a{3}',
    directory => $tmp,
    pattern   => 'quant.txt',
    is_regex  => 1,
});
ok($result->{success}, 'a{3} regex compiles');
ok(scalar(@{$result->{output}}) == 3,
   'a{3} matches exactly the 3 lines with 3+ consecutive a\'s (got ' . scalar(@{$result->{output}}) . ')');

# ---- grep_search integration: literal {text} treated as text ----

my $literal_path = "$tmp/literal.txt";
open $fh, '>:encoding(UTF-8)', $literal_path or die;
print $fh "{3} marker\nhello {3} world\nno braces here\n";
close $fh;

$result = $tool->grep_search({
    query     => '{3}',
    directory => $tmp,
    pattern   => 'literal.txt',
    is_regex  => 1,
});
ok($result->{success}, 'literal {3} regex compiles');
ok(scalar(@{$result->{output}}) == 2,
   'literal {3} matches the 2 lines containing the literal text {3} (got ' . scalar(@{$result->{output}}) . ')');

print "\n";
print "Pass: $pass\n";
print "Fail: $fail\n";
exit($fail ? 1 : 0);
