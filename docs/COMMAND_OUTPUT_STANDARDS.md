# CLIO Command Output Styling Standards

**Audience:** Developers adding or modifying slash commands

## Purpose

This document defines the standard patterns for formatting slash command output in CLIO. Following these standards ensures a consistent, professional user experience across all commands and themes.

---

## Architecture

### Command Base Class

All slash commands extend `CLIO::UI::Commands::Base`, which delegates display methods to `CLIO::UI::Chat`:

```perl
package CLIO::UI::Commands::MyCommand;
use parent 'CLIO::UI::Commands::Base';

sub handle {
    my ($self, @args) = @_;
    $self->display_command_header("MY COMMAND");
    $self->display_key_value("Key", "value");
    $self->display_success_message("Done");
}
```

All display helpers are available on `$self` via delegation - no need to access `$chat` directly.

### Command Registration

Commands are registered in the command registry (`CLIO::UI::Commands`) and dispatched by name. Larger command families (like `/api`) are split into submodules:

```
lib/CLIO/UI/Commands/
├── Base.pm           # Base class with display helpers
├── API.pm            # /api dispatcher
├── API/
│   ├── Auth.pm       # /api login, logout, key
│   ├── Config.pm     # /api provider, set, show
│   └── Models.pm     # /api models, list
├── Config.pm         # /config
├── Session.pm        # /session
├── Stats.pm          # /stats
└── ...
```

---

## Theme System

CLIO uses a layered theming system:

```
Style (colors) + Theme (templates) = Rendered Output
```

**Style** defines color tokens (e.g., `command_header => '@BOLD@@BRIGHT_CYAN@'`)
**Theme** defines output templates using those tokens

Commands should use theme tokens via the `colorize()` method, never hardcode colors.

---

## Available Theme Tokens

### Status Messages

| Token | Purpose | Default Color |
|-------|---------|---------------|
| `success_message` | Success indicators | `@BRIGHT_GREEN@` |
| `warning_message` | Warnings | `@BRIGHT_YELLOW@` |
| `info_message` | Informational | `@BRIGHT_CYAN@` |
| `error_message` | Errors | `@BRIGHT_RED@` |
| `system_message` | System notifications | `@BRIGHT_MAGENTA@` |

### Command Output

| Token | Purpose | Default Color |
|-------|---------|---------------|
| `command_header` | Major section headers | `@BOLD@@BRIGHT_CYAN@` |
| `command_subheader` | Minor section headers | `@BOLD@@CYAN@` |
| `command_label` | Labels/keys | `@CYAN@` |
| `command_value` | Values | `@BRIGHT_WHITE@` |
| `help_command` | Command names in help | Theme-dependent |

### General Purpose

| Token | Purpose | Default Color |
|-------|---------|---------------|
| `data` | Generic data display | `@BRIGHT_WHITE@` |
| `dim` | Muted/secondary text | `@DIM@` |
| `highlight` | Emphasized text | `@BRIGHT_YELLOW@` |
| `muted` | De-emphasized text | `@DIM@@WHITE@` |

---

## Display Helper Methods

All of these are available on `$self` in any Commands::Base subclass:

### Headers

```perl
# Major section header (double-line border)
$self->display_command_header("SESSION INFORMATION");
# Output:
# ══════════════════════════════════════════════════════════════════════
# SESSION INFORMATION
# ══════════════════════════════════════════════════════════════════════

# Subsection header (single-line border)
$self->display_section_header("Current Settings");
# Output:
# Current Settings
# ──────────────────────────────────────────────────────────────────────
```

### Key-Value Pairs

```perl
$self->display_key_value("Session ID", $id, 20);
$self->display_key_value("Model", $model, 20);
# Output:
# Session ID:          abc123-def456
# Model:               claude-sonnet-4
```

### Status Messages

```perl
$self->display_success_message("Configuration saved");
# Output: [OK] Configuration saved

$self->display_warning_message("Rate limit approaching");
# Output: [WARN] Rate limit approaching

$self->display_info_message("Using cached model list");
# Output: [INFO] Using cached model list

$self->display_error_message("Invalid session ID");
# Output: ERROR: Invalid session ID
```

### Lists

```perl
# Bulleted list
$self->display_list_item("First item");
$self->display_list_item("Second item");
# Output:
#   • First item
#   • Second item

# Numbered list
$self->display_list_item("First step", 1);
$self->display_list_item("Second step", 2);
# Output:
#   1. First step
#   2. Second step
```

### Command Rows (for help output)

```perl
$self->display_command_row("/models", "List available models");
$self->display_command_row("/config show", "Display configuration");
# Output:
#   /models                   List available models
#   /config show              Display configuration
```

### Tips

```perl
$self->display_tip("Use /debug on for verbose output");
# Output:
#   • Use /debug on for verbose output  (muted color)
```

### Tables

```perl
my $table = <<'TABLE';
| Column 1 | Column 2 |
|----------|----------|
| Value A  | Value B  |
TABLE
print $self->render_markdown($table);
```

### Paginated Output

```perl
# For long lists
$self->display_paginated_list(\@items, "AVAILABLE MODELS");

# For long text content
$self->display_paginated_content($text, "FILE CONTENTS");
```

### Confirmation Prompts

For interactive prompts that require user input:

```perl
my ($header, $input_line) = @{$self->{chat}{theme_mgr}->get_confirmation_prompt(
    "Confirm action",
    "proceed"
)};
print $header;
my $answer = <STDIN>;
```

---

## Command Output Guidelines

### 1. Always Use Headers for Multi-Section Output

```perl
# Good
$self->display_command_header("SESSION INFORMATION");
$self->display_key_value("Session ID", $id);

# Bad
print "Session ID: $id\n";
```

### 2. Use Status Messages for Feedback

```perl
# Good
$self->display_success_message("Session created");

# Bad
print "Session created successfully\n";
```

### 3. Use Colorize, Never Hardcode ANSI

```perl
# Good
my $colored = $self->colorize("Error", 'error_message');

# Bad
my $colored = "\e[91mError\e[0m";
```

### 4. Respect Terminal Width

Default to 70 characters for headers/separators (80-column safe with margin).

### 5. Add Breathing Room

Include blank lines:
- Before and after major headers
- Between sections
- After final output

### 6. Be Consistent Within a Command

All sections of a single command should use the same header style, separator characters, and indentation.

---

## Example: Complete Command Implementation

```perl
package CLIO::UI::Commands::MyFeature;
use parent 'CLIO::UI::Commands::Base';

sub handle {
    my ($self, @args) = @_;
    
    $self->display_command_header("MY FEATURE");
    
    $self->display_section_header("Settings");
    $self->display_key_value("Option A", $self->{config}->get('option_a'), 20);
    $self->display_key_value("Option B", $self->{config}->get('option_b'), 20);
    print "\n";
    
    $self->display_section_header("Available Items");
    my @items = $self->_get_items();
    if (@items) {
        for my $i (0..$#items) {
            $self->display_list_item($items[$i], $i + 1);
        }
    } else {
        $self->display_info_message("No items found");
    }
    
    $self->display_tip("Use /myfeature add <name> to create a new item");
}

1;
```

---

## Implementation Checklist

For new slash commands:

- [ ] Extends `CLIO::UI::Commands::Base`
- [ ] Uses `display_*` helpers for all output
- [ ] Uses `colorize()` with theme tokens, never hardcoded ANSI
- [ ] Uses `display_command_header` for top-level output
- [ ] Uses `display_section_header` for subsections
- [ ] Includes `use strict; use warnings; use utf8;`
- [ ] Has `binmode(STDOUT, ':encoding(UTF-8)')` and `binmode(STDERR, ':encoding(UTF-8)')`
- [ ] Has POD documentation
- [ ] Registered in the command registry
