#!/usr/bin/env perl

use strict;
use warnings;
use lib 'lib';
use Time::HiRes qw(time);

use CLIO::UI::Markdown;
use CLIO::UI::Theme;
use CLIO::UI::ANSI;

# Create theme manager and markdown renderer
my $ansi = CLIO::UI::ANSI->new();
my $theme_mgr = CLIO::UI::Theme->new(
    ansi => $ansi,
    style => 'default',
    theme => 'default'
);

my $md = CLIO::UI::Markdown->new(theme_mgr => $theme_mgr);

# Test markdown content with various elements
my $test_markdown = <<'MARKDOWN';
# Header 1 Level

This is a paragraph with **bold text** and *italic text* and `inline code`.

## Header 2 Level

Here's a list:
- Item 1 with **bold**
- Item 2 with *italic*
- Item 3 with `code`

### Code Block

```perl
sub example {
    my ($self, $arg) = @_;
    return $arg * 2;
}
```

### Table Example

| Column 1 | Column 2 | Column 3 |
|----------|----------|----------|
| Data 1   | Data 2   | Data 3   |
| Data 4   | Data 5   | Data 6   |

> This is a blockquote with **bold** and *italic* text.

More text with [links](https://example.com) and ![images](image.png).

1. Ordered item 1
2. Ordered item 2
3. Ordered item 3

**Bold** and __also bold__ and *italic* and _also italic_.
MARKDOWN

# Warm-up run
$md->render($test_markdown);

# Benchmark: Run 100 times
my $iterations = 100;
my $start_time = time();

for (1 .. $iterations) {
    my $rendered = $md->render($test_markdown);
    my $parsed = $ansi->parse($rendered);
}

my $end_time = time();
my $total_time = $end_time - $start_time;
my $avg_time = $total_time / $iterations;
my $avg_ms = $avg_time * 1000;

print "\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
print "MARKDOWN RENDERING PERFORMANCE TEST\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
print "\n";
print "Test content:\n";
print "  - Lines: " . (scalar split /\n/, $test_markdown) . "\n";
print "  - Characters: " . length($test_markdown) . "\n";
print "  - Elements: headers, lists, code blocks, tables, links\n";
print "\n";
print "Results:\n";
print "  - Iterations: $iterations\n";
print "  - Total time: " . sprintf("%.3f", $total_time) . "s\n";
print "  - Average per render: " . sprintf("%.2f", $avg_ms) . "ms\n";
print "\n";

if ($avg_ms < 1) {
    print "✓ EXCELLENT - Rendering is <1ms per call\n";
} elsif ($avg_ms < 10) {
    print "✓ GOOD - Rendering is <10ms per call\n";
} elsif ($avg_ms < 50) {
    print "⚠ OK - Rendering is <50ms but could be optimized\n";
} else {
    print "✗ SLOW - Rendering takes >50ms and needs optimization\n";
}

print "\n";
