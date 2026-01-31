# CLIO UX Style Guide

This document defines the standard patterns for command output in CLIO.

## Command Output Structure

All `/command` outputs should follow this structure:

```
═══════════════════════════════════════════════════════════════
COMMAND NAME
═══════════════════════════════════════════════════════════════

SECTION TITLE
──────────────────────────────────────────────────────────────
  /command <args>           Description here
  /command <args>           Description here

ANOTHER SECTION
──────────────────────────────────────────────────────────────
  Key:                      Value
  Key:                      Value

TIPS
──────────────────────────────────────────────────────────────
  • Tip text here
  • Another tip here
```

## Display Helpers

Use these standardized helpers from `Display.pm`:

### `display_command_header($title)`
- Main header for any `/command` output
- Uses double-line border (`═══`) above and below
- Title in command_header color
- Automatically adds blank lines before/after

### `display_section_header($title)`  
- Section header within command output
- Title in command_subheader color
- Single-line underline (`───`) below
- Use ALL CAPS for section names

### `display_command_row($command, $description, $width)`
- Format: `  /cmd <args>           Description`
- Indented by 2 spaces
- Command in help_command color
- Default width: 25 characters

### `display_key_value($key, $value, $width)`
- Format: `Key:                    Value`
- Key in command_label color with colon
- Value in command_value color
- Default width: 20 characters

### `display_list_item($item, $number)`
- Bulleted: `  • Item text`
- Numbered: `  1. Item text`
- Bullet/number in command_label color

### `display_tip($text)`
- Format: `  • Tip text`
- Entire line in muted color
- Use for hints, notes, suggestions

## Standards

### Headers
- Use `═` (double-line) for main command header only
- Use `─` (single-line) for section underlines
- Header width: 62 characters
- Always use ALL CAPS for section titles

### Commands
- Always start with `/`
- Show arguments in `<angle brackets>`
- Show optional arguments in `[square brackets]`
- Align descriptions consistently (use cmd_width parameter)

### Colors
- `command_header` - Main header text and borders
- `command_subheader` - Section titles
- `help_command` - Command text
- `command_label` - Keys, bullets, numbers
- `command_value` - Values
- `dim` - Underlines, separators
- `muted` - Tips, hints

### Confirmation Prompts
Use the standardized input prompt from Theme.pm:

```perl
print $self->{chat}{theme_mgr}->get_input_prompt("Delete file?", "cancel") . " ";
my $response = <STDIN>;
chomp $response if defined $response;
unless ($response && $response =~ /^y(es)?$/i) {
    # Cancelled
}
```

### Pagination
All list/help displays use the BBS-style pagination:
- First-time hint: `═══[ Tip: ^/v pages · Q quit · any key more ]═══`
- Navigation prompt: `═══[ 1/5 ]═══ ^v Q ▸`
- Up/Down arrows navigate
- Q quits
- Any other key advances

## Examples

### Good
```perl
$self->display_command_header("FILE");

$self->display_section_header("COMMANDS");
$self->display_command_row("/file read <path>", "Read and display file", 25);
$self->display_command_row("/file edit <path>", "Open in editor", 25);
$self->writeline("", markdown => 0);

$self->display_section_header("TIPS");
$self->display_tip("Use /file list to see directory contents");
$self->writeline("", markdown => 0);
```

### Bad
```perl
# DON'T: Inconsistent formatting
$self->writeline("FILE COMMANDS", markdown => 0);
$self->writeline("━━━━━━━━━━━━━━━", markdown => 0);  # Wrong character
print "  /file read - Read a file\n";               # Direct print
$self->display_list_item("/file edit - Edit file");  # Mixing styles
```

## Adding New Commands

1. Add delegate methods for display helpers
2. Use `display_command_header("COMMAND")` for main header
3. Use `display_section_header("SECTION")` for sections  
4. Use `display_command_row()` for command listings
5. Use `display_tip()` for hints
6. Always end sections with `$self->writeline("", markdown => 0);`
7. Test output formatting visually
