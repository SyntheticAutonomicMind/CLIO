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

# Create a LARGE markdown document (simulate AI response with lots of code examples)
my $large_markdown = '';

for my $i (1..20) {
    $large_markdown .= <<SECTION;
## Section $i: Complex Code Example

This section contains **bold text**, *italic text*, and `inline code` examples.

Here's a detailed explanation with multiple paragraphs. We need to test how the
markdown renderer handles longer documents with many elements.

### Subsection $i.1: Code Block

```perl
package Example::Module::Section$i;

use strict;
use warnings;

sub new {
    my (\$class, %opts) = \@_;
    my \$self = {
        debug => \$opts{debug} || 0,
        name => \$opts{name} || 'default',
        items => [],
    };
    return bless \$self, \$class;
}

sub process {
    my (\$self, \$data) = \@_;
    
    # Process each item
    for my \$item (\@{\$data->{items}}) {
        push \@{\$self->{items}}, {
            id => \$item->{id},
            value => \$item->{value} * 2,
            timestamp => time(),
        };
    }
    
    return \$self->{items};
}

1;
```

### Subsection $i.2: Feature List

Here are the key features:

- **Feature 1**: High performance processing with [documentation](https://example.com/docs)
- **Feature 2**: Comprehensive error handling
- **Feature 3**: `Configurable` options for all scenarios
- **Feature 4**: Integration with *multiple* systems
- **Feature 5**: Detailed logging and debugging support

### Subsection $i.3: Configuration Table

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| debug | boolean | false | Enable debug output |
| timeout | integer | 30 | Request timeout in seconds |
| retries | integer | 3 | Number of retry attempts |
| verbose | boolean | true | Show verbose logging |

> **Note**: This is an important blockquote with **bold** and *italic* text
> that spans multiple lines and contains `code references`.

SECTION
}

# Print document stats
my $lines = ($large_markdown =~ tr/\n//);
my $chars = length($large_markdown);
print "\n";
print "Document stats:\n";
print "  Lines: $lines\n";
print "  Characters: $chars\n";
print "  Size: " . sprintf("%.1f", $chars/1024) . " KB\n";
print "\n";

# Warm-up
$md->render($large_markdown);

# Benchmark
print "Running benchmark (10 iterations)...\n";
my $iterations = 10;
my $start_time = time();

for (1 .. $iterations) {
    my $rendered = $md->render($large_markdown);
    my $parsed = $ansi->parse($rendered);
}

my $end_time = time();
my $total_time = $end_time - $start_time;
my $avg_time = $total_time / $iterations;
my $avg_ms = $avg_time * 1000;

print "\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
print "LARGE DOCUMENT PERFORMANCE TEST\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
print "\n";
print "Results:\n";
print "  - Iterations: $iterations\n";
print "  - Total time: " . sprintf("%.3f", $total_time) . "s\n";
print "  - Average per render: " . sprintf("%.2f", $avg_ms) . "ms\n";
print "  - Throughput: " . sprintf("%.1f", ($chars * $iterations) / $total_time / 1024) . " KB/s\n";
print "\n";

if ($avg_ms < 10) {
    print "✓ EXCELLENT - Rendering is <10ms per call\n";
} elsif ($avg_ms < 50) {
    print "✓ GOOD - Rendering is <50ms per call\n";
} elsif ($avg_ms < 100) {
    print "⚠ OK - Rendering is <100ms but could be optimized\n";
} else {
    print "✗ SLOW - Rendering takes >100ms and needs optimization\n";
}

print "\n";
