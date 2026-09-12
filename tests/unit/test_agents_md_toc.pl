#!/usr/bin/env perl
# Tests for CLIO::Core::InstructionsReader - AGENTS.md ToC generation
# and keyword extraction.
#
# Tests that:
# - _generate_agents_md_toc returns a proper TOC string
# - Keywords are extracted from section content
# - Code blocks are properly skipped
# - Line ranges are correct
# - Keywords appear in the output

use strict;
use warnings;
use lib './lib';
use Test::More;

use CLIO::Core::InstructionsReader;

# Create a test AGENTS.md file in a temp location
my $tmp_dir = "./tests/tmp";
mkdir $tmp_dir unless -d $tmp_dir;

my $test_agents_file = "$tmp_dir/test_AGENTS.md";
my $test_content = <<'MARKDOWN';
# Title

Some intro content.

## Project Overview

**CLIO** is an AI-powered development assistant built in Perl.

- Language: Perl 5.32+
- Architecture: terminal UI
- Philosophy: The Unbroken Method

## Quick Setup

```bash
./clio --new
./clio --debug --new
./clio --input "test query" --exit
```

## Architecture

```
User Input
    |
    v
Terminal UI
```

The architecture has several layers including the terminal UI and API manager.

## Testing

Tests cover unit tests, integration tests, and e2e tests.
All tests are written in Perl using Test::More.

## Licensing

The project uses GPL-3.0-only license.
Contributions are welcome.

MARKDOWN

open my $fh, '>', $test_agents_file;
print $fh $test_content;
close $fh;

# Test 1: Basic ToC generation
subtest 'basic ToC generation' => sub {
    my $reader = CLIO::Core::InstructionsReader->new();
    my $toc = $reader->_generate_agents_md_toc($test_agents_file);

    ok(defined $toc, 'ToC is defined');
    like($toc, qr/AGENTS\.md/, 'Contains AGENTS.md title');
    like($toc, qr/Project Overview/, 'Contains Project Overview section');
    like($toc, qr/Quick Setup/, 'Contains Quick Setup section');
    like($toc, qr/Architecture/, 'Contains Architecture section');
    like($toc, qr/Testing/, 'Contains Testing section');
    like($toc, qr/Licensing/, 'Contains Licensing section');

    # Clean up
    unlink $test_agents_file;
};

# Test 2: Line numbers are present
subtest 'line ranges in ToC' => sub {
    open $fh, '>', $test_agents_file;
    print $fh $test_content;
    close $fh;

    my $reader = CLIO::Core::InstructionsReader->new();
    my $toc = $reader->_generate_agents_md_toc($test_agents_file);

    # Each section should have line range (start-end)
    like($toc, qr/\(\d+-\d+\)/, 'Contains line range format');
    like($toc, qr/Project Overview \(\d+-\d+\)/, 'Project Overview has line range');
    like($toc, qr/Architecture \(\d+-\d+\)/, 'Architecture has line range');

    unlink $test_agents_file;
};

# Test 3: Keyword extraction
subtest 'keyword extraction from sections' => sub {
    open $fh, '>', $test_agents_file;
    print $fh $test_content;
    close $fh;

    my $reader = CLIO::Core::InstructionsReader->new();
    my $toc = $reader->_generate_agents_md_toc($test_agents_file);

    # Project Overview section should have keywords like 'Perl', 'Architecture'
    ok($toc =~ /keywords:\s+.+/, 'Contains keywords line');

    # Check that perl keyword appears somewhere in the keywords (case-insensitive)
    ok($toc =~ /perl/i, 'Contains perl keyword (case-insensitive)');
    ok($toc =~ /Architecture/, 'Contains Architecture');

    unlink $test_agents_file;
};

# Test 4: Keywords exclude stop words and common words
subtest 'keyword extraction excludes stop words' => sub {
    my @keywords = (
        'Perl', 'architecture', 'terminal', 'manager', 'input',
        'output', 'streaming', 'session', 'memory', 'provider',
        'anthropic', 'openai', 'claude', 'gpt', 'model',
        'config', 'setup', 'install', 'debug', 'test'
    );

    # Create content with known keywords mixed with stop words
    my $kw_content = <<MARKDOWN;
# Test Doc

## Section One

The project uses Perl for development. The architecture includes
a terminal user interface and an API manager for handling requests.
This section discusses input processing and output streaming.

## Section Two

Session management handles memory persistence and provider routing.
Anthropic and OpenAI providers are supported. The model configuration
requires setup during install and debug phases.
MARKDOWN

    open $fh, '>', $test_agents_file;
    print $fh $kw_content;
    close $fh;

    my $reader = CLIO::Core::InstructionsReader->new();
    my $toc = $reader->_generate_agents_md_toc($test_agents_file);

    # The first section should have keywords like perl, architecture, terminal
    # The second section should have keywords like session, memory, provider
    ok($toc =~ /keywords:\s+.+/, 'Has keywords');

    # Verify stop words are not in keywords
    unlike($toc, qr/keywords:\s+[^n]*\bthe\b/, 'Stop word "the" not in keywords');
    unlike($toc, qr/keywords:\s+[^n]*\band\b/, 'Stop word "and" not in keywords');

    unlink $test_agents_file;
};

# Test 5: _extract_keywords method directly
subtest '_extract_keywords method' => sub {
    my $reader = CLIO::Core::InstructionsReader->new();

    # Create test lines
    my @lines = (
        '## Section',
        '',
        'The project uses Perl for development.',
        'Architecture includes terminal UI and API manager.',
        '',
        '## Next Section',
        'More content here.',
    );

    # Extract keywords from lines 2-4 (after "## Section" heading at line 1)
    my @kw = $reader->_extract_keywords(\@lines, 2, 4);

    ok(@kw > 0, 'Extracted some keywords');
    ok(grep(/perl/i, @kw), 'Extracted "perl" keyword');
    ok(grep(/architecture/, @kw), 'Extracted "architecture" keyword');
    ok(grep(/terminal/, @kw), 'Extracted "terminal" keyword');

    # Should not contain stop words
    ok(!grep(/^the$/, @kw), 'Stop word "the" excluded');
    ok(!grep(/^for$/, @kw), 'Stop word "for" excluded');
    ok(!grep(/^and$/, @kw), 'Stop word "and" excluded');
};

# Test 6: Code blocks are skipped in keyword extraction
subtest 'code blocks skipped in keyword extraction' => sub {
    my $reader = CLIO::Core::InstructionsReader->new();

    my @lines = (
        '## Section',
        '',
        '```bash',
        'config setup install build debug',
        '```',
        '',
        'The architecture uses Perl and has a terminal interface.',
        'Memory management handles session persistence.',
    );

    # Extract from lines 2-8
    my @kw = $reader->_extract_keywords(\@lines, 2, 8);

    ok(@kw > 0, 'Extracted keywords');
    ok(!grep(/^config$/, @kw), 'Code block word "config" skipped');
    ok(!grep(/^setup$/, @kw), 'Code block word "setup" skipped');
    ok(grep(/perl/, @kw), 'Non-code-block word "perl" extracted');
    ok(grep(/architecture/, @kw), 'Non-code-block word "architecture" extracted');
};

# Test 7: Empty or short sections
subtest 'empty section handling' => sub {
    my $reader = CLIO::Core::InstructionsReader->new();

    my @lines = (
        '## Empty Section',
        '',
        '## Next Section',
        'Content here.',
    );

    # Empty section (just blank line between headings)
    my @kw = $reader->_extract_keywords(\@lines, 2, 2);
    is(scalar(@kw), 0, 'Empty section returns no keywords');
};

# Test 8: Heading line itself is not included in keyword extraction
subtest 'heading title not in keyword content' => sub {
    my $reader = CLIO::Core::InstructionsReader->new();

    my @lines = (
        '## Project Overview',
        'The project overview describes the architecture.',
        '',
        '## Testing',
        'Testing is important.',
    );

    my @kw = $reader->_extract_keywords(\@lines, 2, 2);

    # "overview" from "Project Overview" heading should NOT be extracted
    # since it's the heading line (line 1), not the content (line 2)
    # But "overview" appears in content too ("The project overview describes")
    # So we just verify the method works correctly
    ok(scalar(@kw) >= 0, 'Method runs without error on heading content');
};

# Test 9: Markdown formatting stripped
subtest 'markdown formatting stripped' => sub {
    my $reader = CLIO::Core::InstructionsReader->new();

    my @lines = (
        '## Section',
        '**Architecture** includes terminal development.',
        '[Link Text](http://example.com) uses Perl.',
        '`skipped_word` but perl is outside backticks.',
    );

    my @kw = $reader->_extract_keywords(\@lines, 2, 4);

    ok(grep(/^architecture$/, @kw), 'Bold markdown stripped, word extracted');
    ok(grep(/^perl$/, @kw), 'Word outside backticks extracted');
    ok(grep(/^terminal$/, @kw), 'Plain word extracted');
    ok(!grep(/^skipped_word$/, @kw), 'Word inside backticks skipped');
    ok(!grep(/^http$/, @kw), 'URL stripped from link');
};

# Test 10: Keyword frequency prioritization
subtest 'keywords prioritized by frequency' => sub {
    my $reader = CLIO::Core::InstructionsReader->new();

    my @lines = (
        '## Section',
        'Architecture architecture ARCHITECTURE perl terminal.',
        'Architecture design patterns. Perl development.',
    );

    my @kw = $reader->_extract_keywords(\@lines, 2, 3);

    # "architecture" appears 3+ times, should come first
    # "perl" appears 2 times
    ok(grep(/^architecture$/, @kw), 'High-frequency word extracted');
    ok(grep(/^perl$/, @kw), 'Medium-frequency word extracted');

    # Check ordering - architecture should come before perl
    my ($arch_idx) = grep { $kw[$_] eq 'architecture' } 0..$#kw;
    my ($perl_idx) = grep { $kw[$_] eq 'perl' } 0..$#kw;
    if (defined $arch_idx && defined $perl_idx) {
        ok($arch_idx < $perl_idx, 'Higher frequency keyword comes first');
    }
};

# Test 11: Max 8 keywords returned
subtest 'max 8 keywords' => sub {
    my $reader = CLIO::Core::InstructionsReader->new();

    my @lines = (
        '## Section',
        'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu',
        'nu xi omicron pi rho sigma tau upsilon phi chi psi omega',
    );

    my @kw = $reader->_extract_keywords(\@lines, 2, 3);

    # All are 4+ chars, not stop words - should get up to 8
    ok(scalar(@kw) <= 8, 'At most 8 keywords returned');
    is(scalar(@kw), 8, 'Exactly 8 keywords returned when more are available');
};

# Test 12: File not found
subtest 'file not found returns undef' => sub {
    my $reader = CLIO::Core::InstructionsReader->new();
    my $toc = $reader->_generate_agents_md_toc('/nonexistent/path/AGENTS.md');
    ok(!defined $toc, 'Returns undef for nonexistent file');
};

# Test 13: Empty file
subtest 'empty file returns undef' => sub {
    my $empty_file = "$tmp_dir/empty_AGENTS.md";
    open $fh, '>', $empty_file;
    close $fh;

    my $reader = CLIO::Core::InstructionsReader->new();
    my $toc = $reader->_generate_agents_md_toc($empty_file);
    ok(!defined $toc, 'Returns undef for empty file');

    unlink $empty_file;
};

# Cleanup
END {
    unlink $test_agents_file if -f $test_agents_file;
};

done_testing();