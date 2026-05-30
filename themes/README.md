# CLIO Themes

Themes define the output format and layout of CLIO's terminal display. While styles control colors, themes control structure - what gets shown, how it's arranged, and which display format to use.

## Using Themes

```bash
./clio --theme verbose             # Use a theme for this session
/config theme compact               # Set default theme
./clio --list-themes                # Show all available themes
```

## Available Themes

| Theme | Description |
|-------|-------------|
| `default` | Standard output with all elements visible |
| `compact` | Condensed output, fewer blank lines |
| `console` | Console-optimized layout |
| `verbose` | Detailed output with full context |

## Theme File Format

Each `.theme` file contains key-value pairs that reference style tokens:

```
# Theme metadata
name=my-theme

# Display format: inline or box
tool_display_format=inline

# Output templates using {style.*} references
thinking_indicator={style.dim}(thinking...){reset}

# ... more keys
```

Themes reference styles using `{style.key_name}` syntax. The theme system resolves these at display time.

See [docs/STYLE_QUICKREF.md](../docs/STYLE_QUICKREF.md) for the complete list of theme keys and available placeholders.