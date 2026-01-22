# CLIO Command Output Styling Standards

**Version:** 1.0  
**Last Updated:** 2025-01-22  
**Audience:** Developers adding or modifying slash commands

## Purpose

This document defines the standard patterns for formatting slash command output in CLIO. Following these standards ensures a consistent, professional user experience across all commands and themes.

---

## Theme System Overview

CLIO uses a layered theming system:

```
Style (colors) + Theme (templates) = Rendered Output
```

**Style** defines color tokens (e.g., `command_header => '@BOLD@@BRIGHT_CYAN@'`)  
**Theme** defines output templates using those tokens (e.g., `{style.command_header}HEADER TEXT@RESET@`)

Commands should use theme tokens via the `colorize()` method, never hardcode colors.

---

## Available Theme Tokens

### Status Messages
| Token | Purpose | Default Color |
|-------|---------|---------------|
| `success_message` | Success indicators | `@BRIGHT_GREEN@` |
| `warning_message` | Warnings | `@BRIGHT_YELLOW@` |
| `info_message` | Informational messages | `@BRIGHT_CYAN@` |
| `error_message` | Errors | `@BRIGHT_RED@` |
| `system_message` | System notifications | `@BRIGHT_MAGENTA@` |

### Command Output Elements
| Token | Purpose | Default Color |
|-------|---------|---------------|
| `command_header` | Major section headers | `@BOLD@@BRIGHT_CYAN@` |
| `command_subheader` | Minor section headers | `@BOLD@@CYAN@` |
| `command_label` | Labels/keys in key-value pairs | `@CYAN@` |
| `command_value` | Values in key-value pairs | `@BRIGHT_WHITE@` |

### General Purpose
| Token | Purpose | Default Color |
|-------|---------|---------------|
| `data` | Generic data display | `@BRIGHT_WHITE@` |
| `dim` | Muted/secondary text | `@DIM@` |
| `highlight` | Emphasized text | `@BRIGHT_YELLOW@` |
| `muted` | De-emphasized text | `@DIM@@WHITE@` |

---

## Standard Output Patterns

### Pattern A: Command Header (Major Section)

Use for top-level command output headers.

```perl
print "\n";
print $self->colorize("═" x 70, 'command_header'), "\n";
print $self->colorize("COMMAND OUTPUT TITLE", 'command_header'), "\n";
print $self->colorize("═" x 70, 'command_header'), "\n";
print "\n";
```

**Example Output:**
```
══════════════════════════════════════════════════════════════════════
SESSION INFORMATION
══════════════════════════════════════════════════════════════════════

[content follows]
```

**Helper Method:**
```perl
$self->display_command_header("SESSION INFORMATION", 70);
```

---

### Pattern B: Section Header (Minor/Subsection)

Use for subsections within command output.

```perl
print $self->colorize("SUBSECTION NAME", 'command_subheader'), "\n";
print $self->colorize("─" x 70, 'dim'), "\n";
```

**Example Output:**
```
Current Settings
──────────────────────────────────────────────────────────────────────
[settings list follows]
```

**Helper Method:**
```perl
$self->display_section_header("Current Settings", 70);
```

---

### Pattern C: Key-Value Pairs

Use for displaying settings, properties, or structured data.

```perl
printf "%-20s %s\n",
    $self->colorize("Session ID:", 'command_label'),
    $self->colorize($session_id, 'command_value');
```

**Example Output:**
```
Session ID:          abc123-def456-789ghi
Model:               claude-3.7-sonnet
Provider:            anthropic
```

**Helper Method:**
```perl
$self->display_key_value("Session ID", $session_id, 20);
$self->display_key_value("Model", $model, 20);
$self->display_key_value("Provider", $provider, 20);
```

---

### Pattern D: Status Messages

Use for feedback to user actions.

#### Success
```perl
$self->display_success_message("Configuration saved successfully");
```
**Output:** `[OK] Configuration saved successfully`

#### Warning
```perl
$self->display_warning_message("API rate limit approaching (80% used)");
```
**Output:** `[WARN] API rate limit approaching (80% used)`

#### Info
```perl
$self->display_info_message("Using cached model list (5 minutes old)");
```
**Output:** `[INFO] Using cached model list (5 minutes old)`

#### Error
```perl
$self->display_error_message("Invalid session ID: $session_id");
```
**Output:** `ERROR: Invalid session ID: abc123`

---

### Pattern E: Lists

Use for displaying multiple items.

#### Bulleted List
```perl
$self->display_list_item("First item");
$self->display_list_item("Second item");
$self->display_list_item("Third item");
```

**Output:**
```
  • First item
  • Second item
  • Third item
```

#### Numbered List
```perl
$self->display_list_item("First step", 1);
$self->display_list_item("Second step", 2);
$self->display_list_item("Third step", 3);
```

**Output:**
```
  1. First step
  2. Second step
  3. Third step
```

---

### Pattern F: Tables

For tabular data, use the markdown table renderer (which applies theme colors automatically):

```perl
my $table_markdown = <<"END_TABLE";
| Column 1 | Column 2 | Column 3 |
|----------|----------|----------|
| Value A  | Value B  | Value C  |
| Value D  | Value E  | Value F  |
END_TABLE

print $self->render_markdown($table_markdown);
```

---

## Helper Methods Reference

### Display Helpers

```perl
# Headers
$self->display_command_header($text, $width);
$self->display_section_header($text, $width);

# Key-value pairs
$self->display_key_value($key, $value, $key_width);

# Status messages
$self->display_success_message($message);
$self->display_warning_message($message);
$self->display_info_message($message);
$self->display_error_message($message);      # Already exists
$self->display_system_message($message);     # Already exists

# Lists
$self->display_list_item($item);             # Bulleted
$self->display_list_item($item, $number);    # Numbered
```

### Colorization

```perl
# Use theme tokens
my $colored = $self->colorize($text, 'TOKEN_NAME');

# Never hardcode ANSI
my $bad = "@BRIGHT_RED@Error@RESET@";        # WRONG
my $good = $self->colorize("Error", 'error_message');  # RIGHT
```

---

## Command Output Guidelines

### 1. Always Include Headers for Multi-Section Output

**Good:**
```perl
$self->display_command_header("SESSION INFORMATION");
$self->display_key_value("Session ID", $id);
$self->display_key_value("Created", $created);
```

**Bad:**
```perl
print "Session ID: $id\n";
print "Created: $created\n";
```

### 2. Use Status Messages for Feedback

**Good:**
```perl
if ($success) {
    $self->display_success_message("Session created successfully");
} else {
    $self->display_error_message("Failed to create session: $error");
}
```

**Bad:**
```perl
print "Session created successfully\n";
print "Error: Failed to create session: $error\n";
```

### 3. Be Consistent Within a Command

All sections of a single command should use the same header style, separator characters, and indentation.

### 4. Respect Terminal Width

Default to 70 characters for headers/separators to ensure compatibility with 80-column terminals (leaving margin).

### 5. Add Breathing Room

Always include blank lines:
- Before and after major headers
- Between sections
- After final output

---

## Examples

### Example 1: /session show

```perl
sub _display_session_info {
    my ($self) = @_;
    
    $self->display_command_header("SESSION INFORMATION");
    
    $self->display_section_header("Current Session");
    $self->display_key_value("Session ID", $self->{session}{session_id});
    $self->display_key_value("Created", format_timestamp($self->{session}{created_at}));
    $self->display_key_value("Model", $self->{session}->state()->{model});
    print "\n";
    
    $self->display_section_header("Activity");
    $self->display_key_value("Messages", scalar(@{$self->{session}->state()->{history}}));
    $self->display_key_value("Last Active", format_timestamp(time()));
    print "\n";
}
```

### Example 2: /api models

```perl
sub handle_models_command {
    my ($self) = @_;
    
    $self->display_command_header("AVAILABLE MODELS");
    
    my @models = $api->get_models();
    
    if (@models) {
        $self->display_info_message("Found " . scalar(@models) . " models");
        print "\n";
        
        my $num = 1;
        for my $model (@models) {
            $self->display_list_item($model->{name}, $num);
            print "    " . $self->colorize($model->{description}, 'dim') . "\n";
            $num++;
        }
    } else {
        $self->display_warning_message("No models available");
    }
    
    print "\n";
}
```

---

## Testing Your Command Output

Before committing changes:

1. **Test with default theme** - Ensure output looks good with built-in colors
2. **Test with different terminal widths** - Verify headers/tables don't break
3. **Test with color disabled** - Run with `--no-color` to ensure text is still readable
4. **Test with different styles** - Use `/style list` and test with alternatives

---

## Extending the Theme System

If you need a new color token:

1. Add to `lib/CLIO/UI/Theme.pm` in `get_builtin_style()`:
   ```perl
   new_token_name => '@BRIGHT_BLUE@',
   ```

2. Document it in this standards guide

3. Use it via `$self->colorize($text, 'new_token_name')`

Never hardcode ANSI escape sequences in command output code.

---

## Questions?

- **Where are helper methods defined?** `lib/CLIO/UI/Chat.pm`
- **Where are theme tokens defined?** `lib/CLIO/UI/Theme.pm`
- **How do I test themes?** Use `/style` and `/theme` commands
- **Can I add custom @-codes?** Only use defined theme tokens via `colorize()`

---

**Document Version History:**
- 1.0 (2025-01-22): Initial standards document
