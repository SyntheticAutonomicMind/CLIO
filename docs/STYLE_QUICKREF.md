# CLIO Style System - Quick Reference

## Using Styles

```bash
./clio --style nord               # Use a style
/config style monokai             # Set as default
./clio --list-styles              # Show all styles
```

## Creating a Style - Minimal Template

```
# Required metadata
name=my-theme

# Core Hierarchy (5 levels)
primary=@BOLD@@BRIGHT_CYAN@       # Titles, headers
secondary=@BRIGHT_CYAN@           # Important elements
normal=@WHITE@                    # Body text
muted=@DIM@@WHITE@               # Labels, hints
subtle=@DIM@                     # Borders

# Conversational
user_prompt=@BRIGHT_GREEN@
user_text=@WHITE@
agent_label=@BRIGHT_CYAN@
agent_text=@WHITE@
system_message=@CYAN@

# Feedback
error=@BRIGHT_RED@
warning=@BRIGHT_YELLOW@
success=@BRIGHT_GREEN@
info=@CYAN@

# Data Display
label=@DIM@@WHITE@               # "Session ID:"
value=@BRIGHT_WHITE@             # abc123-def456

# Actionable
command=@BRIGHT_GREEN@           # /help, /exit
link=@BRIGHT_CYAN@@UNDERLINE@

# Prompt
prompt_model=@CYAN@
prompt_directory=@BRIGHT_CYAN@
prompt_git_branch=@DIM@@CYAN@
prompt_indicator=@BRIGHT_GREEN@

# Markdown
markdown_h1=@BOLD@@BRIGHT_CYAN@
markdown_h2=@BRIGHT_CYAN@
markdown_h3=@WHITE@
markdown_bold=@BOLD@
markdown_italic=@DIM@
markdown_code=@CYAN@
markdown_code_block=@CYAN@
markdown_link=@BRIGHT_CYAN@@UNDERLINE@
markdown_quote=@DIM@@CYAN@
markdown_list_bullet=@BRIGHT_GREEN@

# Tables
table_header=@BOLD@@BRIGHT_CYAN@
table_border=@DIM@

# UI
spinner_frames=⠋,⠙,⠹,⠸,⠼,⠴,⠦,⠧,⠇,⠏
```

## ANSI Color Codes

```
Basic:        Bright:
@BLACK@       @BRIGHT_BLACK@
@RED@         @BRIGHT_RED@
@GREEN@       @BRIGHT_GREEN@
@YELLOW@      @BRIGHT_YELLOW@
@BLUE@        @BRIGHT_BLUE@
@MAGENTA@     @BRIGHT_MAGENTA@
@CYAN@        @BRIGHT_CYAN@
@WHITE@       @BRIGHT_WHITE@

Modifiers:
@BOLD@        @DIM@
@UNDERLINE@   @RESET@
```

## Best Practices

 Use 5-level hierarchy (primary -> subtle)
 Make label vs value visually distinct
 Limit palette to 2-3 colors for cohesion
 Test with real data before sharing
[FAIL] Don't make everything bright (screen vomit)
[FAIL] Don't ignore semantic purpose of keys

## Common Patterns

**Monochrome:** One color, varied brightness
```
primary=@BOLD@@BRIGHT_GREEN@
secondary=@BRIGHT_GREEN@
normal=@GREEN@
muted=@DIM@@GREEN@
```

**Duo-tone:** Base + accent
```
primary=@BOLD@@BRIGHT_CYAN@     # Primary color
secondary=@BRIGHT_CYAN@
normal=@WHITE@                  # Neutral
command=@BRIGHT_GREEN@          # Accent
```

**Professional:** Blues/grays
```
primary=@BOLD@@BRIGHT_BLUE@
secondary=@BLUE@
normal=@WHITE@
muted=@DIM@@WHITE@
```

## Available Styles (24)

**Modern:** default, greyscale, light, dark, slate, solarized-dark, 
solarized-light, nord, dracula

**Retro:** amber-terminal, apple-ii, bbs-bright, commodore-64, dos-blue, 
green-screen, photon, retro-rainbow, vt100

**Flair/Nature:** monokai, synthwave, cyberpunk, matrix, ocean, forest

## More Info

Full guide: `docs/STYLE_GUIDE.md`
Schema: `scratch/style_schema_v2.txt`
Examples: `styles/` directory
