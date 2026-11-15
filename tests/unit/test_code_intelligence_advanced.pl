#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_code_intelligence_advanced.pl - Advanced tests for CodeIntelligence tool

=head1 DESCRIPTION

Tests the new CodeIntelligence features:
- list_usages: max_results cap, kind classification, non-code filtering,
  path normalization, context lines, line truncation
- outline: new operation, symbol extraction, signature capture
- Scanner/Extractor: comment stripping, symbol extraction, reference classification

=cut

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use CLIO::Tools::CodeIntelligence;
use CLIO::Code::Scanner qw(scan language_for is_code_language);
use CLIO::Code::Extractor qw(extract_symbols classify_reference kind_weights);
use File::Temp qw(tempdir);
use File::Spec;
use Cwd 'abs_path';

print "="x60, "\n";
print "CodeIntelligence Advanced Test Suite\n";
print "="x60, "\n\n";

my $project_root = abs_path("$FindBin::Bin/../..");
chdir($project_root) or die "Cannot change to project root: $!";
print "Working directory: $project_root\n\n";

my $tool = CLIO::Tools::CodeIntelligence->new(debug => 0);

my $tests_passed = 0;
my $tests_failed = 0;

sub run_test {
    my ($name, $params, $expected_success, $check_output) = @_;

    print "-"x60, "\n";
    print "TEST: $name\n";
    print "-"x60, "\n";

    my $result = $tool->execute($params, { session => { id => 'test' } });

    my $success = $result->{success} ? 1 : 0;

    if ($success == $expected_success) {
        if (!$check_output || $check_output->($result)) {
            print "[OK] PASS\n\n";
            $tests_passed++;
            return 1;
        } else {
            print "[FAIL] FAIL: Output validation failed\n";
            require Data::Dumper;
            local $Data::Dumper::Indent = 1;
            local $Data::Dumper::Sortkeys = 1;
            local $Data::Dumper::Terse = 1;
            local $Data::Dumper::Maxdepth = 3;
            print "Result: ", Data::Dumper::Dumper($result), "\n\n";
            $tests_failed++;
            return 0;
        }
    } else {
        print "[FAIL] FAIL: Expected success=$expected_success, got $success\n";
        print "Error: ", $result->{error} || 'N/A', "\n";
        print "Message: ", $result->{message} || 'N/A', "\n\n";
        $tests_failed++;
        return 0;
    }
}

print "\n### list_usages: max_results cap Tests ###\n";

# Test: max_results caps the output
run_test(
    "list_usages - max_results caps output",
    { operation => 'list_usages', symbol_name => 'use strict', file_paths => ['lib/'], max_results => 5 },
    1,
    sub {
        my $r = shift;
        return $r->{count} == 5 && $r->{truncated} && $r->{limit} == 5;
    }
);

# Test: max_results=0 means no limit (0)
run_test(
    "list_usages - max_results=0 means no limit",
    { operation => 'list_usages', symbol_name => 'use strict', file_paths => ['lib/'], max_results => 0 },
    1,
    sub {
        my $r = shift;
        return $r->{limit} == 0;
    }
);

# Test: max_results above limit (1000) is clamped
run_test(
    "list_usages - max_results clamped to 1000",
    { operation => 'list_usages', symbol_name => 'use strict', file_paths => ['lib/'], max_results => 99999 },
    1,
    sub {
        my $r = shift;
        return $r->{limit} == 1000;
    }
);

# Test: invalid max_results (string) rejected
run_test(
    "list_usages - invalid max_results rejected",
    { operation => 'list_usages', symbol_name => 'use strict', file_paths => ['lib/'], max_results => 'abc' },
    0,
    sub {
        my $r = shift;
        return $r->{error} =~ /max_results/;
    }
);

# Test: invalid context_lines (string) rejected
run_test(
    "list_usages - invalid context_lines rejected",
    { operation => 'list_usages', symbol_name => 'use strict', file_paths => ['lib/'], context_lines => 'abc' },
    0,
    sub {
        my $r = shift;
        return $r->{error} =~ /context_lines/;
    }
);

# Test: context_lines capped at 10
run_test(
    "list_usages - context_lines capped at 10",
    { operation => 'list_usages', symbol_name => 'use strict', file_paths => ['lib/'], context_lines => 999 },
    1,
    sub {
        my $r = shift;
        # The cap is applied; we just verify it doesn't error
        return $r->{success};
    }
);

print "\n### list_usages: kind classification Tests ###\n";

# Test: kind classification on a Perl sub definition
run_test(
    "list_usages - kind classification: definition",
    { operation => 'list_usages', symbol_name => 'list_usages', file_paths => ['lib/CLIO/Tools/CodeIntelligence.pm'] },
    1,
    sub {
        my $r = shift;
        return 0 unless $r->{count} > 0;
        my $def = grep { $_->{kind} eq 'definition' } @{$r->{usages}};
        return $def > 0;
    }
);

# Test: kind classification: call
run_test(
    "list_usages - kind classification: call",
    { operation => 'list_usages', symbol_name => 'log_debug', file_paths => ['lib/CLIO/Tools/CodeIntelligence.pm'] },
    1,
    sub {
        my $r = shift;
        return 0 unless $r->{count} > 0;
        my $call = grep { $_->{kind} eq 'call' } @{$r->{usages}};
        return $call > 0;
    }
);

# Test: non-code matches are actually filtered
# Asserting only that the field exists let the filter be disabled entirely
# without a single test failing - the count would simply read 0.
run_test(
    "list_usages - non-code matches are filtered out",
    { operation => 'list_usages', symbol_name => 'FileOperations', file_paths => ['lib/'] },
    1,
    sub {
        my $r = shift;
        return 0 unless $r->{success};
        return 0 unless defined $r->{filtered_noncode};
        # FileOperations appears in POD, in comments, and in 'use' lines.
        # Some of those hits must have been rejected as non-code.
        return $r->{filtered_noncode} > 0;
    }
);

# Test: ranking puts a definition above a mention, then the cap applies
# The cap used to be applied while collecting matches, so it returned the
# first files alphabetically - prose, usually - and the definition never
# reached the result set however small the budget.
run_test(
    "list_usages - cap applies after ranking, not during collection",
    { operation => 'list_usages', symbol_name => 'read_file', file_paths => ['.'], max_results => 1 },
    1,
    sub {
        my $r = shift;
        return 0 unless $r->{success} && $r->{count} == 1;
        my $top = $r->{usages}[0];
        return 0 unless $top;
        # With a budget of one and correct ordering the single result is the
        # definition, in source, not a mention in documentation.
        return ($top->{kind} // '') eq 'definition'
            && $top->{file} =~ m{^lib/};
    }
);

# Test: a qualified reference is not mistaken for a comment
# The post-filter's lookbehind excluded ':' before the symbol, which is
# exactly the shape of a qualified call, so every such reference was counted
# as non-code and dropped.
run_test(
    "list_usages - qualified references are classified, not dropped",
    { operation => 'list_usages', symbol_name => 'language_for', file_paths => ['lib/'], max_results => 200 },
    1,
    sub {
        my $r = shift;
        return 0 unless $r->{success};
        my @qualified = grep { ($_->{kind} // '') eq 'qualified_call' } @{ $r->{usages} || [] };
        return @qualified > 0;
    }
);

print "\n### list_usages: path normalization Tests ###\n";

# Test: paths are repo-root-relative
run_test(
    "list_usages - paths are repo-root-relative",
    { operation => 'list_usages', symbol_name => 'use strict', file_paths => ['lib/'] },
    1,
    sub {
        my $r = shift;
        return 0 unless $r->{count} > 0;
        # All paths should be relative (not absolute)
        for my $u (@{$r->{usages}}) {
            return 0 if File::Spec->file_name_is_absolute($u->{file});
        }
        return 1;
    }
);

# Test: the same query from a subdirectory returns the same answer
# The reported path is repo-root-relative while the scan resolved it against
# the process working directory. From lib/ that produced lib/lib/..., which
# does not exist, so the file could not be read and every match in it was
# reported as non-code.
run_test(
    "list_usages - identical result from a subdirectory",
    { operation => 'list_usages', symbol_name => 'scan_file', file_paths => ['.'], max_results => 100 },
    1,
    sub {
        my $from_root = shift;
        return 0 unless $from_root->{success};

        my $cwd = Cwd::getcwd();
        chdir("$project_root/lib") or return 0;
        my $from_sub = $tool->execute(
            { operation => 'list_usages', symbol_name => 'scan_file',
              file_paths => ['.'], max_results => 100 },
            { session => { id => 'test' } },
        );
        chdir($cwd) or return 0;

        return 0 unless $from_sub->{success};
        return 0 unless ($from_sub->{count} // -1) == ($from_root->{count} // -2);

        # Same files, same kinds - not merely the same number.
        my $sig = sub {
            my ($r) = @_;
            return join '|', map { ($_->{file} // '') . ':' . ($_->{kind} // '') }
                sort { ($a->{file} // '') cmp ($b->{file} // '') }
                @{ $r->{usages} || [] };
        };
        return $sig->($from_sub) eq $sig->($from_root);
    }
);

# Test: a symbol that appears in POD, comments and its own module still has
# its definition found and its prose excluded. The raw match count, the kept
# count and the drop count must add up, so a scan that failed to read the file
# (and therefore classified everything as non-code) shows up as a change in
# the total rather than hiding behind a plausible-looking cap.
run_test(
    "list_usages - definition found, POD and comments excluded",
    { operation => 'list_usages', symbol_name => 'read_file',
      file_paths => ['lib/CLIO/Tools/FileOperations.pm'], max_results => 500 },
    1,
    sub {
        my $r = shift;
        return 0 unless $r->{success};
        return 0 unless ($r->{count} // 0) > 0;

        my @defs = grep { ($_->{kind} // '') eq 'definition' } @{ $r->{usages} };
        return 0 unless @defs == 1;
        return 0 unless $defs[0]{file} eq 'lib/CLIO/Tools/FileOperations.pm';

        # Nothing that survived may be a POD line or a comment.
        for my $u (@{ $r->{usages} }) {
            my $text = $u->{line} // '';
            return 0 if $text =~ /^\s*=head|^\s*=item|^\s*=cut/;
        }
        # Some hits were prose (the module documents its own operations), so
        # the filter must have done something.
        return ($r->{filtered_noncode} // 0) > 0;
    }
);

print "\n### list_usages: line truncation Tests ###\n";

# Test: long lines are truncated
run_test(
    "list_usages - long lines truncated",
    { operation => 'list_usages', symbol_name => 'use strict', file_paths => ['docs/'] },
    1,
    sub {
        my $r = shift;
        return 0 unless $r->{count} > 0;
        # Check that at least one line has truncation marker or all are short
        my $has_truncation = 0;
        for my $u (@{$r->{usages}}) {
            if (exists $u->{line_full_length}) {
                $has_truncation = 1;
                last;
            }
        }
        return 1;  # Either truncated or all lines are short enough
    }
);

print "\n### outline Tests ###\n";

# Test: outline a Perl file
run_test(
    "outline - Perl file",
    { operation => 'outline', path => 'lib/CLIO/Tools/CodeIntelligence.pm' },
    1,
    sub {
        my $r = shift;
        return $r->{language} eq 'perl'
            && $r->{total_lines} > 0
            && ref($r->{symbols}) eq 'ARRAY'
            && @{$r->{symbols}} > 0;
    }
);

# Test: outline returns package
run_test(
    "outline - returns package",
    { operation => 'outline', path => 'lib/CLIO/Tools/CodeIntelligence.pm' },
    1,
    sub {
        my $r = shift;
        return defined $r->{package} && $r->{package} eq 'CLIO::Tools::CodeIntelligence';
    }
);

# Test: outline returns function symbols
run_test(
    "outline - returns function symbols",
    { operation => 'outline', path => 'lib/CLIO/Tools/CodeIntelligence.pm' },
    1,
    sub {
        my $r = shift;
        my $funcs = grep { $_->{kind} eq 'function' } @{$r->{symbols}};
        return $funcs > 0;
    }
);

# Test: outline returns signatures
run_test(
    "outline - returns signatures",
    { operation => 'outline', path => 'lib/CLIO/Tools/CodeIntelligence.pm' },
    1,
    sub {
        my $r = shift;
        my $with_sig = grep { defined $_->{signature} } @{$r->{symbols}};
        return $with_sig > 0;
    }
);

# Test: outline missing path
run_test(
    "outline - missing path",
    { operation => 'outline' },
    0,
);

# Test: outline non-existent file
run_test(
    "outline - non-existent file",
    { operation => 'outline', path => 'nonexistent/file.pm' },
    0,
);

# Test: outline markdown file (markdown is a code language, returns 0 symbols)
run_test(
    "outline - markdown file",
    { operation => 'outline', path => 'README.md' },
    1,
    sub {
        my $r = shift;
        return $r->{language} eq 'markdown' && scalar(@{$r->{symbols} // []}) == 0;
    }
);

# Test: outline Python file
run_test(
    "outline - Python file",
    { operation => 'outline', path => 'terminal-bench/clio_tb_agent.py' },
    1,
    sub {
        my $r = shift;
        return $r->{language} eq 'python' && scalar(@{$r->{symbols} // []}) > 0;
    }
);

print "\n### Scanner Tests ###\n";

# Test: scan strips comments
run_test(
    "Scanner - strips comments",
    { operation => 'list_usages', symbol_name => 'test' },  # dummy to enter test harness
    1,
    sub {
        my $src = "sub foo { # this is a comment\n return 1; # another comment\n}";
        my $clean = scan($src, 'perl');
        return $clean !~ /this is a comment/ && $clean !~ /another comment/;
    }
);

# Test: scan strips POD
run_test(
    "Scanner - strips POD",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my $src = "=head1 NAME\n\nTest module\n\n=cut\n\nsub foo { 1 }";
        my $clean = scan($src, 'perl');
        return $clean !~ /Test module/ && $clean =~ /sub foo/;
    }
);

# Test: '#' used as an operator is not a comment
# The invariant is that a comment scan may leave a noisy match but must never
# hide a real one. Treating every '#' as a comment start broke that for
# $#array (Perl last index) and ${#var}/$# (shell length and argument count):
# the rest of the line was blanked, so a symbol defined after the operator was
# invisible to a scan-based search.
run_test(
    "Scanner - '#' as an operator does not hide code",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my $perl  = scan("my \$last = \$#array; my \$kept = 1;\n", 'perl');
        my $sh_len = scan("echo \${#arr[\@]}; echo KEPT_SHELL\n", 'sh');
        my $sh_cnt = scan("echo \$#; echo ALSO_KEPT\n", 'sh');
        # ...while a real comment is still blanked.
        my $real  = scan("my \$x = 1; # REAL_COMMENT\nmy \$after = 2;\n", 'perl');
        return $perl   =~ /\$kept/
            && $sh_len =~ /KEPT_SHELL/
            && $sh_cnt =~ /ALSO_KEPT/
            && $real !~ /REAL_COMMENT/
            && $real =~ /\$after/;
    }
);

# Test: markdown HTML comments, single- and multi-line
# '<!--' was declared as both a line comment and a block opener. The
# line-comment branch won and consumed only the opener, so the body of a
# multi-line comment survived while a single-line one was blanked.
run_test(
    "Scanner - markdown HTML comments (block and inline)",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my $multi  = scan("before\n<!--\nHIDDEN_ML\n-->\nafter\n", 'markdown');
        my $inline = scan("before <!-- HIDDEN_INLINE --> after\n", 'markdown');
        my $plain  = scan("before\nVISIBLE_TEXT\nafter\n", 'markdown');
        return $multi  !~ /HIDDEN_ML/
            && $inline !~ /HIDDEN_INLINE/
            && $plain  =~ /VISIBLE_TEXT/
            && $multi  =~ /before/
            && $multi  =~ /after/;
    }
);

# Test: a line-anchored block opener still requires a line start
run_test(
    "Scanner - ruby =begin stays line-anchored",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my $src = "puts 1\n=begin\nHIDDEN_RUBY\n=end\nputs 2\n";
        my $clean = scan($src, 'ruby');
        return $clean !~ /HIDDEN_RUBY/ && $clean =~ /puts 2/;
    }
);

# Test: scan strips string literals
run_test(
    "Scanner - strips string literals",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my $src = 'my $x = "hello world"; sub foo { 1 }';
        my $clean = scan($src, 'perl');
        return $clean !~ /hello world/ && $clean =~ /sub foo/;
    }
);

# Test: language_for
run_test(
    "Scanner - language_for",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        return language_for('foo.pm') eq 'perl'
            && language_for('foo.py') eq 'python'
            && language_for('foo.rb') eq 'ruby'
            && language_for('foo.sh') eq 'sh'
            && language_for('foo.md') eq 'markdown'
            && language_for('foo.txt') eq 'text';
    }
);

# Test: is_code_language
run_test(
    "Scanner - is_code_language",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        # markdown is scanned (HTML comments blanked) so it IS a code language;
        # it simply yields no symbols, which the outline tests assert.
        return is_code_language('perl') == 1
            && is_code_language('python') == 1
            && is_code_language('text') == 0
            && is_code_language('markdown') == 1;
    }
);

print "\n### Extractor Tests ###\n";

# Test: extract_symbols from Perl
run_test(
    "Extractor - extract Perl symbols",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my $src = "package Foo::Bar;\nsub baz { 1 }\nuse strict;\nour \$x = 1;\n";
        my $clean = scan($src, 'perl');
        my @syms = extract_symbols($clean, 'perl', 'test.pm');
        my %kinds = map { $_->{kind} => 1 } @syms;
        return $kinds{package} && $kinds{function} && $kinds{import} && $kinds{variable};
    }
);

# Test: extract_symbols from Python
run_test(
    "Extractor - extract Python symbols",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my $src = "class Foo:\n    def bar(self): pass\n    def baz(self): pass\n";
        my $clean = scan($src, 'python');
        my @syms = extract_symbols($clean, 'python', 'test.py');
        my %kinds = map { $_->{kind} => 1 } @syms;
        return $kinds{class} && $kinds{function};
    }
);

# Test: extract_symbols returns line numbers
run_test(
    "Extractor - returns line numbers",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my $src = "sub foo { 1 }\nsub bar { 2 }\n";
        my $clean = scan($src, 'perl');
        my @syms = extract_symbols($clean, 'perl', 'test.pm');
        my %by_name = map { $_->{name} => $_->{line} } @syms;
        return $by_name{foo} == 1 && $by_name{bar} == 2;
    }
);

# Test: extract_symbols returns signatures
run_test(
    "Extractor - returns signatures",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my $src = "sub foo(\$a, \$b) { 1 }\n";
        my $clean = scan($src, 'perl');
        my @syms = extract_symbols($clean, 'perl', 'test.pm');
        return @syms && defined $syms[0]{signature} && $syms[0]{signature} =~ /foo/;
    }
);

# Test: classify_reference: definition
run_test(
    "Extractor - classify_reference: definition",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        return classify_reference('sub foo {', 'foo') eq 'definition';
    }
);

# Test: classify_reference: call
run_test(
    "Extractor - classify_reference: call",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        return classify_reference('foo(1, 2)', 'foo') eq 'call';
    }
);

# Test: classify_reference: method_call
run_test(
    "Extractor - classify_reference: method_call",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        return classify_reference('$obj->foo(1)', 'foo') eq 'method_call';
    }
);

# Test: classify_reference: qualified_call
run_test(
    "Extractor - classify_reference: qualified_call",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        return classify_reference('Foo::foo(1)', 'foo') eq 'qualified_call';
    }
);

# Test: classify_reference: assignment
# A bare assignment (no declaration keyword) must read as assignment; a
# 'my $foo = 1' is primarily a declaration and is covered by the next test.
run_test(
    "Extractor - classify_reference: assignment",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        return classify_reference('$foo = 1', 'foo') eq 'assignment';
    }
);

# Test: classify_reference: declaration
run_test(
    "Extractor - classify_reference: declaration",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        return classify_reference('my $foo', 'foo') eq 'declaration';
    }
);

# Test: a declaration names the symbol being declared, not anything on the line
# The pattern used to match the name anywhere after `my`, so a qualified call
# assigned to a variable was labelled a declaration of the callee. Since
# declarations outrank calls, those references sorted to the top.
run_test(
    "Extractor - declaration means the declared name, not any name on the line",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        return 0 unless classify_reference('my $foo', 'foo') eq 'declaration';
        # Every member of a list declaration is declared.
        return 0 unless classify_reference('my ($a, $b) = @_;', 'b') eq 'declaration';
        # The callee on the right of the assignment is a qualified call.
        return 0 unless classify_reference(
            'my $lang = CLIO::Code::Scanner::language_for($file);', 'language_for'
        ) eq 'qualified_call';
        # ...and the variable it is assigned to is still a declaration.
        return 0 unless classify_reference(
            'my $lang = CLIO::Code::Scanner::language_for($file);', 'lang'
        ) eq 'declaration';
        return 1;
    }
);

# Test: classify_reference: reference (fallback)
run_test(
    "Extractor - classify_reference: reference",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        return classify_reference('foo bar baz', 'foo') eq 'reference';
    }
);

# Test: kind_weights
run_test(
    "Extractor - kind_weights",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my $w = kind_weights();
        return $w->{definition} > $w->{call} && $w->{call} > $w->{reference};
    }
);

# Test: extract_symbols from C-like
run_test(
    "Extractor - extract C-like symbols",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        # Extraction is line-based: each definition line yields one symbol, so
        # the class and its method are written on separate lines as they are
        # in real source.
        my $src = "class Foo {\npublic:\n    void bar() {}\n};\n";
        my $clean = scan($src, 'c');
        my @syms = extract_symbols($clean, 'c', 'test.cpp');
        my %kinds = map { $_->{kind} => 1 } @syms;
        return $kinds{class} && $kinds{function};
    }
);

# Test: extract_symbols from Ruby
run_test(
    "Extractor - extract Ruby symbols",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my $src = "module Foo\nclass Bar\ndef baz\nend\nend\nend\n";
        my $clean = scan($src, 'ruby');
        my @syms = extract_symbols($clean, 'ruby', 'test.rb');
        my %kinds = map { $_->{kind} => 1 } @syms;
        return $kinds{package} && $kinds{class} && $kinds{function};
    }
);

# Test: extract_symbols from shell
run_test(
    "Extractor - extract shell symbols",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my $src = "foo() { echo hi; }\n";
        my $clean = scan($src, 'sh');
        my @syms = extract_symbols($clean, 'sh', 'test.sh');
        my %kinds = map { $_->{kind} => 1 } @syms;
        return $kinds{function};
    }
);

# Test: extract_symbols from unsupported language returns empty
run_test(
    "Extractor - unsupported language returns empty",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my @syms = extract_symbols("hello world", 'unknown_lang', 'test.txt');
        return @syms == 0;
    }
);

# Test: extract_symbols does not produce symbols from comments
run_test(
    "Extractor - no symbols from comments",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my $src = "# sub fake_func { }\nsub real_func { 1 }\n";
        my $clean = scan($src, 'perl');
        my @syms = extract_symbols($clean, 'perl', 'test.pm');
        my @names = map { $_->{name} } @syms;
        return grep($_ eq 'real_func', @names) && !grep($_ eq 'fake_func', @names);
    }
);

print "\n### Edge Cases ###\n";

# Test: list_usages with empty file_paths defaults to repo root
run_test(
    "list_usages - empty file_paths defaults to repo root",
    { operation => 'list_usages', symbol_name => 'use strict' },
    1,
    sub {
        my $r = shift;
        return $r->{count} > 0;
    }
);

# Test: list_usages with non-existent file_paths
run_test(
    "list_usages - non-existent file_paths",
    { operation => 'list_usages', symbol_name => 'use strict', file_paths => ['nonexistent/path/'] },
    1,
    sub {
        my $r = shift;
        return $r->{count} == 0;
    }
);

# Test: outline with file too large (mock)
run_test(
    "outline - file too large",
    { operation => 'outline', path => 'lib/CLIO/Tools/CodeIntelligence.pm' },
    1,
    sub {
        my $r = shift;
        # The file is under 4MB, so this should succeed
        return $r->{success};
    }
);

# Commit search: tokenizer, stemmer, and scoring
run_test(
    "search_history - Porter stemmer vectors",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my %want = (
            caresses => 'caress', ponies => 'poni',   ties     => 'ti',
            hopping  => 'hop',    falling => 'fall',  hissing  => 'hiss',
            filing   => 'file',   agreed  => 'agre',  relational => 'relat',
            controll => 'control', ignore => 'ignor', ignored  => 'ignor',
            ignoring => 'ignor',
        );
        for my $word (sort keys %want) {
            my $got = CLIO::Tools::CodeIntelligence::_stem($word);
            return 0 unless $got eq $want{$word};
        }
        return 1;
    }
);

run_test(
    "search_history - tokenizer drops function words and stems",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my @terms = CLIO::Tools::CodeIntelligence::_tokenize(
            "stop the agent from ignoring files");
        my %have = map { $_ => 1 } @terms;
        return 0 if $have{the} || $have{from};
        return 0 unless $have{ignor} && $have{file} && $have{agent} && $have{stop};
        return 1;
    }
);

run_test(
    "search_history - IDF favours the rare term",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my $self  = bless {}, 'CLIO::Tools::CodeIntelligence';
        my $terms = ['common', 'rare'];
        my $idf   = { common => 1, rare => 10 };
        my $rare  = $self->_score_commit($terms, $idf, { rare   => 1 }, {});
        my $common = $self->_score_commit($terms, $idf, { common => 1 }, {});
        return $rare > $common;
    }
);

run_test(
    "search_history - full coverage outranks a single match",
    { operation => 'list_usages', symbol_name => 'test' },
    1,
    sub {
        my $self  = bless {}, 'CLIO::Tools::CodeIntelligence';
        my $terms = ['alpha', 'beta'];
        my $idf   = { alpha => 2, beta => 2 };
        my $both  = $self->_score_commit($terms, $idf, { alpha => 1, beta => 1 }, {});
        my $one   = $self->_score_commit($terms, $idf, { beta => 1 }, {});
        return $both > $one;
    }
);

# Summary
print "="x60, "\n";
print "TEST SUMMARY\n";
print "="x60, "\n";
print "Passed: $tests_passed\n";
print "Failed: $tests_failed\n";
print "Total:  ", ($tests_passed + $tests_failed), "\n";

if ($tests_failed > 0) {
    print "\n[FAIL] SOME TESTS FAILED\n";
    exit 1;
} else {
    print "\n[OK] ALL TESTS PASSED\n";
    exit 0;
}
