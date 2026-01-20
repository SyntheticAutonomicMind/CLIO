#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use CLIO::UI::Markdown;

my $md = CLIO::UI::Markdown->new();

my $test_text = <<'EOF';
# This is a Header

This is **bold text** and *italic text* and `inline code`.

## Subheader

Here's a link: [CLIO GitHub](https://github.com/fewtarius/clio)

### Lists

- First item
- Second item with **bold**
- Third item with `code`

1. Numbered first
2. Numbered second

> This is a blockquote with *emphasis*

```perl
sub example {
    my ($self) = @_;
    return "Hello, World!";
}
```

Regular text with **bold**, *italic*, and `code` mixed together.
EOF

print "\n=== RENDERED MARKDOWN ===\n\n";
print $md->render($test_text);
print "\n\n=== STRIPPED (PLAIN TEXT) ===\n\n";
print $md->strip_markdown($test_text);
print "\n";
